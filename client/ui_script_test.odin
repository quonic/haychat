package client

import "core:strings"
import "core:testing"
import "ui"
import SDL "vendor:sdl3"

@(test)
testUIScriptTokenizerHandlesQuotesEscapesAndComments :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	tokens, err := uiScriptTokenize(`click "# general"   # the channel, not a comment`)
	assert(err == "", "expected a valid line")
	assert(len(tokens) == 2, "expected the command and one quoted argument")
	assert(tokens[1].text == "# general" && tokens[1].quoted, "expected # kept inside quotes")

	tokens, err = uiScriptTokenize(`type "say \"hi\"\tthen\\go\n"`)
	assert(err == "", "expected escapes to parse")
	assert(tokens[1].text == "say \"hi\"\tthen\\go\n", "expected escapes resolved")

	tokens, err = uiScriptTokenize("  # only a comment")
	assert(err == "" && len(tokens) == 0, "expected a comment line to have no tokens")
	tokens, err = uiScriptTokenize(`type ""`)
	assert(err == "" && len(tokens) == 2 && tokens[1].text == "", "expected an empty string")

	_, err = uiScriptTokenize(`type "unterminated`)
	assert(err == "unterminated quoted string", "expected an unterminated quote rejected")
	_, err = uiScriptTokenize(`type "bad \q escape"`)
	assert(len(err) > 0, "expected an unknown escape rejected")
	_, err = uiScriptTokenize(`type "glued"word`)
	assert(err == "a closing quote must end a word", "expected text after a quote rejected")
	_, err = uiScriptTokenize(`type mid"quote"`)
	assert(err == "a quote must start a word", "expected a quote inside a word rejected")
}

@(test)
testUIScriptParsesEveryCommand :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := strings.join(
		{
			"# a scenario",
			"",
			"wait 250",
			`wait-text "# general"`,
			`wait-text "Loading" 1500`,
			`wait-count 2 bob 9000`,
			`click "# general"`,
			"click 120 48.5",
			"click-id dm-input 1 7",
			`type "hello there"`,
			"key Shift+Return",
			"screenshot shots/01-general.BMP",
			`assert-text "hello there"`,
			"quit # done",
		},
		"\n",
		context.temp_allocator,
	)
	commands, errLine, err := uiScriptParse(source)
	defer uiScriptDeleteCommands(&commands)
	assert(err == "" && errLine == 0, "expected the script to parse")
	assert(len(commands) == 12, "expected comments and blank lines skipped")

	assert(commands[0].kind == .Wait && commands[0].timeoutMS == 250, "expected wait 250")
	assert(commands[0].line == 3, "expected 1-based line numbers counting skipped lines")
	assert(commands[1].kind == .WaitText && commands[1].text == "# general", "expected wait-text")
	assert(commands[1].timeoutMS == UI_SCRIPT_DEFAULT_TIMEOUT_MS, "expected the default timeout")
	assert(commands[2].timeoutMS == 1500, "expected an explicit wait-text timeout")
	assert(commands[3].kind == .WaitCount && commands[3].count == 2, "expected wait-count 2")
	assert(commands[3].text == "bob" && commands[3].timeoutMS == 9000, "expected bare text")
	assert(commands[4].kind == .Click && commands[4].text == "# general", "expected click text")
	assert(commands[5].kind == .ClickAt, "expected two numbers to click coordinates")
	assert(commands[5].x == 120 && commands[5].y == 48.5, "expected the coordinates")
	assert(commands[6].kind == .ClickID && commands[6].text == "dm-input", "expected click-id")
	assert(commands[6].idCount == 2 && commands[6].ids[1] == 7, "expected click-id integers")
	assert(commands[7].kind == .Type && commands[7].text == "hello there", "expected type")
	assert(commands[8].kind == .Key && commands[8].key.key == SDL.K_RETURN, "expected Return")
	assert(commands[8].key.mod == SDL.KMOD_LSHIFT, "expected Shift held")
	assert(commands[9].kind == .Screenshot, "expected a .BMP name accepted in any case")
	assert(commands[10].kind == .AssertText, "expected assert-text")
	assert(commands[11].kind == .Quit, "expected quit with a trailing comment")
}

