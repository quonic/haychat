package common

import "core:mem"

// A thin allocator that wipes every block it gives back (#111). The control channel's seal and
// open (sealPacketForSession, openPacketForSession) encode and decode plaintext with it:
// cbor.marshal grows its output buffer as it writes, and cbor.unmarshal grows a decoded byte
// string of more than cbor.DEFAULT_MAX_PRE_ALLOC (1 KiB), so without it every outgrown copy of
// an invite code, a message's text or key material would go back to the heap unwiped.
//
// - Alloc and Alloc_Non_Zeroed go straight to the backing allocator, so a block it hands out
//   is the backing allocator's own: freeing it there (delete without an allocator) is valid,
//   only unwiped, and the test runner's tracking allocator sees every allocation and free.
// - Free wipes old_size bytes first. A free that does not say its size (old_size 0, as
//   free(ptr) sends) cannot be wiped and is passed on as it is.
// - Resize never asks the backing allocator to resize, since a backing allocator that moves the
//   block frees the old one unwiped and does not say whether it moved. It always takes a new
//   block, copies, wipes the whole old block (so a shrink's tail is wiped too) and frees it.
//   A resize that does not say its old size cannot copy and is passed on unwiped.
// - Free_All is refused (Mode_Not_Implemented): the wrapper keeps no list of its blocks, so it
//   could not wipe them. Use it over an allocator that frees block by block (the heap).
// - Query_Info is refused; Query_Features reports what is above.
//
// The wrapper keeps the backing allocator in a WipingAllocator the caller owns, so the
// mem.Allocator it returns is valid only while that value lives (a local in the proc that
// encodes or decodes).
WipingAllocator :: struct {
	backing: mem.Allocator,
}

WipingAllocator_allocator :: proc(wiping: ^WipingAllocator) -> mem.Allocator {
	return mem.Allocator{procedure = wipingAllocatorProc, data = wiping}
}

wipingAllocatorProc :: proc(
	allocatorData: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	oldMemory: rawptr,
	oldSize: int,
	loc := #caller_location,
) -> (
	[]byte,
	mem.Allocator_Error,
) {
	wiping := (^WipingAllocator)(allocatorData)
	backing := wiping.backing

	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		return backing.procedure(backing.data, mode, size, alignment, nil, 0, loc)

	case .Free:
		if oldMemory != nil && oldSize > 0 {
			mem.zero_explicit(oldMemory, oldSize)
		}
		return backing.procedure(backing.data, .Free, 0, 0, oldMemory, oldSize, loc)

	case .Resize, .Resize_Non_Zeroed:
		if oldMemory == nil {
			allocMode: mem.Allocator_Mode = .Alloc if mode == .Resize else .Alloc_Non_Zeroed
			return backing.procedure(backing.data, allocMode, size, alignment, nil, 0, loc)
		}
		if oldSize <= 0 {
			// Nothing to copy from or wipe: only the backing allocator knows the block.
			return backing.procedure(backing.data, mode, size, alignment, oldMemory, oldSize, loc)
		}
		if size <= 0 {
			mem.zero_explicit(oldMemory, oldSize)
			_, freeErr := backing.procedure(backing.data, .Free, 0, 0, oldMemory, oldSize, loc)
			return nil, freeErr
		}
		allocMode: mem.Allocator_Mode = .Alloc if mode == .Resize else .Alloc_Non_Zeroed
		block, allocErr := backing.procedure(backing.data, allocMode, size, alignment, nil, 0, loc)
		if allocErr != nil {
			// The old block stays the caller's, as after any failed resize.
			return nil, allocErr
		}
		mem.copy_non_overlapping(raw_data(block), oldMemory, min(oldSize, size))
		mem.zero_explicit(oldMemory, oldSize)
		_, freeErr := backing.procedure(backing.data, .Free, 0, 0, oldMemory, oldSize, loc)
		return block, freeErr

	case .Free_All:
		return nil, .Mode_Not_Implemented

	case .Query_Features:
		features := (^mem.Allocator_Mode_Set)(oldMemory)
		if features != nil {
			features^ = {
				.Alloc,
				.Alloc_Non_Zeroed,
				.Free,
				.Resize,
				.Resize_Non_Zeroed,
				.Query_Features,
			}
		}
		return nil, nil

	case .Query_Info:
		return nil, .Mode_Not_Implemented
	}
	return nil, .Mode_Not_Implemented
}
