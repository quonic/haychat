package common

// Voice device IDs (protocol 13). Each client profile has one, generated once and kept in its
// config as `device_id`, and sends it with every ClientJoinVoice. The server keeps at most one
// voice session per account and uses the ID for one thing only: an automatic re-join after a
// reconnect may replace a voice session of the same device (a stale session the server has
// not timed out yet), but never one of another device.
//
// On the wire and in the config it is the same 32-character lowercase hex string, so the
// config value can be sent as it is, a person can read and edit it in config.json, and both
// sides check it with one parser that allocates nothing. It is not a secret, but it is
// stable per profile, so do not log it without a reason.

VOICE_DEVICE_ID_SIZE :: 16
VOICE_DEVICE_ID_HEX_LENGTH :: VOICE_DEVICE_ID_SIZE * 2

VoiceDeviceID :: [VOICE_DEVICE_ID_SIZE]u8

@(private = "file")
voiceDeviceIDHexDigit :: proc(char: u8) -> (value: u8, ok: bool) {
	switch char {
	case '0' ..= '9':
		return char - '0', true
	case 'a' ..= 'f':
		return char - 'a' + 10, true
	}
	return 0, false
}

// Parses a device ID: exactly 32 lowercase hex characters that are not all zero. All zeros is
// what a client that never set one would send, so it never counts as a device.
voiceDeviceIDFromHex :: proc(hexValue: string) -> (id: VoiceDeviceID, ok: bool) {
	if len(hexValue) != VOICE_DEVICE_ID_HEX_LENGTH {
		return {}, false
	}
	nonZero := false
	for index in 0 ..< VOICE_DEVICE_ID_SIZE {
		high, highOK := voiceDeviceIDHexDigit(hexValue[index * 2])
		low, lowOK := voiceDeviceIDHexDigit(hexValue[index * 2 + 1])
		if !highOK || !lowOK {
			return {}, false
		}
		id[index] = high << 4 | low
		nonZero ||= id[index] != 0
	}
	if !nonZero {
		return {}, false
	}
	return id, true
}

voiceDeviceIDIsValid :: proc(hexValue: string) -> bool {
	_, ok := voiceDeviceIDFromHex(hexValue)
	return ok
}

// The device ID as 32 lowercase hex characters, allocated with allocator.
voiceDeviceIDToHex :: proc(id: VoiceDeviceID, allocator := context.allocator) -> string {
	hexDigits := "0123456789abcdef"
	buffer := make([]u8, VOICE_DEVICE_ID_HEX_LENGTH, allocator)
	for value, index in id {
		buffer[index * 2] = hexDigits[value >> 4]
		buffer[index * 2 + 1] = hexDigits[value & 0x0f]
	}
	return string(buffer)
}

// A new random device ID. Fails only without a system random source; the chance of an all-zero
// result is 2^-128, but it is retried rather than handed out as an invalid ID.
generateVoiceDeviceID :: proc() -> (id: VoiceDeviceID, ok: bool) {
	for _ in 0 ..< 4 {
		if !generateRandomBytes(id[:]) {
			return {}, false
		}
		if id != (VoiceDeviceID{}) {
			return id, true
		}
	}
	return {}, false
}
