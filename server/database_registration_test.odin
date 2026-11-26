package server

import "../common"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "shared:pg"

// Registration statements (protocol 25, #43 G1) against a real PostgreSQL when
// HAYCHAT_DATABASE_SQL_TEST=1, each in a schema of its own that is rolled back
// (databaseAdminTestOpen).

// A new invite code stored with the given columns (SQL expressions); returns the code and the
// row's ID.
@(private = "file")
registrationTestCode :: proc(
	conn: pg.Conn,
	columns := "",
	values := "",
) -> (
	code: common.InviteCodeBytes,
	id: int,
) {
	generated, ok := common.generateInviteCode()
	assert(ok, "expected a random invite code")
	hash := common.inviteCodeHash(generated)
	hashHex := common.encodeBytesToHex(hash[:])
	defer delete(hashHex)
	extraColumns := len(columns) > 0 ? fmt.tprintf(", %s", columns) : ""
	extraValues := len(values) > 0 ? fmt.tprintf(", %s", values) : ""
	value := databaseAdminTestValue(
		conn,
		fmt.tprintf(
			"INSERT INTO invites (code_hash%s) VALUES (decode('%s', 'hex')%s) RETURNING id::text",
			extraColumns,
			hashHex,
			extraValues,
		),
	)
	parsed, parsedOK := databaseParseTestInt(value)
	assert(parsedOK, fmt.tprintf("expected an invite ID, got %q", value))
	return generated, parsed
}

@(private = "file")
registrationTestRole :: proc(
	conn: pg.Conn,
	name: string,
	permissions: common.ServerPermissions,
) -> int {
	value := databaseAdminTestValue(
		conn,
		fmt.tprintf(
			"INSERT INTO server_roles (name, permissions) VALUES ('%s', %d) RETURNING id::text",
			name,
			common.serverPermissionsMask(permissions),
		),
	)
	id, ok := databaseParseTestInt(value)
	assert(ok, fmt.tprintf("expected a role ID, got %q", value))
	return id
}

@(private = "file")
registrationTestHold :: proc(conn: pg.Conn, userID, roleID: int) {
	databaseDefaultRoomTestExec(
		conn,
		"hold a role",
		fmt.tprintf("INSERT INTO user_server_roles VALUES (%d, %d)", userID, roleID),
	)
}

@(private = "file")
registrationTestMode :: proc(conn: pg.Conn, mode: common.RegistrationMode) {
	databaseDefaultRoomTestExec(
		conn,
		"set the mode",
		fmt.tprintf("UPDATE server_settings SET registration_mode = %d", int(mode)),
	)
}

// Runs one register statement. Strings move to the temp allocator.
@(private = "file")
registrationTestRegister :: proc(
	conn: pg.Conn,
	key: common.IdentityPublicKeyBytes,
	nickname: string,
	code: common.InviteCodeBytes,
	hasCode := true,
	reason := "",
) -> common.DatabaseRegisterResult {
	response := databaseExecuteRequest(
		conn,
		common.DatabaseRegisterRequest {
			publicKey = key,
			nickname = nickname,
			codeHash = common.inviteCodeHash(code),
			hasCode = hasCode,
			reason = reason,
		},
	)
	result, resultOK := response.result.(common.DatabaseRegisterResult)
	assert(
		response.success && resultOK,
		fmt.tprintf("expected the register statement to run: %s", response.message),
	)
	delete(response.message)
	result.nickname = strings.clone(result.nickname, context.temp_allocator)
	delete(response.result.(common.DatabaseRegisterResult).nickname)
	result.roleIds = slice.clone_to_dynamic(result.roleIds[:], context.temp_allocator)
	delete(response.result.(common.DatabaseRegisterResult).roleIds)
	request := result.request
	result.request = common.RegistrationRequestSummary_clone(request, context.temp_allocator)
	common.RegistrationRequestSummary_deinit(&request)
	return result
}

@(private = "file")
registrationTestUses :: proc(conn: pg.Conn, inviteID: int) -> string {
	return databaseAdminTestValue(
		conn,
		fmt.tprintf("SELECT uses::text FROM invites WHERE id = %d", inviteID),
	)
}

// Runs the identity statement with registering and the admin key. Strings move to the temp
// allocator.
@(private = "file")
registrationTestIdentity :: proc(
	conn: pg.Conn,
	nickname: string,
	key: common.IdentityPublicKeyBytes,
	registering := false,
	adminKey: common.IdentityPublicKeyBytes = {},
	hasAdminKey := false,
) -> common.DatabaseUserIdentityResult {
	response := databaseExecuteRequest(
		conn,
		common.DatabaseUserIdentityRequest {
			nickname = nickname,
			publicKey = key,
			adminPublicKey = adminKey,
			hasAdminPublicKey = hasAdminKey,
			registering = registering,
		},
	)
	identity, identityOK := response.result.(common.DatabaseUserIdentityResult)
	assert(
		response.success && identityOK,
		fmt.tprintf("expected the identity statement to run: %s", response.message),
	)
	delete(response.message)
	result := identity
	result.nickname = strings.clone(identity.nickname, context.temp_allocator)
	result.previousNickname = strings.clone(identity.previousNickname, context.temp_allocator)
	result.banReason = strings.clone(identity.banReason, context.temp_allocator)
	result.decisionReason = strings.clone(identity.decisionReason, context.temp_allocator)
	result.roleIds = slice.clone_to_dynamic(identity.roleIds[:], context.temp_allocator)
	result.declinedRequest = common.RegistrationRequestSummary_clone(
		identity.declinedRequest,
		context.temp_allocator,
	)
	common.RegistrationRequestSummary_deinit(&identity.declinedRequest)
	delete(identity.roleIds)
	delete(identity.nickname)
	delete(identity.previousNickname)
	delete(identity.banReason)
	delete(identity.decisionReason)
	return result
}

@(private = "file")
registrationTestRooms :: proc(conn: pg.Conn, userID: int) -> string {
	return databaseAdminTestValue(
		conn,
		fmt.tprintf(
			"SELECT COALESCE(string_agg(r.name, ',' ORDER BY r.name), '') FROM rooms r " +
			"JOIN room_members m ON m.room_id = r.id WHERE m.user_id = %d",
			userID,
		),
	)
}

