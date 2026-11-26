package server

import "../common"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:thread"
import "core:time"
import "shared:pg"

// Database change notifications (#116; #75 is meant to add a channel). A change an operator
// makes with SQL, which the router's in-memory state would otherwise miss until a restart,
// reaches the router through PostgreSQL's LISTEN/NOTIFY:
//
// - A trigger (migration 18, haychat_notify_row_id) sends NOTIFY on a channel with the changed
//   row's ID as its payload. PostgreSQL delivers it at commit and folds identical ones of one
//   transaction into one. Channels are database-wide: a notification from another schema on
//   the same database (the SQL tests) names IDs the router then reads in its own schema and
//   finds unchanged, which costs one statement and sends nothing.
// - The listener (DatabaseChangeListener) is a thread the database worker starts once it is
//   ready and stops before it returns, so a restarted worker starts a new one. It holds a
//   connection of its own, so waiting for notifications, reconnecting (connect_timeout is
//   DATABASE_CONNECT_TIMEOUT_SECONDS) and its backoff never delay the worker's queries. It
//   waits in poll() on the connection's socket for at most DATABASE_LISTENER_POLL_MS, reads
//   with PQconsumeInput, and sends the router one DatabaseChangeNotification per channel per
//   pass (the IDs distinct and ascending), so a bulk UPDATE becomes one message.
// - A lost connection (a failed read, CONNECTION_BAD, or TCP keepalives giving up on a silent
//   peer) is closed and reopened with a backoff from DATABASE_LISTENER_RETRY_MIN to
//   DATABASE_LISTENER_RETRY_MAX. After every LISTEN, the first one included, the listener
//   sends DatabaseChangeListening: notifications are not queued for a listener that was not
//   connected, so the router reads each channel's state again and applies what differs
//   (MainRouterState_databaseChangesListening). Listening before that read means no change is
//   missed between the two.
// - The router (router_database_changes.odin) handles each channel. Every handler must be
//   idempotent: the router's own changes fire the same triggers, and a resync may report a
//   change a notification also reports. Restricted compares with MainRouterState.
//   restrictedUserIDs and does nothing for an account that already matches.
//
// Adding a channel (#75): a trigger in a new migration that calls
// haychat_notify_row_id('haychat_...') (or a function of its own for a table without an id
// column), a DatabaseChangeChannel member with its name in DATABASE_CHANGE_CHANNEL_NAMES, a
// case in MainRouterState_handleDatabaseChange that reads the rows again, and a resync in
// MainRouterState_databaseChangesListening.

// The channels the listener LISTENs on. The router switches over every member.
DatabaseChangeChannel :: enum u8 {
	// users.restricted changed (migration 18, users_restricted_notify); IDs are account IDs.
	Restricted,
}

// Channel names as the triggers pass them to haychat_notify_row_id. Plain identifiers: the
// listener sends them unquoted in LISTEN.
DATABASE_CHANGE_CHANNEL_NAMES := [DatabaseChangeChannel]string {
	.Restricted = "haychat_restricted",
}

// Database listener -> main: the IDs one channel reported in one pass, distinct and ascending.
// ids is owned (IPC__message_deinit frees it).
DatabaseChangeNotification :: struct {
	channel: DatabaseChangeChannel,
	ids:     [dynamic]int,
}

// Database listener -> main: the listener (re)connected and LISTENs on every channel. What
// changed while it was not listening was never reported.
DatabaseChangeListening :: struct {}

// How long one wait for a notification lasts, which bounds how long a stop request waits.
DATABASE_LISTENER_POLL_MS :: 250
// The backoff between attempts to reopen the listener's connection.
DATABASE_LISTENER_RETRY_MIN :: time.Second
DATABASE_LISTENER_RETRY_MAX :: 30 * time.Second
// TCP keepalives for the listener's connection, which otherwise only reads: a peer that went
// away without closing the socket is noticed after about idle + interval * count seconds.
DATABASE_LISTENER_KEEPALIVES ::
	"keepalives=1 keepalives_idle=60 keepalives_interval=10 keepalives_count=3"

// The channel a notification's relname names.
databaseChangeChannelFromName :: proc(name: string) -> (DatabaseChangeChannel, bool) {
	for channelName, channel in DATABASE_CHANGE_CHANNEL_NAMES {
		if channelName == name {
			return channel, true
		}
	}
	return {}, false
}

