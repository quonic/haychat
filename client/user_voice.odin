package client

// Per-user voice volume and local mute (issue 47), per server. They live in the server's
// config entry (Server.user_voice), so they apply only on this profile and are not synced
// between devices, and reach the voice engine as per-speaker controls
// (VoiceEngine_setSpeakerControl): every entry of the voice server when an engine starts, and
// each change at once while one runs. The server never learns about them; a local mute only
// stops this client from playing that user.

// The volume (linear, 0..SERVER_USER_VOICE_VOLUME_MAX) and local mute for userID on serverID.
// 1 and false for an unknown server or user.
State_userVoice :: proc(state: ^State, serverID, userID: int) -> (volume: f32, muted: bool) {
	server, ok := State_serverConfig(state, serverID)
	if !ok {
		return 1, false
	}
	return Server_userVoice(server^, userID)
}

// Gives a new engine every user's volume and mute for serverID. Called before the engine
// starts, so the first frame already plays at the right level.
State_voiceApplyUserVoice :: proc(state: ^State, engine: ^VoiceEngine, serverID: int) {
	server, ok := State_serverConfig(state, serverID)
	if !ok || engine == nil {
		return
	}
	for entry in server.user_voice {
		_ = VoiceEngine_setSpeakerControl(
			engine,
			u32(entry.user_id),
			serverUserVoiceVolume(entry),
			entry.muted,
		)
	}
}

// Stores userID's volume and mute on serverID and applies them to the running engine when
// voice is on that server. persist saves config.json; a slider passes false while it is
// dragged and true when it is let go, so a drag writes the file once. Returns false when
// nothing was stored: an unknown server, an invalid user ID, or a full table
// (SERVER_USER_VOICE_MAX_ENTRIES).
State_setUserVoice :: proc(
	state: ^State,
	serverID, userID: int,
	volume: f32,
	muted: bool,
	persist := true,
) -> bool {
	server, ok := State_serverConfig(state, serverID)
	if !ok || !Server_setUserVoice(server, userID, volume, muted) {
		return false
	}
	if persist {
		State_saveConfig(state)
	}
	if engine := state.voice.engine; engine != nil && state.voice.serverID == serverID {
		cleanVolume, cleanMuted := Server_userVoice(server^, userID)
		_ = VoiceEngine_setSpeakerControl(engine, u32(userID), cleanVolume, cleanMuted)
	}
	return true
}

// Changes userID's volume on serverID and keeps the mute (see State_setUserVoice).
State_setUserVoiceVolume :: proc(
	state: ^State,
	serverID, userID: int,
	volume: f32,
	persist := true,
) -> bool {
	_, muted := State_userVoice(state, serverID, userID)
	return State_setUserVoice(state, serverID, userID, volume, muted, persist)
}

// Mutes or unmutes userID on serverID for this client only and keeps the volume.
State_setUserVoiceMuted :: proc(state: ^State, serverID, userID: int, muted: bool) -> bool {
	volume, _ := State_userVoice(state, serverID, userID)
	return State_setUserVoice(state, serverID, userID, volume, muted)
}
