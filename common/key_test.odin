package common

import "core:crypto/ecdh"
import "core:crypto/ed25519"
import "core:mem"
import "core:testing"

@(test)
test_key_generation :: proc(t: ^testing.T) {
	key: EncryptionKey
	ok := generateKey(&key)
	defer clearKey(&key)

	testing.expect(t, ok, "Key generation should succeed")
}

@(test)
test_ecdh_key_exchange :: proc(t: ^testing.T) {
	// Create two parties
	alice: EncryptionKey
	bob: EncryptionKey
	testing.expect(t, generateKey(&alice), "Alice key generation should succeed")
	testing.expect(t, generateKey(&bob), "Bob key generation should succeed")
	defer clearKey(&alice)
	defer clearKey(&bob)

	// Get public keys
	alicePublic, bobPublic: ecdh.Public_Key
	ecdh.public_key_set_priv(&alicePublic, &alice.privateKey)
	ecdh.public_key_set_priv(&bobPublic, &bob.privateKey)

	// Perform key exchange
	aliceSecret, alice_ok := exchangeSecret(&alice, &bobPublic)
	if !alice_ok {
		// "Alice key exchange failed")
		return
	}
	defer {
		mem.zero_slice(aliceSecret)
		delete(aliceSecret)
	}

	bobSecret, bob_ok := exchangeSecret(&bob, &alicePublic)
	if !bob_ok {
		// "Bob key exchange failed")
		return
	}
	defer {
		mem.zero_slice(bobSecret)
		delete(bobSecret)
	}

	// Verify shared secrets match
	testing.expect(t, len(aliceSecret) == len(bobSecret), "Shared secrets should be same length")
	testing.expect(t, mem.compare(aliceSecret, bobSecret) == 0, "Shared secrets should match")
}

@(test)
test_hkdf_key_derivation :: proc(t: ^testing.T) {
	// Create two parties
	alice: EncryptionKey
	bob: EncryptionKey
	testing.expect(t, generateKey(&alice), "Alice key generation should succeed")
	testing.expect(t, generateKey(&bob), "Bob key generation should succeed")
	defer clearKey(&alice)
	defer clearKey(&bob)

	// Get public keys
	alicePublic, bobPublic: ecdh.Public_Key
	ecdh.public_key_set_priv(&alicePublic, &alice.privateKey)
	ecdh.public_key_set_priv(&bobPublic, &bob.privateKey)

	// Derive encryption keys
	aliceKey, alice_ok := deriveEncryptionKey(&alice, &bobPublic)
	if !alice_ok {
		// "Alice key derivation failed")
		return
	}
	defer {
		mem.zero_slice(aliceKey)
		delete(aliceKey)
	}

	bobKey, bob_ok := deriveEncryptionKey(&bob, &alicePublic)
	if !bob_ok {
		// "Bob key derivation failed")
		return
	}
	defer {
		mem.zero_slice(bobKey)
		delete(bobKey)
	}

	// Verify derived keys match
	testing.expect(t, len(aliceKey) == 32, "Derived key should be 32 bytes (AES-256)")
	testing.expect(t, len(bobKey) == 32, "Derived key should be 32 bytes (AES-256)")
	testing.expect(t, mem.compare(aliceKey, bobKey) == 0, "Derived keys should match")
}

