#!/usr/bin/env bash
set -euo pipefail

# Live proof of registration (protocol 25, #43, plan D7-D19) with headless clients
# (docs/testing-harness.md, "Registration") against a running server, and a second server on
# a fresh database:
#
#   1. mode:      admin alice (deploy/sql/make-admin.sql) gives bob a role with create-invites
#                 and switches the server to Invite only; bob sees registration_mode.
#   2. no code:   carol, a new key without a code, gets registration_required (mode invite):
#                 her status is registering, not connected, and she cannot send.
#   3. code:      bob (not an admin) creates a code and carol registers with it in the same
#                 session: registration_result created, connected with registered true, and
#                 her message in #general reaches alice.
#   4. refusals:  frank is refused an expired code (expires_at moved into the past with SQL),
#                 a revoked one and carol's used-up one, all "This invite code is not valid".
#   5. link:      henry opens bob's invite link (link-open): a link with another server key is
#                 refused (key_differs), the real one matches the key henry pinned; link-confirm
#                 reconnects registering and `register form` signs him up with the link's code.
#   6. approval:  alice switches to Invite + approval. dave's code makes a pending request: alice
#                 sees registration_request with pendingCount and approves it, and dave, still
#                 connected, is created live. george's request is declined with a reason, which
#                 he sees at once and again on his next attempt.
#   7. room code: alice's code for an Admin invite room (with skip approval) signs erin up
#                 restricted: her rooms are that room only (not #general), her users only the
#                 room's members (alice, not carol or bob), and bob does not see her. Her direct
#                 message to carol is refused ("You no longer share a room with this person")
#                 until alice adds carol to the room; then carol receives it. alice sees erin
#                 restricted at once, from the user_updated her sign-up sends (#102). alice
#                 makes the room Public: erin's user list gains bob, and bob's gains erin (#104).
#   7b. gone room: two requests through a room code (ivy, jack). ivy is approved while away,
#                 then alice deletes the room: approving jack is refused ("The room this invite
#                 was for is no longer available"), declining him still works, and ivy's next
#                 sign-in is declined by the server with no account made (#115).
#   8. bootstrap: a second server on a fresh database, in Invite only mode from the start, with
#                 HAYCHAT_ADMIN_PUBLIC_KEY set to boss's key: zed is told to register, boss signs
#                 in, an operator code (deploy/sql/create-invite.sql) signs zed up, and boss is
#                 made an admin with make-admin.sql.
#
# The proof restores the running server's registration mode when it ends, so the proofs after
# it (under --all) find the server as it was. Step 8 needs a database role that may create
# databases (the throwaway PostgreSQL's superuser in ./dev.sh and CI) and a free UDP port
# (HAYCHAT_REGISTRATION_PROOF_PORT, default 12346); it drops its database again.
#
# dev/live-proof.sh --registration (and --all) runs it against its throwaway server and passes
# its server binary in HAYCHAT_SERVER_BIN; without it the proof builds the server. It needs
# bash, coreutils and psql (HAYCHAT_DATABASE_* as for the server).
#
# Usage: dev/registration-proof.sh [HOST:PORT]   (default 127.0.0.1:12345)

repo_dir=$(cd -- "$(dirname -- "$0")/.." >/dev/null 2>&1 && pwd)
server_address=${1:-127.0.0.1:12345}
command_timeout_secs=15
smoke_label=registration
ready_timeout_secs=${HAYCHAT_SERVER_READY_TIMEOUT_SECS:-60}
fresh_port=${HAYCHAT_REGISTRATION_PROOF_PORT:-12346}

work_dir=$(mktemp -d -t haychat-registration.XXXXXX)
client_bin="$work_dir/haychat-client"
run_tag=$(date +%s%N)
run_tag=${run_tag: -9}
fresh_db="haychat_regproof_$run_tag"
fresh_db_created=false
fresh_pid=""
original_mode=""

declare -A client_pid=()
declare -A client_fd=()

INVALID_CODE="This invite code is not valid"
RESTRICTED_DM="You no longer share a room with this person"
ROOM_UNAVAILABLE="The room this invite was for is no longer available"
ROOM_GONE_REASON="$ROOM_UNAVAILABLE; ask for a new invite"

