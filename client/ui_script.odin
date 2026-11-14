package client

// UI script mode: `client --ui-script FILE` opens the real window and drives it from a script,
// so an agent can click, type, press keys, wait for text, and capture screenshots without any
// OS-level input injection. Input travels the same path as real input: the interpreter runs on
// the UI thread between frames and pushes synthetic SDL events, which the loop in app.odin
// hands to ui.handleEvent. Lookups read the strings and widget rects the ui package records
// while automation is enabled (client/ui/automation.odin). Results leave as one JSON line per
// command on stdout, like the headless harness (headless.odin). See docs/testing-harness.md.

import "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:os"
import "core:strconv"
import "core:strings"
import "ui"
import SDL "vendor:sdl3"

UI_SCRIPT_FLAG :: "--ui-script"
UI_SCRIPT_EXIT_OK :: 0
UI_SCRIPT_EXIT_USAGE :: 1
UI_SCRIPT_EXIT_FAILED :: 3
UI_SCRIPT_DEFAULT_TIMEOUT_MS :: 5000
UI_SCRIPT_MAX_COUNT :: 1000
// How far one scroll command may turn the wheel, in notches either way.
UI_SCRIPT_MAX_SCROLL_NOTCHES :: 100
UI_SCRIPT_SCROLL_USAGE ::
	"usage: scroll X Y N (N wheel notches, -100 to 100, positive scrolls down)"
UI_SCRIPT_MAX_IDS :: 4
UI_SCRIPT_MAX_WINDOW_SIZE :: 16384
// Longest the loop sleeps while a script runs, so waits and timeouts are checked promptly.
UI_SCRIPT_TICK_MS :: 10
// Frames drawn after an input command before the next command runs: one applies the input,
// the next settles hover and press state (see ui.endFrame).
UI_SCRIPT_SETTLE_FRAMES :: 2
UI_SCRIPT_USAGE ::
	"usage: client --ui-script FILE [--name NAME] [--server HOST:PORT] [--config-dir DIR]\n" +
	"                           [--window WxH]\n" +
	"  --ui-script FILE       run the window from FILE (one command per line, # comments)\n" +
	"  --name NAME            display name (3-32 bytes); saved to the profile\n" +
	"  --server HOST:PORT     the profile's only server; saved to the profile\n" +
	"  --config-dir DIR       config root for this profile (like XDG_CONFIG_HOME)\n" +
	"  --window WxH           window size in window coordinates (default 1280x800)\n" +
	"Set SDL_VIDEO_DRIVER=offscreen to run without a display."

// ── Options ───────────────────────────────────────────────────────

UIScriptOptions :: struct {
	scriptPath:   string, // Borrowed from the argument list
	profile:      HeadlessOptions,
	windowWidth:  i32,
	windowHeight: i32,
}

uiScriptRequested :: proc(args: []string) -> bool {
	for arg in args {
		if arg == UI_SCRIPT_FLAG || strings.has_prefix(arg, UI_SCRIPT_FLAG + "=") {
			return true
		}
	}
	return false
}

// Parses WxH, e.g. 1280x800. Sizes below the window minimum are rejected because SDL would
// enlarge the window and screenshots would not have the asked-for size.
uiScriptParseWindowSize :: proc(value: string) -> (width, height: i32, ok: bool) {
	separator := strings.index_any(value, "xX")
	if separator <= 0 {
		return 0, 0, false
	}
	w, wOK := headlessParseNumber(value[:separator], UI_SCRIPT_MAX_WINDOW_SIZE)
	h, hOK := headlessParseNumber(value[separator + 1:], UI_SCRIPT_MAX_WINDOW_SIZE)
	if !wOK || !hOK || w < WINDOW_MIN_WIDTH || h < WINDOW_MIN_HEIGHT {
		return 0, 0, false
	}
	return i32(w), i32(h), true
}

