# Struct Literal Consistency

```odin
Message :: struct {
	id: int,
	kind: int,
	timestamp: i64,
}

newMessageNamed :: proc() -> Message {
	return Message{id = 1, kind = 2, timestamp = 3}
}

newMessagePositional :: proc() -> Message {
	return Message{1, 2, 3}
}

// Invalid in Odin: mixing positional and named fields in one literal
// return Message{1, kind = 2, timestamp = 3}
```

Use either all named fields or all positional fields in the same literal.