@(private = "file")
registrationTestRoom :: proc(conn: pg.Conn, name: string, access: int, encrypted := false) -> int {
	value := databaseAdminTestValue(
		conn,
		fmt.tprintf(
			"INSERT INTO rooms (name, access, encrypted) VALUES ('%s', %d, %v) RETURNING id::text",
			name,
			access,
			encrypted,
		),
	)
	id, ok := databaseParseTestInt(value)
	assert(ok, fmt.tprintf("expected a room ID, got %q", value))
	return id
}

@(private = "file")
registrationTestJoin :: proc(conn: pg.Conn, roomID, userID: int) {
	databaseDefaultRoomTestExec(
		conn,
		"join a room",
		fmt.tprintf("INSERT INTO room_members (room_id, user_id) VALUES (%d, %d)", roomID, userID),
	)
}

// D9, D11, D13: every branch of DATABASE_REGISTER_SQL and the uses it counts.
@(test)
testRegisterStatementAgainstPostgreSQL :: proc(t: ^testing.T) {
	_ = t
	if os.get_env(DATABASE_SQL_TEST_ENV, context.temp_allocator) != "1" {
		return
	}
	conn := databaseAdminTestOpen(t, "register")
	general := registrationTestRoom(conn, "reg-general", 1)
	_ = general
	club := registrationTestRoom(conn, "reg-club", 2)
	sealed := registrationTestRoom(conn, "reg-sealed", 3, encrypted = true)
	role := registrationTestRole(conn, "reg-inviter", {.CreateInvites})
	roleRoom := registrationTestRoom(conn, "reg-role-room", 4)
	databaseDefaultRoomTestExec(
		conn,
		"give the role room its role",
		fmt.tprintf("INSERT INTO room_access_roles VALUES (%d, %d)", roleRoom, role),
	)

	// Open without a code creates a plain account in the Public rooms.
	{
		result := registrationTestRegister(conn, databaseIdentityTestKey(), "reg-open", {}, false)
		assert(
			result.outcome == .Created && result.userId > 0 && !result.isRestricted,
			fmt.tprintf("expected an Open sign-up without a code, got %v", result),
		)
		assert(
			registrationTestRooms(conn, result.userId) == "reg-general",
			"expected the Public room only",
		)
	}

	// Invite only: no code and unknown, revoked, expired and used-up codes are all invalid.
	registrationTestMode(conn, .InviteOnly)
	{
		result := registrationTestRegister(conn, databaseIdentityTestKey(), "reg-none", {}, false)
		assert(result.outcome == .InvalidCode, "expected no code refused in Invite only")
		unknown, _ := common.generateInviteCode()
		result = registrationTestRegister(conn, databaseIdentityTestKey(), "reg-unknown", unknown)
		assert(result.outcome == .InvalidCode, "expected an unknown code refused")
		revoked, revokedID := registrationTestCode(conn, "revoked_at", "CURRENT_TIMESTAMP")
		result = registrationTestRegister(conn, databaseIdentityTestKey(), "reg-revoked", revoked)
		assert(result.outcome == .InvalidCode, "expected a revoked code refused")
		assert(registrationTestUses(conn, revokedID) == "0", "expected no use counted")
		expired, _ := registrationTestCode(
			conn,
			"expires_at",
			"CURRENT_TIMESTAMP - interval '1 minute'",
		)
		result = registrationTestRegister(conn, databaseIdentityTestKey(), "reg-expired", expired)
		assert(result.outcome == .InvalidCode, "expected an expired code refused")
		usedUp, _ := registrationTestCode(conn, "max_uses, uses", "1, 1")
		result = registrationTestRegister(conn, databaseIdentityTestKey(), "reg-used", usedUp)
		assert(result.outcome == .InvalidCode, "expected a used-up code refused")
	}

	// A plain code with one use: the first sign-up takes it, a taken name counts nothing, and
	// the second account is refused.
	{
		code, codeID := registrationTestCode(conn, "max_uses", "1")
		taken := registrationTestRegister(conn, databaseIdentityTestKey(), "reg-open", code)
		assert(taken.outcome == .NameTaken, "expected a taken name refused")
		assert(registrationTestUses(conn, codeID) == "0", "expected a refusal to count nothing")
		key := databaseIdentityTestKey()
		first := registrationTestRegister(conn, key, "reg-plain", code)
		assert(
			first.outcome == .Created && first.inviteId == codeID,
			fmt.tprintf("expected the plain code to create an account, got %v", first),
		)
		assert(registrationTestUses(conn, codeID) == "1", "expected the use counted")
		again := registrationTestRegister(conn, key, "reg-plain-2", code)
		assert(again.outcome == .HasAccount, "expected a key with an account refused")
		second := registrationTestRegister(conn, databaseIdentityTestKey(), "reg-plain-3", code)
		assert(second.outcome == .InvalidCode, "expected the used-up code refused")
		invite := databaseAdminTestValue(
			conn,
			fmt.tprintf("SELECT invite_id::text FROM users WHERE id = %d", first.userId),
		)
		assert(invite == fmt.tprintf("%d", codeID), "expected users.invite_id to name the code")
	}

	// A room code with a role: restricted, joins only its room and the role's Role room, holds
	// the role, and its permissions come back.
	{
		code, _ := registrationTestCode(
			conn,
			"room_id, restricted",
			fmt.tprintf("%d, true", club),
		)
		databaseDefaultRoomTestExec(
			conn,
			"give the code a role",
			fmt.tprintf(
				"INSERT INTO invite_roles SELECT id, %d FROM invites ORDER BY id DESC LIMIT 1",
				role,
			),
		)
		result := registrationTestRegister(conn, databaseIdentityTestKey(), "reg-room", code)
		assert(
			result.outcome == .Created &&
			result.isRestricted &&
			result.permissions == {.CreateInvites},
			fmt.tprintf("expected a restricted account with the role, got %v", result),
		)
		rooms := registrationTestRooms(conn, result.userId)
		assert(
			rooms == "reg-club,reg-role-room",
			fmt.tprintf("expected only the code's room and the role room, got %q", rooms),
		)
		// A room code whose room became encrypted or Public no longer works.
		bad, _ := registrationTestCode(conn, "room_id, restricted", fmt.tprintf("%d, true", sealed))
		refused := registrationTestRegister(conn, databaseIdentityTestKey(), "reg-sealed", bad)
		assert(refused.outcome == .InvalidCode, "expected a code for an encrypted room refused")
	}

	// Invite + approval: a reason is required, the request counts a use once, a second one is
	// already pending, a declined request is replaced, and skip approval creates at once.
	registrationTestMode(conn, .InviteApproval)
	{
		code, codeID := registrationTestCode(conn)
		key := databaseIdentityTestKey()
		noReason := registrationTestRegister(conn, key, "reg-applicant", code)
		assert(noReason.outcome == .ReasonRequired, "expected a reason required")
		pending := registrationTestRegister(conn, key, "reg-applicant", code, reason = "I know bob")
		assert(
			pending.outcome == .Pending &&
			pending.request.id > 0 &&
			pending.request.status == .Pending &&
			pending.request.reason == "I know bob" &&
			pending.request.nickname == "reg-applicant" &&
			pending.request.inviteId == codeID &&
			pending.request.identityPublicKey == key &&
			pending.pendingCount == 1,
			fmt.tprintf("expected a pending request, got %v", pending),
		)
		assert(registrationTestUses(conn, codeID) == "1", "expected the request to count a use")
		again := registrationTestRegister(conn, key, "reg-applicant", code, reason = "again")
		assert(again.outcome == .AlreadyPending, "expected the second request refused")
		assert(registrationTestUses(conn, codeID) == "1", "expected no second use")
		databaseDefaultRoomTestExec(
			conn,
			"decline it",
			fmt.tprintf(
				"UPDATE registration_requests SET status = 3, decision_reason = 'no' " +
				"WHERE id = %d",
				pending.request.id,
			),
		)
		replaced := registrationTestRegister(conn, key, "reg-applicant", code, reason = "please")
		assert(
			replaced.outcome == .Pending &&
			replaced.request.id == pending.request.id &&
			replaced.request.reason == "please" &&
			len(replaced.request.decisionReason) == 0,
			fmt.tprintf("expected the declined request replaced, got %v", replaced),
		)
		assert(registrationTestUses(conn, codeID) == "2", "expected the new request counted")

		skip, _ := registrationTestCode(conn, "skip_approval", "true")
		created := registrationTestRegister(conn, databaseIdentityTestKey(), "reg-skip", skip)
		assert(created.outcome == .Created, "expected skip approval to create the account")
	}
}

