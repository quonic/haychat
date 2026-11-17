package server

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "shared:pg"

// HAYCHAT_DATABASE_SQL_TEST_FAIL=1 makes testAbandonedSQLTestReleasesItsConnectionAgainstPostgreSQL
// fail on purpose (dev/live-proof.sh --sql runs it that way once, #80).
DATABASE_SQL_TEST_FAIL_ENV :: "HAYCHAT_DATABASE_SQL_TEST_FAIL"

// A connection an SQL test opened, closed by databaseSQLTestClose.
@(private = "file")
DatabaseSQLTestConnection :: struct {
	t:        ^testing.T,
	conn:     pg.Conn,
	// Dropped (CASCADE) before the connection closes, when set. Owned.
	schema:   string,
	// The test's thread, to tell a close after the test returned from one after it failed.
	threadID: int,
}

// Opens a connection to the SQL test database and registers its close with testing.cleanup,
// which rolls back an open transaction, drops dropSchema when it is set, and closes the
// connection. Callers never close it themselves.
//
// Unlike a defer, a cleanup runs when an assertion fails too: the runner stops the failed
// test's thread without unwinding it and calls the test's cleanups from its own thread. A
// deferred close never ran then, so the connection stayed open inside the transaction holding
// the migration lock, and the next test that migrated waited for that lock forever (#80).
databaseSQLTestOpen :: proc(t: ^testing.T, dropSchema := "") -> pg.Conn {
	conn, openErr := databaseOpenRuntimeConnection(databaseSQLTestConfig())
	assert(len(openErr) == 0, openErr)
	connection := new(DatabaseSQLTestConnection)
	connection^ = {
		t        = t,
		conn     = conn,
		schema   = strings.clone(dropSchema),
		threadID = sync.current_thread_id(),
	}
	testing.cleanup(t, databaseSQLTestClose, connection)
	return conn
}

@(private = "file")
databaseSQLTestClose :: proc(data: rawptr) {
	connection := (^DatabaseSQLTestConnection)(data)
	defer free(connection)
	defer delete(connection.schema)
	defer pg.finish(connection.conn)

	// When the test returned, this runs on its thread and a failure here fails the test. After
	// a failed assertion it runs on the runner's thread, where only a message is safe, and it
	// must not fail in turn (that would end the runner).
	onTestThread := sync.current_thread_id() == connection.threadID
	report :: proc(connection: ^DatabaseSQLTestConnection, onTestThread: bool, err: string) {
		defer delete(err)
		if onTestThread {
			testing.expectf(connection.t, false, "expected the SQL test cleanup to run: %s", err)
		} else {
			fmt.eprintfln("[SQL test cleanup] %s", err)
		}
	}
	status := pg.transaction_status(connection.conn)
	if status == .In_Trans || status == .In_Error {
		if err := databaseMigrationExec(connection.conn, "roll back SQL test", "ROLLBACK");
		   len(err) > 0 {
			report(connection, onTestThread, err)
		}
	}
	if len(connection.schema) > 0 {
		// Not the temp allocator: that belongs to the test's thread.
		query := fmt.aprintf("DROP SCHEMA %s CASCADE", connection.schema)
		defer delete(query)
		if err := databaseMigrationExec(connection.conn, "drop SQL test schema", query);
		   len(err) > 0 {
			report(connection, onTestThread, err)
		}
	}
}

// Fails, when asked to, while its connection is inside the transaction that holds the migration
// lock, as a failed assertion in any SQL test would. The runner must then name this test and
// every later SQL test must still take the lock and pass. Its name sorts before every other SQL
// test (the runner orders tests by name, and dev/live-proof.sh checks it stays first), so in the
// failing run all of them come after it. Run normally, it opens and closes a connection.
@(test)
testAbandonedSQLTestReleasesItsConnectionAgainstPostgreSQL :: proc(t: ^testing.T) {
	if os.get_env(DATABASE_SQL_TEST_ENV, context.temp_allocator) != "1" {
		return
	}
	databaseAdminTestOpen(t, "abandoned")
	failOnPurpose := os.get_env(DATABASE_SQL_TEST_FAIL_ENV, context.temp_allocator) == "1"
	assert(!failOnPurpose, "failing on purpose while holding the migration lock")
}
