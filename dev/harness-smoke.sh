#!/usr/bin/env bash
set -euo pipefail

# Smoke test for the headless client harness (docs/testing-harness.md). It builds the client,
# starts headless clients against a running server, and drives them over named pipes the way
# an agent would.
#
#   1. single client: connect, `status`, `wait room_list`, `rooms`, then `reconnect` and wait
#      for the worker to connect again
#   2. two clients:   A sends to room 1 and B must print the matching room_chat event
#   3. direct message: A sees B come online (presence), finds B's ID with `users`, and sends
#      it a direct message; B must print the matching direct_message event, and B's
#      `dm-history` with A must contain it
#   4. rename:         B quits and comes back from the same profile (the same identity key)
#      under a new name; A must see the same user ID come online with the new nickname, and
#      A's `users` must list it under that name
#   5. room admin:     A is made an admin with deploy/sql/make-admin.sql (psql), reconnects
#      and must report isAdmin; A creates a room, B must see room_membership and list it in
#      `rooms`, and B sends to it; A renames it and B must see room_edited; A deletes it and B
#      must see room_deleted and fall back to #general
#   6. read state:     D signs up and goes offline; C sends two messages to room 1 and a direct
#      message to D. D comes back and `rooms` shows 2 unread in room 1, `conversations` 1 from
#      C. A second session of D (the same profile) is connected when D runs `read`; it must
#      receive both read_marker events and then list 0, and a third session started afterwards
#      must list 0 from the server
#
# dev/live-proof.sh --harness runs it against its throwaway server. It needs bash, coreutils,
# and psql (for step 5, which reaches the server's database through the HAYCHAT_DATABASE_*
# variables dev/live-proof.sh runs under); JSON lines are matched as text because the harness
# prints compact JSON with a fixed key order.
#
# Usage: dev/harness-smoke.sh [HOST:PORT]   (default 127.0.0.1:12345)

repo_dir=$(cd -- "$(dirname -- "$0")/.." >/dev/null 2>&1 && pwd)
server_address=${1:-127.0.0.1:12345}
room_id=1
command_timeout_secs=10

work_dir=$(mktemp -d -t haychat-harness.XXXXXX)
client_bin="$work_dir/haychat-client"
run_tag=$(date +%s%N)

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

cd "$repo_dir"
echo "==> [harness] building the client"
odin build client -out:"$client_bin"

echo "==> [harness] single client: connect, status, rooms"
start_client a "harness-a-$run_tag"
expect_connected a
expect_ok a status
[[ "$last_result" == *'"connected":true'* ]] || fail "client a status is not connected"
expect_ok a wait room_list 5000
expect_ok a rooms
[[ "$last_result" == *'"loaded":true'* ]] || fail "client a rooms are not loaded"
# The first `connected` is still counted for `wait`; take it so the next wait needs a new one.
expect_ok a wait connected 0
expect_ok a reconnect
expect_ok a wait connected 8000
expect_ok a status
[[ "$last_result" == *'"connected":true'* ]] || fail "client a is not connected after reconnect"
echo "==> [harness] single client passed"

# Needs every user to be a member of room 1. On main before the open-rooms change (work
# package A), new users join no rooms, so the server rejects A's message and B sees nothing.
echo "==> [harness] two clients: A sends to room $room_id, B receives it"
start_client b "harness-b-$run_tag"
expect_connected b
expect_ok b wait room_list 5000
message="harness smoke $run_tag"
expect_ok a send "$room_id" "$message"
if ! received=$(client_command b wait room_chat 5000) ||
	[[ "$received" != '{"ok":true,'* ]]; then
	fail "[two-client] client b did not receive a room_chat event within 5 s" \
		"(${received:-no result}); both clients must be members of room $room_id" \
		"(rooms are open, so check that the #general fixture was loaded before they connected)"
fi
chat_line=$(wait_for_line b "\"content\":\"$message\"" 0) ||
	fail "[two-client] client b received a room_chat event without the sent text"
echo "    b< $chat_line"
echo "==> [harness] two clients passed"

echo "==> [harness] direct message: A finds B with \`users\`, B receives A's message"
nickname_b="harness-b-$run_tag"
# B's first session signing in is announced to every other session, so A hears of it.
presence_line=$(wait_for_match a \
	"^\\{\"event\":\"presence\",.*\"nickname\":\"$nickname_b\",\"isOnline\":true\\}$") ||
	fail "[dm] client a did not receive a presence event for $nickname_b"
