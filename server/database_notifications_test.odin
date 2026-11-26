package server

import "../common"
import "core:encoding/cbor"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:sync"
import "core:testing"
import "core:time"
import "shared:pg"

// Database change notifications (#116, database_notifications.odin). The pure tests always
// run. testRestrictedChangeInTheDatabaseReachesSessionsAgainstPostgreSQL runs when
// HAYCHAT_DATABASE_SQL_TEST=1 (dev/live-proof.sh --all and --sql): the real listener thread on
// a connection of its own, the router with stub sessions, and an operator's UPDATE on another
// connection, in a migrated schema of its own that the runner commits and the cleanup drops.

@(test)
testDatabaseChangeChannelNamesRoundTrip :: proc(t: ^testing.T) {
	_ = t
	for name, channel in DATABASE_CHANGE_CHANNEL_NAMES {
		parsed, ok := databaseChangeChannelFromName(name)
		assert(ok && parsed == channel, fmt.tprintf("expected %q to name %v", name, channel))
	}
	_, unknownOK := databaseChangeChannelFromName("haychat_unknown")
	assert(!unknownOK, "expected an unknown channel refused")
}

@(test)
testDatabaseChangeParseIDTakesOnlyAPositiveDecimal :: proc(t: ^testing.T) {
	_ = t
	id, ok := databaseChangeParseID("42")
	assert(ok && id == 42, fmt.tprintf("expected 42, got %d (%v)", id, ok))
	for payload in ([]string{"", "0", "-1", "4 2", "12a", "+1", "12345678901234567890"}) {
		_, refused := databaseChangeParseID(payload)
		assert(!refused, fmt.tprintf("expected %q refused", payload))
	}
}

@(test)
testDatabaseChangeBatchHandsOutDistinctSortedIDs :: proc(t: ^testing.T) {
	_ = t
	batch: DatabaseChangeBatch
	defer DatabaseChangeBatch_deinit(&batch)
	assert(databaseChangeBatchAdd(&batch, "haychat_restricted", "7"), "expected 7 recorded")
	assert(databaseChangeBatchAdd(&batch, "haychat_restricted", "3"), "expected 3 recorded")
	assert(databaseChangeBatchAdd(&batch, "haychat_restricted", "7"), "expected 7 again")
	assert(!databaseChangeBatchAdd(&batch, "haychat_other", "1"), "expected others ignored")
	assert(!databaseChangeBatchAdd(&batch, "haychat_restricted", "x"), "expected junk ignored")
	ids := databaseChangeBatchTake(&batch, .Restricted)
	defer delete(ids)
	assert(slice.equal(ids[:], []int{3, 7}), fmt.tprintf("expected [3, 7], got %v", ids))
	again := databaseChangeBatchTake(&batch, .Restricted)
	assert(again == nil, fmt.tprintf("expected the channel emptied, got %v", again))
}

// The listener the test started, stopped by the test's defer or, after a failed assertion, by
// its cleanup (which then finds it stopped or still running).
@(private = "file")
DatabaseNotifyTestListener :: struct {
	listener: ^DatabaseChangeListener,
}

@(private = "file")
databaseNotifyTestStop :: proc(data: rawptr) {
	holder := (^DatabaseNotifyTestListener)(data)
	databaseChangeListenerStop(holder.listener)
	holder.listener = nil
}

@(private = "file")
databaseNotifyTestCleanup :: proc(data: rawptr) {
	databaseNotifyTestStop(data)
	free(data)
}

// One pass of what the server's threads do: main handles what the listener sent, the database
// worker's queries run against conn, and the sessions' messages are opened into messages.
// Fails once deadline passed.
@(private = "file")
databaseNotifyTestPump :: proc(
	h: ^RouterTestHarness,
	conn: pg.Conn,
	peers: []RouterTestPeer,
	messages: ^[dynamic]RouterChangeTestMessage,
	deadline: time.Tick,
	why: string,
) {
	assert(time.tick_diff(time.tick_now(), deadline) > 0, why)
	progressed := false
	for {
		msg, err := IPC_Client_poll(h.pm.config.mainFd)
		if err != nil {
			break
		}
		progressed = true
		mainLoopHandleMessage(&h.pm, &h.state, msg)
	}
	for {
		msg, err := IPC_Client_poll(h.databaseFd)
		if err != nil {
			break
		}
		progressed = true
		query, isQuery := msg.(DatabaseQuery)
		if !isQuery {
			IPC__message_deinit(&msg)
			continue
		}
		response := databaseExecuteRequest(conn, query.request)
		IPC__database_query_request_deinit(query.request)
		MainRouterState_handleDatabaseResult(&h.pm, &h.state, query.request_id, response)
	}
	collected := routerChangeTestCollect(h, peers)
	progressed ||= len(collected) > 0
	append(messages, ..collected[:])
	delete(collected)
	if !progressed {
		IPC_Client_wait(h.pm.config.mainFd, 20 * time.Millisecond)
	}
}

// erin's last ServerAccountUpdated in messages, and whether there was one.
@(private = "file")
databaseNotifyTestAccountUpdate :: proc(
	messages: []RouterChangeTestMessage,
	peerID: u32,
) -> (
	common.ServerAccountUpdatedPayload,
	bool,
) {
	#reverse for message in messages {
		if message.peerID == peerID && message.messageType == .ServerAccountUpdated {
			updated: common.ServerAccountUpdatedPayload
			assert(cbor.unmarshal(message.payload, &updated) == nil, "expected its payload")
			delete(updated.nickname)
			updated.nickname = ""
			return updated, true
		}
	}
	return {}, false
}

