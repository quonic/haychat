package client

import "core:fmt"
import "core:os"
import "core:sync"
import "core:time"
import "hotkey"
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
	// The headless harness (headless.odin) never initialises SDL.
	if headlessRequested(os.args[1:]) {
		os.exit(headlessMain(os.args[1:]))
	}
	// A hidden debug mode (voice_loopback.odin): microphone → Opus → speakers, no window.
	if voiceLoopbackRequested(os.args[1:]) {
		os.exit(voiceLoopbackMain(os.args[1:]))
	}
	// UI script mode (ui_script.odin) drives this same window from a script.
	if uiScriptRequested(os.args[1:]) {
		os.exit(uiScriptMain(os.args[1:]))
	}
	// A haychat:// link (plan D19) goes to a HayChat window that already runs, if any.
	if link := schemeLinkArgument(os.args[1:]); len(link) > 0 {
		initConfigHome()
		if schemeHandler(link) {
			os.exit(0)
		}
	}
	if !runApp() {
		os.exit(1)
	}
}

AppOptions :: struct {
	// Set by --ui-script: the loop runs one script step per iteration and ends with the script.
	script:       ^UIScriptRunner,
	windowWidth:  i32, // 0 means WINDOW_DEFAULT_WIDTH
	windowHeight: i32, // 0 means WINDOW_DEFAULT_HEIGHT
}