echo "    a< $presence_line"
expect_ok a users
[[ "$last_result" =~ \{\"id\":([0-9]+),\"nickname\":\"$nickname_b\",\"isOnline\":true, ]] ||
	fail "[dm] client a's users do not list $nickname_b as online"
user_b=${BASH_REMATCH[1]}
dm_message="harness dm $run_tag"
expect_ok a dm "$user_b" "$dm_message"
if ! received=$(client_command b wait direct_message 5000) ||
	[[ "$received" != '{"ok":true,'* ]]; then
	fail "[dm] client b did not receive a direct_message event within 5 s (${received:-no result})"
fi
dm_line=$(wait_for_match b \
	"^\\{\"event\":\"direct_message\",.*\"content\":\"$dm_message\"\\}$") ||
	fail "[dm] client b received a direct_message event without the sent text"
echo "    b< $dm_line"
[[ "$dm_line" =~ \"senderID\":([0-9]+), ]] || fail "[dm] the direct_message has no senderID"
user_a=${BASH_REMATCH[1]}
[[ "$dm_line" == *"\"recipientID\":$user_b,"* ]] ||
	fail "[dm] the direct_message is not addressed to user $user_b"
history_start=$(wc -l <"$work_dir/b.out")
expect_ok b dm-history "$user_a"
history_line=$(wait_for_match b "^\\{\"event\":\"direct_history\",.*\"peerUserID\":$user_a," \
	"$history_start") || fail "[dm] client b did not receive a direct_history page"
[[ "$history_line" == *"\"content\":\"$dm_message\""* ]] ||
	fail "[dm] client b's history with user $user_a does not contain the message: $history_line"
echo "    b< $history_line"
echo "==> [harness] direct message passed"

# The identity is the key, so the same profile under a new name renames user B rather than
# creating an account or being refused as a taken name.
echo "==> [harness] rename: B returns from the same profile under a new name"
renamed_b="harness-r-$run_tag"
rename_start=$(wc -l <"$work_dir/a.out")
stop_client b
start_client b2 "$renamed_b" b
expect_connected b2
rename_pattern="^\\{\"event\":\"presence\",.*\"userID\":$user_b,"
rename_pattern+="\"nickname\":\"$renamed_b\",\"isOnline\":true\\}$"
rename_line=$(wait_for_match a "$rename_pattern" "$rename_start") ||
	fail "[rename] client a did not see user $user_b come back as $renamed_b"
echo "    a< $rename_line"
expect_ok a users
[[ "$last_result" == *"{\"id\":$user_b,\"nickname\":\"$renamed_b\",\"isOnline\":true,"* ]] ||
	fail "[rename] client a's users do not list user $user_b as $renamed_b"
echo "==> [harness] rename passed"

# The admin role lives in the database; a session learns it at sign-in, so A reconnects.
echo "==> [harness] room admin: A becomes an admin, creates, renames, and deletes a room"
nickname_a="harness-a-$run_tag"
expect_ok a status
[[ "$last_result" == *'"isAdmin":false,'* ]] || fail "[admin] client a is an admin already"
make_admin "$nickname_a"
expect_ok a reconnect
expect_ok a wait connected 8000
expect_ok a status
[[ "$last_result" == *'"isAdmin":true,'* ]] ||
	fail "[admin] client a does not report isAdmin after reconnecting"

room_name="harness-room-$run_tag"
renamed_room="harness-renamed-$run_tag"
admin_start_a=$(wc -l <"$work_dir/a.out")
admin_start_b=$(wc -l <"$work_dir/b2.out")
expect_ok a room-create "$room_name" "made by the harness"
created_line=$(wait_for_match a \
	"^\\{\"event\":\"room_created\",.*\"name\":\"$room_name\"," "$admin_start_a") ||
	fail "[admin] client a did not receive room_created for $room_name"
echo "    a< $created_line"
[[ "$created_line" =~ \"roomID\":([0-9]+), ]] || fail "[admin] room_created has no roomID"
new_room=${BASH_REMATCH[1]}
membership_line=$(wait_for_line b2 \
	"{\"event\":\"room_membership\",\"serverID\":1,\"roomID\":$new_room,\"joined\":true}" \
	"$admin_start_b") || fail "[admin] client b did not receive room_membership for $new_room"
echo "    b< $membership_line"
wait_for_match b2 "^\\{\"event\":\"room_list\",.*\"name\":\"$room_name\"" \
	"$admin_start_b" >/dev/null || fail "[admin] client b's room list never listed $room_name"
expect_ok b2 rooms
[[ "$last_result" == *"{\"id\":$new_room,\"name\":\"$room_name\","* ]] ||
	fail "[admin] client b's rooms do not list $room_name"
# Sending selects the room on B, so the delete below has to move B back to #general.
expect_ok b2 send "$new_room" "hello new room $run_tag"
wait_for_line a "\"content\":\"hello new room $run_tag\"" "$admin_start_a" >/dev/null ||
	fail "[admin] client a did not receive B's message in the new room"

expect_ok a room-edit "$new_room" "$renamed_room" "renamed by the harness"
edited_line=$(wait_for_match b2 \
	"^\\{\"event\":\"room_edited\",.*\"roomID\":$new_room,\"name\":\"$renamed_room\"," \
	"$admin_start_b") || fail "[admin] client b did not receive room_edited for $new_room"
echo "    b< $edited_line"

expect_ok a room-delete "$new_room"
deleted_line=$(wait_for_line b2 \
	"{\"event\":\"room_deleted\",\"serverID\":1,\"roomID\":$new_room}" "$admin_start_b") ||
	fail "[admin] client b did not receive room_deleted for $new_room"
echo "    b< $deleted_line"
expect_ok b2 status
[[ "$last_result" == *'"selectedRoomID":1,'* ]] ||
	fail "[admin] client b did not fall back to #general after the delete"
echo "==> [harness] room admin passed"

# Counts are matched exactly, so the readers are fresh accounts: nobody else writes to room 1
# or to them while this runs, and a new account has nothing unread from before it joined.
echo "==> [harness] read state: badges survive a reconnect and clear on a second session"
nickname_c="harness-c-$run_tag"
nickname_d="harness-d-$run_tag"
start_client d "$nickname_d"
expect_connected d
expect_ok d wait room_list 5000
stop_client d

start_client c "$nickname_c"
expect_connected c
connected_c=$(wait_for_line c '{"event":"connected",' 0) || fail "[read] client c never connected"
[[ "$connected_c" =~ \"userID\":([0-9]+), ]] || fail "[read] client c's connected line lacks userID"
user_c=${BASH_REMATCH[1]}
expect_ok c wait user_list 5000
expect_ok c users
[[ "$last_result" =~ \{\"id\":([0-9]+),\"nickname\":\"$nickname_d\",\"isOnline\":false, ]] ||
	fail "[read] client c's users do not list $nickname_d as offline"
user_d=${BASH_REMATCH[1]}
for text in "read one $run_tag" "read two $run_tag"; do
	expect_ok c send "$room_id" "$text"
	# The sender's own copy means the server stored it.
	wait_for_line c "\"content\":\"$text\"" 0 >/dev/null ||
		fail "[read] client c never saw its room message stored"
done
expect_ok c dm "$user_d" "read dm $run_tag"
wait_for_match c "^\\{\"event\":\"direct_message\",.*\"content\":\"read dm $run_tag\"\\}$" \
	>/dev/null || fail "[read] client c never saw its direct message stored"

# room_list and conversations arrive by themselves after connecting; their counts come from
# the server's read markers (D has none yet, so its join time decides for the room).
room_unread_pattern="\\{\"id\":$room_id,\"name\":\"[^\"]*\",\"description\":\"[^\"]*\","
room_unread_pattern+="\"lastReadMessageId\":[0-9]+,\"unreadCount\":"
dm_unread_pattern="\\{\"peerUserID\":$user_c,[^}]*\"unreadCount\":"
expect_room_unread() {
	local client=$1 expected=$2 why=$3
	expect_ok "$client" rooms
	[[ "$last_result" =~ ${room_unread_pattern}${expected}\} ]] ||
		fail "[read] client $client: expected $expected unread in room $room_id $why"
}
expect_dm_unread() {
	local client=$1 expected=$2 why=$3
	expect_ok "$client" conversations
	[[ "$last_result" =~ ${dm_unread_pattern}${expected}\} ]] ||
		fail "[read] client $client: expected $expected unread from user $user_c $why"
}
start_client d1 "$nickname_d" d
expect_connected d1
expect_ok d1 wait room_list 5000
expect_ok d1 wait conversations 5000
expect_room_unread d1 2 "after reconnecting"
expect_dm_unread d1 1 "after reconnecting"

start_client d2 "$nickname_d" d
expect_connected d2
expect_ok d2 wait room_list 5000
expect_ok d2 wait conversations 5000
expect_room_unread d2 2 "on a second session"
# The reader loads what it reads; without MESSAGE_ID, `read` marks the newest loaded message.
expect_ok d1 history "$room_id"
expect_ok d1 wait room_history 5000
expect_ok d1 dm-history "$user_c"
expect_ok d1 wait direct_history 5000
marker_start=$(wc -l <"$work_dir/d2.out")
expect_ok d1 read room "$room_id"
expect_ok d1 read dm "$user_c"
for target in "room\",\"conversationID\":$room_id," "dm\",\"conversationID\":$user_c,"; do
	marker_pattern="^\\{\"event\":\"read_marker\",\"serverID\":1,\"kind\":\"$target"
	marker_pattern+="\"lastReadMessageId\":[0-9]+,\"unreadCount\":0\\}$"
	marker_line=$(wait_for_match d2 "$marker_pattern" "$marker_start") ||
		fail "[read] the second session did not receive a read_marker ($target)"
	echo "    d2< $marker_line"
	wait_for_match d1 "$marker_pattern" 0 >/dev/null ||
		fail "[read] the session that read did not receive its own read_marker ($target)"
done
expect_room_unread d2 0 "after the other session read it"
expect_dm_unread d2 0 "after the other session read it"

# The cleared state is the server's, so a session started afterwards lists it too.
start_client d3 "$nickname_d" d
expect_connected d3
expect_ok d3 wait room_list 5000
expect_ok d3 wait conversations 5000
expect_room_unread d3 0 "on a new session after the read"
expect_dm_unread d3 0 "on a new session after the read"
stop_client c
stop_client d1
stop_client d2
stop_client d3
echo "==> [harness] read state passed"

stop_client a
stop_client b2
echo "==> [harness] passed"
