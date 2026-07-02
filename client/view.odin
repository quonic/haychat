package client

import "../common"
import "core:fmt"
import "core:strings"
import "shared:skald"


view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	return view_main_body(s, ctx)
}

view_main_body :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	return skald.row(
		view_server_selection(s, ctx),
		// skald.flex(1, view_inner_body(s, ctx)),
		view_inner_body(s, ctx),
		width = s.window_width,
		cross_align = skald.Cross_Align.Stretch,
		spacing = general_spacing,
	)
}

server_width: f32 = 50
friends_list_width: f32 = 200
button_padding: f32 = 0
general_spacing: f32 = 2

view_server_selection :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	list: [dynamic]skald.View

	append(
		&list,
		skald.button(
			ctx,
			"DMs",
			Msg{kind = .SwitchToDMs},
			width = server_width,
			padding = button_padding,
		),
	)
	for server in s.config.servers {
		append(
			&list,
			skald.tooltip(
				ctx,
				skald.button(
					ctx,
					server.short_name,
					Msg{kind = .SwitchToServer, id = server.id},
					width = server_width,
					padding = button_padding,
				),
				server.name, // Tooltip text shows the full server name when hovering over the button
			),
		)
	}
	return skald.col(..list[:], spacing = general_spacing)
}

view_inner_body :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	if s.view_dms {
		return view_dms(s, ctx)
	} else {
		return view_server(s, ctx)
	}
	return skald.text("!?", th.color.fg)
}

view_server :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme

	channel_buttons: [dynamic]skald.View
	append(
		&channel_buttons,
		skald.button(
			ctx,
			"General",
			Msg {
				kind = .SwitchToChannel,
				id = s.selected_server_id,
				channel_id = common.GENERAL_ROOM_ID,
				new_value = "general",
			},
			padding = button_padding,
		),
	)

	chat_area := skald.col(
		skald.scroll(
			ctx, // Chat messages area
			{s.window_width - friends_list_width - server_width, s.window_height - 45},
			skald.rich_text_selectable(ctx, s.current_chat_messages[:], th.color.fg),
		),
		skald.flex(1, skald.spacer(0)),
		view_chat_status(s, ctx),
		skald.divider(ctx),
		// Chat input area
		skald.chat_input(
			ctx,
			s.chat_input_draft,
			Draft_Channel_Changed,
			Send_Channel_Pressed,
			placeholder = "Message… (Enter to send, Shift+Enter for newline)",
			width = s.window_width - friends_list_width - server_width,
		),
		main_align = skald.Main_Align.Start,
		cross_align = skald.Cross_Align.Stretch,
	)

	return skald.row(
		skald.row(
			skald.col(
				skald.text("Channels", th.color.fg),
				skald.divider(ctx),
				// Channels list area
				skald.scroll(
					ctx,
					size = {server_width + friends_list_width, s.window_height - 35},
					content = skald.col(..channel_buttons[:], spacing = general_spacing),
				),
			),
			skald.flex(1, skald.spacer(0)),
			chat_area,
			cross_align = skald.Cross_Align.Stretch,
			spacing = general_spacing,
		),
	)

}

view_chat_status :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	if len(s.chat_status_message) == 0 {
		return skald.spacer(0)
	}

	return skald.text(s.chat_status_message, ctx.theme.color.danger)
}

view_selected_transport_status :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	if s.selected_transport_index < 0 || s.selected_transport_index >= len(s.serverTransports) {
		return skald.text("No transport selected", th.color.fg_muted)
	}

	transport := s.serverTransports[s.selected_transport_index]
	status := fmt.tprintf(
		"Transport phase: %v | Trust: %v | User ID: %d",
		transport.transport.phase,
		transport.transport.peerTrustState,
		transport.authenticatedUserID,
	)
	if len(transport.lastError) > 0 {
		return skald.col(
			skald.text(status, th.color.fg_muted),
			skald.text(fmt.tprintf("Last error: %s", transport.lastError), th.color.danger),
			spacing = general_spacing,
		)
	}

	return skald.text(status, th.color.fg_muted)
}

view_dms :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	return skald.row(dm_list(s, ctx), dm_chat(s, ctx), cross_align = skald.Cross_Align.Stretch)
}

dm_list :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	list: [dynamic]skald.View
	append(
		&list,
		skald.button(
			ctx,
			"Add Friend",
			Msg{kind = .AddFriend},
			width = friends_list_width,
			padding = button_padding,
		),
	)
	for friend in s.config.friends {
		if friend.status == .Online {
			append(
				&list,
				skald.button(
					ctx,
					fmt.tprintf("🟢 %s", friend.display_name),
					Msg{kind = .SwitchToFriendsList, id = friend.id},
					width = friends_list_width,
					padding = button_padding,
				),
			)
		} else if friend.status == .Offline {
			append(
				&list,
				skald.button(
					ctx,
					fmt.tprintf("🔴 %s", friend.display_name),
					Msg{kind = .SwitchToFriendsList, id = friend.id},
					width = friends_list_width,
					padding = button_padding,
				),
			)
		} else if friend.status == .Idle {
			append(
				&list,
				skald.button(
					ctx,
					fmt.tprintf("🟡 %s", friend.display_name),
					Msg{kind = .SwitchToFriendsList, id = friend.id},
					width = friends_list_width,
					padding = button_padding,
				),
			)
		} else if friend.status == .DoNotDisturb {
			append(
				&list,
				skald.button(
					ctx,
					fmt.tprintf("⛔ %s", friend.display_name),
					Msg{kind = .SwitchToFriendsList, id = friend.id},
					width = friends_list_width,
					padding = button_padding,
				),
			)
		} else {
			append(
				&list,
				skald.button(
					ctx,
					fmt.tprintf("⚪ %s", friend.display_name),
					Msg{kind = .SwitchToFriendsList, id = friend.id},
					width = friends_list_width,
					padding = button_padding,
				),
			)
		}
	}
	return skald.col(..list[:], spacing = general_spacing)
}

dm_chat :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	font_height := th.font.size_md
	return skald.col(
		skald.scroll(
			ctx,
			{
				s.window_width - server_width - friends_list_width,
				s.window_height -
				35 -
				f32(len(strings.split_lines(s.dm_chat_draft))) * font_height,
			},
			skald.rich_text_selectable(ctx, s.current_dm_chat[:], th.color.fg), // Chat messages area
		),
		skald.flex(1, skald.spacer(0)),
		view_chat_status(s, ctx),
		skald.divider(ctx),
		skald.chat_input(
			ctx,
			s.dm_chat_draft,
			Draft_DM_Changed,
			Send_DM_Pressed,
			placeholder = "Message… (Enter to send, Shift+Enter for newline)",
			width = s.window_width - server_width - friends_list_width,
		),
		main_align = skald.Main_Align.Start,
		cross_align = skald.Cross_Align.Stretch,
	)
}

Draft_DM_Changed :: proc(new_value: string) -> Msg {
	return Msg{kind = .UpdateChatInputValue, new_value = new_value}
}
Send_DM_Pressed :: proc(value: string) -> Msg {
	return Msg{kind = .SendChatMessage, new_value = value}
}

Draft_Channel_Changed :: proc(new_value: string) -> Msg {
	return Msg{kind = .UpdateChannelChatInputValue, new_value = new_value}
}
Send_Channel_Pressed :: proc(value: string) -> Msg {
	return Msg{kind = .SendChannelChatMessage, new_value = value}
}
