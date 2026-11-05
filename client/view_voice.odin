package client

import "core:fmt"
import "ui"

// Voice in the window (voice-rooms-design.md 5.3): participant rows in the channel list, the
// voice bar at the bottom of the sidebar, and the Settings → Voice section. Everything shown
// comes from the view models in voice_view_model.odin; clicks call the State actions after
// drawing, because they can reallocate what was drawn.

VOICE_PARTICIPANT_INDENT :: 24
VOICE_DOT_SIZE :: 10
VOICE_METER_HEIGHT :: 6
VOICE_SETTINGS_METER_HEIGHT :: 10
VOICE_SLIDER_HEIGHT :: 22
// While audio meters move, the frame loop redraws this often (design 5.3: about 100 ms).
VOICE_REDRAW_INTERVAL_MS :: 100
VOICE_SPEAKER_ICON :: "🔊"

// A round dot; with ring set, a ring of that color around the dot's own fill.
@(private = "file")
viewVoiceDot :: proc(ctx: ^ui.Context, r: ui.Rect, fill: ui.Color, ring: Maybe(ui.Color) = nil) {
	if color, hasRing := ring.?; hasRing {
		ui.fillRoundedRect(ctx, r, r.w / 2, color)
		inner := ui.shrink(r, max(1, ui.dp(ctx, 2)))
		ui.fillRoundedRect(ctx, inner, inner.w / 2, fill)
		return
	}
	ui.fillRoundedRect(ctx, r, r.w / 2, fill)
}

// The speaker icon at the right of a Channel row with anyone in its voice. Takes its width
// from content.
viewChannelVoiceIndicator :: proc(ctx: ^ui.Context, content: ^ui.Rect, voiceUsers: int) {
	if voiceUsers <= 0 {
		return
	}
	text := fmt.tprintf("%s %d", VOICE_SPEAKER_ICON, voiceUsers)
	width := ui.textSize(ui.textGet(ctx, 0, .Regular, text)).x
	ui.label(ctx, ui.cutRight(content, width), text, ctx.theme.fgMuted)
	_ = ui.cutRight(content, ui.dp(ctx, 6))
}

// One user in a room's voice, indented under the room: a dot ringed green while they speak,
// their name, how many devices they joined from, and mute and deafen marks.
viewVoiceParticipantRow :: proc(ctx: ^ui.Context, serverID: int, row: SidebarRow, rect: ui.Rect) {
	participant := row.voice
	content := ui.shrinkXY(rect, ui.dp(ctx, ctx.theme.padding), 0)
	_ = ui.cutLeft(&content, ui.dp(ctx, VOICE_PARTICIPANT_INDENT - ctx.theme.padding))
	dotSize := ui.dp(ctx, VOICE_DOT_SIZE)
	dot := ui.Rect{content.x, content.y + (content.h - dotSize) / 2, dotSize, dotSize}
	if participant.speaking {
		viewVoiceDot(ctx, dot, ctx.theme.surface, ctx.theme.success)
	} else {
		viewVoiceDot(ctx, dot, ctx.theme.border)
	}
	_ = ui.cutLeft(&content, dotSize + ui.dp(ctx, 8))

	marks := ""
	if participant.deafened {
		marks = "deafened"
	} else if participant.muted {
		marks = "muted"
	}
	if participant.deviceCount > 1 {
		devices := fmt.tprintf("×%d", participant.deviceCount)
		marks = len(marks) > 0 ? fmt.tprintf("%s %s", devices, marks) : devices
	}
	if len(marks) > 0 {
		width := ui.textSize(ui.textGet(ctx, 0, .Regular, marks)).x
		marked := participant.muted || participant.deafened
		markColor := marked ? ctx.theme.danger : ctx.theme.fgMuted
		ui.label(ctx, ui.cutRight(&content, width), marks, markColor)
		_ = ui.cutRight(&content, ui.dp(ctx, 6))
	}
	color := participant.speaking ? ctx.theme.fg : ctx.theme.fgMuted
	ui.label(ctx, content, row.label, color, participant.isSelf ? .Bold : .Regular)

	status := participant.speaking ? "Speaking" : "In voice"
	if participant.deafened {
		status = fmt.tprintf("%s, deafened", status)
	} else if participant.muted {
		status = fmt.tprintf("%s, muted", status)
	}
	if participant.deviceCount > 1 {
		status = fmt.tprintf("%s, on %d devices", status, participant.deviceCount)
	}
	id := ui.idOf("voice-participant", serverID, row.roomID, participant.userID)
	ui.tooltip(ctx, id, rect, status)
}

