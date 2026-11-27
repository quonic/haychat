package common

import "core:encoding/cbor"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"

// A backing allocator for the wiping allocator's tests: it hands out blocks from one buffer
// and never reuses them, so a test can read a block after it was freed, and it checks at every
// free that the block is already zero.
@(private = "file")
RecordingBacking :: struct {
	buffer:        []u8,
	used:          int,
	allocs:        int,
	frees:         int,
	freedNonZero:  int,
	freedUnsized:  int,
	resizesPassed: int,
}

@(private = "file")
recordingBackingProc :: proc(
	allocatorData: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	oldMemory: rawptr,
	oldSize: int,
	loc := #caller_location,
) -> (
	[]byte,
	mem.Allocator_Error,
) {
	backing := (^RecordingBacking)(allocatorData)
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		start := mem.align_forward_int(backing.used, max(alignment, 1))
		if start + size > len(backing.buffer) {
			return nil, .Out_Of_Memory
		}
		block := backing.buffer[start:start + size]
		if mode == .Alloc {
			mem.zero_slice(block)
		} else {
			// Garbage, so a test sees a copy that is not wiped.
			for &b in block {
				b = 0x5c
			}
		}
		backing.used = start + size
		backing.allocs += 1
		return block, nil
	case .Free:
		backing.frees += 1
		if oldSize <= 0 {
			backing.freedUnsized += 1
			return nil, nil
		}
		for b in ([^]u8)(oldMemory)[:oldSize] {
			if b != 0 {
				backing.freedNonZero += 1
				break
			}
		}
		return nil, nil
	case .Resize, .Resize_Non_Zeroed:
		backing.resizesPassed += 1
		return nil, .Mode_Not_Implemented
	}
	return nil, .Mode_Not_Implemented
}

@(private = "file")
recordingBackingAllocator :: proc(backing: ^RecordingBacking) -> mem.Allocator {
	return mem.Allocator{procedure = recordingBackingProc, data = backing}
}

@(private = "file")
bytesAreZero :: proc(bytes: []u8) -> bool {
	for b in bytes {
		if b != 0 {
			return false
		}
	}
	return true
}

@(test)
testWipingAllocatorZeroesOnFree :: proc(t: ^testing.T) {
	_ = t
	buffer := make([]u8, 4096)
	defer delete(buffer)
	backing := RecordingBacking {
		buffer = buffer,
	}
	wiping := WipingAllocator {
		backing = recordingBackingAllocator(&backing),
	}
	allocator := WipingAllocator_allocator(&wiping)

	secret, allocErr := make([]u8, 48, allocator)
	assert(allocErr == nil, fmt.tprintf("expected the allocation to succeed, got %v", allocErr))
	for &b, i in secret {
		b = u8(i + 1)
	}
	block := secret
	delete(secret, allocator)
	assert(bytesAreZero(block), "expected the freed block to be zero")
	assert(
		backing.frees == 1 && backing.freedNonZero == 0,
		fmt.tprintf(
			"expected one free of a zeroed block, got %d frees, %d not zeroed",
			backing.frees,
			backing.freedNonZero,
		),
	)

	// A free that does not say its size cannot be wiped, and is passed on.
	unsized, unsizedErr := mem.alloc(16, allocator = allocator)
	assert(unsizedErr == nil, "expected the unsized block's allocation to succeed")
	mem.free(unsized, allocator)
	assert(backing.freedUnsized == 1, "expected the unsized free to reach the backing allocator")

	// Free_All would have to wipe blocks the wrapper does not track: refused.
	freeAllErr := mem.free_all(allocator)
	assert(
		freeAllErr == .Mode_Not_Implemented,
		fmt.tprintf("expected Free_All to be refused, got %v", freeAllErr),
	)
}

@(test)
testWipingAllocatorZeroesTheOldBlockOnAMovingResize :: proc(t: ^testing.T) {
	_ = t
	buffer := make([]u8, 4096)
	defer delete(buffer)
	backing := RecordingBacking {
		buffer = buffer,
	}
	wiping := WipingAllocator {
		backing = recordingBackingAllocator(&backing),
	}
	allocator := WipingAllocator_allocator(&wiping)

	old, allocErr := mem.alloc_bytes(32, allocator = allocator)
	assert(allocErr == nil, "expected the first allocation to succeed")
	for &b in old {
		b = 0xa7
	}

	// Growing: the wrapper never lets the backing allocator resize, it moves the block.
	grown, growErr := mem.resize_bytes(old, 256, allocator = allocator)
	assert(growErr == nil, fmt.tprintf("expected the resize to succeed, got %v", growErr))
	assert(raw_data(grown) != raw_data(old), "expected the resize to move the block")
	assert(len(grown) == 256, fmt.tprintf("expected 256 bytes, got %d", len(grown)))
	for b, i in grown[:32] {
		assert(b == 0xa7, fmt.tprintf("expected byte %d copied as 0xa7, got %x", i, b))
	}
	assert(bytesAreZero(grown[32:]), "expected a zeroing resize to zero the new tail")
	assert(bytesAreZero(old), "expected the outgrown block to be zero")
	assert(backing.resizesPassed == 0, "expected no resize to reach the backing allocator")

	// Shrinking moves too, so the old block's tail is wiped with the rest of it.
	for &b in grown {
		b = 0x3c
	}
	shrunk, shrinkErr := mem.resize_bytes(grown, 8, allocator = allocator)
	assert(shrinkErr == nil, "expected the shrink to succeed")
	assert(len(shrunk) == 8, fmt.tprintf("expected 8 bytes, got %d", len(shrunk)))
	for b in shrunk {
		assert(b == 0x3c, "expected the kept bytes to be copied")
	}
	assert(bytesAreZero(grown), "expected the whole old block, tail too, to be zero")

	// Resizing to nothing frees, wiped.
	for &b in shrunk {
		b = 0x11
	}
	_, freeErr := mem.resize_bytes(shrunk, 0, allocator = allocator)
	assert(freeErr == nil, "expected a resize to zero to free the block")
	assert(bytesAreZero(shrunk), "expected the block freed by a resize to zero to be zero")
	assert(
		backing.frees == 3 && backing.freedNonZero == 0,
		fmt.tprintf(
			"expected three frees of zeroed blocks, got %d frees, %d not zeroed",
			backing.frees,
			backing.freedNonZero,
		),
	)
}

