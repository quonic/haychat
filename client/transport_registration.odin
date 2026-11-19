package client

import "../common"
import "core:encoding/cbor"

// Registration packets of an authenticated session (protocol 25, #43 G2): the mode broadcast,
// invite codes and sign-up requests. The registering session's own packets are in
// connection.odin (ClientServerTransport_serviceRegisteringSession, _sendRegister). Every
// request here is answered by the server or refused with a ServerProtocolError; the client
// only decides which controls to show (registration.odin).

ClientServerTransport_translateRegistrationPacket :: proc(
	transport: ^ClientServerTransport,
	innerPacket: common.Packet,
) -> (
	ClientTransportRuntimeEvent,
	bool,
) {
	#partial switch innerPacket.messageType {
	case .ServerRegistrationMode:
		payload: common.ServerRegistrationModePayload
		if cbor.unmarshal(innerPacket.payload, &payload) != nil ||
		   !common.registrationModeIsSupported(payload.mode) {
			return ClientServerTransport_registrationInvalid(
					transport,
					"invalid registration mode payload",
				),
				true
		}
		return ClientTransportRuntimeEvent {
				kind = .RegistrationModeChanged,
				serverID = transport.serverID,
				registrationMode = payload.mode,
			},
			true

	case .ServerInviteCreated:
		payload: common.ServerInviteCreatedPayload
		if cbor.unmarshal(innerPacket.payload, &payload) != nil || payload.invite.id <= 0 {
			common.ServerInviteCreatedPayload_deinit(&payload)
			return ClientServerTransport_registrationInvalid(
					transport,
					"invalid invite payload",
				),
				true
		}
		return ClientTransportRuntimeEvent {
				kind = .InviteCreated,
				serverID = transport.serverID,
				invite = payload.invite,
				inviteCode = payload.code,
			},
			true

	case .ServerInviteList:
		payload: common.ServerInviteListPayload
		if cbor.unmarshal(innerPacket.payload, &payload) != nil {
			common.ServerInviteListPayload_deinit(&payload)
			return ClientServerTransport_registrationInvalid(
					transport,
					"invalid invite list payload",
				),
				true
		}
		return ClientTransportRuntimeEvent {
				kind = .InviteList,
				serverID = transport.serverID,
				invites = payload.invites,
			},
			true

	case .ServerRegistrationRequests:
		payload: common.ServerRegistrationRequestsPayload
		if cbor.unmarshal(innerPacket.payload, &payload) != nil || payload.pendingCount < 0 {
			common.ServerRegistrationRequestsPayload_deinit(&payload)
			return ClientServerTransport_registrationInvalid(
					transport,
					"invalid sign-up request list payload",
				),
				true
		}
		return ClientTransportRuntimeEvent {
				kind = .RegistrationRequests,
				serverID = transport.serverID,
				registrationRequests = payload.requests,
				pendingCount = payload.pendingCount,
			},
			true

	case .ServerRegistrationRequestUpdated:
		payload: common.ServerRegistrationRequestUpdatedPayload
		if cbor.unmarshal(innerPacket.payload, &payload) != nil ||
		   payload.request.id <= 0 ||
		   payload.pendingCount < 0 {
			common.ServerRegistrationRequestUpdatedPayload_deinit(&payload)
			return ClientServerTransport_registrationInvalid(
					transport,
					"invalid sign-up request payload",
				),
				true
		}
		return ClientTransportRuntimeEvent {
				kind = .RegistrationRequestUpdated,
				serverID = transport.serverID,
				registrationRequest = payload.request,
				pendingCount = payload.pendingCount,
			},
			true
	}
	return {}, false
}

@(private = "file")
ClientServerTransport_registrationInvalid :: proc(
	transport: ^ClientServerTransport,
	message: string,
) -> ClientTransportRuntimeEvent {
	ClientServerTransport_runtimeProtocolError(transport, message)
	return ClientServerTransport_makeRuntimeEvent(transport, .ProtocolError, transport.lastError)
}

ClientServerTransport_setRegistrationMode :: proc(
	transport: ^ClientServerTransport,
	mode: common.RegistrationMode,
) -> bool {
	return ClientServerTransport_sendEncryptedRuntimeMessage(
		transport,
		.ClientAdminSetRegistrationMode,
		common.ClientAdminSetRegistrationModePayload{mode = mode},
	)
}

// The request's strings and roleIDs are borrowed for the send.
ClientServerTransport_createInvite :: proc(
	transport: ^ClientServerTransport,
	note: string,
	expiresInSeconds, maxUses: int,
	roleIDs: []int,
	roomID: int,
	skipApproval: bool,
) -> bool {
	ids := make([dynamic]int, 0, len(roleIDs))
	defer delete(ids)
	append(&ids, ..roleIDs)
	return ClientServerTransport_sendEncryptedRuntimeMessage(
		transport,
		.ClientCreateInvite,
		common.ClientCreateInvitePayload {
			note = note,
			expiresInSeconds = expiresInSeconds,
			maxUses = maxUses,
			roleIds = ids,
			roomId = roomID,
			skipApproval = skipApproval,
		},
	)
}

ClientServerTransport_listInvites :: proc(transport: ^ClientServerTransport) -> bool {
	return ClientServerTransport_sendEncryptedRuntimeMessage(
		transport,
		.ClientListInvites,
		common.ClientListInvitesPayload{},
	)
}

ClientServerTransport_revokeInvite :: proc(
	transport: ^ClientServerTransport,
	inviteID: int,
) -> bool {
	return ClientServerTransport_sendEncryptedRuntimeMessage(
		transport,
		.ClientRevokeInvite,
		common.ClientRevokeInvitePayload{inviteId = inviteID},
	)
}

ClientServerTransport_listRegistrationRequests :: proc(
	transport: ^ClientServerTransport,
	includeDecided: bool,
) -> bool {
	return ClientServerTransport_sendEncryptedRuntimeMessage(
		transport,
		.ClientListRegistrationRequests,
		common.ClientListRegistrationRequestsPayload{includeDecided = includeDecided},
	)
}

ClientServerTransport_decideRegistration :: proc(
	transport: ^ClientServerTransport,
	requestID: int,
	approve: bool,
	reason: string,
) -> bool {
	return ClientServerTransport_sendEncryptedRuntimeMessage(
		transport,
		.ClientDecideRegistration,
		common.ClientDecideRegistrationPayload{id = requestID, approve = approve, reason = reason},
	)
}

ClientServerTransport_setRestricted :: proc(
	transport: ^ClientServerTransport,
	userID: int,
	restricted: bool,
) -> bool {
	return ClientServerTransport_sendEncryptedRuntimeMessage(
		transport,
		.ClientAdminSetRestricted,
		common.ClientAdminSetRestrictedPayload{userId = userID, restricted = restricted},
	)
}
