package server

import "../common"
import "core:strings"
import "shared:pg"

// Sender chains in encrypted rooms (protocol 19, migration 8, e2ee-design.md 6.4): storing and
// fetching SenderKey envelopes, and the check behind a key request. The router has already
// checked an envelope's structure and its signature against the sender's identity key
// (router_room_keys.odin); every rule that depends on the room's state is one statement here,
// so a membership or log change between the check and the store cannot slip through.
//
// Nothing here allocates from the temporary allocator.

// $1 room, $2 sender, $3 epoch, $4 chain ID (hex), $5 the wraps' user IDs (an array literal),
// $6 the envelope (hex). Stores the envelope only when the room is encrypted, the sender is a
// member, every wrap names a member, and the epoch is the room's log version or, for a re-seal
// answering a key request, an older epoch whose chain is already stored. One row: whether the
// room exists, its flag, the sender's membership, its log version, whether the chain is known,
// how many wraps name non-members, and the stored row's ID.
DATABASE_STORE_ROOM_KEY_ENVELOPE_SQL ::
	"WITH room AS (SELECT encrypted, log_version FROM rooms WHERE id = $1::bigint), " +
	"member AS (SELECT 1 FROM room_members WHERE room_id = $1::bigint " +
	"AND user_id = $2::bigint), " +
	"known AS (SELECT 1 FROM room_key_envelopes WHERE room_id = $1::bigint " +
	"AND sender_user_id = $2::bigint AND epoch = $3::bigint " +
	"AND chain_id = decode($4::text, 'hex') LIMIT 1), " +
	"outsiders AS (SELECT count(*) AS n FROM unnest($5::bigint[]) AS r(user_id) " +
	"WHERE NOT EXISTS (SELECT 1 FROM room_members rm WHERE rm.room_id = $1::bigint " +
	"AND rm.user_id = r.user_id)), " +
	"ok AS (SELECT 1 FROM room WHERE encrypted AND EXISTS (SELECT 1 FROM member) " +
	"AND ($3::bigint = log_version OR ($3::bigint < log_version " +
	"AND EXISTS (SELECT 1 FROM known))) AND (SELECT n FROM outsiders) = 0), " +
	"stored AS (INSERT INTO room_key_envelopes (room_id, epoch, sender_user_id, chain_id, " +
	"recipient_user_ids, envelope) SELECT $1::bigint, $3::bigint, $2::bigint, " +
	"decode($4::text, 'hex'), $5::bigint[], decode($6::text, 'hex') " +
	"WHERE EXISTS (SELECT 1 FROM ok) RETURNING id) " +
	"SELECT EXISTS (SELECT 1 FROM room)::text, " +
	"COALESCE((SELECT encrypted FROM room), false)::text, " +
	"EXISTS (SELECT 1 FROM member)::text, " +
	"COALESCE((SELECT log_version FROM room), 0)::text, " +
	"EXISTS (SELECT 1 FROM known)::text, (SELECT n FROM outsiders)::text, s.id::text " +
	"FROM (SELECT 1) AS one LEFT JOIN stored s ON true"

// $1 the requester, $2 the room, $3 sinceEpoch, $4 afterId, $5 the page size plus one. Members
// only; only envelopes with a wrap for the requester. One row with NULL envelope columns when
// there is nothing to send.
DATABASE_FETCH_ROOM_KEYS_SQL ::
	"WITH allowed AS (SELECT EXISTS (SELECT 1 FROM room_members WHERE room_id = $2::bigint " +
	"AND user_id = $1::bigint) AS ok) " +
	"SELECT a.ok::text, e.id::text, e.epoch::text, e.sender_user_id::text, " +
	"encode(e.chain_id, 'hex'), encode(e.envelope, 'hex') FROM allowed a " +
	"LEFT JOIN LATERAL (SELECT id, epoch, sender_user_id, chain_id, envelope " +
	"FROM room_key_envelopes WHERE a.ok AND room_id = $2::bigint AND epoch >= $3::bigint " +
	"AND id > $4::bigint AND $1::bigint = ANY (recipient_user_ids) " +
	"ORDER BY id LIMIT $5::bigint) e ON true ORDER BY e.id"

