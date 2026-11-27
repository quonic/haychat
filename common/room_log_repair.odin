package common

// Repairing an encrypted room's damaged member log (protocol 34, #196). Admins only, checked in
// the database statements (DATABASE_ACTOR_IS_ADMIN_SQL), like attachment moderation.
//
// A stored log is damaged when it does not replay from version 1 (an entry a rule refuses, a
// row that is not an entry, a version gap) or does not end at rooms.log_version. The server
// refuses every append, removal and ban to such a room (RoomLogAppendOutcome.Damaged,
// ServerAdminActionResult.failedRoomIds), and writes a [RoomLog] line naming the version to
// truncate to.
//
// - Diagnose: ClientAdminRoomLogStatus{roomId} replays the stored log of one encrypted room
//   (roomId > 0) or of every encrypted room (roomId 0) and answers ServerAdminRoomLogStatus:
//   one RoomLogStatus for the room asked for, damaged or not, or the damaged rooms only (at
//   most ROOM_LOG_STATUS_ROOMS_MAX, with how many were checked and damaged).
// - Repair: ClientAdminTruncateRoomLog{roomId, toVersion} deletes the entries after toVersion,
//   which must be the status's goodVersion (the last version that replays), in one
//   transaction with the room locked: room_members, room_log_managers and rooms.access follow
//   the replayed state at toVersion, rooms.log_version becomes toVersion, and the room key
//   envelopes, sealed messages and sealed edits of later epochs are deleted (their epochs will
//   be used again by other entries). It is answered by ServerAdminActionResult
//   {TruncateRoomLog, roomId} and sent to the members, the managers and everyone either set
//   lost as ServerRoomLog{afterVersion = headVersion = toVersion, no entries}, plus
//   ServerRoomMembershipChanged for each member the rebuild added or removed; the room's voice
//   ends. A client that verified a later head sees the head go back (a Rollback) and shows
//   "This room's member list was changed on the server" for the room.
//
// deploy/sql/truncate-room-log.sql does the same without a client, for a version the server
// reported; it cannot reach a running server, which must be restarted afterwards.

// Most damaged rooms one ServerAdminRoomLogStatus for every encrypted room lists.
ROOM_LOG_STATUS_ROOMS_MAX :: 50

ROOM_LOG_REPAIR_NOT_DAMAGED_MESSAGE :: "This room's member list is not damaged"
ROOM_LOG_REPAIR_WRONG_VERSION_MESSAGE ::
	"The member list can only be truncated to the last version that replays; check it again"
ROOM_LOG_REPAIR_NOTHING_TO_KEEP_MESSAGE ::
	"No version of this room's member list replays; delete the room instead"

// ClientAdminRoomLogStatus: replay one encrypted room's stored log (roomId > 0), or every
// encrypted room's (roomId 0). Answered by ServerAdminRoomLogStatus, or a ServerProtocolError
// ("Admin permission required", "Room not found", "This room is not encrypted").
ClientAdminRoomLogStatusPayload :: struct {
	roomId: int,
}

// What replaying one room's stored log found. storedVersion is rooms.log_version, entryCount
// the stored rows, goodVersion the last version that replays from version 1. failingVersion
// is the stored version that does not (0 when every stored entry replays) and error why
// (VersionNotNext for a gap, Truncated for a row that is not an entry). A log whose entries
// all replay but whose head is not storedVersion has failingVersion 0 and error None.
RoomLogStatus :: struct {
	roomId:         int,
	storedVersion:  int,
	entryCount:     int,
	goodVersion:    int,
	failingVersion: int,
	error:          RoomLogError,
}

// Whether the server refuses appends to the room for its log.
roomLogStatusIsDamaged :: proc(status: RoomLogStatus) -> bool {
	return status.goodVersion != status.storedVersion || status.goodVersion != status.entryCount
}

// ServerAdminRoomLogStatus: roomId echoes the request. For one room, rooms holds its status;
// for every room (roomId 0), the damaged ones in room ID order, at most
// ROOM_LOG_STATUS_ROOMS_MAX, with checkedRooms the encrypted rooms replayed and damagedRooms
// how many were damaged. rooms is owned once decoded.
ServerAdminRoomLogStatusPayload :: struct {
	roomId:       int,
	rooms:        [dynamic]RoomLogStatus,
	checkedRooms: int,
	damagedRooms: int,
}

ServerAdminRoomLogStatusPayload_deinit :: proc(payload: ^ServerAdminRoomLogStatusPayload) {
	delete(payload.rooms)
	payload.rooms = nil
}

// ClientAdminTruncateRoomLog: delete the entries of roomId's damaged log after toVersion, its
// goodVersion. Answered by ServerAdminActionResult{TruncateRoomLog, roomId} or a
// ServerProtocolError.
ClientAdminTruncateRoomLogPayload :: struct {
	roomId:    int,
	toVersion: int,
}

// Database IPC (server only).

DatabaseRoomLogRepairAction :: enum u8 {
	Status,
	Truncate,
}

// roomId 0 with Status checks every encrypted room. toVersion is read by Truncate only.
DatabaseRoomLogRepairRequest :: struct {
	action:                  DatabaseRoomLogRepairAction,
	actorUserId:             int,
	roomId:                  int,
	toVersion:               int,
	serverIdentityPublicKey: IdentityPublicKeyBytes,
}

DatabaseRoomLogRepairOutcome :: enum u8 {
	Applied,
	NotAdmin,
	UnknownRoom,
	NotEncrypted,
	NotDamaged, // Truncate: the log replays and ends at the room's head
	WrongVersion, // Truncate: toVersion is not the log's goodVersion
	NothingToKeep, // Truncate: not even the Create replays (goodVersion 0)
}

// statuses (owned) as ServerAdminRoomLogStatus carries them. A Truncate that applied reports
// the status before it (status), the members and managers after it (ascending, owned), the
// members it added and removed (owned), every account that was a member or manager before
// it (owned), and how many rows of each kind it deleted.
DatabaseRoomLogRepairResult :: struct {
	outcome:          DatabaseRoomLogRepairOutcome,
	statuses:         [dynamic]RoomLogStatus,
	checkedRooms:     int,
	damagedRooms:     int,
	status:           RoomLogStatus,
	memberUserIDs:    [dynamic]int,
	managerUserIDs:   [dynamic]int,
	addedUserIDs:     [dynamic]int,
	removedUserIDs:   [dynamic]int,
	formerUserIDs:    [dynamic]int,
	deletedEntries:   int,
	deletedEnvelopes: int,
	deletedMessages:  int,
	deletedEdits:     int,
}

DatabaseRoomLogRepairResult_deinit :: proc(result: ^DatabaseRoomLogRepairResult) {
	delete(result.statuses)
	delete(result.memberUserIDs)
	delete(result.managerUserIDs)
	delete(result.addedUserIDs)
	delete(result.removedUserIDs)
	delete(result.formerUserIDs)
	result^ = {}
}
