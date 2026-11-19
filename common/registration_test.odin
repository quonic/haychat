package common

import "core:encoding/cbor"
import "core:fmt"
import "core:strings"
import "core:testing"

// Protocol 25: the registration enums are numbers on the wire and in the database.
@(test)
testRegistrationEnumWireValuesArePinned :: proc(t: ^testing.T) {
	_ = t
	assert(
		int(RegistrationMode.Open) == 1 &&
		int(RegistrationMode.InviteOnly) == 2 &&
		int(RegistrationMode.InviteApproval) == 3,
		"expected RegistrationMode to stay Open 1, InviteOnly 2, InviteApproval 3",
	)
	assert(
		int(RegistrationRequestStatus.None) == 0 &&
		int(RegistrationRequestStatus.Pending) == 1 &&
		int(RegistrationRequestStatus.Approved) == 2 &&
		int(RegistrationRequestStatus.Declined) == 3,
		"expected RegistrationRequestStatus to stay None 0, Pending 1, Approved 2, Declined 3",
	)
	assert(
		int(RegisterStatus.Created) == 0 &&
		int(RegisterStatus.Pending) == 1 &&
		int(RegisterStatus.Refused) == 2 &&
		int(RegisterStatus.Declined) == 3,
		"expected RegisterStatus to stay Created 0, Pending 1, Refused 2, Declined 3",
	)
	assert(
		int(AdminAction.RevokeInvite) == 7 &&
		int(AdminAction.SetRegistrationMode) == 8 &&
		int(AdminAction.DecideRegistration) == 9 &&
		int(AdminAction.SetRestricted) == 10,
		"expected the protocol 25 AdminAction values 7..10",
	)
}

@(test)
testInviteCodeFormatsAndParsesBack :: proc(t: ^testing.T) {
	_ = t
	code: InviteCodeBytes
	for index in 0 ..< INVITE_CODE_BYTES {
		code[index] = u8(index * 13 + 7)
	}
	text := formatInviteCode(code)
	defer delete(text)
	assert(
		len(text) == INVITE_CODE_SYMBOLS + INVITE_CODE_SYMBOLS / INVITE_CODE_GROUP - 1,
		fmt.tprintf("expected 8 groups of 4 symbols, got %q", text),
	)
	assert(strings.count(text, "-") == 7, fmt.tprintf("expected 7 dashes in %q", text))
	parsed, ok := parseInviteCode(text)
	assert(ok && parsed == code, "expected the formatted code to parse back")

	// People retype codes: lower case, no dashes, spaces, and O, I, L for 0, 1, 1.
	lower := strings.to_lower(text)
	defer delete(lower)
	plain, _ := strings.remove_all(lower, "-")
	defer delete(plain)
	spaced := strings.concatenate({" ", plain[:10], " ", plain[10:], "\t"})
	defer delete(spaced)
	again, againOK := parseInviteCode(spaced)
	assert(againOK && again == code, "expected lower case with spaces to parse")

	zeros: InviteCodeBytes
	zeroText := formatInviteCode(zeros)
	defer delete(zeroText)
	assert(
		strings.has_prefix(zeroText, "0000-"),
		fmt.tprintf("expected an all-zero code to be zeros, got %q", zeroText),
	)
	confusable, _ := strings.replace_all(zeroText, "0", "o")
	defer delete(confusable)
	read, readOK := parseInviteCode(confusable)
	assert(readOK && read == zeros, "expected O to read as 0")
	ones := "1111-1111-1111-1111-1111-1111-1111-1111"
	viaI, viaIOK := parseInviteCode("iiii-IIII-llll-LLLL-1111-1111-1111-1111")
	direct, _ := parseInviteCode(ones)
	assert(viaIOK && viaI == direct, "expected I and L to read as 1")
}

@(test)
testInviteCodeParseRefusesMalformedText :: proc(t: ^testing.T) {
	_ = t
	cases := [?]string {
		"",
		"ABCD",
		"0000-0000-0000-0000-0000-0000-0000-000", // one symbol short
		"0000-0000-0000-0000-0000-0000-0000-00000", // one symbol long
		"0000-0000-0000-0000-0000-0000-0000-000U", // U is not Crockford
		"0000-0000-0000-0000-0000-0000-0000-000!",
		"0000-0000-0000-0000-0000-0000-0000-000é",
		"0000 0000 0000 0000 0000 0000 0000 0000 - - - - - - - - - - - - - - - - - - - - - -",
	}
	for text in cases {
		_, ok := parseInviteCode(text)
		assert(!ok, fmt.tprintf("expected %q to be refused", text))
	}
}

@(test)
testInviteCodeHashIsSha256OfTheBytes :: proc(t: ^testing.T) {
	_ = t
	zeros: InviteCodeBytes
	hash := inviteCodeHash(zeros)
	hex := encodeBytesToHex(hash[:])
	defer delete(hex)
	// sha256 of 20 zero bytes.
	assert(
		hex == "de47c9b27eb8d300dbb5f2c353e632c393262cf06340c4fa7f1b40c4cbd36f90",
		fmt.tprintf("expected sha256 of 20 zero bytes, got %s", hex),
	)
	other: InviteCodeBytes
	other[0] = 1
	otherHash := inviteCodeHash(other)
	assert(otherHash != hash, "expected different codes to hash differently")
}

