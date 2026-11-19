package common

import "core:crypto/chacha20poly1305"
import "core:crypto/x25519"
import "core:encoding/cbor"
import "core:encoding/endian"
import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"

// Known-answer vectors from dev/tools/e2ee-vectors.py, an independent implementation of the
// layouts in common/e2ee.odin with Python's `cryptography` package (OpenSSL) and a hand-written
// HChaCha20 checked against draft-irtf-cfrg-xchacha-03. Every input is SHA-256 of a label, so
// the script and these tests derive the same keys. Rerun the script after any change to a
// layout, a domain string or an HKDF label, and paste its output here.

@(private = "file")
KAT_SERVER_PUBLIC :: "bbf324b19315c060c0eeda3cfd001a3c80d529e2dfb89fadc5156a993b996cc6"
@(private = "file")
KAT_ALICE_PUBLIC :: "5b371a06b0c9f8eff82e469f49f4b411a66b81d55c3469ac3b305f4152719245"
@(private = "file")
KAT_ALICE_ENCRYPTION_PUBLIC ::
	"c7a2b97b9de9491f5c9891922932e1854793e120d1eceb5a3564381aa8e5f146"
@(private = "file")
KAT_BUNDLE_SIGNATURE ::
	"babf0fd1dbcfda55c445f42c42aff6f645066589f7f08cc3790bffa84dd76a3ae6a063632f136c6f" +
	"518c1d94b151c2eeb0d0d8b983b977b3f447c4224f4ca50f"
@(private = "file")
KAT_DM_WRAP_KEY_BOB :: "ecf0398ad96dcad834afbbfae867a27f12595b8686a9066b6d67dc13c2a88a38"
@(private = "file")
KAT_DM_ENVELOPE ::
	"0101062fe0eebf28d45d0af141abcc9db1a49a0ef7c7feb2977414a396878cdacb02020007000000" +
	"000000003e3f004efda10d357a7c29360781c0b32c786244a86f03aefeb502b45a604bcfb2d38dde" +
	"ca0c18c15c5dca36142e01aa0900000000000000fd147000b9adc7c0c587be8b5840235da522a895" +
	"6696e4a0aa8c32616348b67946cb937fd13d6a739b4abece75de7d803f4c811cb20e556e455b6fd1" +
	"50cd143d86ba184f111029af100100001be7a7db0babf078b65febdd112906756b7be1faf7cdcfb6" +
	"6035ad33022d49ea3768877d9e51a8409bdf9caf93524b5d9e6d1f725677cfcebeefd3d4b939af90" +
	"3217292a8619f40cf8988d2ed232b71156a8bd151aee9966e772349aa5e8223902e968f6ee957583" +
	"8c21e7fa60740cd7e46b285de0eaa2e5379f5033a0e1fa69d76655d6a428ee94e8a7c85528e82b84" +
	"6a5dcac8115e7f91e78032e5024c6e7cc3b248a787bb9cbd9a8dcf772579f53a95f6c00c7c4b1aa1" +
	"45bd44de87a0ae741be4550441065e9f062763857f21c1bc0730b1ae3577a0cc75ee232ccd373eef" +
	"5147ec06e555a3a80ea1c1600666a2c67b7c2ca2643b95318e2b055d14c1460a2a34d1a6bd709524" +
	"77baff70ef7fb5dd208e334e4fa706f37b6241c173320ed6450d7d607c8bab0ade1cc365b5dc353d" +
	"70e04c111d6f0441c7ad2c0b0dedc2d993778be7af26eb3875dd33d5175dac0a"
@(private = "file")
KAT_CHAIN_KEY_1 :: "56c6c28fa4c40d5544b238975d00641a8b4143f30b04c2ddd79a9613820d97dd"
@(private = "file")
KAT_CHAIN_MESSAGE_KEY_0 :: "8c1fd106a8833eb19bced9f5bd7c7bb26f72f9b0c6301e162ca8b2dc81440944"
@(private = "file")
KAT_CHAIN_MESSAGE_KEY_1 :: "53f06ed2cd0262b77fe09d3fc13da8933d82d9e2fe6145c23764b2aca67ab222"
@(private = "file")
KAT_CHAIN_MESSAGE_KEY_5 :: "c4d371baa7e0602e0810e59c2e262508c91f2e9aef62f676791e0a113a2ad915"
@(private = "file")
KAT_CHAIN_MESSAGE_KEY_999 :: "cac7222ae163614f0b3a67e63ae0874b776d88f5ee3b0f259c796548d855238b"
@(private = "file")
KAT_ROOM_MESSAGE ::
	"0103000000000000009896c8d6960bef7816ab5b42c5bc9427050000007724d82d05f8759620fd8d" +
	"4e7857a32369d66aa3f35e95d010010000c588ab855607a2b2c134f6893ddd0d13ee68532f7c7510" +
	"b46614361d68aea7d3717f2ac31502d4e00e24693df35cc7f55919b1ca6aa58eabc0b527c7c97872" +
	"aa081d07e9d0cf9d957e71352f836e788ff03c9741709cca25160ac6749556bd3c749fe88c345e2b" +
	"83d192f9b7ac5d43284ba305eb2f21bd7e369824a1417301f1e552361aabb45bf776e2b88a96e895" +
	"a2f314dbb104944e135b2af9a22e9c64d0974cdcfd50ec3a9de09e57d8bf83bb237804ca0fc81bc4" +
	"5a40c48ae654813860490b41c9716c3e65142d9b3724529bbef14fdcf1580dcff211d9a2ae49a7c5" +
	"4b47781c3170da763558f175dfb8ad0e734527241558dcdcc9904d36d2eeafad6772a1b24cfcc1a2" +
	"8ff0aa06bbfe3907f6b8e6ee852644d98e4ece67d2eed7685beca1b1b2178a0a922a11bb97faba2d" +
	"5e50c0e1be4a0e90dc12f9d8e403bf690fe39dfde7333f2f1dc78396e0ad06a900"
@(private = "file")
KAT_ROOM_LOG_CREATE ::
	"012a0000000000000001000000000000000000000000000000000000000000000000000000000000" +
	"0000000000000000000107000000000000005b371a06b0c9f8eff82e469f49f4b411a66b81d55c34" +
	"69ac3b305f415271924507000000000000005b371a06b0c9f8eff82e469f49f4b411a66b81d55c34" +
	"69ac3b305f4152719245007116690000000001030201020007000000000000005b371a06b0c9f8ef" +
	"f82e469f49f4b411a66b81d55c3469ac3b305f41527192450b00000000000000f3701ca445177867" +
	"d3c23f38bee0cdbc521f156fefee4e63df3d4416cbc26558b65da60c4c05a058246c4f8021419186" +
	"65c85e6c17fb566e87d34156d1c89675693d318984f284e36c2ea795b8a2bfd7d3952260405c5cfc" +
	"b2c2fc359e6a9108"
@(private = "file")
KAT_ROOM_LOG_CREATE_HASH :: "c74bbd99da02d8a3cdced101713f632b6b58778b95317323388701669080e33c"
@(private = "file")
KAT_PLAIN_SIGNATURE ::
	"5e9e8eb05f0eb2d3cb66253afc06c1057983c2469369a72997cb8863fa8da686d6a9b2135fcebf0c" +
	"2663d19e7fb528283ed758b947b9cd9f044dce9b480c6605"
@(private = "file")
KAT_ROOM_PLAIN_SIGNATURE ::
	"f3f4a68990f887cafab9bea8f40c2c101ced56240e5ea879c53651b8e08c5d2cccd8aafefef3b2aa" +
	"05960e04be9d8d22b29f2f23ca1e9f16699a8c7b3e9e1100"
@(private = "file")
KAT_SAFETY_NUMBER :: "63169 33002 55097 54173 25823 15407 58924 75444 38904 85841 67880 39441"

@(private = "file")
KAT_ROOM_KEY_FORWARD ::
	"010313de0e4f9a3dec1e7461450153148681526a2d1ab6239d0ac884d24e7fafa03501000b000000" +
	"00000000fb64864c8655b477eb43e9834a980f02cf339f00182b489b8e1e1e9389f6b007f8e3a2d7" +
	"5105bbbae931402668d3777ec91b9028578e01ee75e98eb4bd3edae54c377b9b96c7651610010000" +
	"cc1bc88e6494abcbd392b4e49723614a4f28fb03b0c8c29e221e64222ca719ee1d7a4623d5ee3fe2" +
	"bc4609f13f4f00d5ab833f8a7045c59276b3f3af5f2235e25bfe038b8a9ae32f7d33745373ed5422" +
	"db2c954679bffd9e96462827621b46602d606c7aa8ed80166baf0e86acd83fbb51d08290242f5ae2" +
	"d2575b6fdc669e16dcf5f9ed00adcf030ada70a6683e231b155cb1b226c56cafef80097b2c588dfc" +
	"3d3d9154b7af57ccd892504235ae0385e8907abedc460929a88e39eb1b4656ac7e568924bcfea47a" +
	"6856e2908dbae245d0f9932dadcde7cb64863d285a69f43028bb3b4b390e7fac61f80d9ae92311ce" +
	"d95807410c2a7493c999c48a0eb14b459c259e9302b2d4b21f3081e046e7fb5cf730b7dfd3eecb80" +
	"5159457bf8bdb4ace93caf847c7e035302a027ecd16a94889b47aee27c012f87959d6e2ce944e812" +
	"16c95568d2838d8dffc200fc379ed40b"

// Protocol 21: alice's voice key (epoch 3, generation 7) sealed to bob and carol.
@(private = "file")
KAT_VOICE_KEY_ENVELOPE ::
	"0104f92010622cb419e36b7830607bd640689eb1674d46ba8e3650f20a73a020c565020009000000" +
	"0000000024ca8097777ecfae9bf53dd73f2fdb867fdd0012956c7254ceadcb13ab1b04bacd861dfa" +
	"f3e2da985f8ae8bb5da76e430b00000000000000719b63a4b2d802479155b1fd683fb12f75c683cb" +
	"310edbfaf2260081f634360e48bf33fb30ad1cd48e12585c2e3db79287a3edb3d38bb6039c3169b7" +
	"15605fffb3bd6816cf4aaa4b10010000619feac73106ac8afe44d7f1dd535a6ae860b11e0a549945" +
	"09fd51bf837e04e05816a497483030ce2bc0b0d77f7a14501440fff76a205bd49893983b50dcecc7" +
	"d45948971738a610c56f92b87ceaa3798724c096599ff1daccada8fdbad252875f99d5f06f2eed38" +
	"5eb71a45f257a8832f334cc7af68c2892fb245bec3bd1707de43576ee1151fb824ab00bf3fa225fe" +
	"7f216ab6943f3ad292424a67587d39af2aee71ddaf708f0602647d7503da3908c06f21d53228de87" +
	"7c37a862e8c8db220154c5b38c5fcb009638fd33128c8edaffd9b69c289cc128181e91308e16fb52" +
	"06e5d74f2de9e92104c8adef9a48c9753c215adcc0c6239014b9785505c52ba8b3b11d3ff4b245ea" +
	"537903f42e4fc24a0abf6ef83e4dea5078c5cda4ef06784f420eab270983e445e1e1d5763ee32072" +
	"f8fa9c7268abda606f99c8ad30410c023b4cea4142d30285e229dff07f677e0c"

// Fixtures shared with dev/tools/e2ee-vectors.py.
@(private = "file")
TEST_ALICE_ID :: 7
@(private = "file")
TEST_BOB_ID :: 9
@(private = "file")
TEST_CAROL_ID :: 11
@(private = "file")
TEST_DAVE_ID :: 13
@(private = "file")
TEST_ERIN_ID :: 15
@(private = "file")
TEST_ROOM_ID :: 42
@(private = "file")
TEST_CREATED_AT :: 1_763_078_400

@(private = "file")
TestUser :: struct {
	id:         int,
	privateKey: IdentityPrivateKeyBytes,
	publicKey:  IdentityPublicKeyBytes,
}

@(private = "file")
testLabel :: proc(label: string) -> [32]u8 {
	return hashBytes(transmute([]u8)label)
}

@(private = "file")
testUser :: proc(name: string, id: int) -> TestUser {
	label := fmt.tprintf("haychat-e2ee-test-%s-identity", name)
	user := TestUser {
		id         = id,
		privateKey = IdentityPrivateKeyBytes(testLabel(label)),
	}
	publicKey, ok := identityPublicKeyFromPrivateKey(user.privateKey)
	assert(ok, "expected a test identity key")
	user.publicKey = publicKey
	return user
}

@(private = "file")
testEncryptionKeyPair :: proc(name: string) -> EncryptionKeyPair {
	label := fmt.tprintf("haychat-e2ee-test-%s-encryption", name)
	return encryptionKeyPairFromPrivateKey(EncryptionPrivateKeyBytes(testLabel(label)))
}

@(private = "file")
testServerPublicKey :: proc() -> IdentityPublicKeyBytes {
	return testUser("server", 1).publicKey
}

// Decodes hex into the front of buffer and returns that part.
@(private = "file")
testHex :: proc(hexValue: string, buffer: []u8) -> []u8 {
	assert(len(hexValue) % 2 == 0 && len(hexValue) / 2 <= len(buffer), "test hex too long")
	bytes := buffer[:len(hexValue) / 2]
	assert(decodeHexIntoBuffer(hexValue, bytes), fmt.tprintf("expected valid hex: %s", hexValue))
	return bytes
}

@(private = "file")
testHexEqual :: proc(bytes: []u8, expectedHex: string) -> bool {
	buffer: [SEALED_ENVELOPE_MAX_BYTES]u8
	expected := testHex(expectedHex, buffer[:])
	return len(bytes) == len(expected) && string(bytes) == string(expected)
}

@(private = "file")
testDirectMessageFields :: proc() -> DirectMessageAADFields {
	alice := testUser("alice", TEST_ALICE_ID)
	bob := testUser("bob", TEST_BOB_ID)
	clientMessageIDLabel := testLabel("haychat-e2ee-test-dm-client-message-id")
	fields := DirectMessageAADFields {
		serverIdentityPublicKey    = testServerPublicKey(),
		senderUserID               = alice.id,
		recipientUserID            = bob.id,
		senderIdentityPublicKey    = alice.publicKey,
		recipientIdentityPublicKey = bob.publicKey,
	}
	copy(fields.clientMessageID[:], clientMessageIDLabel[:CLIENT_MESSAGE_ID_SIZE])
	return fields
}

// Seals the direct message of the KAT_DM_ENVELOPE vector into dst.
@(private = "file")
testSealVectorDirectMessage :: proc(dst: []u8) -> []u8 {
	alice := testUser("alice", TEST_ALICE_ID)
	aliceKeys := testEncryptionKeyPair("alice")
	bobKeys := testEncryptionKeyPair("bob")
	fields := testDirectMessageFields()
	aad := makeDirectMessageAAD(fields)
	plaintext: [DIRECT_MESSAGE_PLAINTEXT_MAX_SIZE]u8
	plaintextLength, encodeOK := encodeSealedDirectMessagePlaintext("hello, bob", plaintext[:])
	assert(encodeOK, "expected the vector plaintext to encode")
	recipients := [2]EnvelopeRecipient {
		{userID = TEST_ALICE_ID, encryptionPublicKey = aliceKeys.publicKey},
		{userID = TEST_BOB_ID, encryptionPublicKey = bobKeys.publicKey},
	}
	nonceLabel := testLabel("haychat-e2ee-test-dm-nonce")
	nonce: E2EENonce
	copy(nonce[:], nonceLabel[:E2EE_NONCE_SIZE])
	n, err := sealEnvelopeWithRandomness(
		.DirectMessage,
		aad[:],
		plaintext[:plaintextLength],
		recipients[:],
		alice.privateKey,
		MessageKey(testLabel("haychat-e2ee-test-dm-message-key")),
		EncryptionPrivateKeyBytes(testLabel("haychat-e2ee-test-dm-ephemeral")),
		nonce,
		dst,
	)
	assert(err == .None, fmt.tprintf("expected the vector envelope to seal, got %v", err))
	return dst[:n]
}

// Opens data as bob with the direct message fields and returns the error only.
@(private = "file")
testOpenAsBob :: proc(data: []u8, fields: DirectMessageAADFields) -> E2EEError {
	aad := makeDirectMessageAAD(fields)
	buffer: [SEALED_ENVELOPE_MAX_BYTES]u8
	_, err := openEnvelope(
		data,
		.DirectMessage,
		aad[:],
		fields.senderIdentityPublicKey,
		TEST_BOB_ID,
		testEncryptionKeyPair("bob"),
		buffer[:],
	)
	return err
}

// Replaces data's trailing envelope signature with signer's signature over aad and the rest, as
// a sender who tampers with their own envelope could. Exercises the layers under the signature.
@(private = "file")
testResign :: proc(data: []u8, domain: string, aad: []u8, signer: IdentityPrivateKeyBytes) {
	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, domain)
	strings.write_bytes(&builder, aad)
	strings.write_bytes(&builder, data[:len(data) - AUTH_SIGNATURE_SIZE])
	signature, ok := signBytes(signer, builder.buf[:])
	assert(ok, "expected the test signature")
	copy(data[len(data) - AUTH_SIGNATURE_SIZE:], signature[:])
}

@(test)
testE2EEConstants :: proc(t: ^testing.T) {
	_ = t
	assert(SEALED_ENVELOPE_MAX_BYTES == 8192, "expected 8192-byte envelopes")
	assert(ENCRYPTED_ROOM_MEMBERS_MAX == 100, "expected at most 100 encrypted room members")
	assert(USER_KEYS_FETCH_MAX == 64, "expected at most 64 users per key fetch")
	assert(SENDER_CHAIN_MAX_MESSAGES == 1000, "expected 1000 messages per chain")
	assert(SENDER_CHAIN_MAX_AGE_SECONDS == 604_800, "expected chains to last 7 days")
	assert(SENDER_CHAIN_MAX_AGE == 7 * 24 * time.Hour, "expected a seven-day chain age")
	assert(DIRECT_MESSAGE_AAD_SIZE == 141, fmt.tprintf("DM AAD: %d", DIRECT_MESSAGE_AAD_SIZE))
	assert(ROOM_KEY_AAD_SIZE == 91, fmt.tprintf("room key AAD: %d", ROOM_KEY_AAD_SIZE))
	assert(ROOM_MESSAGE_AAD_SIZE == 107, fmt.tprintf("room AAD: %d", ROOM_MESSAGE_AAD_SIZE))
	assert(
		ROOM_KEY_FORWARD_AAD_SIZE == 115,
		fmt.tprintf("room key forward AAD: %d", ROOM_KEY_FORWARD_AAD_SIZE),
	)
	assert(VOICE_KEY_AAD_SIZE == 104, fmt.tprintf("voice key AAD: %d", VOICE_KEY_AAD_SIZE))
	assert(VOICE_KEY_PLAINTEXT_SIZE == 77, "expected a 77-byte voice key plaintext")
	assert(
		sealedEnvelopeSize(SEALED_ENVELOPE_MAX_WRAPS, VOICE_KEY_PLAINTEXT_SIZE) <=
		SEALED_ENVELOPE_MAX_BYTES,
		"expected a voice key to 100 members to fit",
	)
	assert(int(EnvelopeKind.VoiceKey) == 4, "expected the VoiceKey envelope kind to stay 4")
	assert(
		ENCRYPTION_KEY_BUNDLE_SIGNED_SIZE == 102,
		fmt.tprintf("bundle: %d", ENCRYPTION_KEY_BUNDLE_SIGNED_SIZE),
	)
	assert(SENDER_KEY_DISTRIBUTION_SIZE == 69, "expected a 69-byte key distribution")
	assert(KEY_WRAP_SIZE == 56, "expected 56-byte wraps")
	assert(SEALED_ENVELOPE_OVERHEAD == 144, "expected 144 bytes of envelope overhead")
	assert(SEALED_ROOM_MESSAGE_OVERHEAD == 137, "expected 137 bytes of room message overhead")
	assert(ROOM_LOG_ENTRY_MIN_BYTES == 203, "expected 203-byte minimal log entries")
	assert(ROOM_LOG_ENTRY_MAX_BYTES == 4208, "expected 4208-byte maximal log entries")
	assert(
		sealedEnvelopeSize(SEALED_ENVELOPE_MAX_WRAPS, 68) <= SEALED_ENVELOPE_MAX_BYTES,
		"expected a key distribution to 100 members to fit",
	)
	assert(
		sealedEnvelopeSize(2, DIRECT_MESSAGE_PLAINTEXT_MAX_SIZE) <= SEALED_ENVELOPE_MAX_BYTES,
		"expected the longest direct message to fit",
	)
	assert(
		sealedRoomMessageSize(DIRECT_MESSAGE_PLAINTEXT_MAX_SIZE) <= SEALED_ROOM_MESSAGE_MAX_BYTES,
		"expected the longest room message to fit",
	)

	// No signed domain may be a prefix of another, or one signature could be read as two kinds.
	domains := [?]string {
		ENCRYPTION_KEY_BUNDLE_DOMAIN,
		ENVELOPE_SIGNATURE_DOMAIN,
		PLAINTEXT_DIRECT_MESSAGE_DOMAIN,
		ROOM_MESSAGE_SIGNATURE_DOMAIN,
		ROOM_LOG_SIGNATURE_DOMAIN,
	}
	for domain, index in domains {
		for other, otherIndex in domains {
			if index != otherIndex {
				assert(
					!strings.has_prefix(domain, other),
					fmt.tprintf("expected %q not to start with %q", domain, other),
				)
			}
		}
	}
	// The same for the AAD labels, so no AAD can be read as one of another kind.
	labels := [?]string {
		DIRECT_MESSAGE_AAD_DOMAIN,
		ROOM_KEY_AAD_DOMAIN,
		ROOM_KEY_FORWARD_AAD_DOMAIN,
		ROOM_MESSAGE_AAD_DOMAIN,
		VOICE_KEY_AAD_DOMAIN,
		VOICE_FRAME_AAD_DOMAIN,
		// And the signature domains and HKDF labels, so a voice label is never read as one.
		ENCRYPTION_KEY_BUNDLE_DOMAIN,
		ENVELOPE_SIGNATURE_DOMAIN,
		ENVELOPE_WRAP_INFO,
		PLAINTEXT_DIRECT_MESSAGE_DOMAIN,
		ROOM_MESSAGE_SIGNATURE_DOMAIN,
		ROOM_LOG_SIGNATURE_DOMAIN,
		SENDER_CHAIN_MESSAGE_INFO,
		SENDER_CHAIN_STEP_INFO,
		SAFETY_NUMBER_DOMAIN,
	}
	for label, index in labels {
		for other, otherIndex in labels {
			if index != otherIndex {
				assert(
					!strings.has_prefix(label, other),
					fmt.tprintf("expected %q not to start with %q", label, other),
				)
			}
		}
	}
}

