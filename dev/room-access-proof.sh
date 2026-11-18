#!/usr/bin/env bash
set -euo pipefail

# Live proof of room access modes (protocol 15) with three headless clients
# (docs/testing-harness.md) against a running server: admin A, and B and C.
#
#   1. admin invite: A creates an Admin invite room and adds B. B lists it with access 3; C,
#                    not a member, does not list it and is refused its history and its member
#                    list ("Not a room member"); B's add of C is refused ("Admin permission
#                    required").
#   2. from join:    A posts in a Member invite room with From join history, adds B, and B
#                    (a member) invites C. B posts; C's history has B's message but not A's
#                    earlier one. B cannot remove C (only admins remove).
#   3. full history: A posts in a Member invite room with Full history and adds C, who reads
#                    A's earlier message.
#   4. leave:        B leaves the Admin invite room and no longer lists it; C cannot leave
#                    #general, a Public room.
#   5. remove:       A removes C from the From join room; C is told and refused its history.
#   6. no join:      A creates an Admin invite room without joining it: A's room list does not
#                    have it, the Admin list (admin-rooms) does, with no members. A adds B and
#                    fetches its members; B posts, and A is refused its history. A makes it
#                    Public, which adds every account (C hears it joined), and deletes it.
#
# dev/live-proof.sh --access (and --all) runs it against its throwaway server. It needs bash,
# coreutils and psql (for make-admin.sql through the HAYCHAT_DATABASE_* variables).
#
# Usage: dev/room-access-proof.sh [HOST:PORT]   (default 127.0.0.1:12345)

repo_dir=$(cd -- "$(dirname -- "$0")/.." >/dev/null 2>&1 && pwd)
server_address=${1:-127.0.0.1:12345}
command_timeout_secs=10
smoke_label=access

work_dir=$(mktemp -d -t haychat-access.XXXXXX)
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

# lines CLIENT: how many lines the client has printed, for waits that must see a new line.
lines() {
	wc -l <"$work_dir/$1.out"
}

# expect_event CLIENT REGEX START WHY: waits for a matching line after START and prints it.
expect_event() {
	local client=$1 pattern=$2 start=$3 why=$4 line
	line=$(wait_for_match "$client" "$pattern" "$start") || fail "$why"
	echo "    $client< $line"
	last_event=$line
}

# expect_refusal CLIENT MESSAGE START WHY: waits for a protocol_error with exactly MESSAGE.
expect_refusal() {
	local client=$1 message=$2 start=$3 why=$4
	expect_event "$client" \
		"^\\{\"event\":\"protocol_error\",\"serverID\":1,\"message\":\"$message\"\\}$" \
		"$start" "$why"
}

# expect_membership CLIENT ROOM JOINED USER START WHY: room_membership for USER in ROOM.
expect_membership() {
	local client=$1 room=$2 joined=$3 user=$4 start=$5 why=$6 pattern
	pattern="^\\{\"event\":\"room_membership\",\"serverID\":1,\"roomID\":$room,"
	pattern+="\"joined\":$joined,\"userID\":$user\\}$"
	expect_event "$client" "$pattern" "$start" "$why"
}

# expect_member_result CLIENT ROOM USER ADDED START WHY: an applied room-add or room-remove.
expect_member_result() {
	local client=$1 room=$2 user=$3 added=$4 start=$5 why=$6 pattern
	pattern="^\\{\"event\":\"room_member_result\",\"serverID\":1,\"roomID\":$room,"
	pattern+="\"userID\":$user,\"added\":$added,\"changed\":true\\}$"
	expect_event "$client" "$pattern" "$start" "$why"
}

# expect_chat CLIENT ROOM TEXT START WHY: a room_chat in ROOM with TEXT.
expect_chat() {
	local client=$1 room=$2 text=$3 start=$4 why=$5
	expect_event "$client" \
		"^\\{\"event\":\"room_chat\",.*\"roomID\":$room,.*\"content\":\"$text\"\\}$" \
		"$start" "$why"
}