// D12, D14, D15: the identity statement's registration paths.
@(test)
testIdentityRegistrationPathsAgainstPostgreSQL :: proc(t: ^testing.T) {
	_ = t
	if os.get_env(DATABASE_SQL_TEST_ENV, context.temp_allocator) != "1" {
		return
	}
	conn := databaseAdminTestOpen(t, "identity_registration")
	registrationTestRoom(conn, "idr-general", 1)
	club := registrationTestRoom(conn, "idr-club", 2)

	// Open: unchanged, but a client that asks to register is told to.
	{
		open := registrationTestIdentity(conn, "idr-open", databaseIdentityTestKey())
		assert(
			open.userId > 0 && !open.needsRegistration && open.registrationMode == .Open,
			fmt.tprintf("expected an Open sign-in, got %v", open),
		)
		asked := registrationTestIdentity(
			conn,
			"idr-asked",
			databaseIdentityTestKey(),
			registering = true,
		)
		assert(
			asked.userId == 0 && asked.needsRegistration && asked.requestStatus == .None,
			fmt.tprintf("expected registering to need a sign-up, got %v", asked),
		)
	}

	registrationTestMode(conn, .InviteOnly)
	{
		// An unknown key must sign up, and creates nothing; a keyless account is not claimable.
		key := databaseIdentityTestKey()
		required := registrationTestIdentity(conn, "idr-new", key)
		assert(
			required.userId == 0 &&
			required.needsRegistration &&
			required.registrationMode == .InviteOnly,
			fmt.tprintf("expected a sign-up required, got %v", required),
		)
		count := databaseAdminTestValue(
			conn,
			"SELECT count(*)::text FROM users WHERE nickname = 'idr-new'",
		)
		assert(count == "0", "expected no account created")
		databaseAdminTestUser(conn, "idr-keyless")
		claim := registrationTestIdentity(conn, "idr-keyless", databaseIdentityTestKey())
		assert(claim.userId == 0 && claim.needsRegistration, "expected no claim in Invite only")

		// The admin key bootstraps in any mode, unrestricted.
		adminKey := databaseIdentityTestKey()
		bootstrap := registrationTestIdentity(
			conn,
			"idr-owner",
			adminKey,
			adminKey = adminKey,
			hasAdminKey = true,
		)
		assert(
			bootstrap.userId > 0 && !bootstrap.isRestricted && !bootstrap.needsRegistration,
			fmt.tprintf("expected the admin key to sign up, got %v", bootstrap),
		)

		// An existing account signs in whatever the mode and registering say.
		again := registrationTestIdentity(conn, "idr-owner", adminKey, registering = true)
		assert(again.userId == bootstrap.userId, "expected the account to sign in")
	}

	// Requests: pending, declined with its reason, then approved: the account is created with
	// the code's room and restriction, and the request is gone.
	{
		code, codeID := registrationTestCode(
			conn,
			"room_id, restricted",
			fmt.tprintf("%d, true", club),
		)
		_ = code
		key := databaseIdentityTestKey()
		keyHex := common.identityPublicKeyToHex(key)
		defer delete(keyHex)
		databaseDefaultRoomTestExec(
			conn,
			"make a request",
			fmt.tprintf(
				"INSERT INTO registration_requests (public_key, nickname, reason, invite_id) " +
				"VALUES (decode('%s', 'hex'), 'idr-applicant', 'hi', %d)",
				keyHex,
				codeID,
			),
		)
		pending := registrationTestIdentity(conn, "idr-applicant", key)
		assert(
			pending.needsRegistration && pending.requestStatus == .Pending,
			fmt.tprintf("expected the pending request reported, got %v", pending),
		)
		databaseDefaultRoomTestExec(
			conn,
			"decline it",
			"UPDATE registration_requests SET status = 3, decision_reason = 'not now'",
		)
		declined := registrationTestIdentity(conn, "idr-applicant", key)
		assert(
			declined.needsRegistration &&
			declined.requestStatus == .Declined &&
			declined.decisionReason == "not now",
			fmt.tprintf("expected the decline and its reason, got %v", declined),
		)
		databaseDefaultRoomTestExec(
			conn,
			"approve it",
			"UPDATE registration_requests SET status = 2",
		)
		// A name taken in the meantime is the usual refusal, and the approval stays.
		databaseDefaultRoomTestExec(
			conn,
			"take the name",
			"INSERT INTO users (nickname, public_key) VALUES ('idr-taken', " +
			"decode(repeat('ab', 32), 'hex'))",
		)
		taken := registrationTestIdentity(conn, "idr-taken", key)
		assert(
			taken.userId == 0 && !taken.needsRegistration,
			fmt.tprintf("expected a name in use refusal, got %v", taken),
		)
		approved := registrationTestIdentity(conn, "idr-other-name", key)
		assert(
			approved.userId > 0 && approved.isRestricted && approved.nickname == "idr-other-name",
			fmt.tprintf("expected the approved account created, got %v", approved),
		)
		rooms := registrationTestRooms(conn, approved.userId)
		assert(rooms == "idr-club", fmt.tprintf("expected only the code's room, got %q", rooms))
		left := databaseAdminTestValue(conn, "SELECT count(*)::text FROM registration_requests")
		assert(left == "0", "expected the completed request deleted")
	}
}