@(test)
testE2EEFixturesMatchVectors :: proc(t: ^testing.T) {
	_ = t
	server := testServerPublicKey()
	alice := testUser("alice", TEST_ALICE_ID)
	aliceKeys := testEncryptionKeyPair("alice")
	assert(testHexEqual(server[:], KAT_SERVER_PUBLIC), "expected the vector server key")
	assert(testHexEqual(alice.publicKey[:], KAT_ALICE_PUBLIC), "expected the vector alice key")
	assert(
		testHexEqual(aliceKeys.publicKey[:], KAT_ALICE_ENCRYPTION_PUBLIC),
		"expected the vector alice encryption key",
	)
}

@(test)
testEncryptionKeyBundle :: proc(t: ^testing.T) {
	_ = t
	alice := testUser("alice", TEST_ALICE_ID)
	bob := testUser("bob", TEST_BOB_ID)
	aliceKeys := testEncryptionKeyPair("alice")

	bundle, ok := signEncryptionKeyBundle(alice.privateKey, aliceKeys.publicKey, TEST_CREATED_AT)
	assert(ok, "expected the bundle to sign")
	assert(bundle.identityPublicKey == alice.publicKey, "expected the bundle's identity key")
	assert(testHexEqual(bundle.signature[:], KAT_BUNDLE_SIGNATURE), "expected the vector")
	assert(verifyEncryptionKeyBundle(bundle), "expected the bundle to verify")

	changed := bundle
	changed.createdAt += 1
	assert(!verifyEncryptionKeyBundle(changed), "expected a changed createdAt to fail")
	changed = bundle
	changed.encryptionPublicKey = testEncryptionKeyPair("bob").publicKey
	assert(!verifyEncryptionKeyBundle(changed), "expected a changed encryption key to fail")
	changed = bundle
	changed.identityPublicKey = bob.publicKey
	assert(!verifyEncryptionKeyBundle(changed), "expected another identity key to fail")
	changed = bundle
	changed.signature[10] ~= 0x01
	assert(!verifyEncryptionKeyBundle(changed), "expected a flipped signature bit to fail")

	// Small-order X25519 keys: zero, one, and the order-8 point from RFC 7748's examples.
	zero: EncryptionPublicKeyBytes
	one: EncryptionPublicKeyBytes
	one[0] = 1
	orderEight: EncryptionPublicKeyBytes
	testHex(
		"e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800",
		orderEight[:],
	)
	for weak in ([?]EncryptionPublicKeyBytes{zero, one, orderEight}) {
		assert(!encryptionPublicKeyIsValid(weak), "expected a small-order key to be refused")
		_, signOK := signEncryptionKeyBundle(alice.privateKey, weak, TEST_CREATED_AT)
		assert(!signOK, "expected a small-order key not to be signed")
	}
	assert(encryptionPublicKeyIsValid(aliceKeys.publicKey), "expected a real key to be valid")

	generated, generatedOK := generateEncryptionKeyPair()
	assert(generatedOK, "expected a generated encryption key")
	derived := encryptionKeyPairFromPrivateKey(generated.privateKey)
	assert(derived.publicKey == generated.publicKey, "expected the public key to rederive")
	EncryptionKeyPair_wipe(&generated)
	assert(generated == EncryptionKeyPair{}, "expected the wiped key pair to be zero")
}

@(test)
testDirectMessageEnvelopeVector :: proc(t: ^testing.T) {
	_ = t
	buffer: [SEALED_ENVELOPE_MAX_BYTES]u8
	sealed := testSealVectorDirectMessage(buffer[:])
	assert(
		testHexEqual(sealed, KAT_DM_ENVELOPE),
		fmt.tprintf("expected the vector envelope, got %x", sealed),
	)

	// The wrap key the independent implementation derived for bob.
	fields := testDirectMessageFields()
	aad := makeDirectMessageAAD(fields)
	bobKeys := testEncryptionKeyPair("bob")
	ephemeral := encryptionKeyPairFromPrivateKey(
		EncryptionPrivateKeyBytes(testLabel("haychat-e2ee-test-dm-ephemeral")),
	)
	sharedSecret: [32]u8
	ephemeralPrivate := ephemeral.privateKey
	bobPublic := bobKeys.publicKey
	x25519.scalarmult(sharedSecret[:], ephemeralPrivate[:], bobPublic[:])
	wrapKey := deriveEnvelopeWrapKey(
		sharedSecret,
		ephemeral.publicKey,
		bobKeys.publicKey,
		.DirectMessage,
		aad[:],
	)
	assert(testHexEqual(wrapKey[:], KAT_DM_WRAP_KEY_BOB), "expected the vector wrap key")

	// The Python envelope opens for both wraps, through every entry point.
	vectorBuffer: [SEALED_ENVELOPE_MAX_BYTES]u8
	vector := testHex(KAT_DM_ENVELOPE, vectorBuffer[:])
	assert(verifyDirectMessageEnvelope(vector, fields) == .None, "expected the server check")
	for reader in ([?]struct {
			id:   int,
			name: string,
		}{{TEST_BOB_ID, "bob"}, {TEST_ALICE_ID, "alice"}}) {
		keys := testEncryptionKeyPair(reader.name)
		opened, err := openDirectMessage(vector, fields, reader.id, keys)
		defer SealedDirectMessagePlaintext_deinit(&opened)
		assert(err == .None, fmt.tprintf("expected %s to open, got %v", reader.name, err))
		assert(opened.content == "hello, bob", fmt.tprintf("got %q", opened.content))
	}

	envelope, decodeErr := decodeSealedEnvelope(vector)
	assert(decodeErr == .None, "expected the vector to decode")
	assert(envelope.kind == .DirectMessage && envelope.wrapCount == 2, "expected two wraps")
	assert(SealedEnvelope_wrap(envelope, 0).recipientUserID == TEST_ALICE_ID, "sender first")
	assert(SealedEnvelope_wrap(envelope, 1).recipientUserID == TEST_BOB_ID, "recipient second")
	_, found := SealedEnvelope_findWrap(envelope, TEST_CAROL_ID)
	assert(!found, "expected no wrap for carol")
}

@(test)
testEnvelopeRoundTripOneAndManyRecipients :: proc(t: ^testing.T) {
	_ = t
	alice := testUser("alice", TEST_ALICE_ID)
	aad := [?]u8{1, 2, 3}
	plaintext := "a sender key, or anything else"
	buffer: [SEALED_ENVELOPE_MAX_BYTES]u8
	opened: [SEALED_ENVELOPE_MAX_BYTES]u8

	// One recipient: the sender alone.
	aliceKeys := testEncryptionKeyPair("alice")
	single := [1]EnvelopeRecipient{{TEST_ALICE_ID, aliceKeys.publicKey}}
	n, err := sealEnvelope(
		.RoomKeyForward,
		aad[:],
		transmute([]u8)plaintext,
		single[:],
		alice.privateKey,
		buffer[:],
	)
	assert(err == .None, fmt.tprintf("expected one recipient to seal, got %v", err))
	assert(n == sealedEnvelopeSize(1, len(plaintext)), "expected the computed size")
	result, openErr := openEnvelope(
		buffer[:n],
		.RoomKeyForward,
		aad[:],
		alice.publicKey,
		TEST_ALICE_ID,
		aliceKeys,
		opened[:],
	)
	assert(openErr == .None && string(result) == plaintext, "expected the sender's wrap to open")

	// ENCRYPTED_ROOM_MEMBERS_MAX recipients, each opening its own wrap.
	recipients: [SEALED_ENVELOPE_MAX_WRAPS + 1]EnvelopeRecipient
	keyPairs: [SEALED_ENVELOPE_MAX_WRAPS + 1]EncryptionKeyPair
	for index in 0 ..< len(recipients) {
		keyPairs[index] = testEncryptionKeyPair(fmt.tprintf("member-%d", index))
		recipients[index] = {100 + index, keyPairs[index].publicKey}
	}
	n, err = sealEnvelope(
		.SenderKey,
		aad[:],
		transmute([]u8)plaintext,
		recipients[:SEALED_ENVELOPE_MAX_WRAPS],
		alice.privateKey,
		buffer[:],
	)
	assert(err == .None, fmt.tprintf("expected 100 recipients to seal, got %v", err))
	for index in 0 ..< SEALED_ENVELOPE_MAX_WRAPS {
		result, openErr = openEnvelope(
			buffer[:n],
			.SenderKey,
			aad[:],
			alice.publicKey,
			recipients[index].userID,
			keyPairs[index],
			opened[:],
		)
		assert(openErr == .None, fmt.tprintf("recipient %d: %v", index, openErr))
		assert(string(result) == plaintext, "expected every recipient's plaintext")
	}
	_, openErr = openEnvelope(
		buffer[:n],
		.SenderKey,
		aad[:],
		alice.publicKey,
		recipients[SEALED_ENVELOPE_MAX_WRAPS].userID,
		keyPairs[SEALED_ENVELOPE_MAX_WRAPS],
		opened[:],
	)
	assert(openErr == .NoWrapForRecipient, fmt.tprintf("non-recipient: %v", openErr))
	// The right wrap with the wrong private key.
	_, openErr = openEnvelope(
		buffer[:n],
		.SenderKey,
		aad[:],
		alice.publicKey,
		recipients[0].userID,
		keyPairs[1],
		opened[:],
	)
	assert(openErr == .BadWrap, fmt.tprintf("wrong private key: %v", openErr))
	_, openErr = openEnvelope(
		buffer[:n],
		.SenderKey,
		aad[:],
		alice.publicKey,
		recipients[0].userID,
		keyPairs[0],
		opened[:len(plaintext)],
	)
	assert(openErr == .BufferTooSmall, fmt.tprintf("small dst: %v", openErr))

	// Refused inputs, each with its own error.
	sealCase :: proc(
		recipients: []EnvelopeRecipient,
		plaintext: []u8,
		aad: []u8,
		dst: []u8,
	) -> E2EEError {
		alice := testUser("alice", TEST_ALICE_ID)
		_, err := sealEnvelope(.SenderKey, aad, plaintext, recipients, alice.privateKey, dst)
		return err
	}
	text := transmute([]u8)plaintext
	assert(sealCase(recipients[:], text, aad[:], buffer[:]) == .BadWrapCount, "101 recipients")
	assert(sealCase(nil, text, aad[:], buffer[:]) == .NoRecipients, "no recipients")
	duplicate := [2]EnvelopeRecipient{recipients[0], recipients[0]}
	assert(
		sealCase(duplicate[:], text, aad[:], buffer[:]) == .DuplicateRecipient,
		"duplicate recipient",
	)
	badID := [1]EnvelopeRecipient{{0, aliceKeys.publicKey}}
	assert(sealCase(badID[:], text, aad[:], buffer[:]) == .BadRecipientUserID, "user ID 0")
	weak := [2]EnvelopeRecipient{recipients[0], {200, EncryptionPublicKeyBytes{}}}
	clean: [SEALED_ENVELOPE_MAX_BYTES]u8
	assert(sealCase(weak[:], text, aad[:], clean[:]) == .BadRecipientKey, "small-order key")
	assert(clean == [SEALED_ENVELOPE_MAX_BYTES]u8{}, "expected no partial envelope on failure")
	huge: [SEALED_ENVELOPE_MAX_BYTES]u8
	assert(sealCase(single[:], huge[:], aad[:], buffer[:]) == .PlaintextTooLarge, "too large")
	assert(sealCase(single[:], text, aad[:], buffer[:100]) == .BufferTooSmall, "small dst")
	longAAD: [E2EE_AAD_MAX_BYTES + 1]u8
	assert(sealCase(single[:], text, longAAD[:], buffer[:]) == .AADTooLarge, "long AAD")
}

@(test)
testEnvelopeEveryTamperFails :: proc(t: ^testing.T) {
	_ = t
	fields := testDirectMessageFields()
	vectorBuffer: [SEALED_ENVELOPE_MAX_BYTES]u8
	vector := testHex(KAT_DM_ENVELOPE, vectorBuffer[:])
	assert(testOpenAsBob(vector, fields) == .None, "expected the untouched vector to open")

	// A flipped bit anywhere: the signature covers every byte before it, so nothing opens.
	for index in 0 ..< len(vector) {
		for bit in ([?]u8{0x01, 0x80}) {
			vector[index] ~= bit
			err := testOpenAsBob(vector, fields)
			vector[index] ~= bit
			assert(err != .None, fmt.tprintf("byte %d bit %x opened", index, bit))
		}
	}

	// Below the signature: a sender who re-signs a tampered envelope still fails each layer.
	alice := testUser("alice", TEST_ALICE_ID)
	aad := makeDirectMessageAAD(fields)
	envelope, _ := decodeSealedEnvelope(vector)
	bobWrapStart := SEALED_ENVELOPE_HEADER_SIZE + KEY_WRAP_SIZE + 8
	ciphertextStart := SEALED_ENVELOPE_HEADER_SIZE + 2 * KEY_WRAP_SIZE + E2EE_NONCE_SIZE + 4
	cases := [?]struct {
		offset:   int,
		expected: E2EEError,
	} {
		{2, .BadWrap}, // the ephemeral key changes every wrap key
		{bobWrapStart, .BadWrap}, // bob's wrapped key
		{bobWrapStart + 40, .BadWrap}, // bob's wrap tag
		{ciphertextStart - 4 - 1, .BadCiphertext}, // the nonce
		{ciphertextStart, .BadCiphertext}, // the body
		{ciphertextStart + len(envelope.ciphertext) - 1, .BadCiphertext}, // the body's tag
	}
	for tamper in cases {
		copied: [SEALED_ENVELOPE_MAX_BYTES]u8
		data := copied[:len(vector)]
		copy(data, vector)
		data[tamper.offset] ~= 0x04
		testResign(data, ENVELOPE_SIGNATURE_DOMAIN, aad[:], alice.privateKey)
		err := testOpenAsBob(data, fields)
		assert(
			err == tamper.expected,
			fmt.tprintf("offset %d: expected %v, got %v", tamper.offset, tamper.expected, err),
		)
	}

	// A small-order ephemeral key, re-signed: refused before any wrap is tried.
	zeroEphemeral: [SEALED_ENVELOPE_MAX_BYTES]u8
	zeroData := zeroEphemeral[:len(vector)]
	copy(zeroData, vector)
	for index in 2 ..< 2 + ENCRYPTION_PUBLIC_KEY_SIZE {
		zeroData[index] = 0
	}
	testResign(zeroData, ENVELOPE_SIGNATURE_DOMAIN, aad[:], alice.privateKey)
	zeroErr := testOpenAsBob(zeroData, fields)
	assert(zeroErr == .BadEphemeralKey, fmt.tprintf("expected BadEphemeralKey, got %v", zeroErr))

	// The kind byte, re-signed: a valid envelope of another kind.
	copied: [SEALED_ENVELOPE_MAX_BYTES]u8
	data := copied[:len(vector)]
	copy(data, vector)
	data[1] = u8(EnvelopeKind.SenderKey)
	testResign(data, ENVELOPE_SIGNATURE_DOMAIN, aad[:], alice.privateKey)
	assert(testOpenAsBob(data, fields) == .WrongKind, "expected WrongKind")
	assert(verifyDirectMessageEnvelope(data, fields) == .WrongKind, "expected the server's too")
}

@(test)
testEnvelopeWrapMovedToAnotherRecipient :: proc(t: ^testing.T) {
	_ = t
	fields := testDirectMessageFields()
	aad := makeDirectMessageAAD(fields)
	alice := testUser("alice", TEST_ALICE_ID)
	vectorBuffer: [SEALED_ENVELOPE_MAX_BYTES]u8
	vector := testHex(KAT_DM_ENVELOPE, vectorBuffer[:])

	// Swap the two wraps' user IDs: alice's wrap now claims to be bob's.
	aliceIDOffset := SEALED_ENVELOPE_HEADER_SIZE
	bobIDOffset := SEALED_ENVELOPE_HEADER_SIZE + KEY_WRAP_SIZE
	endian.unchecked_put_u64le(vector[aliceIDOffset:], u64(TEST_BOB_ID))
	endian.unchecked_put_u64le(vector[bobIDOffset:], u64(TEST_ALICE_ID))
	assert(testOpenAsBob(vector, fields) == .BadSignature, "expected the server's swap to fail")

	// Even the sender cannot make a wrap open for someone it was not sealed to.
	testResign(vector, ENVELOPE_SIGNATURE_DOMAIN, aad[:], alice.privateKey)
	assert(testOpenAsBob(vector, fields) == .BadWrap, "expected the moved wrap not to open")
}

@(test)
testEnvelopeAADFieldsAreBound :: proc(t: ^testing.T) {
	_ = t
	fields := testDirectMessageFields()
	carol := testUser("carol", TEST_CAROL_ID)
	vectorBuffer: [SEALED_ENVELOPE_MAX_BYTES]u8
	vector := testHex(KAT_DM_ENVELOPE, vectorBuffer[:])

	changes: [6]DirectMessageAADFields
	for &change in changes {
		change = fields
	}
	changes[0].serverIdentityPublicKey = carol.publicKey
	changes[1].senderUserID = TEST_CAROL_ID
	changes[2].recipientUserID = TEST_CAROL_ID
	changes[3].senderIdentityPublicKey[0] ~= 0x01
	changes[4].recipientIdentityPublicKey = carol.publicKey
	changes[5].clientMessageID[15] ~= 0x01
	for change, index in changes {
		// The opener checks the signature against changes[index].senderIdentityPublicKey; for
		// change 3 that is not alice's key, which fails as BadSignature or BadSenderKey.
		err := testOpenAsBob(vector, change)
		assert(
			err == .BadSignature || err == .BadSenderKey,
			fmt.tprintf("AAD change %d: %v", index, err),
		)
		assert(verifyDirectMessageEnvelope(vector, change) != .None, "server check must fail")
	}

	// The AAD is also bound below the signature: re-signed for another AAD, the wraps fail.
	alice := testUser("alice", TEST_ALICE_ID)
	moved := fields
	moved.clientMessageID[0] ~= 0x01
	movedAAD := makeDirectMessageAAD(moved)
	testResign(vector, ENVELOPE_SIGNATURE_DOMAIN, movedAAD[:], alice.privateKey)
	assert(testOpenAsBob(vector, moved) == .BadWrap, "expected the AAD in the wrap key")
}

@(test)
testEnvelopeWrongSigner :: proc(t: ^testing.T) {
	_ = t
	fields := testDirectMessageFields()
	bob := testUser("bob", TEST_BOB_ID)
	vectorBuffer: [SEALED_ENVELOPE_MAX_BYTES]u8
	vector := testHex(KAT_DM_ENVELOPE, vectorBuffer[:])
	aad := makeDirectMessageAAD(fields)
	opened: [SEALED_ENVELOPE_MAX_BYTES]u8

	_, err := openEnvelope(
		vector,
		.DirectMessage,
		aad[:],
		bob.publicKey,
		TEST_BOB_ID,
		testEncryptionKeyPair("bob"),
		opened[:],
	)
	assert(err == .BadSignature, fmt.tprintf("expected bob's pin to refuse, got %v", err))

	invalidKey: IdentityPublicKeyBytes
	for &value in invalidKey {
		value = 0xFF
	}
	_, err = openEnvelope(
		vector,
		.DirectMessage,
		aad[:],
		invalidKey,
		TEST_BOB_ID,
		testEncryptionKeyPair("bob"),
		opened[:],
	)
	assert(err == .BadSenderKey, fmt.tprintf("expected an invalid pin, got %v", err))

	// Signed by bob while the AAD names alice as the sender: the sealer refuses.
	buffer: [SEALED_ENVELOPE_MAX_BYTES]u8
	_, err = sealDirectMessage(
		fields,
		"hi",
		testEncryptionKeyPair("alice").publicKey,
		testEncryptionKeyPair("bob").publicKey,
		bob.privateKey,
		buffer[:],
	)
	assert(err == .BadSigningKey, fmt.tprintf("expected BadSigningKey, got %v", err))
}

