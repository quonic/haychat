#!/usr/bin/env bash
set -euo pipefail

# Live proof of the admin actions and room types (protocol 14) with two headless clients
# (docs/testing-harness.md) against a running server:
#
#   1. role:    A is made an admin with deploy/sql/make-admin.sql and reconnects. A makes B an
#               admin: B's harness prints account_updated isAdmin true without reconnecting,
#               and A sees user_updated. A revokes it again (admins cannot be kicked or banned).
#   2. rename:  A renames B and locks the name: B sees account_updated with the new name, and
#               B's reconnect (still asking for its old display name) signs in under it.
#   3. kick:    A kicks B: B prints session_ended kicked and does not reconnect by itself; its
#               `reconnect` signs in again.
#   4. ban:     A bans B: B prints session_ended banned, its reconnect is refused with
#               connect_failed failure Banned, and A's `users` shows B banned. A unbans B and
#               B's reconnect signs in.
#   5. types:   A creates a room for text and voice, B joins its voice, A makes it text-only:
#               B prints voice_left "voice is disabled in this room", and B's next voice-join
#               is refused with the same reason.
#
# dev/live-proof.sh --admin (and --all) runs it against its throwaway server. It needs bash,
# coreutils, psql (for make-admin.sql through the HAYCHAT_DATABASE_* variables), and libopus
# for step 5's voice join.
#
# Usage: dev/admin-proof.sh [HOST:PORT]   (default 127.0.0.1:12345)

repo_dir=$(cd -- "$(dirname -- "$0")/.." >/dev/null 2>&1 && pwd)
server_address=${1:-127.0.0.1:12345}
command_timeout_secs=10
smoke_label=admin

work_dir=$(mktemp -d -t haychat-admin.XXXXXX)
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
}

cd "$repo_dir"
echo "==> [admin] building the client"
odin build client -out:"$client_bin"

nickname_a="adm-a-$run_tag"
nickname_b="adm-b-$run_tag"
renamed_b="adm-r-$run_tag"

echo "==> [admin] A becomes an admin; B signs in"
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
expect_event a "^\\{\"event\":\"presence\",.*\"nickname\":\"$nickname_b\",\"isOnline\":true\\}$" \
	0 "client a never saw $nickname_b come online"
