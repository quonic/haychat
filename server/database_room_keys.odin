package server

import "../common"
import "core:strings"
import "shared:pg"

// Sender chains in encrypted rooms (protocol 19, migration 8, e2ee-design.md 6.4): storing and
// fetching SenderKey envelopes, and the check behind a key request. Protocol 20 (migration 9,
// design 6.6): RoomKeyForward envelopes in Full history rooms, stored next to them with their
// forwarder, and key requests that every member of a Full history room is asked. The router
// has already checked an envelope's structure and its signature against the sender's (or
// forwarder's) identity key (router_room_keys.odin); every rule that depends on the room's
// state is one statement here, so a membership or log change between the check and the store
// cannot slip through.
//
// Nothing here allocates from the temporary allocator.

// $1 room, $2 the chain's sender, $3 epoch, $4 chain ID (hex), $5 the wraps' user IDs (an array
// literal), $6 the envelope (hex), $7 the forwarder (0 for a SenderKey envelope, which $2
// sealed).
//
// A SenderKey envelope is stored only when the room is encrypted, the sender is a member, every
// wrap names a member, and the epoch is the room's log version or, for a re-seal answering a
// key request, an older epoch whose chain is already stored. A RoomKeyForward (protocol 20)
// needs the forwarder to be a member, every wrap a member, the room's history Full, an epoch
// whose chain (sender, chain ID) is already stored, and no stored envelope of that chain with a
// wrap for the recipient (the first forward wins; later ones are dropped). One row: whether the
// room exists, its flag, the storing account's membership, its log version, whether the chain
// is known, how many wraps name non-members, the stored row's ID, the room's history
// visibility, and whether a recipient already holds the chain.
DATABASE_STORE_ROOM_KEY_ENVELOPE_SQL ::
	"WITH room AS (SELECT encrypted, log_version, history_visibility FROM rooms " +
	"WHERE id = $1::bigint), " +
	"member AS (SELECT 1 FROM room_members WHERE room_id = $1::bigint " +
	"AND user_id = CASE WHEN $7::bigint > 0 THEN $7::bigint ELSE $2::bigint END), " +
	"known AS (SELECT 1 FROM room_key_envelopes WHERE room_id = $1::bigint " +
	"AND sender_user_id = $2::bigint AND epoch = $3::bigint " +
	"AND chain_id = decode($4::text, 'hex') LIMIT 1), " +
	"held AS (SELECT 1 FROM room_key_envelopes WHERE $7::bigint > 0 AND room_id = $1::bigint " +
	"AND sender_user_id = $2::bigint AND epoch = $3::bigint " +
	"AND chain_id = decode($4::text, 'hex') AND recipient_user_ids && $5::bigint[] LIMIT 1), " +
	"outsiders AS (SELECT count(*) AS n FROM unnest($5::bigint[]) AS r(user_id) " +
	"WHERE NOT EXISTS (SELECT 1 FROM room_members rm WHERE rm.room_id = $1::bigint " +
	"AND rm.user_id = r.user_id)), " +
	"ok AS (SELECT 1 FROM room WHERE encrypted AND EXISTS (SELECT 1 FROM member) " +
	"AND (SELECT n FROM outsiders) = 0 AND (($7::bigint = 0 " +
	"AND ($3::bigint = log_version OR ($3::bigint < log_version " +
	"AND EXISTS (SELECT 1 FROM known)))) OR ($7::bigint > 0 AND history_visibility = 2 " +
	"AND $3::bigint <= log_version AND EXISTS (SELECT 1 FROM known) " +
	"AND NOT EXISTS (SELECT 1 FROM held)))), " +
	"stored AS (INSERT INTO room_key_envelopes (room_id, epoch, sender_user_id, chain_id, " +
	"recipient_user_ids, envelope, forwarder_user_id) SELECT $1::bigint, $3::bigint, " +
	"$2::bigint, decode($4::text, 'hex'), $5::bigint[], decode($6::text, 'hex'), " +
	"NULLIF($7::bigint, 0) WHERE EXISTS (SELECT 1 FROM ok) RETURNING id) " +
	"SELECT EXISTS (SELECT 1 FROM room)::text, " +
	"COALESCE((SELECT encrypted FROM room), false)::text, " +
	"EXISTS (SELECT 1 FROM member)::text, " +
	"COALESCE((SELECT log_version FROM room), 0)::text, " +
	"EXISTS (SELECT 1 FROM known)::text, (SELECT n FROM outsiders)::text, s.id::text, " +
	"COALESCE((SELECT history_visibility FROM room), 0)::text, " +
	"EXISTS (SELECT 1 FROM held)::text " +
	"FROM (SELECT 1) AS one LEFT JOIN stored s ON true"