// A notification's payload: one positive row ID in decimal, nothing else.
databaseChangeParseID :: proc(payload: string) -> (int, bool) {
	if len(payload) == 0 || len(payload) > 19 {
		return 0, false
	}
	value := 0
	for character in transmute([]u8)payload {
		if character < '0' || character > '9' {
			return 0, false
		}
		value = value * 10 + int(character - '0')
	}
	return value, value > 0
}

// The IDs collected in one pass, per channel. Owned arrays; databaseChangeBatchTake hands
// them out.
DatabaseChangeBatch :: struct {
	ids: [DatabaseChangeChannel][dynamic]int,
}

DatabaseChangeBatch_deinit :: proc(batch: ^DatabaseChangeBatch) {
	for &ids in batch.ids {
		delete(ids)
		ids = nil
	}
}

// Records one notification. false (and nothing recorded) for an unknown channel or a payload
// that is not an ID: the listener ignores those.
databaseChangeBatchAdd :: proc(
	batch: ^DatabaseChangeBatch,
	relname: string,
	payload: string,
) -> bool {
	channel, channelOK := databaseChangeChannelFromName(relname)
	if !channelOK {
		return false
	}
	id, idOK := databaseChangeParseID(payload)
	if !idOK {
		return false
	}
	append(&batch.ids[channel], id)
	return true
}

// The channel's IDs, distinct and ascending (owned by the caller), and an empty channel in the
// batch. nil when the channel reported nothing.
databaseChangeBatchTake :: proc(
	batch: ^DatabaseChangeBatch,
	channel: DatabaseChangeChannel,
) -> [dynamic]int {
	ids := batch.ids[channel]
	batch.ids[channel] = nil
	if len(ids) == 0 {
		delete(ids)
		return nil
	}
	slice.sort(ids[:])
	unique := slice.unique(ids[:])
	resize(&ids, len(unique))
	return ids
}

// The listener's connection string: the worker's, with keepalives. The caller frees it.
databaseListenerConninfo :: proc(config: ServerConfig) -> cstring {
	base := databaseRuntimeConninfo(config)
	defer delete(base)
	return fmt.caprintf("%s %s", base, DATABASE_LISTENER_KEEPALIVES)
}

// Opens a connection with conninfo and LISTENs on every channel. On failure the connection is
// closed and the error (owned) says why.
databaseListenerOpen :: proc(conninfo: cstring) -> (pg.Conn, string) {
	conn := pg.connectdb(conninfo)
	if conn == nil {
		return nil, strings.clone("could not allocate a PostgreSQL connection")
	}
	if pg.status(conn) != .Ok {
		err := cloneCStringOrEmpty(pg.error_message(conn))
		pg.finish(conn)
		return nil, err
	}
	for channelName in DATABASE_CHANGE_CHANNEL_NAMES {
		query := fmt.caprintf("LISTEN %s", channelName)
		result := pg.exec(conn, query)
		delete(query)
		ok := result != nil && pg.result_status(result) == .Command_OK
		err: string
		if !ok {
			err = cloneCStringOrEmpty(
				result != nil ? pg.result_error_message(result) : pg.error_message(conn),
			)
		}
		if result != nil {
			pg.clear(result)
		}
		if !ok {
			pg.finish(conn)
			return nil, err
		}
	}
	return conn, ""
}

// Waits up to timeoutMS for the connection's socket, reads what arrived, and moves every queued
// notification into batch. false when the connection is gone (the caller closes it).
databaseListenerPoll :: proc(
	conn: pg.Conn,
	batch: ^DatabaseChangeBatch,
	timeoutMS: i32,
) -> bool {
	socket := pg.socket(conn)
	if socket < 0 {
		return false
	}
	fds := [1]linux.Poll_Fd{{fd = linux.Fd(socket), events = {.IN}}}
	ready, pollErr := linux.poll(fds[:], timeoutMS)
	if pollErr != nil && pollErr != .EINTR {
		return false
	}
	if ready > 0 {
		if !pg.consume_input(conn) {
			return false
		}
	}
	for {
		notify := pg.notifies(conn)
		if notify == nil {
			break
		}
		databaseChangeBatchAdd(batch, string(notify.relname), string(notify.extra))
		pg.free_mem(notify)
	}
	return pg.status(conn) == .Ok
}

