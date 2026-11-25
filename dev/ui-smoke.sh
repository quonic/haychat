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
#      Protocol 19: alice sends a message there; the header shows the lock, the message
#      carries the lock badge, and its SQL row is sealed with an empty content.
#  12. roles (protocol 23): in Server settings → Admin alice clicks "New role…", names the
#      role, ticks Create invites and creates it; SQL must find the role with that permission.
#  13. registration (protocol 25): before the window opens, headless erin asks to sign up with
#      an operator's code (deploy/sql/create-invite.sql) while the server is briefly in
#      Invite + approval mode, so her request waits. alice's sidebar gear shows the approver
#      badge ("⚙ N") and Sign-up requests "N pending"; she switches the registration mode and
#      back (bob sees both registration_mode events), creates an invite code with "New
#      invite…" and "Create code" (the code and "Copy link" are shown once; SQL must find it
#      under her account), and approves erin's request, which drops the badge; erin, still
#      connected, is signed up at once.
#  14. attachments (attachments plan F4): in #general alice attaches a file (`attach-file`, as
#      if picked in the open dialog) and drops one far over the size limit on the window
#      (`drop-file`), which is refused before its upload and stays as a failed chip while Send
#      waits; she removes the failed chip, the
#      upload finishes and she sends the file with a line of text. bob must list it signed and
#      save it with a matching hash. bob sends alice an encrypted file in their direct
#      conversation; she saves it through its card (`save-path` answers the save dialog) and
#      its hash must match. Admin alice removes her own file from its card's menu with a
#      reason: her card shows "Attachment removed by an admin", bob hears attachment_removed
#      and his history lists it removed. Last she opens Admin → Storage and
#      (protocol 29) Removed files, which lists her removal with its reason.
#  15. editing and deleting messages (#76 M3): in #general alice sends a message, edits it from
#      its menu ("Editing message" bar, Ctrl+A, new text, Return) and again with Up in the empty
#      composer; bob must print both edits verified. She rests the pointer on "(edited)"
#      (`hover`) and the history shows the original and both edits. She deletes the message
#      from its menu (the confirmation names its files and edit history) and it reads "Message
#      deleted"; as an admin she deletes bob's #general message, which reads "Removed by the
#      server", and bob prints both tombstones (removedByServer false, then true). Last she
#      edits and deletes a message in her encrypted conversation with bob, who prints the
#      verified edit and the signed tombstone.
#
# Under --all the server holds every earlier proof's accounts, so the Admin section is several
# screens long: the script reaches each control with `scroll-until`, never by a fixed scroll.
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
	if [[ -n "$original_mode" ]]; then
		ui_psql -c "UPDATE server_settings SET registration_mode = $original_mode" >/dev/null ||
			echo "could not restore the registration mode" >&2
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
# The echo canceller's wrapper (#171) next to the client, as the release ships it, so the GUI's
# defaults (echo cancellation and WebRTC's noise suppression on) run on the dummy audio driver.
deploy/build-linux-webrtc-apm.sh "$(dirname -- "$client_bin")"

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
encrypted_room_message="ui smoke sealed room message $run_tag"
gui_role="ui-role-$run_tag"
nickname_erin="ui-erin-$run_tag"
# Step 14's files: alice's (8 MiB, so the chip is still uploading for its screenshot), one far
# over any size limit (sparse: refused from its size alone, never read), and bob's (6 MiB).
alice_file_name="ui-file-$run_tag.bin"
alice_file="$work_dir/$alice_file_name"
head -c $((8 * 1024 * 1024)) /dev/urandom >"$alice_file"
alice_file_sha=$(sha256sum "$alice_file" | cut -d' ' -f1)
huge_file="$work_dir/ui-huge-$run_tag.bin"
truncate -s 2G "$huge_file"
bob_file_name="ui-bob-file-$run_tag.bin"
bob_file="$work_dir/$bob_file_name"
head -c $((6 * 1024 * 1024)) /dev/urandom >"$bob_file"
bob_file_sha=$(sha256sum "$bob_file" | cut -d' ' -f1)
alice_saved="$work_dir/alice-saved-$run_tag.bin"
file_message="ui smoke file from alice $run_tag"
bob_file_message="ui smoke file from bob $run_tag"
remove_reason="ui smoke removal $run_tag"
# Step 15's messages (#76 M3).
edit_target="ui smoke edit me $run_tag"
edit_first="ui smoke edited once $run_tag"
edit_second="ui smoke edited twice $run_tag"
bob_doomed="ui smoke bob says $run_tag"
dm_edit_target="ui smoke dm edit me $run_tag"
dm_edited="ui smoke dm edited $run_tag"
# The registration mode the server had, restored on exit whatever happens (step 13 changes it).
original_mode=""

