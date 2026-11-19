#!/usr/bin/env bash
set -euo pipefail

# Live proof of attachment transfers (protocol 26, attachments plan F1) and attachments on
# messages (protocol 27, F2) with two headless client processes (docs/testing-harness.md
# "Attachments") against a running server:
#
#   1. baseline:  A and B each measure their own room message echo time with chat-latency
#                 (no transfer running): p50, p95 and max.
#   2. upload:    A uploads a 25 MiB random file to #general while A and B measure again. The
#                 blob's file is in HAYCHAT_ATTACHMENT_DIR/blobs/<2 hex>/<hex>, mode 0600, with
#                 the file's size, and no part file is left.
#   3. download:  A downloads the blob while both measure again; its sha256 is the file's.
#   4. refusals:  B cannot download A's blob (F1: owner only), and B's upload to a room it is
#                 not in is refused.
#   5. resume:    A starts a second 25 MiB upload, reconnects in the middle, and resumes it with
#                 attach-resume: it continues at the offset the server acknowledged and the
#                 stored blob is the file.
#   6. cancel:    A starts an upload and cancels it: attachment_error cancelled, the part file
#                 is deleted, and attach-resume is refused.
#   7. room:      (F2) A uploads a small file to #general and sends it with a message (send
#                 --attach); B's room_chat lists it with its name and hash (signed, v2), B
#                 saves it by message (attach-download 1 MESSAGE 0 OUT) and, now that it is
#                 bound to a message B can read, by blob too (D10); A's upload is forgotten, so
#                 attaching it again is refused.
#   8. dm:        (F2) A and B exchange an encrypted direct message, then A uploads the file to
#                 the conversation: it is sealed (attachment_done encrypted, the stored blob is
#                 not the file), B's direct_message lists it from inside the seal and B saves
#                 the decrypted file by message.
#   9. encrypted: (F2) A, made an admin, creates an encrypted room and adds B; A sends the
#                 file sealed with a message, B opens the message and saves the decrypted file.
#
# The latency lines it prints ("[attachments] latency ...") are the F1 measurement of control
# packets during a transfer: the plan's main risk is file crypto on the router thread and
# ENet's shared reliable window. A p95 during a transfer above ATTACHMENT_PROOF_P95_LIMIT_MS
# (default 1000) fails the proof.
#
# dev/live-proof.sh --attachments (and --all) runs it against its throwaway server, which
# exports HAYCHAT_ATTACHMENT_DIR. It needs bash, coreutils, sha256sum and (step 9, make_admin)
# psql through the HAYCHAT_DATABASE_* variables.
#
# Usage: dev/attachment-proof.sh [HOST:PORT]   (default 127.0.0.1:12345)

repo_dir=$(cd -- "$(dirname -- "$0")/.." >/dev/null 2>&1 && pwd)
server_address=${1:-127.0.0.1:12345}
command_timeout_secs=60
smoke_label=attachments
p95_limit_ms=${ATTACHMENT_PROOF_P95_LIMIT_MS:-1000}
attachment_dir=${HAYCHAT_ATTACHMENT_DIR:-}

work_dir=$(mktemp -d -t haychat-attachments.XXXXXX)
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

# json_field LINE KEY: the value of a string or number field of one JSON line.
json_field() {
	local line=$1 key=$2
	sed -nE "s/.*\"$key\":(\"([^\"]*)\"|([-0-9.e+]+)).*/\2\3/p" <<<"$line"
}

# send_line CLIENT COMMAND...: sends a command without waiting; prints the output line count
# before it, for wait_for_line.
send_line() {
	local client=$1 start
	shift
	start=$(wc -l <"$work_dir/$client.out")
	printf '%s\n' "$*" >&"${client_fd[$client]}"
	echo "$start"
}

# latency_pair LABEL COUNT: chat-latency on A and B at once; prints and records both results.
latency_pair() {
	local label=$1 count=$2 start_a start_b line client p95
	start_a=$(send_line a "chat-latency 1 $count 50")
	start_b=$(send_line b "chat-latency 1 $count 50")
	for client in a b; do
		local start=$start_a
		[[ $client == b ]] && start=$start_b
		line=$(wait_for_line "$client" '"cmd":"chat-latency"' "$start") ||
			fail "no chat-latency result from $client ($label)"
		[[ "$line" == '{"ok":true,'* ]] || fail "chat-latency failed on $client: $line"
		p95=$(json_field "$line" p95MS)
		printf '[attachments] latency %-9s client %s: received %s/%s p50 %.1f ms p95 %.1f ms max %.1f ms mean %.1f ms\n' \
			"$label" "$client" "$(json_field "$line" received)" "$count" \
			"$(json_field "$line" p50MS)" "$p95" "$(json_field "$line" maxMS)" \
			"$(json_field "$line" meanMS)"
		[[ "$(json_field "$line" received)" == "$count" ]] ||
			fail "client $client lost chat echoes during $label: $line"
		if [[ $label != baseline ]] && awk -v p="$p95" -v l="$p95_limit_ms" 'BEGIN{exit !(p > l)}'; then
			fail "client $client p95 $p95 ms during $label is over ${p95_limit_ms} ms"
		fi
	done
}

