package client

import "core:fmt"
import "core:strings"

// What the encryption key UI shows (e2ee-design.md 3.4, 3.5): the Verify encryption… dialog,
// the key banner above a direct conversation, and the key indicator on member and conversation
// rows. Pure builders over State; view_e2ee.odin draws them.

// The open Verify encryption… dialog, if any.
VerifyDialogState :: struct {
	open:     bool,
	serverID: int,
	userID:   int,
}

// Opens the dialog for an account of the server, not yourself, and asks the server for its
// current bundle so the number shown is checked against what the server says now.
State_openVerifyDialog :: proc(state: ^State, serverID, userID: int) -> bool {
	if userID <= 0 || userID == State_selfUserID(state, serverID) {
		return false
	}
	State_closeContextMenu(state)
	state.verifyDialog = VerifyDialogState {
		open     = true,
		serverID = serverID,
		userID   = userID,
	}
	ids := [1]int{userID}
	State_e2eeRequestUserKeys(state, serverID, ids[:])
	return true
}

State_closeVerifyDialog :: proc(state: ^State) {
	state.verifyDialog = {}
}

State_verifyDialogMarkVerified :: proc(state: ^State) -> bool {
	dialog := state.verifyDialog
	if !dialog.open {
		return false
	}
	return State_e2eeMarkVerified(state, dialog.serverID, dialog.userID)
}

E2EEBannerTone :: enum u8 {
	Notice,
	Warning,
}

VerifyDialogView :: struct {
	visible:          bool,
	serverID:         int,
	userID:           int,
	title:            string,
	// Three rows of four groups of five digits; empty while there is no key to compare.
	safetyNumberRows: [3]string,
	safetyNumber:     string,
	explanation:      string,
	stateText:        string,
	stateTone:        E2EEBannerTone,
	markEnabled:      bool,
	markLabel:        string,
}

VERIFY_DIALOG_EXPLANATION ::
	"Compare this number with the one %s sees, in person or over a call you trust. If they " +
	"match, nobody can read your encrypted messages in between. The number is the same on " +
	"every server where you both have an account."

// The dialog for state.verifyDialog. Strings are in allocator or borrowed from State.
buildVerifyDialogView :: proc(
	state: ^State,
	allocator := context.temp_allocator,
) -> (
	view: VerifyDialogView,
) {
	dialog := state.verifyDialog
	if !dialog.open || State_selectedTransportIndexForServerID(state^, dialog.serverID) < 0 {
		return
	}
	view.visible = true
	view.serverID = dialog.serverID
	view.userID = dialog.userID
	name := State_e2eeUserName(state, dialog.serverID, dialog.userID, allocator)
	view.title = fmt.aprintf("Verify encryption with %s", name, allocator = allocator)
	view.explanation = fmt.aprintf(VERIFY_DIALOG_EXPLANATION, name, allocator = allocator)

	info := State_e2eePeerKeyInfo(state, dialog.serverID, dialog.userID)
	if number, ok := State_e2eeSafetyNumber(state, dialog.serverID, dialog.userID, allocator);
	   ok {
		view.safetyNumber = number
		// Each group is five digits and a space: rows of four groups are 24 bytes apart.
		for row in 0 ..< 3 {
			start := row * 24
			view.safetyNumberRows[row] = number[start:min(start + 23, len(number))]
		}
	}

	view.markLabel = "Mark as verified"
	switch info.state {
	case .Verified:
		view.stateText = "Verified. The keys match what you compared."
		view.markLabel = "Verified"
	case .Unverified:
		view.stateText = "Not verified yet."
		view.markEnabled = true
	case .KeyChanged:
		view.stateTone = .Warning
		if info.hasOfferedKey {
			view.stateText = fmt.aprintf(
				"%s's key changed. This is the number for the new key; mark it verified " +
				"only after comparing it with %s.",
				name,
				name,
				allocator = allocator,
			)
			view.markLabel = "Trust and mark as verified"
			view.markEnabled = true
		} else {
			view.stateText = fmt.aprintf(
				"%s's key changed. Waiting for the new key from the server…",
				name,
				allocator = allocator,
			)
		}
	case .Unknown, .NotSetUp, .NotProvided, .InvalidKey:
		view.stateTone = info.state == .Unknown ? .Notice : .Warning
		view.stateText = e2eeKeyStateText(info, name, allocator)
	}
	return
}