# create_room CLIENT OPTIONS NAME: room-create, and the new room's ID in created_room.
create_room() {
	local client=$1 options=$2 name=$3 start
	start=$(lines "$client")
	expect_ok "$client" room-create "$options" "$name" "access proof"
	expect_event "$client" "^\\{\"event\":\"room_created\",.*\"name\":\"$name\"," "$start" \
		"client $client did not receive room_created for $name"
	[[ "$last_event" =~ \"roomID\":([0-9]+), ]] || fail "room_created has no roomID"
	created_room=${BASH_REMATCH[1]}
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

# history_of CLIENT ROOM: the client's room_history line for ROOM in history_line.
history_of() {
	local client=$1 room=$2 start
	start=$(lines "$client")
	expect_ok "$client" history "$room"
	expect_event "$client" "^\\{\"event\":\"room_history\",\"serverID\":1,\"roomID\":$room," \
		"$start" "client $client got no history of room $room"
	history_line=$last_event
}

cd "$repo_dir"
echo "==> [access] building the client"
odin build client -out:"$client_bin"

nickname_a="acc-a-$run_tag"
nickname_b="acc-b-$run_tag"
nickname_c="acc-c-$run_tag"

echo "==> [access] A becomes an admin; B and C sign in"
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
expect_ok a users
[[ "$last_result" =~ \{\"id\":([0-9]+),\"nickname\":\"$nickname_b\", ]] ||
	fail "client a's users do not list $nickname_b"
user_b=${BASH_REMATCH[1]}
[[ "$last_result" =~ \{\"id\":([0-9]+),\"nickname\":\"$nickname_c\", ]] ||
	fail "client a's users do not list $nickname_c"
user_c=${BASH_REMATCH[1]}
[[ "$last_result" =~ \{\"id\":([0-9]+),\"nickname\":\"$nickname_a\", ]] ||
	fail "client a's users do not list $nickname_a"
user_a=${BASH_REMATCH[1]}
# Every room message is signed by its sender (protocol 22), and a client shows one only once it
# checked the signature against the sender's pinned key. B and C pin the others' keys now, so
# the history pages below open at once instead of waiting for a key fetch.
pin_keys b "$user_a" "$user_c"
pin_keys c "$user_a" "$user_b"

echo "==> [access] admin invite: A adds B; C cannot see the room, its history, or its members"
create_room a both,admin-invite "acc-admin-$run_tag"
admin_room=$created_room
created_tail='"access":3,"historyVisibility":1,"isMember":true,"encrypted":false,'
created_tail+='"logVersion":0,"myPermissions":'
[[ "$last_event" == *"$created_tail"* ]] ||
	fail "the Admin invite room was not created as asked: $last_event"
start_a=$(lines a)
start_b=$(lines b)
expect_ok a room-add "$admin_room" "$user_b"
expect_member_result a "$admin_room" "$user_b" true "$start_a" \
	"client a got no room_member_result for adding b"
expect_membership b "$admin_room" true "$user_b" "$start_b" \
	"client b was not told it joined the Admin invite room"
expect_event b "^\\{\"event\":\"room_list\",.*\"id\":$admin_room,[^}]*\"access\":3," "$start_b" \
	"client b's room list does not have the Admin invite room"
expect_ok c rooms
[[ "$last_result" != *"\"id\":$admin_room,"* ]] ||
	fail "client c lists the Admin invite room it is not in: $last_result"
start_c=$(lines c)
expect_ok c history "$admin_room"
expect_refusal c "Not a room member" "$start_c" "client c was not refused the room's history"
start_c=$(lines c)
expect_ok c room-members "$admin_room"
expect_refusal c "Not a room member" "$start_c" "client c was not refused the room's members"
start_b=$(lines b)
expect_ok b room-add "$admin_room" "$user_c"
expect_refusal b "Admin permission required" "$start_b" \
	"client b's add to an Admin invite room was not refused"
echo "==> [access] admin invite passed"

echo "==> [access] from join: B invites C, who reads only what was sent after"
create_room a both,member-invite,from-join "acc-join-$run_tag"
join_room=$created_room
before_text="before c joined $run_tag"
after_text="after c joined $run_tag"
start_a=$(lines a)
expect_ok a send "$join_room" "$before_text"
expect_chat a "$join_room" "$before_text" "$start_a" "client a's message was not stored"
expect_ok a room-add "$join_room" "$user_b"
start_b=$(lines b)
start_c=$(lines c)
expect_membership b "$join_room" true "$user_b" 0 "client b was not added to the From join room"
expect_ok b room-add "$join_room" "$user_c"
expect_member_result b "$join_room" "$user_c" true "$start_b" \
	"client b's invite of c was not applied"
expect_membership c "$join_room" true "$user_c" "$start_c" \
	"client c was not told it joined the From join room"
expect_ok b send "$join_room" "$after_text"
expect_chat c "$join_room" "$after_text" "$start_c" "client c did not receive b's message"
history_of c "$join_room"
[[ "$history_line" == *"\"content\":\"$after_text\""* ]] ||
	fail "client c's history misses the message sent after it joined: $history_line"
[[ "$history_line" != *"$before_text"* ]] ||
	fail "client c's From join history has a message from before it joined: $history_line"
history_of b "$join_room"
[[ "$history_line" != *"$before_text"* ]] ||
	fail "client b's From join history has a message from before it joined: $history_line"
start_b=$(lines b)
expect_ok b room-remove "$join_room" "$user_c"
expect_refusal b "Admin permission required" "$start_b" "client b was allowed to remove c"
echo "==> [access] from join passed"

echo "==> [access] full history: C reads what was sent before it joined"
create_room a both,member-invite,full "acc-full-$run_tag"
full_room=$created_room
old_text="before the full room had c $run_tag"
start_a=$(lines a)
expect_ok a send "$full_room" "$old_text"
expect_chat a "$full_room" "$old_text" "$start_a" "client a's message was not stored"
start_c=$(lines c)
expect_ok a room-add "$full_room" "$user_c"
expect_membership c "$full_room" true "$user_c" "$start_c" \
	"client c was not added to the Full history room"
history_of c "$full_room"
[[ "$history_line" == *"\"content\":\"$old_text\""* ]] ||
	fail "client c's Full history misses the earlier message: $history_line"
echo "==> [access] full history passed"

echo "==> [access] leave: B leaves the Admin invite room; nobody leaves #general"
start_b=$(lines b)
expect_ok b room-leave "$admin_room"
expect_membership b "$admin_room" false "$user_b" "$start_b" \
	"client b was not told it left the room"
expect_event b "^\\{\"event\":\"room_list\"," "$start_b" "client b's room list was not refreshed"
[[ "$last_event" != *"\"id\":$admin_room,"* ]] ||
	fail "client b still lists the room it left: $last_event"
start_c=$(lines c)
expect_ok c room-leave 1
expect_refusal c "You cannot leave a public room" "$start_c" "client c left #general"
echo "==> [access] leave passed"

echo "==> [access] remove: A removes C from the From join room"
start_a=$(lines a)
start_c=$(lines c)
expect_ok a room-remove "$join_room" "$user_c"
expect_member_result a "$join_room" "$user_c" false "$start_a" \
	"client a's removal of c was not applied"
expect_membership c "$join_room" false "$user_c" "$start_c" "client c was not told it was removed"
start_c=$(lines c)
expect_ok c history "$join_room"
expect_refusal c "Not a room member" "$start_c" "client c read a room it was removed from"
echo "==> [access] remove passed"

echo "==> [access] no join: A creates a room it is not in and manages it"
hidden_name="acc-hidden-$run_tag"
create_room a text,admin-invite,no-join "$hidden_name"
hidden_room=$created_room
[[ "$last_event" == *'"isMember":false,"encrypted":false,"logVersion":0,"myPermissions":'* ]] ||
	fail "the room created without joining has the creator as a member: $last_event"
expect_ok a rooms
[[ "$last_result" != *"\"id\":$hidden_room,"* ]] ||
	fail "client a lists a room it did not join: $last_result"
start_a=$(lines a)
expect_ok a admin-rooms
admin_rooms_pattern="^\\{\"event\":\"admin_rooms\",.*\"id\":$hidden_room,\"name\":\"$hidden_name\","
admin_rooms_pattern+="[^}]*\\},\"isMember\":false,\"memberCount\":0\\}"
expect_event a "$admin_rooms_pattern" "$start_a" \
	"client a's admin room list does not have the room it is not in"
start_a=$(lines a)
start_b=$(lines b)
expect_ok a room-add "$hidden_room" "$user_b"
expect_member_result a "$hidden_room" "$user_b" true "$start_a" \
	"client a could not add b to a room it is not in"
expect_membership b "$hidden_room" true "$user_b" "$start_b" \
	"client b was not added to the hidden room"
start_a=$(lines a)
expect_ok a room-members "$hidden_room"
members_pattern="^\\{\"event\":\"room_members\",\"serverID\":1,\"roomID\":$hidden_room,"
members_pattern+="\"userIDs\":\\[$user_b\\]\\}$"
expect_event a "$members_pattern" "$start_a" "client a could not list the hidden room's members"
expect_ok b send "$hidden_room" "only for b $run_tag"
start_a=$(lines a)
expect_ok a history "$hidden_room"
expect_refusal a "Not a room member" "$start_a" "client a read a room it is not a member of"
start_a=$(lines a)
start_c=$(lines c)
expect_ok a room-edit "$hidden_room" text,public "$hidden_name"
expect_membership c "$hidden_room" true "$user_c" "$start_c" \
	"client c was not added when the room became Public"
public_pattern="^\\{\"event\":\"room_list\",.*\"id\":$hidden_room,[^}]*"
public_pattern+="\"access\":1,\"historyVisibility\":2,"
expect_event c "$public_pattern" "$start_c" \
	"client c does not list the room as Public with full history"
history_of c "$hidden_room"
[[ "$history_line" == *"only for b $run_tag"* ]] ||
	fail "client c does not read the whole history of the now Public room: $history_line"
start_b=$(lines b)
expect_ok a room-delete "$hidden_room"
expect_event b "^\\{\"event\":\"room_deleted\",\"serverID\":1,\"roomID\":$hidden_room\\}$" \
	"$start_b" "client b was not told the room was deleted"
echo "==> [access] no join passed"

stop_client c
stop_client b
stop_client a
echo "==> [access] passed"
