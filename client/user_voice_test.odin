#+feature dynamic-literals
package client

import "../common"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:testing"

// Per-user voice volume and local mute (issue 47): the engine's per-speaker table, the gain
// and mute on the file sink, and the State actions that store and apply them.

// The table keeps only non-default entries, clamps gains, refuses a new user when full, and
// changes an existing one in place.
@(test)
testVoiceEngineSpeakerControlTable :: proc(t: ^testing.T) {
	engine := VoiceEngine_create({sink = {kind = .Null}, unpaced = true})
	defer VoiceEngine_destroy(engine)

	gain, muted := VoiceEngine_speakerControl(engine, 5)
	assert(gain == 1 && !muted, "expected an unknown speaker at gain 1, not muted")
	assert(!VoiceEngine_setSpeakerControl(engine, 0, 0.5, false), "expected user 0 refused")
	assert(VoiceEngine_setSpeakerGain(engine, 5, 3), "expected a gain for user 5")
	gain, muted = VoiceEngine_speakerControl(engine, 5)
	assert(
		gain == VOICE_SPEAKER_GAIN_MAX && !muted,
		fmt.tprintf("expected the gain clamped to 2, got %v", gain),
	)
	assert(VoiceEngine_setSpeakerMuted(engine, 5, true), "expected user 5 muted")
	gain, muted = VoiceEngine_speakerControl(engine, 5)
	assert(gain == 2 && muted, "expected the mute to keep the gain")
	assert(VoiceEngine_setSpeakerControl(engine, 6, math.nan_f32(), true), "expected user 6")
	gain, _ = VoiceEngine_speakerControl(engine, 6)
	assert(gain == 1, fmt.tprintf("expected NaN to mean gain 1, got %v", gain))
	assert(engine.speakerControlCount == 2, "expected two entries")
	// Back to the default removes the entry and keeps the table packed.
	assert(VoiceEngine_setSpeakerControl(engine, 5, 1, false), "expected user 5 reset")
	assert(
		engine.speakerControlCount == 1 && engine.speakerControls[0].userID == 6,
		fmt.tprintf("expected only user 6 left, got %v", engine.speakerControls[:2]),
	)
	assert(VoiceEngine_setSpeakerControl(engine, 6, 1, false), "expected user 6 reset")
	assert(engine.speakerControlCount == 0, "expected an empty table")

	for userID in 1 ..= VOICE_SPEAKER_CONTROL_CAPACITY {
		assert(
			VoiceEngine_setSpeakerGain(engine, u32(userID), 0.5),
			fmt.tprintf("expected room for user %d", userID),
		)
	}
	assert(
		!VoiceEngine_setSpeakerGain(engine, VOICE_SPEAKER_CONTROL_CAPACITY + 1, 0.5),
		"expected a full table to refuse a new user",
	)
	assert(VoiceEngine_setSpeakerMuted(engine, 3, true), "expected a known user to change")
	assert(
		VoiceEngine_setSpeakerControl(engine, VOICE_SPEAKER_CONTROL_CAPACITY + 1, 1, false),
		"expected a default for an unknown user to need no slot",
	)
	_ = t
}

@(private = "file")
userVoiceTestRMSDB :: proc(samples: []f32, firstFrame, frames: int) -> f64 {
	from := firstFrame * common.VOICE_FRAME_SAMPLES
	to := from + frames * common.VOICE_FRAME_SAMPLES
	assert(to <= len(samples), fmt.tprintf("expected %d samples, got %d", to, len(samples)))
	return voiceRMSDB(samples[from:to])
}

