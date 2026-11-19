package client

// Native file dialogs for attachments (attachments plan F4): the composer's paperclip opens
// SDL_ShowOpenFileDialog (several files at once) and a file card's Save… opens
// SDL_ShowSaveFileDialog. SDL may call a dialog's callback on another thread, so the callback
// only copies the chosen paths into its slot of a FileDialogQueue under the queue's mutex and
// wakes the UI loop; the loop takes the answers (State_pollFileDialogs) and only then touches
// State. Nothing here runs a file or reads one.
//
// Automation (ui-script) cannot drive a native dialog, so it goes around it: `attach-file PATH`
// queues a path as if it was picked for the composer on screen (FileDialogQueue_pushPicked),
// and `save-path PATH` answers the next Save… with PATH instead of opening the dialog
// (FileDialogQueue_setNextSavePath).
//
// The queue is heap allocated and owned by State (State.fileDialogs). A dialog still open when
// State goes away keeps its slot's pointer, so the queue is then left allocated for the
// callback that may still come.

import "base:runtime"
import "core:c"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import SDL "vendor:sdl3"

// At most this many native dialogs open at once; a request beyond it is refused.
FILE_DIALOG_SLOTS :: 4

FileDialogKind :: enum u8 {
	Open, // paths to attach to the composer of target
	Save, // where to save file target.index of message target.messageID
}

// What a dialog's answer is for. current (automation only) means the composer shown when the
// answer is handled.
FileDialogTarget :: struct {
	serverID:   int,
	roomID:     int,
	peerUserID: int,
	messageID:  int,
	index:      int,
	current:    bool,
}

@(private = "file")
FileDialogSlot :: struct {
	queue:  ^FileDialogQueue,
	inUse:  bool,
	done:   bool,
	kind:   FileDialogKind,
	target: FileDialogTarget,
	paths:  [dynamic]string, // owned, filled by the callback
	failed: bool,
	error:  string, // owned
}

FileDialogQueue :: struct {
	mutex:           sync.Mutex,
	// The context the callback allocates with: the one the queue was made in.
	ctx:             runtime.Context,
	slots:           [FILE_DIALOG_SLOTS]FileDialogSlot,
	// Automation: paths queued as if picked (owned), and the answer to the next Save….
	picked:          [dynamic]string,
	nextSavePath:    string,
	hasNextSavePath: bool,
	// Wakes the UI loop after an answer arrived (app.odin's appWakeFromWorker).
	wake:            NetworkWorkerEventQueuedProc,
	wakeData:        rawptr,
}

// One answer taken from the queue. paths are owned (FileDialogAnswer_deinit). cancelled: the
// user closed the dialog without choosing; error: the dialog could not open.
FileDialogAnswer :: struct {
	kind:      FileDialogKind,
	target:    FileDialogTarget,
	paths:     [dynamic]string,
	cancelled: bool,
	error:     string,
}

FileDialogAnswer_deinit :: proc(answer: ^FileDialogAnswer) {
	for path in answer.paths {
		delete(path)
	}
	delete(answer.paths)
	delete(answer.error)
	answer^ = {}
}

FileDialogQueue_create :: proc() -> ^FileDialogQueue {
	queue := new(FileDialogQueue)
	queue.ctx = context
	for &slot in queue.slots {
		slot.queue = queue
	}
	return queue
}

@(private = "file")
fileDialogSlotClear :: proc(slot: ^FileDialogSlot) {
	for path in slot.paths {
		delete(path)
	}
	delete(slot.paths)
	delete(slot.error)
	queue := slot.queue
	slot^ = {}
	slot.queue = queue
}

// Frees the queue unless a dialog is still open (its callback would write into it). Returns
// whether it was freed.
FileDialogQueue_destroy :: proc(queue: ^FileDialogQueue) -> bool {
	if queue == nil {
		return true
	}
	sync.mutex_lock(&queue.mutex)
	open := false
	for &slot in queue.slots {
		if slot.inUse && !slot.done {
			open = true
		}
	}
	if open {
		// Left for the callback still to come, which must then wake nothing.
		queue.wake = nil
		queue.wakeData = nil
		sync.mutex_unlock(&queue.mutex)
		return false
	}
	for &slot in queue.slots {
		fileDialogSlotClear(&slot)
	}
	for path in queue.picked {
		delete(path)
	}
	delete(queue.picked)
	delete(queue.nextSavePath)
	sync.mutex_unlock(&queue.mutex)
	free(queue)
	return true
}

// Automation: queues path as if it was picked in the open dialog of the composer on screen.
FileDialogQueue_pushPicked :: proc(queue: ^FileDialogQueue, path: string) {
	sync.mutex_lock(&queue.mutex)
	append(&queue.picked, strings.clone(path, queue.ctx.allocator))
	sync.mutex_unlock(&queue.mutex)
}

