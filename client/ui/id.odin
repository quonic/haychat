package ui

// Widget identity. IDs are hashes, so the same widget gets the same ID every frame as long as
// it is created with the same label under the same parent IDs.

ID :: distinct u64

FNV_OFFSET_BASIS :: 0xcbf29ce484222325
FNV_PRIME :: 0x100000001b3

hashBytes :: proc(seed: u64, data: []u8) -> u64 {
	hash := seed == 0 ? FNV_OFFSET_BASIS : seed
	for b in data {
		hash ~= u64(b)
		hash *= FNV_PRIME
	}
	return hash
}

hashString :: proc(seed: u64, str: string) -> u64 {
	return hashBytes(seed, transmute([]u8)str)
}

hashInt :: proc(seed: u64, value: int) -> u64 {
	value := value
	return hashBytes(seed, ([^]u8)(&value)[:size_of(value)])
}
