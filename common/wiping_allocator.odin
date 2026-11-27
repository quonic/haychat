package common

import "base:runtime"
import "core:encoding/cbor"
import "core:mem"
import "core:reflect"

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

// Zeroes a byte buffer before freeing it with the context allocator, for the payload
// openPacketForSession returns (#189): it is the decrypted CBOR of an invite code, a sign-up
// reason or a message's text, so the router's and the client transport's dispatch free it
// through here after the handler is done.
wipeAndDeleteBytes :: proc(value: ^[]u8) {
	if len(value^) > 0 {
		mem.zero_explicit(raw_data(value^), len(value^))
	}
	delete(value^)
	value^ = nil
}

// Decodes a payload that carries a secret (ClientRegister's invite code, ServerInviteCreated's
// code) through a WipingAllocator (#189), so the copies cbor.unmarshal outgrows are wiped as it
// grows them. What it decodes is the context allocator's, as with cbor.unmarshal: the caller
// frees it with the payload's _deinit, which wipes the secret fields.
//
// cbor.unmarshal stores the allocator it decodes with in every dynamic array and map it makes
// (ServerInviteCreated's invite.roleIds). That allocator points at the WipingAllocator on this
// procedure's stack, so before returning, every one of them is pointed back at the backing
// allocator, which owns their blocks (Alloc goes straight through). Unions are not walked: no
// secret payload decodes one.
unmarshalSecretPayload :: proc(payload: []u8, value: ^$T) -> cbor.Unmarshal_Error {
	wiping := WipingAllocator {
		backing = context.allocator,
	}
	wipingAllocator := WipingAllocator_allocator(&wiping)
	err := cbor.unmarshal_from_bytes(
		payload,
		value,
		allocator = wipingAllocator,
		temp_allocator = wipingAllocator,
	)
	wipingAllocatorRebind(any{value, typeid_of(T)}, &wiping)
	return err
}

// Points every dynamic array and map inside v whose allocator is wiping's back at its backing
// allocator (unmarshalSecretPayload).
@(private = "file")
wipingAllocatorRebind :: proc(v: any, wiping: ^WipingAllocator) {
	if v.data == nil {
		return
	}
	isWiping :: proc(allocator: mem.Allocator, wiping: ^WipingAllocator) -> bool {
		return allocator.procedure == wipingAllocatorProc && allocator.data == wiping
	}
	at :: proc(base: rawptr, offset: uintptr, elem: ^reflect.Type_Info) -> any {
		return any{rawptr(uintptr(base) + offset), elem.id}
	}
	ti := reflect.type_info_base(type_info_of(v.id))
	#partial switch info in ti.variant {
	case reflect.Type_Info_Struct:
		for i in 0 ..< int(info.field_count) {
			wipingAllocatorRebind(at(v.data, info.offsets[i], info.types[i]), wiping)
		}
	case reflect.Type_Info_Array:
		for i in 0 ..< info.count {
			wipingAllocatorRebind(at(v.data, uintptr(i * info.elem_size), info.elem), wiping)
		}
	case reflect.Type_Info_Slice:
		raw := (^mem.Raw_Slice)(v.data)
		for i in 0 ..< raw.len {
			wipingAllocatorRebind(at(raw.data, uintptr(i * info.elem_size), info.elem), wiping)
		}
	case reflect.Type_Info_Dynamic_Array:
		raw := (^mem.Raw_Dynamic_Array)(v.data)
		if isWiping(raw.allocator, wiping) {
			raw.allocator = wiping.backing
		}
		for i in 0 ..< raw.len {
			wipingAllocatorRebind(at(raw.data, uintptr(i * info.elem_size), info.elem), wiping)
		}
	case reflect.Type_Info_Map:
		// The map itself only: no secret payload decodes a map of owned values.
		raw := (^runtime.Raw_Map)(v.data)
		if isWiping(raw.allocator, wiping) {
			raw.allocator = wiping.backing
		}
	}
}
