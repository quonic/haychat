package server

import "../common"
import "core:fmt"

// Database change notifications in the router (#116; database_notifications.odin has the
// listener and the mechanism). Each channel reads the changed rows again and applies them
// through the code path the router's own change uses, so the clients see the same messages
// whether an admin changed something from a client or an operator with SQL.
//
// Every handler is idempotent: the router's own changes fire the same triggers, and a resync
// may repeat what a notification already brought. Restricted compares each account with
// MainRouterState.restrictedUserIDs (MainRouterState_applyRestrictedChange) and sends nothing
// for one that already matches. The router's ClientAdminSetRestricted therefore fans out once:
// its statement commits before the database worker answers it, and the worker answers it
// before it runs the read the notification caused, so the set is already current then.

MainRouterState_handleDatabaseChange :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	notification: DatabaseChangeNotification,
) {
	switch notification.channel {
	case .Restricted:
		MainRouterState_restrictedChangedInDatabase(pm, state, notification.ids[:])
	}
}

// The listener (re)connected: whatever changed while nobody listened was never reported, so
// every channel's state is read again. The first time it is also the router's start, which
// MainRouterState_handleRestrictedUsersResult tells apart.
MainRouterState_databaseChangesListening :: proc(pm: ^ProcessManager, state: ^MainRouterState) {
	MainRouterState_loadRestrictedUsers(pm, state)
}

// Reads userIDs (distinct) again; MainRouterState_handleRestrictedChangesResult applies them.
// Accounts the router counts as restricted are named in the request, so one whose restriction
// was lifted joins the Public rooms in the same statement.
MainRouterState_restrictedChangedInDatabase :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	userIDs: []int,
) {
	if len(userIDs) == 0 {
		return
	}
	request := common.DatabaseRestrictedChangesRequest {
		userIds           = make([dynamic]int, 0, len(userIDs)),
		restrictedUserIds = make([dynamic]int),
	}
	for userID in userIDs {
		append(&request.userIds, userID)
		if MainRouterState_userIsRestricted(state, userID) {
			append(&request.restrictedUserIds, userID)
		}
	}
	MainRouterState_enqueueChannelDatabaseRequest(
		pm,
		state,
		0,
		request,
		PendingDBRequest{requestType = .RestrictedChanges},
	)
}

MainRouterState_handleRestrictedChangesResult :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	response: common.DatabaseQueryResponse,
) {
	changes, changesOK := response.result.(common.DatabaseRestrictedChangesResult)
	if !response.success || !changesOK {
		fmt.printfln(
			"[Main] Could not read restrictions changed in the database: %s",
			response.message,
		)
		return
	}
	applied := 0
	for account in changes.accounts {
		if MainRouterState_applyRestrictedChange(pm, state, account) {
			applied += 1
		}
	}
	if applied == 0 {
		return
	}
	fmt.printfln("[Main] Applied %d restriction change(s) made in the database", applied)
	// Who sees the accounts, and whom they see, changed for everyone: once for all of them.
	MainRouterState_resendAllUserLists(pm, state)
}