// Takes --ui-script and --window, and hands every other argument to the headless option
// parser, so --name, --server and --config-dir behave exactly as in headless mode. Returns a
// static error message on failure.
uiScriptParseOptions :: proc(args: []string) -> (options: UIScriptOptions, err: string) {
	options.windowWidth = WINDOW_DEFAULT_WIDTH
	options.windowHeight = WINDOW_DEFAULT_HEIGHT
	shared := make([dynamic]string, 0, len(args), context.temp_allocator)
	for index := 0; index < len(args); index += 1 {
		arg := args[index]
		flag := arg
		value := ""
		hasValue := false
		if equals := strings.index_byte(arg, '='); equals > 0 && strings.has_prefix(arg, "--") {
			flag = arg[:equals]
			value = arg[equals + 1:]
			hasValue = true
		}
		switch flag {
		case UI_SCRIPT_FLAG, "--window":
		case HEADLESS_FLAG, "--connect-timeout":
			return {}, "--headless and --connect-timeout do not apply to --ui-script"
		case:
			append(&shared, arg)
			continue
		}
		if !hasValue {
			if index + 1 >= len(args) {
				return {}, "missing value for an option"
			}
			index += 1
			value = args[index]
		}
		if flag == UI_SCRIPT_FLAG {
			if len(value) == 0 {
				return {}, "--ui-script needs a script file"
			}
			options.scriptPath = value
		} else {
			width, height, ok := uiScriptParseWindowSize(value)
			if !ok {
				return {}, "--window must be WxH, at least 800x480 and at most 16384x16384"
			}
			options.windowWidth = width
			options.windowHeight = height
		}
	}
	if len(options.scriptPath) == 0 {
		return {}, "--ui-script needs a script file"
	}
	profile, profileErr := headlessParseOptions(shared[:])
	if len(profileErr) > 0 {
		return {}, profileErr
	}
	options.profile = profile
	return options, ""
}

// ── Script language ───────────────────────────────────────────────

UIScriptCommandKind :: enum u8 {
	Wait,
	WaitText,
	WaitCount,
	AssertText,
	Click,
	ClickAt,
	ClickID,
	Type,
	Key,
	Screenshot,
	Quit,
	RightClick,
	RightClickAt,
	RightClickID,
	WaitGone,
	Scroll,
}

UI_SCRIPT_COMMAND_NAMES := [UIScriptCommandKind]string {
	.Wait         = "wait",
	.WaitText     = "wait-text",
	.WaitCount    = "wait-count",
	.AssertText   = "assert-text",
	.Click        = "click",
	.ClickAt      = "click",
	.ClickID      = "click-id",
	.Type         = "type",
	.Key          = "key",
	.Screenshot   = "screenshot",
	.Quit         = "quit",
	.RightClick   = "right-click",
	.RightClickAt = "right-click",
	.RightClickID = "right-click-id",
	.WaitGone     = "wait-gone",
	.Scroll       = "scroll",
}

UIScriptKey :: struct {
	scancode: SDL.Scancode,
	key:      SDL.Keycode,
	mod:      SDL.Keymod,
}

UIScriptCommand :: struct {
	kind:      UIScriptCommandKind,
	line:      int, // 1-based line in the script file
	text:      string, // Owned: the TEXT, NAME, or FILE argument, or the key's name
	count:     int, // wait-count: how many times the text must be drawn; scroll: the notches
	timeoutMS: int, // wait: the duration; wait-text, wait-count: the timeout
	x, y:      f32, // click X Y, right-click X Y and scroll X Y N, in window coordinates
	ids:       [UI_SCRIPT_MAX_IDS]int, // click-id, right-click-id: the integers after the name
	idCount:   int,
	key:       UIScriptKey,
}

uiScriptDeleteCommands :: proc(commands: ^[dynamic]UIScriptCommand) {
	for command in commands {
		delete(command.text)
	}
	delete(commands^)
	commands^ = nil
}

UIScriptToken :: struct {
	text:   string, // Temp-allocated when quoted (escapes resolved), otherwise borrowed
	quoted: bool,
}

// Splits a line into words and "quoted strings". A quoted string may hold spaces and the
// escapes \" \\ \n \t. A # that starts a word outside quotes begins a comment.
uiScriptTokenize :: proc(line: string) -> (tokens: [dynamic]UIScriptToken, err: string) {
	tokens = make([dynamic]UIScriptToken, context.temp_allocator)
	index := 0
	for index < len(line) {
		c := line[index]
		if c == ' ' || c == '\t' || c == '\r' {
			index += 1
			continue
		}
		if c == '#' {
			break
		}
		if c != '"' {
			start := index
			for index < len(line) && line[index] != ' ' && line[index] != '\t' &&
			    line[index] != '\r' {
				if line[index] == '"' {
					return tokens, "a quote must start a word"
				}
				index += 1
			}
			append(&tokens, UIScriptToken{line[start:index], false})
			continue
		}

		builder := strings.builder_make(context.temp_allocator)
		index += 1
		closed := false
		for index < len(line) {
			c = line[index]
			index += 1
			if c == '"' {
				closed = true
				break
			}
			if c != '\\' {
				strings.write_byte(&builder, c)
				continue
			}
			if index >= len(line) {
				break
			}
			escaped := line[index]
			index += 1
			switch escaped {
			case '"', '\\':
				strings.write_byte(&builder, escaped)
			case 'n':
				strings.write_byte(&builder, '\n')
			case 't':
				strings.write_byte(&builder, '\t')
			case:
				return tokens, "unknown escape in a quoted string (use \\\" \\\\ \\n \\t)"
			}
		}
		if !closed {
			return tokens, "unterminated quoted string"
		}
		if index < len(line) && line[index] != ' ' && line[index] != '\t' && line[index] != '\r' {
			return tokens, "a closing quote must end a word"
		}
		append(&tokens, UIScriptToken{strings.to_string(builder), true})
	}
	return tokens, ""
}

