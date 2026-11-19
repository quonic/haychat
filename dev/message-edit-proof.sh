#!/usr/bin/env bash
set -euo pipefail

# Live proof of editing and deleting messages (protocol 30, #76 M1,
# docs/plan/2026-11-19-message-edit-delete.md) with three headless clients
# (docs/testing-harness.md) against a running server:
#
#   1. room edit:   A edits its #general message; A and B print message_edited verified with the
#                   new text, B fetches the edit history (message_edits) and its history page
#                   carries editCount 1 and the latest version.
#   2. refusals:    B edits and deletes A's message (--unchecked, past the client's own check):
#                   the server refuses both, naming the message. A's forged edit (--forge, a bad
#                   signature) is refused too. B, no admin, is refused an admin delete.
#   3. room delete: A deletes its message: B prints message_deleted, removedByServer false, and
#                   B's history shows the tombstone. A (an admin) deletes B's message without a
#                   signature: both print it removedByServer true.
#   4. direct:      B's encryption key is removed in the database so A's DM to B goes out as
#                   signed plaintext (dm-plain); A edits it and B sees the edit verified and
#                   fetches its history; B's edit and delete of A's message are refused; A
#                   deletes it and B sees the signed tombstone. An encrypted DM from A to C: A's
#                   edit is refused locally (sealed edits are M2), A's signed delete reaches C.
#   5. from join:   in a Member invite room with From join history, A edits a message from
#                   before C joined: B hears of it, C does not (and is refused its edit
#                   history); A's edit of a later message reaches C.
#   6. files:       A sends a file in #general, B downloads it, A deletes the message: B hears
#                   attachment_removed and message_deleted, and B's next download of the blob is
#                   refused.
#
# dev/live-proof.sh --edits (and --all) runs it against its throwaway server. It needs bash,
# coreutils, sha256sum and psql (make-admin.sql and the key removal, through the
# HAYCHAT_DATABASE_* variables).
#
# Usage: dev/message-edit-proof.sh [HOST:PORT]   (default 127.0.0.1:12345)

repo_dir=$(cd -- "$(dirname -- "$0")/.." >/dev/null 2>&1 && pwd)
server_address=${1:-127.0.0.1:12345}
command_timeout_secs=10
smoke_label=edits

work_dir=$(mktemp -d -t haychat-edits.XXXXXX)
client_bin="$work_dir/haychat-client"
run_tag=$(date +%s%N)
run_tag=${run_tag: -9}

declare -A client_pid=()
declare -A client_fd=()

on_exit() {
	local status=$? client
	for client in "${!client_pid[@]}"; do
		kill "${client_pid[$client]}" 2>/dev/null || true
	done
	if [[ $status -ne 0 ]]; then
		print_client_output
	fi
	rm -rf -- "$work_dir"
	exit "$status"
}
trap on_exit EXIT

# shellcheck source=dev/harness-lib.sh
source "$repo_dir/dev/harness-lib.sh"

lines() {
	wc -l <"$work_dir/$1.out"
}

# expect_event CLIENT REGEX START WHY: waits for a matching line after START and prints it;
# the line is in last_event.
expect_event() {
	local client=$1 pattern=$2 start=$3 why=$4 line
	line=$(wait_for_match "$client" "$pattern" "$start") || fail "$why"
	echo "    $client< $line"
	last_event=$line
}

# expect_refusal CLIENT MESSAGE START WHY: a protocol_error with exactly MESSAGE (taken
# literally: the refusals name their message in parentheses).
expect_refusal() {
	local client=$1 message=$2 start=$3 why=$4
	message=$(sed 's/[][\.*^$()+?{}|]/\\&/g' <<<"$message")
	expect_event "$client" \
		"^\\{\"event\":\"protocol_error\",\"serverID\":1,\"message\":\"$message\"\\}$" \
		"$start" "$why"
}

# json_field LINE KEY: a string or number field of a JSON line.
json_field() {
	local line=$1 key=$2
	sed -nE "s/.*\"$key\":(\"([^\"]*)\"|([-0-9.e+]+)).*/\2\3/p" <<<"$line"
}