// D10: who may create, list and revoke codes, and what they may attach.
@(test)
testInviteStatementsAgainstPostgreSQL :: proc(t: ^testing.T) {
	_ = t
	if os.get_env(DATABASE_SQL_TEST_ENV, context.temp_allocator) != "1" {
		return
	}
	conn := databaseAdminTestOpen(t, "invites")
	admin := databaseAdminTestUser(conn, "inv-admin")
	databaseAdminTestGrant(conn, admin)
	inviter := databaseAdminTestUser(conn, "inv-bob")
	inviterRole := registrationTestRole(conn, "inv-inviters", {.CreateInvites})
	registrationTestHold(conn, inviter, inviterRole)
	nobody := databaseAdminTestUser(conn, "inv-carol")
	public := registrationTestRoom(conn, "inv-public", 1)
	club := registrationTestRoom(conn, "inv-club", 3)
	sealed := registrationTestRoom(conn, "inv-sealed", 2, encrypted = true)
	roleRoom := registrationTestRoom(conn, "inv-role", 4)
	adminRole := databaseAdminTestValue(conn, "SELECT id::text FROM server_roles WHERE builtin")
	adminRoleID, _ := databaseParseTestInt(adminRole)

	create :: proc(
		conn: pg.Conn,
		actor: int,
		expires := 3600,
		uses := 0,
		roles: []int = nil,
		room := 0,
		skip := false,
	) -> common.DatabaseInviteResult {
		code, _ := common.generateInviteCode()
		roleIDs := make([dynamic]int, 0, len(roles))
		append(&roleIDs, ..roles)
		defer delete(roleIDs)
		response := databaseExecuteRequest(
			conn,
			common.DatabaseInviteRequest {
				action = .Create,
				actorUserId = actor,
				codeHash = common.inviteCodeHash(code),
				note = "test",
				expiresInSeconds = expires,
				maxUses = uses,
				roleIds = roleIDs,
				roomId = room,
				skipApproval = skip,
			},
		)
		result, ok := response.result.(common.DatabaseInviteResult)
		assert(response.success && ok, fmt.tprintf("expected a create: %s", response.message))
		delete(response.message)
		copy := result
		copy.invite.note = strings.clone(result.invite.note, context.temp_allocator)
		copy.invite.createdByNickname = strings.clone(
			result.invite.createdByNickname,
			context.temp_allocator,
		)
		copy.invite.createdAt = strings.clone(result.invite.createdAt, context.temp_allocator)
		copy.invite.expiresAt = strings.clone(result.invite.expiresAt, context.temp_allocator)
		copy.invite.roleIds = make([dynamic]int, len(result.invite.roleIds), context.temp_allocator)
		for roleID, index in result.invite.roleIds {
			copy.invite.roleIds[index] = roleID
		}
		invite := result.invite
		common.InviteSummary_deinit(&invite)
		return copy
	}

	assert(create(conn, nobody).outcome == .NotPermitted, "expected no permission refused")
	plain := create(conn, inviter, uses = 3)
	assert(
		plain.outcome == .Applied &&
		plain.invite.createdBy == inviter &&
		plain.invite.createdByNickname == "inv-bob" &&
		plain.invite.maxUses == 3 &&
		len(plain.invite.expiresAt) > 0 &&
		!plain.invite.restricted,
		fmt.tprintf("expected the inviter's plain code, got %v", plain),
	)
	assert(
		create(conn, inviter, roles = {inviterRole}).outcome == .AdminRequired,
		"expected roles admin only",
	)
	assert(create(conn, inviter, room = club).outcome == .AdminRequired, "expected room admin only")
	assert(create(conn, inviter, skip = true).outcome == .AdminRequired, "expected skip admin only")
	assert(create(conn, inviter, expires = 0).outcome == .ExpiryTooLong, "expected an expiry")
	assert(
		create(conn, inviter, expires = common.INVITE_INVITER_EXPIRY_MAX_SECONDS + 1).outcome ==
		.ExpiryTooLong,
		"expected at most 7 days",
	)
	assert(
		create(conn, admin, roles = {adminRoleID}).outcome == .UnknownRole,
		"expected the admin role refused",
	)
	assert(create(conn, admin, roles = {999_999}).outcome == .UnknownRole, "expected unknown")
	for room in ([]int{public, sealed, roleRoom, 999_999}) {
		assert(create(conn, admin, room = room).outcome == .BadRoom, "expected the room refused")
	}
	full := create(conn, admin, expires = 0, roles = {inviterRole}, room = club, skip = true)
	assert(
		full.outcome == .Applied &&
		full.invite.restricted &&
		full.invite.roomId == club &&
		full.invite.skipApproval &&
		len(full.invite.expiresAt) == 0 &&
		len(full.invite.roleIds) == 1 &&
		full.invite.roleIds[0] == inviterRole,
		fmt.tprintf("expected the admin's full code, got %v", full),
	)

	list :: proc(conn: pg.Conn, actor: int) -> (common.DatabaseInviteOutcome, []int) {
		response := databaseExecuteRequest(
			conn,
			common.DatabaseInviteRequest{action = .List, actorUserId = actor},
		)
		defer IPC__database_query_response_deinit(response)
		result := response.result.(common.DatabaseInviteResult)
		ids := make([dynamic]int, context.temp_allocator)
		for invite in result.invites {
			append(&ids, invite.id)
		}
		return result.outcome, ids[:]
	}
	outcome: common.DatabaseInviteOutcome
	adminIDs, inviterIDs: []int
	outcome, adminIDs = list(conn, admin)
	assert(outcome == .Applied && len(adminIDs) == 2, "expected admins to see every code")
	outcome, inviterIDs = list(conn, inviter)
	assert(
		outcome == .Applied && len(inviterIDs) == 1 && inviterIDs[0] == plain.invite.id,
		"expected the inviter to see only its own code",
	)
	outcome, _ = list(conn, nobody)
	assert(outcome == .NotPermitted, "expected others refused the list")

	revoke :: proc(conn: pg.Conn, actor, id: int) -> common.DatabaseInviteResult {
		response := databaseExecuteRequest(
			conn,
			common.DatabaseInviteRequest{action = .Revoke, actorUserId = actor, inviteId = id},
		)
		defer IPC__database_query_response_deinit(response)
		return response.result.(common.DatabaseInviteResult)
	}
	assert(
		revoke(conn, inviter, full.invite.id).outcome == .UnknownInvite,
		"expected someone else's code hidden",
	)
	own := revoke(conn, inviter, plain.invite.id)
	assert(own.outcome == .Applied && own.changed, "expected the inviter to revoke its code")
	twice := revoke(conn, inviter, plain.invite.id)
	assert(twice.outcome == .Applied && !twice.changed, "expected a second revoke a no-op")
	any := revoke(conn, admin, full.invite.id)
	assert(any.outcome == .Applied && any.changed, "expected admins to revoke any code")

	// A non-admin holds at most INVITES_ACTIVE_MAX_PER_INVITER usable codes.
	for _ in 0 ..< common.INVITES_ACTIVE_MAX_PER_INVITER {
		assert(create(conn, inviter).outcome == .Applied, "expected the inviter's codes")
	}
	assert(create(conn, inviter).outcome == .TooManyInvites, "expected the cap")
}