@(test)
testRegistrationTextValidation :: proc(t: ^testing.T) {
	_ = t
	assert(registrationTextIsValid("", 0, 500), "expected an empty optional reason")
	assert(!registrationTextIsValid("", 1, 500), "expected a required reason to need text")
	assert(registrationTextIsValid("I know alice\nfrom work", 1, 500), "expected newlines")
	assert(!registrationTextIsValid("bell\x07", 0, 500), "expected control characters refused")
	long := strings.repeat("é", 500)
	defer delete(long)
	assert(registrationTextIsValid(long, 1, 500), "expected 500 characters to be allowed")
	longer := strings.repeat("é", 501)
	defer delete(longer)
	assert(!registrationTextIsValid(longer, 1, 500), "expected 501 characters refused")
}

@(test)
testInviteCreateRequestShape :: proc(t: ^testing.T) {
	_ = t
	ok := ClientCreateInvitePayload {
		note             = "for bob",
		expiresInSeconds = 3600,
		maxUses          = 1,
	}
	assert(inviteCreateRequestIsValid(ok), "expected a plain code to be valid")
	bad := ok
	bad.expiresInSeconds = -1
	assert(!inviteCreateRequestIsValid(bad), "expected a negative expiry refused")
	bad = ok
	bad.expiresInSeconds = INVITE_EXPIRY_MAX_SECONDS + 1
	assert(!inviteCreateRequestIsValid(bad), "expected an expiry past a year refused")
	bad = ok
	bad.maxUses = INVITE_MAX_USES + 1
	assert(!inviteCreateRequestIsValid(bad), "expected too many uses refused")
	note := strings.repeat("x", INVITE_NOTE_MAX_BYTES + 1)
	defer delete(note)
	bad = ok
	bad.note = note
	assert(!inviteCreateRequestIsValid(bad), "expected a long note refused")
	roles := make([dynamic]int)
	defer delete(roles)
	append(&roles, 2, 2)
	bad = ok
	bad.roleIds = roles
	assert(!inviteCreateRequestIsValid(bad), "expected duplicate roles refused")
}

@(test)
testRegistrationPayloadsRoundTrip :: proc(t: ^testing.T) {
	_ = t
	auth := ServerAuthSuccessPayload {
		userId           = 9,
		message          = "ok",
		nickname         = "carol",
		permissions      = {.CreateInvites},
		registrationMode = .InviteApproval,
		isRestricted     = true,
	}
	encoded, err := cbor.marshal(
		ServerRegisterResponsePayload{status = .Created, message = "ok", auth = auth},
	)
	assert(err == nil, "expected ServerRegisterResponsePayload to encode")
	defer delete(encoded)
	decoded: ServerRegisterResponsePayload
	assert(cbor.unmarshal(encoded, &decoded) == nil, "expected it to decode")
	defer ServerRegisterResponsePayload_deinit(&decoded)
	assert(
		decoded.status == .Created &&
		decoded.auth.userId == 9 &&
		decoded.auth.nickname == "carol" &&
		decoded.auth.registrationMode == .InviteApproval &&
		decoded.auth.isRestricted &&
		.CreateInvites in decoded.auth.permissions,
		"expected the Created answer to carry the sign-in fields",
	)

	required, requiredErr := cbor.marshal(
		ServerRegistrationRequiredPayload {
			mode = .InviteOnly,
			status = .Declined,
			message = "Your sign-up request was declined: no",
		},
	)
	assert(requiredErr == nil, "expected ServerRegistrationRequiredPayload to encode")
	defer delete(required)
	decodedRequired: ServerRegistrationRequiredPayload
	assert(cbor.unmarshal(required, &decodedRequired) == nil, "expected it to decode")
	defer ServerRegistrationRequiredPayload_deinit(&decodedRequired)
	assert(
		decodedRequired.mode == .InviteOnly && decodedRequired.status == .Declined,
		"expected the mode and status to round trip",
	)

	authRequest, authErr := cbor.marshal(ClientAuthRequestPayload{registering = true})
	assert(authErr == nil, "expected ClientAuthRequestPayload to encode")
	defer delete(authRequest)
	decodedAuth: ClientAuthRequestPayload
	assert(cbor.unmarshal(authRequest, &decodedAuth) == nil, "expected it to decode")
	assert(decodedAuth.registering, "expected registering to round trip")

	register, registerErr := cbor.marshal(
		ClientRegisterRequest{inviteCode = "ABCD-EFGH", reason = "I know alice"},
	)
	assert(registerErr == nil, "expected ClientRegisterRequest to encode")
	defer delete(register)
	decodedRegister: ClientRegisterRequest
	assert(cbor.unmarshal(register, &decodedRegister) == nil, "expected it to decode")
	defer ClientRegisterRequest_deinit(&decodedRegister)
	assert(
		decodedRegister.inviteCode == "ABCD-EFGH" && decodedRegister.reason == "I know alice",
		"expected the code and reason to round trip",
	)
}