// Sends the batch's channels to main as DatabaseChangeNotifications, one per channel that
// reported anything. false when main no longer takes messages.
databaseListenerSend :: proc(ipcFd: linux.Fd, batch: ^DatabaseChangeBatch) -> bool {
	for channel in DatabaseChangeChannel {
		ids := databaseChangeBatchTake(batch, channel)
		if ids == nil {
			continue
		}
		msg: Message = DatabaseChangeNotification {
			channel = channel,
			ids     = ids,
		}
		if IPC_Client_send(ipcFd, msg) != nil {
			IPC__message_deinit(&msg)
			return false
		}
	}
	return true
}

// The listener thread's state. The database worker owns it (databaseChangeListenerStart and
// databaseChangeListenerStop); only stop is shared with the thread.
DatabaseChangeListener :: struct {
	conninfo: cstring,
	ipcFd:    linux.Fd,
	stop:     bool,
	thread:   ^thread.Thread,
}

// Sleeps for duration in DATABASE_LISTENER_POLL_MS steps; false when stop was asked for.
@(private = "file")
databaseListenerSleep :: proc(
	listener: ^DatabaseChangeListener,
	duration: time.Duration,
) -> bool {
	start := time.tick_now()
	for time.tick_since(start) < duration {
		if sync.atomic_load(&listener.stop) {
			return false
		}
		step := min(duration - time.tick_since(start), DATABASE_LISTENER_POLL_MS * time.Millisecond)
		time.sleep(step)
	}
	return !sync.atomic_load(&listener.stop)
}

@(private = "file")
databaseListenerRun :: proc(listener: ^DatabaseChangeListener) {
	conn: pg.Conn
	defer if conn != nil {
		pg.finish(conn)
	}
	batch: DatabaseChangeBatch
	defer DatabaseChangeBatch_deinit(&batch)
	retry := DATABASE_LISTENER_RETRY_MIN
	// Whether the last attempt failed, so an outage is logged once and its end once.
	failing := false

	for !sync.atomic_load(&listener.stop) {
		if conn == nil {
			opened, openErr := databaseListenerOpen(listener.conninfo)
			if opened == nil {
				if !failing {
					fmt.printfln(
						"[Database] Change listener could not connect (retrying): %s",
						strings.trim_space(openErr),
					)
				}
				delete(openErr)
				failing = true
				if !databaseListenerSleep(listener, retry) {
					break
				}
				retry = min(retry * 2, DATABASE_LISTENER_RETRY_MAX)
				continue
			}
			conn = opened
			retry = DATABASE_LISTENER_RETRY_MIN
			if failing {
				fmt.printfln("[Database] Change listener connected again")
			}
			failing = false
			// After LISTEN: the router reads every channel's state again, so nothing that changed
			// while no listener was connected is missed.
			if IPC_Client_send(listener.ipcFd, DatabaseChangeListening{}) != nil {
				break
			}
		}

		alive := databaseListenerPoll(conn, &batch, DATABASE_LISTENER_POLL_MS)
		if !databaseListenerSend(listener.ipcFd, &batch) {
			break
		}
		if !alive {
			fmt.printfln(
				"[Database] Change listener lost its connection (reconnecting): %s",
				strings.trim_space(string(pg.error_message(conn))),
			)
			pg.finish(conn)
			conn = nil
			failing = true
		}
	}
}

// Starts the listener thread; it sends to main through ipcFd (the database worker's
// endpoint). The caller stops it with databaseChangeListenerStop. nil when the thread could
// not start: the server then runs without change notifications, as before #116.
databaseChangeListenerStart :: proc(
	conninfo: cstring,
	ipcFd: linux.Fd,
) -> ^DatabaseChangeListener {
	listener := new(DatabaseChangeListener)
	listener.conninfo = conninfo
	listener.ipcFd = ipcFd
	// The caller's context, so allocations the router frees come from the same allocator; the
	// thread never uses the temporary allocator.
	listener.thread = thread.create_and_start_with_poly_data(
		listener,
		databaseListenerRun,
		context,
	)
	if listener.thread == nil {
		fmt.printfln("[Database] Could not start the change listener thread")
		delete(listener.conninfo)
		free(listener)
		return nil
	}
	return listener
}

