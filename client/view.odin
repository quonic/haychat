package client

import "core:fmt"
import "core:os"
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
	server_list: [dynamic]skald.View
	for server in s.config.servers {
		if server.id == s.selected_server_id {
			append(&server_list, skald.text(server.name, th.color.fg))
		}
	}
	return skald.col(..server_list[:], spacing = general_spacing)
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
	return skald.col(
		skald.scroll(
			ctx,
			{s.window_width - server_width - friends_list_width, s.window_height - 35},
			skald.rich_text_selectable(ctx, s.current_dm_chat[:], th.color.fg), // Chat messages area
		),
		skald.flex(1, skald.spacer(0)),
		skald.divider(ctx),
		skald.chat_input(
			ctx,
			s.dm_chat_draft,
			Draft_Changed,
			Send_Pressed,
			placeholder = "Message… (Enter to send, Shift+Enter for newline)",
			width = s.window_width - server_width - friends_list_width,
		),
		main_align = skald.Main_Align.Start,
		cross_align = skald.Cross_Align.Stretch,
	)
}

Draft_Changed :: proc(new_value: string) -> Msg {
	return Msg{kind = .UpdateChatInputValue, new_value = new_value}
}
Send_Pressed :: proc(value: string) -> Msg {
	return Msg{kind = .SendChatMessage, new_value = value}
}