# proof_psql DATABASE ARGS...: psql against the HAYCHAT_DATABASE_* server, on DATABASE.
proof_psql() {
	local database=$1
	shift
	PGPASSWORD="${HAYCHAT_DATABASE_PASS:-haychat}" psql -q -X -t -A -v ON_ERROR_STOP=1 \
		-h "${HAYCHAT_DATABASE_URL:-localhost}" -p "${HAYCHAT_DATABASE_PORT:-5432}" \
		-U "${HAYCHAT_DATABASE_USER:-haychat}" -d "$database" "$@"
}

main_db=${HAYCHAT_DATABASE_NAME:-haychat}

# run_sql SQL: runs statements against the running server's database.
run_sql() {
	proof_psql "$main_db" -c "$1" || fail "SQL failed: $1"
}

stop_fresh_server() {
	if [[ -z "$fresh_pid" ]] || ! kill -0 "$fresh_pid" 2>/dev/null; then
		fresh_pid=""
		return 0
	fi
	kill -INT "$fresh_pid" 2>/dev/null || true
	for _ in $(seq 1 50); do
		kill -0 "$fresh_pid" 2>/dev/null || break
		sleep 0.1
	done
	kill -KILL "$fresh_pid" 2>/dev/null || true
	wait "$fresh_pid" 2>/dev/null || true
	fresh_pid=""
}