@(test)
testEnvelopeTruncationAndStructure :: proc(t: ^testing.T) {
	_ = t
	fields := testDirectMessageFields()
	vectorBuffer: [SEALED_ENVELOPE_MAX_BYTES + 1]u8
	vector := testHex(KAT_DM_ENVELOPE, vectorBuffer[:])
	for length in 0 ..< len(vector) {
		_, err := decodeSealedEnvelope(vector[:length])
		assert(err != .None, fmt.tprintf("expected %d bytes to be refused", length))
		assert(testOpenAsBob(vector[:length], fields) != .None, "expected no truncated open")
	}
	_, err := decodeSealedEnvelope(vector[:len(vector) - 1])
	assert(err == .Truncated, fmt.tprintf("expected Truncated, got %v", err))
	_, err = decodeSealedEnvelope(vectorBuffer[:len(vector) + 1])
	assert(err == .TrailingBytes, fmt.tprintf("expected TrailingBytes, got %v", err))
	_, err = decodeSealedEnvelope(vectorBuffer[:SEALED_ENVELOPE_MAX_BYTES + 1])
	assert(err == .TooLarge, fmt.tprintf("expected TooLarge, got %v", err))

	structureCase :: proc(vector: []u8, offset: int, value: u8) -> E2EEError {
		copied: [SEALED_ENVELOPE_MAX_BYTES]u8
		data := copied[:len(vector)]
		copy(data, vector)
		data[offset] = value
		_, err := decodeSealedEnvelope(data)
		return err
	}
	assert(structureCase(vector, 0, 2) == .UnsupportedVersion, "version 2")
	assert(structureCase(vector, 1, 0) == .UnknownKind, "kind 0")
	assert(structureCase(vector, 1, 5) == .UnknownKind, "kind 5")
	assert(structureCase(vector, 34, 0) == .BadWrapCount, "zero wraps")
	assert(structureCase(vector, 34, 3) == .Truncated, "three wraps claimed")
	assert(structureCase(vector, 35, 1) == .BadWrapCount, "257 wraps")
	assert(structureCase(vector, 36, 0) == .BadRecipientUserID, "user ID 0")
	assert(structureCase(vector, 43, 0x80) == .BadRecipientUserID, "negative user ID")
	assert(structureCase(vector, 36 + 56, TEST_ALICE_ID) == .DuplicateRecipient, "duplicate")
	lengthOffset := SEALED_ENVELOPE_HEADER_SIZE + 2 * KEY_WRAP_SIZE + E2EE_NONCE_SIZE
	assert(structureCase(vector, lengthOffset, 0x11) == .Truncated, "a longer ciphertext")
	assert(structureCase(vector, lengthOffset, 0x0F) == .TrailingBytes, "a shorter one")

	// A consistent but impossible ciphertext length (not tag + 256k): shorten the body by 16.
	shortened: [SEALED_ENVELOPE_MAX_BYTES]u8
	cut := lengthOffset + 4 + 16
	copy(shortened[:cut], vector[:cut])
	copy(shortened[cut:], vector[cut + 16:])
	endian.unchecked_put_u32le(shortened[lengthOffset:], 256)
	_, err = decodeSealedEnvelope(shortened[:len(vector) - 16])
	assert(err == .BadCiphertextLength, fmt.tprintf("expected BadCiphertextLength, got %v", err))
}

@(test)
testPaddingEveryLength :: proc(t: ^testing.T) {
	_ = t
	plaintext: [CHAT_MESSAGE_MAX_BYTES]u8
	for &value, index in plaintext {
		value = u8(index % 251 + 1)
	}
	padded: [CHAT_MESSAGE_MAX_BYTES + E2EE_PADDING_BLOCK]u8
	for length in 0 ..= CHAT_MESSAGE_MAX_BYTES {
		n, err := padPlaintext(plaintext[:length], padded[:])
		assert(err == .None, fmt.tprintf("length %d: %v", length, err))
		assert(n == paddedLength(length), "expected paddedLength")
		assert(n % E2EE_PADDING_BLOCK == 0 && n > length, "expected a whole number of blocks")
		assert(n - length <= E2EE_PADDING_BLOCK, "expected at most one block of padding")
		assert(padded[length] == 0x80, "expected the 0x80 marker")
		unpadded, unpadErr := unpadPlaintext(padded[:n])
		assert(unpadErr == .None, fmt.tprintf("length %d: %v", length, unpadErr))
		assert(string(unpadded) == string(plaintext[:length]), "expected the plaintext back")
	}
	assert(paddedLength(255) == 256 && paddedLength(256) == 512, "expected the block edges")

	_, err := padPlaintext(plaintext[:10], padded[:255])
	assert(err == .BufferTooSmall, "expected BufferTooSmall")

	bad: [512]u8
	_, err = unpadPlaintext(bad[:])
	assert(err == .BadPadding, "expected all zeros to fail")
	_, err = unpadPlaintext(nil)
	assert(err == .BadPadding, "expected empty input to fail")
	bad[100] = 0x80
	_, err = unpadPlaintext(bad[:])
	assert(err == .BadPadding, "expected a marker outside the last block to fail")
	_, err = unpadPlaintext(bad[:300])
	assert(err == .BadPadding, "expected a length that is not a block multiple to fail")
	bad[511] = 0x01
	bad[400] = 0x80
	_, err = unpadPlaintext(bad[:])
	assert(err == .BadPadding, "expected a non-zero byte after the marker to fail")
	bad[511] = 0x80
	unpadded, unpadErr := unpadPlaintext(bad[:])
	assert(unpadErr == .None && len(unpadded) == 511, "expected the last 0x80 as the marker")
}

@(test)
testDirectMessagePlaintextCBOR :: proc(t: ^testing.T) {
	_ = t
	content: [CHAT_MESSAGE_MAX_BYTES + 1]u8
	for &value in content {
		value = 'x'
	}
	buffer: [DIRECT_MESSAGE_PLAINTEXT_MAX_SIZE + 1]u8
	// The plaintext without attachments (protocol 27 added the optional key).
	ContentOnly :: struct {
		content: string,
	}
	for length in ([?]int{1, 23, 24, 255, 256, CHAT_MESSAGE_MAX_BYTES}) {
		text := string(content[:length])
		n, ok := encodeSealedDirectMessagePlaintext(text, buffer[:])
		assert(ok, fmt.tprintf("expected %d bytes to encode", length))
		marshalled, marshalErr := cbor.marshal(ContentOnly{content = text})
		defer delete(marshalled)
		assert(marshalErr == nil, "expected core:encoding/cbor to encode")
		assert(
			string(buffer[:n]) == string(marshalled),
			fmt.tprintf("length %d: expected the canonical CBOR", length),
		)
		decoded, err := decodeSealedDirectMessagePlaintext(buffer[:n])
		defer SealedDirectMessagePlaintext_deinit(&decoded)
		assert(err == .None && decoded.content == text, "expected the content back")
	}
	_, ok := encodeSealedDirectMessagePlaintext("", buffer[:])
	assert(!ok, "expected empty content to be refused")
	_, ok = encodeSealedDirectMessagePlaintext(string(content[:]), buffer[:])
	assert(!ok, "expected CHAT_MESSAGE_MAX_BYTES + 1 to be refused")
	_, ok = encodeSealedDirectMessagePlaintext("\xff\xfe", buffer[:])
	assert(!ok, "expected invalid UTF-8 to be refused")
	_, ok = encodeSealedDirectMessagePlaintext("hello", buffer[:5])
	assert(!ok, "expected a short buffer to be refused")

	// Later fields are ignored by this decoder.
	Later :: struct {
		content: string,
		replyTo: int,
	}
	later, laterErr := cbor.marshal(Later{content = "with a reply", replyTo = 77})
	defer delete(later)
	assert(laterErr == nil, "expected the later plaintext to encode")
	decoded, err := decodeSealedDirectMessagePlaintext(later)
	defer SealedDirectMessagePlaintext_deinit(&decoded)
	assert(err == .None && decoded.content == "with a reply", "expected unknown keys ignored")

	empty, emptyErr := cbor.marshal(ContentOnly{})
	defer delete(empty)
	assert(emptyErr == nil, "expected the empty plaintext to encode")
	_, err = decodeSealedDirectMessagePlaintext(empty)
	assert(err == .BadPlaintext, "expected empty content to be refused")
	garbage := [?]u8{0xFF, 0x00, 0x13}
	_, err = decodeSealedDirectMessagePlaintext(garbage[:])
	assert(err == .BadPlaintext, "expected garbage to be refused")

	// The strict reader. "content" is 67 63 6F 6E 74 65 6E 74; 61 'a' is the text "a".
	accepted := [?][]u8 {
		// Unknown keys before content, with nested arrays, maps, tags, floats and simple values.
		{
			0xA3,
			0x62, 'r', 'e', 0x82, 0x01, 0xA1, 0x61, 'k', 0xC1, 0x1A, 0, 0, 0, 1,
			0x62, 'f', 'l', 0xFB, 0, 0, 0, 0, 0, 0, 0, 0,
			0x67, 'c', 'o', 'n', 't', 'e', 'n', 't', 0x61, 'a',
		},
		{0xA2, 0x67, 'c', 'o', 'n', 't', 'e', 'n', 't', 0x61, 'a', 0x61, 'z', 0xF5},
	}
	for data, index in accepted {
		decodedCase, caseErr := decodeSealedDirectMessagePlaintext(data)
		defer SealedDirectMessagePlaintext_deinit(&decodedCase)
		assert(caseErr == .None && decodedCase.content == "a", fmt.tprintf("case %d", index))
	}
	refused := [?][]u8 {
		// A repeated key.
		{
			0xA2,
			0x67, 'c', 'o', 'n', 't', 'e', 'n', 't', 0x61, 'a',
			0x67, 'c', 'o', 'n', 't', 'e', 'n', 't', 0x61, 'b',
		},
		// Trailing bytes after the map.
		{0xA1, 0x67, 'c', 'o', 'n', 't', 'e', 'n', 't', 0x61, 'a', 0x00},
		// An indefinite-length map, and an indefinite-length text.
		{0xBF, 0x67, 'c', 'o', 'n', 't', 'e', 'n', 't', 0x61, 'a', 0xFF},
		{0xA1, 0x67, 'c', 'o', 'n', 't', 'e', 'n', 't', 0x7F, 0x61, 'a', 0xFF},
		// content as bytes, and as an integer.
		{0xA1, 0x67, 'c', 'o', 'n', 't', 'e', 'n', 't', 0x41, 'a'},
		{0xA1, 0x67, 'c', 'o', 'n', 't', 'e', 'n', 't', 0x01},
		// No content, a non-text key, a short text, and an array at the top.
		{0xA1, 0x61, 'z', 0x61, 'a'},
		{0xA1, 0x01, 0x61, 'a'},
		{0xA1, 0x67, 'c', 'o', 'n', 't', 'e', 'n', 't', 0x62, 'a'},
		{0x81, 0x61, 'a'},
		// An unknown value nested past the depth limit, and a huge claimed array.
		{0xA1, 0x61, 'z', 0x81, 0x81, 0x81, 0x81, 0x81, 0x81, 0x81, 0x81, 0x81, 0x00},
		{0xA1, 0x61, 'z', 0x9B, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF},
		// More keys than CBOR_PLAINTEXT_MAX_KEYS.
		{0xB1},
		// A reserved additional-information value.
		{0xA1, 0x67, 'c', 'o', 'n', 't', 'e', 'n', 't', 0x7C},
	}
	for data, index in refused {
		_, caseErr := decodeSealedDirectMessagePlaintext(data)
		assert(caseErr == .BadPlaintext, fmt.tprintf("expected case %d refused", index))
	}
}

@(test)
testDirectMessageSealOpenAndServerCheck :: proc(t: ^testing.T) {
	_ = t
	fields := testDirectMessageFields()
	alice := testUser("alice", TEST_ALICE_ID)
	aliceKeys := testEncryptionKeyPair("alice")
	bobKeys := testEncryptionKeyPair("bob")
	carolKeys := testEncryptionKeyPair("carol")
	buffer: [SEALED_ENVELOPE_MAX_BYTES]u8

	n, err := sealDirectMessage(
		fields,
		"ünïcödé ✓",
		aliceKeys.publicKey,
		bobKeys.publicKey,
		alice.privateKey,
		buffer[:],
	)
	assert(err == .None, fmt.tprintf("expected the message to seal, got %v", err))
	assert(verifyDirectMessageEnvelope(buffer[:n], fields) == .None, "expected the server check")
	for reader in ([?]struct {
			id:   int,
			keys: EncryptionKeyPair,
		}{{TEST_ALICE_ID, aliceKeys}, {TEST_BOB_ID, bobKeys}}) {
		opened, openErr := openDirectMessage(buffer[:n], fields, reader.id, reader.keys)
		defer SealedDirectMessagePlaintext_deinit(&opened)
		assert(openErr == .None && opened.content == "ünïcödé ✓", "expected both sides to open")
	}
	_, err = openDirectMessage(buffer[:n], fields, TEST_CAROL_ID, carolKeys)
	assert(err == .NoWrapForRecipient, fmt.tprintf("expected no wrap for carol, got %v", err))

	// A DirectMessage envelope with a third wrap, or without the sender's, is refused by both
	// the server and the reader, even with a valid signature.
	aad := makeDirectMessageAAD(fields)
	plaintext: [DIRECT_MESSAGE_PLAINTEXT_MAX_SIZE]u8
	plaintextLength, _ := encodeSealedDirectMessagePlaintext("sneaky", plaintext[:])
	badSets := [2][]EnvelopeRecipient {
		{
			{TEST_ALICE_ID, aliceKeys.publicKey},
			{TEST_BOB_ID, bobKeys.publicKey},
			{TEST_CAROL_ID, carolKeys.publicKey},
		},
		{{TEST_BOB_ID, bobKeys.publicKey}, {TEST_CAROL_ID, carolKeys.publicKey}},
	}
	for recipients, index in badSets {
		n, err = sealEnvelope(
			.DirectMessage,
			aad[:],
			plaintext[:plaintextLength],
			recipients,
			alice.privateKey,
			buffer[:],
		)
		assert(err == .None, "expected the generic sealer to accept the set")
		serverErr := verifyDirectMessageEnvelope(buffer[:n], fields)
		assert(serverErr == .WrongRecipients, fmt.tprintf("set %d: %v", index, serverErr))
		_, openErr := openDirectMessage(buffer[:n], fields, TEST_BOB_ID, bobKeys)
		assert(openErr == .WrongRecipients, fmt.tprintf("set %d: %v", index, openErr))
	}

	toSelf := fields
	toSelf.recipientUserID = TEST_ALICE_ID
	_, err = sealDirectMessage(
		toSelf,
		"me",
		aliceKeys.publicKey,
		aliceKeys.publicKey,
		alice.privateKey,
		buffer[:],
	)
	assert(err == .DuplicateRecipient, fmt.tprintf("expected no message to self, got %v", err))
	_, err = sealDirectMessage(
		fields,
		"",
		aliceKeys.publicKey,
		bobKeys.publicKey,
		alice.privateKey,
		buffer[:],
	)
	assert(err == .BadPlaintext, fmt.tprintf("expected empty content refused, got %v", err))
}

@(test)
testPlaintextRoomMessageSignature :: proc(t: ^testing.T) {
	_ = t
	alice := testUser("alice", TEST_ALICE_ID)
	bob := testUser("bob", TEST_BOB_ID)
	label := testLabel("haychat-e2ee-test-room-plain-client-message-id")
	fields := PlaintextRoomMessageFields {
		serverIdentityPublicKey = testServerPublicKey(),
		roomID                  = TEST_ROOM_ID,
		senderUserID            = TEST_ALICE_ID,
	}
	copy(fields.clientMessageID[:], label[:CLIENT_MESSAGE_ID_SIZE])
	signature, ok := signPlaintextRoomMessage(fields, "room hello", alice.privateKey)
	assert(ok, "expected the room message to sign")
	assert(
		testHexEqual(signature[:], KAT_ROOM_PLAIN_SIGNATURE),
		"expected the vector signature",
	)
	assert(
		verifyPlaintextRoomMessage(fields, "room hello", alice.publicKey, signature),
		"expected the signature to verify",
	)
	changes: [4]PlaintextRoomMessageFields
	for &change in changes {
		change = fields
	}
	changes[0].serverIdentityPublicKey = bob.publicKey
	changes[1].roomID = TEST_ROOM_ID + 1
	changes[2].senderUserID = TEST_BOB_ID
	changes[3].clientMessageID[5] ~= 0x01
	for change, index in changes {
		assert(
			!verifyPlaintextRoomMessage(change, "room hello", alice.publicKey, signature),
			fmt.tprintf("expected changed field %d to fail", index),
		)
	}
	assert(
		!verifyPlaintextRoomMessage(fields, "room hellO", alice.publicKey, signature),
		"expected changed content to fail",
	)
	assert(
		!verifyPlaintextRoomMessage(fields, "room hello", bob.publicKey, signature),
		"expected another sender key to fail",
	)
	// A direct message's signature over the same bytes is not a room message's.
	directFields := PlaintextDirectMessageFields {
		serverIdentityPublicKey = fields.serverIdentityPublicKey,
		senderUserID            = TEST_ALICE_ID,
		recipientUserID         = TEST_ROOM_ID,
		clientMessageID         = fields.clientMessageID,
	}
	directSignature, directOK := signPlaintextDirectMessage(
		directFields,
		"room hello",
		alice.privateKey,
	)
	assert(directOK, "expected the direct message to sign")
	assert(
		!verifyPlaintextRoomMessage(fields, "room hello", alice.publicKey, directSignature),
		"expected a direct message signature refused",
	)
	unset := fields
	unset.clientMessageID = {}
	_, ok = signPlaintextRoomMessage(unset, "room hello", alice.privateKey)
	assert(!ok, "expected an unset client message ID to be refused")
	assert(
		!verifyPlaintextRoomMessage(unset, "room hello", alice.publicKey, signature),
		"expected an unset client message ID never to verify",
	)
	_, ok = signPlaintextRoomMessage(fields, "", alice.privateKey)
	assert(!ok, "expected empty content to be refused")
	long: [CHAT_MESSAGE_MAX_BYTES + 1]u8
	_, ok = signPlaintextRoomMessage(fields, string(long[:]), alice.privateKey)
	assert(!ok, "expected over-long content to be refused")
}

@(private = "file")
testPlaintextFields :: proc() -> PlaintextDirectMessageFields {
	label := testLabel("haychat-e2ee-test-plain-client-message-id")
	fields := PlaintextDirectMessageFields {
		serverIdentityPublicKey = testServerPublicKey(),
		senderUserID            = TEST_ALICE_ID,
		recipientUserID         = TEST_BOB_ID,
	}
	copy(fields.clientMessageID[:], label[:CLIENT_MESSAGE_ID_SIZE])
	return fields
}

@(test)
testPlaintextFallbackSignature :: proc(t: ^testing.T) {
	_ = t
	alice := testUser("alice", TEST_ALICE_ID)
	bob := testUser("bob", TEST_BOB_ID)
	fields := testPlaintextFields()
	signature, ok := signPlaintextDirectMessage(fields, "plain hello", alice.privateKey)
	assert(ok, "expected the fallback to sign")
	assert(testHexEqual(signature[:], KAT_PLAIN_SIGNATURE), "expected the vector signature")
	assert(
		verifyPlaintextDirectMessage(fields, "plain hello", alice.publicKey, signature),
		"expected the signature to verify",
	)

	changes: [4]PlaintextDirectMessageFields
	for &change in changes {
		change = fields
	}
	changes[0].serverIdentityPublicKey = bob.publicKey
	changes[1].senderUserID = TEST_CAROL_ID
	changes[2].recipientUserID = TEST_CAROL_ID
	changes[3].clientMessageID[3] ~= 0x10
	for change, index in changes {
		assert(
			!verifyPlaintextDirectMessage(change, "plain hello", alice.publicKey, signature),
			fmt.tprintf("expected changed field %d to fail", index),
		)
	}
	assert(
		!verifyPlaintextDirectMessage(fields, "plain hellO", alice.publicKey, signature),
		"expected changed content to fail",
	)
	assert(
		!verifyPlaintextDirectMessage(fields, "plain hello", bob.publicKey, signature),
		"expected another sender key to fail",
	)
	flipped := signature
	flipped[63] ~= 0x01
	assert(
		!verifyPlaintextDirectMessage(fields, "plain hello", alice.publicKey, flipped),
		"expected a flipped signature bit to fail",
	)
	_, ok = signPlaintextDirectMessage(fields, "", alice.privateKey)
	assert(!ok, "expected empty content to be refused")
	long: [CHAT_MESSAGE_MAX_BYTES + 1]u8
	_, ok = signPlaintextDirectMessage(fields, string(long[:]), alice.privateKey)
	assert(!ok, "expected over-long content to be refused")
	longest, longestOK := signPlaintextDirectMessage(
		fields,
		string(long[:CHAT_MESSAGE_MAX_BYTES]),
		alice.privateKey,
	)
	assert(longestOK, "expected CHAT_MESSAGE_MAX_BYTES of content to sign")
	assert(
		verifyPlaintextDirectMessage(
			fields,
			string(long[:CHAT_MESSAGE_MAX_BYTES]),
			alice.publicKey,
			longest,
		),
		"expected the longest message to verify",
	)
}

