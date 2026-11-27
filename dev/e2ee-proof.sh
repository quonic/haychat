#!/usr/bin/env bash
set -euo pipefail

# Live proof of the account encryption keys (protocol 16, e2ee-design.md 3, 12.4) with
# headless clients (docs/testing-harness.md) against a running server:
#
#   1. bundles: alice and bob sign in, publish their bundles, and fetch each other's
#               (user-keys): each pins the other unverified, the pinned keys are the ones in the
#               other profile's config.json, and both see the same safety number. alice marks
#               bob verified.
#   2. restart: bob quits and signs in again from the same profile: his encryption key is the
#               same, and alice's fetch still finds him verified (no "set up encryption again").
#               alice's key store file holds bob's pin.
#   3. swap:    mallory signs in and publishes; then SQL moves mallory's identity key and bundle
#               onto bob's account behind the server's back. alice's next fetch shows bob's key
#               changed (sending blocked), and trust-key pins the new key, unverified.
#   4. dm:      (protocol 17, design 12.4 step 1) carol and dan exchange encrypted direct
#               messages both ways (carol's first one waits for dan's key, then goes out
#               encrypted); both see them opened, and carol's history, after a restart of her
#               client, still opens.
#   5. sql:     (step 2) no message text appears in direct_messages: every row between carol
#               and dan has an envelope, an empty content, and no marker text in the envelope.
#   6. rebuild: (step 6) dan's key store is deleted and his client restarted: his history waits
#               for carol's key, which he pins again, and his old messages open again.
#   7. signed:  (protocol 22, #82, #90) carol's signed plaintext room message reaches dan as
#               plain; then SQL writes a room message and a direct message in carol's name, each
#               once under a signature that is not hers and once with an all-zero one: dan's
#               client shows none of them (hidden, no content) and never prints their text.
#   8. dave:    (step 7) dave's bundle is removed behind the server's back (he published one when
#               he signed in, and stays signed in so his client does not publish again): carol's
#               `dm` to him is refused, and `dm-plain` reaches him with encrypted false and a
#               valid signature on both sides; SQL finds that text, as it should.
#   9. room:    (protocol 18, design 12.4 step 3) admin ra creates an encrypted Admin invite
#               room (its Create entry signed by ra) and adds rb: both verify the member log
#               with ra as manager and both as members. rc, not a member, cannot fetch its log
#               or history, and a message to the room is stored sealed, never readable.
#  10. forged:  (step 5, second half) an unsigned Add of rc inserted into room_log_entries by
#               SQL: ra's and rb's clients refuse the log with the member-list warning.
#  11. managed: (step 9) ra creates a second encrypted room without joining it, adds rb and
#               makes rb a manager; admin re, who is not a manager, is refused by the server
#               when adding rc, removes rb through the server (rb sees "the server removed"),
#               and an add signed by re and inserted by SQL is refused by ra's log check.
#  12. chains:  (protocol 19, step 3) ra and rb exchange sealed messages in a new encrypted
#               room: ra's first one waits for her chain's distribution; rc, not a member, is
#               refused the room's keys and history. A restart of ra's client starts a new chain:
#               every stored message has its own (sender, chain, index), ra's in two chains.
#  13. sql:     (step 2 for rooms) every chat_messages row of the room is sealed with an empty
#               content and no marker text, and its envelopes hold no marker either.
#  14. rebuild: (step 6 for rooms) rb's key store is deleted and his client restarted: the
#               room's history opens again from the envelopes the server keeps.
#  15. join:    (step 8, From join) rb invites rc to a Member invite room: rc reads only what
#               is sent after, and holds no chain from before.
#  16. removal: (step 4) ra removes rb: rb shows the removal, ra's next message is sealed in a
#               chain with no wrap for rb, and rb cannot read the room any more.
#  17. inserted:(step 5, first half) rc is added to room_members by SQL: she fetches the history
#               but holds no chain and opens nothing, and ra refuses her key request.
#  18. full:    (protocol 20, step 8, Full history) ra creates a Full history Member invite
#               room with rb; both send. ra is offline while rb (restarted, so in a new chain)
#               sends again: a chain ra never held. ra invites rc and forwards the two chains
#               she holds; rc reads all three messages, rb's newest chain re-sealed by rb on
#               request (ra answers that she does not hold it). Then, with rb offline, ra
#               invites re: rc, not its sender, forwards rb's newest chain on request. SQL:
#               forward envelopes exist only in the Full history room (none in step 14's From
#               join room, where nothing older opened for rc).
#  19. ban:     (protocol 32, #72) ra adds a new account rd to an encrypted room, where rd
#               opens ra's message, and to a second one whose log SQL then damages. ra bans rd:
#               the server removes rd from the first room (ra sees "the server removed rd" in a
#               new epoch) and names the second in admin_result failedRoomIDs. ra sends during
#               the ban and unbans rd: rd signs in again but is no member, is refused the room's
#               history and keys, never opens the message sent during the ban, and no envelope
#               of the new epoch has a wrap for rd. The damaged room still lists rd.
#  20. managers:(protocol 33, #195) ra adds a new account rf to an encrypted Admin invite room
#               with rc, makes rf a manager and steps down, so rf is its only manager. ra bans
#               rf: the server writes its Remove and its RemoveManager (one room_log, "the
#               server removed rf as a manager"), and admin_result says the room has no manager
#               left. ra and rc replay the log without error and keep sending to each other, and
#               an add signed by rc, a member who is no manager, is refused by the server.
#  21. secrets: no client ever printed its encryption private key, and no client wrote the
#               text of an encrypted message to its log (stderr).
#
# dev/live-proof.sh --e2ee (and --all) runs it against its throwaway server. It needs bash,
# coreutils and psql (through the HAYCHAT_DATABASE_* variables).
#
# Usage: dev/e2ee-proof.sh [HOST:PORT]   (default 127.0.0.1:12345)

repo_dir=$(cd -- "$(dirname -- "$0")/.." >/dev/null 2>&1 && pwd)
server_address=${1:-127.0.0.1:12345}
command_timeout_secs=10
smoke_label=e2ee

work_dir=$(mktemp -d -t haychat-e2ee.XXXXXX)
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

expect_event() {
	local client=$1 pattern=$2 start=$3 why=$4 line
	line=$(wait_for_match "$client" "$pattern" "$start") || fail "$why"
	echo "    $client< $line" >&2
	printf '%s\n' "$line"
}

# run_sql SQL: runs statements against the server's database, like make_admin.
run_sql() {
	command -v psql >/dev/null 2>&1 || fail "the e2ee proof needs psql on PATH"
	PGPASSWORD="${HAYCHAT_DATABASE_PASS:-haychat}" psql -q -X -t -A -v ON_ERROR_STOP=1 \
		-h "${HAYCHAT_DATABASE_URL:-localhost}" -p "${HAYCHAT_DATABASE_PORT:-5432}" \
		-U "${HAYCHAT_DATABASE_USER:-haychat}" -d "${HAYCHAT_DATABASE_NAME:-haychat}" \
		-c "$1" || fail "SQL failed: $1"
}

# config_value PROFILE KEY: a string or number from a profile's config.json.
config_value() {
	local file="$work_dir/profile-$1/haychat/config.json"
	[[ -f "$file" ]] || fail "no config.json for profile $1"
	tr -d '\n' <"$file" | grep -oE "\"$2\":(\"[^\"]*\"|[0-9]+)" | head -n1 | sed -E 's/^[^:]+://; s/"//g'
}