@(private = "file")
uiScriptParseTimeout :: proc(tokens: []UIScriptToken, index: int) -> (int, bool) {
	if index >= len(tokens) {
		return UI_SCRIPT_DEFAULT_TIMEOUT_MS, true
	}
	if tokens[index].quoted {
		return 0, false
	}
	return headlessParseNumber(tokens[index].text, HEADLESS_MAX_WAIT_MS)
}

@(private = "file")
uiScriptParseCoordinate :: proc(token: UIScriptToken) -> (f32, bool) {
	if token.quoted {
		return 0, false
	}
	value, ok := strconv.parse_f32(token.text)
	return value, ok && value >= 0 && value <= UI_SCRIPT_MAX_WINDOW_SIZE
}

// Parses one script line. isCommand is false for blank and comment lines. command.text is
// allocated with context.allocator.
uiScriptParseLine :: proc(
	line: string,
	lineNumber: int,
) -> (
	command: UIScriptCommand,
	isCommand: bool,
	err: string,
) {
	tokens, tokenErr := uiScriptTokenize(line)
	if len(tokenErr) > 0 {
		return {}, false, tokenErr
	}
	if len(tokens) == 0 {
		return {}, false, ""
	}
	if tokens[0].quoted {
		return {}, false, "a line must start with a command name"
	}
	command.line = lineNumber
	args := tokens[1:]
	text := ""
	ok := true
	switch tokens[0].text {
	case "wait":
		command.kind = .Wait
		ok = len(args) == 1 && !args[0].quoted
		if ok {
			command.timeoutMS, ok = headlessParseNumber(args[0].text, HEADLESS_MAX_WAIT_MS)
		}
		if !ok {
			return {}, false, "usage: wait MS (at most 600000)"
		}
	case "wait-text", "assert-text":
		command.kind = tokens[0].text == "wait-text" ? .WaitText : .AssertText
		command.count = 1
		maxArgs := command.kind == .WaitText ? 2 : 1
		ok = len(args) >= 1 && len(args) <= maxArgs && len(args[0].text) > 0
		if ok && command.kind == .WaitText {
			command.timeoutMS, ok = uiScriptParseTimeout(args, 1)
		}
		if !ok {
			if command.kind == .AssertText {
				return {}, false, "usage: assert-text \"TEXT\""
			}
			return {}, false, "usage: wait-text \"TEXT\" [TIMEOUT_MS]"
		}
		text = args[0].text
	case "wait-gone":
		command.kind = .WaitGone
		ok = len(args) >= 1 && len(args) <= 2 && len(args[0].text) > 0
		if ok {
			command.timeoutMS, ok = uiScriptParseTimeout(args, 1)
		}
		if !ok {
			return {}, false, "usage: wait-gone \"TEXT\" [TIMEOUT_MS]"
		}
		text = args[0].text
	case "wait-count":
		command.kind = .WaitCount
		ok = len(args) >= 2 && len(args) <= 3 && !args[0].quoted && len(args[1].text) > 0
		if ok {
			command.count, ok = headlessParseNumber(args[0].text, UI_SCRIPT_MAX_COUNT)
			ok = ok && command.count > 0
		}
		if ok {
			command.timeoutMS, ok = uiScriptParseTimeout(args, 2)
		}
		if !ok {
			return {}, false, "usage: wait-count N \"TEXT\" [TIMEOUT_MS] (N from 1 to 1000)"
		}
		text = args[1].text
	case "click", "right-click":
		right := tokens[0].text == "right-click"
		switch len(args) {
		case 1:
			command.kind = right ? .RightClick : .Click
			ok = len(args[0].text) > 0
			text = args[0].text
		case 2:
			command.kind = right ? .RightClickAt : .ClickAt
			xOK, yOK: bool
			command.x, xOK = uiScriptParseCoordinate(args[0])
			command.y, yOK = uiScriptParseCoordinate(args[1])
			ok = xOK && yOK
		case:
			ok = false
		}
		if !ok {
			if right {
				return {}, false, "usage: right-click \"TEXT\" or right-click X Y"
			}
			return {}, false, "usage: click \"TEXT\" or click X Y"
		}
	case "scroll":
		command.kind = .Scroll
		ok = len(args) == 3 && !args[2].quoted
		if ok {
			xOK, yOK, nOK: bool
			command.x, xOK = uiScriptParseCoordinate(args[0])
			command.y, yOK = uiScriptParseCoordinate(args[1])
			command.count, nOK = strconv.parse_int(args[2].text, 10)
			ok =
				xOK &&
				yOK &&
				nOK &&
				command.count != 0 &&
				abs(command.count) <= UI_SCRIPT_MAX_SCROLL_NOTCHES
		}
		if !ok {
			return {}, false, UI_SCRIPT_SCROLL_USAGE
		}
	case "click-id", "right-click-id":
		right := tokens[0].text == "right-click-id"
		command.kind = right ? .RightClickID : .ClickID
		ok = len(args) >= 1 && len(args) <= 1 + UI_SCRIPT_MAX_IDS && len(args[0].text) > 0
		for index := 1; ok && index < len(args); index += 1 {
			value, valueOK := strconv.parse_int(args[index].text, 10)
			ok = valueOK && !args[index].quoted
			command.ids[command.idCount] = value
			command.idCount += 1
		}
		if !ok {
			if right {
				return {}, false, "usage: right-click-id NAME [INTEGER...] (at most 4 integers)"
			}
			return {}, false, "usage: click-id NAME [INTEGER...] (at most 4 integers)"
		}
		text = args[0].text
	case "type":
		command.kind = .Type
		ok = len(args) == 1 && len(args[0].text) > 0 && strings.index_byte(args[0].text, 0) < 0
		if !ok {
			return {}, false, "usage: type \"TEXT\""
		}
		text = args[0].text
	case "key":
		command.kind = .Key
		ok = len(args) == 1 && !args[0].quoted
		if ok {
			command.key, ok = uiScriptParseKey(args[0].text)
		}
		if !ok {
			return {}, false, "usage: key [Shift+|Ctrl+|Alt+|Gui+]NAME (see the key table)"
		}
		text = args[0].text
	case "screenshot":
		command.kind = .Screenshot
		file := len(args) == 1 ? args[0].text : ""
		ok = len(file) > 4 && strings.equal_fold(file[len(file) - 4:], ".bmp")
		if !ok {
			return {}, false, "usage: screenshot FILE.bmp (screenshots are written as BMP)"
		}
		text = args[0].text
	case "quit":
		command.kind = .Quit
		if len(args) != 0 {
			return {}, false, "usage: quit"
		}
	case:
		return {}, false, "unknown command"
	}
	command.text = strings.clone(text)
	return command, true, ""
}