@(private = "file")
testChainKey0 :: proc() -> ChainKey {
	return ChainKey(testLabel("haychat-e2ee-test-chain-key-0"))
}

@(test)
testSenderChainVectors :: proc(t: ^testing.T) {
	_ = t
	chainKey0 := testChainKey0()
	messageKey0 := deriveSenderMessageKey(chainKey0)
	assert(testHexEqual(messageKey0[:], KAT_CHAIN_MESSAGE_KEY_0), "expected messageKey_0")
	chainKey1 := advanceSenderChainKey(chainKey0)
	assert(testHexEqual(chainKey1[:], KAT_CHAIN_KEY_1), "expected chainKey_1")
	expected := [?]struct {
		index: u32,
		hex:   string,
	}{{0, KAT_CHAIN_MESSAGE_KEY_0}, {1, KAT_CHAIN_MESSAGE_KEY_1}, {5, KAT_CHAIN_MESSAGE_KEY_5},
		{999, KAT_CHAIN_MESSAGE_KEY_999}}
	for vector in expected {
		key, ok := deriveSenderChainMessageKey(chainKey0, 0, vector.index)
		assert(ok, fmt.tprintf("expected index %d to derive", vector.index))
		assert(testHexEqual(key[:], vector.hex), fmt.tprintf("index %d vector", vector.index))
	}
	// From a later start: chainKey_1 at index 1 reaches index 5 too.
	key5, ok := deriveSenderChainMessageKey(chainKey1, 1, 5)
	assert(ok && testHexEqual(key5[:], KAT_CHAIN_MESSAGE_KEY_5), "expected a later start")
}

@(test)
testSenderChainRandomAccessEqualsStepping :: proc(t: ^testing.T) {
	_ = t
	chain := SenderChain {
		startKey   = testChainKey0(),
		currentKey = testChainKey0(),
		createdAt  = TEST_CREATED_AT,
	}
	stepped: [SENDER_CHAIN_MAX_MESSAGES]MessageKey
	for expectedIndex in 0 ..< SENDER_CHAIN_MAX_MESSAGES {
		index, key, ok := SenderChain_nextMessageKey(&chain)
		assert(ok && int(index) == expectedIndex, fmt.tprintf("step %d", expectedIndex))
		stepped[index] = key
	}
	_, _, ok := SenderChain_nextMessageKey(&chain)
	assert(!ok, "expected the chain to end after SENDER_CHAIN_MAX_MESSAGES")
	assert(SenderChain_needsReplacement(chain, TEST_CREATED_AT), "expected a used-up chain")

	samples := [?]u32{0, 1, 2, 7, 100, 499, 500, 998, 999}
	for index in samples {
		key, derived := deriveSenderChainMessageKey(testChainKey0(), 0, index)
		assert(derived && key == stepped[index], fmt.tprintf("index %d from chainKey_0", index))
	}
	// From a distribution that starts at index 10.
	chainKey10 := testChainKey0()
	for _ in 0 ..< 10 {
		chainKey10 = advanceSenderChainKey(chainKey10)
	}
	for index in u32(10) ..< 20 {
		key, derived := deriveSenderChainMessageKey(chainKey10, 10, index)
		assert(derived && key == stepped[index], fmt.tprintf("index %d from chainKey_10", index))
	}
	_, derivedOK := deriveSenderChainMessageKey(chainKey10, 10, 9)
	assert(!derivedOK, "expected an index before the start to be refused")
	_, derivedOK = deriveSenderChainMessageKey(testChainKey0(), 0, SENDER_CHAIN_MAX_MESSAGES)
	assert(!derivedOK, "expected the cap to be refused")

	fresh, created := SenderChain_create(TEST_CREATED_AT)
	defer SenderChain_wipe(&fresh)
	assert(created && fresh.startKey == fresh.currentKey, "expected a new chain at index 0")
	assert(fresh.chainID != ChainID{}, "expected a random chain ID")
	assert(!SenderChain_needsReplacement(fresh, TEST_CREATED_AT), "expected a fresh chain")
	assert(
		!SenderChain_needsReplacement(fresh, TEST_CREATED_AT + SENDER_CHAIN_MAX_AGE_SECONDS - 1),
		"expected a chain just under seven days old to be kept",
	)
	assert(
		SenderChain_needsReplacement(fresh, TEST_CREATED_AT + SENDER_CHAIN_MAX_AGE_SECONDS),
		"expected a seven-day-old chain to be replaced",
	)
	assert(SenderChain_needsReplacement(fresh, TEST_CREATED_AT - 1), "expected a clock jump")
}

@(private = "file")
testRoomContext :: proc() -> RoomMessageContext {
	label := testLabel("haychat-e2ee-test-room-client-message-id")
	roomContext := RoomMessageContext {
		serverIdentityPublicKey = testServerPublicKey(),
		roomID                  = TEST_ROOM_ID,
		senderUserID            = TEST_ALICE_ID,
	}
	copy(roomContext.clientMessageID[:], label[:CLIENT_MESSAGE_ID_SIZE])
	return roomContext
}

@(private = "file")
testRoomHeader :: proc() -> RoomMessageHeader {
	label := testLabel("haychat-e2ee-test-chain-id")
	header := RoomMessageHeader {
		epoch = 3,
		index = 5,
	}
	copy(header.chainID[:], label[:CHAIN_ID_SIZE])
	return header
}

@(private = "file")
testOpenRoomMessage :: proc(
	data: []u8,
	roomContext: RoomMessageContext,
	senderKey: IdentityPublicKeyBytes,
	messageKey: MessageKey,
) -> E2EEError {
	message, err := decodeSealedRoomMessage(data)
	if err != .None {
		return err
	}
	buffer: [SEALED_ROOM_MESSAGE_MAX_BYTES]u8
	_, err = openRoomMessage(message, roomContext, senderKey, messageKey, buffer[:])
	return err
}

@(test)
testRoomMessageVectorAndTampering :: proc(t: ^testing.T) {
	_ = t
	alice := testUser("alice", TEST_ALICE_ID)
	bob := testUser("bob", TEST_BOB_ID)
	roomContext := testRoomContext()
	header := testRoomHeader()
	messageKey, _ := deriveSenderChainMessageKey(testChainKey0(), 0, header.index)
	plaintext: [DIRECT_MESSAGE_PLAINTEXT_MAX_SIZE]u8
	plaintextLength, _ := encodeSealedDirectMessagePlaintext("hi room", plaintext[:])
	nonceLabel := testLabel("haychat-e2ee-test-room-nonce")
	nonce: E2EENonce
	copy(nonce[:], nonceLabel[:E2EE_NONCE_SIZE])

	buffer: [SEALED_ROOM_MESSAGE_MAX_BYTES]u8
	n, err := sealRoomMessageWithNonce(
		roomContext,
		header,
		messageKey,
		plaintext[:plaintextLength],
		alice.privateKey,
		nonce,
		buffer[:],
	)
	assert(err == .None, fmt.tprintf("expected the vector to seal, got %v", err))
	assert(testHexEqual(buffer[:n], KAT_ROOM_MESSAGE), fmt.tprintf("got %x", buffer[:n]))

	vectorBuffer: [SEALED_ROOM_MESSAGE_MAX_BYTES + 1]u8
	vector := testHex(KAT_ROOM_MESSAGE, vectorBuffer[:])
	message, decodeErr := decodeSealedRoomMessage(vector)
	assert(decodeErr == .None && message.header == header, "expected the vector header")
	opened: [SEALED_ROOM_MESSAGE_MAX_BYTES]u8
	result, openErr := openRoomMessage(message, roomContext, alice.publicKey, messageKey, opened[:])
	assert(openErr == .None, fmt.tprintf("expected the vector to open, got %v", openErr))
	decoded, plainErr := decodeSealedDirectMessagePlaintext(result)
	defer SealedDirectMessagePlaintext_deinit(&decoded)
	assert(plainErr == .None && decoded.content == "hi room", "expected the room plaintext")
	assert(
		verifyRoomMessageSignature(message, roomContext, alice.publicKey) == .None,
		"expected the server's signature check",
	)

	// Every flipped byte fails.
	for index in 0 ..< len(vector) {
		vector[index] ~= 0x02
		tamperErr := testOpenRoomMessage(vector, roomContext, alice.publicKey, messageKey)
		vector[index] ~= 0x02
		assert(tamperErr != .None, fmt.tprintf("byte %d opened", index))
	}
	// Every AAD field the reader supplies is bound.
	contexts: [4]RoomMessageContext
	for &changed in contexts {
		changed = roomContext
	}
	contexts[0].serverIdentityPublicKey = bob.publicKey
	contexts[1].roomID += 1
	contexts[2].senderUserID = TEST_BOB_ID
	contexts[3].clientMessageID[0] ~= 0x01
	for changed, index in contexts {
		changedErr := testOpenRoomMessage(vector, changed, alice.publicKey, messageKey)
		assert(changedErr == .BadSignature, fmt.tprintf("context %d: %v", index, changedErr))
	}
	// The epoch, chain and index travel in the message: changing them breaks the signature.
	for offset in ([?]int{1, 9, 25}) {
		vector[offset] ~= 0x01
		changedErr := testOpenRoomMessage(vector, roomContext, alice.publicKey, messageKey)
		vector[offset] ~= 0x01
		assert(changedErr == .BadSignature, fmt.tprintf("offset %d: %v", offset, changedErr))
	}
	wrongSigner := testOpenRoomMessage(vector, roomContext, bob.publicKey, messageKey)
	assert(wrongSigner == .BadSignature, "expected another member's key to fail")
	otherKey, _ := deriveSenderChainMessageKey(testChainKey0(), 0, header.index + 1)
	wrongKey := testOpenRoomMessage(vector, roomContext, alice.publicKey, otherKey)
	assert(wrongKey == .BadCiphertext, fmt.tprintf("expected BadCiphertext, got %v", wrongKey))

	// Structure.
	for length in 0 ..< len(vector) {
		_, lengthErr := decodeSealedRoomMessage(vector[:length])
		assert(lengthErr != .None, fmt.tprintf("expected %d bytes to be refused", length))
	}
	_, err = decodeSealedRoomMessage(vectorBuffer[:len(vector) + 1])
	assert(err == .TrailingBytes, fmt.tprintf("expected TrailingBytes, got %v", err))
	vector[0] = 2
	_, err = decodeSealedRoomMessage(vector)
	assert(err == .UnsupportedVersion, "expected version 2 to be refused")
	vector[0] = 1

	badHeader := header
	badHeader.index = SENDER_CHAIN_MAX_MESSAGES
	_, err = sealRoomMessage(roomContext, badHeader, messageKey, {'x'}, alice.privateKey, buffer[:])
	assert(err == .BadIndex, fmt.tprintf("expected BadIndex, got %v", err))
	badHeader = header
	badHeader.epoch = 0
	_, err = sealRoomMessage(roomContext, badHeader, messageKey, {'x'}, alice.privateKey, buffer[:])
	assert(err == .BadEpoch, fmt.tprintf("expected BadEpoch, got %v", err))
	endian.unchecked_put_u32le(vector[25:29], SENDER_CHAIN_MAX_MESSAGES)
	_, err = decodeSealedRoomMessage(vector)
	assert(err == .BadIndex, fmt.tprintf("expected a decoded BadIndex, got %v", err))
}

// A sender who signs a body without valid padding: the reader's strict unpad refuses it.
@(test)
testRoomMessageBadPaddingIsRefused :: proc(t: ^testing.T) {
	_ = t
	alice := testUser("alice", TEST_ALICE_ID)
	roomContext := testRoomContext()
	header := testRoomHeader()
	messageKey, _ := deriveSenderChainMessageKey(testChainKey0(), 0, header.index)
	aad := makeRoomMessageAAD(roomContext, header)

	data: [SEALED_ROOM_MESSAGE_HEADER_SIZE + 256 + E2EE_TAG_SIZE + AUTH_SIGNATURE_SIZE]u8
	data[0] = SEALED_ROOM_MESSAGE_VERSION
	endian.unchecked_put_u64le(data[1:9], u64(header.epoch))
	copy(data[9:25], header.chainID[:])
	endian.unchecked_put_u32le(data[25:29], header.index)
	endian.unchecked_put_u32le(data[53:57], 256 + E2EE_TAG_SIZE)
	body := data[57:57 + 256]
	for &value in body {
		value = 'A' // no 0x80 marker
	}
	ctx: chacha20poly1305.Context
	keyCopy := messageKey
	chacha20poly1305.init_xchacha(&ctx, keyCopy[:])
	chacha20poly1305.seal(&ctx, body, data[57 + 256:57 + 256 + 16], data[29:53], aad[:], body)
	chacha20poly1305.reset(&ctx)
	testResign(data[:], ROOM_MESSAGE_SIGNATURE_DOMAIN, aad[:], alice.privateKey)
	err := testOpenRoomMessage(data[:], roomContext, alice.publicKey, messageKey)
	assert(err == .BadPadding, fmt.tprintf("expected BadPadding, got %v", err))
}

@(test)
testSenderKeyDistribution :: proc(t: ^testing.T) {
	_ = t
	alice := testUser("alice", TEST_ALICE_ID)
	names := [3]string{"alice", "bob", "carol"}
	ids := [3]int{TEST_ALICE_ID, TEST_BOB_ID, TEST_CAROL_ID}
	recipients: [3]EnvelopeRecipient
	for name, index in names {
		recipients[index] = {ids[index], testEncryptionKeyPair(name).publicKey}
	}
	aadFields := RoomKeyAADFields {
		serverIdentityPublicKey = testServerPublicKey(),
		roomID                  = TEST_ROOM_ID,
		epoch                   = 4,
		senderUserID            = TEST_ALICE_ID,
		chainID                 = testRoomHeader().chainID,
	}
	chainKey := testChainKey0()
	buffer: [SEALED_ENVELOPE_MAX_BYTES]u8
	n, err := sealSenderKeyDistribution(
		aadFields,
		0,
		chainKey,
		recipients[:],
		alice.privateKey,
		buffer[:],
	)
	assert(err == .None, fmt.tprintf("expected the distribution to seal, got %v", err))
	for name, index in names {
		distribution, openErr := openSenderKeyDistribution(
			buffer[:n],
			aadFields,
			alice.publicKey,
			ids[index],
			testEncryptionKeyPair(name),
		)
		assert(openErr == .None, fmt.tprintf("%s: %v", name, openErr))
		assert(distribution.chainKey == chainKey && distribution.startIndex == 0, "chain key")
		assert(distribution.epoch == 4 && distribution.roomID == TEST_ROOM_ID, "room and epoch")
	}
	_, err = openSenderKeyDistribution(
		buffer[:n],
		aadFields,
		alice.publicKey,
		TEST_DAVE_ID,
		testEncryptionKeyPair("dave"),
	)
	assert(err == .NoWrapForRecipient, fmt.tprintf("expected no wrap for dave, got %v", err))

	// Each AAD field: room, epoch, sender, chain, server.
	changes: [5]RoomKeyAADFields
	for &change in changes {
		change = aadFields
	}
	changes[0].roomID += 1
	changes[1].epoch += 1
	changes[2].senderUserID = TEST_BOB_ID
	changes[3].chainID[2] ~= 0x01
	changes[4].serverIdentityPublicKey = alice.publicKey
	for change, index in changes {
		_, changeErr := openSenderKeyDistribution(
			buffer[:n],
			change,
			alice.publicKey,
			TEST_BOB_ID,
			testEncryptionKeyPair("bob"),
		)
		assert(changeErr == .BadSignature, fmt.tprintf("AAD change %d: %v", index, changeErr))
	}

	// A distribution whose plaintext names another epoch than its AAD.
	plaintext: [SENDER_KEY_DISTRIBUTION_SIZE]u8
	_, err = encodeSenderKeyDistribution(
		{roomID = TEST_ROOM_ID, epoch = 5, chainID = aadFields.chainID, chainKey = chainKey},
		plaintext[:],
	)
	assert(err == .None, "expected the plaintext to encode")
	aad := makeRoomKeyAAD(aadFields)
	n, err = sealEnvelope(
		.SenderKey,
		aad[:],
		plaintext[:],
		recipients[:],
		alice.privateKey,
		buffer[:],
	)
	assert(err == .None, "expected the mismatched envelope to seal")
	_, err = openSenderKeyDistribution(
		buffer[:n],
		aadFields,
		alice.publicKey,
		TEST_BOB_ID,
		testEncryptionKeyPair("bob"),
	)
	assert(err == .MismatchedKeyDistribution, fmt.tprintf("expected a mismatch, got %v", err))

	// The same AAD under the wrong envelope kind.
	n, err = sealEnvelope(
		.RoomKeyForward,
		aad[:],
		plaintext[:],
		recipients[:],
		alice.privateKey,
		buffer[:],
	)
	assert(err == .None, "expected the forward envelope to seal")
	_, err = openSenderKeyDistribution(
		buffer[:n],
		aadFields,
		alice.publicKey,
		TEST_BOB_ID,
		testEncryptionKeyPair("bob"),
	)
	assert(err == .WrongKind, fmt.tprintf("expected WrongKind, got %v", err))

	// The plaintext layout's own checks.
	encoded: [SENDER_KEY_DISTRIBUTION_SIZE + 1]u8
	distribution := SenderKeyDistribution {
		roomID     = TEST_ROOM_ID,
		epoch      = 4,
		startIndex = 12,
		chainKey   = chainKey,
	}
	_, err = encodeSenderKeyDistribution(distribution, encoded[:])
	assert(err == .None, "expected the distribution to encode")
	decoded, decodeErr := decodeSenderKeyDistribution(encoded[:SENDER_KEY_DISTRIBUTION_SIZE])
	assert(decodeErr == .None && decoded == distribution, "expected a round trip")
	_, decodeErr = decodeSenderKeyDistribution(encoded[:])
	assert(decodeErr == .TrailingBytes, "expected TrailingBytes")
	_, decodeErr = decodeSenderKeyDistribution(encoded[:SENDER_KEY_DISTRIBUTION_SIZE - 1])
	assert(decodeErr == .Truncated, "expected Truncated")
	encoded[0] = 2
	_, decodeErr = decodeSenderKeyDistribution(encoded[:SENDER_KEY_DISTRIBUTION_SIZE])
	assert(decodeErr == .UnsupportedVersion, "expected UnsupportedVersion")
	invalid := distribution
	invalid.startIndex = SENDER_CHAIN_MAX_MESSAGES
	_, err = encodeSenderKeyDistribution(invalid, encoded[:])
	assert(err == .BadIndex, "expected BadIndex")
	invalid = distribution
	invalid.epoch = 0
	_, err = encodeSenderKeyDistribution(invalid, encoded[:])
	assert(err == .BadEpoch, "expected BadEpoch")
	invalid = distribution
	invalid.roomID = -1
	_, err = encodeSenderKeyDistribution(invalid, encoded[:])
	assert(err == .BadRoomID, "expected BadRoomID")
}

@(private = "file")
testForwardFields :: proc() -> RoomKeyForwardAADFields {
	return RoomKeyForwardAADFields {
		serverIdentityPublicKey = testServerPublicKey(),
		roomID = TEST_ROOM_ID,
		epoch = 3,
		senderUserID = TEST_ALICE_ID,
		chainID = testRoomHeader().chainID,
		forwarderUserID = TEST_BOB_ID,
		recipientUserID = TEST_CAROL_ID,
	}
}