// A loopback tone played through the file sink: at a gain of 0.5 it measures 6 dB below the
// same tone at 1 (20·log10(0.5) = −6.02 dB), at 1.5 it is 3.5 dB above, muted the sink is
// exactly silent and the frames are counted as dropped before decoding, and after unmuting
// the speaker comes back at its gain. Every change applies from the next step, as it does on
// a running engine.
@(test)
testVoiceEngineSpeakerGainAndMuteOnTheFileSink :: proc(t: ^testing.T) {
	if !voiceTestOpusAvailable(t) {
		return
	}
	dir := configTestCreateTempDir("haychat_user_voice")
	defer configTestRemovePathIfExists(dir)
	path := configTestJoinPath({dir, "out.f32"})
	engine := VoiceEngine_create(
		{
			source = {kind = .Tone, toneHz = 440, toneAmplitude = 0.5},
			sink = {kind = .File, path = path},
			gateMode = .PushToTalk,
			loopback = true,
			unpaced = true,
		},
	)
	defer VoiceEngine_destroy(engine)
	VoiceEngine_setPushToTalk(engine, true)
	assert(
		VoiceEngine_open(engine),
		fmt.tprintf("expected the engine to open: %s", VoiceEngine_lastError(engine)),
	)
	// Each phase runs PHASE frames; the windows measured skip the first SETTLE frames of a
	// phase (the codec's start-up and the jitter pre-roll in the first one).
	PHASE :: 50
	SETTLE :: 20
	speaker := VOICE_LOOPBACK_USER_ID
	for _ in 0 ..< PHASE {
		VoiceEngine_step(engine)
	}
	assert(VoiceEngine_setSpeakerGain(engine, speaker, 0.5), "expected the gain set")
	for _ in 0 ..< PHASE {
		VoiceEngine_step(engine)
	}
	snapshot := VoiceEngine_snapshot(engine)
	assert(
		snapshot.speakerCount == 1 && snapshot.speakers[0].gain == 0.5,
		fmt.tprintf("expected the speaker at gain 0.5, got %v", snapshot.speakers[0]),
	)
	assert(VoiceEngine_setSpeakerGain(engine, speaker, 1.5), "expected the gain raised")
	for _ in 0 ..< PHASE {
		VoiceEngine_step(engine)
	}
	assert(VoiceEngine_setSpeakerMuted(engine, speaker, true), "expected the speaker muted")
	for _ in 0 ..< PHASE {
		VoiceEngine_step(engine)
	}
	muted := VoiceEngine_snapshot(engine)
	assert(
		muted.speakerCount == 0 && muted.stats.inboundLocallyMuted >= PHASE - 1,
		fmt.tprintf(
			"expected no speaker and %d frames dropped while muted, got %d speakers and %d",
			PHASE - 1,
			muted.speakerCount,
			muted.stats.inboundLocallyMuted,
		),
	)
	decodedWhileMuted := muted.stats.framesDecoded
	assert(VoiceEngine_setSpeakerMuted(engine, speaker, false), "expected the speaker unmuted")
	for _ in 0 ..< PHASE {
		VoiceEngine_step(engine)
	}
	VoiceEngine_close(engine)
	after := VoiceEngine_snapshot(engine)
	assert(
		after.stats.framesDecoded > decodedWhileMuted,
		"expected decoding to resume after unmuting",
	)

	bytes, readErr := os.read_entire_file_from_path(path, context.allocator)
	defer delete(bytes)
	assert(readErr == nil, "expected the sink file to be readable")
	samples := mem.slice_data_cast([]f32, bytes[:len(bytes) / 4 * 4])
	assert(
		len(samples) == 5 * PHASE * common.VOICE_FRAME_SAMPLES,
		fmt.tprintf("expected one frame per step, got %d samples", len(samples)),
	)
	window := PHASE - SETTLE
	full := userVoiceTestRMSDB(samples, SETTLE, window)
	half := userVoiceTestRMSDB(samples, PHASE + SETTLE, window)
	loud := userVoiceTestRMSDB(samples, 2 * PHASE + SETTLE, window)
	resumed := userVoiceTestRMSDB(samples, 4 * PHASE + SETTLE, window)
	assert(full > -12, fmt.tprintf("expected the tone at gain 1, got %.2f dBFS", full))
	assert(
		math.abs(half - full - -6.02) < 0.5,
		fmt.tprintf("expected gain 0.5 at -6 dB, got %.2f dB (%.2f, %.2f)", half - full, half, full),
	)
	assert(
		math.abs(loud - full - 3.52) < 0.5,
		fmt.tprintf("expected gain 1.5 at +3.5 dB, got %.2f dB", loud - full),
	)
	// Muting releases the speaker at the start of the next step: from then on every frame is
	// written as silence.
	mutedFrom := 3 * PHASE * common.VOICE_FRAME_SAMPLES
	peak: f32
	for sample in samples[mutedFrom:mutedFrom + PHASE * common.VOICE_FRAME_SAMPLES] {
		peak = max(peak, math.abs(sample))
	}
	assert(peak == 0, fmt.tprintf("expected silence while muted, peak %v", peak))
	assert(
		math.abs(resumed - loud) < 0.5,
		fmt.tprintf("expected the tone back at gain 1.5, got %.2f vs %.2f", resumed, loud),
	)
	_ = t
}

