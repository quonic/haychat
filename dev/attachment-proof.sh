#!/usr/bin/env bash
set -euo pipefail

# Live proof of file attachments (protocols 26-28, attachments plan F1-F5) with headless client
# processes (docs/testing-harness.md "Attachments"). Steps 1-10 run against the server
# dev/live-proof.sh started; steps 11-16 against a second server this script starts itself, on a
# fresh database it creates and drops, with small limits and its own blob directory, so the
# CI server's limits stay as they are and the proof may restart it.
#
#   1. baseline:  A and B each measure their own room message echo time with chat-latency
#                 (no transfer running): p50, p95 and max.
#   2. upload:    A uploads a 25 MiB random file to #general while A and B measure again. The
#                 blob's file is in HAYCHAT_ATTACHMENT_DIR/blobs/<2 hex>/<hex>, mode 0600, with
#                 the file's size, and no part file is left.
#   3. download:  A downloads the blob while both measure again; its sha256 is the file's.
#   4. refusals:  B cannot download A's unbound blob (only its owner may, D10), and B's upload
#                 to a room that does not exist is refused. (#132) A sends a small file with a
#                 message and the proof deletes its stored file: B's download is "Attachment
#                 not found", not a storage error, and the server makes the row a Removed
#                 tombstone with no admin: A and B (the readers) hear attachment_removed, B's
#                 history lists it removed, and B's next download is refused at the check
#                 (step 10 finds it in the removal log with no admin).
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
#  10. removal:   (F3, protocol 28) B sends a 25 MiB file to #general and starts saving it;
#                 admin A removes it mid-download (attach-remove): B's download ends with
#                 "Attachment removed by an admin", A and B (the readers) hear
#                 attachment_removed, the file is gone from the blob directory, B's history
#                 lists it removed with its signed fields, saving it again is refused, and A's
#                 attach-usage shows B's 25 MiB freed. B, not an admin, cannot remove anything.
#                 Then the operator helpers: deploy/sql/attachment-usage.sql lists the
#                 accounts, and deploy/sql/remove-attachment.sql removes A's step 7 file, which
#                 B's next history fetch lists as removed and the server refuses to send.
#                 (Protocol 29, #138) attachment_removed names the message
#                 (chatMessageID), and A's attach-removals lists both removals newest first:
#                 the helper's with no admin and its -v reason, then A's with A's reason; the
#                 cursor pages past the first, and B, not an admin, is refused the list. (#132
#                 follow-up) Step 4's missing file follows A's, with no admin and the reason
#                 "File missing from storage".
#  11. limits:    (F5) the second server allows 2 MiB per file and 3 MiB per account at a pace of
#                 512 KiB/s. C's client refuses a file one byte over the size and, after C
#                 stored 2 MiB, a 1.5 MiB file over the quota (D18); with attach-upload
#                 --unchecked the server refuses both itself, with the same sentences.
#  12. access:    (F5) admin D makes a Member invite, From join room and sends a file there. C,
#                 not a member, is refused an upload to the room and the file. D adds C: the
#                 file from before C joined is still refused (From join, D10), a file D sends
#                 after it C saves by message and by blob.
#  13. AttachFiles: (F5) C uploads a file to the room, then D takes AttachFiles from everyone
#                 (room-permissions-set ROOM send,speak): C's next upload is refused at begin,
#                 the message that names C's finished upload is refused at binding, and C's
#                 text still posts.
#  14. kill:      (F5, D9) K starts an upload and its client process is killed mid-file. A new
#                 process with K's profile cannot resume it ("only an upload this process
#                 started can be resumed": the client keeps no state about uploads on disk),
#                 and a fresh upload of the same file succeeds as a new blob. The old blob stays
#                 Uploading, its part file in incoming/, until the sweeper deletes it (step 15).
#  15. sweep:     (F5, D17) D deletes the room. The proof stops the second server, backdates
#                 rows in its throwaway database with psql (the room's two bound files, K's
#                 stale upload, C's unbound upload in the room past the pending window, and two
#                 controls), puts a two-hour-old orphan file in the blob directory, and starts
#                 the server again: the startup sweep deletes exactly those four rows and their
#                 files, the startup scan the orphan, and the controls (a bound file of a live
#                 #general message, and an unbound upload within the pending window) stay and
#                 the first still downloads.
#  16. guards:    (#131) the startup scan's guards against a wrong restore order. With every
#                 file made two hours old, 12 planted files without a row (over the floor of
#                 10 and over 10% of the files) are kept with a warning; after the rows are
#                 deleted with psql (an empty table) every file is kept with the empty-table
#                 warning; one start with HAYCHAT_ATTACHMENT_ALLOW_ORPHAN_PURGE=1 deletes them
#                 all.
#
# The latency lines it prints ("[attachments] latency ...") measure control packets during a
# transfer: the plan's main risk is file crypto on the router thread and ENet's shared reliable
# window. A p95 during a transfer above ATTACHMENT_PROOF_P95_LIMIT_MS (default 250; measured p95s
# have been 11-16 ms) fails the proof.
#
# dev/live-proof.sh --attachments (and --all) runs it against its throwaway server, which
# exports HAYCHAT_ATTACHMENT_DIR, and passes its server binary in HAYCHAT_SERVER_BIN (without it
# the proof builds the server). It needs bash, coreutils, sha256sum and psql through the
# HAYCHAT_DATABASE_* variables (make_admin, the deploy/sql helpers, and the second server's
# database, which needs a role with CREATEDB). The second server listens on
# HAYCHAT_ATTACHMENT_PROOF_PORT (default 12347).
#
# Usage: dev/attachment-proof.sh [HOST:PORT]   (default 127.0.0.1:12345)