// The KAT_ROOM_KEY_FORWARD envelope, sealed with the vector's fixed randomness.
@(private = "file")
testSealVectorForward :: proc(dst: []u8) -> []u8 {
	bob := testUser("bob", TEST_BOB_ID)
	fields := testForwardFields()
	plaintext: [SENDER_KEY_DISTRIBUTION_SIZE]u8
	_, encodeErr := encodeSenderKeyDistribution(
		{
			roomID = fields.roomID,
			epoch = fields.epoch,
			chainID = fields.chainID,
			chainKey = testChainKey0(),
		},
		plaintext[:],
	)
	assert(encodeErr == .None, "expected the forward plaintext to encode")
	aad := makeRoomKeyForwardAAD(fields)
	recipients := [1]EnvelopeRecipient{{TEST_CAROL_ID, testEncryptionKeyPair("carol").publicKey}}
	nonceLabel := testLabel("haychat-e2ee-test-forward-nonce")
	nonce: E2EENonce
	copy(nonce[:], nonceLabel[:E2EE_NONCE_SIZE])
	n, err := sealEnvelopeWithRandomness(
		.RoomKeyForward,
		aad[:],
		plaintext[:],
		recipients[:],
		bob.privateKey,
		MessageKey(testLabel("haychat-e2ee-test-forward-message-key")),
		EncryptionPrivateKeyBytes(testLabel("haychat-e2ee-test-forward-ephemeral")),
		nonce,
		dst,
	)
	assert(err == .None, fmt.tprintf("expected the vector forward to seal, got %v", err))
	return dst[:n]
}

@(test)
testRoomKeyForwardVectorAndRoundTrip :: proc(t: ^testing.T) {
	_ = t
	bob := testUser("bob", TEST_BOB_ID)
	carolKeys := testEncryptionKeyPair("carol")
	fields := testForwardFields()
	buffer: [SEALED_ENVELOPE_MAX_BYTES]u8
	vector := testSealVectorForward(buffer[:])
	assert(testHexEqual(vector, KAT_ROOM_KEY_FORWARD), "expected the forward vector bytes")
	kat: [SEALED_ENVELOPE_MAX_BYTES]u8
	katBytes := testHex(KAT_ROOM_KEY_FORWARD, kat[:])
	distribution, err := openRoomKeyForward(katBytes, fields, bob.publicKey, carolKeys)
	assert(err == .None, fmt.tprintf("expected carol to open the vector forward, got %v", err))
	assert(distribution.chainKey == testChainKey0(), "expected the forwarded chain key")
	assert(distribution.startIndex == 0 && distribution.epoch == 3, "expected index and epoch")
	decoded, decodeErr := decodeSealedEnvelope(katBytes)
	assert(decodeErr == .None && decoded.kind == .RoomKeyForward, "expected a forward kind")
	assert(
		verifyRoomKeyForwardEnvelope(decoded, fields, bob.publicKey) == .None,
		"expected the server's check to accept the forward",
	)

	// A fresh forward from a later start, through the public sealing procedure.
	chainKey := advanceSenderChainKey(testChainKey0())
	n, sealErr := sealRoomKeyForward(
		fields,
		1,
		chainKey,
		carolKeys.publicKey,
		bob.privateKey,
		buffer[:],
	)
	assert(sealErr == .None, fmt.tprintf("expected the forward to seal, got %v", sealErr))
	distribution, err = openRoomKeyForward(buffer[:n], fields, bob.publicKey, carolKeys)
	assert(err == .None && distribution.startIndex == 1, "expected the start index to travel")
	assert(distribution.chainKey == chainKey, "expected the chain key at index 1")

	// Nobody but the recipient opens it, even with the right AAD for themselves.
	daveFields := fields
	daveFields.recipientUserID = TEST_DAVE_ID
	daveKeys := testEncryptionKeyPair("dave")
	_, err = openRoomKeyForward(buffer[:n], daveFields, bob.publicKey, daveKeys)
	assert(err == .BadSignature, fmt.tprintf("expected dave's AAD to fail, got %v", err))
	_, err = openRoomKeyForward(buffer[:n], fields, bob.publicKey, daveKeys)
	assert(err == .BadWrap, fmt.tprintf("expected dave's key to fail the wrap, got %v", err))

	// The field rules: a forwarder is never the sender, nor the recipient.
	carolPublic := carolKeys.publicKey
	bad := fields
	bad.forwarderUserID = TEST_ALICE_ID
	_, sealErr = sealRoomKeyForward(bad, 0, chainKey, carolPublic, bob.privateKey, buffer[:])
	assert(sealErr == .BadForwarderUserID, fmt.tprintf("sender as forwarder: %v", sealErr))
	bad = fields
	bad.forwarderUserID = 0
	_, sealErr = sealRoomKeyForward(bad, 0, chainKey, carolPublic, bob.privateKey, buffer[:])
	assert(sealErr == .BadForwarderUserID, fmt.tprintf("no forwarder: %v", sealErr))
	bad = fields
	bad.recipientUserID = TEST_BOB_ID
	_, sealErr = sealRoomKeyForward(bad, 0, chainKey, carolPublic, bob.privateKey, buffer[:])
	assert(sealErr == .DuplicateRecipient, fmt.tprintf("forward to self: %v", sealErr))
	bad = fields
	bad.epoch = 0
	_, sealErr = sealRoomKeyForward(bad, 0, chainKey, carolPublic, bob.privateKey, buffer[:])
	assert(sealErr == .BadEpoch, fmt.tprintf("epoch 0: %v", sealErr))
	_, sealErr = sealRoomKeyForward(
		fields,
		0,
		chainKey,
		carolKeys.publicKey,
		testUser("dave", TEST_DAVE_ID).privateKey,
		buffer[:],
	)
	assert(sealErr == .None, "a forward signed by anyone seals; the opener's pin decides")
}

@(test)
testRoomKeyForwardTamperingFails :: proc(t: ^testing.T) {
	_ = t
	alice := testUser("alice", TEST_ALICE_ID)
	bob := testUser("bob", TEST_BOB_ID)
	carolKeys := testEncryptionKeyPair("carol")
	fields := testForwardFields()
	buffer: [SEALED_ENVELOPE_MAX_BYTES]u8
	vector := testSealVectorForward(buffer[:])

	// Each AAD field: server, room, epoch, original sender, chain, forwarder, recipient.
	changes: [7]RoomKeyForwardAADFields
	for &change in changes {
		change = fields
	}
	changes[0].serverIdentityPublicKey = alice.publicKey
	changes[1].roomID += 1
	changes[2].epoch += 1
	changes[3].senderUserID = TEST_DAVE_ID
	changes[4].chainID[5] ~= 0x01
	changes[5].forwarderUserID = TEST_DAVE_ID
	changes[6].recipientUserID = TEST_ERIN_ID
	for change, index in changes {
		_, err := openRoomKeyForward(vector, change, bob.publicKey, carolKeys)
		assert(err == .BadSignature, fmt.tprintf("forward AAD change %d: %v", index, err))
	}

	// The wrong forwarder key: the forward is bob's, presented as dave's or checked as alice's.
	_, err := openRoomKeyForward(vector, fields, alice.publicKey, carolKeys)
	assert(err == .BadSignature, fmt.tprintf("expected another forwarder key to fail, got %v", err))
	decoded, _ := decodeSealedEnvelope(vector)
	assert(
		verifyRoomKeyForwardEnvelope(decoded, fields, alice.publicKey) == .BadSignature,
		"expected the server's check to refuse another forwarder key",
	)

	// A flipped bit anywhere in the envelope.
	for offset in 0 ..< len(vector) {
		vector[offset] ~= 0x10
		_, flipErr := openRoomKeyForward(vector, fields, bob.publicKey, carolKeys)
		assert(flipErr != .None, fmt.tprintf("expected a flipped bit at %d to fail", offset))
		vector[offset] ~= 0x10
	}

	// A forward presented as a SenderKey distribution: the kind and the AAD differ.
	roomKeyFields := RoomKeyAADFields {
		serverIdentityPublicKey = fields.serverIdentityPublicKey,
		roomID                  = fields.roomID,
		epoch                   = fields.epoch,
		senderUserID            = TEST_BOB_ID,
		chainID                 = fields.chainID,
	}
	_, err = openSenderKeyDistribution(
		vector,
		roomKeyFields,
		bob.publicKey,
		TEST_CAROL_ID,
		carolKeys,
	)
	assert(err == .BadSignature, fmt.tprintf("forward as a SenderKey: %v", err))
	// Re-signed by bob over the SenderKey AAD, the kind still gives it away.
	forwardCopy: [SEALED_ENVELOPE_MAX_BYTES]u8
	copy(forwardCopy[:], vector)
	resigned := forwardCopy[:len(vector)]
	roomKeyAAD := makeRoomKeyAAD(roomKeyFields)
	testResign(resigned, ENVELOPE_SIGNATURE_DOMAIN, roomKeyAAD[:], bob.privateKey)
	_, err = openSenderKeyDistribution(
		resigned,
		roomKeyFields,
		bob.publicKey,
		TEST_CAROL_ID,
		carolKeys,
	)
	assert(err == .WrongKind, fmt.tprintf("re-signed forward as a SenderKey: %v", err))

	// And a SenderKey distribution presented as a forward, as is and re-signed.
	recipients := [1]EnvelopeRecipient{{TEST_CAROL_ID, carolKeys.publicKey}}
	senderKeyFields := roomKeyFields
	senderKeyFields.senderUserID = TEST_ALICE_ID
	other: [SEALED_ENVELOPE_MAX_BYTES]u8
	n, sealErr := sealSenderKeyDistribution(
		senderKeyFields,
		0,
		testChainKey0(),
		recipients[:],
		alice.privateKey,
		other[:],
	)
	assert(sealErr == .None, "expected the distribution to seal")
	aliceForwardFields := fields
	aliceForwardFields.forwarderUserID = TEST_BOB_ID
	_, err = openRoomKeyForward(other[:n], aliceForwardFields, alice.publicKey, carolKeys)
	assert(err == .BadSignature, fmt.tprintf("SenderKey as a forward: %v", err))
	forwardAAD := makeRoomKeyForwardAAD(fields)
	testResign(other[:n], ENVELOPE_SIGNATURE_DOMAIN, forwardAAD[:], bob.privateKey)
	_, err = openRoomKeyForward(other[:n], fields, bob.publicKey, carolKeys)
	assert(err == .WrongKind, fmt.tprintf("re-signed SenderKey as a forward: %v", err))

	// Two wraps, both carol's and bob's, signed by bob: refused, a forward has one recipient.
	twoRecipients := [2]EnvelopeRecipient {
		{TEST_CAROL_ID, carolKeys.publicKey},
		{TEST_BOB_ID, testEncryptionKeyPair("bob").publicKey},
	}
	plaintext: [SENDER_KEY_DISTRIBUTION_SIZE]u8
	_, _ = encodeSenderKeyDistribution(
		{roomID = fields.roomID, epoch = fields.epoch, chainID = fields.chainID},
		plaintext[:],
	)
	n, sealErr = sealEnvelope(
		.RoomKeyForward,
		forwardAAD[:],
		plaintext[:],
		twoRecipients[:],
		bob.privateKey,
		other[:],
	)
	assert(sealErr == .None, "expected the two-wrap forward to seal")
	_, err = openRoomKeyForward(other[:n], fields, bob.publicKey, carolKeys)
	assert(err == .WrongRecipients, fmt.tprintf("two-wrap forward: %v", err))

	// A plaintext naming another epoch than the AAD.
	_, _ = encodeSenderKeyDistribution(
		{roomID = fields.roomID, epoch = fields.epoch + 1, chainID = fields.chainID},
		plaintext[:],
	)
	n, sealErr = sealEnvelope(
		.RoomKeyForward,
		forwardAAD[:],
		plaintext[:],
		recipients[:],
		bob.privateKey,
		other[:],
	)
	assert(sealErr == .None, "expected the mismatched forward to seal")
	_, err = openRoomKeyForward(other[:n], fields, bob.publicKey, carolKeys)
	assert(err == .MismatchedKeyDistribution, fmt.tprintf("mismatched forward: %v", err))
}

@(test)
testSafetyNumber :: proc(t: ^testing.T) {
	_ = t
	alice := testUser("alice", TEST_ALICE_ID)
	bob := testUser("bob", TEST_BOB_ID)
	carol := testUser("carol", TEST_CAROL_ID)
	aliceBob := computeSafetyNumber(alice.publicKey, bob.publicKey)
	assert(aliceBob == computeSafetyNumber(bob.publicKey, alice.publicKey), "expected symmetry")
	text := formatSafetyNumber(aliceBob)
	assert(string(text[:]) == KAT_SAFETY_NUMBER, fmt.tprintf("got %s", string(text[:])))
	assert(aliceBob != computeSafetyNumber(alice.publicKey, carol.publicKey), "expected a pair")
	for group in aliceBob {
		assert(group < 100_000, "expected five-digit groups")
	}
	small := SafetyNumber{0, 1, 12, 123, 1234, 12345, 99999, 0, 0, 0, 0, 7}
	smallText := formatSafetyNumber(small)
	assert(
		string(smallText[:]) ==
		"00000 00001 00012 00123 01234 12345 99999 00000 00000 00000 00000 00007",
		fmt.tprintf("expected zero-padded groups, got %s", string(smallText[:])),
	)
}

// ---------------------------------------------------------------------------------------------
// Member log.

// A log under construction: entries is every accepted entry's bytes (owned), state the state
// they prove. pins answers lookups for the replay context.
@(private = "file")
TestRoomLog :: struct {
	state:   RoomLogState,
	entries: [dynamic][]u8,
	pins:    map[int]IdentityPublicKeyBytes,
}

@(private = "file")
testRoomLogPinLookup :: proc(userData: rawptr, userID: int) -> (IdentityPublicKeyBytes, bool) {
	log := (^TestRoomLog)(userData)
	key, found := log.pins[userID]
	return key, found
}

@(private = "file")
testRoomLogContext :: proc(log: ^TestRoomLog) -> RoomLogContext {
	return RoomLogContext {
		serverIdentityPublicKey = testServerPublicKey(),
		lookupPin = testRoomLogPinLookup,
		pinUserData = log,
	}
}

@(private = "file")
testRoomLogMake :: proc() -> TestRoomLog {
	return TestRoomLog{state = RoomLogState_init(TEST_ROOM_ID)}
}

@(private = "file")
testRoomLogDestroy :: proc(log: ^TestRoomLog) {
	for entry in log.entries {
		delete(entry)
	}
	delete(log.entries)
	delete(log.pins)
	RoomLogState_deinit(&log.state)
}

// The next entry for log: version and prevHash from its head.
@(private = "file")
testRoomLogNext :: proc(
	log: ^TestRoomLog,
	action: RoomLogAction,
	target: TestUser,
	actor: TestUser,
) -> RoomLogEntry {
	return RoomLogEntry {
		roomID = TEST_ROOM_ID,
		version = log.state.version + 1,
		prevHash = log.state.headHash,
		action = action,
		targetUserID = target.id,
		targetIdentityKey = target.publicKey,
		actorUserID = actor.id,
		createdAt = TEST_CREATED_AT + u64(log.state.version),
	}
}

// Signs entry as signer (none for a zero signer), encodes it into a new allocation.
@(private = "file")
testRoomLogEncode :: proc(entry: RoomLogEntry, signer: TestUser) -> []u8 {
	entry := entry
	if signer.id != 0 {
		err := signRoomLogEntry(&entry, testServerPublicKey(), signer.privateKey)
		assert(err == .None, fmt.tprintf("expected the entry to sign, got %v", err))
	}
	buffer: [ROOM_LOG_ENTRY_MAX_BYTES]u8
	n, err := encodeRoomLogEntry(entry, buffer[:])
	assert(err == .None, fmt.tprintf("expected the entry to encode, got %v", err))
	return clone_bytes(buffer[:n])
}

// Applies data to log; keeps it on success, frees it otherwise. Returns the apply result.
@(private = "file")
testRoomLogApply :: proc(log: ^TestRoomLog, data: []u8) -> RoomLogError {
	_, err := RoomLogState_apply(&log.state, data, testRoomLogContext(log))
	if err != .None {
		delete(data)
		return err
	}
	append(&log.entries, data)
	return .None
}

@(private = "file")
testRoomLogTry :: proc(
	log: ^TestRoomLog,
	action: RoomLogAction,
	target: TestUser,
	actor: TestUser,
) -> RoomLogError {
	entry := testRoomLogNext(log, action, target, actor)
	if action == .SetAccess {
		entry.targetUserID = 0
		entry.targetIdentityKey = {}
		entry.settings = {
			access            = log.state.access == .AdminInvite ? .MemberInvite : .AdminInvite,
			historyVisibility = log.state.historyVisibility,
		}
	}
	return testRoomLogApply(log, testRoomLogEncode(entry, actor))
}

@(private = "file")
clone_bytes :: proc(data: []u8) -> []u8 {
	copied := make([]u8, len(data))
	copy(copied, data)
	return copied
}

// Creates the room as alice with managers alice and carol (carol not a member).
@(private = "file")
testRoomLogCreate :: proc(
	log: ^TestRoomLog,
	access: RoomLogAccess,
	creatorJoins := true,
) -> RoomLogError {
	alice := testUser("alice", TEST_ALICE_ID)
	carol := testUser("carol", TEST_CAROL_ID)
	managers := [2]RoomLogManager{{alice.id, alice.publicKey}, {carol.id, carol.publicKey}}
	entry := testRoomLogNext(log, .Create, alice, alice)
	entry.createdAt = TEST_CREATED_AT
	entry.settings = {
		access            = access,
		historyVisibility = .Full,
		creatorJoins      = creatorJoins,
		managers          = managers[:],
	}
	return testRoomLogApply(log, testRoomLogEncode(entry, alice))
}

@(test)
testRoomLogCreateVector :: proc(t: ^testing.T) {
	_ = t
	log := testRoomLogMake()
	defer testRoomLogDestroy(&log)
	err := testRoomLogCreate(&log, .AdminInvite)
	assert(err == .None, fmt.tprintf("expected the Create to apply, got %v", err))
	assert(testHexEqual(log.entries[0], KAT_ROOM_LOG_CREATE), fmt.tprintf("%x", log.entries[0]))
	hash := hashRoomLogEntry(log.entries[0])
	assert(testHexEqual(hash[:], KAT_ROOM_LOG_CREATE_HASH), "expected the vector hash")
	assert(log.state.headHash == hash && log.state.version == 1, "expected the head")
	assert(log.state.access == .AdminInvite && log.state.historyVisibility == .Full, "settings")
	assert(len(log.state.members) == 1 && RoomLogState_isMember(log.state, TEST_ALICE_ID), "alice")
	assert(RoomLogState_isManager(log.state, TEST_CAROL_ID), "expected carol as a manager")
	assert(!RoomLogState_isMember(log.state, TEST_CAROL_ID), "expected carol not a member")
	assert(len(log.state.identities) == 2, "expected two named identities")

	// The Python bytes decode to the same fields and replay to the same state.
	vectorBuffer: [ROOM_LOG_ENTRY_MAX_BYTES]u8
	vector := testHex(KAT_ROOM_LOG_CREATE, vectorBuffer[:])
	managers: [ROOM_LOG_MANAGERS_MAX]RoomLogManager
	entry, decodeErr := decodeRoomLogEntry(vector, managers[:])
	assert(decodeErr == .None, fmt.tprintf("expected the vector to decode, got %v", decodeErr))
	assert(entry.action == .Create && len(entry.settings.managers) == 2, "expected the Create")
	assert(entry.settings.creatorJoins, "expected creatorJoins")
	entries := [1][]u8{vector}
	state, replayErr, _ := replayRoomLog(TEST_ROOM_ID, entries[:], testRoomLogContext(&log))
	defer RoomLogState_deinit(&state)
	assert(replayErr == .None && state.headHash == hash, "expected the vector to replay")

	// Every flipped byte is refused.
	for index in 0 ..< len(vector) {
		vector[index] ~= 0x01
		fresh := RoomLogState_init(TEST_ROOM_ID)
		_, tamperErr := RoomLogState_apply(&fresh, vector, testRoomLogContext(&log))
		RoomLogState_deinit(&fresh)
		vector[index] ~= 0x01
		assert(tamperErr != .None, fmt.tprintf("byte %d applied", index))
	}
}

