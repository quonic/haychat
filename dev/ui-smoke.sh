#!/usr/bin/env bash
set -euo pipefail

# Smoke test for GUI automation (docs/testing-harness.md, "GUI automation"). It builds the
# client, starts a headless "bob" (the stdio harness), and runs the real GUI window as "alice"
# from a generated --ui-script on SDL's offscreen video driver, so no display is needed:
#
#   1. alice waits for #general, clicks it and the composer, types a message, presses Return,
#      and waits until the message is drawn in the transcript; bob must receive it
#   2. bob finds alice with `users` and sends her a direct message; alice waits until bob's
#      row appears in the Direct Messages section, clicks it, and asserts the message is shown
#   3. alice types a reply and presses Return; bob must receive it as a direct_message
#   4. alice is an admin (her profile connects once headlessly first, so the account exists
#      for deploy/sql/make-admin.sql): she clicks "+ New room", types a name, clicks Create,
#      and waits until the room is drawn; bob must receive room_membership and list it
#   5. alice clicks "Join voice" in #general and waits for the voice bar's "Voice connected";
#      bob must see her in #general's voice participants. She mutes (bob sees her muted),
#      opens Settings → Voice while joined, closes it, and leaves voice (bob sees the room's
#      voice empty). The window runs on SDL's dummy audio driver (SDL_AUDIO_DRIVER), so the
#      device engine opens without sound hardware.
#   6. context menus: alice right-clicks her #general message, clicks "Copy message", right-
#      clicks the empty composer, clicks "Paste" and sends it again (bob must receive it a
#      second time). bob then posts in alice's new room, which she is not viewing; she waits
#      for its unread badge, right-clicks the channel and clicks "Mark as read". A second
#      headless session of alice's account (her profile) must get the read_marker for it.
#   7. admin (plan P4): alice right-clicks bob in Members and clicks "Make admin"; bob's harness
#      must see account_updated with isAdmin true without reconnecting. She removes the role
#      again (another admin cannot be banned), clicks "Ban…" in his menu, which opens Server
#      settings → Admin with the ban confirmation, types a reason and confirms; bob must get
#      session_ended "banned" with that reason. She unbans him with the Admin section's Unban
#      and bob's `reconnect` signs in again. bob joins #general's voice; alice right-clicks his
#      voice row and mutes him for herself from the menu, which also holds his volume slider.
#      Last, she edits her room to "Voice" in the room form (a note replaces the composer),
#      then to "Text", and Join voice disappears from its header and its menu; bob's room list
#      must show the room as text-only (roomType 1). She opens Server settings from the rail
#      button's menu and scrolls to the Admin section's rooms list.
#   8. access modes (protocol 15): alice creates an Admin invite room from the room form (Who
#      can join: Admin invite), invites bob from his member menu (Invite to room… → Invite to
#      #room), and opens the room's Members page from its channel menu, which offers Leave
#      room; bob must receive room_membership for it and list it with access 3.
#   9. encryption keys (protocol 16): alice opens bob's Verify encryption… dialog from his
#      member menu, waits for his key (the safety number and "Not verified yet."), clicks Mark
#      as verified and closes the dialog. Her key store file must then hold bob verified.
#  10. encrypted direct messages (protocol 17): bob's message in step 2 and alice's reply are
#      end-to-end encrypted, so alice's pane shows the lock badge (step 2). dave, a headless
#      account whose key bundle SQL removed, cannot be encrypted to: alice opens his
#      conversation, sees the banner saying why instead of a composer, turns on "Send without
#      encryption", accepts the first-time confirmation, sees the red "Unencrypted: the server
#      can read this" label, and sends with "Send unencrypted"; her message shows the
#      "Unencrypted" badge and dave receives it unencrypted with a valid signature.
#  11. encrypted rooms (protocol 18): alice opens the room form, picks Admin invite, sees
#      "Encrypt this room" on by default with herself checked as a manager, and creates
#      the room. Its Members page opens with the verified member list: alice as member and
#      manager, the Managers and Admins sections, and the room's SQL row is encrypted.
#
# alice takes a screenshot (BMP) at each step. They are kept after the run, in
# HAYCHAT_UI_SCREENSHOT_DIR when it is set and in a new temporary directory otherwise, and the
# script prints their paths. `magick FILE.bmp FILE.png` converts one.
#
# dev/live-proof.sh --ui runs it against its throwaway server. SDL_VIDEO_DRIVER may be set to
# use another driver (for example `wayland` to watch the window on a desktop).
#
# Usage: dev/ui-smoke.sh [HOST:PORT]   (default 127.0.0.1:12345)

