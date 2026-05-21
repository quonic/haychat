package client

import "core:os"
import "core:strings"
import "shared:skald"


view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	return skald.View{}
}