// Parses a whole script. On error nothing is returned and errLine names the offending line.
uiScriptParse :: proc(
	source: string,
) -> (
	commands: [dynamic]UIScriptCommand,
	errLine: int,
	err: string,
) {
	remaining := source
	lineNumber := 0
	for line in strings.split_lines_iterator(&remaining) {
		lineNumber += 1
		command, isCommand, lineErr := uiScriptParseLine(line, lineNumber)
		if len(lineErr) > 0 {
			uiScriptDeleteCommands(&commands)
			return nil, lineNumber, lineErr
		}
		if isCommand {
			append(&commands, command)
		}
	}
	return commands, 0, ""
}

// ── Keys ──────────────────────────────────────────────────────────

UIScriptKeyName :: struct {
	name:     string,
	scancode: SDL.Scancode,
	key:      SDL.Keycode,
}

// The keys a script can press, matched without regard to case. Letters are here for
// shortcuts such as Ctrl+A; text is typed with `type`.
UI_SCRIPT_KEYS := [?]UIScriptKeyName {
	{"Return", .RETURN, SDL.K_RETURN},
	{"Enter", .RETURN, SDL.K_RETURN},
	{"Escape", .ESCAPE, SDL.K_ESCAPE},
	{"Tab", .TAB, SDL.K_TAB},
	{"Backspace", .BACKSPACE, SDL.K_BACKSPACE},
	{"Delete", .DELETE, SDL.K_DELETE},
	{"Space", .SPACE, SDL.K_SPACE},
	{"Up", .UP, SDL.K_UP},
	{"Down", .DOWN, SDL.K_DOWN},
	{"Left", .LEFT, SDL.K_LEFT},
	{"Right", .RIGHT, SDL.K_RIGHT},
	{"Home", .HOME, SDL.K_HOME},
	{"End", .END, SDL.K_END},
	{"PageUp", .PAGEUP, SDL.K_PAGEUP},
	{"PageDown", .PAGEDOWN, SDL.K_PAGEDOWN},
	{"A", .A, SDL.K_A},
	{"C", .C, SDL.K_C},
	{"V", .V, SDL.K_V},
	{"X", .X, SDL.K_X},
}