repo_dir=$(cd -- "$(dirname -- "$0")/.." >/dev/null 2>&1 && pwd)
server_address=${1:-127.0.0.1:12345}
command_timeout_secs=30
smoke_label=ui

work_dir=$(mktemp -d -t haychat-ui-smoke.XXXXXX)
client_bin="$work_dir/haychat-client"
run_tag=$(date +%s%N)
screenshot_dir=${HAYCHAT_UI_SCREENSHOT_DIR:-}
if [[ -z "$screenshot_dir" ]]; then
	screenshot_dir=$(mktemp -d -t haychat-ui-shots.XXXXXX)
fi
mkdir -p -- "$screenshot_dir"
screenshot_dir=$(cd -- "$screenshot_dir" && pwd)

declare -A client_pid=()
declare -A client_fd=()
gui_pid=""
watched_pid=""

print_gui_output() {
	echo "---- GUI alice stdout ----" >&2
	cat "$work_dir/alice.out" >&2 || true
	echo "---- GUI alice stderr ----" >&2
	cat "$work_dir/alice.err" >&2 || true
	echo "---- end GUI output ----" >&2
}

on_exit() {
	local status=$? client
	for client in "${!client_pid[@]}"; do
		kill "${client_pid[$client]}" 2>/dev/null || true
	done
	if [[ -n "$gui_pid" ]]; then
		kill "$gui_pid" 2>/dev/null || true
	fi
	if [[ $status -ne 0 ]]; then
		print_client_output
		if [[ -f "$work_dir/alice.out" ]]; then
			print_gui_output
		fi
	fi
	rm -rf -- "$work_dir"
	exit "$status"
}
trap on_exit EXIT

# shellcheck source=dev/harness-lib.sh
source "$repo_dir/dev/harness-lib.sh"

cd "$repo_dir"
echo "==> [ui] building the client"
odin build client -out:"$client_bin"

nickname_alice="ui-alice-$run_tag"
nickname_bob="ui-bob-$run_tag"
room_message="ui smoke room $run_tag"
dm_message="ui smoke dm from bob $run_tag"
reply_message="ui smoke reply from alice $run_tag"
admin_room="ui-room-$run_tag"
unread_message="ui smoke unread from bob $run_tag"
ban_reason="ui smoke ban $run_tag"
access_room="ui-invite-$run_tag"
nickname_dave="ui-dave-$run_tag"
plain_message="ui smoke unencrypted to dave $run_tag"
encrypted_room="ui-secret-$run_tag"

# run_sql SQL: runs statements against the server's database, like make_admin.
run_sql() {
	command -v psql >/dev/null 2>&1 || fail "the UI smoke test needs psql on PATH"
	PGPASSWORD="${HAYCHAT_DATABASE_PASS:-haychat}" psql -q -X -t -A -v ON_ERROR_STOP=1 \
		-h "${HAYCHAT_DATABASE_URL:-localhost}" -p "${HAYCHAT_DATABASE_PORT:-5432}" \
		-U "${HAYCHAT_DATABASE_USER:-haychat}" -d "${HAYCHAT_DATABASE_NAME:-haychat}" \
		-c "$1" || fail "SQL failed: $1"
}