@(test)
testRoomLogValidChainAndReplay :: proc(t: ^testing.T) {
	_ = t
	alice := testUser("alice", TEST_ALICE_ID)
	bob := testUser("bob", TEST_BOB_ID)
	carol := testUser("carol", TEST_CAROL_ID)
	dave := testUser("dave", TEST_DAVE_ID)
	erin := testUser("erin", TEST_ERIN_ID)
	server := TestUser{}
	log := testRoomLogMake()
	defer testRoomLogDestroy(&log)

	steps := [?]struct {
		action: RoomLogAction,
		target: TestUser,
		actor:  TestUser,
	} {
		{.Add, bob, alice}, // a manager who is a member adds
		{.Add, dave, carol}, // a manager who is not a member adds
		{.Remove, bob, server}, // the server removes on its own
		{.Leave, dave, dave},
		{.AddManager, erin, alice},
		{.RemoveManager, carol, erin}, // a new manager removes an old one
		{.SetAccess, {}, alice}, // to Member invite
		{.Add, erin, alice}, // a manager adds themselves
		{.Add, bob, erin}, // a member invites in a Member invite room
		{.Remove, erin, alice}, // a manager removes a member (even a manager)
	}
	assert(testRoomLogCreate(&log, .AdminInvite) == .None, "expected the Create")
	for step, index in steps {
		err := testRoomLogTry(&log, step.action, step.target, step.actor)
		assert(err == .None, fmt.tprintf("step %d (%v): %v", index, step.action, err))
	}
	state := &log.state
	assert(state.version == len(steps) + 1, "expected one version per entry")
	assert(state.access == .MemberInvite, "expected Member invite after SetAccess")
	assert(len(state.members) == 2, fmt.tprintf("members: %v", state.members))
	assert(RoomLogState_isMember(state^, TEST_ALICE_ID), "expected alice")
	assert(RoomLogState_isMember(state^, TEST_BOB_ID), "expected bob")
	assert(len(state.managers) == 2, fmt.tprintf("managers: %v", state.managers))
	assert(RoomLogState_isManager(state^, TEST_ERIN_ID), "expected erin as manager")
	assert(!RoomLogState_isManager(state^, TEST_CAROL_ID), "expected carol removed")
	assert(len(state.identities) == 5, "expected every named user")

	// The whole log replays to the same head, with or without a known head on the way.
	ctx := testRoomLogContext(&log)
	head := RoomLogState_head(state^)
	replayed, err, _ := replayRoomLog(TEST_ROOM_ID, log.entries[:], ctx)
	defer RoomLogState_deinit(&replayed)
	assert(err == .None && RoomLogState_head(replayed) == head, "expected the same head")
	assert(len(replayed.members) == 2 && len(replayed.managers) == 2, "expected the same state")
	middle := RoomLogHead {
		version = 4,
		hash    = hashRoomLogEntry(log.entries[3]),
	}
	again, againErr, _ := replayRoomLog(TEST_ROOM_ID, log.entries[:], ctx, middle)
	defer RoomLogState_deinit(&again)
	assert(againErr == .None, fmt.tprintf("expected a known head to pass, got %v", againErr))

	// Validate checks without applying.
	next := testRoomLogEncode(testRoomLogNext(&log, .Add, carol, alice), alice)
	defer delete(next)
	_, validateErr := RoomLogState_validate(&log.state, next, ctx)
	assert(validateErr == .None && log.state.version == head.version, "expected no change")
	// A duplicate of the head is refused (the caller compares hashes to tell it from a fork).
	_, duplicateErr := RoomLogState_apply(&log.state, log.entries[len(log.entries) - 1], ctx)
	assert(duplicateErr == .VersionNotNext, "expected a duplicate to be refused")
}

@(test)
testRoomLogAuthorization :: proc(t: ^testing.T) {
	_ = t
	alice := testUser("alice", TEST_ALICE_ID)
	bob := testUser("bob", TEST_BOB_ID)
	carol := testUser("carol", TEST_CAROL_ID)
	dave := testUser("dave", TEST_DAVE_ID)
	erin := testUser("erin", TEST_ERIN_ID)

	{
		// Admin invite: only managers add.
		log := testRoomLogMake()
		defer testRoomLogDestroy(&log)
		assert(testRoomLogCreate(&log, .AdminInvite) == .None, "expected the Create")
		assert(testRoomLogTry(&log, .Add, bob, alice) == .None, "expected alice to add bob")
		err := testRoomLogTry(&log, .Add, dave, bob)
		assert(err == .NotAuthorized, fmt.tprintf("member add in Admin invite: %v", err))
		err = testRoomLogTry(&log, .Add, dave, dave)
		assert(err == .NotAuthorized, fmt.tprintf("outsider add: %v", err))
		err = testRoomLogTry(&log, .Add, bob, alice)
		assert(err == .AlreadyMember, fmt.tprintf("double add: %v", err))
		err = testRoomLogTry(&log, .SetAccess, {}, bob)
		assert(err == .NotAuthorized, fmt.tprintf("SetAccess by a member: %v", err))
		err = testRoomLogTry(&log, .AddManager, bob, bob)
		assert(err == .NotAuthorized, fmt.tprintf("AddManager by a member: %v", err))
		err = testRoomLogTry(&log, .AddManager, carol, alice)
		assert(err == .AlreadyManager, fmt.tprintf("AddManager of a manager: %v", err))
		err = testRoomLogTry(&log, .RemoveManager, alice, bob)
		assert(err == .NotAuthorized, fmt.tprintf("RemoveManager by a member: %v", err))
		err = testRoomLogTry(&log, .RemoveManager, bob, alice)
		assert(err == .NotManager, fmt.tprintf("RemoveManager of a member: %v", err))
		err = testRoomLogTry(&log, .Remove, alice, bob)
		assert(err == .NotAuthorized, fmt.tprintf("Remove by a member: %v", err))
		err = testRoomLogTry(&log, .Remove, dave, alice)
		assert(err == .NotMember, fmt.tprintf("Remove of a non-member: %v", err))
		err = testRoomLogTry(&log, .Leave, bob, alice)
		assert(err == .LeaveNotSelf, fmt.tprintf("Leave signed by another: %v", err))
		err = testRoomLogTry(&log, .Leave, dave, dave)
		assert(err == .NotMember, fmt.tprintf("Leave of a non-member: %v", err))
		// Managers who are not members do count as signers.
		assert(testRoomLogTry(&log, .Add, erin, carol) == .None, "expected carol to add erin")
		assert(testRoomLogTry(&log, .Remove, erin, carol) == .None, "and to remove her")
	}
	{
		// Member invite: members add too, but still do not remove.
		log := testRoomLogMake()
		defer testRoomLogDestroy(&log)
		assert(testRoomLogCreate(&log, .MemberInvite) == .None, "expected the Create")
		assert(testRoomLogTry(&log, .Add, bob, alice) == .None, "expected alice to add bob")
		assert(testRoomLogTry(&log, .Add, dave, bob) == .None, "expected bob to invite dave")
		err := testRoomLogTry(&log, .Add, erin, erin)
		assert(err == .NotAuthorized, fmt.tprintf("outsider add: %v", err))
		err = testRoomLogTry(&log, .Remove, dave, bob)
		assert(err == .NotAuthorized, fmt.tprintf("member removal: %v", err))
		err = testRoomLogTry(&log, .SetAccess, {}, bob)
		assert(err == .NotAuthorized, fmt.tprintf("SetAccess by a member: %v", err))
		assert(testRoomLogTry(&log, .Leave, dave, dave) == .None, "expected dave to leave")
	}
}

@(test)
testRoomLogSignaturesAndUnsignedEntries :: proc(t: ^testing.T) {
	_ = t
	alice := testUser("alice", TEST_ALICE_ID)
	bob := testUser("bob", TEST_BOB_ID)
	dave := testUser("dave", TEST_DAVE_ID)
	server := TestUser{}
	log := testRoomLogMake()
	defer testRoomLogDestroy(&log)
	assert(testRoomLogCreate(&log, .AdminInvite) == .None, "expected the Create")
	assert(testRoomLogTry(&log, .Add, bob, alice) == .None, "expected alice to add bob")

	// An unsigned Add (the server adding a reader) is refused.
	unsignedAdd := testRoomLogNext(&log, .Add, dave, server)
	err := testRoomLogApply(&log, testRoomLogEncode(unsignedAdd, server))
	assert(err == .Unsigned, fmt.tprintf("expected an unsigned Add refused, got %v", err))
	// An unsigned Remove with leftovers of a signature is malformed.
	malformed := testRoomLogNext(&log, .Remove, bob, server)
	malformed.signature[0] = 1
	err = testRoomLogApply(&log, testRoomLogEncode(malformed, server))
	assert(err == .MalformedUnsigned, fmt.tprintf("expected MalformedUnsigned, got %v", err))
	malformed.signature = {}
	malformed.actorIdentityKey = alice.publicKey
	err = testRoomLogApply(&log, testRoomLogEncode(malformed, server))
	assert(err == .MalformedUnsigned, fmt.tprintf("expected MalformedUnsigned, got %v", err))

	// An Add signed by bob's key but claiming alice as the actor.
	forged := testRoomLogNext(&log, .Add, dave, alice)
	forgedBytes := testRoomLogEncode(forged, bob)
	endian.unchecked_put_u64le(forgedBytes[90:98], u64(TEST_ALICE_ID))
	err = testRoomLogApply(&log, forgedBytes)
	assert(err == .IdentityKeyMismatch, fmt.tprintf("expected the actor's key, got %v", err))
	// A signature over another server's key.
	otherServer := testRoomLogNext(&log, .Add, dave, alice)
	signErr := signRoomLogEntry(&otherServer, bob.publicKey, alice.privateKey)
	assert(signErr == .None, "expected the entry to sign")
	err = testRoomLogApply(&log, testRoomLogEncode(otherServer, server))
	assert(err == .BadSignature, fmt.tprintf("expected another server refused, got %v", err))
	// A broken signature byte.
	broken := testRoomLogEncode(testRoomLogNext(&log, .Add, dave, alice), alice)
	broken[len(broken) - 1] ~= 0x01
	err = testRoomLogApply(&log, broken)
	assert(err == .BadSignature, fmt.tprintf("expected BadSignature, got %v", err))

	// The unsigned removal is accepted.
	err = testRoomLogTry(&log, .Remove, bob, server)
	assert(err == .None, fmt.tprintf("expected the server's removal, got %v", err))
	assert(!RoomLogState_isMember(log.state, TEST_BOB_ID), "expected bob removed")
	err = testRoomLogTry(&log, .Leave, bob, server)
	assert(err == .Unsigned, fmt.tprintf("expected an unsigned Leave refused, got %v", err))
}

@(test)
testRoomLogChainingForksAndRollback :: proc(t: ^testing.T) {
	_ = t
	alice := testUser("alice", TEST_ALICE_ID)
	bob := testUser("bob", TEST_BOB_ID)
	dave := testUser("dave", TEST_DAVE_ID)
	log := testRoomLogMake()
	defer testRoomLogDestroy(&log)
	assert(testRoomLogCreate(&log, .AdminInvite) == .None, "expected the Create")
	assert(testRoomLogTry(&log, .Add, bob, alice) == .None, "expected bob added")
	assert(testRoomLogTry(&log, .Add, dave, alice) == .None, "expected dave added")
	ctx := testRoomLogContext(&log)

	brokenHash := testRoomLogNext(&log, .Remove, dave, alice)
	brokenHash.prevHash[0] ~= 0x01
	err := testRoomLogApply(&log, testRoomLogEncode(brokenHash, alice))
	assert(err == .BadPrevHash, fmt.tprintf("expected BadPrevHash, got %v", err))
	skipped := testRoomLogNext(&log, .Remove, dave, alice)
	skipped.version += 1
	err = testRoomLogApply(&log, testRoomLogEncode(skipped, alice))
	assert(err == .VersionNotNext, fmt.tprintf("expected VersionNotNext, got %v", err))
	otherRoom := testRoomLogNext(&log, .Remove, dave, alice)
	otherRoom.roomID += 1
	err = testRoomLogApply(&log, testRoomLogEncode(otherRoom, alice))
	assert(err == .WrongRoom, fmt.tprintf("expected WrongRoom, got %v", err))
	secondCreate := testRoomLogNext(&log, .Create, alice, alice)
	managers := [1]RoomLogManager{{alice.id, alice.publicKey}}
	secondCreate.settings = {
		access            = .AdminInvite,
		historyVisibility = .Full,
		managers          = managers[:],
	}
	err = testRoomLogApply(&log, testRoomLogEncode(secondCreate, alice))
	assert(err == .UnexpectedCreate, fmt.tprintf("expected UnexpectedCreate, got %v", err))

	// A log rewritten on the server: the entry at the verified head's version changes.
	head := RoomLogState_head(log.state)
	rewritten: TestRoomLog = testRoomLogMake()
	defer testRoomLogDestroy(&rewritten)
	assert(testRoomLogCreate(&rewritten, .AdminInvite) == .None, "expected the Create")
	assert(testRoomLogTry(&rewritten, .Add, bob, alice) == .None, "expected bob added")
	carol := testUser("carol", TEST_CAROL_ID)
	assert(testRoomLogTry(&rewritten, .Add, dave, carol) == .None, "a different version 3")
	_, forkErr, forkIndex := replayRoomLog(TEST_ROOM_ID, rewritten.entries[:], ctx, head)
	assert(forkErr == .Fork && forkIndex == 2, fmt.tprintf("expected Fork, got %v", forkErr))
	// The rewritten log is valid on its own; only the known head catches it.
	fresh, freshErr, _ := replayRoomLog(TEST_ROOM_ID, rewritten.entries[:], ctx)
	defer RoomLogState_deinit(&fresh)
	assert(freshErr == .None, "expected the rewritten log to be valid without a head")
	// A log that stops before the verified head.
	_, rollbackErr, rollbackIndex := replayRoomLog(TEST_ROOM_ID, log.entries[:2], ctx, head)
	assert(rollbackErr == .Rollback && rollbackIndex == 2, "expected Rollback")
	// Entries out of order, and an empty log.
	swapped := [3][]u8{log.entries[0], log.entries[2], log.entries[1]}
	_, swapErr, swapIndex := replayRoomLog(TEST_ROOM_ID, swapped[:], ctx)
	assert(swapErr == .VersionNotNext && swapIndex == 1, "expected out-of-order refused")
	_, emptyErr, _ := replayRoomLog(TEST_ROOM_ID, nil, ctx)
	assert(emptyErr == .EmptyLog, "expected an empty log refused")
	firstNotCreate := [1][]u8{log.entries[1]}
	_, firstErr, _ := replayRoomLog(TEST_ROOM_ID, firstNotCreate[:], ctx)
	assert(firstErr == .BadPrevHash || firstErr == .VersionNotNext, "expected a version 1")
}

@(test)
testRoomLogCreateRulesAndManagers :: proc(t: ^testing.T) {
	_ = t
	alice := testUser("alice", TEST_ALICE_ID)
	bob := testUser("bob", TEST_BOB_ID)
	carol := testUser("carol", TEST_CAROL_ID)
	server := TestUser{}

	{
		// The first entry must be a Create.
		log := testRoomLogMake()
		defer testRoomLogDestroy(&log)
		err := testRoomLogTry(&log, .Add, bob, alice)
		assert(err == .FirstEntryNotCreate, fmt.tprintf("expected a Create first, got %v", err))
		err = testRoomLogTry(&log, .Remove, bob, server)
		assert(err == .FirstEntryNotCreate, "expected an unsigned first entry refused")

		create := testRoomLogNext(&log, .Create, alice, alice)
		withoutCreator := [1]RoomLogManager{{carol.id, carol.publicKey}}
		create.settings = {
			access            = .AdminInvite,
			historyVisibility = .FromJoin,
			managers          = withoutCreator[:],
		}
		err = testRoomLogApply(&log, testRoomLogEncode(create, alice))
		assert(err == .CreatorNotManager, fmt.tprintf("expected CreatorNotManager, got %v", err))
		withCreator := [1]RoomLogManager{{alice.id, alice.publicKey}}
		create.settings.managers = withCreator[:]
		create.targetUserID = bob.id
		create.targetIdentityKey = bob.publicKey
		err = testRoomLogApply(&log, testRoomLogEncode(create, alice))
		assert(err == .CreatorNotTarget, fmt.tprintf("expected CreatorNotTarget, got %v", err))
		// The creator's manager entry naming another key than the creator's.
		create.targetUserID = alice.id
		create.targetIdentityKey = alice.publicKey
		wrongKey := [1]RoomLogManager{{alice.id, bob.publicKey}}
		create.settings.managers = wrongKey[:]
		err = testRoomLogApply(&log, testRoomLogEncode(create, alice))
		assert(err == .IdentityKeyMismatch, fmt.tprintf("expected a key mismatch, got %v", err))

		// creatorJoins false: the creator manages a room it is not in.
		create.settings.managers = withCreator[:]
		err = testRoomLogApply(&log, testRoomLogEncode(create, alice))
		assert(err == .None, fmt.tprintf("expected the Create, got %v", err))
		assert(len(log.state.members) == 0, "expected no members without creatorJoins")
		assert(testRoomLogTry(&log, .Add, bob, alice) == .None, "expected a non-member to add")
	}
	{
		// The last manager cannot leave the role while the room has members.
		log := testRoomLogMake()
		defer testRoomLogDestroy(&log)
		assert(testRoomLogCreate(&log, .AdminInvite) == .None, "expected the Create")
		assert(testRoomLogTry(&log, .RemoveManager, carol, alice) == .None, "expected carol out")
		err := testRoomLogTry(&log, .RemoveManager, alice, alice)
		assert(err == .LastManager, fmt.tprintf("expected LastManager, got %v", err))
		assert(testRoomLogTry(&log, .Leave, alice, alice) == .None, "expected alice to leave")
		err = testRoomLogTry(&log, .RemoveManager, alice, alice)
		assert(err == .None, fmt.tprintf("expected an empty room's last manager out, got %v", err))
		err = testRoomLogTry(&log, .Add, bob, alice)
		assert(err == .NotAuthorized, "expected nobody to add after that")
	}
	{
		// SetAccess keeps the history visibility.
		log := testRoomLogMake()
		defer testRoomLogDestroy(&log)
		assert(testRoomLogCreate(&log, .AdminInvite) == .None, "expected the Create")
		entry := testRoomLogNext(&log, .SetAccess, {}, alice)
		entry.settings = {
			access            = .MemberInvite,
			historyVisibility = .FromJoin,
		}
		err := testRoomLogApply(&log, testRoomLogEncode(entry, alice))
		assert(err == .HistoryVisibilityChanged, fmt.tprintf("expected a refusal, got %v", err))
		assert(testRoomLogTry(&log, .SetAccess, {}, carol) == .None, "expected carol to switch")
		assert(log.state.access == .MemberInvite, "expected Member invite")
	}
}

@(test)
testRoomLogPinsAndIdentityKeys :: proc(t: ^testing.T) {
	_ = t
	alice := testUser("alice", TEST_ALICE_ID)
	bob := testUser("bob", TEST_BOB_ID)
	impostor := testUser("impostor", TEST_BOB_ID)
	log := testRoomLogMake()
	defer testRoomLogDestroy(&log)
	assert(testRoomLogCreate(&log, .AdminInvite) == .None, "expected the Create")

	// A pin that disagrees with the log's key for bob.
	log.pins[TEST_BOB_ID] = impostor.publicKey
	err := testRoomLogTry(&log, .Add, bob, alice)
	assert(err == .PinMismatch, fmt.tprintf("expected PinMismatch, got %v", err))
	log.pins[TEST_BOB_ID] = bob.publicKey
	assert(testRoomLogTry(&log, .Add, bob, alice) == .None, "expected the pinned key accepted")
	assert(testRoomLogTry(&log, .Remove, bob, alice) == .None, "expected bob removed")

	// Without a pin, the log still holds bob to the key it named first.
	delete_key(&log.pins, TEST_BOB_ID)
	err = testRoomLogTry(&log, .Add, impostor, alice)
	assert(err == .IdentityKeyMismatch, fmt.tprintf("expected a key mismatch, got %v", err))
	// The actor's pin is checked too.
	log.pins[TEST_ALICE_ID] = impostor.publicKey
	err = testRoomLogTry(&log, .Add, bob, alice)
	assert(err == .PinMismatch, fmt.tprintf("expected the actor's pin checked, got %v", err))
	delete_key(&log.pins, TEST_ALICE_ID)

	// No lookup at all: every key is a first use.
	ctx := testRoomLogContext(&log)
	ctx.lookupPin = nil
	state, replayErr, _ := replayRoomLog(TEST_ROOM_ID, log.entries[:], ctx)
	defer RoomLogState_deinit(&state)
	assert(replayErr == .None, "expected a replay without pins")
	assert(state.identities[TEST_BOB_ID] == bob.publicKey, "expected bob's key to be reported")
}

@(test)
testRoomLogRoomFull :: proc(t: ^testing.T) {
	_ = t
	alice := testUser("alice", TEST_ALICE_ID)
	log := testRoomLogMake()
	defer testRoomLogDestroy(&log)
	assert(testRoomLogCreate(&log, .AdminInvite) == .None, "expected the Create")
	for index in 1 ..< ENCRYPTED_ROOM_MEMBERS_MAX {
		member := testUser(fmt.tprintf("member-%d", index), 1000 + index)
		err := testRoomLogTry(&log, .Add, member, alice)
		assert(err == .None, fmt.tprintf("member %d: %v", index, err))
	}
	assert(len(log.state.members) == ENCRYPTED_ROOM_MEMBERS_MAX, "expected a full room")
	extra := testUser("member-extra", 5000)
	err := testRoomLogTry(&log, .Add, extra, alice)
	assert(err == .RoomFull, fmt.tprintf("expected RoomFull, got %v", err))
}

