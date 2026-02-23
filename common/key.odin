package common

import "core:crypto"
import "core:crypto/aes"
import "core:crypto/ecdh"
import "core:crypto/hash"
import "core:crypto/hkdf"
import "core:fmt"
import "core:mem"

/*
Cryptographic Key Management for HayChat

This module provides secure key exchange and encryption using:
- ECDH (X25519) for key exchange
- HKDF-SHA256 for key derivation
- AES-256-GCM for authenticated encryption

Example workflow:
	// 1. Generate key pairs (both parties)
	var aliceKey, bobKey: EncryptionKey
	generateKey(&aliceKey)
	generateKey(&bobKey)
	defer clearKey(&aliceKey)
	defer clearKey(&bobKey)

	// 2. Exchange public keys
	alicePublic := ecdh.Public_Key{}
	ecdh.public_key_set_priv(&alicePublic, &aliceKey.privateKey)
	bobPublic := ecdh.Public_Key{}
	ecdh.public_key_set_priv(&bobPublic, &bobKey.privateKey)

	// 3. Derive shared encryption key (both parties get same result)
	aliceAESKey := deriveEncryptionKey(&aliceKey, &bobPublic) or_return
	defer mem.zero_slice(aliceAESKey)

	// 4. Initialize GCM context
	gcmCtx := makeGcm(aliceAESKey) or_return

	// 5. Encrypt/decrypt messages
	aad := generateAad("session-123", MessageType.ClientChatMessage)
	defer delete(aad)
	ciphertext := encrypt([]byte("secret message"), aad, &gcmCtx)
	plaintext, ok := decrypt(ciphertext, aad, &gcmCtx)
*/

// EncryptionKey represents an ECDH private key used for deriving encryption keys.
// This should only be used for encryption. For authentication, use ed25519 keys separately.
EncryptionKey :: struct {
	privateKey: ecdh.Private_Key,
	gcm:        aes.Context_GCM,
}

// generateKey creates a new random X25519 private key for ECDH key exchange.
// Returns false if the system entropy source is unavailable.
generateKey :: proc(key: ^EncryptionKey) -> (ok: bool) {
	ok = ecdh.private_key_generate(&key.privateKey, ecdh.Curve.X25519)
	return
}

// setKey loads an existing X25519 private key from raw bytes.
// The data must be exactly 32 bytes for X25519.
// Returns false if the data is invalid or wrong size.
setKey :: proc(key: ^EncryptionKey, data: []u8) -> (ok: bool) {
	if len(data) != ecdh.PRIVATE_KEY_SIZES[.X25519] {
		return false
	}
	ok = ecdh.private_key_set_bytes(&key.privateKey, ecdh.Curve.X25519, data)
	return
}

// clearKey securely zeros all sensitive key material in memory.
// Always defer this after creating an EncryptionKey.
clearKey :: proc(key: ^EncryptionKey) {
	ecdh.private_key_clear(&key.privateKey)
	aes.reset_gcm(&key.gcm)
}

// exchangeSecret performs ECDH key exchange to derive a shared secret.
// NOTE: This returns the raw ECDH output. You should use deriveEncryptionKey instead,
// which properly derives an AES key using HKDF.
// The caller must zero and delete the returned shared_secret when done.
exchangeSecret :: proc(
	private_key: ^EncryptionKey,
	public_key: ^ecdh.Public_Key,
) -> (
	shared_secret: []u8,
	ok: bool,
) {
	// X25519 produces a 32-byte shared secret
	shared_secret = make([]u8, ecdh.SHARED_SECRET_SIZES[.X25519])
	ok = ecdh.ecdh(&private_key.privateKey, public_key, shared_secret)
	if !ok {
		mem.zero_slice(shared_secret)
		delete(shared_secret)
		return nil, false
	}
	return
}