expect_event() {
	local client=$1 pattern=$2 start=$3 line
	line=$(wait_for_match "$client" "$pattern" "$start") || fail "client $client: no $pattern"
	echo "    $client< $line" >&2
	printf '%s\n' "$line"
}

echo "==> [attachments] building the client"
odin build "$repo_dir/client" -out:"$client_bin"

big_file="$work_dir/big.bin"
second_file="$work_dir/second.bin"
head -c $((25 * 1024 * 1024)) /dev/urandom >"$big_file"
head -c $((25 * 1024 * 1024)) /dev/urandom >"$second_file"
big_sha=$(sha256sum "$big_file" | cut -d' ' -f1)
second_sha=$(sha256sum "$second_file" | cut -d' ' -f1)

start_client a "att-a-$run_tag"
start_client b "att-b-$run_tag"
expect_connected a
expect_connected b

echo "==> [attachments] 1. baseline latency"
latency_pair baseline 40

echo "==> [attachments] 2. upload 25 MiB while measuring"
upload_start=$(send_line a "attach-upload 1 $big_file")
latency_pair upload 120
done_line=$(expect_event a '"event":"attachment_done".*"direction":"upload"' "$upload_start")
blob=$(json_field "$done_line" blobID)
[[ "$(json_field "$done_line" sha256)" == "$big_sha" ]] || fail "upload hash differs: $done_line"
[[ "$(json_field "$done_line" size)" == $((25 * 1024 * 1024)) ]] || fail "upload size: $done_line"
echo "[attachments] upload of 25 MiB took $(json_field "$done_line" elapsedMS) ms"
if [[ -n "$attachment_dir" ]]; then
	stored="$attachment_dir/blobs/${blob:0:2}/$blob"
	[[ -f "$stored" ]] || fail "expected the blob at $stored"
	[[ "$(stat -c %a "$stored")" == 600 ]] || fail "expected $stored to be mode 0600"
	[[ "$(stat -c %s "$stored")" == $((25 * 1024 * 1024)) ]] || fail "expected 25 MiB stored"
	[[ ! -e "$attachment_dir/incoming/$blob.part" ]] || fail "expected no part file left"
	[[ "$(sha256sum "$stored" | cut -d' ' -f1)" == "$big_sha" ]] || fail "stored bytes differ"
fi

echo "==> [attachments] 3. download while measuring"
out_file="$work_dir/downloaded.bin"
download_start=$(send_line a "attach-download $blob $out_file")
latency_pair download 120
done_line=$(expect_event a '"event":"attachment_done".*"direction":"download"' "$download_start")
[[ "$(json_field "$done_line" sha256)" == "$big_sha" ]] || fail "download hash: $done_line"
[[ "$(sha256sum "$out_file" | cut -d' ' -f1)" == "$big_sha" ]] || fail "downloaded file differs"
[[ ! -e "$out_file.part" ]] || fail "expected the part file renamed away"
echo "[attachments] download of 25 MiB took $(json_field "$done_line" elapsedMS) ms"

echo "==> [attachments] 4. refusals"
start=$(wc -l <"$work_dir/b.out")
expect_ok b "attach-download $blob $work_dir/stolen.bin"
expect_event b '"event":"attachment_error".*"error":"Attachment not found"' "$start" >/dev/null
[[ ! -e "$work_dir/stolen.bin" && ! -e "$work_dir/stolen.bin.part" ]] || fail "B saved a file"
start=$(wc -l <"$work_dir/b.out")
expect_ok b "attach-upload 999999 $big_file"
expect_event b '"event":"attachment_error".*"error":"Not a room member"' "$start" >/dev/null