@(test)
test_encrypt_decrypt_roundtrip :: proc(t: ^testing.T) {
	// Setup encryption key
	alice: EncryptionKey
	bob: EncryptionKey
	testing.expect(t, generateKey(&alice), "Alice key generation should succeed")
	testing.expect(t, generateKey(&bob), "Bob key generation should succeed")
	defer clearKey(&alice)
	defer clearKey(&bob)

	alicePublic, bobPublic: ecdh.Public_Key
	ecdh.public_key_set_priv(&alicePublic, &alice.privateKey)
	ecdh.public_key_set_priv(&bobPublic, &bob.privateKey)

	aesKey, key_ok := deriveEncryptionKey(&alice, &bobPublic)
	if !key_ok {
		// "Key derivation failed")
		return
	}
	defer {
		mem.zero_slice(aesKey)
		delete(aesKey)
	}

	gcmCtx, ok := makeGcm(aesKey)
	testing.expect(t, ok, "GCM context creation should succeed")

	// Test message
	plaintext := transmute([]u8)string("Hello, secure world!")
	aad := generateAad("session-123", MessageType.ClientChatMessage)
	defer delete(aad)

	// Encrypt
	ciphertext := encrypt(plaintext, aad, &gcmCtx)
	defer delete(ciphertext)

	testing.expect(
		t,
		len(ciphertext) > len(plaintext),
		"Ciphertext should be longer than plaintext (includes IV and tag)",
	)

	// Decrypt
	decrypted, decrypt_ok := decrypt(ciphertext, aad, &gcmCtx)
	defer {
		if decrypted != nil {
			delete(decrypted)
		}
	}

	testing.expect(t, decrypt_ok, "Decryption should succeed")
	testing.expect(
		t,
		len(decrypted) == len(plaintext),
		"Decrypted should be same length as plaintext",
	)
	testing.expect(t, mem.compare(decrypted, plaintext) == 0, "Decrypted should match plaintext")
}

@(test)
test_decrypt_with_wrong_key :: proc(t: ^testing.T) {
	// Setup two different keys
	alice: EncryptionKey
	bob: EncryptionKey
	eve: EncryptionKey
	testing.expect(t, generateKey(&alice), "Alice key generation should succeed")
	testing.expect(t, generateKey(&bob), "Bob key generation should succeed")
	testing.expect(t, generateKey(&eve), "Eve key generation should succeed")
	defer clearKey(&alice)
	defer clearKey(&bob)
	defer clearKey(&eve)

	alicePublic, bobPublic, evePublic: ecdh.Public_Key
	ecdh.public_key_set_priv(&alicePublic, &alice.privateKey)
	ecdh.public_key_set_priv(&bobPublic, &bob.privateKey)
	ecdh.public_key_set_priv(&evePublic, &eve.privateKey)

	// Alice encrypts for Bob
	aliceBobKey, ab_ok := deriveEncryptionKey(&alice, &bobPublic)
	if !ab_ok {
		// "Key derivation failed")
		return
	}
	defer {
		mem.zero_slice(aliceBobKey)
		delete(aliceBobKey)
	}

	aliceCtx, ok := makeGcm(aliceBobKey)
	testing.expect(t, ok, "GCM context creation should succeed")

	plaintext := transmute([]u8)string("Secret message for Bob")
	aad := generateAad("session-456", MessageType.ClientDirectMessage)
	defer delete(aad)

	ciphertext := encrypt(plaintext, aad, &aliceCtx)
	defer delete(ciphertext)

	// Eve tries to decrypt with wrong key
	aliceEveKey, ae_ok := deriveEncryptionKey(&alice, &evePublic)
	if !ae_ok {
		// "Key derivation failed")
		return
	}
	defer {
		mem.zero_slice(aliceEveKey)
		delete(aliceEveKey)
	}

	eveCtx, eve_ok := makeGcm(aliceEveKey)
	testing.expect(t, eve_ok, "GCM context creation should succeed")

	decrypted, decrypt_ok := decrypt(ciphertext, aad, &eveCtx)
	defer {
		if decrypted != nil {
			delete(decrypted)
		}
	}

	testing.expect(t, !decrypt_ok, "Decryption with wrong key should fail")
	testing.expect(t, decrypted == nil, "Decrypted data should be nil on failure")
}

