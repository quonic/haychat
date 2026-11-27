package common

import "core:encoding/cbor"
import "core:fmt"
import "core:testing"

// Protocol 35 (#196): the member log repair payloads round-trip, and a status reads as damaged
// exactly when the server refuses appends to the room.
@(test)
testRoomLogRepairPayloadsRoundTrip :: proc(t: ^testing.T) {
	_ = t
	{
		encoded, err := cbor.marshal(ClientAdminRoomLogStatusPayload{roomId = 7})
		assert(err == nil, "expected ClientAdminRoomLogStatusPayload encoding to succeed")
		defer delete(encoded)
		decoded: ClientAdminRoomLogStatusPayload
		assert(cbor.unmarshal(encoded, &decoded) == nil, "expected the status request to decode")
		assert(decoded.roomId == 7, fmt.tprintf("expected room 7, got %v", decoded))
	}
	{
		encoded, err := cbor.marshal(ClientAdminTruncateRoomLogPayload{roomId = 7, toVersion = 4})
		assert(err == nil, "expected ClientAdminTruncateRoomLogPayload encoding to succeed")
		defer delete(encoded)
		decoded: ClientAdminTruncateRoomLogPayload
		assert(cbor.unmarshal(encoded, &decoded) == nil, "expected the truncate request to decode")
		assert(
			decoded.roomId == 7 && decoded.toVersion == 4,
			fmt.tprintf("expected room 7 to version 4, got %v", decoded),
		)
	}
	{
		rooms := make([dynamic]RoomLogStatus, 0, 2)
		defer delete(rooms)
		append(
			&rooms,
			RoomLogStatus {
				roomId = 3,
				storedVersion = 5,
				entryCount = 5,
				goodVersion = 4,
				failingVersion = 5,
				error = .BadSignature,
			},
			RoomLogStatus{roomId = 9, storedVersion = 6, entryCount = 4, goodVersion = 4},
		)
		original := ServerAdminRoomLogStatusPayload {
			roomId       = 0,
			rooms        = rooms,
			checkedRooms = 12,
			damagedRooms = 2,
		}
		encoded, err := cbor.marshal(original)
		assert(err == nil, "expected ServerAdminRoomLogStatusPayload encoding to succeed")
		defer delete(encoded)
		decoded: ServerAdminRoomLogStatusPayload
		assert(
			cbor.unmarshal(encoded, &decoded) == nil,
			"expected the status answer to decode",
		)
		defer ServerAdminRoomLogStatusPayload_deinit(&decoded)
		assert(
			decoded.checkedRooms == 12 &&
			decoded.damagedRooms == 2 &&
			len(decoded.rooms) == 2 &&
			decoded.rooms[0] == rooms[0] &&
			decoded.rooms[1] == rooms[1],
			fmt.tprintf("expected the two statuses back, got %v", decoded),
		)
	}
	{
		encoded, err := cbor.marshal(
			ServerAdminActionResultPayload {
				action = .TruncateRoomLog,
				roomId = 3,
				message = "Truncated",
			},
		)
		assert(err == nil, "expected the truncate result to encode")
		defer delete(encoded)
		decoded: ServerAdminActionResultPayload
		assert(cbor.unmarshal(encoded, &decoded) == nil, "expected the truncate result to decode")
		defer ServerAdminActionResultPayload_deinit(&decoded)
		assert(
			decoded.action == .TruncateRoomLog && decoded.roomId == 3,
			fmt.tprintf("expected TruncateRoomLog of room 3, got %v", decoded),
		)
	}

	intact := RoomLogStatus{roomId = 1, storedVersion = 3, entryCount = 3, goodVersion = 3}
	assert(!roomLogStatusIsDamaged(intact), "expected a log that replays to its head intact")
	assert(!roomLogStatusIsDamaged({roomId = 1}), "expected a log not set up yet intact")
	refused := RoomLogStatus {
		roomId         = 1,
		storedVersion  = 3,
		entryCount     = 3,
		goodVersion    = 2,
		failingVersion = 3,
		error          = .BadSignature,
	}
	assert(roomLogStatusIsDamaged(refused), "expected a refused entry damaged")
	behind := RoomLogStatus{roomId = 1, storedVersion = 2, entryCount = 3, goodVersion = 3}
	assert(roomLogStatusIsDamaged(behind), "expected entries past the head damaged")
	ahead := RoomLogStatus{roomId = 1, storedVersion = 4, entryCount = 3, goodVersion = 3}
	assert(roomLogStatusIsDamaged(ahead), "expected a head past the entries damaged")
}