UIScriptModifierName :: struct {
	name: string,
	mod:  SDL.Keymod,
}

UI_SCRIPT_MODIFIERS := [?]UIScriptModifierName {
	{"Shift", SDL.KMOD_LSHIFT},
	{"Ctrl", SDL.KMOD_LCTRL},
	{"Alt", SDL.KMOD_LALT},
	// The ui package reads the GUI (Command) key as Ctrl on macOS.
	{"Gui", SDL.KMOD_LGUI},
	{"Cmd", SDL.KMOD_LGUI},
}

// Parses a key name with optional modifiers, e.g. Return, Shift+Return or ctrl+a.
uiScriptParseKey :: proc(name: string) -> (key: UIScriptKey, ok: bool) {
	rest := name
	for {
		plus := strings.index_byte(rest, '+')
		if plus < 0 {
			break
		}
		modifier := rest[:plus]
		found := false
		for entry in UI_SCRIPT_MODIFIERS {
			if strings.equal_fold(entry.name, modifier) {
				key.mod += entry.mod
				found = true
				break
			}
		}
		if !found {
			return {}, false
		}
		rest = rest[plus + 1:]
	}
	for entry in UI_SCRIPT_KEYS {
		if strings.equal_fold(entry.name, rest) {
			key.scancode = entry.scancode
			key.key = entry.key
			return key, true
		}
	}
	return {}, false
}

// ── Interpreter ───────────────────────────────────────────────────

UIScriptResultJSON :: struct {
	ok:       bool,
	cmd:      string,
	line:     int,
	text:     string `json:"text,omitempty"`,
	name:     string `json:"name,omitempty"`,
	key:      string `json:"key,omitempty"`,
	file:     string `json:"file,omitempty"`,
	// Maybe, because omitempty leaves only nil unions out, never a zero number.
	x:        Maybe(f32) `json:"x,omitempty"`,
	y:        Maybe(f32) `json:"y,omitempty"`,
	ms:       Maybe(int) `json:"ms,omitempty"`,
	waitedMS: Maybe(int) `json:"waitedMS,omitempty"`,
	error:    string `json:"error,omitempty"`,
}

UIScriptDoneJSON :: struct {
	event:   string,
	failed:  int,
	skipped: int,
}

// Runs a parsed script against the window, one step per loop iteration. The script stops at
// the first failed command; the rest count as skipped.
UIScriptRunner :: struct {
	commands:         []UIScriptCommand, // Borrowed
	out:              io.Writer, // JSON lines only
	index:            int,
	commandStarted:   bool,
	commandStartMS:   u64,
	captureRequested: bool,
	// The next command waits until the UI has drawn this frame, so input already pushed has
	// been handled and its effects are on screen.
	settleUntilFrame: u64,
	// Text of the last pushed TEXT_INPUT event. SDL keeps only the pointer, so it lives until
	// the frames after the push have handled it.
	pendingText:      cstring,
	failed:           int,
	skipped:          int,
	finished:         bool,
	exitCode:         int,
}

UIScriptRunner_deinit :: proc(runner: ^UIScriptRunner) {
	delete(runner.pendingText)
	runner.pendingText = nil
}

@(private = "file")
uiScriptWriteJSON :: proc(runner: ^UIScriptRunner, value: any) {
	data, err := json.marshal(value)
	if err != nil {
		fmt.eprintln("[Error] Failed to encode JSON output:", err)
		return
	}
	defer delete(data)
	// One write per line, so a reader never sees half a line.
	line := make([]u8, len(data) + 1)
	defer delete(line)
	copy(line, data)
	line[len(data)] = '\n'
	_, _ = io.write(runner.out, line)
}

