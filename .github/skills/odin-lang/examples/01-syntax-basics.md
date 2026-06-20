# Syntax Basics

```odin
package main

import "core:fmt"

sum :: proc(a: int, b: int) -> int {
	return a + b
}

main :: proc() {
	total := sum(2, 3)
	for i := 0; i < total; i += 1 {
		fmt.println(i)
	}
}
```

Highlights:

- `:=` for inferred declarations.
- `proc` for procedures.
- `for` handles counting loops.
