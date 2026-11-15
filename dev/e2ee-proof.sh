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
#   4. secrets: no client ever printed its encryption private key.
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

echo "==> [e2ee] secrets: no client printed its encryption private key"
for profile in a b m; do
	secret=$(config_value "$profile" encryption_private_key)
	[[ ${#secret} -eq 64 ]] || fail "profile $profile has no encryption private key"
	if grep -rqF -- "$secret" "$work_dir"/*.out "$work_dir"/*.err; then
		fail "profile $profile's encryption private key was printed"
	fi
done

stop_client a
echo "==> [e2ee] PASS"