on_exit() {
	local status=$? client
	for client in "${!client_pid[@]}"; do
		kill "${client_pid[$client]}" 2>/dev/null || true
	done
	stop_fresh_server
	if [[ "$fresh_db_created" == true ]]; then
		proof_psql "$main_db" -c "DROP DATABASE IF EXISTS $fresh_db WITH (FORCE)" >/dev/null ||
			echo "could not drop the database $fresh_db" >&2
	fi
	# Whatever happened, the next proof finds the server in the mode it started in.
	if [[ -n "$original_mode" ]]; then
		proof_psql "$main_db" -c "UPDATE server_settings SET registration_mode = $original_mode" \
			>/dev/null || echo "could not restore the registration mode" >&2
	fi
	if [[ $status -ne 0 ]]; then
		print_client_output
		if [[ -f "$work_dir/fresh-server.log" ]]; then
			echo "---- fresh server log ----" >&2
			cat "$work_dir/fresh-server.log" >&2 || true
			echo "---- end fresh server log ----" >&2
		fi
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

# expect_not_ok CLIENT COMMAND...: runs a command and fails unless it is refused.
expect_not_ok() {
	local client=$1 result
	shift
	result=$(client_command "$client" "$@") || fail "client $client: no result for \`$*\`"
	echo "    $client> $*"
	echo "    $client< $result"
	[[ "$result" == '{"ok":false,'* ]] || fail "client $client: \`$*\` was not refused: $result"
}

# expect_required CLIENT MODE START: registration_required for MODE after START.
expect_required() {
	local client=$1 mode=$2 start=$3
	expect_event "$client" \
		"^\\{\"event\":\"registration_required\",\"serverID\":1,\"mode\":\"$mode\"," "$start" \
		"client $client was not told to register (mode $mode)"
}

# expect_result CLIENT STATUS START: registration_result with STATUS after START.
expect_result() {
	local client=$1 status=$2 start=$3
	expect_event "$client" \
		"^\\{\"event\":\"registration_result\",\"serverID\":1,\"status\":\"$status\"," "$start" \
		"client $client got no registration_result $status"
}

# expect_registered CLIENT START: registration_result created, then connected with registered
# true; the account's ID ends up in registered_user.
expect_registered() {
	local client=$1 start=$2
	expect_result "$client" created "$start"
	expect_event "$client" '^\{"event":"connected",.*"registered":true' "$start" \
		"client $client did not connect as a new account"
	[[ "$last_event" =~ \"userID\":([0-9]+), ]] || fail "client $client's connected has no userID"
	registered_user=${BASH_REMATCH[1]}
}

# create_invite CLIENT OPTIONS NOTE: invite-create, and the invite's ID, code and link in
# invite_id, invite_code and invite_link.
create_invite() {
	local client=$1 options=$2 note=$3 start pattern
	start=$(lines "$client")
	expect_ok "$client" invite-create "$options" "$note"
	pattern="^\\{\"event\":\"invite_created\",\"serverID\":1,\"invite\":\\{\"id\":[0-9]+,"
	pattern+="\"note\":\"$note\","
	expect_event "$client" "$pattern" "$start" "client $client got no invite_created for $note"
	[[ "$last_event" =~ \"invite\":\{\"id\":([0-9]+), ]] || fail "invite_created has no ID"
	invite_id=${BASH_REMATCH[1]}
	[[ "$last_event" =~ \"code\":\"([0-9A-Z-]+)\",\"link\":\"([^\"]+)\" ]] ||
		fail "invite_created has no code and link"
	invite_code=${BASH_REMATCH[1]}
	invite_link=${BASH_REMATCH[2]}
}

# set_mode CLIENT MODE: registration-mode, answered by admin_result and registration_mode.
set_mode() {
	local client=$1 mode=$2 start
	start=$(lines "$client")
	expect_ok "$client" registration-mode "$mode"
	expect_event "$client" '^\{"event":"admin_result",.*"action":"registration-mode"' "$start" \
		"client $client got no admin_result for the mode $mode"
	expect_event "$client" \
		"^\\{\"event\":\"registration_mode\",\"serverID\":1,\"mode\":\"$mode\"\\}$" "$start" \
		"client $client did not see the mode become $mode"
}

# user_id_of CLIENT NICKNAME: the account's ID in the client's users, in found_user.
user_id_of() {
	local client=$1 nickname=$2
	expect_ok "$client" users
	[[ "$last_result" =~ \{\"id\":([0-9]+),\"nickname\":\"$nickname\", ]] ||
		fail "client $client's users do not list $nickname"
	found_user=${BASH_REMATCH[1]}
}

# wait_server_ready LOG PID: waits for the server's readiness line, like dev/live-proof.sh.
wait_server_ready() {
	local log=$1 pid=$2 deadline=$((SECONDS + ready_timeout_secs))
	while ((SECONDS < deadline)); do
		grep -Fq "=== Server Running ===" "$log" && return 0
		grep -Fq "[Startup]" "$log" && fail "the fresh server failed during startup"
		kill -0 "$pid" 2>/dev/null || fail "the fresh server exited before it was ready"
		sleep 0.1
	done
	fail "the fresh server was not ready after ${ready_timeout_secs}s"
}

cd "$repo_dir"
command -v psql >/dev/null 2>&1 || fail "the registration proof needs psql on PATH"
original_mode=$(run_sql "SELECT registration_mode FROM server_settings")
[[ "$original_mode" =~ ^[123]$ ]] || fail "unexpected registration mode '$original_mode'"
if [[ "$original_mode" != 1 ]]; then
	# Admin alice and inviter bob need plain accounts first; the mode is restored at the end.
	run_sql "UPDATE server_settings SET registration_mode = 1" >/dev/null
fi

echo "==> [registration] building the client"
odin build client -out:"$client_bin"
server_bin=${HAYCHAT_SERVER_BIN:-}
if [[ -z "$server_bin" ]]; then
	echo "==> [registration] building the server (HAYCHAT_SERVER_BIN is not set)"
	server_bin="$work_dir/haychat-server"
	odin build server -out:"$server_bin"
fi

nickname_alice="reg-alice-$run_tag"
nickname_bob="reg-bob-$run_tag"
nickname_carol="reg-carol-$run_tag"
nickname_frank="reg-frank-$run_tag"
nickname_henry="reg-henry-$run_tag"
nickname_dave="reg-dave-$run_tag"
nickname_george="reg-george-$run_tag"
nickname_erin="reg-erin-$run_tag"
nickname_ivy="reg-ivy-$run_tag"
nickname_jack="reg-jack-$run_tag"
gone_room="reg-gone-$run_tag"
role_name="reg-inviters-$run_tag"
restricted_room="reg-room-$run_tag"
decline_reason="reg proof decline $run_tag"

echo "==> [registration] 1. alice is an admin, bob an inviter, and the server Invite only"
start_client alice "$nickname_alice"
expect_connected alice
make_admin "$nickname_alice"
expect_ok alice wait connected 0
expect_ok alice reconnect
expect_ok alice wait connected 8000
expect_ok alice status
[[ "$last_result" == *'"isAdmin":true,'* ]] || fail "alice is not an admin after reconnecting"
start_client bob "$nickname_bob"
expect_connected bob
expect_ok bob wait room_list 5000
user_id_of alice "$nickname_bob"
user_bob=$found_user

start_a=$(lines alice)
start_b=$(lines bob)
expect_ok alice roles-save 0 create-invites "$role_name"
expect_event alice '^\{"event":"admin_result",.*"action":"role-save",' "$start_a" \
	"alice got no admin_result for the inviters role"
[[ "$last_event" =~ \"roleID\":([0-9]+)[,}] ]] || fail "the inviters role has no roleID"
role_inviters=${BASH_REMATCH[1]}
expect_ok alice roles-assign "$user_bob" "$role_inviters"
expect_event bob '^\{"event":"account_updated",.*"permissions":\["create-invites"\],' "$start_b" \
	"bob did not get create-invites"
set_mode alice invite
expect_event bob '^\{"event":"registration_mode","serverID":1,"mode":"invite"\}$' "$start_b" \
	"bob did not see the mode become invite"

echo "==> [registration] 2. carol, without a code, is told to register and cannot chat"
start_client carol "$nickname_carol"
expect_required carol invite 0
expect_ok carol status
[[ "$last_result" == *'"connection":"registering"'* && "$last_result" == *'"connected":false'* ]] ||
	fail "carol's status is not registering: $last_result"
expect_not_ok carol send 1 "carol before signing up $run_tag"

echo "==> [registration] 3. bob's code signs carol up in the same session"
create_invite bob "expires=3600,uses=1" "for carol $run_tag"
code_carol=$invite_code
start_c=$(lines carol)
expect_ok carol register "$code_carol"
expect_registered carol "$start_c"
user_carol=$registered_user
[[ "$last_event" == *'"isRestricted":false'* ]] || fail "carol is restricted: $last_event"
expect_ok carol wait room_list 5000
start_a=$(lines alice)
expect_ok carol send 1 "carol signed up $run_tag"
expect_event alice "^\\{\"event\":\"room_chat\",.*\"content\":\"carol signed up $run_tag\"\\}$" \
	"$start_a" "alice did not receive carol's first message"

echo "==> [registration] 4. an expired, a revoked and a used-up code are refused"
create_invite alice "expires=3600,uses=1" "expired $run_tag"
code_expired=$invite_code
run_sql "UPDATE invites SET expires_at = now() - interval '1 minute' WHERE id = $invite_id" \
	>/dev/null
create_invite alice "expires=3600,uses=1" "revoked $run_tag"
code_revoked=$invite_code
start_a=$(lines alice)
expect_ok alice invite-revoke "$invite_id"
revoke_pattern="^\\{\"event\":\"admin_result\",.*\"action\":\"invite-revoke\","
revoke_pattern+=".*\"inviteID\":${invite_id}[,}]"
expect_event alice "$revoke_pattern" "$start_a" "alice got no admin_result for the revoke"
start_client_at frank "$nickname_frank" "$server_address" --invite-code "$code_expired"
expect_result frank refused 0
[[ "$last_event" == *"\"message\":\"$INVALID_CODE\""* ]] ||
	fail "frank's expired code was not refused as invalid: $last_event"
for code in "$code_revoked" "$code_carol"; do
	start_f=$(lines frank)
	expect_ok frank register "$code"
	expect_result frank refused "$start_f"
	[[ "$last_event" == *"\"message\":\"$INVALID_CODE\""* ]] ||
		fail "frank's code was not refused as invalid: $last_event"
done
expect_ok frank status
[[ "$last_result" == *'"connected":false'* ]] || fail "frank signed in: $last_result"
stop_client frank

echo "==> [registration] 5. henry signs up through bob's invite link"
create_invite bob "expires=3600,uses=1" "link for henry $run_tag"
link_henry=$invite_link
[[ "$link_henry" == "haychat://$server_address/invite/$invite_code?key="* ]] ||
	fail "the invite link does not name this server and code: $link_henry"
start_client henry "$nickname_henry"
expect_required henry invite 0
# A key that is not the one henry pinned (any other 64 hex characters) is refused.
real_key=${link_henry##*key=}
other_key=$(printf '%s' "$real_key" | tr '0-9a-f' '1-9a-f0')
start_h=$(lines henry)
expect_ok henry link-open "${link_henry%key=*}key=$other_key"
expect_event henry '^\{"event":"link_pending",.*"match":"key_differs",' "$start_h" \
	"henry's client did not refuse a link with another server key"
[[ "$last_event" != *'"error":""'* ]] || fail "the refused link gives no reason: $last_event"
start_h=$(lines henry)
expect_ok henry link-open "$link_henry"
link_pattern='^\{"event":"link_pending",.*"kind":"invite",.*"hasCode":true,.*"match":"pinned",'
expect_event henry "$link_pattern" "$start_h" \
	"henry's client did not match the link to the server it pinned"
[[ "$last_event" != *"$invite_code"* ]] || fail "link_pending printed the code"
start_h=$(lines henry)
expect_ok henry link-confirm
expect_required henry invite "$start_h"
start_h=$(lines henry)
expect_ok henry register form
expect_registered henry "$start_h"

echo "==> [registration] 6. approval: dave is approved live, george declined"
set_mode alice approval
create_invite alice "expires=3600,uses=1" "for dave $run_tag"
code_dave=$invite_code
start_a=$(lines alice)
start_client_at dave "$nickname_dave" "$server_address" --invite-code "$code_dave" \
	--reason "carol's friend $run_tag"
expect_result dave pending 0
request_pattern="^\\{\"event\":\"registration_request\",\"serverID\":1,\"pendingCount\":([0-9]+),"
request_pattern+="\"request\":\\{\"id\":[0-9]+,\"nickname\":\"$nickname_dave\","
expect_event alice "$request_pattern" "$start_a" "alice did not hear of dave's request"
[[ "$last_event" =~ \"pendingCount\":([0-9]+), ]] || fail "the request has no pendingCount"
pending_with_dave=${BASH_REMATCH[1]}
((pending_with_dave >= 1)) || fail "pendingCount $pending_with_dave does not count dave"
[[ "$last_event" =~ \"request\":\{\"id\":([0-9]+), ]] || fail "the request has no ID"
request_dave=${BASH_REMATCH[1]}
[[ "$last_event" == *"\"reason\":\"carol's friend $run_tag\""* &&
	"$last_event" == *'"status":"pending"'* ]] ||
	fail "dave's request does not carry his reason as pending: $last_event"
expect_ok alice registration-list
[[ "$last_result" == *"\"pendingCount\":$pending_with_dave,"* &&
	"$last_result" == *"{\"id\":$request_dave,\"nickname\":\"$nickname_dave\","* ]] ||
	fail "alice's registration-list does not hold dave's request: $last_result"
expect_ok alice status
[[ "$last_result" == *"\"pendingRegistrations\":$pending_with_dave"* ]] ||
	fail "alice's badge is not $pending_with_dave: $last_result"
start_a=$(lines alice)
start_d=$(lines dave)
expect_ok alice registration-decide "$request_dave" approve
decide_pattern="^\\{\"event\":\"admin_result\",.*\"action\":\"registration-decide\","
decide_pattern+=".*\"requestID\":${request_dave}[,}]"
expect_event alice "$decide_pattern" "$start_a" "alice got no admin_result for the approval"
decided_pattern="^\\{\"event\":\"registration_request\",\"serverID\":1,"
decided_pattern+="\"pendingCount\":$((pending_with_dave - 1)),\"request\":\\{\"id\":$request_dave,"
expect_event alice "$decided_pattern" "$start_a" "alice's badge did not go down after approving"
expect_registered dave "$start_d"
expect_ok dave wait room_list 5000
expect_ok dave rooms
[[ "$last_result" == *'{"id":1,'* ]] || fail "dave is not in #general: $last_result"

create_invite alice "expires=3600,uses=1" "for george $run_tag"
start_a=$(lines alice)
start_client_at george "$nickname_george" "$server_address" --invite-code "$invite_code" \
	--reason "a stranger $run_tag"
expect_result george pending 0
request_pattern="^\\{\"event\":\"registration_request\",.*\"request\":\\{\"id\":([0-9]+),"
request_pattern+="\"nickname\":\"$nickname_george\","
expect_event alice "$request_pattern" "$start_a" "alice did not hear of george's request"
[[ "$last_event" =~ \"request\":\{\"id\":([0-9]+), ]] || fail "george's request has no ID"
request_george=${BASH_REMATCH[1]}
start_g=$(lines george)
expect_ok alice registration-decide "$request_george" decline "$decline_reason"
expect_result george declined "$start_g"
[[ "$last_event" == *"$decline_reason"* ]] || fail "george's decline has no reason: $last_event"
start_g=$(lines george)
expect_ok george reconnect
expect_event george \
	"^\\{\"event\":\"registration_required\",.*\"status\":\"declined\",.*$decline_reason" \
	"$start_g" "george's next attempt does not show the decline and its reason"

echo "==> [registration] 7. a room code makes erin restricted to that room"
start_a=$(lines alice)
expect_ok alice room-create "text,admin-invite" "$restricted_room" "registration proof"
expect_event alice "^\\{\"event\":\"room_created\",.*\"name\":\"$restricted_room\"," "$start_a" \
	"alice did not create $restricted_room"
[[ "$last_event" =~ \"roomID\":([0-9]+), ]] || fail "room_created has no roomID"
room_id=${BASH_REMATCH[1]}
create_invite alice "expires=3600,uses=1,room=$room_id,skip-approval" "for erin $run_tag"
[[ "$last_event" == *"\"roomId\":$room_id,\"restricted\":true,\"skipApproval\":true"* ]] ||
	fail "erin's code is not a restricted room code: $last_event"
start_a=$(lines alice)
start_client_at erin "$nickname_erin" "$server_address" --invite-code "$invite_code"
expect_registered erin 0
user_erin=$registered_user
[[ "$last_event" == *'"isRestricted":true'* ]] || fail "erin is not restricted: $last_event"
# #102: the sign-up reaches alice as erin's full entry, before or with her presence.
updated_pattern="^\\{\"event\":\"user_updated\",\"serverID\":1,"
updated_pattern+="\"user\":\\{\"id\":$user_erin,.*\"isRestricted\":true"
expect_event alice "$updated_pattern" "$start_a" \
	"alice was not sent erin's entry with her restriction"
expect_ok erin wait room_list 5000
expect_ok erin rooms
[[ "$last_result" == *"{\"id\":$room_id,\"name\":\"$restricted_room\","* ]] ||
	fail "erin is not in $restricted_room: $last_result"
[[ "$last_result" != *'{"id":1,'* ]] || fail "erin joined #general: $last_result"
expect_ok erin users
[[ "$last_result" == *"\"nickname\":\"$nickname_alice\","* ]] ||
	fail "erin does not see alice, who shares her room: $last_result"
[[ "$last_result" != *"\"nickname\":\"$nickname_carol\","* &&
	"$last_result" != *"\"nickname\":\"$nickname_bob\","* ]] ||
	fail "erin sees accounts she shares no room with: $last_result"
expect_ok bob users
[[ "$last_result" != *"\"nickname\":\"$nickname_erin\","* ]] ||
	fail "bob sees erin, with whom he shares no room: $last_result"
# Admins see every account, and alice's directory has erin's restriction without signing in
# again (#102).
user_id_of alice "$nickname_erin"
[[ "$found_user" == "$user_erin" ]] || fail "alice lists erin under ID $found_user"
restricted_entry="\\{\"id\":$user_erin,\"nickname\":\"$nickname_erin\",[^}]*\"isRestricted\":true"
[[ "$last_result" =~ $restricted_entry ]] ||
	fail "alice's users do not show erin restricted: $last_result"

start_e=$(lines erin)
start_c=$(lines carol)
erin_refused="erin to carol, refused $run_tag"
result=$(client_command erin dm "$user_carol" "$erin_refused") || fail "erin: no result for dm"
echo "    erin> dm $user_carol $erin_refused"
echo "    erin< $result"
if [[ "$result" == '{"ok":true,'* ]]; then
	expect_event erin \
		"^\\{\"event\":\"protocol_error\",\"serverID\":1,\"message\":\"$RESTRICTED_DM\"\\}$" \
		"$start_e" "the server did not refuse erin's direct message to carol"
fi
expect_ok carol sleep 1000
! grep -Fq -- "$erin_refused" <(tail -n "+$((start_c + 1))" "$work_dir/carol.out") ||
	fail "carol received erin's direct message without a shared room"

start_e=$(lines erin)
start_a=$(lines alice)
expect_ok alice room-add "$room_id" "$user_carol"
member_pattern="^\\{\"event\":\"room_member_result\",\"serverID\":1,\"roomID\":$room_id,"
member_pattern+="\"userID\":$user_carol,"
expect_event alice "$member_pattern" "$start_a" "alice could not add carol to $restricted_room"
expect_event erin "^\\{\"event\":\"user_list\",.*\"nickname\":\"$nickname_carol\"," "$start_e" \
	"erin's user list did not gain carol once they shared a room"
start_c=$(lines carol)
erin_allowed="erin to carol, allowed $run_tag"
expect_ok erin dm "$user_carol" "$erin_allowed"
dm_pattern="^\\{\"event\":\"direct_message\",.*\"senderID\":$user_erin,"
dm_pattern+=".*\"content\":\"$erin_allowed\"\\}$"
expect_event carol "$dm_pattern" "$start_c" \
	"carol did not receive erin's direct message once they shared a room"
# The refused message was queued by erin's client and dropped, never sent once allowed.
! grep -Fq -- "$erin_refused" "$work_dir/carol.out" ||
	fail "erin's refused direct message reached carol later"

# #104: the room made Public adds bob, so erin and bob now share it and see each other.
start_e=$(lines erin)
start_b=$(lines bob)
start_a=$(lines alice)
expect_ok alice room-edit "$room_id" text,public "$restricted_room"
expect_event alice "^\\{\"event\":\"room_edited\",\"serverID\":1,\"roomID\":$room_id," \
	"$start_a" "alice could not make $restricted_room Public"
expect_event erin "^\\{\"event\":\"user_list\",.*\"nickname\":\"$nickname_bob\"," "$start_e" \
	"erin's user list did not gain bob once the room was Public"
expect_event bob "^\\{\"event\":\"user_list\",.*\"nickname\":\"$nickname_erin\"," "$start_b" \
	"bob's user list did not gain erin once the room was Public"
stop_client erin

echo "==> [registration] 7b. a room code whose room is deleted after approval signs nobody up"
start_a=$(lines alice)
expect_ok alice room-create "text,admin-invite" "$gone_room" "registration proof"
expect_event alice "^\\{\"event\":\"room_created\",.*\"name\":\"$gone_room\"," "$start_a" \
	"alice did not create $gone_room"
[[ "$last_event" =~ \"roomID\":([0-9]+), ]] || fail "room_created has no roomID"
gone_id=${BASH_REMATCH[1]}
create_invite alice "expires=3600,uses=2,room=$gone_id" "for ivy and jack $run_tag"
code_gone=$invite_code
request_ids=()
for applicant in ivy jack; do
	nickname_var="nickname_$applicant"
	start_a=$(lines alice)
	start_client_at "$applicant" "${!nickname_var}" "$server_address" --invite-code "$code_gone" \
		--reason "for $gone_room"
	expect_result "$applicant" pending 0
	request_pattern="^\\{\"event\":\"registration_request\",.*\"request\":\\{\"id\":([0-9]+),"
	request_pattern+="\"nickname\":\"${!nickname_var}\","
	expect_event alice "$request_pattern" "$start_a" "alice did not hear of $applicant's request"
	[[ "$last_event" =~ \"request\":\{\"id\":([0-9]+), ]] || fail "the request has no ID"
	request_ids+=("${BASH_REMATCH[1]}")
done
# ivy leaves before the decision, so her account would only be made at her next sign-in.
stop_client ivy
start_a=$(lines alice)
expect_ok alice registration-decide "${request_ids[0]}" approve
expect_event alice "^\\{\"event\":\"admin_result\",.*\"action\":\"registration-decide\"," \
	"$start_a" "alice got no admin_result for ivy's approval"
start_a=$(lines alice)
expect_ok alice room-delete "$gone_id"
expect_event alice "^\\{\"event\":\"room_deleted\",\"serverID\":1,\"roomID\":$gone_id\\}$" \
	"$start_a" "alice could not delete $gone_room"
start_a=$(lines alice)
expect_ok alice registration-decide "${request_ids[1]}" approve
expect_event alice \
	"^\\{\"event\":\"protocol_error\",\"serverID\":1,\"message\":\"$ROOM_UNAVAILABLE\"\\}$" \
	"$start_a" "approving jack's request for a deleted room was not refused"
start_j=$(lines jack)
expect_ok alice registration-decide "${request_ids[1]}" decline
expect_result jack declined "$start_j"
start_client ivy-again "$nickname_ivy" ivy
expect_event ivy-again \
	"^\\{\"event\":\"registration_required\",.*\"status\":\"declined\",.*$ROOM_GONE_REASON" \
	0 "ivy's sign-in after her room was deleted was not declined by the server"
[[ $(run_sql "SELECT count(*) FROM users WHERE nickname = '$nickname_ivy'") == 0 ]] ||
	fail "an account was made for ivy without her room"
stop_client ivy-again
stop_client jack
stop_client george
stop_client dave
stop_client henry
stop_client carol
stop_client bob
set_mode alice open
stop_client alice

echo "==> [registration] 8. a fresh database in Invite only mode; the admin key bootstraps"
# boss's identity key exists before the server starts: the client makes it with the profile,
# and this first run fails fast against a port nobody listens on.
"$client_bin" --headless --name "reg-boss-$run_tag" --server 127.0.0.1:1 \
	--config-dir "$work_dir/profile-boss" --connect-timeout 1 \
	</dev/null >"$work_dir/boss-setup.out" 2>&1 || true
boss_key=$(sed -n 's/.*"public_key"[[:space:]]*:[[:space:]]*"\([0-9A-Fa-f]*\)".*/\1/p' \
	"$work_dir/profile-boss/haychat/config.json")
[[ "$boss_key" =~ ^[0-9a-f]{64}$ ]] || fail "boss's profile has no public key: '$boss_key'"

proof_psql "$main_db" -c "CREATE DATABASE $fresh_db" >/dev/null ||
	fail "could not create the database $fresh_db (the role needs CREATEDB)"
fresh_db_created=true
mkdir -p "$work_dir/fresh/storage" "$work_dir/fresh/logs"
HAYCHAT_DATABASE_NAME=$fresh_db HAYCHAT_LISTEN_PORT=$fresh_port \
	HAYCHAT_LOG_DIR="$work_dir/fresh/logs" HAYCHAT_FILE_STORAGE_PATH="$work_dir/fresh/storage" \
	HAYCHAT_SERVER_IDENTITY_FILE="$work_dir/fresh/storage/server_identity.json" \
	HAYCHAT_ADMIN_PUBLIC_KEY=$boss_key \
	"$server_bin" >"$work_dir/fresh-server.log" 2>&1 &
fresh_pid=$!
wait_server_ready "$work_dir/fresh-server.log" "$fresh_pid"
proof_psql "$fresh_db" -v mode=invite -f deploy/sql/set-registration-mode.sql >/dev/null ||
	fail "set-registration-mode.sql failed on the fresh database"
accounts=$(proof_psql "$fresh_db" -c "SELECT count(*) FROM users")
[[ "$accounts" == 0 ]] || fail "the fresh database already has $accounts accounts"
fresh_address="127.0.0.1:$fresh_port"

start_client_at zed "reg-zed-$run_tag" "$fresh_address"
expect_required zed invite 0
start_client_at boss "reg-boss-$run_tag" "$fresh_address"
expect_connected boss
expect_ok boss status
[[ "$last_result" == *'"registrationMode":"invite"'* &&
	"$last_result" == *'"isRestricted":false'* ]] ||
	fail "boss did not sign in unrestricted on the Invite only server: $last_result"
operator_code=$(proof_psql "$fresh_db" -v uses=1 -v days=1 -v note='registration proof' \
	-f deploy/sql/create-invite.sql | tail -n 1)
start_z=$(lines zed)
expect_ok zed register "$operator_code"
expect_registered zed "$start_z"
HAYCHAT_DATABASE_NAME=$fresh_db make_admin "reg-boss-$run_tag"
expect_ok boss wait connected 0
expect_ok boss reconnect
expect_ok boss wait connected 8000
expect_ok boss status
[[ "$last_result" == *'"isAdmin":true,'* ]] || fail "boss is not an admin: $last_result"
accounts=$(proof_psql "$fresh_db" -c "SELECT count(*) FROM users")
[[ "$accounts" == 2 ]] || fail "the fresh database has $accounts accounts, expected boss and zed"
stop_client zed
stop_client boss
stop_fresh_server

echo "==> [registration] passed"