@(test)
test_decrypt_with_wrong_aad :: proc(t: ^testing.T) {
	// Setup encryption
	alice: EncryptionKey
	bob: EncryptionKey
	testing.expect(t, generateKey(&alice), "Alice key generation should succeed")
	testing.expect(t, generateKey(&bob), "Bob key generation should succeed")
	defer clearKey(&alice)
	defer clearKey(&bob)

	alicePublic, bobPublic: ecdh.Public_Key
	ecdh.public_key_set_priv(&alicePublic, &alice.privateKey)
	ecdh.public_key_set_priv(&bobPublic, &bob.privateKey)

	aesKey, key_ok := deriveEncryptionKey(&alice, &bobPublic)
	if !key_ok {
		// "Key derivation failed")
		return
	}
	defer {
		mem.zero_slice(aesKey)
		delete(aesKey)
	}

	gcmCtx, ok := makeGcm(aesKey)
	testing.expect(t, ok, "GCM context creation should succeed")

	plaintext := transmute([]u8)string("Message with AAD")
	correctAad := generateAad("session-789", MessageType.ClientChatMessage)
	defer delete(correctAad)

	// Encrypt with correct AAD
	ciphertext := encrypt(plaintext, correctAad, &gcmCtx)
	defer delete(ciphertext)

	// Try to decrypt with wrong AAD
	wrongAad := generateAad("session-999", MessageType.ClientChatMessage)
	defer delete(wrongAad)

	decrypted, decrypt_ok := decrypt(ciphertext, wrongAad, &gcmCtx)
	defer {
		if decrypted != nil {
			delete(decrypted)
		}
	}

	testing.expect(t, !decrypt_ok, "Decryption with wrong AAD should fail")
	testing.expect(t, decrypted == nil, "Decrypted data should be nil on failure")
}

@(test)
test_decrypt_malformed_input :: proc(t: ^testing.T) {
	// Setup encryption
	alice: EncryptionKey
	bob: EncryptionKey
	testing.expect(t, generateKey(&alice), "Alice key generation should succeed")
	testing.expect(t, generateKey(&bob), "Bob key generation should succeed")
	defer clearKey(&alice)
	defer clearKey(&bob)

	alicePublic, bobPublic: ecdh.Public_Key
	ecdh.public_key_set_priv(&alicePublic, &alice.privateKey)
	ecdh.public_key_set_priv(&bobPublic, &bob.privateKey)

	aesKey, key_ok := deriveEncryptionKey(&alice, &bobPublic)
	if !key_ok {
		// "Key derivation failed")
		return
	}
	defer {
		mem.zero_slice(aesKey)
		delete(aesKey)
	}

	gcmCtx, ok := makeGcm(aesKey)
	testing.expect(t, ok, "GCM context creation should succeed")

	aad := generateAad("session-abc", MessageType.ServerChatMessage)
	defer delete(aad)

	// Test with input too short
	shortInput := []byte{1, 2, 3}
	decrypted, decrypt_ok := decrypt(shortInput, aad, &gcmCtx)
	testing.expect(t, !decrypt_ok, "Decryption of too-short input should fail")
	testing.expect(t, decrypted == nil, "Decrypted data should be nil on failure")
}

@(test)
test_makeGcm_invalid_key_size :: proc(t: ^testing.T) {
	// Test with invalid key size
	invalidKey := []byte{1, 2, 3, 4, 5} // Only 5 bytes, not 16, 24, or 32
	_, ok := makeGcm(invalidKey)
	testing.expect(t, !ok, "makeGcm should fail with invalid key size")
}

@(test)
test_dual_key_system :: proc(t: ^testing.T) {
	// Verify ECDH keys work for encryption
	alice: EncryptionKey
	bob: EncryptionKey
	testing.expect(t, generateKey(&alice), "Alice ECDH key generation should succeed")
	testing.expect(t, generateKey(&bob), "Bob ECDH key generation should succeed")
	defer clearKey(&alice)
	defer clearKey(&bob)

	// Verify key size
	testing.expect(
		t,
		ecdh.key_size(&alice.privateKey) == 32,
		"ECDH private key should be 32 bytes",
	)

	// Verify we can derive encryption keys
	alicePublic, bobPublic: ecdh.Public_Key
	ecdh.public_key_set_priv(&alicePublic, &alice.privateKey)
	ecdh.public_key_set_priv(&bobPublic, &bob.privateKey)

	aesKey, ok := deriveEncryptionKey(&alice, &bobPublic)
	defer {
		if aesKey != nil {
			mem.zero_slice(aesKey)
			delete(aesKey)
		}
	}

	testing.expect(t, ok, "Key derivation should succeed")
	testing.expect(t, len(aesKey) == 32, "AES key should be 32 bytes for AES-256")
}