// D14, D18: listing and deciding sign-up requests.
@(test)
testRegistrationRequestStatementsAgainstPostgreSQL :: proc(t: ^testing.T) {
	_ = t
	if os.get_env(DATABASE_SQL_TEST_ENV, context.temp_allocator) != "1" {
		return
	}
	conn := databaseAdminTestOpen(t, "registration_requests")
	approver := databaseAdminTestUser(conn, "req-approver")
	approverRole := registrationTestRole(conn, "req-approvers", {.ApproveRegistrations})
	registrationTestHold(conn, approver, approverRole)
	nobody := databaseAdminTestUser(conn, "req-nobody")
	registrationTestMode(conn, .InviteApproval)
	code, _ := registrationTestCode(conn, "note", "'for friends'")
	first := registrationTestRegister(conn, databaseIdentityTestKey(), "req-1", code, reason = "a")
	second := registrationTestRegister(conn, databaseIdentityTestKey(), "req-2", code, reason = "b")
	assert(first.outcome == .Pending && second.pendingCount == 2, "expected two requests")

	run :: proc(
		conn: pg.Conn,
		request: common.DatabaseRegistrationRequestsRequest,
	) -> (
		outcome: common.DatabaseRegistrationRequestsOutcome,
		ids: []int,
		pending: int,
		status: common.RegistrationRequestStatus,
	) {
		response := databaseExecuteRequest(conn, request)
		defer IPC__database_query_response_deinit(response)
		assert(response.success, response.message)
		result := response.result.(common.DatabaseRegistrationRequestsResult)
		listed := make([dynamic]int, context.temp_allocator)
		for summary in result.requests {
			append(&listed, summary.id)
			assert(summary.inviteNote == "for friends", "expected the code's note")
		}
		return result.outcome, listed[:], result.pendingCount, result.request.status
	}
	outcome: common.DatabaseRegistrationRequestsOutcome
	ids: []int
	pending: int
	status: common.RegistrationRequestStatus
	outcome, _, _, _ = run(conn, {action = .List, actorUserId = nobody})
	assert(outcome == .NotPermitted, "expected non-approvers refused the list")
	outcome, ids, pending, _ = run(conn, {action = .List, actorUserId = approver})
	assert(
		outcome == .Applied &&
		pending == 2 &&
		len(ids) == 2 &&
		ids[0] == first.request.id &&
		ids[1] == second.request.id,
		fmt.tprintf("expected both pending requests, oldest first, got %v", ids),
	)
	outcome, _, _, _ = run(conn, {action = .Decide, actorUserId = nobody, requestId = ids[0]})
	assert(outcome == .NotPermitted, "expected non-approvers refused a decision")
	outcome, _, pending, status = run(
		conn,
		{action = .Decide, actorUserId = approver, requestId = ids[0], approve = true},
	)
	assert(
		outcome == .Applied && pending == 1 && status == .Approved,
		"expected the approval and one request left",
	)
	outcome, _, _, _ = run(
		conn,
		{action = .Decide, actorUserId = approver, requestId = ids[0], approve = false},
	)
	assert(outcome == .AlreadyDecided, "expected a second decision refused")
	outcome, _, _, _ = run(conn, {action = .Decide, actorUserId = approver, requestId = 999_999})
	assert(outcome == .UnknownRequest, "expected an unknown request")
	outcome, _, pending, status = run(
		conn,
		{
			action = .Decide,
			actorUserId = approver,
			requestId = ids[1],
			approve = false,
			reason = "sorry",
		},
	)
	assert(outcome == .Applied && pending == 0 && status == .Declined, "expected the decline")
	outcome, ids, _, _ = run(conn, {action = .List, actorUserId = approver})
	assert(len(ids) == 0, "expected no pending request left")
	outcome, ids, _, _ = run(conn, {action = .List, actorUserId = approver, includeDecided = true})
	assert(len(ids) == 2, "expected the decided requests with includeDecided")
}