@(test)
testRoomLogEncodingRules :: proc(t: ^testing.T) {
	_ = t
	alice := testUser("alice", TEST_ALICE_ID)
	bob := testUser("bob", TEST_BOB_ID)
	buffer: [ROOM_LOG_ENTRY_MAX_BYTES + 1]u8
	managerBuffer: [ROOM_LOG_MANAGERS_MAX]RoomLogManager

	add := RoomLogEntry {
		roomID            = TEST_ROOM_ID,
		version           = 2,
		action            = .Add,
		targetUserID      = bob.id,
		targetIdentityKey = bob.publicKey,
		actorUserID       = alice.id,
	}
	assert(signRoomLogEntry(&add, testServerPublicKey(), alice.privateKey) == .None, "sign")
	n, err := encodeRoomLogEntry(add, buffer[:])
	assert(err == .None && n == ROOM_LOG_ENTRY_MIN_BYTES, "expected a minimal entry")
	decoded, decodeErr := decodeRoomLogEntry(buffer[:n], managerBuffer[:])
	assert(decodeErr == .None && decoded.targetUserID == bob.id, "expected a round trip")
	assert(decoded.signature == add.signature, "expected the signature back")

	for length in 0 ..< n {
		_, lengthErr := decodeRoomLogEntry(buffer[:length], managerBuffer[:])
		assert(lengthErr != .None, fmt.tprintf("expected %d bytes refused", length))
	}
	_, decodeErr = decodeRoomLogEntry(buffer[:n + 1], managerBuffer[:])
	assert(decodeErr == .TrailingBytes, fmt.tprintf("expected TrailingBytes, got %v", decodeErr))

	byteCase :: proc(data: []u8, offset: int, value: u8) -> RoomLogError {
		copied: [ROOM_LOG_ENTRY_MAX_BYTES]u8
		copy(copied[:], data)
		copied[offset] = value
		managers: [ROOM_LOG_MANAGERS_MAX]RoomLogManager
		_, err := decodeRoomLogEntry(copied[:len(data)], managers[:])
		return err
	}
	entry := buffer[:n]
	assert(byteCase(entry, 0, 2) == .UnsupportedFormat, "format 2")
	assert(byteCase(entry, 49, 0) == .UnknownAction, "action 0")
	assert(byteCase(entry, 49, 8) == .UnknownAction, "action 8")
	assert(byteCase(entry, 138, 1) == .BadSettings, "settings on an Add")
	assert(byteCase(entry, 138, 2) == .BadSettings, "settings flag 2")
	assert(byteCase(entry, 1, 0) == .BadRoomID, "room 0")
	assert(byteCase(entry, 9, 0) == .BadVersion, "version 0")
	assert(byteCase(entry, 50, 0) == .BadTarget, "target 0")
	assert(byteCase(entry, 57, 0x80) == .BadUserID, "negative target")
	assert(byteCase(entry, 97, 0x80) == .BadUserID, "negative actor")

	// Create settings.
	managers := [2]RoomLogManager{{alice.id, alice.publicKey}, {bob.id, bob.publicKey}}
	create := RoomLogEntry {
		roomID            = TEST_ROOM_ID,
		version           = 1,
		action            = .Create,
		targetUserID      = alice.id,
		targetIdentityKey = alice.publicKey,
		actorUserID       = alice.id,
		settings          = {
			access = .AdminInvite,
			historyVisibility = .FromJoin,
			creatorJoins = true,
			managers = managers[:],
		},
	}
	n, err = encodeRoomLogEntry(create, buffer[:])
	assert(err == .None, "expected a Create to encode")
	createBytes := buffer[:n]
	assert(byteCase(createBytes, 139, 1) == .BadAccess, "access Public")
	assert(byteCase(createBytes, 139, 4) == .BadAccess, "access 4")
	assert(byteCase(createBytes, 140, 0) == .BadHistoryVisibility, "history 0")
	assert(byteCase(createBytes, 140, 3) == .BadHistoryVisibility, "history 3")
	assert(byteCase(createBytes, 141, 2) == .BadSettings, "creatorJoins 2")
	assert(byteCase(createBytes, 142, 3) == .Truncated, "three managers claimed")
	assert(byteCase(createBytes, 142, 1) == .TrailingBytes, "one manager claimed")
	assert(byteCase(createBytes, 142, 0) == .TrailingBytes, "no managers claimed")
	assert(byteCase(createBytes, 143, 1) == .TooManyManagers, "257 managers claimed")
	assert(byteCase(createBytes, 144 + 40, TEST_ALICE_ID) == .DuplicateManager, "duplicate")
	assert(byteCase(createBytes, 144, 0) == .BadUserID, "manager 0")
	assert(byteCase(createBytes, 49, u8(RoomLogAction.Add)) == .BadSettings, "Add + settings")
	_, decodeErr = decodeRoomLogEntry(createBytes, managerBuffer[:1])
	assert(decodeErr == .BufferTooSmall, "expected a small manager buffer refused")

	// The encoder refuses what the decoder would.
	invalid := create
	invalid.settings.managers = nil
	_, err = encodeRoomLogEntry(invalid, buffer[:])
	assert(err == .BadSettings, fmt.tprintf("expected a Create without managers, got %v", err))
	duplicates := [2]RoomLogManager{managers[0], managers[0]}
	invalid.settings.managers = duplicates[:]
	_, err = encodeRoomLogEntry(invalid, buffer[:])
	assert(err == .DuplicateManager, "expected duplicate managers refused")
	tooMany: [ROOM_LOG_MANAGERS_MAX + 1]RoomLogManager
	invalid.settings.managers = tooMany[:]
	_, err = encodeRoomLogEntry(invalid, buffer[:])
	assert(err == .TooManyManagers, "expected too many managers refused")
	setAccess := add
	setAccess.action = .SetAccess
	setAccess.settings = {
		access            = .MemberInvite,
		historyVisibility = .FromJoin,
	}
	_, err = encodeRoomLogEntry(setAccess, buffer[:])
	assert(err == .BadTarget, fmt.tprintf("expected SetAccess with a target refused, got %v", err))
	setAccess.targetUserID = 0
	setAccess.targetIdentityKey = {}
	setAccess.settings.creatorJoins = true
	_, err = encodeRoomLogEntry(setAccess, buffer[:])
	assert(err == .BadSettings, "expected SetAccess with creatorJoins refused")
	setAccess.settings.creatorJoins = false
	n, err = encodeRoomLogEntry(setAccess, buffer[:])
	assert(err == .None, "expected a SetAccess to encode")
	_, err = encodeRoomLogEntry(setAccess, buffer[:n - 1])
	assert(err == .BufferTooSmall, "expected BufferTooSmall")
	unsigned := add
	unsigned.actorUserID = 0
	assert(
		signRoomLogEntry(&unsigned, testServerPublicKey(), alice.privateKey) == .Unsigned,
		"expected signing without an actor refused",
	)
}

// ---------------------------------------------------------------------------------------------
// Voice keys (protocol 21, e2ee-voice-design.md 3.1).

@(private = "file")
testVoiceKeyFields :: proc() -> VoiceKeyAADFields {
	sessionLabel := testLabel("haychat-e2ee-test-voice-session")
	fields := VoiceKeyAADFields {
		serverIdentityPublicKey = testServerPublicKey(),
		roomID                  = TEST_ROOM_ID,
		epoch                   = 3,
		senderUserID            = TEST_ALICE_ID,
		generation              = 7,
		createdAtUnix           = TEST_CREATED_AT,
	}
	copy(fields.voiceSessionID[:], sessionLabel[:VOICE_SESSION_ID_SIZE])
	return fields
}

@(private = "file")
testVoiceKey :: proc() -> VoiceKey {
	return VoiceKey(testLabel("haychat-e2ee-test-voice-key"))
}

// The voice key plaintext for fields and key, built by hand from the layout.
@(private = "file")
testVoiceKeyPlaintext :: proc(
	fields: VoiceKeyAADFields,
	key: VoiceKey,
) -> [VOICE_KEY_PLAINTEXT_SIZE]u8 {
	fields := fields
	key := key
	plaintext: [VOICE_KEY_PLAINTEXT_SIZE]u8
	plaintext[0] = 1
	endian.unchecked_put_u64le(plaintext[1:9], u64(i64(fields.roomID)))
	endian.unchecked_put_u64le(plaintext[9:17], u64(i64(fields.epoch)))
	copy(plaintext[17:33], fields.voiceSessionID[:])
	endian.unchecked_put_u32le(plaintext[33:37], fields.generation)
	endian.unchecked_put_u64le(plaintext[37:45], u64(fields.createdAtUnix))
	copy(plaintext[45:], key[:])
	return plaintext
}

// The KAT_VOICE_KEY_ENVELOPE envelope, sealed with the vector's fixed randomness.
@(private = "file")
testSealVectorVoiceKey :: proc(dst: []u8) -> []u8 {
	alice := testUser("alice", TEST_ALICE_ID)
	fields := testVoiceKeyFields()
	plaintext := testVoiceKeyPlaintext(fields, testVoiceKey())
	aad := makeVoiceKeyAAD(fields)
	recipients := [2]EnvelopeRecipient {
		{TEST_BOB_ID, testEncryptionKeyPair("bob").publicKey},
		{TEST_CAROL_ID, testEncryptionKeyPair("carol").publicKey},
	}
	nonceLabel := testLabel("haychat-e2ee-test-voice-nonce")
	nonce: E2EENonce
	copy(nonce[:], nonceLabel[:E2EE_NONCE_SIZE])
	n, err := sealEnvelopeWithRandomness(
		.VoiceKey,
		aad[:],
		plaintext[:],
		recipients[:],
		alice.privateKey,
		MessageKey(testLabel("haychat-e2ee-test-voice-message-key")),
		EncryptionPrivateKeyBytes(testLabel("haychat-e2ee-test-voice-ephemeral")),
		nonce,
		dst,
	)
	assert(err == .None, fmt.tprintf("expected the vector voice key to seal, got %v", err))
	return dst[:n]
}

@(test)
testVoiceKeyVectorAndRoundTrip :: proc(t: ^testing.T) {
	_ = t
	alice := testUser("alice", TEST_ALICE_ID)
	bob := testUser("bob", TEST_BOB_ID)
	fields := testVoiceKeyFields()
	buffer: [SEALED_ENVELOPE_MAX_BYTES]u8
	vector := testSealVectorVoiceKey(buffer[:])
	assert(testHexEqual(vector, KAT_VOICE_KEY_ENVELOPE), "expected the voice key vector bytes")
	kat: [SEALED_ENVELOPE_MAX_BYTES]u8
	katBytes := testHex(KAT_VOICE_KEY_ENVELOPE, kat[:])

	// Both recipients open it with alice's pin; the server's check accepts it.
	for recipient in ([2]struct {
			id:   int,
			name: string,
		}{{TEST_BOB_ID, "bob"}, {TEST_CAROL_ID, "carol"}}) {
		key, err := openVoiceKey(
			katBytes,
			fields,
			alice.publicKey,
			recipient.id,
			testEncryptionKeyPair(recipient.name),
		)
		assert(
			err == .None,
			fmt.tprintf("expected %s to open the voice key, got %v", recipient.name, err),
		)
		assert(key == testVoiceKey(), fmt.tprintf("expected %s's voice key", recipient.name))
	}
	decoded, decodeErr := decodeSealedEnvelope(katBytes)
	assert(decodeErr == .None && decoded.kind == .VoiceKey, "expected a VoiceKey envelope")
	assert(
		verifyVoiceKeyEnvelope(decoded, fields, alice.publicKey) == .None,
		"expected the server's check to accept the voice key",
	)

	// A member without a wrap, and a wrong pin, which fails before any key material is used.
	bobKeys := testEncryptionKeyPair("bob")
	daveKeys := testEncryptionKeyPair("dave")
	_, err := openVoiceKey(katBytes, fields, alice.publicKey, TEST_DAVE_ID, daveKeys)
	assert(err == .NoWrapForRecipient, fmt.tprintf("expected no wrap for dave, got %v", err))
	_, err = openVoiceKey(katBytes, fields, bob.publicKey, TEST_BOB_ID, bobKeys)
	assert(err == .BadSignature, fmt.tprintf("expected the wrong pin to fail, got %v", err))
	carolKeys := testEncryptionKeyPair("carol")
	_, err = openVoiceKey(katBytes, fields, alice.publicKey, TEST_BOB_ID, carolKeys)
	assert(err == .BadWrap, fmt.tprintf("expected carol's key to fail bob's wrap, got %v", err))

	// Every AAD field is bound: a change to any of them fails the signature.
	tampered: [7]VoiceKeyAADFields
	for &field in tampered {
		field = fields
	}
	tampered[0].serverIdentityPublicKey = bob.publicKey
	tampered[1].roomID += 1
	tampered[2].epoch += 1
	tampered[3].senderUserID = TEST_BOB_ID
	tampered[4].voiceSessionID[0] ~= 1
	tampered[5].generation += 1
	tampered[6].createdAtUnix += 1
	for field, index in tampered {
		_, err = openVoiceKey(katBytes, field, alice.publicKey, TEST_BOB_ID, bobKeys)
		assert(err == .BadSignature, fmt.tprintf("AAD field %d: BadSignature: %v", index, err))
		assert(
			verifyVoiceKeyEnvelope(decoded, field, alice.publicKey) == .BadSignature,
			fmt.tprintf("AAD field %d: expected the server's check to fail", index),
		)
	}

	// The kind byte and the signature are covered by the signature.
	copied: [SEALED_ENVELOPE_MAX_BYTES]u8
	data := copied[:len(katBytes)]
	copy(data, katBytes)
	data[1] = u8(EnvelopeKind.SenderKey)
	_, err = openVoiceKey(data, fields, alice.publicKey, TEST_BOB_ID, bobKeys)
	assert(err == .BadSignature, fmt.tprintf("expected a changed kind to fail, got %v", err))
	copy(data, katBytes)
	data[len(data) - 1] ~= 1
	_, err = openVoiceKey(data, fields, alice.publicKey, TEST_BOB_ID, bobKeys)
	assert(err == .BadSignature, fmt.tprintf("expected a changed signature to fail, got %v", err))

	// A fresh key through the public procedure.
	key, keyOK := generateVoiceKey()
	assert(keyOK, "expected a random voice key")
	recipients := [1]EnvelopeRecipient{{TEST_BOB_ID, testEncryptionKeyPair("bob").publicKey}}
	n, sealErr := sealVoiceKey(fields, key, recipients[:], alice.privateKey, buffer[:])
	assert(sealErr == .None, fmt.tprintf("expected the voice key to seal, got %v", sealErr))
	opened, openErr := openVoiceKey(buffer[:n], fields, alice.publicKey, TEST_BOB_ID, bobKeys)
	assert(openErr == .None && opened == key, fmt.tprintf("expected the round trip: %v", openErr))
}

@(test)
testVoiceKeyRefusesWhatItMustNot :: proc(t: ^testing.T) {
	_ = t
	alice := testUser("alice", TEST_ALICE_ID)
	bobKeys := testEncryptionKeyPair("bob")
	fields := testVoiceKeyFields()
	buffer: [SEALED_ENVELOPE_MAX_BYTES]u8
	bobOnly := [1]EnvelopeRecipient{{TEST_BOB_ID, bobKeys.publicKey}}

	// The speaker never wraps its own key, and the server refuses an envelope that does.
	withSender := [2]EnvelopeRecipient {
		{TEST_BOB_ID, bobKeys.publicKey},
		{TEST_ALICE_ID, testEncryptionKeyPair("alice").publicKey},
	}
	_, err := sealVoiceKey(fields, testVoiceKey(), withSender[:], alice.privateKey, buffer[:])
	assert(err == .WrongRecipients, fmt.tprintf("expected the sender's wrap refused: %v", err))
	plaintext := testVoiceKeyPlaintext(fields, testVoiceKey())
	aad := makeVoiceKeyAAD(fields)
	n: int
	signer := alice.privateKey
	n, err = sealEnvelope(.VoiceKey, aad[:], plaintext[:], withSender[:], signer, buffer[:])
	assert(err == .None, "expected the raw envelope to seal")
	decoded, decodeErr := decodeSealedEnvelope(buffer[:n])
	assert(decodeErr == .None, "expected the raw envelope to decode")
	assert(
		verifyVoiceKeyEnvelope(decoded, fields, alice.publicKey) == .WrongRecipients,
		"expected the server to refuse a voice key wrapped for its sender",
	)

	// Another kind under the voice key AAD.
	n, err = sealEnvelope(.SenderKey, aad[:], plaintext[:], bobOnly[:], alice.privateKey, buffer[:])
	assert(err == .None, "expected the SenderKey envelope to seal")
	_, err = openVoiceKey(buffer[:n], fields, alice.publicKey, TEST_BOB_ID, bobKeys)
	assert(err == .WrongKind, fmt.tprintf("expected WrongKind, got %v", err))

	// A plaintext that does not repeat the AAD's fields, correctly signed by the sender.
	mismatched: [5]VoiceKeyAADFields
	for &field in mismatched {
		field = fields
	}
	mismatched[0].roomID += 1
	mismatched[1].epoch += 1
	mismatched[2].voiceSessionID[3] ~= 0x40
	mismatched[3].generation += 1
	mismatched[4].createdAtUnix -= 1
	for other, index in mismatched {
		otherPlaintext := testVoiceKeyPlaintext(other, testVoiceKey())
		n, err = sealEnvelope(.VoiceKey, aad[:], otherPlaintext[:], bobOnly[:], signer, buffer[:])
		assert(err == .None, "expected the mismatched envelope to seal")
		_, err = openVoiceKey(buffer[:n], fields, alice.publicKey, TEST_BOB_ID, bobKeys)
		assert(
			err == .MismatchedVoiceKey,
			fmt.tprintf("field %d: expected MismatchedVoiceKey, got %v", index, err),
		)
	}
	// A plaintext of the wrong version or length.
	badVersion := plaintext
	badVersion[0] = 2
	n, err = sealEnvelope(.VoiceKey, aad[:], badVersion[:], bobOnly[:], alice.privateKey, buffer[:])
	assert(err == .None, "expected the version 2 envelope to seal")
	_, err = openVoiceKey(buffer[:n], fields, alice.publicKey, TEST_BOB_ID, bobKeys)
	assert(err == .BadPlaintext, fmt.tprintf("expected version 2 to be refused, got %v", err))
	n, err = sealEnvelope(.VoiceKey, aad[:], plaintext[:76], bobOnly[:], signer, buffer[:])
	assert(err == .None, "expected the short envelope to seal")
	_, err = openVoiceKey(buffer[:n], fields, alice.publicKey, TEST_BOB_ID, bobKeys)
	assert(err == .BadPlaintext, fmt.tprintf("expected a short plaintext refused: %v", err))

	// Field rules.
	bad := fields
	bad.roomID = 0
	_, err = sealVoiceKey(bad, testVoiceKey(), bobOnly[:], alice.privateKey, buffer[:])
	assert(err == .BadRoomID, fmt.tprintf("room 0: %v", err))
	bad = fields
	bad.epoch = 0
	_, err = sealVoiceKey(bad, testVoiceKey(), bobOnly[:], alice.privateKey, buffer[:])
	assert(err == .BadEpoch, fmt.tprintf("epoch 0: %v", err))
	bad = fields
	bad.senderUserID = 0
	_, err = sealVoiceKey(bad, testVoiceKey(), bobOnly[:], alice.privateKey, buffer[:])
	assert(err == .BadSenderUserID, fmt.tprintf("sender 0: %v", err))
	_, err = sealVoiceKey(fields, testVoiceKey(), nil, alice.privateKey, buffer[:])
	assert(err == .NoRecipients, fmt.tprintf("no recipients: %v", err))
}

// ---------------------------------------------------------------------------------------------
// Attachments on messages (protocol 27, attachments plan D14-D16). Vectors from
// dev/tools/e2ee-vectors.py (plain_v2_vectors, sealed_attachments_vector).

@(private = "file")
KAT_ROOM_PLAIN_V2_SIGNATURE ::
	"ed41ac41143caf1bdf346ed590d4f090b91125ce53ba19a8e38fc6f6cb21ce0a816133c318358f22" +
	"5c7fdbdb3e5dded5d6f87c7d8196af10718e9a1a0874ae0f"
@(private = "file")
KAT_PLAIN_V2_SIGNATURE ::
	"55d1b3198ab5d8544244f62b6e6ab22d50fe5c8d1144e0a2f7865c68f8e2841750d4a006a72f99cb" +
	"8265b7bb47a0c5e44601e5dd1cfc6230ac7d3fcf7a6f9d04"
@(private = "file")
KAT_SEALED_ATTACHMENTS_PLAINTEXT ::
	"a267636f6e74656e746974776f2066696c65736b6174746163686d656e747382a666626c6f624964" +
	"50bbd408fc31182bb6c38be926949aa33c636b657958200ef59d4a659c8ae94a250062d5b0d0700a" +
	"2b3aa0ae9abf3db5681317e4431e13667368613235365820268443f520c8b79a78386bca6f58ec85" +
	"d5b0b4763636b05d7bd610ca65ba272a6473697a651904d2646e616d656a7265706f72742e706466" +
	"64747970656f6170706c69636174696f6e2f706466a666626c6f624964504238afb03c65a40ba9c9" +
	"f799ee58a25e636b657958201be8b04307ab53e01cec615d3839883ec3fde3fcca22c17b93aa8d36" +
	"479d4a5766736861323536582071b7f675c390c458ae8650e2e2c8ab41c0496e014a3e1db9b6e063" +
	"1425afca3b6473697a651a00011170646e616d657670686f746f206f662074686520636166c3a92e" +
	"6a706764747970656a696d6167652f6a706567"