@(private = "file")
uiScriptResult :: proc(command: ^UIScriptCommand) -> UIScriptResultJSON {
	result := UIScriptResultJSON {
		ok   = true,
		cmd  = UI_SCRIPT_COMMAND_NAMES[command.kind],
		line = command.line,
	}
	switch command.kind {
	case .WaitText, .WaitCount, .WaitGone, .AssertText, .Click, .RightClick, .Type:
		result.text = command.text
	case .ClickID, .RightClickID:
		result.name = command.text
	case .Key:
		result.key = command.text
	case .Screenshot:
		result.file = command.text
	case .Wait:
		result.ms = command.timeoutMS
	case .ClickAt, .RightClickAt, .Scroll, .Quit:
	}
	return result
}

@(private = "file")
uiScriptFinish :: proc(runner: ^UIScriptRunner) {
	if runner.finished {
		return
	}
	runner.finished = true
	runner.exitCode = runner.failed > 0 ? UI_SCRIPT_EXIT_FAILED : UI_SCRIPT_EXIT_OK
	uiScriptWriteJSON(
		runner,
		UIScriptDoneJSON {
			event = "ui_script_done",
			failed = runner.failed,
			skipped = runner.skipped,
		},
	)
}

@(private = "file")
uiScriptAdvance :: proc(runner: ^UIScriptRunner, result: UIScriptResultJSON) {
	uiScriptWriteJSON(runner, result)
	runner.index += 1
	runner.commandStarted = false
	runner.captureRequested = false
}

@(private = "file")
uiScriptFail :: proc(runner: ^UIScriptRunner, result: UIScriptResultJSON, message: string) {
	result := result
	result.ok = false
	result.error = message
	uiScriptWriteJSON(runner, result)
	runner.failed += 1
	runner.skipped = len(runner.commands) - runner.index - 1
	runner.index = len(runner.commands)
	uiScriptFinish(runner)
}

// Ends a script that did not get to finish, e.g. because the window was closed.
UIScriptRunner_stop :: proc(runner: ^UIScriptRunner, message: string) {
	if runner.finished {
		return
	}
	if runner.index < len(runner.commands) {
		uiScriptFail(runner, uiScriptResult(&runner.commands[runner.index]), message)
	} else {
		uiScriptFinish(runner)
	}
}

@(private = "file")
uiScriptPushEvent :: proc(event: ^SDL.Event) -> bool {
	if !SDL.PushEvent(event) {
		fmt.eprintln("[Error] SDL_PushEvent failed:", SDL.GetError())
		return false
	}
	return true
}

// Moves the pointer to p (window coordinates) and clicks a button there (the left one unless
// button says otherwise).
@(private = "file")
uiScriptPushClick :: proc(window: ^SDL.Window, p: ui.Vec2, button: u8 = SDL.BUTTON_LEFT) -> bool {
	windowID := SDL.GetWindowID(window)
	motion: SDL.Event
	motion.motion = SDL.MouseMotionEvent {
		type     = .MOUSE_MOTION,
		windowID = windowID,
		x        = p.x,
		y        = p.y,
	}
	press: SDL.Event
	press.button = SDL.MouseButtonEvent {
		type     = .MOUSE_BUTTON_DOWN,
		windowID = windowID,
		button   = button,
		down     = true,
		clicks   = 1,
		x        = p.x,
		y        = p.y,
	}
	release := press
	release.button.type = .MOUSE_BUTTON_UP
	release.button.down = false
	return uiScriptPushEvent(&motion) && uiScriptPushEvent(&press) && uiScriptPushEvent(&release)
}

// Moves the pointer to p and turns the wheel by notches (positive scrolls the content down,
// which SDL reports as a negative y).
@(private = "file")
uiScriptPushWheel :: proc(window: ^SDL.Window, p: ui.Vec2, notches: int) -> bool {
	windowID := SDL.GetWindowID(window)
	motion: SDL.Event
	motion.motion = SDL.MouseMotionEvent {
		type     = .MOUSE_MOTION,
		windowID = windowID,
		x        = p.x,
		y        = p.y,
	}
	wheel: SDL.Event
	wheel.wheel = SDL.MouseWheelEvent {
		type      = .MOUSE_WHEEL,
		windowID  = windowID,
		y         = -f32(notches),
		integer_y = -i32(notches),
		direction = .NORMAL,
		mouse_x   = p.x,
		mouse_y   = p.y,
	}
	return uiScriptPushEvent(&motion) && uiScriptPushEvent(&wheel)
}