// The height the voice bar takes for view at width, 0 when hidden.
@(private = "file")
voiceBarHeight :: proc(ctx: ^ui.Context, view: ^VoiceBarView, width: f32) -> f32 {
	if view.kind == .Hidden {
		return 0
	}
	padding := ui.dp(ctx, PANEL_PADDING)
	textW := width - ui.dp(ctx, VOICE_DOT_SIZE + 8)
	height := padding * 3 + ui.wrappedTextHeight(ctx, view.text, textW)
	if view.showLevel {
		height += ui.dp(ctx, VOICE_METER_HEIGHT) + padding
	}
	if len(view.note) > 0 {
		height += ui.wrappedTextHeight(ctx, view.note, width) + padding
	}
	return height + ui.dp(ctx, ROW_HEIGHT)
}

// The voice bar at the bottom of the sidebar, shown while voice is active, on its way, or
// reporting a problem.
viewVoiceBar :: proc(state: ^State, ctx: ^ui.Context, area: ^ui.Rect) {
	view := buildVoiceBarView(state)
	inner := ui.dp(ctx, 16)
	height := voiceBarHeight(ctx, &view, area.w - inner * 2)
	if height <= 0 {
		return
	}
	bar := ui.cutBottom(area, height)
	ui.fillRect(ctx, bar, ctx.theme.elevated)
	ui.divider(ctx, ui.Rect{bar.x, bar.y, bar.w, 1})
	padding := ui.dp(ctx, PANEL_PADDING)
	content := ui.shrinkXY(bar, inner, 0)
	_ = ui.cutTop(&content, padding * 1.5)

	// Status line: a dot that is green while you speak, then the text.
	textColor := view.isError ? ctx.theme.danger : ctx.theme.fg
	dotSize := ui.dp(ctx, VOICE_DOT_SIZE)
	textW := content.w - dotSize - ui.dp(ctx, 8)
	textH := ui.wrappedTextHeight(ctx, view.text, textW)
	line := ui.cutTop(&content, textH)
	dot := ui.Rect{line.x, line.y + (ui.lineHeight(ctx) - dotSize) / 2, dotSize, dotSize}
	dotColor := ctx.theme.warning
	switch view.kind {
	case .Joined:
		dotColor = view.speaking ? ctx.theme.success : ctx.theme.border
	case .Unavailable, .Notice:
		dotColor = ctx.theme.danger
	case .Joining, .Rejoining, .Hidden:
	}
	if view.kind == .Joined && view.speaking {
		viewVoiceDot(ctx, dot, ctx.theme.elevated, ctx.theme.success)
	} else {
		viewVoiceDot(ctx, dot, dotColor)
	}
	_ = ui.cutLeft(&line, dotSize + ui.dp(ctx, 8))
	ui.wrappedLabel(ctx, line, view.text, textColor)
	_ = ui.cutTop(&content, padding)

	if view.showLevel {
		meter := ui.cutTop(&content, ui.dp(ctx, VOICE_METER_HEIGHT))
		fraction := ui.rangeFraction(view.levelDB, VOICE_METER_FLOOR_DB, VOICE_METER_CEILING_DB)
		meterColor := view.speaking ? ctx.theme.success : ctx.theme.fgMuted
		ui.levelMeter(ctx, meter, fraction, {color = meterColor})
		_ = ui.cutTop(&content, padding)
	}
	if len(view.note) > 0 {
		noteH := ui.wrappedTextHeight(ctx, view.note, content.w)
		ui.wrappedLabel(ctx, ui.cutTop(&content, noteH), view.note, ctx.theme.fgMuted)
		_ = ui.cutTop(&content, padding)
	}

	buttons := ui.cutTop(&content, ui.dp(ctx, ROW_HEIGHT))
	gap := ui.dp(ctx, 4)
	muteClicked, deafenClicked, leaveClicked, dismissClicked := false, false, false, false
	if view.showControls {
		buttonW := (buttons.w - gap * 2) / 3
		muteOptions := ui.ButtonOptions {
			align      = .Center,
			selected   = view.muted,
			background = view.muted ? ctx.theme.selected : ctx.theme.hover,
			color      = view.muted ? ctx.theme.danger : ctx.theme.fg,
		}
		muteText := view.muted ? "Unmute" : "Mute"
		muteClicked = ui.button(
			ctx,
			ui.idOf("voice-mute"),
			ui.cutLeft(&buttons, buttonW),
			muteText,
			muteOptions,
		)
		_ = ui.cutLeft(&buttons, gap)
		deafenOptions := muteOptions
		deafenOptions.selected = view.deafened
		deafenOptions.background = view.deafened ? ctx.theme.selected : ctx.theme.hover
		deafenOptions.color = view.deafened ? ctx.theme.danger : ctx.theme.fg
		deafenText := view.deafened ? "Undeafen" : "Deafen"
		deafenClicked = ui.button(
			ctx,
			ui.idOf("voice-deafen"),
			ui.cutLeft(&buttons, buttonW),
			deafenText,
			deafenOptions,
		)
		_ = ui.cutLeft(&buttons, gap)
		leaveOptions := ui.ButtonOptions {
			align      = .Center,
			color      = ctx.theme.onPrimary,
			background = ctx.theme.danger,
		}
		leaveClicked = ui.button(ctx, ui.idOf("voice-leave"), buttons, "Leave", leaveOptions)
	} else {
		dismissOptions := ui.ButtonOptions {
			align      = .Center,
			background = ctx.theme.hover,
		}
		dismissClicked = ui.button(
			ctx,
			ui.idOf("voice-dismiss"),
			ui.cutLeft(&buttons, ui.dp(ctx, 96)),
			"Dismiss",
			dismissOptions,
		)
	}

	switch {
	case muteClicked:
		State_setVoiceMuted(state, !state.voice.muted)
	case deafenClicked:
		State_setVoiceDeafened(state, !state.voice.deafened)
	case leaveClicked, dismissClicked:
		// Dismiss uses the same action: it clears the error, and there is nothing to leave.
		State_leaveVoice(state)
	}
}

