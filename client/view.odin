package client

import "core:fmt"
import "core:os"
import "core:strings"
import "shared:skald"


view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	return view_main_body(s, ctx)
}

view_main_body :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	return skald.row(view_server_selection(s, ctx), view_inner_body(s, ctx))
}

view_server_selection :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	list: [dynamic]skald.View
	append(&list, skald.button(ctx, "DMs", Msg{kind = .SwitchToDMs}))
	for server in s.config.servers {
		append(&list, skald.button(ctx, server.name, Msg{kind = .SwitchToServer, id = server.id}))
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
	return skald.row(dm_list(s, ctx), online_view(s, ctx))
}

dm_list :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	list: [dynamic]skald.View
	for friend in s.config.friends {
		append(
			&list,
			skald.button(
				ctx,
				friend.display_name,
				Msg{kind = .SwitchToFriendsList, id = friend.id},
			),
		)
	}
	return skald.col(..list[:])
}

online_view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	friendsOnline: [dynamic]skald.View
	for friend in s.config.friends {
		if friend.online {
			append(
				&friendsOnline,
				skald.text(fmt.tprintf("🟢 %s", friend.display_name), th.color.fg),
			)
		} else {
			append(
				&friendsOnline,
				skald.text(fmt.tprintf("🔴 %s", friend.display_name), th.color.fg),
			)
		}
	}
	return skald.col(..friendsOnline[:])
}