// deriveEncryptionKey performs ECDH and derives a 32-byte AES-256 key using HKDF-SHA256.
// This is the recommended way to establish encryption between two parties.
// The caller must zero and delete the returned key when done.
deriveEncryptionKey :: proc(
	private_key: ^EncryptionKey,
	public_key: ^ecdh.Public_Key,
	salt: []u8 = nil,
	info: string = "haychat-encryption-v1",
) -> (
	aes_key: []u8,
	ok: bool,
) {
	// Perform ECDH to get shared secret
	shared_secret := exchangeSecret(private_key, public_key) or_return
	defer {
		mem.zero_slice(shared_secret)
		delete(shared_secret)
	}

	// Derive AES-256 key using HKDF-SHA256
	aes_key = make([]u8, aes.KEY_SIZE_256)
	info_bytes := transmute([]u8)info
	hkdf.extract_and_expand(hash.Algorithm.SHA256, salt, shared_secret, info_bytes, aes_key)

	return aes_key, true
}

// makeGcm initializes an AES-GCM context with the provided key.
// The key must be 16, 24, or 32 bytes (AES-128, AES-192, or AES-256).
// For HayChat, always use 32-byte keys (AES-256) derived from deriveEncryptionKey.
// Returns false if the key size is invalid.
makeGcm :: proc(key: []byte) -> (gcm: aes.Context_GCM, ok: bool) {
	// Validate key size
	if len(key) != aes.KEY_SIZE_128 &&
	   len(key) != aes.KEY_SIZE_192 &&
	   len(key) != aes.KEY_SIZE_256 {
		return gcm, false
	}
	aes.init_gcm(&gcm, key)
	return gcm, true
}

// generateAad creates Additional Authenticated Data for AES-GCM.
// The AAD binds the ciphertext to a specific session and message type,
// preventing ciphertext from being replayed in different contexts.
// IMPORTANT: The caller MUST delete(aad) when done to avoid memory leaks.
generateAad :: proc(
	session_id: string,
	message_type: MessageType,
	allocator := context.allocator,
) -> (
	aad: []byte,
) {
	aad = transmute([]byte)(fmt.aprintf("%s|%d", session_id, message_type, allocator = allocator))
	return
}

// encrypt encrypts plaintext using AES-GCM with a random IV.
// The output format is: [IV || ciphertext || tag]
// The AAD is authenticated but not encrypted.
// Uses standard GCM parameters: 12-byte IV, 16-byte tag.
encrypt :: proc(
	plain, aad: []byte,
	ctx: ^aes.Context_GCM,
	tag_len: int = aes.GCM_TAG_SIZE,
	iv_len: int = aes.GCM_IV_SIZE,
) -> (
	res: []byte,
) {
	res = make_slice([]byte, len(plain) + tag_len + iv_len)

	iv := res[:iv_len]
	crypto.rand_bytes(iv)

	str := res[iv_len:(len(res) - tag_len)]
	tag := res[len(res) - tag_len:]

	aes.seal_gcm(ctx, str, tag, iv, aad, plain)
	return res
}

// decrypt decrypts ciphertext produced by encrypt.
// Expected input format: [IV || ciphertext || tag]
// Returns nil and false if authentication fails or input is malformed.
// Uses standard GCM parameters: 12-byte IV, 16-byte tag.
decrypt :: proc(
	str, aad: []byte,
	ctx: ^aes.Context_GCM,
	tag_len: int = aes.GCM_TAG_SIZE,
	iv_len: int = aes.GCM_IV_SIZE,
) -> (
	res: []byte,
	ok: bool,
) {
	// Validate input is large enough to contain IV and tag
	if len(str) < tag_len + iv_len {
		return nil, false
	}

	res = make_slice([]byte, len(str) - tag_len - iv_len)

	iv := str[:iv_len]
	enc := str[iv_len:(len(str) - tag_len)]
	tag := str[len(str) - tag_len:]

	ok = aes.open_gcm(ctx, res, iv, aad, enc, tag)
	if !ok {
		// Zero and free on authentication failure
		mem.zero_slice(res)
		delete(res)
		return nil, false
	}
	return res, ok
}