// The mouse button a click command presses.
@(private = "file")
uiScriptButton :: proc(kind: UIScriptCommandKind) -> u8 {
	#partial switch kind {
	case .RightClick, .RightClickAt, .RightClickID:
		return SDL.BUTTON_RIGHT
	}
	return SDL.BUTTON_LEFT
}

@(private = "file")
uiScriptPushKey :: proc(window: ^SDL.Window, key: UIScriptKey) -> bool {
	press: SDL.Event
	press.key = SDL.KeyboardEvent {
		type     = .KEY_DOWN,
		windowID = SDL.GetWindowID(window),
		scancode = key.scancode,
		key      = key.key,
		mod      = key.mod,
		down     = true,
	}
	release := press
	release.key.type = .KEY_UP
	release.key.down = false
	return uiScriptPushEvent(&press) && uiScriptPushEvent(&release)
}

@(private = "file")
uiScriptPushText :: proc(runner: ^UIScriptRunner, window: ^SDL.Window, text: string) -> bool {
	delete(runner.pendingText)
	runner.pendingText = strings.clone_to_cstring(text)
	event: SDL.Event
	event.text = SDL.TextInputEvent {
		type     = .TEXT_INPUT,
		windowID = SDL.GetWindowID(window),
		text     = runner.pendingText,
	}
	return uiScriptPushEvent(&event)
}

// Converts a rect the ui recorded (render pixels) to the window coordinates of its centre.
@(private = "file")
uiScriptWindowPoint :: proc(ctx: ^ui.Context, r: ui.Rect) -> ui.Vec2 {
	density := ctx.pixelDensity > 0 ? ctx.pixelDensity : 1
	return ui.rectCentre(r) / density
}

// Runs the current command as far as it can go without blocking. Called by the UI loop once
// per iteration, between frames; it never draws.
UIScriptRunner_step :: proc(runner: ^UIScriptRunner, ctx: ^ui.Context, window: ^SDL.Window) {
	if runner.finished {
		return
	}
	if ctx.frame < runner.settleUntilFrame {
		ui.requestFrame(ctx)
		return
	}
	if runner.pendingText != nil {
		delete(runner.pendingText)
		runner.pendingText = nil
	}
	if runner.index >= len(runner.commands) {
		uiScriptFinish(runner)
		return
	}

	command := &runner.commands[runner.index]
	now := u64(SDL.GetTicks())
	if !runner.commandStarted {
		runner.commandStarted = true
		runner.commandStartMS = now
	}
	elapsed := int(now - runner.commandStartMS)
	result := uiScriptResult(command)
	automation := ctx.automation
	pushed := false
	pushOK := true

	switch command.kind {
	case .Wait:
		if elapsed >= command.timeoutMS {
			uiScriptAdvance(runner, result)
		}
	case .WaitText, .WaitCount:
		drawn := ui.Automation_countText(automation, command.text)
		if drawn >= command.count {
			result.waitedMS = elapsed
			uiScriptAdvance(runner, result)
		} else if elapsed >= command.timeoutMS {
			uiScriptFail(
				runner,
				result,
				fmt.tprintf(
					"timed out after %d ms: drawn %d time(s), wanted %d",
					command.timeoutMS,
					drawn,
					command.count,
				),
			)
		}
	case .WaitGone:
		drawn := ui.Automation_countText(automation, command.text)
		if drawn == 0 {
			result.waitedMS = elapsed
			uiScriptAdvance(runner, result)
		} else if elapsed >= command.timeoutMS {
			uiScriptFail(
				runner,
				result,
				fmt.tprintf(
					"timed out after %d ms: still drawn %d time(s)",
					command.timeoutMS,
					drawn,
				),
			)
		}
	case .AssertText:
		if ui.Automation_countText(automation, command.text) > 0 {
			uiScriptAdvance(runner, result)
		} else {
			uiScriptFail(runner, result, "the text is not drawn in the current frame")
		}
	case .Click, .RightClick:
		rect, found := ui.Automation_findText(automation, command.text)
		if !found {
			uiScriptFail(runner, result, "no drawn text equals TEXT in the current frame")
			return
		}
		point := uiScriptWindowPoint(ctx, rect)
		result.x, result.y = point.x, point.y
		pushOK = uiScriptPushClick(window, point, uiScriptButton(command.kind))
		pushed = true
	case .ClickID, .RightClickID:
		id := ui.idOf(command.text, ..command.ids[:command.idCount])
		rect, found := ui.Automation_findWidget(automation, id)
		if !found {
			uiScriptFail(runner, result, "no widget with that ID is on screen in the current frame")
			return
		}
		point := uiScriptWindowPoint(ctx, rect)
		result.x, result.y = point.x, point.y
		pushOK = uiScriptPushClick(window, point, uiScriptButton(command.kind))
		pushed = true
	case .ClickAt, .RightClickAt:
		result.x, result.y = command.x, command.y
		point := ui.Vec2{command.x, command.y}
		pushOK = uiScriptPushClick(window, point, uiScriptButton(command.kind))
		pushed = true
	case .Scroll:
		result.x, result.y = command.x, command.y
		pushOK = uiScriptPushWheel(window, ui.Vec2{command.x, command.y}, command.count)
		pushed = true
	case .Type:
		pushOK = uiScriptPushText(runner, window, command.text)
		pushed = true
	case .Key:
		pushOK = uiScriptPushKey(window, command.key)
		pushed = true
	case .Screenshot:
		if !runner.captureRequested {
			runner.captureRequested = true
			ui.requestCapture(ctx, command.text)
			return
		}
		status, message := ui.captureResult(ctx)
		#partial switch status {
		case .Done:
			uiScriptAdvance(runner, result)
		case .Failed:
			uiScriptFail(runner, result, fmt.tprintf("could not write the screenshot: %s", message))
		case:
			ui.requestFrame(ctx)
		}
	case .Quit:
		uiScriptAdvance(runner, result)
		runner.skipped = len(runner.commands) - runner.index
		uiScriptFinish(runner)
	}

	if pushed {
		if !pushOK {
			uiScriptFail(runner, result, "SDL could not queue the input event")
			return
		}
		uiScriptAdvance(runner, result)
		runner.settleUntilFrame = ctx.frame + UI_SCRIPT_SETTLE_FRAMES
		ui.requestFrame(ctx)
	}
}