echo "==> [attachments] 5. resume after a reconnect"
start=$(wc -l <"$work_dir/a.out")
expect_ok a "attach-upload 1 $second_file"
progress=$(expect_event a '"event":"attachment_progress".*"direction":"upload".*"bytes":[1-9]' "$start")
second_blob=$(json_field "$progress" blobID)
start=$(wc -l <"$work_dir/a.out")
expect_ok a reconnect
expect_event a '"event":"attachment_error".*"error":"connection lost"' "$start" >/dev/null
expect_event a '"event":"connected"' "$start" >/dev/null
start=$(wc -l <"$work_dir/a.out")
expect_ok a "attach-resume $second_blob"
resumed=$(expect_event a '"event":"attachment_progress".*"direction":"upload"' "$start")
resumed_at=$(json_field "$resumed" bytes)
((resumed_at > 0)) || fail "expected the resume to continue after byte 0: $resumed"
echo "[attachments] resumed at byte $resumed_at of $((25 * 1024 * 1024))"
done_line=$(expect_event a '"event":"attachment_done".*"direction":"upload"' "$start")
[[ "$(json_field "$done_line" blobID)" == "$second_blob" ]] || fail "resume made a new blob"
[[ "$(json_field "$done_line" sha256)" == "$second_sha" ]] || fail "resumed hash: $done_line"

echo "==> [attachments] 6. cancel"
start=$(wc -l <"$work_dir/a.out")
expect_ok a "attach-upload 1 $second_file"
progress=$(expect_event a '"event":"attachment_progress".*"direction":"upload"' "$start")
cancel_blob=$(json_field "$progress" blobID)
start=$(wc -l <"$work_dir/a.out")
expect_ok a "attach-cancel $cancel_blob"
expect_event a '"event":"attachment_error".*"error":"cancelled"' "$start" >/dev/null
if [[ -n "$attachment_dir" ]]; then
	for _ in $(seq 1 50); do
		[[ -e "$attachment_dir/incoming/$cancel_blob.part" ]] || break
		sleep 0.1
	done
	[[ ! -e "$attachment_dir/incoming/$cancel_blob.part" ]] || fail "expected the part deleted"
fi
start=$(wc -l <"$work_dir/a.out")
expect_ok a "attach-resume $cancel_blob"
expect_event a '"event":"attachment_error"' "$start" >/dev/null

lines() {
	wc -l <"$work_dir/$1.out"
}