// The two attachments the vectors use, as plaintext references (the stored blob's hash) and as
// sealed entries (with their file keys).
@(private = "file")
testAttachmentRefs :: proc() -> [2]AttachmentRef {
	refs: [2]AttachmentRef
	for index in 0 ..< 2 {
		blob := testLabel(fmt.tprintf("haychat-e2ee-test-attachment-blob-%d", index + 1))
		copy(refs[index].blobId[:], blob[:ATTACHMENT_BLOB_ID_SIZE])
		refs[index].sha256 = AttachmentSHA256(
			testLabel(fmt.tprintf("haychat-e2ee-test-attachment-sha-%d", index + 1)),
		)
	}
	refs[0].size = 1234
	refs[0].name = "report.pdf"
	refs[0].mediaType = "application/pdf"
	refs[1].size = 70000
	refs[1].name = "photo of the café.jpg"
	refs[1].mediaType = "image/jpeg"
	return refs
}

@(private = "file")
testSealedAttachments :: proc() -> [2]SealedAttachment {
	refs := testAttachmentRefs()
	sealed: [2]SealedAttachment
	for index in 0 ..< 2 {
		sealed[index] = SealedAttachment {
			blobId    = refs[index].blobId,
			key       = AttachmentFileKey(
				testLabel(fmt.tprintf("haychat-e2ee-test-attachment-key-%d", index + 1)),
			),
			sha256    = refs[index].sha256,
			size      = refs[index].size,
			name      = refs[index].name,
			mediaType = refs[index].mediaType,
		}
	}
	return sealed
}

@(test)
testPlaintextRoomMessageV2Signature :: proc(t: ^testing.T) {
	_ = t
	alice := testUser("alice", TEST_ALICE_ID)
	label := testLabel("haychat-e2ee-test-room-plain-client-message-id")
	fields := PlaintextRoomMessageFields {
		serverIdentityPublicKey = testServerPublicKey(),
		roomID                  = TEST_ROOM_ID,
		senderUserID            = TEST_ALICE_ID,
	}
	copy(fields.clientMessageID[:], label[:CLIENT_MESSAGE_ID_SIZE])
	refs := testAttachmentRefs()
	signature, ok := signPlaintextRoomMessage(fields, "two files", alice.privateKey, refs[:])
	assert(ok, "expected the room message with attachments to sign")
	assert(
		testHexEqual(signature[:], KAT_ROOM_PLAIN_V2_SIGNATURE),
		"expected the v2 vector signature",
	)
	assert(
		verifyPlaintextRoomMessage(fields, "two files", alice.publicKey, signature, refs[:]),
		"expected the v2 signature to verify",
	)
	// The label follows the count: without attachments the same bytes do not verify, and a v1
	// signature does not verify with attachments added.
	assert(
		!verifyPlaintextRoomMessage(fields, "two files", alice.publicKey, signature),
		"expected stripped attachments to fail",
	)
	v1, v1OK := signPlaintextRoomMessage(fields, "two files", alice.privateKey)
	assert(v1OK, "expected the v1 message to sign")
	assert(
		!verifyPlaintextRoomMessage(fields, "two files", alice.publicKey, v1, refs[:]),
		"expected added attachments to fail a v1 signature",
	)
	testAttachmentRefTampering(
		t,
		proc(refs: []AttachmentRef, content: string, signature: SignatureBytes) -> bool {
			alice := testUser("alice", TEST_ALICE_ID)
			label := testLabel("haychat-e2ee-test-room-plain-client-message-id")
			fields := PlaintextRoomMessageFields {
				serverIdentityPublicKey = testServerPublicKey(),
				roomID                  = TEST_ROOM_ID,
				senderUserID            = TEST_ALICE_ID,
			}
			copy(fields.clientMessageID[:], label[:CLIENT_MESSAGE_ID_SIZE])
			return verifyPlaintextRoomMessage(fields, content, alice.publicKey, signature, refs)
		},
		"two files",
		signature,
	)
	// The fields prefix is still covered.
	changed := fields
	changed.roomID += 1
	assert(
		!verifyPlaintextRoomMessage(changed, "two files", alice.publicKey, signature, refs[:]),
		"expected another room to fail",
	)
	changed = fields
	changed.clientMessageID[0] ~= 1
	assert(
		!verifyPlaintextRoomMessage(changed, "two files", alice.publicKey, signature, refs[:]),
		"expected another client message ID to fail",
	)
	// Empty content is allowed with attachments only; bad references never sign.
	_, ok = signPlaintextRoomMessage(fields, "", alice.privateKey, refs[:1])
	assert(ok, "expected empty content with an attachment to sign")
	_, ok = signPlaintextRoomMessage(fields, "", alice.privateKey)
	assert(!ok, "expected empty content without attachments to be refused")
	bad := refs
	bad[1].blobId = bad[0].blobId
	_, ok = signPlaintextRoomMessage(fields, "x", alice.privateKey, bad[:])
	assert(!ok, "expected duplicate blob IDs to be refused")
	bad = refs
	bad[0].name = "a/b"
	_, ok = signPlaintextRoomMessage(fields, "x", alice.privateKey, bad[:])
	assert(!ok, "expected a name with a separator to be refused")
}

// Every signed attachment field: changing any one fails verify, and so do a dropped, an added
// or a reordered attachment, and other content. removed is not signed.
@(private = "file")
testAttachmentRefTampering :: proc(
	t: ^testing.T,
	verify: proc(refs: []AttachmentRef, content: string, signature: SignatureBytes) -> bool,
	content: string,
	signature: SignatureBytes,
) {
	_ = t
	refs := testAttachmentRefs()
	assert(verify(refs[:], content, signature), "expected the untouched references to verify")
	for field in 0 ..< 5 {
		for index in 0 ..< 2 {
			changed := refs
			switch field {
			case 0:
				changed[index].blobId[3] ~= 0x40
			case 1:
				changed[index].sha256[31] ~= 0x01
			case 2:
				changed[index].size += 1
			case 3:
				changed[index].name = "report.pdF"
			case 4:
				changed[index].mediaType = "application/octet-stream"
			}
			assert(
				!verify(changed[:], content, signature),
				fmt.tprintf("expected field %d of attachment %d to be signed", field, index),
			)
		}
	}
	assert(!verify(refs[:1], content, signature), "expected a dropped attachment to fail")
	swapped := [2]AttachmentRef{refs[1], refs[0]}
	assert(!verify(swapped[:], content, signature), "expected reordered attachments to fail")
	extra := [3]AttachmentRef{refs[0], refs[1], refs[1]}
	extra[2].blobId[0] ~= 0xFF
	assert(!verify(extra[:], content, signature), "expected an added attachment to fail")
	assert(!verify(refs[:], "other", signature), "expected other content to fail")
	removed := refs
	removed[0].removed = true
	assert(verify(removed[:], content, signature), "expected removed not to be signed")
}

@(test)
testPlaintextDirectMessageV2Signature :: proc(t: ^testing.T) {
	_ = t
	alice := testUser("alice", TEST_ALICE_ID)
	bob := testUser("bob", TEST_BOB_ID)
	fields := testPlaintextFields()
	refs := testAttachmentRefs()
	signature, ok := signPlaintextDirectMessage(fields, "", alice.privateKey, refs[:1])
	assert(ok, "expected the fallback with an attachment and no text to sign")
	assert(testHexEqual(signature[:], KAT_PLAIN_V2_SIGNATURE), "expected the v2 vector")
	assert(
		verifyPlaintextDirectMessage(fields, "", alice.publicKey, signature, refs[:1]),
		"expected the v2 fallback to verify",
	)
	assert(
		!verifyPlaintextDirectMessage(fields, "", bob.publicKey, signature, refs[:1]),
		"expected another signer to fail",
	)
	changed := fields
	changed.recipientUserID = TEST_ALICE_ID + 100
	assert(
		!verifyPlaintextDirectMessage(changed, "", alice.publicKey, signature, refs[:1]),
		"expected another recipient to fail",
	)
	// Every field of a two-attachment direct message is signed too.
	two, twoOK := signPlaintextDirectMessage(fields, "two files", alice.privateKey, refs[:])
	assert(twoOK, "expected two attachments to sign")
	testAttachmentRefTampering(
		t,
		proc(refs: []AttachmentRef, content: string, signature: SignatureBytes) -> bool {
			alice := testUser("alice", TEST_ALICE_ID)
			return verifyPlaintextDirectMessage(
				testPlaintextFields(),
				content,
				alice.publicKey,
				signature,
				refs,
			)
		},
		"two files",
		two,
	)
	// A room message's v2 signature over the same body is not a direct message's.
	roomFields := PlaintextRoomMessageFields {
		serverIdentityPublicKey = fields.serverIdentityPublicKey,
		roomID                  = TEST_BOB_ID,
		senderUserID            = TEST_ALICE_ID,
		clientMessageID         = fields.clientMessageID,
	}
	roomSignature, roomOK := signPlaintextRoomMessage(
		roomFields,
		"two files",
		alice.privateKey,
		refs[:],
	)
	assert(roomOK, "expected the room message to sign")
	assert(
		!verifyPlaintextDirectMessage(fields, "two files", alice.publicKey, roomSignature, refs[:]),
		"expected the room label to fail as a direct message",
	)
}

@(test)
testSealedPlaintextWithAttachments :: proc(t: ^testing.T) {
	_ = t
	sealed := testSealedAttachments()
	buffer: [DIRECT_MESSAGE_PLAINTEXT_MAX_SIZE]u8
	n, ok := encodeSealedMessagePlaintext("two files", sealed[:], buffer[:])
	assert(ok, "expected the plaintext with attachments to encode")
	assert(
		testHexEqual(buffer[:n], KAT_SEALED_ATTACHMENTS_PLAINTEXT),
		"expected the canonical vector",
	)
	decoded, err := decodeSealedDirectMessagePlaintext(buffer[:n])
	defer SealedDirectMessagePlaintext_deinit(&decoded)
	assert(err == .None, fmt.tprintf("expected the vector to decode, got %v", err))
	assert(decoded.content == "two files" && len(decoded.attachments) == 2, "expected both back")
	for attachment, index in decoded.attachments {
		want := sealed[index]
		assert(
			attachment.blobId == want.blobId &&
			attachment.key == want.key &&
			attachment.sha256 == want.sha256 &&
			attachment.size == want.size &&
			attachment.name == want.name &&
			attachment.mediaType == want.mediaType,
			fmt.tprintf("expected attachment %d back unchanged", index),
		)
	}

	// Empty content only with attachments (D15).
	n, ok = encodeSealedMessagePlaintext("", sealed[:1], buffer[:])
	assert(ok, "expected empty content with an attachment to encode")
	emptyDecoded, emptyErr := decodeSealedDirectMessagePlaintext(buffer[:n])
	defer SealedDirectMessagePlaintext_deinit(&emptyDecoded)
	assert(
		emptyErr == .None && emptyDecoded.content == "" && len(emptyDecoded.attachments) == 1,
		"expected empty content with one attachment to decode",
	)
	_, ok = encodeSealedMessagePlaintext("", nil, buffer[:])
	assert(!ok, "expected empty content without attachments to be refused")

	// The encoder refuses what a message may not carry.
	five: [5]SealedAttachment
	for &entry, index in five {
		entry = sealed[0]
		entry.blobId[0] = u8(index + 1)
	}
	_, ok = encodeSealedMessagePlaintext("x", five[:], buffer[:])
	assert(!ok, "expected five attachments to be refused")
	duplicate := [2]SealedAttachment{sealed[0], sealed[0]}
	_, ok = encodeSealedMessagePlaintext("x", duplicate[:], buffer[:])
	assert(!ok, "expected a repeated blob ID to be refused")
	badType := sealed
	badType[0].mediaType = "pdf"
	_, ok = encodeSealedMessagePlaintext("x", badType[:], buffer[:])
	assert(!ok, "expected a media type without a subtype to be refused")
	badName := sealed
	badName[1].name = "\x07bell"
	_, ok = encodeSealedMessagePlaintext("x", badName[:], buffer[:])
	assert(!ok, "expected a control character in a name to be refused")

	// The largest plaintext still fits the envelope and a sealed room message.
	text: [CHAT_MESSAGE_MAX_BYTES]u8
	for &value in text {
		value = 'y'
	}
	longName: [ATTACHMENT_NAME_MAX_BYTES]u8
	for &value in longName {
		value = 'n'
	}
	longType: [ATTACHMENT_MEDIA_TYPE_MAX_BYTES]u8
	for &value in longType {
		value = 't'
	}
	longType[50] = '/'
	largest: [ATTACHMENTS_PER_MESSAGE_MAX]SealedAttachment
	for &entry, index in largest {
		entry = sealed[0]
		entry.blobId[0] = u8(index + 1)
		entry.size = max(u64)
		entry.name = string(longName[:])
		entry.mediaType = string(longType[:])
	}
	n, ok = encodeSealedMessagePlaintext(string(text[:]), largest[:], buffer[:])
	assert(ok, "expected the largest plaintext to encode")
	assert(n == DIRECT_MESSAGE_PLAINTEXT_MAX_SIZE, fmt.tprintf("expected the maximum, got %d", n))
	assert(
		sealedEnvelopeSize(2, n) <= SEALED_ENVELOPE_MAX_BYTES &&
		sealedRoomMessageSize(n) <= SEALED_ROOM_MESSAGE_MAX_BYTES,
		"expected the largest plaintext to fit an envelope and a sealed room message",
	)
	fields := testDirectMessageFields()
	alice := testUser("alice", TEST_ALICE_ID)
	aliceKeys := testEncryptionKeyPair("alice")
	bobKeys := testEncryptionKeyPair("bob")
	envelope: [SEALED_ENVELOPE_MAX_BYTES]u8
	sealedLength, sealErr := sealDirectMessage(
		fields,
		string(text[:]),
		aliceKeys.publicKey,
		bobKeys.publicKey,
		alice.privateKey,
		envelope[:],
		largest[:],
	)
	assert(sealErr == .None, fmt.tprintf("expected the largest message to seal, got %v", sealErr))
	opened, openErr := openDirectMessage(
		envelope[:sealedLength],
		fields,
		TEST_BOB_ID,
		bobKeys,
	)
	defer SealedDirectMessagePlaintext_deinit(&opened)
	assert(
		openErr == .None && len(opened.attachments) == ATTACHMENTS_PER_MESSAGE_MAX,
		fmt.tprintf("expected the attachments to open, got %v", openErr),
	)
	assert(opened.attachments[3].size == max(u64), "expected the largest size back")
}

@(test)
testSealedAttachmentsStrictReader :: proc(t: ^testing.T) {
	_ = t
	sealed := testSealedAttachments()
	buffer: [DIRECT_MESSAGE_PLAINTEXT_MAX_SIZE]u8
	n, ok := encodeSealedMessagePlaintext("a", sealed[:1], buffer[:])
	assert(ok, "expected one attachment to encode")
	canonical := buffer[:n]
	// The entry starts after A2 "content" "a" "attachments" 81: 1 + 8 + 2 + 12 + 1.
	entry := 24
	assert(canonical[entry] == 0xA6, "expected the entry map at its offset")

	refusals := make([dynamic][]u8, context.temp_allocator)
	mutate :: proc(source: []u8, offset: int, value: u8) -> []u8 {
		copied := make([]u8, len(source), context.temp_allocator)
		copy(copied, source)
		copied[offset] = value
		return copied
	}
	// Not an array; an empty array; an array of five.
	attachmentsValue := entry - 1
	append(&refusals, mutate(canonical, attachmentsValue, 0xA1))
	append(&refusals, mutate(canonical, attachmentsValue, 0x80))
	append(&refusals, mutate(canonical, attachmentsValue, 0x85))
	// An entry with five keys (one missing) and with seven (a repeated one runs off the end).
	append(&refusals, mutate(canonical, entry, 0xA5))
	append(&refusals, mutate(canonical, entry, 0xA7))
	// blobId as 15 bytes and as text; key as text.
	append(&refusals, mutate(canonical, entry + 7, 0x4F))
	append(&refusals, mutate(canonical, entry + 7, 0x70))
	keyValue := entry + 1 + 7 + 17 + 4
	append(&refusals, mutate(canonical, keyValue, 0x78))
	// size as a negative integer.
	sizeValue := entry + 1 + 7 + 17 + 4 + 34 + 7 + 34 + 5
	append(&refusals, mutate(canonical, sizeValue, 0x39))
	// A control character in the name.
	nameValue := sizeValue + 3 + 5
	append(&refusals, mutate(canonical, nameValue + 1, 0x01))
	// Trailing bytes.
	trailing := make([]u8, len(canonical) + 1, context.temp_allocator)
	copy(trailing, canonical)
	append(&refusals, trailing)
	for data, index in refusals {
		_, err := decodeSealedDirectMessagePlaintext(data)
		assert(err == .BadPlaintext, fmt.tprintf("expected refusal %d, got %v", index, err))
	}

	// Unknown keys inside an entry are skipped.
	Later :: struct {
		blobId:  [16]u8,
		key:     [32]u8,
		sha256:  [32]u8,
		size:    u64,
		name:    string,
		type:    string,
		preview: [3]int,
	}
	Message :: struct {
		content:     string,
		attachments: [1]Later,
	}
	later := Message {
		content = "later",
		attachments = {
			{
				blobId = sealed[0].blobId,
				key = transmute([32]u8)sealed[0].key,
				sha256 = sealed[0].sha256,
				size = 9,
				name = "a.txt",
				type = "text/plain",
				preview = {1, 2, 3},
			},
		},
	}
	encoded, marshalErr := cbor.marshal(later)
	defer delete(encoded)
	assert(marshalErr == nil, "expected the later plaintext to encode")
	decoded, err := decodeSealedDirectMessagePlaintext(encoded)
	defer SealedDirectMessagePlaintext_deinit(&decoded)
	assert(
		err == .None && len(decoded.attachments) == 1 && decoded.attachments[0].name == "a.txt",
		fmt.tprintf("expected an unknown entry key to be skipped, got %v", err),
	)
}

@(test)
testAttachmentRefValidation :: proc(t: ^testing.T) {
	_ = t
	refs := testAttachmentRefs()
	assert(attachmentRefsAreValid(refs[:], sealed = false), "expected plaintext refs to pass")
	assert(!attachmentRefsAreValid(refs[:], sealed = true), "expected full refs to fail sealed")
	outer := [1]AttachmentRef{{blobId = refs[0].blobId, size = 77}}
	assert(attachmentRefsAreValid(outer[:], sealed = true), "expected an outer ref to pass")
	assert(!attachmentRefsAreValid(outer[:], sealed = false), "expected it to fail plaintext")
	outer[0].removed = true
	assert(!attachmentRefsAreValid(outer[:], sealed = true), "expected removed from a client")
	assert(
		attachmentRefsAreValid(outer[:], sealed = true, fromServer = true),
		"expected removed from the server",
	)
	outer[0].removed = false
	outer[0].size = 0
	assert(!attachmentRefsAreValid(outer[:], sealed = true), "expected size 0 to fail")
	for name in ([?]string{"", ".", "..", "a/b", "a\\b", "tab\there", "del\x7f", "c1\u0085"}) {
		assert(!attachmentNameIsValid(name), fmt.tprintf("expected %q to be refused", name))
	}
	long: [ATTACHMENT_NAME_MAX_BYTES + 1]u8
	for &value in long {
		value = 'a'
	}
	assert(attachmentNameIsValid(string(long[:ATTACHMENT_NAME_MAX_BYTES])), "expected 255 bytes")
	assert(!attachmentNameIsValid(string(long[:])), "expected 256 bytes to be refused")
	assert(attachmentNameIsValid(".hidden file (1).tar.gz"), "expected an ordinary name")
	for mediaType in ([?]string{"image/png", "application/vnd.ms-excel", "text/x-c++src"}) {
		assert(attachmentMediaTypeIsValid(mediaType), fmt.tprintf("expected %s", mediaType))
	}
	for mediaType in ([?]string{"", "png", "/png", "image/", "image/png; q=1", "a/b/c", "é/x"}) {
		assert(
			!attachmentMediaTypeIsValid(mediaType),
			fmt.tprintf("expected %q refused", mediaType),
		)
	}
	assert(messageContentLengthIsValid(0, 1), "expected empty content with one attachment")
	assert(!messageContentLengthIsValid(0, 0), "expected empty content alone to be refused")
	assert(!messageContentLengthIsValid(1, 5), "expected five attachments to be refused")
	assert(!messageContentLengthIsValid(CHAT_MESSAGE_MAX_BYTES + 1, 1), "expected too long")
}