// ── Entry point ───────────────────────────────────────────────────

// Prepares the profile like the headless harness does: --config-dir isolates it, and --name and
// --server are saved to it. A profile without a name or server is allowed: the window then
// opens the first-run screen, which a script can fill in.
@(private = "file")
uiScriptPrepareProfile :: proc(options: HeadlessOptions) -> bool {
	if len(options.configDir) > 0 && !headlessUseConfigDir(options.configDir) {
		return false
	}
	config := loadConfig()
	defer Config_deinit(&config)
	if len(config.private_key) == 0 || len(config.public_key) == 0 {
		fmt.eprintln("[Error] Could not load or create the client config and identity key")
		return false
	}
	if headlessApplyOptions(&config, options) {
		saveConfig(config)
	}
	return true
}

uiScriptMain :: proc(args: []string) -> int {
	// stdout carries only JSON lines; route the client's diagnostics to stderr.
	jsonOut := os.stdout
	os.stdout = os.stderr
	defer os.stdout = jsonOut

	options, optionsErr := uiScriptParseOptions(args)
	if len(optionsErr) > 0 {
		fmt.eprintln("[Error]", optionsErr)
		fmt.eprintln(UI_SCRIPT_USAGE)
		return UI_SCRIPT_EXIT_USAGE
	}
	source, readErr := os.read_entire_file_from_path(options.scriptPath, context.allocator)
	if readErr != nil {
		fmt.eprintln("[Error] Cannot read the script", options.scriptPath, readErr)
		return UI_SCRIPT_EXIT_USAGE
	}
	commands, errLine, parseErr := uiScriptParse(string(source))
	delete(source)
	defer uiScriptDeleteCommands(&commands)

	runner := UIScriptRunner {
		commands = commands[:],
		out      = os.to_writer(jsonOut),
	}
	defer UIScriptRunner_deinit(&runner)
	if len(parseErr) > 0 {
		// Nothing runs when any line is bad, so a typo cannot leave half a scenario done.
		uiScriptWriteJSON(
			&runner,
			UIScriptResultJSON {
				ok = false,
				cmd = "parse",
				line = errLine,
				error = parseErr,
			},
		)
		return UI_SCRIPT_EXIT_USAGE
	}
	if !uiScriptPrepareProfile(options.profile) {
		return UI_SCRIPT_EXIT_USAGE
	}
	appOptions := AppOptions {
		script       = &runner,
		windowWidth  = options.windowWidth,
		windowHeight = options.windowHeight,
	}
	if !runApp(appOptions) {
		return UI_SCRIPT_EXIT_USAGE
	}
	return runner.exitCode
}