// $1 the requester, $2 the room, $3 the epoch, $4 the chain's sender, $5 the chain ID (hex).
DATABASE_ROOM_KEY_REQUEST_CHECK_SQL ::
	"SELECT (EXISTS (SELECT 1 FROM rooms WHERE id = $2::bigint AND encrypted) " +
	"AND EXISTS (SELECT 1 FROM room_members WHERE room_id = $2::bigint " +
	"AND user_id = $1::bigint) " +
	"AND EXISTS (SELECT 1 FROM room_members WHERE room_id = $2::bigint " +
	"AND user_id = $4::bigint) " +
	"AND EXISTS (SELECT 1 FROM room_key_envelopes WHERE room_id = $2::bigint " +
	"AND sender_user_id = $4::bigint AND epoch = $3::bigint " +
	"AND chain_id = decode($5::text, 'hex')))::text"

databaseExecuteStoreRoomKeyEnvelope :: proc(
	conn: pg.Conn,
	request: common.DatabaseStoreRoomKeyEnvelopeRequest,
) -> common.DatabaseQueryResponse {
	chainID := request.chainId
	roomIDParam := databaseIntParam(request.roomId)
	defer delete(roomIDParam)
	senderIDParam := databaseIntParam(request.senderId)
	defer delete(senderIDParam)
	epochParam := databaseIntParam(request.epoch)
	defer delete(epochParam)
	chainHex := common.encodeBytesToHex(chainID[:])
	defer delete(chainHex)
	chainParam, _ := strings.clone_to_cstring(chainHex)
	defer delete(chainParam)
	recipientsParam := databaseIntArrayParam(request.recipientUserIDs[:])
	defer delete(recipientsParam)
	envelopeHex := common.encodeBytesToHex(request.envelope)
	defer delete(envelopeHex)
	envelopeParam, _ := strings.clone_to_cstring(envelopeHex)
	defer delete(envelopeParam)
	params := [?][^]byte {
		transmute([^]byte)roomIDParam,
		transmute([^]byte)senderIDParam,
		transmute([^]byte)epochParam,
		transmute([^]byte)chainParam,
		transmute([^]byte)recipientsParam,
		transmute([^]byte)envelopeParam,
	}
	result := databaseExecParams(conn, DATABASE_STORE_ROOM_KEY_ENVELOPE_SQL, params[:])
	if result == nil {
		return databaseConnectionError(conn)
	}
	defer pg.clear(result)
	if pg.result_status(result) != .Tuples_OK || pg.n_tuples(result) != 1 {
		return databaseResultError(&result)
	}
	outcome := common.RoomKeyEnvelopeOutcome.Stored
	logVersion, _ := databaseGetInt(result, 0, 3)
	outsiders, _ := databaseGetInt(result, 0, 5)
	switch {
	case !databaseGetBool(result, 0, 0):
		outcome = .NotMember
	case !databaseGetBool(result, 0, 1):
		outcome = .NotEncrypted
	case !databaseGetBool(result, 0, 2):
		outcome = .NotMember
	case outsiders > 0:
		outcome = .WrongRecipients
	case request.epoch != logVersion && !databaseGetBool(result, 0, 4):
		outcome = .StaleEpoch
	case request.epoch > logVersion:
		outcome = .StaleEpoch
	}
	storedID, storedOK := databaseGetInt(result, 0, 6)
	if outcome != .Stored || !storedOK {
		if outcome == .Stored {
			outcome = .StaleEpoch
		}
		return databaseSuccess(common.DatabaseStoreRoomKeyEnvelopeResult{outcome = outcome})
	}
	envelope := make([]u8, len(request.envelope))
	copy(envelope, request.envelope)
	recipients := make([dynamic]int, 0, len(request.recipientUserIDs))
	append(&recipients, ..request.recipientUserIDs[:])
	return databaseSuccess(
		common.DatabaseStoreRoomKeyEnvelopeResult {
			outcome = .Stored,
			stored = common.RoomKeyEnvelope {
				id = storedID,
				roomId = request.roomId,
				epoch = request.epoch,
				senderId = request.senderId,
				chainId = request.chainId,
				envelope = envelope,
			},
			recipientUserIDs = recipients,
		},
	)
}

