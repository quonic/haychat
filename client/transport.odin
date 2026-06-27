package client

import "../common"
import "core:crypto/ecdh"
import "core:encoding/cbor"
import "core:fmt"
import "core:strings"

ClientTransportResult :: struct {
	responsePacketBytes: []u8,
	hasResponse:         bool,
	openedPacket:        common.Packet,
	hasOpenedPacket:     bool,
}

ClientServerTransport :: struct {
	serverID:                  int,
	serverName:                string,
	serverHost:                string,
	serverPort:                i32,
	clientIdentityPrivateKey:  common.IdentityPrivateKeyBytes,
	clientIdentityPublicKey:   common.IdentityPublicKeyBytes,
	clientEphemeralPrivateKey: ecdh.Private_Key,
	clientEphemeralPublicKey:  common.KeyExchangePublicKeyBytes,
	serverIdentityPublicKey:   common.IdentityPublicKeyBytes,
	serverEphemeralPublicKey:  common.KeyExchangePublicKeyBytes,
	sessionID:                 common.SessionID,
	authChallenge:             common.AuthChallengeBytes,
	pendingKeys:               common.DirectionalTransportKeys,
	pendingKeysReady:          bool,
	transport:                 common.TransportState,
	authenticatedUserID:       int,
	lastError:                 string,
}

ClientServerTransport_setLastError :: proc(transport: ^ClientServerTransport, message: string) {
	if len(transport.lastError) > 0 {
		delete(transport.lastError)
	}
	transport.lastError = strings.clone(message)
}

ClientServerTransport_fail :: proc(transport: ^ClientServerTransport, message: string) {
	ClientServerTransport_setLastError(transport, message)
	transport.pendingKeysReady = false
	transport.transport.phase = .Failed
}

ClientServerTransport_init :: proc(
	server: Server,
	config: Config,
) -> (
	ClientServerTransport,
	bool,
) {
	clientPrivateKey, privateKeyOK := common.identityPrivateKeyFromHex(config.private_key)
	clientPublicKey, publicKeyOK := common.identityPublicKeyFromHex(config.public_key)
	if !privateKeyOK || !publicKeyOK {
		return {}, false
	}

	clientEphemeralPrivateKey, clientEphemeralPublicKey, clientEphemeralOK :=
		common.generateKeyExchangeKeyPair()
	if !clientEphemeralOK {
		return {}, false
	}

	transport := ClientServerTransport {
			serverID                  = server.id,
			serverName                = strings.clone(server.name),
			serverHost                = strings.clone(server.host),
			serverPort                = server.port,
			clientIdentityPrivateKey  = clientPrivateKey,
			clientIdentityPublicKey   = clientPublicKey,
			clientEphemeralPrivateKey = clientEphemeralPrivateKey,
			clientEphemeralPublicKey  = clientEphemeralPublicKey,
			transport                 = common.TransportState_init(.Client),
		}
	return transport, true
}

ClientTransportCatalog_init :: proc(config: ^Config) -> [dynamic]ClientServerTransport {
	catalog := make([dynamic]ClientServerTransport, 0, len(config.servers))
	for server in config.servers {
		transport, ok := ClientServerTransport_init(server, config^)
		if ok {
			append(&catalog, transport)
		}
	}
	return catalog
}

ClientServerTransport_beginHandshake :: proc(transport: ^ClientServerTransport) -> ([]u8, bool) {
	transport.pendingKeysReady = false
	transport.transport.phase = .ClientHelloSent

	clientHello := common.ClientHello {
			version                  = common.protocolVersion,
			clientIdentityPublicKey  = transport.clientIdentityPublicKey,
			clientEphemeralPublicKey = transport.clientEphemeralPublicKey,
		}
	return common.buildPacketBytes(.ClientHello, clientHello)
}