// D11, D17: restricted accounts in the user list, direct messages, room adds, Public rooms,
// and lifting the restriction.
@(test)
testRestrictedAccountsAgainstPostgreSQL :: proc(t: ^testing.T) {
	_ = t
	if os.get_env(DATABASE_SQL_TEST_ENV, context.temp_allocator) != "1" {
		return
	}
	conn := databaseAdminTestOpen(t, "restricted")
	admin := databaseAdminTestUser(conn, "rst-admin")
	databaseAdminTestGrant(conn, admin)
	bob := databaseSQLTestCreateUser(conn, "rst-bob")
	carol := databaseSQLTestCreateUser(conn, "rst-carol")
	erin := databaseSQLTestCreateUser(conn, "rst-erin")
	approver := databaseAdminTestUser(conn, "rst-approver")
	approverRole := registrationTestRole(conn, "rst-approvers", {.ApproveRegistrations})
	registrationTestHold(conn, approver, approverRole)
	club := registrationTestRoom(conn, "rst-club", 2)
	registrationTestJoin(conn, club, bob)
	registrationTestJoin(conn, club, erin)
	databaseDefaultRoomTestExec(
		conn,
		"restrict erin",
		fmt.tprintf("UPDATE users SET restricted = true WHERE id = %d", erin),
	)

	sees :: proc(conn: pg.Conn, viewer: int) -> map[int]bool {
		response := databaseExecuteRequest(
			conn,
			common.DatabaseUserDirectoryRequest{viewerUserId = viewer},
		)
		defer IPC__database_query_response_deinit(response)
		assert(response.success, response.message)
		seen := make(map[int]bool, context.temp_allocator)
		for user in response.result.(common.DatabaseUserDirectoryResult).users {
			seen[user.id] = true
		}
		return seen
	}
	erinSees := sees(conn, erin)
	assert(
		erinSees[erin] && erinSees[bob] && erinSees[admin] && !erinSees[carol] &&
		!erinSees[approver],
		fmt.tprintf("expected erin to see herself, bob and the admin only, got %v", erinSees),
	)
	carolSees := sees(conn, carol)
	assert(!carolSees[erin] && carolSees[bob], "expected carol not to see erin")
	bobSees := sees(conn, bob)
	assert(bobSees[erin], "expected bob, who shares a room, to see erin")
	approverSees := sees(conn, approver)
	assert(approverSees[erin] && approverSees[carol], "expected approvers to see everyone")

	post :: proc(conn: pg.Conn, sender, recipient: int) -> common.DirectMessagePostOutcome {
		response := databaseSQLTestPost(conn, sender, recipient, "hello")
		defer IPC__database_query_response_deinit(response)
		assert(response.success, response.message)
		return response.result.(common.DatabasePostDirectMessageResult).outcome
	}
	assert(post(conn, erin, carol) == .Restricted, "expected erin refused a DM to carol")
	assert(post(conn, carol, erin) == .Restricted, "expected carol refused a DM to erin")
	assert(post(conn, erin, bob) == .Stored, "expected erin to DM bob")
	assert(post(conn, erin, admin) == .Stored, "expected erin to DM the admin")
	assert(post(conn, carol, bob) == .Stored, "expected unrestricted DMs unchanged")

	history :: proc(conn: pg.Conn, userID, peer: int) -> bool {
		response := databaseExecuteRequest(
			conn,
			common.DatabaseDirectHistoryRequest{userId = userID, peerUserId = peer, limit = 10},
		)
		defer IPC__database_query_response_deinit(response)
		assert(response.success, response.message)
		return response.result.(common.DatabaseDirectHistoryResult).peerExists
	}
	assert(!history(conn, erin, carol), "expected carol hidden from erin's history")
	// The last shared room goes: history stays readable, new messages are refused.
	databaseDefaultRoomTestExec(
		conn,
		"take bob out",
		fmt.tprintf("DELETE FROM room_members WHERE room_id = %d AND user_id = %d", club, bob),
	)
	assert(history(conn, erin, bob), "expected the old conversation readable")
	assert(post(conn, erin, bob) == .Restricted, "expected new messages refused")
	registrationTestJoin(conn, club, bob)

	// Only member managers add a restricted account (D11): a member of a Member invite room
	// cannot, the admin can.
	add :: proc(conn: pg.Conn, actor, room, target: int) -> common.DatabaseRoomMemberOutcome {
		response := databaseExecuteRequest(
			conn,
			common.DatabaseRoomMemberActionRequest {
				action = .Add,
				actorUserId = actor,
				roomId = room,
				targetUserId = target,
			},
		)
		defer IPC__database_query_response_deinit(response)
		assert(response.success, response.message)
		return response.result.(common.DatabaseRoomMemberActionResult).outcome
	}
	other := registrationTestRoom(conn, "rst-other", 2)
	registrationTestJoin(conn, other, bob)
	assert(add(conn, bob, other, erin) == .RestrictedTarget, "expected a member refused")
	assert(add(conn, bob, other, carol) == .Applied, "expected unrestricted adds unchanged")
	assert(add(conn, admin, other, erin) == .Applied, "expected the admin to add erin")

	// Public rooms skip restricted accounts: a new Public room and a switch to Public.
	created := databaseExecuteRequest(
		conn,
		common.DatabaseCreateRoomRequest {
			creatorUserId = admin,
			name = "rst-new-public",
			roomType = .ChatAndVoice,
			access = .Public,
			historyVisibility = .Full,
		},
	)
	defer IPC__database_query_response_deinit(created)
	assert(created.success, created.message)
	rooms := registrationTestRooms(conn, erin)
	assert(
		!strings.contains(rooms, "rst-new-public"),
		fmt.tprintf("expected erin outside the new Public room, got %q", rooms),
	)

	// Who may see erin for presence: room mates (carol shares rst-other now) and admins, not
	// dave; and the restricted list the router loads.
	dave := databaseSQLTestCreateUser(conn, "rst-dave")
	candidates := make([dynamic]int)
	append(&candidates, dave, carol, bob, admin)
	shared := databaseExecuteRequest(
		conn,
		common.DatabaseSharedRoomsRequest{userId = erin, candidateUserIds = candidates},
	)
	defer IPC__database_query_response_deinit(shared)
	defer delete(candidates)
	sharedIDs := shared.result.(common.DatabaseSharedRoomsResult).userIds
	assert(
		len(sharedIDs) == 3 &&
		sharedIDs[0] == admin &&
		sharedIDs[1] == bob &&
		sharedIDs[2] == carol,
		fmt.tprintf("expected the admin, bob and carol, got %v", sharedIDs),
	)
	restricted := databaseExecuteRequest(conn, common.DatabaseRestrictedUsersRequest{})
	defer IPC__database_query_response_deinit(restricted)
	restrictedIDs := restricted.result.(common.DatabaseRestrictedUsersResult).userIds
	assert(len(restrictedIDs) == 1 && restrictedIDs[0] == erin, "expected erin listed")

	// Admins cannot be restricted; lifting erin's restriction joins the Public rooms.
	databaseAdminTestExpect(
		conn,
		{action = .SetRestricted, actorUserId = admin, targetUserId = admin, restricted = true},
		.AdminTarget,
		"restricting an admin",
	)
	databaseAdminTestExpect(
		conn,
		{action = .SetRestricted, actorUserId = bob, targetUserId = erin, restricted = false},
		.NotAdmin,
		"a non-admin lifting it",
	)
	lifted := databaseAdminTestExpect(
		conn,
		{action = .SetRestricted, actorUserId = admin, targetUserId = erin, restricted = false},
		.Applied,
		"lifting erin's restriction",
	)
	assert(
		lifted.changed && !lifted.user.isRestricted && len(lifted.addedRoomIDs) == 1,
		fmt.tprintf("expected erin unrestricted and in the Public room, got %v", lifted),
	)
	again := databaseAdminTestExpect(
		conn,
		{action = .SetRestricted, actorUserId = admin, targetUserId = erin, restricted = true},
		.Applied,
		"restricting erin again",
	)
	assert(
		again.changed && again.user.isRestricted && len(again.addedRoomIDs) == 0,
		"expected the restriction set, removing no room",
	)
	assert(
		strings.contains(registrationTestRooms(conn, erin), "rst-new-public"),
		"expected setting it to keep the memberships",
	)
}

