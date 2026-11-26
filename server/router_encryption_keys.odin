package server

import "../common"
import "core:encoding/cbor"

// Account encryption keys (protocol 16, e2ee-design.md 3.1-3.2):
//
// - ClientPublishEncryptionKey: the bundle is verified against the session's own identity key
//   (verifyEncryptionKeyBundle on a bundle whose identity key is the session's), so an account
//   can only publish a key signed by itself. Then it is stored (database_encryption_keys.odin):
//   an identical bundle changes nothing, and a first or different bundle is sent to every
//   authenticated session as ServerUserKeyChanged.
// - ClientFetchUserKeys: 1..USER_KEYS_FETCH_MAX distinct positive IDs, answered with
//   ServerUserKeys (the bundles, and the requested IDs that have none). Protocol 25 (D17,
//   #103): an account the requester may not see is listed in missingUserIds exactly like an
//   unknown ID (DATABASE_FETCH_USER_KEYS_VISIBLE_SQL).
//
// Both decode with the heap as CBOR's temporary allocator: fixed-size byte strings are decoded
// through it, and the router never frees the temporary allocator.

ENCRYPTION_KEY_UNAUTHENTICATED_MESSAGE :: "Unauthenticated encryption key request"

MainRouterState_handleClientPublishEncryptionKey :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	userID, ok := MainRouterState_authenticatedUserID(
		pm,
		state,
		peerID,
		ENCRYPTION_KEY_UNAUTHENTICATED_MESSAGE,
	)
	if !ok {
		return
	}
	session, sessionOK := MainRouterState_getPeerSession(state, peerID)
	if !sessionOK {
		return
	}
	req: common.ClientPublishEncryptionKeyPayload
	if cbor.unmarshal(payload, &req, temp_allocator = context.allocator) != nil ||
	   req.createdAt > u64(max(i64)) {
		MainRouterState_sendProtocolError(pm, state, peerID, common.ENCRYPTION_KEY_INVALID_MESSAGE)
		return
	}
	bundle := common.EncryptionKeyBundle {
		identityPublicKey   = session.clientIdentityPublicKey,
		encryptionPublicKey = req.encryptionPublicKey,
		createdAt           = req.createdAt,
		signature           = req.signature,
	}
	if !common.verifyEncryptionKeyBundle(bundle) {
		MainRouterState_sendProtocolError(pm, state, peerID, common.ENCRYPTION_KEY_INVALID_MESSAGE)
		return
	}
	MainRouterState_enqueueChannelDatabaseRequest(
		pm,
		state,
		peerID,
		common.DatabasePublishEncryptionKeyRequest {
			userId = userID,
			encryptionPublicKey = req.encryptionPublicKey,
			createdAt = req.createdAt,
			signature = req.signature,
		},
		PendingDBRequest{requestType = .PublishEncryptionKey},
	)
}

MainRouterState_handleClientFetchUserKeys :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	userID, ok := MainRouterState_authenticatedUserID(
		pm,
		state,
		peerID,
		ENCRYPTION_KEY_UNAUTHENTICATED_MESSAGE,
	)
	if !ok {
		return
	}
	req: common.ClientFetchUserKeysPayload
	decodeErr := cbor.unmarshal(payload, &req, temp_allocator = context.allocator)
	if decodeErr != nil || !common.userKeysFetchIsValid(req.userIds[:]) {
		common.ClientFetchUserKeysPayload_deinit(&req)
		MainRouterState_sendProtocolError(
			pm,
			state,
			peerID,
			common.USER_KEYS_INVALID_REQUEST_MESSAGE,
		)
		return
	}
	// The request takes the decoded array; the database side frees it.
	MainRouterState_enqueueChannelDatabaseRequest(
		pm,
		state,
		peerID,
		common.DatabaseFetchUserKeysRequest{requesterUserId = userID, userIds = req.userIds},
		PendingDBRequest{requestType = .FetchUserKeys},
	)
}

MainRouterState_handlePublishEncryptionKeyResult :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	request: PendingDBRequest,
	response: common.DatabaseQueryResponse,
) {
	published, publishedOK := response.result.(common.DatabasePublishEncryptionKeyResult)
	if MainRouterState_databaseFailed(pm, state, request.peerID, response, publishedOK) {
		return
	}
	if !published.stored {
		return
	}
	// Protocol 25 (D17): only to sessions that may see the account.
	userID := published.bundle.userId
	MainRouterState_sendAboutUser(
		pm,
		state,
		userID,
		MainRouterState_userIsRestricted(state, userID),
		0,
		MainRouterVisibilityPayload{kind = .KeyChanged, keyBundle = published.bundle},
	)
}

MainRouterState_handleFetchUserKeysResult :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	request: PendingDBRequest,
	response: common.DatabaseQueryResponse,
) {
	fetched, fetchedOK := response.result.(common.DatabaseFetchUserKeysResult)
	if MainRouterState_databaseFailed(pm, state, request.peerID, response, fetchedOK) {
		return
	}
	MainRouterState_sendPeerMessage(
		pm,
		state,
		request.peerID,
		.ServerUserKeys,
		common.ServerUserKeysPayload {
			keys = fetched.keys,
			missingUserIds = fetched.missingUserIds,
		},
	)
}