ClientServerTransport_handleIncomingPacket :: proc(
	transport: ^ClientServerTransport,
	server: ^Server,
	config: ^Config,
	packetBytes: []u8,
) -> (
	ClientTransportResult,
	bool,
) {
	result: ClientTransportResult

	outerPacket: common.Packet
	if cbor.unmarshal(packetBytes, &outerPacket) != nil {
		ClientServerTransport_fail(transport, "invalid outer packet")
		return result, false
	}
	defer delete(outerPacket.payload)

	#partial switch outerPacket.messageType {
	case .ServerHello:
		if transport.transport.phase != .ClientHelloSent {
			ClientServerTransport_fail(transport, "unexpected ServerHello")
			return result, false
		}

		serverHello: common.ServerHello
		if cbor.unmarshal(outerPacket.payload, &serverHello) != nil {
			ClientServerTransport_fail(transport, "invalid ServerHello payload")
			return result, false
		}

		clientHello := common.ClientHello {
				version                  = common.protocolVersion,
				clientIdentityPublicKey  = transport.clientIdentityPublicKey,
				clientEphemeralPublicKey = transport.clientEphemeralPublicKey,
			}
		if !common.verifyServerHello(serverHello, clientHello) {
			ClientServerTransport_fail(transport, "server hello signature verification failed")
			return result, false
		}

		trustState, configChanged := pinServerIdentity(server, serverHello.serverIdentityPublicKey)
		transport.transport.peerTrustState = trustState
		if configChanged {
			saveConfig(config^)
		}
		transport.serverIdentityPublicKey = serverHello.serverIdentityPublicKey
		transport.serverEphemeralPublicKey = serverHello.serverEphemeralPublicKey
		transport.sessionID = serverHello.sessionID
		transport.transport.phase = .ServerHelloSent
		return result, true

	case .ServerAuthChallenge:
		if transport.transport.phase != .ServerHelloSent {
			ClientServerTransport_fail(transport, "unexpected auth challenge")
			return result, false
		}

		authChallenge: common.ServerAuthChallengePayload
		if cbor.unmarshal(outerPacket.payload, &authChallenge) != nil {
			ClientServerTransport_fail(transport, "invalid auth challenge payload")
			return result, false
		}

		requestSessionID := authChallenge.sessionID
		storedSessionID := transport.sessionID
		if !common.constantTimeEqual(requestSessionID[:], storedSessionID[:]) {
			ClientServerTransport_fail(transport, "auth challenge session ID mismatch")
			return result, false
		}

		transport.authChallenge = authChallenge.challenge
		clientAuthProof := common.buildClientAuthProof(
			transport.sessionID,
			transport.authChallenge,
			transport.clientIdentityPublicKey,
			transport.clientEphemeralPublicKey,
			transport.serverIdentityPublicKey,
			transport.serverEphemeralPublicKey,
		)
		clientAuthRequest, clientAuthRequestOK := common.signClientAuthRequest(
			transport.clientIdentityPrivateKey,
			clientAuthProof,
		)
		if !clientAuthRequestOK {
			ClientServerTransport_fail(transport, "failed to sign auth request")
			return result, false
		}

		sharedSecret, sharedSecretOK := common.deriveSharedSecret(
			&transport.clientEphemeralPrivateKey,
			transport.serverEphemeralPublicKey,
		)
		if !sharedSecretOK {
			ClientServerTransport_fail(transport, "failed to derive shared secret")
			return result, false
		}

		serverHelloProof := common.buildServerHelloProof(
			transport.sessionID,
			transport.clientIdentityPublicKey,
			transport.clientEphemeralPublicKey,
			transport.serverIdentityPublicKey,
			transport.serverEphemeralPublicKey,
		)
		transcriptHash, transcriptHashOK := common.deriveHandshakeTranscriptHash(
			serverHelloProof,
			clientAuthProof,
		)
		if !transcriptHashOK {
			ClientServerTransport_fail(transport, "failed to derive transcript hash")
			return result, false
		}

		transport.pendingKeys = common.deriveDirectionalTransportKeys(
			.Client,
			transport.sessionID,
			sharedSecret,
			transcriptHash,
		)
		transport.pendingKeysReady = true
		transport.transport.phase = .AwaitingAuthResult

		responsePacketBytes, responseOK := common.buildPacketBytes(
			.ClientAuthRequest,
			clientAuthRequest,
		)
		if !responseOK {
			ClientServerTransport_fail(transport, "failed to encode auth request packet")
			return result, false
		}

		result.responsePacketBytes = responsePacketBytes
		result.hasResponse = true
		return result, true

	case .ServerAuthSuccess:
		if transport.transport.phase != .AwaitingAuthResult || !transport.pendingKeysReady {
			ClientServerTransport_fail(transport, "unexpected auth success")
			return result, false
		}

		authSuccess: common.ServerAuthSuccessPayload
		if cbor.unmarshal(outerPacket.payload, &authSuccess) != nil {
			ClientServerTransport_fail(transport, "invalid auth success payload")
			return result, false
		}
		defer delete(authSuccess.message)

		common.TransportState_activate(
			&transport.transport,
			transport.sessionID,
			transport.pendingKeys,
			transport.transport.peerTrustState,
		)
		transport.pendingKeysReady = false
		transport.authenticatedUserID = authSuccess.userId
		return result, true

	case .ServerAuthFailure:
		authFailure: common.ServerAuthFailurePayload
		if cbor.unmarshal(outerPacket.payload, &authFailure) != nil {
			ClientServerTransport_fail(transport, "invalid auth failure payload")
			return result, false
		}
		defer delete(authFailure.message)
		ClientServerTransport_fail(transport, authFailure.message)
		return result, false

	case .EncryptedPacket:
		if !common.TransportState_canEncrypt(&transport.transport) {
			ClientServerTransport_fail(transport, "encrypted packet received before auth success")
			return result, false
		}

		innerPacket, openOK := common.openPacketForSession(&transport.transport, outerPacket)
		if !openOK {
			ClientServerTransport_fail(transport, "failed to open encrypted packet")
			return result, false
		}
		result.openedPacket = innerPacket
		result.hasOpenedPacket = true
		return result, true

	case .ServerProtocolError:
		protocolError: common.ProtocolErrorResponse
		if cbor.unmarshal(outerPacket.payload, &protocolError) == nil {
			defer delete(protocolError.message)
			ClientServerTransport_fail(transport, protocolError.message)
		} else {
			ClientServerTransport_fail(transport, "server protocol error")
		}
		return result, false

	case:
		ClientServerTransport_fail(
			transport,
			fmt.aprintf("unexpected server message type: %v", outerPacket.messageType),
		)
		return result, false
	}
}

ClientServerTransport_buildEncryptedPacketBytes :: proc(
	transport: ^ClientServerTransport,
	messageType: common.MessageType,
	payload: any,
) -> (
	[]u8,
	bool,
) {
	if !common.TransportState_canEncrypt(&transport.transport) {
		ClientServerTransport_fail(transport, "transport not established")
		return nil, false
	}

	sealedPacket, sealOK := common.sealPacketForSession(&transport.transport, messageType, payload)
	if !sealOK {
		ClientServerTransport_fail(transport, "failed to seal encrypted packet")
		return nil, false
	}
	defer delete(sealedPacket.payload)

	packetBytes, packetErr := cbor.marshal(sealedPacket)
	if packetErr != nil {
		ClientServerTransport_fail(transport, "failed to marshal encrypted packet")
		return nil, false
	}
	return packetBytes, true
}