// ── Settings → Voice ──────────────────────────────────────────────

@(private = "file")
voiceSettingsLabel :: proc(ctx: ^ui.Context, column: ^ui.Rect, text: string, value := "") {
	row := ui.cutTop(column, ui.lineHeight(ctx))
	if len(value) > 0 {
		ui.label(ctx, row, value, ctx.theme.fg, align = .Right)
	}
	ui.label(ctx, row, text, ctx.theme.fgMuted, .Bold)
	_ = ui.cutTop(column, ui.dp(ctx, SETTINGS_LABEL_GAP))
}

@(private = "file")
voiceSettingsWrapped :: proc(ctx: ^ui.Context, column: ^ui.Rect, text: string, color: ui.Color) {
	if len(text) == 0 {
		return
	}
	height := ui.wrappedTextHeight(ctx, text, column.w)
	ui.wrappedLabel(ctx, ui.cutTop(column, height), text, color)
	_ = ui.cutTop(column, ui.dp(ctx, SETTINGS_LABEL_GAP))
}

// A list of devices as selectable rows. Returns the index clicked, or -1.
@(private = "file")
voiceSettingsDeviceList :: proc(
	ctx: ^ui.Context,
	column: ^ui.Rect,
	idName: string,
	options: []VoiceDeviceOption,
) -> int {
	clicked := -1
	for option, index in options {
		row := ui.cutTop(column, ui.dp(ctx, ROW_HEIGHT))
		buttonOptions := ui.ButtonOptions {
			selected = option.selected,
			color    = option.selected ? ctx.theme.fg : ctx.theme.fgMuted,
		}
		if ui.button(ctx, ui.idOf(idName, index), row, option.label, buttonOptions) {
			clicked = index
		}
		_ = ui.cutTop(column, ui.dp(ctx, ROW_SPACING))
	}
	return clicked
}

// A labelled slider. Returns its result; the caller applies the value.
@(private = "file")
voiceSettingsSlider :: proc(
	ctx: ^ui.Context,
	column: ^ui.Rect,
	id: ui.ID,
	label, valueText: string,
	value, low, high, step: f32,
) -> ui.SliderResult {
	voiceSettingsLabel(ctx, column, label, valueText)
	track := ui.cutTop(column, ui.dp(ctx, VOICE_SLIDER_HEIGHT))
	result := ui.slider(ctx, id, track, value, low, high, step)
	_ = ui.cutTop(column, ui.dp(ctx, SETTINGS_SECTION_GAP) * 0.75)
	return result
}