// #116 acceptance: an operator's UPDATE of users.restricted on another connection reaches the
// connected sessions without a restart, and lifting it joins the account to the Public room.
@(test)
testRestrictedChangeInTheDatabaseReachesSessionsAgainstPostgreSQL :: proc(t: ^testing.T) {
	if os.get_env(DATABASE_SQL_TEST_ENV, context.temp_allocator) != "1" {
		return
	}
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)

	conn, schema := databaseMigrationTestOpen(t, "change_notify")
	_ = schema
	databaseMigrationTestMigrate(conn, DATABASE_MIGRATIONS[:])
	adminID := databaseAdminTestUser(conn, "notify-admin")
	bobID := databaseAdminTestUser(conn, "notify-bob")
	erinID := databaseAdminTestUser(conn, "notify-erin")
	databaseDefaultRoomTestExec(
		conn,
		"admin role",
		fmt.tprintf(
			"INSERT INTO user_server_roles (user_id, role_id) " +
			"SELECT %d, id FROM server_roles WHERE name = 'admin'",
			adminID,
		),
	)
	generalID, generalErr := databaseEnsureDefaultRoom(conn)
	assert(len(generalErr) == 0 && generalID > 0, generalErr)

	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)
	transports: [3]common.TransportState
	defer for &transport in transports {
		common.TransportState_deinit(&transport)
	}
	accounts := [3]struct {
		peerID:   u32,
		userID:   int,
		nickname: string,
		isAdmin:  bool,
	} {
		{1, adminID, "notify-admin", true},
		{2, bobID, "notify-bob", false},
		{3, erinID, "notify-erin", false},
	}
	peers: [3]RouterTestPeer
	for account, index in accounts {
		peers[index] = RouterTestPeer {
			peerID    = account.peerID,
			transport = &transports[index],
		}
		if account.peerID != 1 {
			h.state.connectedPeers[account.peerID] = true
			MainRouterState_setPeerSession(&h.state, account.peerID, RouterPeerSession_init())
		}
		transports[index] = routerCompleteHandshake(
			&h,
			account.peerID,
			userID = account.userID,
			nickname = account.nickname,
			isAdmin = account.isAdmin,
		)
		collected := routerChangeTestCollect(&h, peers[:index + 1])
		RouterChangeTestMessages_deinit(&collected)
		routerChangeTestDropQueries(&h)
	}
	if session, ok := &h.state.peerSessions[1]; ok {
		session.permissions = common.serverPermissionsFromMask(-1)
	}

	holder := new(DatabaseNotifyTestListener)
	testing.cleanup(t, databaseNotifyTestCleanup, holder)
	holder.listener = databaseChangeListenerStart(
		databaseListenerConninfo(databaseSQLTestConfig()),
		h.databaseFd,
	)
	assert(holder.listener != nil, "expected the listener thread to start")
	// Before the harness's IPC state goes: the thread sends through it.
	defer databaseNotifyTestStop(holder)

	messages := make([dynamic]RouterChangeTestMessage)
	defer RouterChangeTestMessages_deinit(&messages)
	deadline := time.tick_add(time.tick_now(), 20 * time.Second)
	// DatabaseChangeListening: the router reads the restricted accounts once listening.
	for !h.state.restrictedUsersLoaded {
		databaseNotifyTestPump(&h, conn, peers[:], &messages, deadline, "expected a listener")
	}

	// The operator restricts erin.
	databaseDefaultRoomTestExec(
		conn,
		"restrict erin",
		fmt.tprintf("UPDATE users SET restricted = true WHERE id = %d", erinID),
	)
	for {
		updated, found := databaseNotifyTestAccountUpdate(messages[:], 3)
		if found && updated.isRestricted {
			break
		}
		databaseNotifyTestPump(&h, conn, peers[:], &messages, deadline, "expected erin restricted")
	}
	assert(MainRouterState_userIsRestricted(&h.state, erinID), "expected erin in the router's set")
	toldAdmin := false
	for message in messages {
		if message.peerID == 1 && message.messageType == .ServerUserUpdated {
			updated: common.ServerUserUpdatedPayload
			assert(cbor.unmarshal(message.payload, &updated) == nil, "expected its payload")
			toldAdmin ||= updated.user.id == erinID && updated.user.isRestricted
			common.UserSummary_deinit(&updated.user)
		}
	}
	assert(toldAdmin, "expected the admin's session told that erin is restricted")

	// Restricted accounts are outside Public rooms (D11); lifting joins her again.
	for message in messages {
		delete(message.payload)
	}
	clear(&messages)
	databaseDefaultRoomTestExec(
		conn,
		"lift erin",
		fmt.tprintf(
			"DELETE FROM room_members WHERE user_id = %d; " +
			"UPDATE users SET restricted = false WHERE id = %d",
			erinID,
			erinID,
		),
	)
	for {
		updated, found := databaseNotifyTestAccountUpdate(messages[:], 3)
		if found && !updated.isRestricted {
			break
		}
		databaseNotifyTestPump(&h, conn, peers[:], &messages, deadline, "expected erin lifted")
	}
	assert(!MainRouterState_userIsRestricted(&h.state, erinID), "expected erin out of the set")
	member := databaseMigrationTestValue(
		conn,
		fmt.tprintf(
			"SELECT EXISTS (SELECT 1 FROM room_members WHERE room_id = %d AND user_id = %d)::text",
			generalID,
			erinID,
		),
	)
	assert(member == "true", "expected erin back in the Public room")
	assert(
		routerChangeTestCount(messages[:], 3, .ServerRoomMembershipChanged) >= 1,
		"expected erin told she joined the Public room",
	)
}