// cbor.marshal grows its output and cbor.unmarshal a byte string of more than 1 KiB: through
// the wiping allocator, every copy they outgrow is zero when it is freed.
@(test)
testWipingAllocatorWipesWhatCborOutgrows :: proc(t: ^testing.T) {
	_ = t
	buffer := make([]u8, 256 * 1024)
	defer delete(buffer)
	backing := RecordingBacking {
		buffer = buffer,
	}
	wiping := WipingAllocator {
		backing = recordingBackingAllocator(&backing),
	}
	allocator := WipingAllocator_allocator(&wiping)

	text := strings.repeat("invite code and reason ", 400)
	defer delete(text)
	request := ClientRegisterRequest {
		reason = text,
	}
	packet, buildOK := buildPacket(.ClientRegister, request, allocator)
	assert(buildOK, "expected the payload to encode")
	packetBytes, marshalOK := marshalPacket(packet, allocator)
	assert(marshalOK, "expected the packet to encode")
	assert(
		backing.frees > 0,
		"expected cbor.marshal to outgrow at least one buffer for a 9 KiB payload",
	)
	assert(
		backing.freedNonZero == 0,
		fmt.tprintf("expected every outgrown buffer zeroed, %d were not", backing.freedNonZero),
	)

	freesBeforeDecode := backing.frees
	decoded: Packet
	decodeErr := cbor.unmarshal_from_bytes(
		packetBytes,
		&decoded,
		allocator = allocator,
		temp_allocator = allocator,
	)
	assert(decodeErr == nil, fmt.tprintf("expected the packet to decode, got %v", decodeErr))
	assert(
		backing.frees > freesBeforeDecode,
		"expected cbor.unmarshal to outgrow its 1 KiB first buffer",
	)
	assert(
		backing.freedNonZero == 0,
		fmt.tprintf(
			"expected every outgrown decode buffer zeroed, %d were not",
			backing.freedNonZero,
		),
	)
	assert(
		string(decoded.payload) == string(packet.payload),
		"expected the decoded payload to match the encoded one",
	)

	delete(decoded.payload, allocator)
	delete(packetBytes, allocator)
	delete(packet.payload, allocator)
	assert(backing.freedNonZero == 0, "expected the final buffers zeroed when freed")
}

// Over the test runner's tracking allocator the wrapper is transparent: a block it hands out
// may be freed with plain delete, and a seal and open of a payload big enough to make both
// cbor.marshal and cbor.unmarshal grow leaves no leak or bad free.
@(test)
testWipingAllocatorIsTransparentToTheContextAllocator :: proc(t: ^testing.T) {
	_ = t
	wiping := WipingAllocator {
		backing = context.allocator,
	}
	allocator := WipingAllocator_allocator(&wiping)
	grown := make([dynamic]u8, 0, 4, allocator)
	for i in 0 ..< 3000 {
		append(&grown, u8(i))
	}
	delete(grown[:])

	sessionID: SessionID
	sharedSecret: SharedSecretBytes
	for i in 0 ..< len(sharedSecret) {
		sharedSecret[i] = u8(0x20 + i)
	}
	transcriptHash: FingerprintBytes
	client := TransportState_init(.Client)
	server := TransportState_init(.Server)
	TransportState_activate(
		&client,
		sessionID,
		deriveDirectionalTransportKeys(.Client, sessionID, sharedSecret, transcriptHash),
		.Trusted,
	)
	TransportState_activate(
		&server,
		sessionID,
		deriveDirectionalTransportKeys(.Server, sessionID, sharedSecret, transcriptHash),
		.Trusted,
	)
	defer TransportState_deinit(&client)
	defer TransportState_deinit(&server)

	text := strings.repeat("a long direct message ", 500)
	defer delete(text)
	request := ClientRegisterRequest {
		reason = text,
	}
	sealed, sealOK := sealPacketForSession(&client, .ClientRegister, request)
	assert(sealOK, "expected the large packet to seal")
	defer delete(sealed.payload)
	opened, openOK := openPacketForSession(&server, sealed)
	assert(openOK, "expected the large packet to open")
	defer delete(opened.payload)
	assert(opened.messageType == .ClientRegister, "expected the inner type to survive")
	decoded: ClientRegisterRequest
	assert(cbor.unmarshal(opened.payload, &decoded) == nil, "expected the payload to decode")
	defer ClientRegisterRequest_deinit(&decoded)
	assert(decoded.reason == text, "expected the reason to survive the round trip")
}

