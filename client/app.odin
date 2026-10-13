package client

import "core:fmt"
import "core:os"
import "core:sync"
import "ui"
import SDL "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

FONT_REGULAR :: #load("assets/fonts/InterVariable.ttf")
FONT_BOLD :: #load("assets/fonts/Inter-Bold.ttf")
FONT_EMOJI :: #load("assets/fonts/Twemoji-Mozilla.ttf")

WINDOW_DEFAULT_WIDTH :: 1280
WINDOW_DEFAULT_HEIGHT :: 800
WINDOW_MIN_WIDTH :: 800
WINDOW_MIN_HEIGHT :: 480
// Longest the loop sleeps without input, network events, or a UI deadline.
IDLE_MAX_WAIT_MS :: 1000
// Used only when SDL cannot register the wake event, so network events are still picked up.
WAKE_FALLBACK_POLL_MS :: 50

// Lets the network worker wake the UI loop. pending coalesces wakes, so a burst of network
// events pushes a single SDL event.
AppWake :: struct {
	eventType: u32,
	pending:   bool,
}

// Runs on the network worker thread. SDL_PushEvent is thread safe.
appWakeFromWorker :: proc(userdata: rawptr) {
	wake := (^AppWake)(userdata)
	if sync.atomic_exchange(&wake.pending, true) {
		return
	}
	event: SDL.Event
	event.type = SDL.EventType(wake.eventType)
	_ = SDL.PushEvent(&event)
}

main :: proc() {
	if !runApp() {
		os.exit(1)
	}
}

runApp :: proc() -> bool {
	_ = SDL.SetAppMetadata("HayChat", nil, "chat.haychat.client")
	// The text input draws IME composition itself.
	_ = SDL.SetHint(SDL.HINT_IME_IMPLEMENTED_UI, "composition")
	_ = SDL.SetHint(SDL.HINT_VIDEO_X11_NET_WM_BYPASS_COMPOSITOR, "0")

	if !SDL.Init({.VIDEO, .EVENTS}) {
		fmt.eprintln("[Error] Failed to initialize SDL:", SDL.GetError())
		return false
	}
	defer SDL.Quit()
	if !ttf.Init() {
		fmt.eprintln("[Error] Failed to initialize SDL_ttf:", SDL.GetError())
		return false
	}
	defer ttf.Quit()

	window := SDL.CreateWindow(
		"HayChat",
		WINDOW_DEFAULT_WIDTH,
		WINDOW_DEFAULT_HEIGHT,
		{.RESIZABLE, .HIGH_PIXEL_DENSITY},
	)
	if window == nil {
		fmt.eprintln("[Error] Failed to create the window:", SDL.GetError())
		return false
	}
	defer SDL.DestroyWindow(window)
	_ = SDL.SetWindowMinimumSize(window, WINDOW_MIN_WIDTH, WINDOW_MIN_HEIGHT)

	renderer := SDL.CreateRenderer(window, nil)
	if renderer == nil {
		fmt.eprintln("[Error] Failed to create the renderer:", SDL.GetError())
		return false
	}
	defer SDL.DestroyRenderer(renderer)
	_ = SDL.SetRenderVSync(renderer, 1)
	_ = SDL.SetRenderDrawBlendMode(renderer, {.BLEND})

	ctx: ui.Context
	if !ui.init(&ctx, window, renderer, {FONT_REGULAR, FONT_BOLD, FONT_EMOJI}) {
		return false
	}
	defer ui.destroy(&ctx)

	wake := AppWake {
		eventType = SDL.RegisterEvents(1),
	}
	wakeProc: NetworkWorkerEventQueuedProc = appWakeFromWorker
	if wake.eventType == 0 {
		fmt.eprintln("[Warning] No SDL user event available; polling for network events")
		wakeProc = nil
	}

	// Startup authentication blocks, so show something while it runs.
	drawStartupFrame(&ctx)
	state := init(wakeProc, &wake)
	// Deferred last so it runs first: the worker stops before the window and SDL go away.
	defer State_deinit(&state)

	running := true
	for running {
		ui.Input_reset(&ctx.input)
		redraw := ctx.needsFrame
		timeout := i32(0)
		if !redraw {
			waitMS := u64(IDLE_MAX_WAIT_MS)
			if ctx.nextDeadlineMS != ui.NO_DEADLINE {
				now := u64(SDL.GetTicks())
				waitMS = ctx.nextDeadlineMS > now ? min(waitMS, ctx.nextDeadlineMS - now) : 0
			}
			if wakeProc == nil {
				waitMS = min(waitMS, WAKE_FALLBACK_POLL_MS)
			}
			timeout = i32(waitMS)
		}

		event: SDL.Event
		if SDL.WaitEventTimeout(&event, timeout) {
			for {
				if handleAppEvent(&ctx, &event, &wake, &running) {
					redraw = true
				}
				if !SDL.PollEvent(&event) {
					break
				}
			}
		}
		if !running {
			break
		}
		if State_drainNetworkEvents(&state) {
			redraw = true
		}
		if ctx.nextDeadlineMS != ui.NO_DEADLINE && u64(SDL.GetTicks()) >= ctx.nextDeadlineMS {
			redraw = true
		}
		if redraw {
			ui.beginFrame(&ctx)
			viewApp(&state, &ctx)
			ui.endFrame(&ctx)
		}
		free_all(context.temp_allocator)
	}
	return true
}

// Returns true when the event needs a new frame.
@(private = "file")
handleAppEvent :: proc(
	ctx: ^ui.Context,
	event: ^SDL.Event,
	wake: ^AppWake,
	running: ^bool,
) -> bool {
	#partial switch event.type {
	case .QUIT, .WINDOW_CLOSE_REQUESTED:
		running^ = false
		return false
	}
	if wake.eventType != 0 && u32(event.type) == wake.eventType {
		// Network events are drained after the event batch.
		sync.atomic_store(&wake.pending, false)
		return false
	}
	return ui.handleEvent(ctx, event)
}

@(private = "file")
drawStartupFrame :: proc(ctx: ^ui.Context) {
	ui.beginFrame(ctx)
	ui.label(ctx, ctx.windowRect, "Connecting…", ctx.theme.fgMuted, align = .Center)
	ui.endFrame(ctx)
	free_all(context.temp_allocator)
}