runApp :: proc(options: AppOptions = {}) -> bool {
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
		options.windowWidth > 0 ? options.windowWidth : WINDOW_DEFAULT_WIDTH,
		options.windowHeight > 0 ? options.windowHeight : WINDOW_DEFAULT_HEIGHT,
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
	script := options.script
	if script != nil {
		ui.enableAutomation(&ctx)
		fmt.eprintln(
			"[Info] UI script: video driver",
			SDL.GetCurrentVideoDriver(),
			"renderer",
			SDL.GetRendererName(renderer),
		)
	}

	wake := AppWake {
		eventType = SDL.RegisterEvents(1),
	}
	wakeProc: NetworkWorkerEventQueuedProc = appWakeFromWorker
	if wake.eventType == 0 {
		fmt.eprintln("[Warning] No SDL user event available; polling for network events")
		wakeProc = nil
	}

	// init returns at once: the network worker connects in the background and the first frame
	// shows the connection status (or the first-run screen).
	state := init(wakeProc, &wake)
	// Deferred last so it runs first: the worker stops before the window and SDL go away.
	defer State_deinit(&state)
	// A conversation counts as viewed, and is marked read, only while the window has focus.
	// A UI script drives the window like a user sitting at it, so it counts as focused even
	// where the video driver (offscreen) never reports focus.
	state.windowFocused = script != nil || .INPUT_FOCUS in SDL.GetWindowFlags(window)
	// Global push-to-talk (issue 45). It wakes the loop like the network worker does. A UI
	// script gets none, so automation never reads the real keyboard.
	globalBackend := script != nil ? hotkey.Backend.None : hotkey.defaultBackend()
	globalWake: hotkey.ChangeProc = nil
	if wakeProc != nil {
		globalWake = appWakeFromWorker
	}
	state.voice.globalPushToTalk = hotkey.create(globalBackend, globalWake, &wake)
	// How long until a throttled mark-read may go out (State_updateReadMarkers), or -1.
	readMarkerWait := time.Duration(-1)
	// Voice meters and speaking dots change with no event. While they are on screen the loop
	// wakes every VOICE_REDRAW_INTERVAL_MS to compare what they would show with what the last
	// frame drew, and redraws only on a change: an idle voice session renders nothing.
	voicePollAtMS: u64

	running := true
	for running {
		if script != nil {
			// Between frames, so pushed input reaches the next frame like real input.
			UIScriptRunner_step(script, &ctx, window)
			if script.finished {
				break
			}
		}
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
			if script != nil {
				waitMS = min(waitMS, UI_SCRIPT_TICK_MS)
			}
			if readMarkerWait >= 0 {
				waitMS = min(waitMS, u64(time.duration_milliseconds(readMarkerWait)) + 1)
			}
			if state.linkHandoffWatch {
				waitMS = min(waitMS, LINK_HANDOFF_POLL_MS)
			}
			if State_voiceNeedsRedraws(&state) {
				now := u64(SDL.GetTicks())
				waitMS = voicePollAtMS > now ? min(waitMS, voicePollAtMS - now) : 0
			}
			timeout = i32(waitMS)
		}

		event: SDL.Event
		if SDL.WaitEventTimeout(&event, timeout) {
			for {
				appTrackWindowFocus(&state, &event, script != nil)
				if appHandleVoiceEvent(&state, &event, ui.hasTextFocus(&ctx)) {
					redraw = true
				}
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
		// A link another process passed on shows its confirmation.
		if State_pollLinkHandoff(&state) {
			redraw = true
		}
		// Encrypted voice (voice_e2ee.odin): timed rotations, epoch grace and key requests.
		State_voiceE2EETick(&state)
		// After the events and the network: both the window's key and a voice join or leave
		// change what push-to-talk follows.
		if State_voiceSyncPushToTalk(&state, ui.hasTextFocus(&ctx)) {
			redraw = true
		}
		if ctx.nextDeadlineMS != ui.NO_DEADLINE && u64(SDL.GetTicks()) >= ctx.nextDeadlineMS {
			redraw = true
		}
		if State_voiceRedrawDue(&state, u64(SDL.GetTicks()), &voicePollAtMS) {
			redraw = true
		}
		if redraw {
			ui.beginFrame(&ctx)
			viewApp(&state, &ctx)
			ui.endFrame(&ctx)
		}
		// After the events and the frame's actions, so a conversation just opened or a message
		// just arrived in the open one is marked read without waiting for another event.
		readMarkerWait = State_updateReadMarkers(&state, time.tick_now())
		free_all(context.temp_allocator)
	}
	if script != nil {
		UIScriptRunner_stop(script, "the window was closed before the script finished")
	}
	return true
}

// Follows the window's input focus for State.windowFocused. A scripted window stays focused.
@(private = "file")
appTrackWindowFocus :: proc(state: ^State, event: ^SDL.Event, scripted: bool) {
	#partial switch event.type {
	case .WINDOW_FOCUS_GAINED:
		state.windowFocused = true
	case .WINDOW_FOCUS_LOST:
		if !scripted {
			// While the conversation still counts as viewed: send a throttled mark-read now,
			// or the messages seen in the last second would count neither as read nor unread.
			State_flushReadMarkers(state, time.tick_now())
		}
		state.windowFocused = scripted
	}
}

// Push-to-talk and audio hotplug. Here the push-to-talk key is read from the window's own
// key events, and losing focus releases it, because the key-up then goes to another window;
// the global monitor covers other windows (State_voiceSyncPushToTalk combines the two after
// the events). textFocused says a text field had keyboard focus in the last frame: a
// push-to-talk key that types is then left to the text field (voicePushToTalkKeyEvent).
// Returns true when the event needs a new frame.
@(private = "file")
appHandleVoiceEvent :: proc(state: ^State, event: ^SDL.Event, textFocused: bool) -> bool {
	#partial switch event.type {
	case .KEY_DOWN, .KEY_UP:
		if event.key.repeat || state.voicePanel.capturingKey {
			return false
		}
		change, held := voicePushToTalkKeyEvent(
			State_voicePushToTalkKeycode(state),
			event.key.key,
			event.type == .KEY_DOWN,
			state.voice.pushToTalkWindowHeld,
			textFocused,
		)
		if change {
			state.voice.pushToTalkWindowHeld = held
		}
	case .WINDOW_FOCUS_LOST:
		state.voice.pushToTalkWindowHeld = false
	case .AUDIO_DEVICE_ADDED, .AUDIO_DEVICE_REMOVED:
		State_voiceAudioDevicesChanged(state)
		return true
	}
	return false
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