# user_id CLIENT NICKNAME: the account ID of NICKNAME from CLIENT's users.
user_id() {
	local client=$1 nickname=$2
	expect_ok "$client" users >&2
	[[ "$last_result" =~ \{\"id\":([0-9]+),\"nickname\":\"$nickname\", ]] ||
		fail "client $client's users do not list $nickname"
	printf '%s\n' "${BASH_REMATCH[1]}"
}

# fetch_keys CLIENT USER_ID: user-keys and the user_keys event that answers it.
fetch_keys() {
	local client=$1 userID=$2 start
	start=$(lines "$client")
	expect_ok "$client" user-keys "$userID" >&2
	expect_event "$client" "^\\{\"event\":\"user_keys\",.*\"userID\":$userID," "$start" \
		"client $client got no user_keys for user $userID"
}

field() {
	local line=$1 name=$2
	[[ "$line" =~ \"$name\":(\"[^\"]*\"|[a-z0-9]+) ]] || fail "no $name in $line"
	local value=${BASH_REMATCH[1]}
	value=${value#\"}
	printf '%s\n' "${value%\"}"
}

cd "$repo_dir"
echo "==> [e2ee] building the client"
odin build client -out:"$client_bin"

alice="e2a-$run_tag"
bob="e2b-$run_tag"
mallory="e2m-$run_tag"

echo "==> [e2ee] bundles: alice and bob pin each other and see the same safety number"
start_client a "$alice"
expect_connected a
start_client b "$bob"
expect_connected b
expect_ok a wait room_list 5000
expect_ok b wait room_list 5000
alice_id=$(user_id b "$alice")
bob_id=$(user_id a "$bob")

a_sees_b=$(fetch_keys a "$bob_id")
b_sees_a=$(fetch_keys b "$alice_id")
[[ $(field "$a_sees_b" keyState) == unverified ]] || fail "alice did not pin bob unverified"
[[ $(field "$b_sees_a" keyState) == unverified ]] || fail "bob did not pin alice unverified"
[[ $(field "$a_sees_b" canEncrypt) == true ]] || fail "alice cannot encrypt to bob"
[[ $(field "$a_sees_b" identityPublicKey) == "$(config_value b public_key)" ]] ||
	fail "alice pinned another identity key than bob's"
bob_encryption_key=$(config_value b encryption_public_key)
[[ $(field "$a_sees_b" encryptionPublicKey) == "$bob_encryption_key" ]] ||
	fail "alice pinned another encryption key than bob's"
[[ $(field "$b_sees_a" encryptionPublicKey) == "$(config_value a encryption_public_key)" ]] ||
	fail "bob pinned another encryption key than alice's"
number_a=$(field "$a_sees_b" safetyNumber)
number_b=$(field "$b_sees_a" safetyNumber)
[[ "$number_a" =~ ^([0-9]{5}\ ){11}[0-9]{5}$ ]] || fail "not a safety number: $number_a"
[[ "$number_a" == "$number_b" ]] || fail "safety numbers differ: $number_a vs $number_b"
echo "    both see $number_a"
expect_ok a verify "$bob_id"
[[ $(field "$last_result" keyState) == verified ]] || fail "alice could not verify bob"

echo "==> [e2ee] restart: bob signs in again with the same key; alice still has him verified"
stop_client b
start_client b2 "$bob" b
expect_connected b2
expect_ok b2 wait room_list 5000
[[ $(config_value b encryption_public_key) == "$bob_encryption_key" ]] ||
	fail "bob's encryption key changed across a restart"
again=$(fetch_keys a "$bob_id")
[[ $(field "$again" keyState) == verified ]] || fail "alice lost bob's verified pin"
[[ $(field "$again" notice) == "" ]] || fail "alice saw a key notice for an unchanged key"
store_files=("$work_dir"/profile-a/haychat/keys/*.json)
[[ -f "${store_files[0]}" ]] || fail "alice has no key store file"
grep -Eq "\"user_id\": ?$bob_id," "${store_files[0]}" ||
	fail "alice's key store has no pin for bob"
mode=$(stat -c %a "${store_files[0]}")
[[ "$mode" == 600 ]] || fail "alice's key store is mode $mode, not 600"
stop_client b2

echo "==> [e2ee] swap: the server hands out mallory's key as bob's"
start_client m "$mallory"
expect_connected m
expect_ok m wait room_list 5000
mallory_id=$(user_id a "$mallory")
mallory_identity=$(config_value m public_key)
stop_client m
run_sql "BEGIN;
CREATE TEMP TABLE swap AS SELECT u.public_key, k.encryption_public_key, k.created_at_unix,
	k.signature FROM users u JOIN user_encryption_keys k ON k.user_id = u.id
	WHERE u.id = $mallory_id;
UPDATE users SET public_key = NULL WHERE id = $mallory_id;
UPDATE users SET public_key = (SELECT public_key FROM swap) WHERE id = $bob_id;
UPDATE user_encryption_keys k SET encryption_public_key = s.encryption_public_key,
	created_at_unix = s.created_at_unix, signature = s.signature FROM swap s
	WHERE k.user_id = $bob_id;
COMMIT;" >/dev/null
swapped=$(fetch_keys a "$bob_id")
[[ $(field "$swapped" keyState) == key_changed ]] || fail "alice did not see bob's key change"
[[ $(field "$swapped" canEncrypt) == false ]] || fail "alice could still encrypt to bob"
[[ $(field "$swapped" identityPublicKey) == "$(config_value b public_key)" ]] ||
	fail "alice's pin for bob moved without her"
[[ $(field "$swapped" message) == "$bob's key changed" ]] || fail "no key-changed sentence"
expect_ok a trust-key "$bob_id"
[[ $(field "$last_result" keyState) == unverified ]] || fail "trust-key did not pin the new key"
[[ $(field "$last_result" identityPublicKey) == "$mallory_identity" ]] ||
	fail "trust-key pinned another key than the one offered"

echo "==> [e2ee] dm: carol and dan exchange encrypted direct messages both ways"
carol="e2c-$run_tag"
dan="e2d-$run_tag"
dave="e2v-$run_tag"
marker_one="e2ee-marker-one-$run_tag"
marker_two="e2ee-marker-two-$run_tag"
plain_text="e2ee-plain-to-dave-$run_tag"
start_client c "$carol"
expect_connected c
start_client d "$dan"
expect_connected d
expect_ok c wait room_list 5000
expect_ok d wait room_list 5000
carol_id=$(user_id d "$carol")
dan_id=$(user_id c "$dan")
# carol never fetched dan's key: her message waits for it, then goes out encrypted.
start=$(lines c)
expect_ok c dm "$dan_id" "$marker_one"
[[ "$last_result" == *'"queued":true'* || "$last_result" == *'"encrypted":true'* ]] ||
	fail "carol's dm was neither encrypted nor queued: $last_result"
expect_event c "^\\{\"event\":\"direct_queue\",.*\"peerUserID\":$dan_id,\"state\":\"sent\"" \
	"$start" "carol's queued message never went out" >/dev/null
encrypted_pattern() {
	printf '%s' "^\\{\"event\":\"direct_message\",.*\"encrypted\":true,\"signed\":true,"
	printf '%s' "\"decryptError\":\"\",\"protection\":\"encrypted\",\"content\":\"$1\"\\}$"
}
expect_event c "$(encrypted_pattern "$marker_one")" "$start" \
	"carol did not see her own message opened" >/dev/null
expect_event d "$(encrypted_pattern "$marker_one")" 0 \
	"dan did not open carol's message" >/dev/null
start=$(lines c)
expect_ok d dm "$carol_id" "$marker_two"
[[ "$last_result" == *'"encrypted":true'* ]] || fail "dan's reply was not encrypted: $last_result"
expect_event c "$(encrypted_pattern "$marker_two")" "$start" \
	"carol did not open dan's reply" >/dev/null

echo "==> [e2ee] dm: carol's history opens after a restart of her client"
stop_client c
start_client c2 "$carol" c
expect_connected c2
expect_ok c2 wait room_list 5000
start=$(lines c2)
expect_ok c2 dm-history "$dan_id"
history=$(expect_event c2 "^\\{\"event\":\"direct_history\",.*\"peerUserID\":$dan_id," "$start" \
	"carol got no history page after her restart")
for marker in "$marker_one" "$marker_two"; do
	[[ "$history" == *"\"protection\":\"encrypted\",\"content\":\"$marker\""* ]] ||
		fail "carol's history after a restart does not open $marker: $history"
done

echo "==> [e2ee] sql: no message text in direct_messages"
rows=$(run_sql "SELECT count(*) || '/' ||
	count(*) FILTER (WHERE envelope IS NOT NULL AND content = '') || '/' ||
	count(*) FILTER (WHERE position(convert_to('e2ee-marker', 'UTF8') in envelope) > 0
		OR position('e2ee-marker' in content) > 0)
	FROM direct_messages WHERE sender_user_id IN ($carol_id, $dan_id)
	AND recipient_user_id IN ($carol_id, $dan_id)")
[[ "$rows" == "2/2/0" ]] ||
	fail "expected 2 encrypted rows with empty content and no marker text, got $rows"

echo "==> [e2ee] rebuild: dan loses his key store; his old messages open again"
stop_client d
rm -f -- "$work_dir"/profile-d/haychat/keys/*.json
start_client d2 "$dan" d
expect_connected d2
expect_ok d2 wait room_list 5000
start=$(lines d2)
expect_ok d2 dm-history "$carol_id"
expect_event d2 "^\\{\"event\":\"direct_history\",.*\"peerUserID\":$carol_id," "$start" \
	"dan got no history page after losing his key store" >/dev/null
for marker in "$marker_one" "$marker_two"; do
	pattern="^\\{\"event\":\"direct_(history|opened)\",.*\"protection\":\"encrypted\","
	pattern+="\"content\":\"$marker\""
	expect_event d2 "$pattern" "$start" "dan's history did not open $marker again" >/dev/null
done

echo "==> [e2ee] signed: messages the server writes in carol's name are never shown"
genuine_text="e2ee-genuine-room-$run_tag"
forged_text="e2ee-forged-$run_tag"
dstart=$(lines d2)
expect_ok c2 send 1 "$genuine_text"
plain_room_pattern="^\\{\"event\":\"room_(chat|opened)\",\"serverID\":[0-9]+,\"roomID\":1,.*"
plain_room_pattern+="\"protection\":\"plain\",\"content\":\"$genuine_text\"\\}$"
expect_event d2 "$plain_room_pattern" "$dstart" \
	"dan did not read carol's signed room message" >/dev/null
run_sql "INSERT INTO chat_messages (room_id, sender_user_id, content, client_message_id,
		signature) VALUES
	(1, $carol_id, '$forged_text-room-bad', decode(md5('room-bad-$run_tag'), 'hex'),
		decode(repeat('ab', 64), 'hex')),
	(1, $carol_id, '$forged_text-room-none', decode(md5('room-none-$run_tag'), 'hex'),
		decode(repeat('00', 64), 'hex'));
	INSERT INTO direct_messages (sender_user_id, recipient_user_id, content, client_message_id,
		signature) VALUES
	($carol_id, $dan_id, '$forged_text-dm-bad', decode(md5('dm-bad-$run_tag'), 'hex'),
		decode(repeat('ab', 64), 'hex')),
	($carol_id, $dan_id, '$forged_text-dm-none', decode(md5('dm-none-$run_tag'), 'hex'),
		decode(repeat('00', 64), 'hex'))" >/dev/null
dstart=$(lines d2)
expect_ok d2 history 1
history=$(expect_event d2 "^\\{\"event\":\"room_history\",\"serverID\":[0-9]+,\"roomID\":1," \
	"$dstart" "dan got no history page of #general")
[[ "$history" == *"\"protection\":\"plain\",\"content\":\"$genuine_text\""* ]] ||
	fail "dan's history does not show carol's signed message: $history"
for reason in bad_signature unsigned; do
	hidden="\"decryptError\":\"$reason\",\"epoch\":0,\"protection\":\"hidden\",\"content\":\"\""
	[[ "$history" == *"$hidden"* ]] ||
		fail "dan's history does not hide the forged room message ($reason): $history"
done
dstart=$(lines d2)
expect_ok d2 dm-history "$carol_id"
history=$(expect_event d2 "^\\{\"event\":\"direct_history\",.*\"peerUserID\":$carol_id," \
	"$dstart" "dan got no direct history with carol")
for reason in bad_signature unsigned; do
	hidden="\"decryptError\":\"$reason\",\"protection\":\"hidden\",\"content\":\"\""
	[[ "$history" == *"$hidden"* ]] ||
		fail "dan's history does not hide the forged direct message ($reason): $history"
done
if grep -qF -- "$forged_text" "$work_dir/d2.out"; then
	fail "dan's client printed the text of a forged message"
fi

echo "==> [e2ee] dave: no key, so dm is refused and dm-plain arrives signed"
start_client v "$dave"
expect_connected v
expect_ok v wait room_list 5000
dave_id=$(user_id c2 "$dave")
for ((attempt = 0; attempt < 50; attempt++)); do
	[[ $(run_sql "SELECT count(*) FROM user_encryption_keys WHERE user_id = $dave_id") == 1 ]] &&
		break
	sleep 0.1
done
run_sql "DELETE FROM user_encryption_keys WHERE user_id = $dave_id" >/dev/null
dave_keys=$(fetch_keys c2 "$dave_id")
[[ $(field "$dave_keys" keyState) == not_set_up ]] ||
	fail "carol does not see dave without a key: $dave_keys"
reply=$(client_command c2 dm "$dave_id" "should not go out")
[[ "$reply" == '{"ok":false,'*"has not set up encryption yet"* ]] ||
	fail "carol's encrypted dm to dave was not refused: $reply"
fetch_keys v "$carol_id" >/dev/null
start=$(lines c2)
vstart=$(lines v)
expect_ok c2 dm-plain "$dave_id" "$plain_text"
[[ "$last_result" == *'"encrypted":false,"queued":false'* ]] ||
	fail "carol's dm-plain did not go out unencrypted: $last_result"
plain_pattern="^\\{\"event\":\"direct_message\",.*\"encrypted\":false,\"signed\":true,"
plain_pattern+="\"decryptError\":\"\",\"protection\":\"signed\",\"content\":\"$plain_text\"\\}$"
expect_event c2 "$plain_pattern" "$start" "carol's own fallback message is not signed" >/dev/null
expect_event v "$plain_pattern" "$vstart" "dave did not receive a signed plaintext" >/dev/null
stored=$(run_sql "SELECT count(*) FROM direct_messages WHERE sender_user_id = $carol_id
	AND recipient_user_id = $dave_id AND content = '$plain_text' AND envelope IS NULL
	AND octet_length(signature) = 64 AND octet_length(client_message_id) = 16")
[[ "$stored" == 1 ]] || fail "SQL does not find the fallback message's text and signature"
stop_client v
stop_client c2
stop_client d2

echo "==> [e2ee] room: admin ra creates an encrypted room and adds rb"
room_alice="e2ra-$run_tag"
room_erin="e2re-$run_tag"
room_bob="e2rb-$run_tag"
room_carol="e2rc-$run_tag"
start_client ra "$room_alice"
expect_connected ra
make_admin "$room_alice"
expect_ok ra reconnect
expect_ok ra wait connected 8000
start_client re "$room_erin"
expect_connected re
make_admin "$room_erin"
expect_ok re reconnect
expect_ok re wait connected 8000
start_client rb "$room_bob"
expect_connected rb
start_client rc "$room_carol"
expect_connected rc
for client in ra re rb rc; do
	expect_ok "$client" wait room_list 5000
done
ra_id=$(user_id rb "$room_alice")
re_id=$(user_id ra "$room_erin")
rb_id=$(user_id ra "$room_bob")
rc_id=$(user_id ra "$room_carol")
fetch_keys ra "$rb_id" >/dev/null
fetch_keys ra "$rc_id" >/dev/null

# room_log_line CLIENT ROOM_ID FIELDS START: waits for a room_log of ROOM_ID whose status and
# version start like FIELDS.
room_log_line() {
	expect_event "$1" "^\\{\"event\":\"room_log\",\"serverID\":[0-9]+,\"roomID\":$2,$3" "$4" \
		"client $1 never reported room $2's log as $3"
}

# room_message CLIENT ROOM_ID MARKER START: waits for an opened room message (live room_chat or
# room_opened, encrypted) carrying MARKER.
room_message() {
	local pattern="^\\{\"event\":\"room_(chat|opened)\",\"serverID\":[0-9]+,\"roomID\":$2,.*"
	pattern+="\"encrypted\":true,\"decryptError\":\"\",\"epoch\":[0-9]+,\"protection\":\"encrypted\","
	pattern+="\"content\":\"$3\"\\}$"
	expect_event "$1" "$pattern" "$4" "client $1 did not open room $2's message $3"
}

start=$(lines ra)
expect_ok ra users >/dev/null
expect_ok ra room-create "text,admin-invite,encrypted,managers=none" "secret-$run_tag"
created=$(expect_event ra "^\\{\"event\":\"room_created\",.*\"name\":\"secret-$run_tag\"" \
	"$start" "ra never got room_created for the encrypted room")
[[ "$created" == *'"isMember":false,"encrypted":true,"logVersion":0,"myPermissions":'* ]] ||
	fail "the encrypted room did not start empty at version 0: $created"
room_id=$(field "$created" roomID)
first=$(room_log_line ra "$room_id" '"status":"verified","logVersion":1,' "$start")
[[ "$first" == *"\"members\":[$ra_id],\"managers\":[$ra_id],"* ]] ||
	fail "ra's verified Create does not name ra member and manager: $first"
expect_event ra "^\\{\"event\":\"room_membership\",.*\"roomID\":$room_id,\"joined\":true" \
	"$start" "ra never joined the encrypted room" >/dev/null

start=$(lines ra)
bstart=$(lines rb)
expect_ok ra room-add "$room_id" "$rb_id"
second=$(room_log_line ra "$room_id" '"status":"verified","logVersion":2,' "$start")
[[ "$second" == *"\"members\":[$ra_id,$rb_id],"* && "$second" == *"added $room_bob"* ]] ||
	fail "ra's log does not show rb added: $second"
bob_log=$(room_log_line rb "$room_id" '"status":"verified","logVersion":2,' "$bstart")
[[ "$bob_log" == *"\"members\":[$ra_id,$rb_id],\"managers\":[$ra_id],"* ]] ||
	fail "rb's verified log differs: $bob_log"
store_files=("$work_dir"/profile-rb/haychat/keys/*.json)
grep -q '"log_head_hash"' "${store_files[0]}" || fail "rb's key store holds no room head"

echo "==> [e2ee] room: rc, not a member, can fetch neither the log nor the history"
cstart=$(lines rc)
expect_ok rc room-log "$room_id"
expect_event rc '^\{"event":"protocol_error",.*"message":"Not a room member"' "$cstart" \
	"rc was not refused the room's log" >/dev/null
cstart=$(lines rc)
expect_ok rc history "$room_id"
expect_event rc '^\{"event":"protocol_error",.*"message":"Not a room member"' "$cstart" \
	"rc was not refused the room's history" >/dev/null
expect_ok ra users >/dev/null
# Since protocol 19 a message to the room is sealed: whatever is stored is never readable.
start=$(lines ra)
expect_ok ra send "$room_id" "plaintext-in-encrypted-$run_tag"
[[ "$last_result" == *'"encrypted":true'* ]] || fail "ra's room message was not encrypted"
room_message ra "$room_id" "plaintext-in-encrypted-$run_tag" "$start" >/dev/null
chat=$(run_sql "SELECT count(*) || '/' || count(*) FILTER (WHERE sealed IS NULL OR content <> ''
	OR position(convert_to('plaintext-in-encrypted', 'UTF8') in sealed) > 0)
	FROM chat_messages WHERE room_id = $room_id")
[[ "$chat" == "1/0" ]] || fail "expected one sealed row and nothing readable, got $chat"

echo "==> [e2ee] forged: an unsigned Add of rc inserted by SQL is refused by ra and rb"
expect_ok ra room-log-entry "$room_id" add "$rc_id" unsigned
forged_hex=$(field "$last_result" entry)
forged_version=$(field "$last_result" version)
run_sql "INSERT INTO room_log_entries (room_id, version, entry)
	VALUES ($room_id, $forged_version, decode('$forged_hex', 'hex'));
	UPDATE rooms SET log_version = $forged_version WHERE id = $room_id;" >/dev/null
for client in ra rb; do
	start=$(lines "$client")
	expect_ok "$client" room-log "$room_id"
	refused=$(room_log_line "$client" "$room_id" '"status":"failed",' "$start")
	[[ "$refused" == *'"logError":"Unsigned","warning":"This room'"'"'s member list was changed on the server"'* ]] ||
		fail "client $client did not refuse the unsigned add: $refused"
done

echo "==> [e2ee] managed: ra creates a room without joining; re is not a manager"
start=$(lines ra)
expect_ok ra room-create "text,admin-invite,encrypted,no-join,managers=none" "managed-$run_tag"
created=$(expect_event ra "^\\{\"event\":\"room_created\",.*\"name\":\"managed-$run_tag\"" \
	"$start" "ra never got room_created for the managed room")
managed_id=$(field "$created" roomID)
first=$(room_log_line ra "$managed_id" '"status":"verified","logVersion":1,' "$start")
[[ "$first" == *'"members":[],'* ]] || fail "the managed room has members: $first"
bstart=$(lines rb)
expect_ok ra room-add "$managed_id" "$rb_id"
room_log_line ra "$managed_id" '"status":"verified","logVersion":2,' "$start" >/dev/null
room_log_line rb "$managed_id" '"status":"verified","logVersion":2,' "$bstart" >/dev/null
fetch_keys rb "$ra_id" >/dev/null
expect_ok ra room-manager "$managed_id" "$rb_id" on
third=$(room_log_line rb "$managed_id" '"status":"verified","logVersion":3,' "$bstart")
[[ "$third" == *"\"managers\":[$ra_id,$rb_id],"* && "$third" == *"made $room_bob a manager"* ]] ||
	fail "rb does not see himself made a manager: $third"

estart=$(lines re)
expect_ok re admin-rooms
room_log_line re "$managed_id" '"status":"verified","logVersion":3,' "$estart" >/dev/null
fetch_keys re "$rc_id" >/dev/null
fetch_keys re "$rb_id" >/dev/null
fetch_keys re "$ra_id" >/dev/null
estart=$(lines re)
expect_ok re room-add "$managed_id" "$rc_id"
expect_event re '^\{"event":"protocol_error",.*"message":"You may not make this change to the member list"' \
	"$estart" "the server did not refuse re's add" >/dev/null
bstart=$(lines rb)
estart=$(lines re)
expect_ok re room-remove "$managed_id" "$rb_id"
removed=$(room_log_line rb "$managed_id" '"status":"verified","logVersion":4,' "$bstart")
[[ "$removed" == *'"members":[],'* && "$removed" == *"the server removed $room_bob"* ]] ||
	fail "rb does not see the server's removal: $removed"
room_log_line re "$managed_id" '"status":"verified","logVersion":4,' "$estart" >/dev/null
expect_ok re room-log-entry "$managed_id" add "$rc_id"
forged_hex=$(field "$last_result" entry)
forged_version=$(field "$last_result" version)
run_sql "INSERT INTO room_log_entries (room_id, version, entry)
	VALUES ($managed_id, $forged_version, decode('$forged_hex', 'hex'));
	UPDATE rooms SET log_version = $forged_version WHERE id = $managed_id;" >/dev/null
start=$(lines ra)
expect_ok ra room-log "$managed_id"
refused=$(room_log_line ra "$managed_id" '"status":"failed",' "$start")
[[ "$refused" == *'"logError":"NotAuthorized"'* ]] ||
	fail "ra's log check did not refuse re's add: $refused"
echo "==> [e2ee] chains: messages in an encrypted room are sealed and open for both members"
chat_one="e2ee-room-marker-one-$run_tag"
chat_two="e2ee-room-marker-two-$run_tag"
chat_three="e2ee-room-marker-three-$run_tag"
start=$(lines ra)
expect_ok ra room-create "text,admin-invite,encrypted,managers=none" "chains-$run_tag"
created=$(expect_event ra "^\\{\"event\":\"room_created\",.*\"name\":\"chains-$run_tag\"" \
	"$start" "ra never got room_created for the chains room")
chat_id=$(field "$created" roomID)
room_log_line ra "$chat_id" '"status":"verified","logVersion":1,' "$start" >/dev/null
bstart=$(lines rb)
expect_ok ra room-add "$chat_id" "$rb_id"
room_log_line ra "$chat_id" '"status":"verified","logVersion":2,' "$start" >/dev/null
room_log_line rb "$chat_id" '"status":"verified","logVersion":2,' "$bstart" >/dev/null
start=$(lines ra)
bstart=$(lines rb)
expect_ok ra send "$chat_id" "$chat_one"
[[ "$last_result" == *'"encrypted":true,"queued":true}' ]] ||
	fail "ra's first message did not wait for its chain: $last_result"
expect_event ra "^\\{\"event\":\"room_queue\",.*\"roomID\":$chat_id,\"state\":\"sent\",\"count\":1" \
	"$start" "ra's queued message never went out" >/dev/null
room_message ra "$chat_id" "$chat_one" "$start" >/dev/null
room_message rb "$chat_id" "$chat_one" "$bstart" >/dev/null
start=$(lines ra)
expect_ok rb send "$chat_id" "$chat_two"
room_message ra "$chat_id" "$chat_two" "$start" >/dev/null
expect_ok rb room-keys "$chat_id"
[[ "$last_result" == *'"epoch":2,'*'"sending":true,"sendingEpoch":2,'*'"distribution":"stored"'* ]] ||
	fail "rb's chain state is not a stored epoch 2 chain: $last_result"
[[ "$last_result" != *chain_key* && "$last_result" != *startKey* ]] ||
	fail "room-keys printed key material: $last_result"

echo "==> [e2ee] chains: rc, not a member, gets neither history nor keys"
cstart=$(lines rc)
expect_ok rc room-keys "$chat_id" fetch
expect_event rc '^\{"event":"protocol_error",.*"message":"Not a room member"' "$cstart" \
	"rc was not refused the room's keys" >/dev/null
cstart=$(lines rc)
expect_ok rc history "$chat_id"
expect_event rc '^\{"event":"protocol_error",.*"message":"Not a room member"' "$cstart" \
	"rc was not refused the room's history" >/dev/null

echo "==> [e2ee] chains: a restart of the sender starts a new chain, never reusing an index"
stop_client ra
start_client ra2 "$room_alice" ra
expect_connected ra2
expect_ok ra2 wait room_list 5000
bstart=$(lines rb)
astart=$(lines ra2)
expect_ok ra2 send "$chat_id" "$chat_three"
room_message ra2 "$chat_id" "$chat_three" "$astart" >/dev/null
room_message rb "$chat_id" "$chat_three" "$bstart" >/dev/null
positions=$(run_sql "SELECT count(*) || '/' ||
	count(DISTINCT (sender_user_id, chain_id, chain_index)) || '/' ||
	count(DISTINCT chain_id) FILTER (WHERE sender_user_id = $ra_id)
	FROM chat_messages WHERE room_id = $chat_id")
[[ "$positions" == "3/3/2" ]] ||
	fail "expected 3 messages at 3 distinct chain positions, ra's in 2 chains, got $positions"

echo "==> [e2ee] sql: no room message text in chat_messages"
rows=$(run_sql "SELECT count(*) || '/' ||
	count(*) FILTER (WHERE sealed IS NOT NULL AND content = '') || '/' ||
	count(*) FILTER (WHERE position(convert_to('e2ee-room-marker', 'UTF8') in sealed) > 0
		OR position('e2ee-room-marker' in content) > 0)
	FROM chat_messages WHERE room_id = $chat_id")
[[ "$rows" == "3/3/0" ]] ||
	fail "expected 3 sealed rows with empty content and no marker text, got $rows"
envelopes=$(run_sql "SELECT count(*) FROM room_key_envelopes WHERE room_id = $chat_id
	AND position(convert_to('e2ee-room-marker', 'UTF8') in envelope) = 0")
[[ "$envelopes" -ge 3 ]] || fail "expected at least 3 stored envelopes, got $envelopes"

echo "==> [e2ee] rebuild: rb loses his key store; the room's messages open again"
stop_client rb
rm -f -- "$work_dir"/profile-rb/haychat/keys/*.json
start_client rb2 "$room_bob" rb
expect_connected rb2
expect_ok rb2 wait room_list 5000
bstart=$(lines rb2)
expect_ok rb2 history "$chat_id"
for marker in "$chat_one" "$chat_two" "$chat_three"; do
	pattern="^\\{\"event\":\"room_(history|opened)\",.*\"protection\":\"encrypted\","
	pattern+="\"content\":\"$marker\""
	expect_event rb2 "$pattern" "$bstart" "rb's history did not open $marker again" >/dev/null
done

echo "==> [e2ee] from join: rb invites rc to a Member invite room; rc reads only what follows"
before_join="e2ee-room-marker-before-join-$run_tag"
after_join="e2ee-room-marker-after-join-$run_tag"
start=$(lines ra2)
expect_ok ra2 room-create "text,member-invite,from-join,encrypted,managers=none" \
	"invite-$run_tag"
created=$(expect_event ra2 "^\\{\"event\":\"room_created\",.*\"name\":\"invite-$run_tag\"" \
	"$start" "ra never got room_created for the invite room")
invite_id=$(field "$created" roomID)
room_log_line ra2 "$invite_id" '"status":"verified","logVersion":1,' "$start" >/dev/null
bstart=$(lines rb2)
fetch_keys ra2 "$rb_id" >/dev/null
expect_ok ra2 room-add "$invite_id" "$rb_id"
room_log_line rb2 "$invite_id" '"status":"verified","logVersion":2,' "$bstart" >/dev/null
start=$(lines ra2)
bstart=$(lines rb2)
expect_ok ra2 send "$invite_id" "$before_join"
room_message rb2 "$invite_id" "$before_join" "$bstart" >/dev/null
fetch_keys rb2 "$rc_id" >/dev/null
cstart=$(lines rc)
bstart=$(lines rb2)
expect_ok rb2 room-add "$invite_id" "$rc_id"
room_log_line rb2 "$invite_id" '"status":"verified","logVersion":3,' "$bstart" >/dev/null
room_log_line rc "$invite_id" '"status":"verified","logVersion":3,' "$cstart" >/dev/null
cstart=$(lines rc)
expect_ok rb2 send "$invite_id" "$after_join"
room_message rc "$invite_id" "$after_join" "$cstart" >/dev/null
cstart=$(lines rc)
expect_ok rc history "$invite_id"
history=$(expect_event rc "^\\{\"event\":\"room_history\",.*\"roomID\":$invite_id," "$cstart" \
	"rc got no history page of the invite room")
[[ "$history" != *"$before_join"* ]] || fail "rc read a message from before she joined"
expect_ok rc room-keys "$invite_id"
[[ "$last_result" != *'"epoch":2,"senderID"'* ]] ||
	fail "rc holds a chain from before she joined: $last_result"

echo "==> [e2ee] removal: ra removes rb; what follows has no key for rb"
bstart=$(lines rb2)
astart=$(lines ra2)
expect_ok ra2 room-remove "$chat_id" "$rb_id"
removed=$(room_log_line rb2 "$chat_id" '"status":"verified","logVersion":3,' "$bstart")
[[ "$removed" == *"removed $room_bob"* ]] || fail "rb does not show his removal: $removed"
room_log_line ra2 "$chat_id" '"status":"verified","logVersion":3,' "$astart" >/dev/null
after_removal="e2ee-room-marker-after-removal-$run_tag"
astart=$(lines ra2)
expect_ok ra2 send "$chat_id" "$after_removal"
room_message ra2 "$chat_id" "$after_removal" "$astart" >/dev/null
wrapped=$(run_sql "SELECT count(*) FILTER (WHERE $rb_id = ANY (recipient_user_ids)) || '/' ||
	count(*) FROM room_key_envelopes WHERE room_id = $chat_id AND epoch = 3")
[[ "$wrapped" == 0/* && "$wrapped" != "0/0" ]] ||
	fail "expected epoch 3 envelopes without a wrap for rb, got $wrapped"
bstart=$(lines rb2)
expect_ok rb2 history "$chat_id"
expect_event rb2 '^\{"event":"protocol_error",.*"message":"Not a room member"' "$bstart" \
	"rb could still read the room after his removal" >/dev/null
if grep -qF -- "$after_removal" "$work_dir/rb2.out"; then
	fail "rb saw a message sent after his removal"
fi

echo "==> [e2ee] inserted member: rc added to room_members by SQL reads nothing"
run_sql "INSERT INTO room_members (room_id, user_id, joined_at)
	VALUES ($chat_id, $rc_id, '2000-01-01')" >/dev/null
cstart=$(lines rc)
astart=$(lines ra2)
expect_ok rc history "$chat_id"
history=$(expect_event rc "^\\{\"event\":\"room_history\",.*\"roomID\":$chat_id," "$cstart" \
	"rc, inserted by SQL, got no history page")
[[ "$history" == *'"encrypted":true'* ]] || fail "rc's history has no sealed messages: $history"
expect_event ra2 "^\\{\"event\":\"room_key_request\",.*\"roomID\":$chat_id,.*\"requesterID\":$rc_id,.*\"outcome\":\"refused\"" \
	"$astart" "ra did not refuse rc's key request" >/dev/null
expect_ok rc room-keys "$chat_id"
[[ "$last_result" == *'"chains":[]'* ]] || fail "rc holds a chain of the room: $last_result"
for marker in "$chat_one" "$chat_three" "$after_removal"; do
	if grep -F -- "$marker" "$work_dir/rc.out" | grep -q '"protection":"encrypted"'; then
		fail "rc, inserted by SQL, opened $marker"
	fi
done

echo "==> [e2ee] full: a Full history room forwards older chains to new members"
full_bob_one="e2ee-room-marker-full-bob-one-$run_tag"
full_alice="e2ee-room-marker-full-alice-$run_tag"
full_bob_two="e2ee-room-marker-full-bob-two-$run_tag"
# key_line CLIENT ROOM_ID FIELDS START: a room_key_request (or with KIND, another event) line.
key_line() {
	expect_event "$1" "^\\{\"event\":\"room_key_request\",\"serverID\":[0-9]+,\"roomID\":$2,$3" "$4" \
		"client $1 never reported a key request in room $2 like $3"
}
start=$(lines ra2)
expect_ok ra2 room-create "text,member-invite,full,encrypted,managers=none" "full-$run_tag"
created=$(expect_event ra2 "^\\{\"event\":\"room_created\",.*\"name\":\"full-$run_tag\"" \
	"$start" "ra never got room_created for the Full history room")
full_id=$(field "$created" roomID)
room_log_line ra2 "$full_id" '"status":"verified","logVersion":1,' "$start" >/dev/null
bstart=$(lines rb2)
expect_ok ra2 room-add "$full_id" "$rb_id"
room_log_line rb2 "$full_id" '"status":"verified","logVersion":2,' "$bstart" >/dev/null
# rb and then ra send in epoch 2; each opens the other's message, so ra holds rb's first chain.
astart=$(lines ra2)
bstart=$(lines rb2)
expect_ok rb2 send "$full_id" "$full_bob_one"
room_message ra2 "$full_id" "$full_bob_one" "$astart" >/dev/null
room_message rb2 "$full_id" "$full_bob_one" "$bstart" >/dev/null
bstart=$(lines rb2)
expect_ok ra2 send "$full_id" "$full_alice"
room_message rb2 "$full_id" "$full_alice" "$bstart" >/dev/null
# ra goes offline; rb restarts (a new run, so a new chain) and sends: ra never holds that one.
stop_client ra2
stop_client rb2
start_client rb3 "$room_bob" rb
expect_connected rb3
expect_ok rb3 wait room_list 5000
bstart=$(lines rb3)
expect_ok rb3 send "$full_id" "$full_bob_two"
room_message rb3 "$full_id" "$full_bob_two" "$bstart" >/dev/null
chains=$(run_sql "SELECT count(DISTINCT chain_id) FROM chat_messages
	WHERE room_id = $full_id AND sender_user_id = $rb_id")
[[ "$chains" == 2 ]] || fail "expected rb's messages in two chains, got $chains"
start_client ra3 "$room_alice" ra
expect_connected ra3
expect_ok ra3 wait room_list 5000
astart=$(lines ra3)
expect_ok ra3 room-log "$full_id"
room_log_line ra3 "$full_id" '"status":"verified","logVersion":2,' "$astart" >/dev/null
expect_ok ra3 room-keys "$full_id"
held=$(grep -o '"senderID"' <<<"$last_result" | wc -l)
[[ "$held" == 2 ]] || fail "expected ra to hold exactly two chains of the room: $last_result"

echo "==> [e2ee] full: ra invites rc and forwards the chains she holds"
fetch_keys ra3 "$rc_id" >/dev/null
astart=$(lines ra3)
cstart=$(lines rc)
expect_ok ra3 room-add "$full_id" "$rc_id"
room_log_line rc "$full_id" '"status":"verified","logVersion":3,' "$cstart" >/dev/null
own=$(key_line ra3 "$full_id" "\"epoch\":2,\"senderID\":$ra_id,.*\"requesterID\":$rc_id,\"outcome\":\"stored\"" \
	"$astart")
[[ "$own" == *'"forwarderID":0}' ]] || fail "ra's own chain was not re-sealed as a SenderKey: $own"
forwarded=$(key_line ra3 "$full_id" "\"epoch\":2,\"senderID\":$rb_id,.*\"requesterID\":$rc_id,\"outcome\":\"stored\"" \
	"$astart")
[[ "$forwarded" == *"\"forwarderID\":$ra_id}" ]] || fail "rb's chain was not forwarded by ra: $forwarded"
cstart=$(lines rc)
expect_ok rc history "$full_id"
for marker in "$full_bob_one" "$full_alice" "$full_bob_two"; do
	pattern="^\\{\"event\":\"room_(history|opened)\",.*\"protection\":\"encrypted\","
	pattern+="\"content\":\"$marker\""
	expect_event rc "$pattern" "$cstart" "rc did not read $marker from before she joined" \
		>/dev/null
done
# rb's newest chain came from rb on request; ra was asked too and does not hold it.
key_line rb3 "$full_id" ".*\"requesterID\":$rc_id,\"outcome\":\"stored\",.*\"forwarderID\":0}" \
	"$bstart" >/dev/null
key_line ra3 "$full_id" ".*\"senderID\":$rb_id,.*\"requesterID\":$rc_id,\"outcome\":\"not_held\"" \
	"$astart" >/dev/null

echo "==> [e2ee] full: with rb offline, rc forwards rb's chain to re on request"
stop_client rb3
fetch_keys ra3 "$re_id" >/dev/null
astart=$(lines ra3)
cstart=$(lines rc)
estart=$(lines re)
expect_ok ra3 room-add "$full_id" "$re_id"
room_log_line re "$full_id" '"status":"verified","logVersion":4,' "$estart" >/dev/null
key_line ra3 "$full_id" "\"epoch\":2,\"senderID\":$rb_id,.*\"requesterID\":$re_id,\"outcome\":\"stored\"" \
	"$astart" >/dev/null
estart=$(lines re)
expect_ok re history "$full_id"
for marker in "$full_bob_one" "$full_alice" "$full_bob_two"; do
	pattern="^\\{\"event\":\"room_(history|opened)\",.*\"protection\":\"encrypted\","
	pattern+="\"content\":\"$marker\""
	expect_event re "$pattern" "$estart" "re did not read $marker from before he joined" \
		>/dev/null
done
by_carol=$(key_line rc "$full_id" ".*\"senderID\":$rb_id,.*\"requesterID\":$re_id,\"outcome\":\"stored\"" \
	"$cstart")
[[ "$by_carol" == *"\"forwarderID\":$rc_id}" ]] || fail "rc did not forward rb's chain: $by_carol"

echo "==> [e2ee] full: forwards exist only in the Full history room"
forwards=$(run_sql "SELECT count(*) FILTER (WHERE room_id = $full_id) || '/' || count(*) || '/' ||
	count(*) FILTER (WHERE room_id = $invite_id)
	FROM room_key_envelopes WHERE forwarder_user_id IS NOT NULL")
[[ "$forwards" =~ ^([0-9]+)/([0-9]+)/0$ && "${BASH_REMATCH[1]}" == "${BASH_REMATCH[2]}" &&
	"${BASH_REMATCH[1]}" -ge 3 ]] ||
	fail "expected at least 3 forwards, all in the Full history room, got $forwards"
history_check=$(run_sql "SELECT history_visibility FROM rooms WHERE id = $invite_id")
[[ "$history_check" == 1 ]] || fail "the From join room is not From join: $history_check"

echo "==> [e2ee] ban: a ban removes rd from its encrypted rooms; unbanned, rd opens nothing new"
room_dan="e2rd-$run_tag"
start_client rd "$room_dan"
expect_connected rd
expect_ok rd wait room_list 5000
rd_id=$(user_id ra3 "$room_dan")
fetch_keys ra3 "$rd_id" >/dev/null
start=$(lines ra3)
expect_ok ra3 room-create "text,admin-invite,encrypted,managers=none" "ban-$run_tag"
created=$(expect_event ra3 "^\\{\"event\":\"room_created\",.*\"name\":\"ban-$run_tag\"" \
	"$start" "ra never got room_created for the ban room")
ban_id=$(field "$created" roomID)
room_log_line ra3 "$ban_id" '"status":"verified","logVersion":1,' "$start" >/dev/null
dstart=$(lines rd)
expect_ok ra3 room-add "$ban_id" "$rd_id"
room_log_line rd "$ban_id" '"status":"verified","logVersion":2,' "$dstart" >/dev/null
before_ban="e2ee-room-marker-before-ban-$run_tag"
during_ban="e2ee-room-marker-during-ban-$run_tag"
dstart=$(lines rd)
expect_ok ra3 send "$ban_id" "$before_ban"
room_message rd "$ban_id" "$before_ban" "$dstart" >/dev/null

# A second room with rd, whose log the server can no longer replay: the ban reports it.
start=$(lines ra3)
expect_ok ra3 room-create "text,admin-invite,encrypted,managers=none" "ban-damaged-$run_tag"
created=$(expect_event ra3 \
	"^\\{\"event\":\"room_created\",.*\"name\":\"ban-damaged-$run_tag\"" \
	"$start" "ra never got room_created for the damaged ban room")
damaged_id=$(field "$created" roomID)
room_log_line ra3 "$damaged_id" '"status":"verified","logVersion":1,' "$start" >/dev/null
expect_ok ra3 room-add "$damaged_id" "$rd_id"
room_log_line ra3 "$damaged_id" '"status":"verified","logVersion":2,' "$start" >/dev/null
expect_ok ra3 room-log-entry "$damaged_id" add "$rc_id" unsigned
forged_hex=$(field "$last_result" entry)
forged_version=$(field "$last_result" version)
run_sql "INSERT INTO room_log_entries (room_id, version, entry)
	VALUES ($damaged_id, $forged_version, decode('$forged_hex', 'hex'));
	UPDATE rooms SET log_version = $forged_version WHERE id = $damaged_id;" >/dev/null

astart=$(lines ra3)
dstart=$(lines rd)
expect_ok ra3 admin-ban "$rd_id" proof ban
expect_event rd '^\{"event":"session_ended",.*"kind":"banned",' "$dstart" \
	"rd did not see session_ended banned" >/dev/null
result=$(expect_event ra3 "^\\{\"event\":\"admin_result\",.*\"action\":\"ban\",\"userID\":$rd_id," \
	"$astart" "ra got no result for the ban")
[[ "$result" == *"removed from 1 encrypted room; 1 encrypted room could not be changed"* &&
	"$result" == *"\"failedRoomIDs\":[$damaged_id]}" ]] ||
	fail "the ban did not report one removal and the damaged room: $result"
removed=$(room_log_line ra3 "$ban_id" '"status":"verified","logVersion":3,' "$astart")
[[ "$removed" == *"\"members\":[$ra_id],"* && "$removed" == *"the server removed $room_dan"* ]] ||
	fail "ra does not see the server's removal of rd: $removed"
astart=$(lines ra3)
expect_ok ra3 send "$ban_id" "$during_ban"
room_message ra3 "$ban_id" "$during_ban" "$astart" >/dev/null
wrapped=$(run_sql "SELECT count(*) FILTER (WHERE $rd_id = ANY (recipient_user_ids)) || '/' ||
	count(*) FROM room_key_envelopes WHERE room_id = $ban_id AND epoch >= 3")
[[ "$wrapped" == 0/* && "$wrapped" != "0/0" ]] ||
	fail "expected envelopes from epoch 3 on without a wrap for rd, got $wrapped"

astart=$(lines ra3)
expect_ok ra3 admin-unban "$rd_id"
expect_event ra3 "^\\{\"event\":\"user_updated\",.*\"id\":$rd_id,.*\"isBanned\":false," \
	"$astart" "ra did not see rd unbanned" >/dev/null
expect_ok rd reconnect
expect_ok rd wait connected 8000
members=$(run_sql "SELECT count(*) FILTER (WHERE room_id = $ban_id) || '/' ||
	count(*) FILTER (WHERE room_id = $damaged_id)
	FROM room_members WHERE user_id = $rd_id")
[[ "$members" == "0/1" ]] ||
	fail "expected rd in the damaged room only after the unban, got $members"
dstart=$(lines rd)
expect_ok rd history "$ban_id"
expect_event rd '^\{"event":"protocol_error",.*"message":"Not a room member"' "$dstart" \
	"the unbanned rd could still read the room's history" >/dev/null
dstart=$(lines rd)
expect_ok rd room-keys "$ban_id" fetch
expect_event rd '^\{"event":"protocol_error",.*"message":"Not a room member"' "$dstart" \
	"the unbanned rd could still fetch the room's keys" >/dev/null
if grep -qF -- "$during_ban" "$work_dir/rd.out"; then
	fail "the unbanned rd saw the message sent during the ban"
fi
stop_client rd

echo "==> [e2ee] managers: a ban removes the only manager; the room keeps talking, nobody adds"
room_frank="e2rf-$run_tag"
start_client rf "$room_frank"
expect_connected rf
expect_ok rf wait room_list 5000
rf_id=$(user_id ra3 "$room_frank")
fetch_keys ra3 "$rf_id" >/dev/null
fetch_keys ra3 "$rc_id" >/dev/null
fetch_keys rc "$ra_id" >/dev/null
fetch_keys rc "$rf_id" >/dev/null
start=$(lines ra3)
expect_ok ra3 room-create "text,admin-invite,encrypted,managers=none" "ban-manager-$run_tag"
created=$(expect_event ra3 \
	"^\\{\"event\":\"room_created\",.*\"name\":\"ban-manager-$run_tag\"" \
	"$start" "ra never got room_created for the manager room")
manager_id=$(field "$created" roomID)
room_log_line ra3 "$manager_id" '"status":"verified","logVersion":1,' "$start" >/dev/null
expect_ok ra3 room-add "$manager_id" "$rf_id"
room_log_line ra3 "$manager_id" '"status":"verified","logVersion":2,' "$start" >/dev/null
cstart=$(lines rc)
expect_ok ra3 room-add "$manager_id" "$rc_id"
room_log_line rc "$manager_id" '"status":"verified","logVersion":3,' "$cstart" >/dev/null
expect_ok ra3 room-manager "$manager_id" "$rf_id" on
room_log_line ra3 "$manager_id" '"status":"verified","logVersion":4,' "$start" >/dev/null
expect_ok ra3 room-manager "$manager_id" "$ra_id" off
only=$(room_log_line rc "$manager_id" '"status":"verified","logVersion":5,' "$cstart")
[[ "$only" == *"\"managers\":[$rf_id],"* ]] || fail "rf is not the room's only manager: $only"

astart=$(lines ra3)
cstart=$(lines rc)
fstart=$(lines rf)
expect_ok ra3 admin-ban "$rf_id" proof ban
expect_event rf '^\{"event":"session_ended",.*"kind":"banned",' "$fstart" \
	"rf did not see session_ended banned" >/dev/null
result=$(expect_event ra3 "^\\{\"event\":\"admin_result\",.*\"action\":\"ban\",\"userID\":$rf_id," \
	"$astart" "ra got no result for rf's ban")
expected="removed from 1 encrypted room; no longer a manager of 1 encrypted room"
expected+=" (1 now with no manager)"
[[ "$result" == *"$expected"* ]] || fail "the ban did not report the manager set it changed: $result"
for client in ra3 rc; do
	if [[ "$client" == ra3 ]]; then
		from=$astart
	else
		from=$cstart
	fi
	demoted=$(room_log_line "$client" "$manager_id" '"status":"verified","logVersion":7,' "$from")
	[[ "$demoted" == *"\"members\":[$ra_id,$rc_id],\"managers\":[],"* &&
		"$demoted" == *"the server removed $room_frank as a manager"* ]] ||
		fail "$client does not see the room left with no manager: $demoted"
done
stop_client rf
no_manager_ra="e2ee-room-marker-no-manager-ra-$run_tag"
no_manager_rc="e2ee-room-marker-no-manager-rc-$run_tag"
cstart=$(lines rc)
expect_ok ra3 send "$manager_id" "$no_manager_ra"
room_message rc "$manager_id" "$no_manager_ra" "$cstart" >/dev/null
astart=$(lines ra3)
expect_ok rc send "$manager_id" "$no_manager_rc"
room_message ra3 "$manager_id" "$no_manager_rc" "$astart" >/dev/null
fetch_keys rc "$re_id" >/dev/null
cstart=$(lines rc)
expect_ok rc room-add "$manager_id" "$re_id"
expect_event rc '^\{"event":"protocol_error",.*"message":"You may not make this change to the member list"' \
	"$cstart" "the server did not refuse rc's add to a room with no manager" >/dev/null
managers=$(run_sql "SELECT count(*) FROM room_log_managers WHERE room_id = $manager_id")
[[ "$managers" == 0 ]] || fail "expected no log manager left in the database, got $managers"
stop_client ra3

for client in re rc; do
	stop_client "$client"
done

echo "==> [e2ee] secrets: no client printed its encryption private key or a plaintext log"
for marker in "$marker_one" "$marker_two" "e2ee-room-marker"; do
	if grep -rqF -- "$marker" "$work_dir"/*.err; then
		fail "a client logged the text of an encrypted message"
	fi
done
for profile in a b m c d ra rb rc; do
	secret=$(config_value "$profile" encryption_private_key)
	[[ ${#secret} -eq 64 ]] || fail "profile $profile has no encryption private key"
	if grep -rqF -- "$secret" "$work_dir"/*.out "$work_dir"/*.err; then
		fail "profile $profile's encryption private key was printed"
	fi
done

stop_client a
echo "==> [e2ee] PASS"
