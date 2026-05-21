package client

import "core:os"
import "core:strings"
import "shared:skald"

update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) {
	out := s
	return out, {}
}