repo_dir=$(cd -- "$(dirname -- "$0")/.." >/dev/null 2>&1 && pwd)
server_address=${1:-127.0.0.1:12345}
command_timeout_secs=60
smoke_label=attachments
p95_limit_ms=${ATTACHMENT_PROOF_P95_LIMIT_MS:-250}
attachment_dir=${HAYCHAT_ATTACHMENT_DIR:-}
ready_timeout_secs=${HAYCHAT_SERVER_READY_TIMEOUT_SECS:-60}
limits_port=${HAYCHAT_ATTACHMENT_PROOF_PORT:-12347}

work_dir=$(mktemp -d -t haychat-attachments.XXXXXX)
client_bin="$work_dir/haychat-client"
run_tag=$(date +%s%N)
run_tag=${run_tag: -9}

limits_db="haychat_attproof_$run_tag"
limits_db_created=false
limits_pid=""
limits_dir="$work_dir/limits"
limits_log="$limits_dir/server.log"

declare -A client_pid=()
declare -A client_fd=()

# main_psql ARGS...: psql against the HAYCHAT_DATABASE_* server's maintenance connection (the
# CI server's database), for creating and dropping the second server's database.
main_psql() {
	PGPASSWORD="${HAYCHAT_DATABASE_PASS:-haychat}" psql -q -X -t -A -v ON_ERROR_STOP=1 \
		-h "${HAYCHAT_DATABASE_URL:-localhost}" -p "${HAYCHAT_DATABASE_PORT:-5432}" \
		-U "${HAYCHAT_DATABASE_USER:-haychat}" -d "${HAYCHAT_DATABASE_NAME:-haychat}" "$@"
}

stop_limits_server() {
	if [[ -z "$limits_pid" ]] || ! kill -0 "$limits_pid" 2>/dev/null; then
		limits_pid=""
		return 0
	fi
	kill -INT "$limits_pid" 2>/dev/null || true
	for _ in $(seq 1 50); do
		kill -0 "$limits_pid" 2>/dev/null || break
		sleep 0.1
	done
	kill -KILL "$limits_pid" 2>/dev/null || true
	wait "$limits_pid" 2>/dev/null || true
	limits_pid=""
}

on_exit() {
	local status=$? client
	for client in "${!client_pid[@]}"; do
		kill "${client_pid[$client]}" 2>/dev/null || true
	done
	stop_limits_server
	if [[ $status -ne 0 ]]; then
		print_client_output
		if [[ -f "$limits_log" ]]; then
			echo "---- second server log ($limits_log) ----" >&2
			cat "$limits_log" >&2 || true
			echo "---- end second server log ----" >&2
		fi
	fi
	if [[ "$limits_db_created" == true ]]; then
		main_psql -c "DROP DATABASE IF EXISTS $limits_db WITH (FORCE)" >/dev/null ||
			echo "could not drop the database $limits_db" >&2
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
	expect_ok "$client" "attach-upload $target $file" >&2
	id=$(json_field "$last_result" id)
	expect_event "$client" "\"event\":\"attachment_done\",\"serverID\":[0-9]+,\"id\":$id," "$start"
}