@(test)
testUIScriptRejectsBadLinesWithTheirLineNumber :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	BadLine :: struct {
		line:  string,
		error: string,
	}
	cases := []BadLine {
		{"jump 3", "unknown command"},
		{`"click" here`, "a line must start with a command name"},
		{"wait", "usage: wait MS (at most 600000)"},
		{"wait soon", "usage: wait MS (at most 600000)"},
		{"wait 600001", "usage: wait MS (at most 600000)"},
		{`wait-text`, `usage: wait-text "TEXT" [TIMEOUT_MS]`},
		{`wait-text "a" "5"`, `usage: wait-text "TEXT" [TIMEOUT_MS]`},
		{`wait-text "a" 5 6`, `usage: wait-text "TEXT" [TIMEOUT_MS]`},
		{`wait-count 0 "a"`, `usage: wait-count N "TEXT" [TIMEOUT_MS] (N from 1 to 1000)`},
		{`assert-text "a" 100`, `usage: assert-text "TEXT"`},
		{"click", `usage: click "TEXT" or click X Y`},
		{"click 1 2 3", `usage: click "TEXT" or click X Y`},
		{`click "1" 2`, `usage: click "TEXT" or click X Y`},
		{"click -5 2", `usage: click "TEXT" or click X Y`},
		{"click-id", "usage: click-id NAME [INTEGER...] (at most 4 integers)"},
		{"click-id a x", "usage: click-id NAME [INTEGER...] (at most 4 integers)"},
		{"click-id a 1 2 3 4 5", "usage: click-id NAME [INTEGER...] (at most 4 integers)"},
		{`type ""`, `usage: type "TEXT"`},
		{`type "a" "b"`, `usage: type "TEXT"`},
		{"key Hyper+Return", "usage: key [Shift+|Ctrl+|Alt+|Gui+]NAME (see the key table)"},
		{"key F13", "usage: key [Shift+|Ctrl+|Alt+|Gui+]NAME (see the key table)"},
		{"screenshot shot.png", "usage: screenshot FILE.bmp (screenshots are written as BMP)"},
		{"quit now", "usage: quit"},
	}
	for bad in cases {
		source := strings.concatenate({"wait 1\n# comment\n", bad.line}, context.temp_allocator)
		commands, errLine, err := uiScriptParse(source)
		assert(commands == nil, "expected no commands from a script with a bad line")
		testing.expectf(t, err == bad.error, "%q: expected %q, got %q", bad.line, bad.error, err)
		testing.expectf(t, errLine == 3, "%q: expected line 3, got %d", bad.line, errLine)
	}
}

@(test)
testUIScriptKeyTableMapsNamesAndModifiers :: proc(t: ^testing.T) {
	key, ok := uiScriptParseKey("Return")
	assert(ok && key.scancode == .RETURN && key.key == SDL.K_RETURN, "expected Return")
	assert(key.mod == {}, "expected no modifiers on a bare key")
	key, ok = uiScriptParseKey("escape")
	assert(ok && key.key == SDL.K_ESCAPE, "expected key names to ignore case")
	key, ok = uiScriptParseKey("ctrl+shift+a")
	assert(ok && key.key == SDL.K_A, "expected the key after modifiers")
	assert(key.mod == SDL.KMOD_LCTRL + SDL.KMOD_LSHIFT, "expected both modifiers")
	assert(ui.keyHasCtrl(key.mod) || ODIN_OS == .Darwin, "expected the ui to read Ctrl")
	assert(ui.keyHasShift(key.mod), "expected the ui to read Shift")

	for entry in UI_SCRIPT_KEYS {
		parsed, parsedOK := uiScriptParseKey(entry.name)
		testing.expectf(t, parsedOK && parsed.key == entry.key, "expected %s to parse", entry.name)
		// The scancode and keycode of one row must name the same key on a US layout.
		testing.expectf(
			t,
			SDL.Keycode(SDL.SCANCODE_TO_KEYCODE(entry.scancode)) == entry.key ||
			entry.key < 0x80,
			"expected %s scancode and keycode to agree",
			entry.name,
		)
	}

	_, ok = uiScriptParseKey("Shift+")
	assert(!ok, "expected a modifier without a key rejected")
	_, ok = uiScriptParseKey("Shift")
	assert(!ok, "expected a lone modifier rejected")
	_, ok = uiScriptParseKey("Meta+Return")
	assert(!ok, "expected an unknown modifier rejected")
}

@(test)
testUIScriptOptionsShareTheHeadlessParser :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	options, err := uiScriptParseOptions(
		{
			"--ui-script",
			"smoke.uis",
			"--name=alice",
			"--server",
			"127.0.0.1:12345",
			"--config-dir",
			"/tmp/p",
			"--window=1024x640",
		},
	)
	assert(err == "", "expected the options to parse")
	assert(options.scriptPath == "smoke.uis", "expected the script path")
	assert(options.profile.name == "alice", "expected --name through the headless parser")
	assert(options.profile.hasServer && options.profile.serverPort == 12345, "expected --server")
	assert(options.profile.configDir == "/tmp/p", "expected --config-dir")
	assert(options.windowWidth == 1024 && options.windowHeight == 640, "expected --window")

	options, err = uiScriptParseOptions({"--ui-script=s.uis"})
	assert(err == "", "expected the script flag alone to be enough")
	assert(options.windowWidth == WINDOW_DEFAULT_WIDTH, "expected the default window width")

	_, err = uiScriptParseOptions({"--name", "alice"})
	assert(err == "--ui-script needs a script file", "expected a missing script rejected")
	_, err = uiScriptParseOptions({"--ui-script", "s", "--window", "640x480"})
	assert(len(err) > 0, "expected a window below the minimum size rejected")
	_, err = uiScriptParseOptions({"--ui-script", "s", "--window", "wide"})
	assert(len(err) > 0, "expected a malformed window size rejected")
	_, err = uiScriptParseOptions({"--ui-script", "s", "--name", "al"})
	assert(err == "--name must be between 3 and 32 bytes", "expected headless validation")
	_, err = uiScriptParseOptions({"--ui-script", "s", "--connect-timeout", "5"})
	assert(len(err) > 0, "expected headless-only options rejected")
	_, err = uiScriptParseOptions({"--ui-script", "s", "--bogus"})
	assert(err == "unknown argument", "expected unknown arguments rejected")
	assert(uiScriptRequested({"--name", "a", "--ui-script=x"}), "expected the = form detected")
	assert(!uiScriptRequested({"--headless"}), "expected no script mode without the flag")
}