// The Voice section of the settings screen, in column. It scrolls, because the device lists
// can be long.
viewVoiceSettings :: proc(state: ^State, ctx: ^ui.Context, area: ui.Rect) {
	panel := &state.voicePanel
	// A captured key arrives as an ordinary key press, before anything is drawn.
	if panel.capturingKey {
		for event in ctx.input.events {
			if press, isKey := event.(ui.KeyPress); isKey && !press.repeat {
				State_captureVoicePushToTalkKey(state, press.key)
				break
			}
		}
	}
	view := buildVoiceSettingsView(state)
	settings := view.settings
	sectionGap := ui.dp(ctx, SETTINGS_SECTION_GAP)
	gap := ui.dp(ctx, PANEL_PADDING)

	scrollID := ui.idOf("settings-voice")
	offset := ui.scrollBegin(ctx, scrollID, area, panel.contentH)
	column := ui.Rect{area.x, area.y - offset, area.w - ui.dp(ctx, 12), max(f32(1e6), area.h)}
	top := column.y

	voiceSettingsWrapped(ctx, &column, VOICE_ECHO_NOTICE, ctx.theme.fgMuted)
	_ = ui.cutTop(&column, sectionGap)

	voiceSettingsLabel(ctx, &column, "Input device")
	voiceSettingsWrapped(ctx, &column, view.devicesNote, ctx.theme.warning)
	inputClicked := voiceSettingsDeviceList(ctx, &column, "voice-input-device", view.inputOptions)
	_ = ui.cutTop(&column, sectionGap)
	voiceSettingsLabel(ctx, &column, "Output device")
	outputClicked := voiceSettingsDeviceList(
		ctx,
		&column,
		"voice-output-device",
		view.outputOptions,
	)
	_ = ui.cutTop(&column, sectionGap)

	voiceSettingsLabel(ctx, &column, "Mode")
	modeRow := ui.cutTop(&column, ui.dp(ctx, ROW_HEIGHT))
	modeW := (modeRow.w - gap) / 2
	vadOptions := ui.ButtonOptions {
		align    = .Center,
		selected = settings.mode == .VoiceActivity,
		color    = settings.mode == .VoiceActivity ? ctx.theme.fg : ctx.theme.fgMuted,
	}
	vadClicked := ui.button(
		ctx,
		ui.idOf("voice-mode-vad"),
		ui.cutLeft(&modeRow, modeW),
		"Voice activity",
		vadOptions,
	)
	_ = ui.cutLeft(&modeRow, gap)
	pttOptions := vadOptions
	pttOptions.selected = settings.mode == .PushToTalk
	pttOptions.color = settings.mode == .PushToTalk ? ctx.theme.fg : ctx.theme.fgMuted
	pttClicked := ui.button(ctx, ui.idOf("voice-mode-ptt"), modeRow, "Push-to-talk", pttOptions)
	_ = ui.cutTop(&column, sectionGap)

	keyClicked := false
	if settings.mode == .PushToTalk {
		voiceSettingsLabel(ctx, &column, "Push-to-talk key")
		keyRow := ui.cutTop(&column, ui.dp(ctx, ROW_HEIGHT))
		keyOptions := ui.ButtonOptions {
			selected   = view.capturingKey,
			background = ctx.theme.hover,
			font       = .Bold,
		}
		keyText := view.pttKeyLabel
		if !view.capturingKey {
			keyText = fmt.tprintf("%s  (change)", view.pttKeyLabel)
		}
		keyClicked = ui.button(ctx, ui.idOf("voice-ptt-key"), keyRow, keyText, keyOptions)
		_ = ui.cutTop(&column, ui.dp(ctx, SETTINGS_LABEL_GAP))
		voiceSettingsWrapped(ctx, &column, view.pttNotice, ctx.theme.fgMuted)
		_ = ui.cutTop(&column, sectionGap)
	}

	// The live input level, with the gate threshold marked on it in voice activity mode.
	voiceSettingsLabel(ctx, &column, "Input level")
	meter := ui.cutTop(&column, ui.dp(ctx, VOICE_SETTINGS_METER_HEIGHT))
	marker: Maybe(f32)
	if settings.mode == .VoiceActivity {
		marker = ui.rangeFraction(
			settings.vadThresholdDB,
			VOICE_METER_FLOOR_DB,
			VOICE_METER_CEILING_DB,
		)
	}
	meterColor := view.transmitting ? ctx.theme.success : ctx.theme.fgMuted
	ui.levelMeter(
		ctx,
		meter,
		ui.rangeFraction(view.levelDB, VOICE_METER_FLOOR_DB, VOICE_METER_CEILING_DB),
		{color = meterColor, markerFraction = marker},
	)
	_ = ui.cutTop(&column, ui.dp(ctx, SETTINGS_LABEL_GAP))
	voiceSettingsWrapped(ctx, &column, view.meterNote, ctx.theme.fgMuted)
	testRow := ui.cutTop(&column, ui.dp(ctx, ROW_HEIGHT))
	testOptions := ui.ButtonOptions {
		align      = .Center,
		font       = .Bold,
		color      = view.testEnabled ? ctx.theme.onPrimary : ctx.theme.fgMuted,
		background = view.testEnabled ? ctx.theme.primary : ctx.theme.hover,
	}
	testClicked := ui.button(
		ctx,
		ui.idOf("voice-test"),
		ui.cutLeft(&testRow, ui.dp(ctx, 160)),
		view.testButtonText,
		testOptions,
	)
	testClicked &&= view.testEnabled
	_ = ui.cutTop(&column, ui.dp(ctx, SETTINGS_LABEL_GAP))
	voiceSettingsWrapped(ctx, &column, view.testError, ctx.theme.danger)
	_ = ui.cutTop(&column, sectionGap)

	threshold := voiceSettingsSlider(
		ctx,
		&column,
		ui.idOf("voice-threshold"),
		"Voice activity threshold",
		view.thresholdText,
		settings.vadThresholdDB,
		VOICE_VAD_THRESHOLD_MIN_DB,
		VOICE_VAD_THRESHOLD_MAX_DB,
		1,
	)
	gain := voiceSettingsSlider(
		ctx,
		&column,
		ui.idOf("voice-input-gain"),
		"Input gain",
		view.inputGainText,
		settings.inputGain,
		0,
		VOICE_INPUT_GAIN_MAX,
		0.05,
	)
	volume := voiceSettingsSlider(
		ctx,
		&column,
		ui.idOf("voice-output-volume"),
		"Output volume",
		view.outputVolumeText,
		settings.outputVolume,
		0,
		VOICE_OUTPUT_VOLUME_MAX,
		0.05,
	)
	bitrate := voiceSettingsSlider(
		ctx,
		&column,
		ui.idOf("voice-bitrate"),
		"Bitrate",
		view.bitrateText,
		f32(settings.bitrate),
		VOICE_BITRATE_MIN,
		VOICE_BITRATE_MAX,
		1000,
	)

	doneOptions := ui.ButtonOptions {
		align      = .Center,
		background = ctx.theme.hover,
	}
	doneRow := ui.cutTop(&column, ui.dp(ctx, ROW_HEIGHT + 4))
	doneClicked := ui.button(
		ctx,
		ui.idOf("settings-voice-done"),
		ui.cutLeft(&doneRow, ui.dp(ctx, 120)),
		"Done",
		doneOptions,
	)
	contentH := column.y + sectionGap - top
	ui.scrollEnd(ctx, scrollID, area)
	if contentH != panel.contentH {
		panel.contentH = contentH
		ui.requestFrame(ctx)
	}

	// Actions last: they replace the config strings and device lists drawn above.
	next := settings
	changed, persist := false, true
	switch {
	case inputClicked >= 0:
		next.inputDevice = view.inputOptions[inputClicked].name
		changed = true
	case outputClicked >= 0:
		next.outputDevice = view.outputOptions[outputClicked].name
		changed = true
	case vadClicked:
		next.mode = .VoiceActivity
		changed = next.mode != settings.mode
	case pttClicked:
		next.mode = .PushToTalk
		changed = next.mode != settings.mode
	}
	for result, index in ([4]ui.SliderResult{threshold, gain, volume, bitrate}) {
		if !result.changed && !result.released {
			continue
		}
		switch index {
		case 0:
			next.vadThresholdDB = result.value
		case 1:
			next.inputGain = result.value
		case 2:
			next.outputVolume = result.value
		case 3:
			next.bitrate = int(result.value + 0.5)
		}
		changed = true
		// Saved once, when the slider is let go, not on every frame of a drag.
		persist = result.released
	}
	if changed {
		State_applyVoiceSettings(state, next, persist)
	}
	switch {
	case keyClicked:
		State_setVoiceKeyCapture(state, !panel.capturingKey)
	case testClicked:
		if panel.testEngine != nil {
			State_stopVoiceTest(state)
		} else {
			State_startVoiceTest(state)
		}
	case doneClicked:
		State_closeSettings(state)
	}
}
