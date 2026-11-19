package client

import "core:fmt"

// What the direct conversation pane shows about encryption (protocol 17, e2ee-design.md 4.5,
// 4.6, 7.2): the badge on each message, the composer's state (encrypted, setting up, blocked
// with the "Send without encryption" switch, its confirmation, or the fallback), and the badge
// on a conversation row whose newest message is not encrypted. Pure builders over State;
// view_direct.odin draws them.

DIRECT_BADGE_ENCRYPTED :: "🔒"
DIRECT_BADGE_UNENCRYPTED :: "Unencrypted"
DIRECT_HEADER_ONLINE_ENCRYPTED :: "Online · 🔒 End-to-end encrypted"
DIRECT_HEADER_OFFLINE_ENCRYPTED :: "Offline · 🔒 End-to-end encrypted"
DIRECT_ROW_UNENCRYPTED :: "unencrypted"
DIRECT_ROW_UNENCRYPTED_TOOLTIP :: "The newest message is not encrypted"
DIRECT_CHECKING_TEXT :: "Checking who sent this message…"

// Whether a message is shown at all (#82): every message must be signed by its sender, so a
// Hidden one is left out of the transcript, the conversation preview and the unread count.
directMessageShown :: proc(security: DirectMessageSecurity) -> bool {
	return security.protection != .Hidden
}

// The badge for one message (design 4.5, 4.6): a lock on an opened envelope, "Unencrypted" (a
// warning) on a signed plaintext fallback or one still being checked. An envelope that has not
// opened has no badge: its text says why.
directMessageBadge :: proc(
	security: DirectMessageSecurity,
	hasEnvelope: bool,
) -> (
	badge: string,
	tone: E2EEIndicatorTone,
) {
	switch security.protection {
	case .Encrypted:
		return DIRECT_BADGE_ENCRYPTED, .Good
	case .Signed:
		return DIRECT_BADGE_UNENCRYPTED, .Warning
	case .Pending:
		if !hasEnvelope {
			return DIRECT_BADGE_UNENCRYPTED, .Warning
		}
	case .Failed, .Hidden:
	}
	return "", .Muted
}

// The text shown for a message: its content, or a placeholder for an envelope that could not
// be opened (never retried) or a message waiting for its sender's key. A plaintext message
// waiting for the key keeps its text in content but shows only the placeholder until its
// signature is checked.
directMessageText :: proc(entry: DirectMessageEntry) -> (text: string, placeholder: bool) {
	// Protocol 30: a tombstone (D6) and the latest verified edit (message_edits.odin; the
	// marked text is in the temp allocator).
	if entry.deleted {
		return messageDeletedText(entry.edit), true
	}
	switch entry.security.protection {
	case .Failed:
		return DIRECT_UNDECRYPTABLE_TEXT, true
	case .Pending:
		if len(entry.envelope) > 0 {
			return DIRECT_OPENING_TEXT, true
		}
		return DIRECT_CHECKING_TEXT, true
	case .Hidden:
		return "", true
	case .Signed, .Encrypted:
	}
	return messageEditShownText(entry.content, entry.edit, entry.editCount), false
}

// Whether a conversation row gets the Unencrypted badge for its newest message: a signed
// plaintext fallback, or one still being checked.
directPreviewUnencrypted :: proc(security: DirectMessageSecurity, hasEnvelope: bool) -> bool {
	switch security.protection {
	case .Signed:
		return true
	case .Pending:
		return !hasEnvelope
	case .Encrypted, .Failed, .Hidden:
	}
	return false
}

DirectComposerMode :: enum u8 {
	Encrypted, // The normal composer; messages are encrypted
	SettingUp, // The peer's key is being fetched; messages wait ("Setting up encryption…")
	Blocked, // Encryption is not possible: no composer, the banner says why, with the switch
	Confirm, // The switch's first-time confirmation
	Fallback, // The switch is on: the composer sends signed plaintext, with the warning
}

// The composer area of a direct conversation. Strings are static or in the view allocator.
DirectComposerView :: struct {
	mode:          DirectComposerMode,
	// Messages to this peer are end-to-end encrypted now (the header says so).
	encrypted:     bool,
	placeholder:   string,
	// SettingUp: the note under the composer; Blocked, Confirm, Fallback: why encryption is not
	// possible (the banner).
	note:          string,
	// Blocked and Fallback: the "Send without encryption" switch and its state.
	showSwitch:    bool,
	switchOn:      bool,
	switchLabel:   string,
	// Fallback: the red label above the composer and the send button's text.
	warningLabel:  string,
	sendLabel:     string,
	// Confirm: the explanation and its two buttons.
	confirmText:   string,
	confirmLabel:  string,
	cancelLabel:   string,
	// Messages waiting for the key.
	queuedCount:   int,
}

buildDirectComposerView :: proc(
	state: ^State,
	serverID, peerUserID: int,
	peerLabel: string,
	allocator := context.temp_allocator,
) -> (
	view: DirectComposerView,
) {
	info := State_e2eePeerKeyInfo(state, serverID, peerUserID)
	conversation: ^DirectConversationCache
	if index := State_serverDirectCacheIndex(state^, serverID); index >= 0 {
		cache := &state.serverDirectCaches[index]
		if conversationIndex := ServerDirectCache_conversationCacheIndex(cache^, peerUserID);
		   conversationIndex >= 0 {
			conversation = &cache.caches[conversationIndex]
		}
	}
	fallbackOn := conversation != nil && conversation.fallbackOn
	confirmOpen := conversation != nil && conversation.fallbackConfirmOpen
	if conversation != nil {
		view.queuedCount = len(conversation.queued)
	}
	view.switchLabel = DIRECT_FALLBACK_SWITCH_LABEL
	view.placeholder = fmt.aprintf(
		"Encrypted message to %s (Enter to send, Shift+Enter for newline)",
		peerLabel,
		allocator = allocator,
	)
	switch directSendMode(info, fallbackOn) {
	case .Encrypt:
		view.mode = .Encrypted
		view.encrypted = true
		return
	case .Queue:
		view.mode = .SettingUp
		view.note = DIRECT_SETTING_UP_TEXT
		return
	case .Blocked, .Plaintext:
	}
	view.note = directBlockedText(info, peerLabel, allocator)
	view.showSwitch = true
	view.switchOn = fallbackOn
	switch {
	case confirmOpen:
		view.mode = .Confirm
		view.confirmText = DIRECT_FALLBACK_CONFIRM_TEXT
		view.confirmLabel = "Turn on"
		view.cancelLabel = "Cancel"
	case fallbackOn:
		view.mode = .Fallback
		view.warningLabel = DIRECT_FALLBACK_LABEL
		view.sendLabel = DIRECT_FALLBACK_SEND_LABEL
		view.placeholder = fmt.aprintf(
			"Unencrypted message to %s (Enter to send, Shift+Enter for newline)",
			peerLabel,
			allocator = allocator,
		)
	case:
		view.mode = .Blocked
	}
	return
}

// Why encryption to the peer is not possible, for the banner (design 4.6's three cases, and a
// key the server sent that did not verify).
directBlockedText :: proc(
	info: E2EEPeerKeyInfo,
	peerLabel: string,
	allocator := context.temp_allocator,
) -> string {
	reason := e2eeKeyStateText(info, peerLabel, allocator)
	return fmt.aprintf(
		"%s, so messages to %s cannot be encrypted.",
		reason,
		peerLabel,
		allocator = allocator,
	)
}