// #115: a room code's request whose room is deleted or made Public cannot be approved, and an
// approved one whose room changed before the applicant signs in is declined by the server
// instead of making a restricted account with no rooms. #102: the identity and register
// statements say when they created an account, with its roles.
@(test)
testRoomCodeRequestWhoseRoomChangedAgainstPostgreSQL :: proc(t: ^testing.T) {
	_ = t
	if os.get_env(DATABASE_SQL_TEST_ENV, context.temp_allocator) != "1" {
		return
	}
	conn := databaseAdminTestOpen(t, "registration_room_changed")
	approver := databaseAdminTestUser(conn, "rc-approver")
	approverRole := registrationTestRole(conn, "rc-approvers", {.ApproveRegistrations})
	registrationTestHold(conn, approver, approverRole)
	registrationTestMode(conn, .InviteApproval)

	decide :: proc(
		conn: pg.Conn,
		actor: int,
		requestID: int,
		approve: bool,
	) -> common.DatabaseRegistrationRequestsOutcome {
		response := databaseExecuteRequest(
			conn,
			common.DatabaseRegistrationRequestsRequest {
				action = .Decide,
				actorUserId = actor,
				requestId = requestID,
				approve = approve,
			},
		)
		defer IPC__database_query_response_deinit(response)
		assert(response.success, response.message)
		return response.result.(common.DatabaseRegistrationRequestsResult).outcome
	}
	// A pending request of a new key through a code for a new invite room.
	apply :: proc(
		conn: pg.Conn,
		name: string,
	) -> (
		key: common.IdentityPublicKeyBytes,
		requestID: int,
		roomID: int,
	) {
		roomID = registrationTestRoom(conn, fmt.tprintf("%s-room", name), 2)
		code, _ := registrationTestCode(
			conn,
			"room_id, restricted",
			fmt.tprintf("%d, true", roomID),
		)
		key = databaseIdentityTestKey()
		registered := registrationTestRegister(conn, key, name, code, reason = "hi")
		assert(registered.outcome == .Pending, fmt.tprintf("expected %s pending", name))
		return key, registered.request.id, roomID
	}
	accounts :: proc(conn: pg.Conn, name: string) -> string {
		return databaseAdminTestValue(
			conn,
			fmt.tprintf("SELECT count(*)::text FROM users WHERE nickname = '%s'", name),
		)
	}

	// Approval refused once the room is gone or Public; declining still works.
	{
		_, requestID, roomID := apply(conn, "rc-deleted")
		databaseDefaultRoomTestExec(
			conn,
			"delete the room",
			fmt.tprintf("DELETE FROM rooms WHERE id = %d", roomID),
		)
		outcome := decide(conn, approver, requestID, true)
		assert(
			outcome == .RoomUnavailable,
			fmt.tprintf("expected room_unavailable, got %v", outcome),
		)
		outcome = decide(conn, approver, requestID, false)
		assert(outcome == .Applied, fmt.tprintf("expected the decline to apply, got %v", outcome))
	}
	{
		_, requestID, roomID := apply(conn, "rc-public")
		databaseDefaultRoomTestExec(
			conn,
			"make the room Public",
			fmt.tprintf("UPDATE rooms SET access = 1 WHERE id = %d", roomID),
		)
		outcome := decide(conn, approver, requestID, true)
		assert(
			outcome == .RoomUnavailable,
			fmt.tprintf("expected room_unavailable, got %v", outcome),
		)
		status := databaseAdminTestValue(
			conn,
			fmt.tprintf("SELECT status::text FROM registration_requests WHERE id = %d", requestID),
		)
		assert(status == "1", "expected the refused approval to change nothing")
	}

	// Approved, then the room goes (deleted, or made Public): the sign-in is declined, no
	// account is made, and the request reads declined with the server's reason.
	roomChanges := []string {
		"DELETE FROM rooms WHERE id = %d",
		"UPDATE rooms SET access = 1 WHERE id = %d",
	}
	for change in roomChanges {
		name := change[0] == 'D' ? "rc-late-deleted" : "rc-late-public"
		key, requestID, roomID := apply(conn, name)
		outcome := decide(conn, approver, requestID, true)
		assert(outcome == .Applied, fmt.tprintf("expected %s approved, got %v", name, outcome))
		databaseDefaultRoomTestExec(conn, "change the room", fmt.tprintf(change, roomID))
		pending := databaseAdminTestValue(
			conn,
			"SELECT count(*)::text FROM registration_requests WHERE status = 1",
		)
		for registering, attempt in ([]bool{true, false}) {
			identity := registrationTestIdentity(conn, name, key, registering = registering)
			assert(
				identity.userId == 0 &&
				identity.needsRegistration &&
				identity.requestStatus == .Declined &&
				identity.decisionReason == common.REGISTRATION_ROOM_GONE_REASON &&
				!identity.created,
				fmt.tprintf("expected %s declined by the server, got %v", name, identity),
			)
			// #165: the sign-in that declined it reports the request for the approvers; a
			// later one finds it declined already and reports none.
			declined := identity.declinedRequest
			if attempt == 0 {
				assert(
					declined.id == requestID &&
					declined.status == .Declined &&
					declined.nickname == name &&
					declined.identityPublicKey == key &&
					declined.decidedBy == 0 &&
					len(declined.decidedAt) > 0 &&
					declined.decisionReason == common.REGISTRATION_ROOM_GONE_REASON &&
					fmt.tprintf("%d", identity.pendingCount) == pending,
					fmt.tprintf("expected %s's declined request, got %v", name, identity),
				)
			} else {
				assert(
					declined.id == 0 && identity.pendingCount == 0,
					fmt.tprintf("expected no second decline for %s, got %v", name, declined),
				)
			}
		}
		assert(accounts(conn, name) == "0", fmt.tprintf("expected no account for %s", name))
		stored := databaseAdminTestValue(
			conn,
			fmt.tprintf(
				"SELECT status::text || ',' || decision_reason || ',' || " +
				"(decided_by_user_id IS NULL)::text FROM registration_requests WHERE id = %d",
				requestID,
			),
		)
		expected := fmt.tprintf("3,%s,true", common.REGISTRATION_ROOM_GONE_REASON)
		assert(stored == expected, fmt.tprintf("expected the stored decline, got %q", stored))
	}

	// #102: an approved account reports created with its code's roles, once.
	{
		roomID := registrationTestRoom(conn, "rc-roles-room", 2)
		role := registrationTestRole(conn, "rc-helpers", {.CreateInvites})
		code, codeID := registrationTestCode(
			conn,
			"room_id, restricted",
			fmt.tprintf("%d, true", roomID),
		)
		databaseDefaultRoomTestExec(
			conn,
			"give the code a role",
			fmt.tprintf("INSERT INTO invite_roles VALUES (%d, %d)", codeID, role),
		)
		key := databaseIdentityTestKey()
		registered := registrationTestRegister(conn, key, "rc-roles", code, reason = "hi")
		assert(registered.outcome == .Pending, "expected rc-roles pending")
		assert(decide(conn, approver, registered.request.id, true) == .Applied, "expected approval")
		created := registrationTestIdentity(conn, "rc-roles", key, registering = true)
		assert(
			created.userId > 0 &&
			created.created &&
			created.isRestricted &&
			len(created.roleIds) == 1 &&
			created.roleIds[0] == role,
			fmt.tprintf("expected rc-roles created with its code's role, got %v", created),
		)
		rooms := registrationTestRooms(conn, created.userId)
		assert(rooms == "rc-roles-room", fmt.tprintf("expected the code's room, got %q", rooms))
		again := registrationTestIdentity(conn, "rc-roles", key)
		assert(
			again.userId == created.userId && !again.created && len(again.roleIds) == 0,
			fmt.tprintf("expected a returning sign-in not created, got %v", again),
		)

		// A sign-up the register statement completes carries the code's roles too.
		registrationTestMode(conn, .InviteOnly)
		direct, directID := registrationTestCode(conn)
		databaseDefaultRoomTestExec(
			conn,
			"give the plain code a role",
			fmt.tprintf("INSERT INTO invite_roles VALUES (%d, %d)", directID, role),
		)
		signedUp := registrationTestRegister(conn, databaseIdentityTestKey(), "rc-direct", direct)
		assert(
			signedUp.outcome == .Created &&
			len(signedUp.roleIds) == 1 &&
			signedUp.roleIds[0] == role,
			fmt.tprintf("expected the sign-up created with its code's role, got %v", signedUp),
		)
		registrationTestMode(conn, .Open)
		open := registrationTestIdentity(conn, "rc-open", databaseIdentityTestKey())
		assert(
			open.userId > 0 && open.created && len(open.roleIds) == 0,
			fmt.tprintf("expected an Open account created without roles, got %v", open),
		)
	}
}
