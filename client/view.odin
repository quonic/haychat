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
	)
}

view_server_selection :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	list: [dynamic]skald.View
	width: f32 = 50
	append(&list, skald.button(ctx, "DMs", Msg{kind = .SwitchToDMs}, width = width))
	for server in s.config.servers {
		append(
			&list,
			skald.tooltip(
				ctx,
				skald.button(
					ctx,
					server.short_name,
					Msg{kind = .SwitchToServer, id = server.id},
					width = width,
				),
				server.name, // Tooltip text shows the full server name when hovering over the button
			),
		)
	}
	return skald.col(..list[:])
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
	return skald.col(..server_list[:])
}

view_dms :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	return skald.row(dm_list(s, ctx), dm_chat(s, ctx), cross_align = skald.Cross_Align.Stretch)
}

dm_list :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	list: [dynamic]skald.View
	for friend in s.config.friends {
		if friend.status == .Online {
			append(
				&list,
				skald.button(
					ctx,
					fmt.tprintf("🟢 %s", friend.display_name),
					Msg{kind = .SwitchToFriendsList, id = friend.id},
				),
			)
		} else if friend.status == .Offline {
			append(
				&list,
				skald.button(
					ctx,
					fmt.tprintf("🔴 %s", friend.display_name),
					Msg{kind = .SwitchToFriendsList, id = friend.id},
				),
			)
		} else if friend.status == .Idle {
			append(
				&list,
				skald.button(
					ctx,
					fmt.tprintf("🟡 %s", friend.display_name),
					Msg{kind = .SwitchToFriendsList, id = friend.id},
				),
			)
		} else if friend.status == .DoNotDisturb {
			append(
				&list,
				skald.button(
					ctx,
					fmt.tprintf("⛔ %s", friend.display_name),
					Msg{kind = .SwitchToFriendsList, id = friend.id},
				),
			)
		} else {
			append(
				&list,
				skald.button(
					ctx,
					fmt.tprintf("⚪ %s", friend.display_name),
					Msg{kind = .SwitchToFriendsList, id = friend.id},
				),
			)
		}
	}
	return skald.col(..list[:])
}

dm_chat :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	return skald.col(
		skald.rich_text(ctx, s.current_dm_chat[:], th.color.fg),
		skald.flex(1, skald.spacer(0)),
		skald.divider(ctx),
		skald.chat_input(
			ctx,
			s.dm_chat_draft,
			proc(v: string) -> Msg {return Draft_Changed(v)},
			proc(v: string) -> Msg {return Send_Pressed(v)},
			placeholder = "Message… (Enter to send, Shift+Enter for newline)",
			width = s.window_width - 184,
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