run_sql() {
	command -v psql >/dev/null 2>&1 || fail "the edit proof needs psql on PATH"
	PGPASSWORD="${HAYCHAT_DATABASE_PASS:-haychat}" psql -q -X -t -A -v ON_ERROR_STOP=1 \
		-h "${HAYCHAT_DATABASE_URL:-localhost}" -p "${HAYCHAT_DATABASE_PORT:-5432}" \
		-U "${HAYCHAT_DATABASE_USER:-haychat}" -d "${HAYCHAT_DATABASE_NAME:-haychat}" \
		-c "$1" || fail "SQL failed: $1"
}

# user_id CLIENT NICKNAME: the account's ID from the client's users.
user_id() {
	local client=$1 nickname=$2
	expect_ok "$client" users >&2
	[[ "$last_result" =~ \{\"id\":([0-9]+),\"nickname\":\"$nickname\", ]] ||
		fail "client $client's users do not list $nickname"
	printf '%s\n' "${BASH_REMATCH[1]}"
}

# pin_keys CLIENT USER_ID...: the client fetches and pins each account's keys.
pin_keys() {
	local client=$1 user start
	shift
	for user in "$@"; do
		start=$(lines "$client")
		expect_ok "$client" user-keys "$user"
		expect_event "$client" "^\\{\"event\":\"user_keys\",.*\"userID\":$user," "$start" \
			"client $client got no user_keys for user $user"
	done
}

# room_message CLIENT ROOM TEXT START: the room_chat for TEXT; its ID in message_id.
room_message() {
	local client=$1 room=$2 text=$3 start=$4
	expect_event "$client" \
		"^\\{\"event\":\"room_chat\",.*\"roomID\":$room,.*\"content\":\"$text\"\\}$" \
		"$start" "client $client did not see \"$text\""
	message_id=$(json_field "$last_event" messageID)
}

# expect_edited CLIENT KIND CONVERSATION MESSAGE TEXT START: message_edited, verified, TEXT.
expect_edited() {
	local client=$1 kind=$2 conversation=$3 message=$4 text=$5 start=$6 pattern
	pattern="^\\{\"event\":\"message_edited\",\"serverID\":1,\"kind\":\"$kind\","
	pattern+="\"conversationID\":$conversation,\"messageID\":$message,.*\"found\":true,"
	pattern+=".*\"editStatus\":\"verified\",\"content\":\"$text\"\\}$"
	expect_event "$client" "$pattern" "$start" \
		"client $client did not see message $message edited to \"$text\""
}

# expect_deleted CLIENT KIND CONVERSATION MESSAGE BY_SERVER START: message_deleted.
expect_deleted() {
	local client=$1 kind=$2 conversation=$3 message=$4 byServer=$5 start=$6 pattern
	pattern="^\\{\"event\":\"message_deleted\",\"serverID\":1,\"kind\":\"$kind\","
	pattern+="\"conversationID\":$conversation,\"messageID\":$message,.*\"found\":true,"
	pattern+="\"deleted\":true,\"removedByServer\":$byServer\\}$"
	expect_event "$client" "$pattern" "$start" \
		"client $client did not see message $message deleted (removedByServer $byServer)"
}

cd "$repo_dir"
echo "==> [edits] building the client"
odin build client -out:"$client_bin"

nickname_a="edit-a-$run_tag"
nickname_b="edit-b-$run_tag"
nickname_c="edit-c-$run_tag"

echo "==> [edits] A becomes an admin; B and C sign in and pin each other's keys"
start_client a "$nickname_a"
expect_connected a
make_admin "$nickname_a"
expect_ok a wait connected 0
expect_ok a reconnect
expect_ok a wait connected 8000
expect_ok a status
[[ "$last_result" == *'"isAdmin":true,'* ]] || fail "client a is not an admin after reconnecting"
start_client b "$nickname_b"
expect_connected b
expect_ok b wait room_list 5000
start_client c "$nickname_c"
expect_connected c
expect_ok c wait room_list 5000
expect_event a "^\\{\"event\":\"presence\",.*\"nickname\":\"$nickname_c\",\"isOnline\":true\\}$" \
	0 "client a never saw $nickname_c come online"
user_a=$(user_id a "$nickname_a")
user_b=$(user_id a "$nickname_b")
user_c=$(user_id a "$nickname_c")
pin_keys a "$user_b" "$user_c"
pin_keys b "$user_a" "$user_c"
pin_keys c "$user_a" "$user_b"

echo "==> [edits] 1. room edit: A edits its message; B sees it and its history"
astart=$(lines a)
bstart=$(lines b)
expect_ok a send 1 "first from a $run_tag"
room_message b 1 "first from a $run_tag" "$bstart"
first=$message_id
expect_event a "^\\{\"event\":\"room_chat\",.*\"messageID\":$first," "$astart" \
	"client a did not see its own message $first"
astart=$(lines a)
bstart=$(lines b)
expect_ok a msg-edit 1 "$first" "first from a, edited $run_tag"
expect_edited a room 1 "$first" "first from a, edited $run_tag" "$astart"
expect_edited b room 1 "$first" "first from a, edited $run_tag" "$bstart"
[[ "$last_event" == *'"editCount":1,'* ]] || fail "client b's edit count is not 1: $last_event"
bstart=$(lines b)
expect_ok b msg-edits room 1 "$first"
edits_pattern="^\\{\"event\":\"message_edits\",\"serverID\":1,\"kind\":\"room\",\"conversationID\":1,"
edits_pattern+="\"messageID\":$first,\"found\":true,\"edits\":\\[\\{\"id\":[0-9]+,\"timestamp\":\"[^\"]+\","
edits_pattern+="\"status\":\"verified\",\"content\":\"first from a, edited $run_tag\"\\}\\]\\}$"
expect_event b "$edits_pattern" "$bstart" "client b did not fetch the edit history"
bstart=$(lines b)
expect_ok b history 1
expect_event b "^\\{\"event\":\"room_history\",\"serverID\":1,\"roomID\":1," "$bstart" \
	"client b got no history of #general"
history_entry="\"id\":$first,\"senderID\":$user_a,\"senderNickname\":\"$nickname_a\","
history_entry+="\"timestamp\":\"[^\"]+\",\"editCount\":1,\"edited\":true,"
history_entry+="\"editStatus\":\"verified\",\"deleted\":false,\"removedByServer\":false,"
[[ "$last_event" =~ $history_entry ]] || fail "client b's history does not carry the edit"
[[ "$last_event" == *"\"content\":\"first from a, edited $run_tag\""* ]] ||
	fail "client b's history does not show the latest version"
echo "==> [edits] room edit passed"

echo "==> [edits] 2. refusals: someone else's message, a forged edit, an admin delete by B"
bstart=$(lines b)
expect_ok b msg-edit 1 "$first" --unchecked "hijacked $run_tag"
expect_refusal b "You can only edit or delete your own messages (message $first)" "$bstart" \
	"client b's edit of a's message was not refused"
bstart=$(lines b)
expect_ok b msg-delete 1 "$first" unchecked
expect_refusal b "You can only edit or delete your own messages (message $first)" "$bstart" \
	"client b's delete of a's message was not refused"
bstart=$(lines b)
expect_ok b msg-delete 1 "$first" admin
expect_refusal b "Admin permission required (message $first)" "$bstart" \
	"client b's admin delete was not refused"
astart=$(lines a)
expect_ok a msg-edit 1 "$first" --forge "forged $run_tag"
expect_refusal a "Invalid message edit signature (message $first)" "$astart" \
	"client a's forged edit was not refused"
if grep -F '"event":"message_edited"' "$work_dir/b.out" | grep -qF -- "hijacked $run_tag"; then
	fail "a refused edit reached a client"
fi
echo "==> [edits] refusals passed"

echo "==> [edits] 3. room delete: A's signed delete, then A's admin delete of B's message"
bstart=$(lines b)
expect_ok a msg-delete 1 "$first"
expect_deleted b room 1 "$first" false "$bstart"
bstart=$(lines b)
expect_ok b history 1
expect_event b "^\\{\"event\":\"room_history\",\"serverID\":1,\"roomID\":1," "$bstart" \
	"client b got no history of #general"
tombstone="\"id\":$first,[^}]*\"editCount\":0,\"edited\":false,\"editStatus\":\"none\","
tombstone+="\"deleted\":true,\"removedByServer\":false,"
[[ "$last_event" =~ $tombstone ]] || fail "client b's history does not show the tombstone"
if [[ "$last_event" == *"first from a"* ]]; then
	fail "client b's history still shows the deleted text"
fi
astart=$(lines a)
bstart=$(lines b)
expect_ok b send 1 "from b $run_tag"
room_message a 1 "from b $run_tag" "$astart"
from_b=$message_id
room_message b 1 "from b $run_tag" "$bstart"
astart=$(lines a)
bstart=$(lines b)
expect_ok a msg-delete 1 "$from_b" admin
expect_deleted a room 1 "$from_b" true "$astart"
expect_deleted b room 1 "$from_b" true "$bstart"
echo "==> [edits] room delete passed"

echo "==> [edits] 4. direct messages: a plaintext DM edited and deleted, an encrypted one deleted"
# B's encryption key goes, so A's DM to B is the signed plaintext fallback (protocol 17).
for ((attempt = 0; attempt < 50; attempt++)); do
	[[ $(run_sql "SELECT count(*) FROM user_encryption_keys WHERE user_id = $user_b") == 1 ]] &&
		break
	sleep 0.1
done
run_sql "DELETE FROM user_encryption_keys WHERE user_id = $user_b" >/dev/null
pin_keys a "$user_b"
astart=$(lines a)
bstart=$(lines b)
expect_ok a dm-plain "$user_b" "dm from a $run_tag"
expect_event b "^\\{\"event\":\"direct_message\",.*\"protection\":\"signed\",\"content\":\"dm from a $run_tag\"\\}$" \
	"$bstart" "client b did not get a's signed DM"
dm_plain=$(json_field "$last_event" id)
expect_event a "^\\{\"event\":\"direct_message\",\"serverID\":1,\"id\":$dm_plain," "$astart" \
	"client a did not see its own DM"
astart=$(lines a)
bstart=$(lines b)
expect_ok a dm-edit "$user_b" "$dm_plain" "dm from a, edited $run_tag"
expect_edited b dm "$user_a" "$dm_plain" "dm from a, edited $run_tag" "$bstart"
expect_edited a dm "$user_b" "$dm_plain" "dm from a, edited $run_tag" "$astart"
bstart=$(lines b)
expect_ok b msg-edits dm "$user_a" "$dm_plain"
expect_event b "^\\{\"event\":\"message_edits\",\"serverID\":1,\"kind\":\"dm\",\"conversationID\":$user_a,\"messageID\":$dm_plain,\"found\":true,\"edits\":\\[\\{.*\"status\":\"verified\",\"content\":\"dm from a, edited $run_tag\"\\}\\]\\}$" \
	"$bstart" "client b did not fetch the DM's edit history"
bstart=$(lines b)
expect_ok b dm-edit "$user_a" "$dm_plain" --unchecked "not b's $run_tag"
expect_refusal b "You can only edit or delete your own messages (message $dm_plain)" "$bstart" \
	"client b's edit of a's DM was not refused"
bstart=$(lines b)
expect_ok b dm-delete "$user_a" "$dm_plain" unchecked
expect_refusal b "You can only edit or delete your own messages (message $dm_plain)" "$bstart" \
	"client b's delete of a's DM was not refused"
bstart=$(lines b)
expect_ok a dm-delete "$user_b" "$dm_plain"
expect_deleted b dm "$user_a" "$dm_plain" false "$bstart"
# An encrypted DM to C: deleting it is signed and works; editing it is M2.
cstart=$(lines c)
expect_ok a dm "$user_c" "secret for c $run_tag"
expect_event c "^\\{\"event\":\"direct_message\",.*\"protection\":\"encrypted\",\"content\":\"secret for c $run_tag\"\\}$" \
	"$cstart" "client c did not get a's encrypted DM"
dm_sealed=$(json_field "$last_event" id)
reply=$(client_command a dm-edit "$user_c" "$dm_sealed" "sealed edit") ||
	fail "no answer to a's sealed dm-edit"
[[ "$reply" == '{"ok":false,'*'Editing encrypted messages is not available yet'* ]] ||
	fail "a's edit of an encrypted DM was not refused locally: $reply"
cstart=$(lines c)
expect_ok a dm-delete "$user_c" "$dm_sealed"
expect_deleted c dm "$user_a" "$dm_sealed" false "$cstart"
echo "==> [edits] direct messages passed"

echo "==> [edits] 5. from join: C hears only of edits of messages it may read"
start=$(lines a)
expect_ok a room-create both,member-invite,from-join "edit-join-$run_tag" "edit proof"
expect_event a "^\\{\"event\":\"room_created\",.*\"name\":\"edit-join-$run_tag\"," "$start" \
	"client a did not receive room_created"
join_room=$(json_field "$last_event" roomID)
bstart=$(lines b)
expect_ok a room-add "$join_room" "$user_b"
expect_event b "^\\{\"event\":\"room_membership\",\"serverID\":1,\"roomID\":$join_room,\"joined\":true," \
	"$bstart" "client b was not added to the From join room"
astart=$(lines a)
bstart=$(lines b)
expect_ok a send "$join_room" "before c $run_tag"
room_message b "$join_room" "before c $run_tag" "$bstart"
early=$message_id
room_message a "$join_room" "before c $run_tag" "$astart"
cstart=$(lines c)
expect_ok a room-add "$join_room" "$user_c"
expect_event c "^\\{\"event\":\"room_membership\",\"serverID\":1,\"roomID\":$join_room,\"joined\":true," \
	"$cstart" "client c was not added to the From join room"
cstart=$(lines c)
expect_ok a send "$join_room" "after c $run_tag"
room_message c "$join_room" "after c $run_tag" "$cstart"
late=$message_id
bstart=$(lines b)
cstart=$(lines c)
expect_ok a msg-edit "$join_room" "$early" "before c, edited $run_tag"
expect_edited b room "$join_room" "$early" "before c, edited $run_tag" "$bstart"
expect_ok a msg-edit "$join_room" "$late" "after c, edited $run_tag"
expect_edited c room "$join_room" "$late" "after c, edited $run_tag" "$cstart"
if tail -n "+$((cstart + 1))" "$work_dir/c.out" | grep -F '"event":"message_edited"' |
	grep -qF "\"messageID\":$early,"; then
	fail "client c heard of an edit of a message from before it joined"
fi
cstart=$(lines c)
expect_ok c msg-edits room "$join_room" "$early"
expect_refusal c "Message not found (message $early)" "$cstart" \
	"client c was not refused the early message's edit history"
echo "==> [edits] from join passed"

echo "==> [edits] 6. files: deleting a message removes its file"
file="$work_dir/edit-proof.txt"
printf 'edit proof %s: a file on a message that goes\n' "$run_tag" >"$file"
astart=$(lines a)
expect_ok a attach-upload 1 "$file"
expect_event a "\"event\":\"attachment_done\"," "$astart" "client a's upload did not finish"
blob=$(json_field "$last_event" blobID)
bstart=$(lines b)
expect_ok a send 1 --attach "$blob" "a file to delete $run_tag"
room_message b 1 "a file to delete $run_tag" "$bstart"
with_file=$message_id
bstart=$(lines b)
expect_ok b attach-download 1 "$with_file" 0 "$work_dir/before.txt"
expect_event b "\"event\":\"attachment_done\"," "$bstart" "client b could not download the file"
bstart=$(lines b)
expect_ok a msg-delete 1 "$with_file"
expect_event b "^\\{\"event\":\"attachment_removed\",\"serverID\":1,\"blobID\":\"$blob\",.*\"chatMessageID\":$with_file," \
	"$bstart" "client b did not hear the file was removed"
expect_deleted b room 1 "$with_file" false "$bstart"
bstart=$(lines b)
expect_ok b attach-download "$blob" "$work_dir/after.txt"
expect_event b '"event":"attachment_error".*"direction":"download"' "$bstart" \
	"client b's download of a deleted message's file was not refused"
[[ ! -e "$work_dir/after.txt" ]] || fail "client b saved a deleted message's file"
echo "==> [edits] files passed"

stop_client a
stop_client b
stop_client c
echo "==> [edits] all steps passed"