# download CLIENT ARGS... : attach-download and its attachment_done line.
download() {
	local client=$1 start id
	shift
	start=$(lines "$client")
	expect_ok "$client" "attach-download $*" >&2
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

echo "==> [attachments] 4. refusals of the unbound blob and a missing room"
start=$(wc -l <"$work_dir/b.out")
expect_ok b "attach-download $blob $work_dir/stolen.bin"
expect_event b '"event":"attachment_error".*"error":"Attachment not found"' "$start" >/dev/null
[[ ! -e "$work_dir/stolen.bin" && ! -e "$work_dir/stolen.bin.part" ]] || fail "B saved a file"
start=$(wc -l <"$work_dir/b.out")
expect_ok b "attach-upload 999999 $big_file"
expect_event b '"event":"attachment_error".*"error":"Not a room member"' "$start" >/dev/null
# (#132) A row whose file is gone (a restore without the blob directory) is "Attachment not
# found", not "Server storage error", and (its follow-up) the server then makes the row a
# Removed tombstone with no admin: its readers hear attachment_removed and later downloads are
# refused at the check. A dedicated small file on its own message, so no later step needs it;
# step 10 finds its row in the removal log once A is an admin.
a_id=$(user_id b "att-a-$run_tag")
b_id=$(user_id a "att-b-$run_tag")
missing_blob=""
if [[ -n "$attachment_dir" ]]; then
	missing_file="$work_dir/missing.txt"
	printf 'attachment proof %s: a file the server loses\n' "$run_tag" >"$missing_file"
	missing_size=$(stat -c %s "$missing_file")
	missing_sha=$(sha256sum "$missing_file" | cut -d' ' -f1)
	done_line=$(upload a 1 "$missing_file")
	missing_blob=$(json_field "$done_line" blobID)
	bstart=$(lines b)
	expect_ok a "send 1 --attach $missing_blob a file the server loses"
	chat=$(expect_event b "\"event\":\"room_chat\".*\"attachments\":\[\{\"blobID\":\"$missing_blob\"" "$bstart")
	missing_message=$(json_field "$chat" messageID)
	rm -- "$attachment_dir/blobs/${missing_blob:0:2}/$missing_blob"
	astart=$(lines a)
	bstart=$(lines b)
	expect_ok b "attach-download $missing_blob $work_dir/missing.bin"
	expect_event b '"event":"attachment_error".*"error":"Attachment not found"' "$bstart" >/dev/null
	[[ ! -e "$work_dir/missing.bin" && ! -e "$work_dir/missing.bin.part" ]] ||
		fail "B saved a file whose blob is missing"
	for client in a b; do
		start=$astart
		[[ $client == b ]] && start=$bstart
		expect_event "$client" "\"event\":\"attachment_removed\",\"serverID\":[0-9]+,\"blobID\":\"$missing_blob\",\"roomID\":1,\"senderID\":$a_id,\"recipientID\":0,\"chatMessageID\":$missing_message,\"directMessageID\":0}" \
			"$start" >/dev/null
	done
	# The tombstone keeps the signed fields; the next download is refused at the check.
	hstart=$(lines b)
	expect_ok b "history 1"
	history=$(expect_event b '"event":"room_history","serverID":[0-9]+,"roomID":1,' "$hstart")
	[[ "$history" == *"{\"blobID\":\"$missing_blob\",\"size\":$missing_size,\"fileSize\":$missing_size,\"sha256\":\"$missing_sha\",\"name\":\"missing.txt\",\"mediaType\":\"text/plain\",\"encrypted\":false,\"removed\":true}"* ]] ||
		fail "expected B's history to list the missing file removed with its signed fields"
	start=$(lines b)
	expect_ok b "attach-download $missing_blob $work_dir/missing-again.bin"
	expect_event b '"event":"attachment_error".*"error":"Attachment removed by an admin"' \
		"$start" >/dev/null
	echo "[attachments] the missing file became a tombstone its readers heard of"
fi

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

# proof_psql ARGS...: psql against the server's database (the variables make_admin uses).
proof_psql() {
	PGPASSWORD="${HAYCHAT_DATABASE_PASS:-haychat}" psql -q -X -v ON_ERROR_STOP=1 \
		-h "${HAYCHAT_DATABASE_URL:-localhost}" -p "${HAYCHAT_DATABASE_PORT:-5432}" \
		-U "${HAYCHAT_DATABASE_USER:-haychat}" -d "${HAYCHAT_DATABASE_NAME:-haychat}" "$@"
}

# usage_bytes CLIENT USER_ID: the stored bytes attach-usage reports for USER_ID (0 if unlisted).
usage_bytes() {
	local client=$1 user=$2 start line
	start=$(lines "$client")
	expect_ok "$client" attach-usage >&2
	line=$(expect_event "$client" '"event":"attachment_usage"' "$start")
	[[ "$line" == *'"freeBytesKnown":true'* ]] || fail "expected the free space known: $line"
	if [[ "$line" =~ \{\"userID\":$user,\"bytes\":([0-9]+), ]]; then
		printf '%s\n' "${BASH_REMATCH[1]}"
	else
		printf '0\n'
	fi
}

echo "==> [attachments] 10. an admin removes a file (protocol 28)"
done_line=$(upload b 1 "$big_file")
big_blob=$(json_field "$done_line" blobID)
astart=$(lines a)
expect_ok b "send 1 --attach $big_blob a large file"
chat=$(expect_event a "\"event\":\"room_chat\".*\"attachments\":\[\{\"blobID\":\"$big_blob\"" "$astart")
big_message=$(json_field "$chat" messageID)
b_before=$(usage_bytes a "$b_id")
((b_before >= 25 * 1024 * 1024)) || fail "expected B's 25 MiB in the usage, got $b_before"
echo "[attachments] B stores $b_before bytes before the removal"
bstart=$(lines b)
expect_ok b "attach-download 1 $big_message 0 $work_dir/b-big.bin"
expect_event b '"event":"attachment_progress".*"direction":"download".*"bytes":[1-9]' "$bstart" \
	>/dev/null
astart=$(lines a)
removal_start=$(lines b)
expect_ok a "attach-remove $big_blob proof of a removal"
expect_event a "\"event\":\"admin_result\".*\"action\":\"attachment-remove\",\"userID\":$b_id,.*\"blobID\":\"$big_blob\"" \
	"$astart" >/dev/null
error_line=$(expect_event b '"event":"attachment_error".*"direction":"download"' "$bstart")
[[ "$error_line" == *'"error":"Attachment removed by an admin"'* ]] ||
	fail "expected B's download ended by the removal: $error_line"
[[ ! -e "$work_dir/b-big.bin" && ! -e "$work_dir/b-big.bin.part" ]] ||
	fail "expected B's cut-off download to leave no file"
for client in a b; do
	start=$astart
	[[ $client == b ]] && start=$removal_start
	expect_event "$client" "\"event\":\"attachment_removed\",\"serverID\":[0-9]+,\"blobID\":\"$big_blob\",\"roomID\":1,\"senderID\":$b_id,\"recipientID\":0,\"chatMessageID\":$big_message,\"directMessageID\":0}" \
		"$start" >/dev/null
done
if [[ -n "$attachment_dir" ]]; then
	stored="$attachment_dir/blobs/${big_blob:0:2}/$big_blob"
	for _ in $(seq 1 50); do
		[[ -e "$stored" ]] || break
		sleep 0.1
	done
	[[ ! -e "$stored" ]] || fail "expected the removed file deleted from $stored"
fi
hstart=$(lines b)
expect_ok b "history 1"
history=$(expect_event b '"event":"room_history","serverID":[0-9]+,"roomID":1,' "$hstart")
[[ "$history" == *"{\"blobID\":\"$big_blob\",\"size\":$((25 * 1024 * 1024)),\"fileSize\":$((25 * 1024 * 1024)),\"sha256\":\"$big_sha\",\"name\":\"big.bin\",\"mediaType\":\"application/octet-stream\",\"encrypted\":false,\"removed\":true}"* ]] ||
	fail "expected B's history to list the file removed with its signed fields"
again=$(client_command b "attach-download 1 $big_message 0 $work_dir/b-big-again.bin") ||
	fail "no answer to a second download"
[[ "$again" == '{"ok":false,'*'Attachment removed by an admin'* ]] ||
	fail "expected the removed file refused by the client: $again"
start=$(lines b)
expect_ok b "attach-download $big_blob $work_dir/b-big-raw.bin"
expect_event b '"event":"attachment_error".*"error":"Attachment removed by an admin"' "$start" \
	>/dev/null
b_after=$(usage_bytes a "$b_id")
((b_before - b_after == 25 * 1024 * 1024)) ||
	fail "expected the removal to free B's 25 MiB, $b_before -> $b_after"
echo "[attachments] B stores $b_after bytes after the removal"
start=$(lines b)
expect_ok b "attach-remove $small_blob not an admin"
expect_event b '"event":"protocol_error".*"Admin permission required"' "$start" >/dev/null

# removals_page CLIENT [BEFORE_ID]: the attachment_removals line answering attach-removals.
removals_page() {
	local client=$1 before=${2:-} start
	start=$(lines "$client")
	expect_ok "$client" "attach-removals${before:+ $before}" >&2
	expect_event "$client" "\"event\":\"attachment_removals\",\"serverID\":[0-9]+,\"beforeID\":${before:-0}," \
		"$start"
}
# removal_entry BLOB OWNER REMOVER REASON MESSAGE NAME: one entry of an attachment_removals line.
removal_entry() {
	printf '"blobID":"%s","ownerID":%s,"removedByID":%s,"removedAt":"[^"]+","reason":"%s","roomID":1,"direct":false,"encrypted":false,"chatMessageID":%s,"directMessageID":0,"name":"%s"' \
		"$1" "$2" "$3" "$4" "$5" "$6"
}
page=$(removals_page a)
[[ "$page" =~ \"entries\":\[\{\"id\":[0-9]+,$(removal_entry "$big_blob" "$b_id" "$a_id" \
	"proof of a removal" "$big_message" big.bin)\} ]] ||
	fail "expected A's removal first in the removal log: $page"
start=$(lines b)
expect_ok b "attach-removals"
expect_event b '"event":"protocol_error".*"Admin permission required"' "$start" >/dev/null

# The operator helpers: usage lists both accounts, and a removal in SQL reaches B on its next
# history fetch (the file goes with the server's hourly pass, or its next start).
usage_out=$(proof_psql -v limit=10 -f "$repo_dir/deploy/sql/attachment-usage.sql")
grep -q "att-a-$run_tag" <<<"$usage_out" || fail "attachment-usage.sql does not list A: $usage_out"
owner_out=$(proof_psql -v owner="att-a-$run_tag" -f "$repo_dir/deploy/sql/attachment-usage.sql")
grep -q "$small_blob" <<<"$owner_out" || fail "attachment-usage.sql -v owner does not list A's file"
proof_psql -v blob="$small_blob" -v reason="Removed by the operator" \
	-f "$repo_dir/deploy/sql/remove-attachment.sql" >/dev/null 2>&1 ||
	fail "remove-attachment.sql failed"
if proof_psql -v blob="$small_blob" -f "$repo_dir/deploy/sql/remove-attachment.sql" \
	>/dev/null 2>&1; then
	fail "remove-attachment.sql removed an already removed attachment"
fi
hstart=$(lines b)
expect_ok b "history 1"
history=$(expect_event b '"event":"room_history","serverID":[0-9]+,"roomID":1,' "$hstart")
[[ "$history" == *"{\"blobID\":\"$small_blob\",\"size\":$small_size,\"fileSize\":$small_size,\"sha256\":\"$small_sha\",\"name\":\"notes.txt\",\"mediaType\":\"text/plain\",\"encrypted\":false,\"removed\":true}"* ]] ||
	fail "expected B's next history fetch to list the SQL removal"
start=$(lines b)
expect_ok b "attach-download $small_blob $work_dir/b-small-raw.bin"
expect_event b '"event":"attachment_error".*"error":"Attachment removed by an admin"' "$start" \
	>/dev/null
# The helper's removal heads the log, with no admin and its reason; A's follows, also on the
# page before it.
page=$(removals_page a)
[[ "$page" =~ \"entries\":\[\{\"id\":([0-9]+),$(removal_entry "$small_blob" "$a_id" 0 \
	"Removed by the operator" "$message_id" notes.txt)\},\{\"id\":[0-9]+,$(removal_entry \
	"$big_blob" "$b_id" "$a_id" "proof of a removal" "$big_message" big.bin)\} ]] ||
	fail "expected the SQL helper's removal first, with no admin: $page"
helper_id=${BASH_REMATCH[1]}
older=$(removals_page a "$helper_id")
[[ "$older" =~ \"entries\":\[\{\"id\":[0-9]+,$(removal_entry "$big_blob" "$b_id" "$a_id" \
	"proof of a removal" "$big_message" big.bin)\} ]] ||
	fail "expected the page before the helper's removal to start with A's: $older"
# (#132 follow-up) Step 4's missing file follows, removed by no admin with the server's reason.
if [[ -n "$missing_blob" ]]; then
	[[ "$older" =~ $(removal_entry "$big_blob" "$b_id" "$a_id" "proof of a removal" \
		"$big_message" big.bin)\},\{\"id\":[0-9]+,$(removal_entry "$missing_blob" "$a_id" 0 \
		"File missing from storage" "$missing_message" missing.txt)\} ]] ||
		fail "expected the missing file's removal after A's, with no admin: $older"
fi
echo "[attachments] the removal log lists the SQL helper's removal and A's, newest first"

stop_client a
stop_client b

# ── Steps 11-15: a second server this script owns (F5) ────────────────────────────────────

MIB=$((1024 * 1024))
LIMIT_MAX_BYTES=$((2 * MIB))
LIMIT_QUOTA_BYTES=$((3 * MIB))

# limits_sql SQL: runs SQL against the second server's database and prints the result.
limits_sql() {
	HAYCHAT_DATABASE_NAME=$limits_db main_psql -c "$1" || fail "SQL failed: $1"
}

wait_limits_ready() {
	local deadline=$((SECONDS + ready_timeout_secs))
	while ((SECONDS < deadline)); do
		grep -Fq "=== Server Running ===" "$limits_log" && return 0
		grep -Fq "[Startup]" "$limits_log" && fail "the second server failed during startup"
		kill -0 "$limits_pid" 2>/dev/null || fail "the second server exited before it was ready"
		sleep 0.1
	done
	fail "the second server was not ready after ${ready_timeout_secs}s"
}

# start_limits_server [ALLOW_PURGE]: starts (or starts again) the second server on its own
# database, port, state and blob directory, with small limits. ALLOW_PURGE (default false) is
# HAYCHAT_ATTACHMENT_ALLOW_ORPHAN_PURGE. The log starts empty on every start.
start_limits_server() {
	: >"$limits_log"
	HAYCHAT_ATTACHMENT_ALLOW_ORPHAN_PURGE=${1:-false} \
		HAYCHAT_DATABASE_NAME=$limits_db HAYCHAT_LISTEN_PORT=$limits_port \
		HAYCHAT_LOG_DIR="$limits_dir/logs" HAYCHAT_FILE_STORAGE_PATH="$limits_dir/storage" \
		HAYCHAT_SERVER_IDENTITY_FILE="$limits_dir/storage/server_identity.json" \
		HAYCHAT_ATTACHMENT_DIR="$limits_dir/attachments" \
		HAYCHAT_ATTACHMENT_MAX_BYTES=$LIMIT_MAX_BYTES \
		HAYCHAT_ATTACHMENT_ACCOUNT_QUOTA_BYTES=$LIMIT_QUOTA_BYTES \
		HAYCHAT_ATTACHMENT_SESSION_BYTES_PER_SECOND=$((512 * 1024)) \
		HAYCHAT_ATTACHMENT_MIN_FREE_BYTES=$((64 * MIB)) \
		"$server_bin" >"$limits_log" 2>&1 &
	limits_pid=$!
	wait_limits_ready
}

# blob_path BLOB: the second server's stored file of BLOB.
blob_path() {
	printf '%s/attachments/blobs/%s/%s\n' "$limits_dir" "${1:0:2}" "$1"
}

# expect_upload_error CLIENT TARGET FILE MESSAGE [--unchecked]: an accepted attach-upload that
# the server refuses with MESSAGE.
expect_upload_error() {
	local client=$1 target=$2 file=$3 message=$4 option=${5:-} start id
	start=$(lines "$client")
	expect_ok "$client" "attach-upload $target $option $file"
	id=$(json_field "$last_result" id)
	expect_event "$client" \
		"\"event\":\"attachment_error\",\"serverID\":[0-9]+,\"id\":$id,.*\"error\":\"$message\"" \
		"$start" >/dev/null
}

# expect_download_error CLIENT BLOB MESSAGE: attach-download of a raw blob the server refuses.
expect_download_error() {
	local client=$1 blob=$2 message=$3 start id
	start=$(lines "$client")
	expect_ok "$client" "attach-download $blob $work_dir/refused-$blob.bin"
	id=$(json_field "$last_result" id)
	expect_event "$client" \
		"\"event\":\"attachment_error\",\"serverID\":[0-9]+,\"id\":$id,.*\"error\":\"$message\"" \
		"$start" >/dev/null
	[[ ! -e "$work_dir/refused-$blob.bin" ]] || fail "client $client saved a refused file"
}

# same_bytes A B: whether files A and B have the same bytes (the image has no cmp).
same_bytes() {
	[[ "$(sha256sum <"$1")" == "$(sha256sum <"$2")" ]]
}

# expect_client_refusal CLIENT COMMAND MESSAGE: a command the client itself refuses.
expect_client_refusal() {
	local client=$1 command=$2 message=$3 result
	result=$(client_command "$client" "$command") || fail "client $client: no result for $command"
	echo "    $client> $command"
	echo "    $client< $result"
	[[ "$result" == '{"ok":false,'*"\"error\":\"$message\""* ]] ||
		fail "client $client did not refuse \`$command\` with \"$message\": $result"
}

server_bin=${HAYCHAT_SERVER_BIN:-}
if [[ -z "$server_bin" ]]; then
	echo "==> [attachments] building the server (HAYCHAT_SERVER_BIN is not set)"
	server_bin="$work_dir/haychat-server"
	odin build "$repo_dir/server" -out:"$server_bin"
fi

echo "==> [attachments] 11. a second server with small limits refuses size and quota"
main_psql -c "CREATE DATABASE $limits_db" >/dev/null ||
	fail "could not create the database $limits_db (the role needs CREATEDB)"
limits_db_created=true
mkdir -p "$limits_dir/storage" "$limits_dir/logs"
start_limits_server
limits_address="127.0.0.1:$limits_port"
nick_c="att-c-$run_tag"
nick_d="att-d-$run_tag"
nick_k="att-k-$run_tag"
start_client_at d "$nick_d" "$limits_address"
start_client_at c "$nick_c" "$limits_address"
start_client_at k "$nick_k" "$limits_address"
expect_connected d
expect_connected c
expect_connected k
HAYCHAT_DATABASE_NAME=$limits_db make_admin "$nick_d"
expect_ok d reconnect
expect_ok d wait connected 8000
expect_ok d wait room_list 5000
c_id=$(user_id d "$nick_c")

over_size="$work_dir/over-size.bin"
fill_file="$work_dir/fill.bin"
over_quota="$work_dir/over-quota.bin"
head -c $((LIMIT_MAX_BYTES + 1)) /dev/urandom >"$over_size"
head -c "$LIMIT_MAX_BYTES" /dev/urandom >"$fill_file"
head -c $((3 * MIB / 2)) /dev/urandom >"$over_quota"
expect_client_refusal c "attach-upload 1 $over_size" "Attachment is too large"
expect_upload_error c 1 "$over_size" "Attachment is too large" --unchecked
fill_done=$(upload c 1 "$fill_file")
fill_blob=$(json_field "$fill_done" blobID)
expect_client_refusal c "attach-upload 1 $over_quota" "Attachment storage quota exceeded"
expect_upload_error c 1 "$over_quota" "Attachment storage quota exceeded" --unchecked
rows=$(limits_sql "SELECT count(*) FROM attachments WHERE owner_user_id = $c_id")
[[ "$rows" == 1 ]] || fail "expected only C's 2 MiB upload stored, found $rows rows"

echo "==> [attachments] 12. a non-member and a From join newcomer are refused older files"
dstart=$(lines d)
expect_ok d room-create "text,member-invite,from-join" "join-$run_tag"
created=$(expect_event d "\"event\":\"room_created\".*\"name\":\"join-$run_tag\"" "$dstart")
join_room=$(json_field "$created" roomID)
old_file="$work_dir/old.txt"
new_file="$work_dir/new.txt"
printf 'sent before C joined %s\n' "$run_tag" >"$old_file"
printf 'sent after C joined %s\n' "$run_tag" >"$new_file"
old_blob=$(json_field "$(upload d "$join_room" "$old_file")" blobID)
dstart=$(lines d)
expect_ok d "send $join_room --attach $old_blob before c joined"
expect_event d "\"event\":\"room_chat\".*\"roomID\":$join_room,.*\"blobID\":\"$old_blob\"" \
	"$dstart" >/dev/null
expect_upload_error c "$join_room" "$new_file" "Not a room member"
expect_download_error c "$old_blob" "Attachment not found"
cstart=$(lines c)
expect_ok d room-add "$join_room" "$c_id"
pattern="^\\{\"event\":\"room_membership\",\"serverID\":[0-9]+,\"roomID\":$join_room,"
expect_event c "$pattern\"joined\":true," "$cstart" >/dev/null
expect_download_error c "$old_blob" "Attachment not found"
new_blob=$(json_field "$(upload d "$join_room" "$new_file")" blobID)
cstart=$(lines c)
expect_ok d "send $join_room --attach $new_blob after c joined"
pattern="\"event\":\"room_(chat|opened)\".*\"roomID\":$join_room,.*\"blobID\":\"$new_blob\""
chat=$(expect_event c "$pattern" "$cstart")
download c "$join_room" "$(json_field "$chat" messageID)" 0 "$work_dir/c-new.txt" >/dev/null
same_bytes "$new_file" "$work_dir/c-new.txt" || fail "C's saved file is not D's"
download c "$new_blob" "$work_dir/c-new-blob.txt" >/dev/null
same_bytes "$new_file" "$work_dir/c-new-blob.txt" || fail "C's saved blob is not D's file"

echo "==> [attachments] 13. AttachFiles taken away: begin and binding are refused"
held_file="$work_dir/held.txt"
printf 'uploaded before AttachFiles went %s\n' "$run_tag" >"$held_file"
held_blob=$(json_field "$(upload c "$join_room" "$held_file")" blobID)
dstart=$(lines d)
cstart=$(lines c)
expect_ok d room-permissions-set "$join_room" send,speak
pattern="^\\{\"event\":\"room_permissions\",\"serverID\":[0-9]+,\"roomID\":$join_room,"
expect_event d "$pattern\"everyone\":\\[\"send\",\"speak\"\\]," "$dstart" >/dev/null
pattern="^\\{\"event\":\"room_list\",.*\"name\":\"join-$run_tag\","
expect_event c "$pattern[^}]*\"myPermissions\":\\[\"send\",\"speak\"\\]" "$cstart" >/dev/null
expect_upload_error c "$join_room" "$held_file" "You cannot attach files in this room"
cstart=$(lines c)
expect_ok c "send $join_room --attach $held_blob a file without AttachFiles"
expect_event c '^\{"event":"protocol_error",.*"message":"You cannot attach files in this room"' \
	"$cstart" >/dev/null
cstart=$(lines c)
expect_ok c "send $join_room text still posts"
pattern="\"event\":\"room_chat\".*\"roomID\":$join_room,.*\"content\":\"text still posts\"}"
expect_event c "$pattern" "$cstart" >/dev/null
state=$(limits_sql "SELECT state FROM attachments WHERE blob_id = decode('$held_blob', 'hex')")
[[ "$state" == 1 ]] || fail "expected C's refused upload still Ready and unbound, state $state"

echo "==> [attachments] 14. the uploader's process is killed mid-file"
kill_file="$work_dir/killed.bin"
head -c $((5 * MIB / 4)) /dev/urandom >"$kill_file"
kill_sha=$(sha256sum "$kill_file" | cut -d' ' -f1)
kstart=$(lines k)
expect_ok k "attach-upload 1 $kill_file"
progress=$(expect_event k '"event":"attachment_progress".*"direction":"upload".*"bytes":[1-9]' \
	"$kstart")
killed_blob=$(json_field "$progress" blobID)
kill -KILL "${client_pid[k]}"
wait "${client_pid[k]}" 2>/dev/null || true
k_fd=${client_fd[k]}
exec {k_fd}>&-
unset "client_pid[k]"
rm -f -- "$work_dir/k.in"
killed_part="$limits_dir/attachments/incoming/$killed_blob.part"
[[ -f "$killed_part" ]] || fail "expected the killed upload's part file at $killed_part"
part_size=$(stat -c %s "$killed_part")
((part_size > 0 && part_size < 5 * MIB / 4)) ||
	fail "expected a part of the file stored, found $part_size bytes"
echo "[attachments] the killed upload stored $part_size of $((5 * MIB / 4)) bytes"
# The same profile in a new process: same account, same identity, a new session.
start_client_at k "$nick_k" "$limits_address"
expect_connected k
kstart=$(lines k)
expect_ok k "attach-resume $killed_blob"
unknown_upload="unknown upload: only an upload this process started can be resumed"
expect_event k "\"event\":\"attachment_error\".*\"error\":\"$unknown_upload\"" "$kstart" \
	>/dev/null
fresh_done=$(upload k 1 "$kill_file")
fresh_blob=$(json_field "$fresh_done" blobID)
[[ "$fresh_blob" != "$killed_blob" ]] || fail "expected the upload again to be a new blob"
[[ "$(json_field "$fresh_done" sha256)" == "$kill_sha" ]] || fail "the new upload's hash differs"
state=$(limits_sql "SELECT state FROM attachments WHERE blob_id = decode('$killed_blob', 'hex')")
[[ "$state" == 0 ]] || fail "expected the killed upload still Uploading, state $state"

echo "==> [attachments] 15. room deletion and the startup sweep empty the blob directory"
control_file="$work_dir/control.txt"
printf 'a file in a message that stays %s\n' "$run_tag" >"$control_file"
control_blob=$(json_field "$(upload d 1 "$control_file")" blobID)
dstart=$(lines d)
expect_ok d "send 1 --attach $control_blob this message stays"
expect_event d "\"event\":\"room_chat\".*\"roomID\":1,.*\"blobID\":\"$control_blob\"" "$dstart" \
	>/dev/null
for blob in "$old_blob" "$new_blob" "$held_blob" "$control_blob" "$fill_blob"; do
	[[ -f "$(blob_path "$blob")" ]] || fail "expected $blob stored before the sweep"
done
dstart=$(lines d)
expect_ok d room-delete "$join_room"
expect_event d "^\\{\"event\":\"room_deleted\",\"serverID\":[0-9]+,\"roomID\":$join_room\\}$" \
	"$dstart" >/dev/null
links=$(limits_sql "SELECT count(*) FROM attachments WHERE blob_id IN \
	(decode('$old_blob', 'hex'), decode('$new_blob', 'hex'), decode('$held_blob', 'hex')) \
	AND room_id IS NULL AND chat_message_id IS NULL")
[[ "$links" == 3 ]] || fail "expected the room's three files unlinked, found $links"
stop_client d
stop_client c
stop_client k
stop_limits_server

# The sweeper never deletes a row younger than an hour and runs hourly and at startup, so the
# proof makes the rows old in its own database while the server is down. Bound files whose
# message is gone and the stale upload need an hour; the unbound upload in the deleted room
# needs HAYCHAT_ATTACHMENT_PENDING_HOURS (24). The controls get two hours too.
limits_sql "UPDATE attachments SET created_at = now() - interval '2 hours', \
	last_chunk_at = now() - interval '2 hours' WHERE blob_id IN (decode('$old_blob', 'hex'), \
	decode('$new_blob', 'hex'), decode('$killed_blob', 'hex'), decode('$control_blob', 'hex'), \
	decode('$fill_blob', 'hex'))" >/dev/null
limits_sql "UPDATE attachments SET created_at = now() - interval '25 hours', \
	last_chunk_at = now() - interval '25 hours' WHERE blob_id = decode('$held_blob', 'hex')" \
	>/dev/null
orphan=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
orphan_path=$(blob_path "$orphan")
mkdir -p "$(dirname "$orphan_path")"
printf 'a file with no row\n' >"$orphan_path"
touch -d '2 hours ago' "$orphan_path"
start_limits_server
deadline=$((SECONDS + command_timeout_secs))
until grep -Fq "[Attachments] Swept 4 attachment rows" "$limits_log" &&
	grep -Fq "[Attachments] Deleted 1 orphan attachment files" "$limits_log"; do
	((SECONDS < deadline)) || fail "the startup sweep and scan did not run as expected"
	sleep 0.1
done
for blob in "$old_blob" "$new_blob" "$held_blob" "$orphan"; do
	path=$(blob_path "$blob")
	for _ in $(seq 1 50); do
		[[ -e "$path" ]] || break
		sleep 0.1
	done
	[[ ! -e "$path" ]] || fail "expected $path deleted by the startup sweep"
done
for _ in $(seq 1 50); do
	[[ -e "$killed_part" ]] || break
	sleep 0.1
done
[[ ! -e "$killed_part" ]] || fail "expected the stale upload's part file deleted"
left=$(limits_sql "SELECT string_agg(encode(blob_id, 'hex'), ',' ORDER BY id) FROM attachments \
	WHERE blob_id IN (decode('$old_blob', 'hex'), decode('$new_blob', 'hex'), \
	decode('$held_blob', 'hex'), decode('$killed_blob', 'hex'))")
[[ -z "$left" ]] || fail "expected the swept rows gone, found $left"
for blob in "$control_blob" "$fill_blob" "$fresh_blob"; do
	[[ -f "$(blob_path "$blob")" ]] || fail "expected $blob kept by the sweep"
done
echo "[attachments] the startup sweep deleted 4 rows and their files and 1 orphan file"
rm -f -- "$work_dir/d.in"
start_client_at d "$nick_d" "$limits_address"
expect_connected d
download d "$control_blob" "$work_dir/d-control.txt" >/dev/null
same_bytes "$control_file" "$work_dir/d-control.txt" || fail "the kept file no longer downloads"
stop_client d
stop_limits_server

echo "==> [attachments] 16. the startup scan keeps a wrong restore's files (#131)"
limits_blobs="$limits_dir/attachments/blobs"
# stored_files: every file the startup scan lists (finished blobs and part files), one per line.
stored_files() {
	find "$limits_blobs" "$limits_dir/attachments/incoming" -type f \
		\( -path "$limits_blobs/*" -o -name '*.part' \)
}
# wait_limits_log TEXT: waits until the second server's log has a line containing TEXT.
wait_limits_log() {
	local deadline=$((SECONDS + command_timeout_secs))
	until grep -Fq -- "$1" "$limits_log"; do
		((SECONDS < deadline)) || fail "the second server never logged: $1"
		sleep 0.1
	done
}
# The scan lists only files older than an hour; make every stored file old enough.
stored_files | xargs -r touch -d '2 hours ago'
known_files=$(stored_files | wc -l)
((known_files > 0)) || fail "expected stored files before the guard steps"
planted=()
for _ in $(seq 1 12); do
	blob=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
	path=$(blob_path "$blob")
	mkdir -p "$(dirname "$path")"
	printf 'a restored file %s\n' "$blob" >"$path"
	touch -d '2 hours ago' "$path"
	planted+=("$path")
done
total_files=$((known_files + 12))

# 12 of the files have no row: more than the floor (10) and more than 10%.
start_limits_server
wait_limits_log "[Attachments] Warning: 12 of the $total_files files older than an hour"
grep -F "[Attachments] Warning: 12 of the" "$limits_log" | grep -Fq \
	"deploy/README.md (Restoring)" || fail "the warning does not name the restore procedure"
! grep -Fq "orphan attachment files" "$limits_log" || fail "the scan deleted files past its guard"
for path in "${planted[@]}"; do
	[[ -f "$path" ]] || fail "expected $path kept by the over-the-share guard"
done
[[ "$(stored_files | wc -l)" == "$total_files" ]] || fail "expected every file kept"
echo "[attachments] the scan kept 12 orphans of $total_files files and warned"
stop_limits_server

# An empty table (a fresh database beside a restored volume): every file stays.
limits_sql "DELETE FROM attachments" >/dev/null
start_limits_server
wait_limits_log "[Attachments] Warning: the attachments table is empty but the blob directory \
holds $total_files files"
grep -F "attachments table is empty" "$limits_log" | grep -Fq \
	"HAYCHAT_ATTACHMENT_ALLOW_ORPHAN_PURGE=1" || fail "the warning does not name the override"
! grep -Fq "orphan attachment files" "$limits_log" || fail "the scan deleted files of a restore"
[[ "$(stored_files | wc -l)" == "$total_files" ]] || fail "expected every file kept"
echo "[attachments] the scan kept all $total_files files beside an empty table and warned"
stop_limits_server

# One start with the override deletes them all.
start_limits_server 1
wait_limits_log "[Attachments] HAYCHAT_ATTACHMENT_ALLOW_ORPHAN_PURGE is set: deleting \
$total_files orphan files of $total_files past the guards"
wait_limits_log "[Attachments] Deleted $total_files orphan attachment files"
left=$(stored_files | wc -l)
[[ "$left" == 0 ]] || fail "expected the override to delete every file, $left left"
echo "[attachments] the override deleted all $total_files files"
stop_limits_server
echo "==> [attachments] PASS"