# ui_psql ARGS...: psql against the server's database, like make_admin.
ui_psql() {
	PGPASSWORD="${HAYCHAT_DATABASE_PASS:-haychat}" psql -q -X -t -A -v ON_ERROR_STOP=1 \
		-h "${HAYCHAT_DATABASE_URL:-localhost}" -p "${HAYCHAT_DATABASE_PORT:-5432}" \
		-U "${HAYCHAT_DATABASE_USER:-haychat}" -d "${HAYCHAT_DATABASE_NAME:-haychat}" "$@"
}

# run_sql SQL: runs statements against the server's database.
run_sql() {
	command -v psql >/dev/null 2>&1 || fail "the UI smoke test needs psql on PATH"
	ui_psql -c "$1" || fail "SQL failed: $1"
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

# erin's sign-up request waits for alice's approval in the window, so its ID can go into the
# script. The server is in Invite + approval mode only while she asks.
echo "==> [ui] erin asks to sign up in Invite + approval mode; alice will approve her"
original_mode=$(run_sql "SELECT registration_mode FROM server_settings")
[[ "$original_mode" =~ ^[123]$ ]] || fail "unexpected registration mode '$original_mode'"
pending_before=$(run_sql "SELECT count(*) FROM registration_requests WHERE status = 1")
pending_with_erin=$((pending_before + 1))
run_sql "UPDATE server_settings SET registration_mode = 3" >/dev/null
erin_code=$(ui_psql -v uses=1 -v days=1 -v note="ui smoke $run_tag" \
	-f deploy/sql/create-invite.sql | tail -n 1) || fail "create-invite.sql failed"
start_client_at erin "$nickname_erin" "$server_address" --invite-code "$erin_code" \
	--reason "ui smoke applicant $run_tag"
erin_pending=$(wait_for_match erin '^\{"event":"registration_result",.*"status":"pending",') ||
	fail "[registration] erin's sign-up request is not pending"
echo "    erin< $erin_pending"
run_sql "UPDATE server_settings SET registration_mode = $original_mode" >/dev/null
request_erin=$(run_sql "SELECT id FROM registration_requests
	WHERE nickname = '$nickname_erin' AND status = 1")
[[ "$request_erin" =~ ^[0-9]+$ ]] || fail "[registration] erin's request has no ID"
# The mode alice switches to in the window, and the sentence each mode shows under the picker.
other_mode=2
[[ "$original_mode" == 2 ]] && other_mode=3
mode_texts=(
	""
	"Anyone may sign up on this server; an invite code can give you roles or a room."
	"This server needs an invite code to sign up"
	"This server needs an invite code and approval to sign up"
)
mode_words=("" open invite approval)
if ((pending_before == 0)); then
	badge_after_approval="wait-gone \"1 pending\" 10000"
else
	badge_after_approval="wait-text \"$pending_before pending\" 10000"
fi

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
# Server settings from the rail button's menu, scrolled down to the Admin section's rooms list
# (Storage follows it). Under --all the server has every earlier proof's accounts, so the page
# is long and its length depends on them: scroll-until, never a fixed scroll.
right-click-id rail-server 1
click "Server settings"
wait-text "Display name on this server" 5000
scroll-until "Create room…" 760 400 3 30000
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
# Sender chains (protocol 19): alice's message in the encrypted room is sealed with her chain;
# the header and the message carry the lock (member list lines do not).
click "# $encrypted_room"
wait-text "🔒 # $encrypted_room" 10000
click "Message #$encrypted_room (Enter to send, Shift+Enter for newline)"
type "$encrypted_room_message"
key Return
wait-text "$encrypted_room_message" 15000
wait-text "🔒" 5000
screenshot $screenshot_dir/37-encrypted-room-message.bmp
# The approver badge (D18) on the sidebar gear: erin's request waited before the window opened.
wait-text "⚙ $pending_with_erin" 10000
screenshot $screenshot_dir/38-approver-badge.bmp
# Roles (protocol 23): a new role with Create invites from Server settings → Admin → Roles.
click-id server-settings 1
wait-text "Display name on this server" 5000
scroll-until "New role…" 760 400 2 30000
click-id admin-role-new 1
scroll-until "Room keepers" 760 400 2 10000
click-id admin-role-name 1 0
type "$gui_role"
scroll-until "Create invites" 760 400 2 10000
click-id admin-role-permission 1 0 2
scroll-until "Create" 760 400 2 10000
screenshot $screenshot_dir/39-role-form.bmp
click-id admin-role-save 1 0
scroll-until "$gui_role" 760 400 2 10000
screenshot $screenshot_dir/40-role-created.bmp
# Registration (protocol 25): the mode picker, there and back.
scroll-until "Invite + approval" 760 400 2 10000
click-id admin-registration-mode 1 $other_mode
wait-text "${mode_texts[$other_mode]}" 10000
screenshot $screenshot_dir/41-registration-mode.bmp
click-id admin-registration-mode 1 $original_mode
wait-text "${mode_texts[$original_mode]}" 10000
# Invites: a code made with the form's defaults is shown once, with Copy and Copy link.
scroll-until "New invite…" 760 400 2 10000
click-id admin-invite-new 1
scroll-until "Create code" 760 400 2 10000
click-id admin-invite-create 1
scroll-until "Copy link" 760 400 -2 10000
screenshot $screenshot_dir/42-invite-created.bmp
click-id admin-invite-done 1
wait-gone "Copy link" 5000
# Sign-up requests: the badge counts erin, and Approve drops it.
scroll-until "$nickname_erin" 760 400 2 10000
wait-text "$pending_with_erin pending" 5000
screenshot $screenshot_dir/43-signup-requests.bmp
click-id admin-request-approve 1 $request_erin
$badge_after_approval
# erin's new account joins the list above, which pushes her request down.
scroll-until "Approved" 760 400 2 10000
screenshot $screenshot_dir/44-request-approved.bmp
click-id server-settings-close 1
# Attachments (F4). The native dialogs cannot be driven: attach-file adds a file as if it was
# picked, save-path answers the next Save…; drop-file drops one on the window
# (SDL_EVENT_DROP_FILE). Chip indexes count from 0 in the order added.
click "# general"
wait-text "Message #general (Enter to send, Shift+Enter for newline)" 5000
attach-file $alice_file
drop-file $huge_file
wait-text "Attachment is too large" 5000
wait-text "Waiting for 1 upload to finish…" 5000
screenshot $screenshot_dir/45-composer-chips.bmp
click-id room-file-chip-remove 1 1 1
wait-gone "Attachment is too large" 5000
wait-gone "Waiting for 1 upload to finish…" 30000
click "Message #general (Enter to send, Shift+Enter for newline)"
type "$file_message"
screenshot $screenshot_dir/46-composer-ready.bmp
click-id room-send 1 1
wait-text "$file_message" 10000
wait-text "Save…" 10000
assert-text "$alice_file_name"
screenshot $screenshot_dir/47-file-card.bmp
# bob saves it, then sends alice an encrypted file in their conversation.
click-id dm-conversation 1 $user_bob
wait-text "$bob_file_name" 120000
save-path $alice_saved
click "Save…"
wait-text "Cancel" 5000
screenshot $screenshot_dir/48-file-saving.bmp
wait-text "Saved as $(basename "$alice_saved")" 30000
screenshot $screenshot_dir/49-file-saved.bmp
# Admin: remove her own file from its card's menu, with a reason.
click "# general"
wait-text "$alice_file_name" 10000
right-click "$alice_file_name"
wait-text "Remove attachment…" 5000
screenshot $screenshot_dir/50-file-menu.bmp
click "Remove attachment…"
wait-text "Reason (optional)" 5000
click-id attachment-remove-reason 1
type "$remove_reason"
screenshot $screenshot_dir/51-remove-confirm.bmp
click-id attachment-remove-confirm 1
wait-gone "Reason (optional)" 10000
wait-text "Attachment removed by an admin" 10000
screenshot $screenshot_dir/52-file-removed.bmp
# Admin → Storage, at the end of the Admin section.
click-id server-settings 1
wait-text "Display name on this server" 5000
scroll-until "Free space" 760 400 3 60000
screenshot $screenshot_dir/53-admin-storage.bmp
# Removed files (protocol 29, #138), after Storage: her removal, newest first, with its reason.
scroll-until "Reason: $remove_reason" 760 400 3 60000
assert-text "Removed files"
assert-text "$alice_file_name"
screenshot $screenshot_dir/54-removed-files.bmp
click-id server-settings-close 1
# Editing and deleting messages (#76 M3). Edit message from the menu opens the "Editing
# message" bar with the text in its own field; Ctrl+A and typing replace it.
click "# general"
click "Message #general (Enter to send, Shift+Enter for newline)"
type "$edit_target"
key Return
wait-text "$edit_target" 10000
right-click "$edit_target"
wait-text "Edit message" 5000
screenshot $screenshot_dir/55-message-menu.bmp
click "Edit message"
wait-text "Editing message" 5000
screenshot $screenshot_dir/56-editing.bmp
key Ctrl+A
type "$edit_first"
key Return
wait-gone "Editing message" 5000
wait-text "$edit_first" 10000
wait-text "(edited)" 5000
screenshot $screenshot_dir/57-edited.bmp
# Up in the empty composer edits her newest message again.
click "Message #general (Enter to send, Shift+Enter for newline)"
key Up
wait-text "Editing message" 5000
key Ctrl+A
type "$edit_second"
key Return
wait-text "$edit_second" 10000
wait-gone "$edit_first" 10000
# Resting on "(edited)" opens the history: the original and both edits, oldest first (the
# newest is drawn twice, in the transcript and in the history).
hover "(edited)"
wait-text "Edit history" 5000
wait-text "Original" 5000
wait-text "$edit_target" 5000
wait-text "$edit_first" 5000
wait-count 2 "$edit_second" 5000
screenshot $screenshot_dir/58-edit-history.bmp
hover 640 80
wait-gone "Edit history" 5000
# Delete her message from its menu: a confirmation, then the tombstone.
right-click "$edit_second"
click "Delete message…"
wait-text "Delete message" 5000
screenshot $screenshot_dir/59-delete-confirm.bmp
click-id message-delete-confirm 1
wait-text "Message deleted" 10000
wait-gone "$edit_second" 5000
screenshot $screenshot_dir/60-deleted.bmp
# As an admin, delete bob's message: members see "Removed by the server".
wait-text "$bob_doomed" 120000
right-click "$bob_doomed"
click "Delete message…"
wait-text "Delete message" 5000
screenshot $screenshot_dir/61-admin-delete-confirm.bmp
click-id message-delete-confirm 1
wait-text "Removed by the server" 10000
wait-gone "$bob_doomed" 5000
screenshot $screenshot_dir/62-admin-deleted.bmp
# A direct message: the conversation with bob is end-to-end encrypted, so the edit is sealed.
click-id dm-conversation 1 $user_bob
click-id dm-input 1 $user_bob
# Up opens her newest message here for editing; Esc leaves it unchanged.
key Up
wait-text "Editing message" 5000
key Escape
wait-gone "Editing message" 5000
click-id dm-input 1 $user_bob
type "$dm_edit_target"
key Return
wait-text "$dm_edit_target" 10000
right-click "$dm_edit_target"
click "Edit message"
wait-text "Editing message" 5000
key Ctrl+A
type "$dm_edited"
key Return
wait-text "$dm_edited" 10000
wait-text "(edited)" 10000
screenshot $screenshot_dir/63-dm-edited.bmp
right-click "$dm_edited"
click "Delete message…"
wait-text "Delete message" 5000
click-id message-delete-confirm 1
wait-text "Message deleted" 10000
wait-gone "$dm_edited" 5000
screenshot $screenshot_dir/64-dm-deleted.bmp
quit
EOF

# The screenshots the run must write, taken from the GUI script itself so the final check
# cannot drift from it. Any left in a reused HAYCHAT_UI_SCREENSHOT_DIR are removed first, so
# a shot this run failed to write is reported as missing.
expected_shots=()
while IFS= read -r line; do
	[[ "$line" == "screenshot "* ]] || continue
	expected_shots+=("${line#screenshot }")
done <"$script"
[[ ${#expected_shots[@]} -gt 0 ]] || fail "the GUI script takes no screenshots"
rm -f -- "${expected_shots[@]}"

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

# wait_for_shot NAME: waits (up to 4 minutes) until alice's window took screenshot NAME.
wait_for_shot() {
	local shot="\"file\":\"$screenshot_dir/$1\"" attempt
	for ((attempt = 0; attempt < 1200; attempt++)); do
		grep -Fq -- "$shot" "$work_dir/alice.out" && return 0
		kill -0 "$gui_pid" 2>/dev/null || fail "alice's window exited before $1"
		sleep 0.2
	done
	fail "alice's window never took $1"
}

echo "==> [ui] alice sends a file to #general from the window; bob saves it and checks it"
wait_for_shot 47-file-card.bmp
file_pattern="^\\{\"event\":\"room_chat\",.*\"senderNickname\":\"$nickname_alice\","
file_pattern+=".*\"name\":\"$alice_file_name\""
file_line=$(wait_for_match bob "$file_pattern" "$reconnect_start") ||
	fail "[files] bob did not receive alice's file"
echo "    bob< $file_line"
[[ "$file_line" == *"\"sha256\":\"$alice_file_sha\""*'"encrypted":false,"removed":false'* ]] ||
	fail "[files] bob's room_chat does not list alice's file as she signed it"
[[ "$file_line" == *"\"protection\":\"plain\",\"content\":\"$file_message\"}" ]] ||
	fail "[files] bob did not verify alice's message with its file"
[[ "$file_line" =~ \"messageID\":([0-9]+), ]] || fail "[files] no message ID in $file_line"
file_message_id=${BASH_REMATCH[1]}
[[ "$file_line" =~ \"blobID\":\"([0-9a-f]{32})\" ]] || fail "[files] no blob ID in $file_line"
alice_blob=${BASH_REMATCH[1]}
bob_saved="$work_dir/bob-saved-$run_tag.bin"
download_start=$(wc -l <"$work_dir/bob.out")
expect_ok bob attach-download 1 "$file_message_id" 0 "$bob_saved"
wait_for_match bob '^\{"event":"attachment_done",.*"direction":"download"' "$download_start" \
	>/dev/null || fail "[files] bob could not save alice's file"
[[ "$(sha256sum "$bob_saved" | cut -d' ' -f1)" == "$alice_file_sha" ]] ||
	fail "[files] bob's copy of alice's file does not match"

echo "==> [ui] bob sends alice an encrypted file; she saves it through its card"
upload_start=$(wc -l <"$work_dir/bob.out")
expect_ok bob attach-upload "@$user_alice" "$bob_file"
upload_line=$(wait_for_match bob '^\{"event":"attachment_done",.*"direction":"upload"' \
	"$upload_start") || fail "[files] bob's upload did not finish"
[[ "$upload_line" == *'"encrypted":true'* ]] || fail "[files] bob's file to alice was not sealed"
[[ "$upload_line" =~ \"blobID\":\"([0-9a-f]{32})\" ]] || fail "[files] no blob in $upload_line"
expect_ok bob dm "$user_alice" --attach "${BASH_REMATCH[1]}" "$bob_file_message"

echo "==> [ui] bob posts in #general for alice to delete as an admin (#76 M3)"
edits_start=$(wc -l <"$work_dir/bob.out")
expect_ok bob send 1 "$bob_doomed"

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
sealed_rows=$(run_sql "SELECT count(*) || ':' ||
	count(*) FILTER (WHERE c.sealed IS NOT NULL AND c.content = '') || ':' ||
	count(*) FILTER (WHERE position(convert_to('ui smoke sealed', 'UTF8') in c.sealed) > 0)
	FROM chat_messages c JOIN rooms r ON r.id = c.room_id WHERE r.name = '$encrypted_room'")
[[ "$sealed_rows" == "1:1:0" ]] ||
	fail "[e2ee] alice's room message is not one sealed row without its text: $sealed_rows"

echo "==> [ui] alice created a role with Create invites on the Roles page"
role_bits=$(run_sql "SELECT permissions FROM server_roles WHERE name = '$gui_role'")
[[ "$role_bits" == 4 ]] ||
	fail "[roles] the role $gui_role does not hold only Create invites (bit 4): '$role_bits'"

echo "==> [ui] alice switched the registration mode and back; bob saw both"
mode_pattern="^\\{\"event\":\"registration_mode\",\"serverID\":1,"
mode_pattern+="\"mode\":\"${mode_words[$other_mode]}\"\\}$"
mode_line=$(wait_for_match bob "$mode_pattern" "$reconnect_start") ||
	fail "[registration] bob never saw the mode become ${mode_words[$other_mode]}"
echo "    bob< $mode_line"
mode_at=$(grep -nE -m1 "$mode_pattern" "$work_dir/bob.out" | cut -d: -f1)
back_pattern="^\\{\"event\":\"registration_mode\",\"serverID\":1,"
back_pattern+="\"mode\":\"${mode_words[$original_mode]}\"\\}$"
back_line=$(wait_for_match bob "$back_pattern" "$mode_at") ||
	fail "[registration] bob never saw the mode go back to ${mode_words[$original_mode]}"
echo "    bob< $back_line"
[[ $(run_sql "SELECT registration_mode FROM server_settings") == "$original_mode" ]] ||
	fail "[registration] the server is not back in mode $original_mode"

echo "==> [ui] alice created an invite code in the window"
invites=$(run_sql "SELECT count(*) FROM invites WHERE created_by_user_id = $user_alice")
[[ "$invites" == 1 ]] || fail "[registration] alice's account has $invites invite codes, not 1"

echo "==> [ui] alice approved erin's request; erin, still connected, is signed up"
erin_created=$(wait_for_match erin '^\{"event":"connected",.*"registered":true') ||
	fail "[registration] erin was not signed up after the approval"
echo "    erin< $erin_created"
# The sign-in that created the account used the approved request up (D14).
[[ $(run_sql "SELECT count(*) FROM registration_requests WHERE id = $request_erin") == 0 ]] ||
	fail "[registration] erin's approved request was not used up by her sign-up"

echo "==> [ui] alice saved bob's file through its card"
[[ -f "$alice_saved" && ! -e "$alice_saved.part" ]] || fail "[files] alice's save left no file"
[[ "$(sha256sum "$alice_saved" | cut -d' ' -f1)" == "$bob_file_sha" ]] ||
	fail "[files] alice's copy of bob's file does not match"

echo "==> [ui] alice removed her file from its menu; bob sees it removed"
removed_line=$(wait_for_match bob \
	"^\\{\"event\":\"attachment_removed\",.*\"blobID\":\"$alice_blob\"" "$reconnect_start") ||
	fail "[files] bob never heard that alice's file was removed"
echo "    bob< $removed_line"
history_start=$(wc -l <"$work_dir/bob.out")
expect_ok bob history 1
history_line=$(wait_for_match bob "^\\{\"event\":\"room_history\"," "$history_start") ||
	fail "[files] bob got no history"
[[ "$history_line" == *"\"blobID\":\"$alice_blob\""*'"removed":true'* ]] ||
	fail "[files] bob's history does not list alice's file removed"

echo "==> [ui] alice edited and deleted messages from the window; bob saw each (#76 M3)"
# expect_bob_event PATTERN WHAT: a line of bob's matching PATTERN since step 15 began.
expect_bob_event() {
	local line
	line=$(wait_for_match bob "$1" "$edits_start") || fail "[edits] $2"
	echo "    bob< $line"
}
edited_pattern="^\\{\"event\":\"message_edited\",\"serverID\":1,\"kind\":\"room\",.*"
edited_pattern+="\"editStatus\":\"verified\",\"editFailure\":\"none\",\"content\":"
expect_bob_event "$edited_pattern\"$edit_first\"\\}$" "bob never saw alice's first edit verified"
expect_bob_event "$edited_pattern\"$edit_second\"\\}$" "bob never saw alice's second edit verified"
deleted_pattern="^\\{\"event\":\"message_deleted\",\"serverID\":1,\"kind\":\"room\","
deleted_pattern+="\"conversationID\":1,.*\"senderID\":"
tombstone_tail=",\"found\":true,\"deleted\":true,\"removedByServer\":"
expect_bob_event "$deleted_pattern$user_alice${tombstone_tail}false\\}$" \
	"bob never saw alice's signed delete"
expect_bob_event "$deleted_pattern$user_bob${tombstone_tail}true\\}$" \
	"bob never saw alice's admin delete of his message as removed by the server"
dm_edited_pattern="^\\{\"event\":\"message_edited\",\"serverID\":1,\"kind\":\"dm\",.*"
dm_edited_pattern+="\"editStatus\":\"verified\",\"editFailure\":\"none\","
dm_edited_pattern+="\"content\":\"$dm_edited\"\\}$"
expect_bob_event "$dm_edited_pattern" "bob never saw alice's sealed DM edit verified"
dm_deleted_pattern="^\\{\"event\":\"message_deleted\",\"serverID\":1,\"kind\":\"dm\",.*"
dm_deleted_pattern+="\"senderID\":$user_alice,\"found\":true,\"deleted\":true,"
dm_deleted_pattern+="\"removedByServer\":false\\}$"
expect_bob_event "$dm_deleted_pattern" "bob never saw alice's signed DM delete"

stop_client erin
stop_client alice-watch
stop_client bob
stop_client dave

echo "==> [ui] screenshots written:"
missing=()
for shot in "${expected_shots[@]}"; do
	if [[ -f "$shot" ]]; then
		echo "    $shot"
	else
		missing+=("$shot")
	fi
done
[[ ${#missing[@]} -eq 0 ]] ||
	fail "${#missing[@]} of ${#expected_shots[@]} screenshots are missing: ${missing[*]}"
echo "==> [ui] passed"