expect_ok a users
[[ "$last_result" =~ \{\"id\":([0-9]+),\"nickname\":\"$nickname_b\",\"isOnline\":true, ]] ||
	fail "client a's users do not list $nickname_b online"
user_b=${BASH_REMATCH[1]}

echo "==> [admin] role: A makes B an admin, B sees it without reconnecting"
start_a=$(lines a)
start_b=$(lines b)
expect_ok a admin-role "$user_b" on
expect_event a "^\\{\"event\":\"admin_result\",.*\"action\":\"role\",\"userID\":$user_b," \
	"$start_a" "client a got no admin_result for the grant"
expect_event b "^\\{\"event\":\"account_updated\",.*\"isAdmin\":true," "$start_b" \
	"client b did not see account_updated isAdmin true"
expect_event a "^\\{\"event\":\"user_updated\",.*\"id\":$user_b,.*\"isAdmin\":true," "$start_a" \
	"client a did not see user_updated for b's role"
expect_ok b status
[[ "$last_result" == *'"connected":true'* && "$last_result" == *'"isAdmin":true,'* ]] ||
	fail "client b's status is not an admin on the same session: $last_result"
# Admins cannot be kicked or banned (D6), so the role goes again before the next steps.
start_b=$(lines b)
expect_ok a admin-role "$user_b" off
expect_event b "^\\{\"event\":\"account_updated\",.*\"isAdmin\":false," "$start_b" \
	"client b did not see account_updated isAdmin false"
echo "==> [admin] role passed"

echo "==> [admin] rename: A renames B and locks it; B's reconnect keeps it"
start_a=$(lines a)
start_b=$(lines b)
expect_ok a admin-rename "$user_b" lock "$renamed_b"
expect_event a "^\\{\"event\":\"admin_result\",.*\"action\":\"rename\",\"userID\":$user_b," \
	"$start_a" "client a got no admin_result for the rename"
renamed_pattern="^\\{\"event\":\"account_updated\",.*\"nickname\":\"$renamed_b\","
renamed_pattern+="\"nicknameLocked\":true\\}$"
expect_event b "$renamed_pattern" "$start_b" "client b did not see its new locked name"
expect_event a "^\\{\"event\":\"user_updated\",.*\"id\":$user_b,\"nickname\":\"$renamed_b\"," \
	"$start_a" "client a did not see user_updated with b's new name"
expect_ok b wait connected 0
expect_ok b reconnect
expect_ok b wait connected 8000
connected_b=$(tail -n +"$((start_b + 1))" "$work_dir/b.out" | grep -F '{"event":"connected",' |
	tail -n 1)
echo "    b< $connected_b"
locked_name="\"nickname\":\"$renamed_b\",\"isAdmin\":false,\"nicknameLocked\":true}"
[[ "$connected_b" == *"$locked_name"* ]] ||
	fail "client b's reconnect did not keep the locked name $renamed_b: $connected_b"
echo "==> [admin] rename passed"

echo "==> [admin] kick: B's session ends and it waits for reconnect"
start_a=$(lines a)
start_b=$(lines b)
expect_ok a admin-kick "$user_b" proof kick
kicked_pattern="^\\{\"event\":\"session_ended\",.*\"kind\":\"kicked\","
kicked_pattern+=".*\"reason\":\"proof kick\","
expect_event b "$kicked_pattern" "$start_b" "client b did not see session_ended kicked"
expect_event a "^\\{\"event\":\"presence\",.*\"userID\":$user_b,.*\"isOnline\":false\\}$" \
	"$start_a" "client a did not see b go offline"
# Not retried by itself: two seconds later b is still stopped.
expect_ok b sleep 2000
expect_ok b status
[[ "$last_result" == *'"connection":"failed"'* ]] ||
	fail "client b reconnected by itself after a kick: $last_result"
expect_ok b reconnect
expect_ok b wait connected 8000
echo "==> [admin] kick passed"

echo "==> [admin] ban: B's session ends and its reconnect is refused; an unban lets it back"
start_a=$(lines a)
start_b=$(lines b)
expect_ok a admin-ban "$user_b" proof ban
banned_pattern="^\\{\"event\":\"session_ended\",.*\"kind\":\"banned\","
banned_pattern+=".*\"reason\":\"proof ban\","
expect_event b "$banned_pattern" "$start_b" "client b did not see session_ended banned"
expect_event a "^\\{\"event\":\"user_updated\",.*\"id\":$user_b,.*\"isBanned\":true\\}\\}$" \
	"$start_a" "client a did not see user_updated with b banned"
expect_ok a users
[[ "$last_result" =~ \{\"id\":$user_b,[^}]*\"isBanned\":true\} ]] ||
	fail "client a's users do not show b banned: $last_result"
start_b=$(lines b)
expect_ok b reconnect
refused_pattern="^\\{\"event\":\"connect_failed\",.*"
refused_pattern+="\"detail\":\"This account is banned from this server: proof ban\","
refused_pattern+="\"failure\":\"Banned\",\"retryable\":false,"
expect_event b "$refused_pattern" "$start_b" "client b's reconnect was not refused as banned"
start_a=$(lines a)
expect_ok a admin-unban "$user_b"
expect_event a "^\\{\"event\":\"user_updated\",.*\"id\":$user_b,.*\"isBanned\":false\\}\\}$" \
	"$start_a" "client a did not see user_updated with b unbanned"
expect_ok b reconnect
expect_ok b wait connected 8000
echo "==> [admin] ban passed"

echo "==> [admin] room types: a room made text-only ends its voice and refuses joins"
room_name="adm-room-$run_tag"
start_a=$(lines a)
start_b=$(lines b)
expect_ok a room-create both "$room_name" "admin proof"
created_line=$(wait_for_match a "^\\{\"event\":\"room_created\",.*\"name\":\"$room_name\"," \
	"$start_a") || fail "client a did not receive room_created"
echo "    a< $created_line"
[[ "$created_line" =~ \"roomID\":([0-9]+), ]] || fail "room_created has no roomID"
room=${BASH_REMATCH[1]}
[[ "$created_line" == *'"roomType":3}'* ]] || fail "the new room is not text and voice"
expect_event b "^\\{\"event\":\"room_list\",.*\"name\":\"$room_name\"" "$start_b" \
	"client b's room list never listed $room_name"
expect_ok b voice-join "$room"
expect_event b "^\\{\"event\":\"voice_status\",.*\"roomID\":$room,\"status\":\"joined\"," \
	"$start_b" "client b did not join the room's voice"
start_b=$(lines b)
expect_ok a room-edit "$room" text "$room_name" "admin proof"
text_only_reason="\"roomID\":$room,\"reason\":\"voice is disabled in this room\"\\}$"
expect_event b "^\\{\"event\":\"voice_left\",\"serverID\":1,$text_only_reason" \
	"$start_b" "client b was not removed from the text-only room's voice"
expect_event b "^\\{\"event\":\"room_edited\",.*\"roomID\":$room,.*\"roomType\":1\\}$" \
	"$start_b" "client b did not see the room become text-only"
start_b=$(lines b)
expect_ok b voice-join "$room"
expect_event b "^\\{\"event\":\"voice_join_rejected\",\"serverID\":1,$text_only_reason" \
	"$start_b" "client b's voice join of a text-only room was not refused"
expect_ok b voice-leave
echo "==> [admin] room types passed"

stop_client b
stop_client a
echo "==> [admin] passed"