// $1 the requester, $2 the room, $3 sinceEpoch, $4 afterId, $5 the page size plus one. Members
// only; only envelopes with a wrap for the requester, forwards (protocol 20) included with
// their forwarder (0 for a SenderKey envelope). One row with NULL envelope columns when there
// is nothing to send.
DATABASE_FETCH_ROOM_KEYS_SQL ::
	"WITH allowed AS (SELECT EXISTS (SELECT 1 FROM room_members WHERE room_id = $2::bigint " +
	"AND user_id = $1::bigint) AS ok) " +
	"SELECT a.ok::text, e.id::text, e.epoch::text, e.sender_user_id::text, " +
	"encode(e.chain_id, 'hex'), encode(e.envelope, 'hex'), " +
	"COALESCE(e.forwarder_user_id, 0)::text FROM allowed a " +
	"LEFT JOIN LATERAL (SELECT id, epoch, sender_user_id, chain_id, envelope, " +
	"forwarder_user_id FROM room_key_envelopes WHERE a.ok AND room_id = $2::bigint " +
	"AND epoch >= $3::bigint AND id > $4::bigint AND $1::bigint = ANY (recipient_user_ids) " +
	"ORDER BY id LIMIT $5::bigint) e ON true ORDER BY e.id"

// $1 the requester, $2 the room, $3 the epoch, $4 the chain's sender, $5 the chain ID (hex).
// One row: whether the request may go out (an encrypted room, the requester a member, the chain
// stored, and, unless the room's history is Full, the sender a member), whether the history is
// Full, and then the members to ask: every member but the requester, comma-separated.
DATABASE_ROOM_KEY_REQUEST_CHECK_SQL ::
	"WITH room AS (SELECT history_visibility = 2 AS is_full FROM rooms " +
	"WHERE id = $2::bigint AND encrypted), " +
	"base AS (SELECT EXISTS (SELECT 1 FROM room) " +
	"AND EXISTS (SELECT 1 FROM room_members WHERE room_id = $2::bigint " +
	"AND user_id = $1::bigint) " +
	"AND EXISTS (SELECT 1 FROM room_key_envelopes WHERE room_id = $2::bigint " +
	"AND sender_user_id = $4::bigint AND epoch = $3::bigint " +
	"AND chain_id = decode($5::text, 'hex')) AS ok), " +
	"fh AS (SELECT COALESCE((SELECT is_full FROM room), false) AS yes) " +
	"SELECT ((SELECT ok FROM base) AND ((SELECT yes FROM fh) " +
	"OR EXISTS (SELECT 1 FROM room_members WHERE room_id = $2::bigint " +
	"AND user_id = $4::bigint)))::text, " +
	"(SELECT yes FROM fh)::text, " +
	"CASE WHEN (SELECT ok FROM base) AND (SELECT yes FROM fh) THEN " +
	"COALESCE((SELECT string_agg(user_id::text, ',' ORDER BY user_id) FROM room_members " +
	"WHERE room_id = $2::bigint AND user_id <> $1::bigint), '') ELSE '' END"

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
	forwarderParam := databaseIntParam(max(request.forwarderId, 0))
	defer delete(forwarderParam)
	params := [?][^]byte {
		transmute([^]byte)roomIDParam,
		transmute([^]byte)senderIDParam,
		transmute([^]byte)epochParam,
		transmute([^]byte)chainParam,
		transmute([^]byte)recipientsParam,
		transmute([^]byte)envelopeParam,
		transmute([^]byte)forwarderParam,
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
	historyVisibility, _ := databaseGetInt(result, 0, 7)
	known := databaseGetBool(result, 0, 4)
	forward := request.forwarderId > 0
	switch {
	case !databaseGetBool(result, 0, 0):
		outcome = .NotMember
	case !databaseGetBool(result, 0, 1):
		outcome = .NotEncrypted
	case !databaseGetBool(result, 0, 2):
		outcome = .NotMember
	case outsiders > 0:
		outcome = .WrongRecipients
	case forward && historyVisibility != int(common.RoomHistoryVisibility.Full):
		outcome = .NotFullHistory
	case forward && (!known || request.epoch > logVersion):
		outcome = .StaleEpoch
	case forward && databaseGetBool(result, 0, 8):
		outcome = .AlreadyHeld
	case request.epoch != logVersion && !known:
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
				forwarderId = max(request.forwarderId, 0),
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
		idOK, epochOK, senderOK, forwarderOK: bool
		envelope.id, idOK = databaseGetInt(result, row, 1)
		envelope.epoch, epochOK = databaseGetInt(result, row, 2)
		envelope.senderId, senderOK = databaseGetInt(result, row, 3)
		chainOK := databaseGetHexBytes(result, row, 4, envelope.chainId[:])
		envelope.envelope = databaseGetOwnedHexBytes(result, row, 5)
		envelope.forwarderId, forwarderOK = databaseGetInt(result, row, 6)
		if !idOK ||
		   !epochOK ||
		   !senderOK ||
		   !forwarderOK ||
		   !chainOK ||
		   len(envelope.envelope) == 0 {
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
	answer := common.DatabaseRoomKeyRequestCheckResult {
		allowed     = databaseGetBool(result, 0, 0),
		request     = request,
		fullHistory = databaseGetBool(result, 0, 1),
	}
	if answer.allowed && answer.fullHistory {
		members := databaseGetText(result, 0, 2)
		defer delete(members)
		answer.memberUserIDs = databaseParseIDList(members)
	}
	return databaseSuccess(answer)
}