// The State actions store a user's setting on the server's config entry and apply it to the
// running engine only when voice is on that server; a new engine gets every stored entry.
@(test)
testUserVoiceActionsStoreAndApplyLive :: proc(t: ^testing.T) {
	state := testStateWithServers(
		{
			Server{id = 851, name = "Voice", host = "voice.example", port = 1},
			Server{id = 852, name = "Other", host = "other.example", port = 1},
		},
	)
	defer State_deinit(&state)

	assert(State_setUserVoiceVolume(&state, 851, 7, 0.4), "expected a volume for user 7")
	assert(State_setUserVoiceMuted(&state, 851, 8, true), "expected a mute for user 8")
	assert(State_setUserVoiceVolume(&state, 852, 7, 1.8), "expected a volume on the other server")
	assert(!State_setUserVoiceVolume(&state, 999, 7, 0.4), "expected an unknown server refused")
	volume, muted := State_userVoice(&state, 851, 7)
	assert(volume == 0.4 && !muted, fmt.tprintf("expected 0.4 for user 7, got %v", volume))
	volume, muted = State_userVoice(&state, 851, 8)
	assert(volume == 1 && muted, "expected user 8 muted at volume 1")
	volume, _ = State_userVoice(&state, 852, 7)
	assert(volume == 1.8, "expected the other server to keep its own volume")

	// A new engine for server 851 starts with that server's entries only.
	engine := VoiceEngine_create({sink = {kind = .Null}, unpaced = true})
	defer VoiceEngine_destroy(engine)
	State_voiceApplyUserVoice(&state, engine, 851)
	gain7, muted7 := VoiceEngine_speakerControl(engine, 7)
	gain8, muted8 := VoiceEngine_speakerControl(engine, 8)
	assert(
		gain7 == 0.4 && !muted7 && gain8 == 1 && muted8 && engine.speakerControlCount == 2,
		fmt.tprintf("expected users 7 and 8 from server 851, got %v", engine.speakerControls[:2]),
	)

	// While voice runs on 851, a change there reaches the engine; one on 852 does not.
	state.voice.engine = engine
	state.voice.serverID = 851
	defer {
		// The engine is the test's, not bound to a transport: State_deinit must not stop it.
		state.voice.engine = nil
		state.voice.serverID = 0
	}
	assert(State_setUserVoiceVolume(&state, 851, 7, 1.25, persist = false), "expected 1.25")
	assert(State_setUserVoiceMuted(&state, 851, 8, false), "expected user 8 unmuted")
	assert(State_setUserVoiceVolume(&state, 852, 9, 0.1), "expected a volume on 852")
	gain7, _ = VoiceEngine_speakerControl(engine, 7)
	gain8, muted8 = VoiceEngine_speakerControl(engine, 8)
	gain9, _ := VoiceEngine_speakerControl(engine, 9)
	assert(
		gain7 == 1.25 && gain8 == 1 && !muted8 && gain9 == 1,
		fmt.tprintf("expected live changes for 851 only, got %v %v %v", gain7, gain8, gain9),
	)
	server, _ := State_serverConfig(&state, 851)
	assert(
		len(server.user_voice) == 1 && server.user_voice[0].user_id == 7,
		fmt.tprintf("expected user 8's default entry dropped, got %v", server.user_voice),
	)
	_ = t
}