echo "==> [ui] starting headless bob"
start_client bob "$nickname_bob"
if ! connected_line=$(wait_for_line bob '{"event":"connected",' 0); then
	fail "bob could not connect"
fi
[[ "$connected_line" =~ \"userID\":([0-9]+), ]] || fail "bob's connected event has no userID"
user_bob=${BASH_REMATCH[1]}
echo "    bob< $connected_line"
expect_ok bob wait room_list 5000

# The admin role needs an account to grant it to, so alice's profile signs in once headlessly
# (creating the account under her key) before her window opens with the same profile.
echo "==> [ui] creating alice's account and making her an admin"
start_client alice-setup "$nickname_alice" alice
expect_connected alice-setup
stop_client alice-setup
make_admin "$nickname_alice"

# dave stays signed in for the whole run with his key bundle removed behind the server's back:
# his client published it once per session, so nobody can fetch it until he signs in again.
echo "==> [ui] starting headless dave, whose encryption key the server no longer has"
start_client dave "$nickname_dave"
if ! dave_connected=$(wait_for_line dave '{"event":"connected",' 0); then
	fail "dave could not connect"
fi
[[ "$dave_connected" =~ \"userID\":([0-9]+), ]] || fail "dave's connected event has no userID"
user_dave=${BASH_REMATCH[1]}
expect_ok dave wait room_list 5000
for ((attempt = 0; attempt < 50; attempt++)); do
	[[ $(run_sql "SELECT count(*) FROM user_encryption_keys WHERE user_id = $user_dave") == 1 ]] &&
		break
	sleep 0.1
done
run_sql "DELETE FROM user_encryption_keys WHERE user_id = $user_dave" >/dev/null
expect_ok dave users
[[ "$last_result" =~ \{\"id\":([0-9]+),\"nickname\":\"$nickname_alice\", ]] ||
	fail "dave's users do not list $nickname_alice"
user_alice_for_dave=${BASH_REMATCH[1]}
# dave pins alice, so he can check her signature.
expect_ok dave user-keys "$user_alice_for_dave"

# alice's profile is fresh, so its only server gets ID 1; the DM composer's widget ID is
# idOf("dm-input", serverID, peerUserID).
script="$work_dir/alice.uis"
cat >"$script" <<EOF
# Generated by dev/ui-smoke.sh for run $run_tag.
wait-text "# general" 15000
screenshot $screenshot_dir/01-connected.bmp
click "# general"
click "Message #general (Enter to send, Shift+Enter for newline)"
type "$room_message"
screenshot $screenshot_dir/02-room-typed.bmp
key Return
wait-text "$room_message" 10000
screenshot $screenshot_dir/03-room-sent.bmp
# bob's row is drawn twice once his message arrives: under Direct Messages and under Members.
wait-count 2 "$nickname_bob" 30000
screenshot $screenshot_dir/04-dm-received.bmp
click "$nickname_bob"
wait-text "$dm_message" 10000
assert-text "$dm_message"
# bob's message is end-to-end encrypted (protocol 17): it carries the lock badge.
wait-text "🔒" 5000
screenshot $screenshot_dir/05-dm-open.bmp
click-id dm-input 1 $user_bob
type "$reply_message"
key Return
wait-text "$reply_message" 10000
screenshot $screenshot_dir/06-dm-replied.bmp
# Server settings from the sidebar header's gear: bob is listed in the Voice section, and
# Mute for me toggles (local only; the server is not told).
click-id server-settings 1
wait-text "Display name on this server" 5000
click-id server-voice-mute 1 $user_bob
wait-text "Muted for me" 5000
screenshot $screenshot_dir/06b-server-settings.bmp
click-id server-voice-mute 1 $user_bob
wait-text "Mute for me" 5000
click-id server-settings-close 1
# alice signed in as an admin, so the Channels header offers "+ New room".
click "+ New room"
click "e.g. random"
type "$admin_room"
screenshot $screenshot_dir/07-new-room-form.bmp
click-id room-editor-submit
wait-text "# $admin_room" 10000
screenshot $screenshot_dir/08-room-created.bmp
# Voice in #general (room 1 on server 1): the header button, the voice bar, mute, settings.
click "# general"
click-id room-voice 1 1
wait-text "Voice connected: #general on $server_address" 15000
screenshot $screenshot_dir/09-voice-connected.bmp
click-id voice-mute
wait-text "Unmute" 5000
screenshot $screenshot_dir/10-voice-muted.bmp
click-id rail-settings
click "Voice"
wait-text "Your input in voice. Leave voice to test your microphone." 5000
screenshot $screenshot_dir/11-voice-settings.bmp
# The gear closes settings again (the section scrolls; its Done button is below the fold).
click-id rail-settings
click-id voice-leave
wait-text "Join voice" 5000
screenshot $screenshot_dir/12-voice-left.bmp
# Context menus: copy the message from its menu, paste it with the composer's own menu (the
# right-click focuses the composer), and send it again.
right-click "$room_message"
wait-text "Copy message" 5000
screenshot $screenshot_dir/13-message-menu.bmp
click "Copy message"
right-click "Message #general (Enter to send, Shift+Enter for newline)"
wait-text "Paste" 5000
click "Paste"
# The composer applies the paste on its next frame; its text is not findable, so just wait.
wait 300
key Return
wait-count 2 "$room_message" 10000
screenshot $screenshot_dir/14-message-pasted.bmp
# bob posts in the new room once alice is in #general: its unread badge is the only "1" drawn.
wait-text "1" 30000
right-click "# $admin_room"
wait-text "Mark as read" 5000
screenshot $screenshot_dir/15-channel-menu.bmp
click "Mark as read"
screenshot $screenshot_dir/16-channel-read.bmp
# Admin: make bob an admin from his Members row. The menu is rebuilt every frame, so once the
# server's user_updated arrives his entry reads "Remove admin".
right-click-id dm-member 1 $user_bob
wait-text "Make admin" 5000
screenshot $screenshot_dir/17-member-admin-menu.bmp
click "Make admin"
right-click-id dm-member 1 $user_bob
wait-text "Remove admin" 10000
screenshot $screenshot_dir/18-bob-admin.bmp
# Another admin cannot be banned (D6): remove the role, then ban from the same menu. Ban… opens
# Server settings → Admin with the confirmation open and scrolled into view.
click "Remove admin"
right-click-id dm-member 1 $user_bob
wait-text "Make admin" 10000
click "Ban…"
wait-text "Ban $nickname_bob" 5000
wait 500
click-id admin-confirm-text 1 $user_bob
type "$ban_reason"
screenshot $screenshot_dir/19-ban-confirm.bmp
click-id admin-confirm 1 $user_bob
# The server's answer is shown under his row, which keeps its place (sorted by name).
wait-text "Banned $nickname_bob" 10000
wait 300
screenshot $screenshot_dir/20-bob-banned.bmp
click-id admin-member-ban 1 $user_bob
wait-text "Unbanned $nickname_bob" 10000
wait 300
screenshot $screenshot_dir/21-bob-unbanned.bmp
click-id server-settings-close 1
# bob signs in again and joins #general's voice: his name is then drawn a third time (after his
# conversation and Members rows), under the channel. His voice row's menu mutes him for alice
# only and holds his volume.
wait-count 3 "$nickname_bob" 30000
right-click-id voice-participant 1 1 $user_bob
wait-text "Mute for me" 5000
screenshot $screenshot_dir/22-participant-menu.bmp
click "Mute for me"
right-click-id voice-participant 1 1 $user_bob
wait-text "Unmute for me" 5000
key Escape
wait-gone "Unmute for me" 5000
# Room types, from the room form: alice's room becomes voice only (a note replaces the
# composer), then text only (Join voice goes from its header and its menu).
click "# $admin_room"
wait-text "Join voice" 5000
right-click "# $admin_room"
click "Edit room…"
wait-text "Text and voice" 5000
click-id room-type 2
click-id room-editor-submit
wait-text "This room is voice only" 10000
assert-text "Join voice"
screenshot $screenshot_dir/23-room-voice-only.bmp
right-click "# $admin_room"
click "Edit room…"
wait-text "Type" 5000
click-id room-type 1
screenshot $screenshot_dir/24-room-type-text.bmp
click-id room-editor-submit
wait-text "Message #$admin_room (Enter to send, Shift+Enter for newline)" 10000
wait-gone "Join voice" 5000
screenshot $screenshot_dir/25-room-text-only.bmp
right-click "# $admin_room"
wait-text "Copy room name" 5000
assert-text "Mark as read"
wait-gone "Join voice" 1000
screenshot $screenshot_dir/26-text-only-menu.bmp
key Escape
# Server settings from the rail button's menu, scrolled to the end (the offset clamps there),
# where the Admin section's rooms list sits above the server key. Under --all the server has
# every earlier proof's accounts, so the page is long.
right-click-id rail-server 1
click "Server settings"
wait-text "Display name on this server" 5000
scroll 760 400 100
scroll 760 400 100
scroll 760 400 100
wait-text "Create room…" 5000
screenshot $screenshot_dir/27-admin-rooms.bmp
click-id server-settings-close 1
# Access modes: an Admin invite room from the form, bob invited from his member menu, and the
# room's Members page from its channel menu.
click "+ New room"
click "e.g. random"
type "$access_room"
click-id room-access 3
wait-text "Only admins add and remove people. Members can leave." 5000
# An invite room is encrypted by default (protocol 18); this one is the plain invite room.
wait-text "Encrypt this room: on" 5000
click-id room-editor-encrypt
wait-text "Encrypt this room: off" 5000
screenshot $screenshot_dir/28-access-room-form.bmp
click-id room-editor-submit
wait-text "# $access_room" 10000
right-click-id dm-member 1 $user_bob
click "Invite to room…"
click "Invite to #$access_room"
wait-text "Added $nickname_bob to #$access_room." 10000
right-click "# $access_room"
click "Members…"
wait-text "Members of #$access_room" 5000
wait-text "Leave room" 5000
screenshot $screenshot_dir/29-room-members.bmp
click "Close"
# Encryption keys (protocol 16): bob's Verify encryption… dialog from his member menu fetches
# his bundle and shows the safety number; Mark as verified pins him verified.
right-click-id dm-member 1 $user_bob
click "Verify encryption…"
wait-text "Verify encryption with $nickname_bob" 5000
wait-text "Not verified yet." 10000
screenshot $screenshot_dir/30-verify-dialog.bmp
click-id verify-mark 1 $user_bob
wait-text "Verified. The keys match what you compared." 5000
screenshot $screenshot_dir/31-verified.bmp
click-id verify-close 1 $user_bob
wait-gone "Verify encryption with $nickname_bob" 5000
# Encrypted direct messages (protocol 17): dave has no key on the server, so his conversation
# shows why instead of a composer, with the Send without encryption switch.
click "$nickname_dave"
wait-text "$nickname_dave has not set up encryption yet, so messages to $nickname_dave cannot be encrypted." 10000
screenshot $screenshot_dir/32-fallback-banner.bmp
click-id dm-fallback-switch 1 $user_dave
wait-text "Turn on" 5000
screenshot $screenshot_dir/33-fallback-confirm.bmp
click "Turn on"
wait-text "Unencrypted: the server can read this" 5000
click-id dm-input 1 $user_dave
type "$plain_message"
click "Send unencrypted"
wait-text "$plain_message" 10000
wait-text "Unencrypted" 5000
screenshot $screenshot_dir/34-fallback-sent.bmp
# Encrypted rooms (protocol 18): Encrypt this room is on by default for an invite room, with
# alice checked as a manager (bob is no longer an admin); the Members page that opens shows the
# verified member list.
click "+ New room"
click "e.g. random"
type "$encrypted_room"
click-id room-access 3
wait-text "Encrypt this room: on" 5000
# The managers list makes the form taller than the window: it and Create are below the fold.
scroll 760 400 100
wait-text "[x] $nickname_alice (you)" 5000
screenshot $screenshot_dir/35-encrypted-room-form.bmp
click-id room-editor-submit
wait-text "Members of #$encrypted_room" 10000
wait-text "Managers" 10000
wait-text "$nickname_alice (you) (manager) · You" 10000
screenshot $screenshot_dir/36-encrypted-room-members.bmp
click "Close"
quit
EOF

# Anything bob printed before the window opens cannot be about alice's new room.
admin_start=$(wc -l <"$work_dir/bob.out")
echo "==> [ui] starting the GUI as alice (SDL_VIDEO_DRIVER=${SDL_VIDEO_DRIVER:-offscreen})"
SDL_VIDEO_DRIVER=${SDL_VIDEO_DRIVER:-offscreen} SDL_AUDIO_DRIVER=${SDL_AUDIO_DRIVER:-dummy} \
	"$client_bin" --ui-script "$script" \
	--name "$nickname_alice" --server "$server_address" \
	--config-dir "$work_dir/profile-alice" --window 1280x800 \
	>"$work_dir/alice.out" 2>"$work_dir/alice.err" &
gui_pid=$!
# Until alice has sent her reply, her window must stay up; stop waiting as soon as it exits.
watched_pid=$gui_pid

echo "==> [ui] alice sends to #general from the window, bob receives it"
room_pattern="^\\{\"event\":\"room_chat\",.*\"senderNickname\":\"$nickname_alice\","
room_pattern+=".*\"content\":\"$room_message\"\\}$"
room_line=$(wait_for_match bob "$room_pattern") ||
	fail "[room] bob did not receive alice's room message"
echo "    bob< $room_line"

echo "==> [ui] bob sends alice a direct message, alice opens it in the window"
expect_ok bob users
[[ "$last_result" =~ \{\"id\":([0-9]+),\"nickname\":\"$nickname_alice\",\"isOnline\":true, ]] ||
	fail "[dm] bob's users do not list $nickname_alice as online"
user_alice=${BASH_REMATCH[1]}
expect_ok bob dm "$user_alice" "$dm_message"

echo "==> [ui] alice replies from the window, bob receives it"
# alice may quit as soon as her reply is drawn, so her exit no longer ends the wait.
watched_pid=""
reply_pattern="^\\{\"event\":\"direct_message\",.*\"senderID\":$user_alice,"
reply_pattern+=".*\"content\":\"$reply_message\"\\}$"
reply_line=$(wait_for_match bob "$reply_pattern") ||
	fail "[dm] bob did not receive alice's reply"
echo "    bob< $reply_line"

echo "==> [ui] alice creates a room from the window, bob sees it"
membership_line=$(wait_for_match bob \
	'^\{"event":"room_membership",.*"joined":true,"userID":[0-9]+\}$' "$admin_start") ||
	fail "[admin] bob did not receive room_membership for alice's new room"
echo "    bob< $membership_line"
wait_for_match bob "^\\{\"event\":\"room_list\",.*\"name\":\"$admin_room\"" "$admin_start" \
	>/dev/null ||
	fail "[admin] bob's room list never listed $admin_room"
expect_ok bob rooms
[[ "$last_result" == *"\"name\":\"$admin_room\""* ]] ||
	fail "[admin] bob's rooms do not list $admin_room"
[[ "$last_result" =~ \{\"id\":([0-9]+),\"name\":\"$admin_room\" ]] ||
	fail "[admin] bob's rooms give no ID for $admin_room"
admin_room_id=${BASH_REMATCH[1]}

echo "==> [ui] alice joins voice in #general from the window, bob sees her, muted, then gone"
voice_pattern="^\\{\"event\":\"voice_participants\",.*\"roomID\":1,.*"
voice_pattern+="\\{\"userID\":$user_alice,\"nickname\":\"$nickname_alice\",\"muted\":false,"
voice_line=$(wait_for_match bob "$voice_pattern" "$admin_start") ||
	fail "[voice] bob never saw alice in #general's voice"
echo "    bob< $voice_line"
muted_pattern="^\\{\"event\":\"voice_participants\",.*\"roomID\":1,.*"
muted_pattern+="\\{\"userID\":$user_alice,\"nickname\":\"$nickname_alice\",\"muted\":true,"
muted_line=$(wait_for_match bob "$muted_pattern" "$admin_start") ||
	fail "[voice] bob never saw alice muted"
echo "    bob< $muted_line"
empty_line=$(wait_for_match bob \
	'^\{"event":"voice_participants",.*"roomID":1,.*"participants":\[\]\}$' "$admin_start") ||
	fail "[voice] bob never saw #general's voice empty after alice left"
echo "    bob< $empty_line"

echo "==> [ui] alice copies her message from its menu and pastes it into the composer"
first_room_line=$(grep -nE -m1 "$room_pattern" "$work_dir/bob.out" | cut -d: -f1)
again_line=$(wait_for_match bob "$room_pattern" "$first_room_line") ||
	fail "[menu] bob did not receive alice's pasted copy of her message"
echo "    bob< $again_line"

echo "==> [ui] bob posts in alice's new room, alice marks it read from the channel's menu"
# A second session of alice's account sees the read marker the server sends every session. It
# runs on a copy of her profile (same identity key): two clients writing one key store would
# overwrite each other's pins (an encrypted room's head, alice's verification of bob).
cp -r -- "$work_dir/profile-alice" "$work_dir/profile-alicewatch"
rm -rf -- "$work_dir/profile-alicewatch/haychat/keys"
start_client alice-watch "$nickname_alice" alicewatch
expect_connected alice-watch
expect_ok bob send "$admin_room_id" "$unread_message"
marker_pattern="^\\{\"event\":\"read_marker\",.*\"kind\":\"room\","
marker_pattern+="\"conversationID\":$admin_room_id,.*\"unreadCount\":0\\}$"
marker_line=$(wait_for_match alice-watch "$marker_pattern") ||
	fail "[menu] alice's account never got a read marker for $admin_room"
echo "    alice-watch< $marker_line"

echo "==> [ui] alice makes bob an admin from his member menu, bob sees it without reconnecting"
admin_on=$(wait_for_match bob '^\{"event":"account_updated",.*"isAdmin":true,' "$admin_start") ||
	fail "[admin] bob never got account_updated with isAdmin true"
echo "    bob< $admin_on"
admin_off=$(wait_for_match bob '^\{"event":"account_updated",.*"isAdmin":false,' "$admin_start") ||
	fail "[admin] bob never got account_updated with isAdmin false"
echo "    bob< $admin_off"

echo "==> [ui] alice bans bob from his member menu with a reason"
ban_pattern="^\\{\"event\":\"session_ended\",.*\"kind\":\"banned\",.*\"reason\":\"$ban_reason\""
ban_line=$(wait_for_match bob "$ban_pattern" "$admin_start") ||
	fail "[admin] bob never got session_ended banned with the reason"
echo "    bob< $ban_line"

echo "==> [ui] alice unbans bob in the Admin section, bob signs in again and joins voice"
unbanned_shot="\"file\":\"$screenshot_dir/21-bob-unbanned.bmp\""
for ((attempt = 0; attempt < command_timeout_secs * 5; attempt++)); do
	grep -Fq -- "$unbanned_shot" "$work_dir/alice.out" && break
	kill -0 "$gui_pid" 2>/dev/null || fail "[admin] alice's window exited before the unban"
	sleep 0.2
done
grep -Fq -- "$unbanned_shot" "$work_dir/alice.out" || fail "[admin] alice never unbanned bob"
reconnect_start=$(wc -l <"$work_dir/bob.out")
expect_ok bob reconnect
reconnected=$(wait_for_line bob '{"event":"connected",' "$reconnect_start") ||
	fail "[admin] bob could not sign in again after the unban"
echo "    bob< $reconnected"
expect_ok bob wait room_list 5000
expect_ok bob voice-join 1

gui_status=0
wait "$gui_pid" || gui_status=$?
gui_pid=""
sed 's/^/    alice< /' "$work_dir/alice.out"
[[ $gui_status -eq 0 ]] || fail "the GUI script exited with status $gui_status"
grep -Fqx '{"event":"ui_script_done","failed":0,"skipped":0}' "$work_dir/alice.out" ||
	fail "the GUI script did not report every command as done"

echo "==> [ui] alice made her room text-only in the room form, bob lists it as text-only"
expect_ok bob rooms
[[ "$last_result" =~ \{\"id\":$admin_room_id,\"name\":\"$admin_room\",[^}]*\"roomType\":1 ]] ||
	fail "[admin] bob's rooms do not list $admin_room as text-only: $last_result"
expect_ok bob voice-leave

echo "==> [ui] alice made an Admin invite room in the form and invited bob from his menu"
invite_line=$(wait_for_match bob \
	"^\\{\"event\":\"room_membership\",.*\"joined\":true,\"userID\":$user_bob\\}$" \
	"$reconnect_start") || fail "[access] bob was never added to alice's invite room"
echo "    bob< $invite_line"
expect_ok bob rooms
[[ "$last_result" =~ \{\"id\":[0-9]+,\"name\":\"$access_room\",[^}]*\"access\":3, ]] ||
	fail "[access] bob's rooms do not list $access_room as Admin invite: $last_result"

echo "==> [ui] alice verified bob in the Verify encryption… dialog"
key_stores=("$work_dir"/profile-alice/haychat/keys/*.json)
[[ -f "${key_stores[0]}" ]] || fail "[e2ee] alice has no key store file"
tr -d ' \n' <"${key_stores[0]}" | grep -Eq "\"user_id\":$user_bob,[^}]*\"verified\":true" ||
	fail "[e2ee] alice's key store does not hold bob verified"

echo "==> [ui] alice sent dave an unencrypted, signed message through the fallback switch"
plain_pattern="^\\{\"event\":\"direct_message\",.*\"encrypted\":false,\"signed\":true,"
plain_pattern+=".*\"content\":\"$plain_message\"\\}$"
plain_line=$(wait_for_match dave "$plain_pattern") ||
	fail "[e2ee] dave did not receive alice's signed plaintext message"
echo "    dave< $plain_line"

echo "==> [ui] alice created an encrypted room from the form, signed by her as its manager"
encrypted_row=$(run_sql "SELECT r.encrypted || ':' || r.log_version || ':' ||
	(SELECT count(*) FROM room_members m WHERE m.room_id = r.id) || ':' ||
	(SELECT count(*) FROM room_log_managers g WHERE g.room_id = r.id
		AND g.user_id = $user_alice)
	FROM rooms r WHERE r.name = '$encrypted_room'")
# Under --all earlier proofs leave other admins, whom the form names as managers too.
[[ "$encrypted_row" == "true:1:1:1" ]] ||
	fail "[e2ee] the encrypted room is not encrypted at version 1 with alice: $encrypted_row"

stop_client alice-watch
stop_client bob
stop_client dave

echo "==> [ui] screenshots written:"
written=0
for shot in "$screenshot_dir"/[0-9][0-9]-*.bmp; do
	[[ -f "$shot" ]] || continue
	echo "    $shot"
	written=$((written + 1))
done
[[ $written -eq 36 ]] || fail "expected 36 screenshots in $screenshot_dir, found $written"
echo "==> [ui] passed"