databaseExecuteFetchRoomKeys :: proc(
	conn: pg.Conn,
	request: common.DatabaseFetchRoomKeysRequest,
) -> common.DatabaseQueryResponse {
	limit := common.ROOM_KEYS_FETCH_MAX_ENVELOPES
	userIDParam := databaseIntParam(request.userId)
	defer delete(userIDParam)
	roomIDParam := databaseIntParam(request.roomId)
	defer delete(roomIDParam)
	sinceParam := databaseIntParam(request.sinceEpoch)
	defer delete(sinceParam)
	afterParam := databaseIntParam(request.afterId)
	defer delete(afterParam)
	limitParam := databaseIntParam(limit + 1)
	defer delete(limitParam)
	params := [?][^]byte {
		transmute([^]byte)userIDParam,
		transmute([^]byte)roomIDParam,
		transmute([^]byte)sinceParam,
		transmute([^]byte)afterParam,
		transmute([^]byte)limitParam,
	}
	result := databaseExecParams(conn, DATABASE_FETCH_ROOM_KEYS_SQL, params[:])
	if result == nil {
		return databaseConnectionError(conn)
	}
	defer pg.clear(result)
	if pg.result_status(result) != .Tuples_OK || pg.n_tuples(result) < 1 {
		return databaseResultError(&result)
	}
	answer := common.DatabaseFetchRoomKeysResult {
		sinceEpoch = request.sinceEpoch,
		afterId    = request.afterId,
		isMember   = databaseGetBool(result, 0, 0),
	}
	if !answer.isMember {
		return databaseSuccess(answer)
	}
	answer.envelopes = make([dynamic]common.RoomKeyEnvelope, 0, limit)
	rows := 0
	for row in 0 ..< pg.n_tuples(result) {
		if pg.get_is_null(result, row, 1) {
			continue
		}
		rows += 1
		if rows > limit {
			answer.hasMore = true
			break
		}
		envelope := common.RoomKeyEnvelope {
			roomId = request.roomId,
		}
		idOK, epochOK, senderOK: bool
		envelope.id, idOK = databaseGetInt(result, row, 1)
		envelope.epoch, epochOK = databaseGetInt(result, row, 2)
		envelope.senderId, senderOK = databaseGetInt(result, row, 3)
		chainOK := databaseGetHexBytes(result, row, 4, envelope.chainId[:])
		envelope.envelope = databaseGetOwnedHexBytes(result, row, 5)
		if !idOK || !epochOK || !senderOK || !chainOK || len(envelope.envelope) == 0 {
			delete(envelope.envelope)
			continue
		}
		append(&answer.envelopes, envelope)
	}
	return databaseSuccess(answer)
}

databaseExecuteRoomKeyRequestCheck :: proc(
	conn: pg.Conn,
	request: common.DatabaseRoomKeyRequestCheckRequest,
) -> common.DatabaseQueryResponse {
	chainID := request.chainId
	requesterParam := databaseIntParam(request.requesterId)
	defer delete(requesterParam)
	roomIDParam := databaseIntParam(request.roomId)
	defer delete(roomIDParam)
	epochParam := databaseIntParam(request.epoch)
	defer delete(epochParam)
	senderParam := databaseIntParam(request.senderId)
	defer delete(senderParam)
	chainHex := common.encodeBytesToHex(chainID[:])
	defer delete(chainHex)
	chainParam, _ := strings.clone_to_cstring(chainHex)
	defer delete(chainParam)
	params := [?][^]byte {
		transmute([^]byte)requesterParam,
		transmute([^]byte)roomIDParam,
		transmute([^]byte)epochParam,
		transmute([^]byte)senderParam,
		transmute([^]byte)chainParam,
	}
	result := databaseExecParams(conn, DATABASE_ROOM_KEY_REQUEST_CHECK_SQL, params[:])
	if result == nil {
		return databaseConnectionError(conn)
	}
	defer pg.clear(result)
	if pg.result_status(result) != .Tuples_OK || pg.n_tuples(result) != 1 {
		return databaseResultError(&result)
	}
	return databaseSuccess(
		common.DatabaseRoomKeyRequestCheckResult {
			allowed = databaseGetBool(result, 0, 0),
			request = request,
		},
	)
}