# user_id CLIENT NICKNAME: the account ID of NICKNAME from CLIENT's users.
user_id() {
	local client=$1 nickname=$2
	expect_ok "$client" users >&2
	[[ "$last_result" =~ \{\"id\":([0-9]+),\"nickname\":\"$nickname\", ]] ||
		fail "client $client's users do not list $nickname"
	printf '%s\n' "${BASH_REMATCH[1]}"
}

# upload CLIENT TARGET FILE: attach-upload and its attachment_done line.
upload() {
	local client=$1 target=$2 file=$3 start id
	start=$(lines "$client")
	expect_ok "$client" "attach-upload $target $file"
	id=$(json_field "$last_result" id)
	expect_event "$client" "\"event\":\"attachment_done\",\"serverID\":[0-9]+,\"id\":$id," "$start"
}

# download CLIENT ARGS... : attach-download and its attachment_done line.
download() {
	local client=$1 start id
	shift
	start=$(lines "$client")
	expect_ok "$client" "attach-download $*"
	id=$(json_field "$last_result" id)
	expect_event "$client" "\"event\":\"attachment_done\",\"serverID\":[0-9]+,\"id\":$id," "$start"
}

small_file="$work_dir/notes.txt"
printf 'attachment proof %s: a small file for a message\n' "$run_tag" >"$small_file"
small_sha=$(sha256sum "$small_file" | cut -d' ' -f1)
small_size=$(stat -c %s "$small_file")
same_file() {
	[[ "$(sha256sum "$1" | cut -d' ' -f1)" == "$small_sha" && ! -e "$1.part" ]] ||
		fail "expected $1 to be the uploaded file"
}

echo "==> [attachments] 7. a file on a room message"
done_line=$(upload a 1 "$small_file")
[[ "$done_line" == *'"encrypted":false'* ]] || fail "a #general upload was sealed: $done_line"
small_blob=$(json_field "$done_line" blobID)
astart=$(lines a)
bstart=$(lines b)
expect_ok a "send 1 --attach $small_blob a file for b"
chat=$(expect_event b "\"event\":\"room_chat\".*\"attachments\":\[\{\"blobID\":\"$small_blob\"" "$bstart")
[[ "$chat" == *"\"size\":$small_size,\"fileSize\":$small_size,\"sha256\":\"$small_sha\",\"name\":\"notes.txt\",\"mediaType\":\"text/plain\",\"encrypted\":false,\"removed\":false"* ]] ||
	fail "B's room_chat does not list the file as A signed it: $chat"
[[ "$chat" == *'"protection":"plain","content":"a file for b"}' ]] ||
	fail "B did not verify the message: $chat"
message_id=$(json_field "$chat" messageID)
# A's own echo binds the upload, so A forgets it.
expect_event a "\"event\":\"room_chat\",\"serverID\":[0-9]+,\"roomID\":1,\"messageID\":$message_id," "$astart" >/dev/null
download b 1 "$message_id" 0 "$work_dir/b-notes.txt" >/dev/null
same_file "$work_dir/b-notes.txt"
download b "$small_blob" "$work_dir/b-blob.txt" >/dev/null
same_file "$work_dir/b-blob.txt"
again=$(client_command a "send 1 --attach $small_blob again") || fail "no answer to a second send"
[[ "$again" == '{"ok":false,'*'not uploaded to this conversation'* ]] ||
	fail "expected a bound upload refused for a second message: $again"

echo "==> [attachments] 8. an encrypted file on a direct message"
a_id=$(user_id b "att-a-$run_tag")
b_id=$(user_id a "att-b-$run_tag")
bstart=$(lines b)
expect_ok a "dm $b_id keys for the file"
expect_event b '"event":"direct_message".*"protection":"encrypted","content":"keys for the file"}' \
	"$bstart" >/dev/null
done_line=$(upload a "@$b_id" "$small_file")
[[ "$done_line" == *'"encrypted":true'* && "$done_line" == *"\"fileSize\":$small_size}"* ]] ||
	fail "the direct message upload was not sealed: $done_line"
secret_blob=$(json_field "$done_line" blobID)
stored_size=$(json_field "$done_line" size)
((stored_size > small_size)) || fail "expected the sealed blob larger than the file"
if [[ -n "$attachment_dir" ]]; then
	stored="$attachment_dir/blobs/${secret_blob:0:2}/$secret_blob"
	[[ "$(stat -c %s "$stored")" == "$stored_size" ]] || fail "expected $stored_size stored bytes"
	! grep -q "attachment proof" "$stored" || fail "the server stored the file in the clear"
fi
bstart=$(lines b)
expect_ok a "dm $b_id --attach $secret_blob"
dm=$(expect_event b "\"event\":\"direct_message\".*\"attachments\":\[\{\"blobID\":\"$secret_blob\"" "$bstart")
[[ "$dm" == *"\"size\":$stored_size,\"fileSize\":$small_size,"*'"name":"notes.txt"'*'"encrypted":true,"removed":false'* ]] ||
	fail "B's direct message does not list the sealed file: $dm"
[[ "$dm" == *'"attachmentsChanged":false,"encrypted":true'*'"protection":"encrypted","content":""}' ]] ||
	fail "B did not open the files-only message: $dm"
download b "@$a_id" "$(json_field "$dm" id)" 0 "$work_dir/b-secret.txt" >/dev/null
same_file "$work_dir/b-secret.txt"

echo "==> [attachments] 9. an encrypted file in an encrypted room"
make_admin "att-a-$run_tag"
expect_ok a reconnect
expect_ok a wait connected 8000
expect_ok a wait room_list 5000
astart=$(lines a)
expect_ok a room-create "text,admin-invite,encrypted,managers=none" "files-$run_tag"
created=$(expect_event a "\"event\":\"room_created\".*\"name\":\"files-$run_tag\"" "$astart")
room_id=$(json_field "$created" roomID)
expect_event a "\"event\":\"room_log\",\"serverID\":[0-9]+,\"roomID\":$room_id,\"status\":\"verified\",\"logVersion\":1," \
	"$astart" >/dev/null
bstart=$(lines b)
expect_ok a room-add "$room_id" "$b_id"
expect_event b "\"event\":\"room_log\",\"serverID\":[0-9]+,\"roomID\":$room_id,\"status\":\"verified\",\"logVersion\":2," \
	"$bstart" >/dev/null
done_line=$(upload a "$room_id" "$small_file")
[[ "$done_line" == *'"encrypted":true'* ]] || fail "the encrypted room's upload was not sealed"
vault_blob=$(json_field "$done_line" blobID)
bstart=$(lines b)
expect_ok a "send $room_id --attach $vault_blob in the vault"
opened=$(expect_event b "\"event\":\"room_(chat|opened)\",\"serverID\":[0-9]+,\"roomID\":$room_id,.*\"attachments\":\[\{\"blobID\":\"$vault_blob\"" "$bstart")
[[ "$opened" == *'"encrypted":true,"removed":false}],"attachmentsChanged":false,"encrypted":true'*'"protection":"encrypted","content":"in the vault"}' ]] ||
	fail "B did not open the sealed room message with its file: $opened"
download b "$room_id" "$(json_field "$opened" messageID)" 0 "$work_dir/b-vault.txt" >/dev/null
same_file "$work_dir/b-vault.txt"

stop_client a
stop_client b
echo "==> [attachments] PASS"