// The peer's name from the directory, or "User N".
State_e2eeUserName :: proc(
	state: ^State,
	serverID, userID: int,
	allocator := context.temp_allocator,
) -> string {
	nickname := ""
	if index := State_serverDirectCacheIndex(state^, serverID); index >= 0 {
		nickname = ServerDirectCache_peerNickname(&state.serverDirectCaches[index], userID)
	}
	return strings.clone(userLabel(nickname, userID, allocator), allocator)
}

// The key banner above a direct conversation: a changed, missing or invalid key (warning), or
// the notice that the peer set up encryption again. Nothing for a matching key, or one not
// checked yet.
E2EEKeyBannerView :: struct {
	visible:     bool,
	tone:        E2EEBannerTone,
	text:        string,
	showVerify:  bool,
	showTrust:   bool,
	showDismiss: bool,
}

buildE2EEKeyBanner :: proc(
	state: ^State,
	serverID, peerUserID: int,
	allocator := context.temp_allocator,
) -> (
	view: E2EEKeyBannerView,
) {
	if peerUserID <= 0 || peerUserID == State_selfUserID(state, serverID) {
		return
	}
	info := State_e2eePeerKeyInfo(state, serverID, peerUserID)
	name := State_e2eeUserName(state, serverID, peerUserID, allocator)
	switch info.state {
	case .KeyChanged:
		view.visible = true
		view.tone = .Warning
		view.text = fmt.aprintf(
			"%s's key changed. Accounts never change keys, so the server may be trying to " +
			"read your messages, or its database was replaced. Encrypted messages to %s are " +
			"blocked until you verify or trust the new key.",
			name,
			name,
			allocator = allocator,
		)
		view.showVerify = true
		view.showTrust = info.hasOfferedKey
	case .NotProvided, .InvalidKey:
		view.visible = true
		view.tone = .Warning
		view.text = e2eeKeyStateText(info, name, allocator)
	case .Unverified, .Verified:
		if info.notice == .KeySetUpAgain {
			view.visible = true
			view.tone = .Notice
			view.text = fmt.aprintf(
				"%s set up encryption again. Verify the new safety number with %s.",
				name,
				name,
				allocator = allocator,
			)
			view.showVerify = true
			view.showDismiss = true
		}
	case .Unknown, .NotSetUp:
	}
	return
}

// The indicator on a member or conversation row, "" for none.
e2eeKeyIndicator :: proc(keyState: E2EEKeyState) -> (text: string, tone: E2EEIndicatorTone) {
	switch keyState {
	case .Unverified:
		return "unverified", .Muted
	case .Verified:
		return "verified", .Good
	case .KeyChanged:
		return "key changed", .Danger
	case .NotProvided, .InvalidKey:
		return "key problem", .Warning
	case .Unknown, .NotSetUp:
	}
	return "", .Muted
}

E2EEIndicatorTone :: enum u8 {
	Muted,
	Good,
	Warning,
	Danger,
}

// The tooltip for a row's key state.
e2eeKeyIndicatorTooltip :: proc(keyState: E2EEKeyState) -> string {
	switch keyState {
	case .Unverified:
		return "Encryption key pinned, not verified"
	case .Verified:
		return "Encryption key verified"
	case .KeyChanged:
		return "Encryption key changed: verify before sending"
	case .NotProvided:
		return "The server is not providing this account's encryption key"
	case .InvalidKey:
		return "The server sent an invalid encryption key"
	case .Unknown, .NotSetUp:
	}
	return ""
}
