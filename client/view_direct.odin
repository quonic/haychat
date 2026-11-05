package client

import "core:fmt"
import "ui"

// The direct conversation pane: the peer's name and online state, the transcript, and a
// composer, laid out like the room pane. It is shown instead of the room while a conversation
// is open (State.selected_dm_peer_id); clicking a channel in the sidebar goes back.
viewDirectChat :: proc(state: ^State, ctx: ^ui.Context, r: ui.Rect, banner: ^ConnectionBanner) {
	view := buildDirectConversationView(state)
	area := r
	viewHeader(ctx, &area, view.peerLabel, view.peerOnline ? "Online" : "Offline")
	viewConnectionBanner(state, ctx, &area, banner)

	serverID := state.selected_server_id
	peerUserID := view.peerUserID
	if draft := State_selectedDirectDraft(state); draft != nil {
		placeholder := fmt.tprintf(
			"Message %s (Enter to send, Shift+Enter for newline)",
			view.peerLabel,
		)
		inputID := ui.idOf("dm-input", serverID, peerUserID)
		result := viewComposer(ctx, &area, inputID, draft, placeholder, view.status)
		if result.submitted {
			State_sendDirectMessage(state)
		}
	} else if len(view.status) > 0 {
		viewComposerStatusOnly(ctx, &area, view.status)
	}

	if view.hasOlder || view.isLoadingHistory {
		historyRow := ui.shrinkXY(
			ui.cutTop(&area, ui.dp(ctx, ROW_HEIGHT + PANEL_PADDING * 2)),
			ui.dp(ctx, COMPOSER_PADDING),
			ui.dp(ctx, PANEL_PADDING),
		)
		if view.isLoadingHistory {
			ui.label(ctx, historyRow, "Loading messages…", ctx.theme.fgMuted, align = .Center)
		} else if ui.button(
			ctx,
			ui.idOf("dm-load-older", serverID, peerUserID),
			historyRow,
			"Load older messages",
			{align = .Center, color = ctx.theme.primary},
		) {
			State_loadOlderDirectHistory(state)
		}
	}

	emptyText := fmt.tprintf("No messages with %s yet. Say hi!", view.peerLabel)
	if view.isLoadingHistory {
		emptyText = "Loading messages…"
	}
	ui.transcript(
		ctx,
		ui.idOf("dm-transcript", serverID, peerUserID),
		area,
		transcriptUnits(ctx, view.lines),
		emptyText,
	)
}
