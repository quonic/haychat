#+feature dynamic-literals
package client

import "../common"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"

// The client transport wipes what it decrypts and decodes before it frees it (#189): the
// payload openPacketForSession returns, and ServerInviteCreated's code. The test runs the
// transport over an allocator that looks at every block given back to it.

// A pass-through allocator over the test's context allocator (so ownership and the leak check
// stay as they are) that looks at every block given back before passing it on: it counts the
// blocks that still hold the secret, and the sized frees of len(secret) bytes that are all
// zero. A resize may move the block and free the old one, so it is looked at too.
@(private = "file")
SecretFreeRecorder :: struct {
	backing:           mem.Allocator,
	secret:            string,
	frees:             int,
	givenBackSecret:   int,
	freedZeroOfLength: int,
}

@(private = "file")
secretFreeRecorderLook :: proc(recorder: ^SecretFreeRecorder, memory: rawptr, size: int) {
	if memory == nil || size <= 0 {
		return
	}
	block := ([^]u8)(memory)[:size]
	if strings.contains(string(block), recorder.secret) {
		recorder.givenBackSecret += 1
	}
	if size == len(recorder.secret) {
		for b in block {
			if b != 0 {
				return
			}
		}
		recorder.freedZeroOfLength += 1
	}
}

@(private = "file")
secretFreeRecorderProc :: proc(
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
	recorder := (^SecretFreeRecorder)(allocatorData)
	#partial switch mode {
	case .Free:
		recorder.frees += 1
		secretFreeRecorderLook(recorder, oldMemory, oldSize)
	case .Resize, .Resize_Non_Zeroed:
		secretFreeRecorderLook(recorder, oldMemory, oldSize)
	}
	backing := recorder.backing
	return backing.procedure(backing.data, mode, size, alignment, oldMemory, oldSize, loc)
}

@(private = "file")
secretFreeRecorderAllocator :: proc(recorder: ^SecretFreeRecorder) -> mem.Allocator {
	return mem.Allocator{procedure = secretFreeRecorderProc, data = recorder}
}

// #189: a sealed ServerInviteCreated through the runtime dispatch. While the event holds the
// code, nothing given back held it (the opened payload and the decode's copies are wiped), and
// freeing the event gives the decoded code back as zeros.
@(test)
testRuntimeDispatchWipesTheOpenedPayloadAndInviteCode :: proc(t: ^testing.T) {
	server := testRoomAdminServer(1890)
	config := testConfigWithServers({server})
	defer Config_deinit(&config)
	transport, serverTransport, ok := buildEstablishedTransportPair(server, config)
	assert(ok, "expected transport pair setup to succeed")
	defer ClientServerTransport_deinit(&transport)
	defer common.TransportState_deinit(&serverTransport)

	code, codeOK := common.generateInviteCode()
	assert(codeOK, "expected a random code")
	text := common.formatInviteCode(code)
	defer common.wipeAndDeleteString(&text)
	sealed, sealOK := common.sealPacketForSession(
		&serverTransport,
		.ServerInviteCreated,
		common.ServerInviteCreatedPayload {
			invite = {id = 5, note = "for carol", maxUses = 1},
			code = text,
		},
	)
	assert(sealOK, "expected ServerInviteCreated to seal")
	defer delete(sealed.payload)
	packetBytes, bytesOK := common.marshalPacket(sealed)
	assert(bytesOK, "expected the sealed packet to marshal")
	defer delete(packetBytes)

	recorder := SecretFreeRecorder {
		backing = context.allocator,
		secret  = text,
	}
	{
		context.allocator = secretFreeRecorderAllocator(&recorder)
		event, eventOK := ClientServerTransport_handleRuntimePacketBytes(&transport, packetBytes)
		assert(
			eventOK && event.kind == .InviteCreated && event.inviteCode == text,
			fmt.tprintf("expected the created invite with its code, got %v", event.kind),
		)
		testing.expect(t, recorder.frees > 0, "expected the dispatch to free through the recorder")
		testing.expect(
			t,
			recorder.givenBackSecret == 0,
			fmt.tprintf(
				"expected the opened payload wiped, %d blocks given back held the code",
				recorder.givenBackSecret,
			),
		)
		zeroBefore := recorder.freedZeroOfLength
		ClientTransportRuntimeEvent_deinit(&event)
		testing.expect(
			t,
			recorder.freedZeroOfLength > zeroBefore,
			"expected the event's decoded code freed as zeros",
		)
	}
	testing.expect(
		t,
		recorder.givenBackSecret == 0,
		fmt.tprintf(
			"expected no block given back holding the code, got %d",
			recorder.givenBackSecret,
		),
	)
}