// #189: unmarshalSecretPayload wipes the copies cbor.unmarshal outgrows for a string of more
// than 1 KiB, what it decodes is the context allocator's (freed and wiped by the payload's
// _deinit), and wipeAndDeleteBytes zeroes a buffer before it frees it.
@(test)
testUnmarshalSecretPayloadAndWipeAndDeleteBytes :: proc(t: ^testing.T) {
	_ = t
	text := strings.repeat("a long sign-up reason ", 300)
	defer delete(text)
	request := ClientRegisterRequest {
		inviteCode = "ABCD-EFGH",
		reason     = text,
	}
	packet, buildOK := buildPacket(.ClientRegister, request)
	assert(buildOK, "expected the payload to encode")
	defer delete(packet.payload)

	buffer := make([]u8, 256 * 1024)
	defer delete(buffer)
	backing := RecordingBacking {
		buffer = buffer,
	}
	// Only the decode and the wipes run on the recording allocator; the deferred frees above
	// stay the test's.
	{
		context.allocator = recordingBackingAllocator(&backing)

		decoded: ClientRegisterRequest
		decodeErr := unmarshalSecretPayload(packet.payload, &decoded)
		assert(decodeErr == nil, fmt.tprintf("expected the payload to decode, got %v", decodeErr))
		assert(
			decoded.inviteCode == "ABCD-EFGH" && decoded.reason == text,
			"expected the code and reason to survive",
		)
		assert(backing.frees > 0, "expected cbor.unmarshal to outgrow its 1 KiB first buffer")
		assert(
			backing.freedNonZero == 0,
			fmt.tprintf("expected every outgrown buffer zeroed, %d were not", backing.freedNonZero),
		)
		reasonBlock := transmute([]u8)decoded.reason
		ClientRegisterRequest_deinit(&decoded)
		assert(bytesAreZero(reasonBlock), "expected the freed reason to be zero")
		assert(
			backing.freedNonZero == 0 && backing.freedUnsized == 0,
			"expected the decoded strings freed sized and zeroed",
		)

		opened, allocErr := make([]u8, 64)
		assert(allocErr == nil, "expected the buffer to allocate")
		for &b, i in opened {
			b = u8(i + 1)
		}
		block := opened
		wipeAndDeleteBytes(&opened)
		assert(opened == nil, "expected the buffer cleared")
		assert(bytesAreZero(block), "expected the freed buffer to be zero")
		assert(backing.freedNonZero == 0, "expected the buffer zeroed before it was freed")
	}
}

// #189 review: cbor.unmarshal stores its allocator in every dynamic array it decodes, and the
// WipingAllocator unmarshalSecretPayload decodes with lives on that procedure's stack. A decoded
// ServerInviteCreated's invite.roleIds must name the context allocator afterwards, so growing
// and freeing it later does not reach a dead WipingAllocator.
@(test)
testUnmarshalSecretPayloadRebindsDecodedDynamicArrays :: proc(t: ^testing.T) {
	_ = t
	roleIds := make([dynamic]int)
	defer delete(roleIds)
	append(&roleIds, 3, 5, 8)
	sent := ServerInviteCreatedPayload {
		invite = InviteSummary{id = 7, roleIds = roleIds},
		code = "ABCD-EFGH",
	}
	encoded, encodeErr := cbor.marshal(sent)
	assert(encodeErr == nil, fmt.tprintf("expected the payload to encode, got %v", encodeErr))
	defer delete(encoded)

	decoded: ServerInviteCreatedPayload
	decodeErr := unmarshalSecretPayload(encoded, &decoded)
	defer ServerInviteCreatedPayload_deinit(&decoded)
	assert(decodeErr == nil, fmt.tprintf("expected the payload to decode, got %v", decodeErr))
	assert(
		len(decoded.invite.roleIds) == 3 && decoded.invite.roleIds[2] == 8,
		fmt.tprintf("expected roles [3 5 8], got %v", decoded.invite.roleIds),
	)
	assert(
		decoded.invite.roleIds.allocator.procedure != wipingAllocatorProc,
		"expected the decoded roles to name the context allocator, not the wiping one",
	)
	assert(
		decoded.invite.roleIds.allocator.data == context.allocator.data,
		"expected the decoded roles to name the context allocator",
	)
	// Growing reaches the stored allocator, as a later append would.
	for i in 0 ..< 64 {
		append(&decoded.invite.roleIds, i)
	}
	assert(decoded.code == "ABCD-EFGH", "expected the code to survive")
}