// Stops the thread (within DATABASE_LISTENER_POLL_MS, or the connect timeout while it is
// connecting), closes its connection and frees the listener.
databaseChangeListenerStop :: proc(listener: ^DatabaseChangeListener) {
	if listener == nil {
		return
	}
	sync.atomic_store(&listener.stop, true)
	thread.join(listener.thread)
	thread.destroy(listener.thread)
	delete(listener.conninfo)
	free(listener)
}

// #116: what the router needs to apply a restriction changed in the database, in the columns
// of the admin statements (database_admin.odin, read by databaseGetAdminUserRow): for every
// account in $1 that exists, by ID. An account in $2 (the router counts it as restricted) that
// no longer is joins every Public room here, as a lifted ClientAdminSetRestricted does, and
// column 13 names every Public room, also those deploy/sql/set-restricted.sql already joined it
// to, so its sessions hear of each. A restriction set in the database removes no membership,
// like the admin action.
DATABASE_RESTRICTED_CHANGES_SQL ::
	"WITH target AS (SELECT u.id, u.nickname, u.nickname_locked, " +
	"u.banned_at IS NOT NULL AS banned, u.restricted, " +
	"COALESCE(encode(u.public_key, 'hex'), '') AS public_key_hex, " +
	"(u.public_key IS NOT NULL AND EXISTS (SELECT 1 FROM user_encryption_keys k " +
	"WHERE k.user_id = u.id)) AS has_key, " +
	"EXISTS (SELECT 1 FROM user_server_roles usr JOIN server_roles sr ON sr.id = usr.role_id " +
	"WHERE usr.user_id = u.id AND sr.name = 'admin') AS is_admin, " +
	"COALESCE((SELECT string_agg(usr.role_id::text, ',' ORDER BY usr.role_id) " +
	"FROM user_server_roles usr WHERE usr.user_id = u.id), '') AS role_ids, " +
	DATABASE_SERVER_PERMISSIONS_OPEN_SQL + "u.id" + DATABASE_SERVER_PERMISSIONS_CLOSE_SQL +
	" AS permissions FROM users u WHERE u.id = ANY($1::bigint[])), " +
	"joined AS (INSERT INTO room_members (room_id, user_id) " +
	"SELECT r.id, t.id FROM rooms r JOIN target t " +
	"ON NOT t.restricted AND t.id = ANY($2::bigint[]) WHERE r.access = 1 " +
	// Unreferenced: PostgreSQL runs a data-modifying WITH query all the same.
	"ON CONFLICT DO NOTHING) " +
	"SELECT 'applied', 'true', t.id::text, t.nickname, t.nickname_locked::text, " +
	"t.is_admin::text, t.banned::text, t.nickname, t.public_key_hex, t.has_key::text, " +
	"t.role_ids, t.permissions::text, t.restricted::text, " +
	"CASE WHEN NOT t.restricted AND t.id = ANY($2::bigint[]) THEN " +
	"COALESCE((SELECT string_agg(r.id::text, ',' ORDER BY r.id) FROM rooms r " +
	"WHERE r.access = 1), '') ELSE '' END " +
	"FROM target t ORDER BY t.id"

databaseExecuteRestrictedChanges :: proc(
	conn: pg.Conn,
	request: common.DatabaseRestrictedChangesRequest,
) -> common.DatabaseQueryResponse {
	idsParam := databaseIntArrayParam(request.userIds[:])
	defer delete(idsParam)
	restrictedParam := databaseIntArrayParam(request.restrictedUserIds[:])
	defer delete(restrictedParam)
	params := [2][^]byte{transmute([^]byte)idsParam, transmute([^]byte)restrictedParam}
	result := databaseExecParams(conn, DATABASE_RESTRICTED_CHANGES_SQL, params[:])
	if result == nil {
		return databaseConnectionError(conn)
	}
	defer pg.clear(result)
	if pg.result_status(result) != .Tuples_OK {
		return databaseResultError(&result)
	}
	changes := common.DatabaseRestrictedChangesResult {
		accounts = make([dynamic]common.DatabaseAdminUserResult, 0, pg.n_tuples(result)),
	}
	for row in 0 ..< pg.n_tuples(result) {
		account, accountOK := databaseGetAdminUserRow(result, row, true)
		if !accountOK {
			for listed in changes.accounts {
				IPC__admin_user_result_deinit(listed)
			}
			delete(changes.accounts)
			return databaseErrorResponse(strings.clone("database returned an invalid user ID"))
		}
		append(&changes.accounts, account)
	}
	return databaseSuccess(changes)
}