// Automation: the next Save… uses path instead of opening the dialog.
FileDialogQueue_setNextSavePath :: proc(queue: ^FileDialogQueue, path: string) {
	sync.mutex_lock(&queue.mutex)
	delete(queue.nextSavePath)
	queue.nextSavePath = strings.clone(path, queue.ctx.allocator)
	queue.hasNextSavePath = true
	sync.mutex_unlock(&queue.mutex)
}

// Takes the answer automation set for the next Save… (owned), if any.
FileDialogQueue_takeNextSavePath :: proc(queue: ^FileDialogQueue) -> (path: string, ok: bool) {
	if queue == nil {
		return "", false
	}
	sync.mutex_lock(&queue.mutex)
	defer sync.mutex_unlock(&queue.mutex)
	if !queue.hasNextSavePath {
		return "", false
	}
	path = queue.nextSavePath
	queue.nextSavePath = ""
	queue.hasNextSavePath = false
	return path, true
}

// Moves every finished dialog's answer and every automation pick to the caller.
FileDialogQueue_take :: proc(queue: ^FileDialogQueue) -> (answers: [dynamic]FileDialogAnswer) {
	if queue == nil {
		return nil
	}
	sync.mutex_lock(&queue.mutex)
	defer sync.mutex_unlock(&queue.mutex)
	for &slot in queue.slots {
		if !slot.inUse || !slot.done {
			continue
		}
		answer := FileDialogAnswer {
			kind      = slot.kind,
			target    = slot.target,
			paths     = slot.paths,
			cancelled = !slot.failed && len(slot.paths) == 0,
			error     = slot.error,
		}
		slot.paths = nil
		slot.error = ""
		fileDialogSlotClear(&slot)
		append(&answers, answer)
	}
	if len(queue.picked) > 0 {
		answer := FileDialogAnswer {
			kind = .Open,
			target = FileDialogTarget{current = true},
			paths = queue.picked,
		}
		queue.picked = nil
		append(&answers, answer)
	}
	return
}

// SDL's callback, on whatever thread SDL chose. filelist is nil on an error and empty when the
// user cancelled.
@(private = "file")
fileDialogCallback :: proc "c" (userdata: rawptr, filelist: [^]cstring, filter: c.int) {
	slot := (^FileDialogSlot)(userdata)
	queue := slot.queue
	context = queue.ctx
	sync.mutex_lock(&queue.mutex)
	if filelist == nil {
		slot.failed = true
		slot.error = strings.clone_from_cstring(SDL.GetError())
	} else {
		for index := 0; filelist[index] != nil; index += 1 {
			append(&slot.paths, strings.clone_from_cstring(filelist[index]))
		}
	}
	slot.done = true
	wake, wakeData := queue.wake, queue.wakeData
	sync.mutex_unlock(&queue.mutex)
	if wake != nil {
		wake(wakeData)
	}
}

@(private = "file")
fileDialogClaimSlot :: proc(
	queue: ^FileDialogQueue,
	kind: FileDialogKind,
	target: FileDialogTarget,
) -> ^FileDialogSlot {
	sync.mutex_lock(&queue.mutex)
	defer sync.mutex_unlock(&queue.mutex)
	for &slot in queue.slots {
		if !slot.inUse {
			slot.inUse = true
			slot.kind = kind
			slot.target = target
			return &slot
		}
	}
	return nil
}

FILE_DIALOG_BUSY_MESSAGE :: "Close the other file dialogs first"

// Opens the native open dialog for target's composer (several files may be picked). Returns
// why it could not open (static), or "".
fileDialogShowOpen :: proc(
	queue: ^FileDialogQueue,
	window: ^SDL.Window,
	target: FileDialogTarget,
) -> string {
	slot := fileDialogClaimSlot(queue, .Open, target)
	if slot == nil {
		return FILE_DIALOG_BUSY_MESSAGE
	}
	// The slot is claimed before SDL is called and the mutex is not held: some backends call
	// back before returning.
	SDL.ShowOpenFileDialog(fileDialogCallback, slot, window, nil, 0, nil, true)
	return ""
}

// Opens the native save dialog for file target.index of message target.messageID, starting at
// suggestedName in the user's Downloads folder. Returns why it could not open (static), or "".
fileDialogShowSave :: proc(
	queue: ^FileDialogQueue,
	window: ^SDL.Window,
	target: FileDialogTarget,
	suggestedName: string,
) -> string {
	slot := fileDialogClaimSlot(queue, .Save, target)
	if slot == nil {
		return FILE_DIALOG_BUSY_MESSAGE
	}
	location := suggestedName
	if downloads := SDL.GetUserFolder(.DOWNLOADS); downloads != nil {
		joined, err := filepath.join(
			{string(downloads), suggestedName},
			context.temp_allocator,
		)
		if err == nil {
			location = joined
		}
	}
	SDL.ShowSaveFileDialog(
		fileDialogCallback,
		slot,
		window,
		nil,
		0,
		strings.clone_to_cstring(location, context.temp_allocator),
	)
	return ""
}
