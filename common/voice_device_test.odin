package common

import "core:fmt"
import "core:testing"

@(test)
testVoiceDeviceIDParsesOnlyLowercaseHexOfTheRightLength :: proc(t: ^testing.T) {
	_ = t
	valid := "00112233445566778899aabbccddeeff"
	id, ok := voiceDeviceIDFromHex(valid)
	assert(ok, "expected 32 lowercase hex characters to parse")
	assert(
		id[0] == 0x00 && id[1] == 0x11 && id[15] == 0xff,
		fmt.tprintf("expected the bytes in order, got %v", id),
	)
	back := voiceDeviceIDToHex(id)
	defer delete(back)
	assert(back == valid, fmt.tprintf("expected %q back, got %q", valid, back))

	malformed := [?]string {
		"",
		"00112233445566778899aabbccddeef", // 31
		"00112233445566778899aabbccddeeff0", // 33
		"00112233445566778899AABBCCDDEEFF", // uppercase
		"00112233445566778899aabbccddeefg", // not hex
		"0011223344556677-899aabbccddeeff",
		"00000000000000000000000000000000", // all zero: never set
	}
	for value in malformed {
		assert(!voiceDeviceIDIsValid(value), fmt.tprintf("expected %q to be refused", value))
	}
}

@(test)
testGeneratedVoiceDeviceIDsAreValidAndDiffer :: proc(t: ^testing.T) {
	_ = t
	first, firstOK := generateVoiceDeviceID()
	second, secondOK := generateVoiceDeviceID()
	assert(firstOK && secondOK, "expected the system random source to produce device IDs")
	assert(first != second, "expected two generated device IDs to differ")
	hexValue := voiceDeviceIDToHex(first)
	defer delete(hexValue)
	assert(
		len(hexValue) == VOICE_DEVICE_ID_HEX_LENGTH && voiceDeviceIDIsValid(hexValue),
		fmt.tprintf("expected a valid 32-character ID, got %q", hexValue),
	)
}
