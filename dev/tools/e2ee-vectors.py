#!/usr/bin/env python3
"""Known-answer vectors for common/e2ee.odin, from an independent implementation.

This rebuilds every layout of docs/plan/e2ee-design.md that common/e2ee_test.odin pins
(the encryption key bundle, a direct message envelope and its wrap key, the sender chain, a
sealed room message, a member log Create entry, the plaintext fallback signature, the
safety number, and a RoomKeyForward envelope) with Python's `cryptography` package (OpenSSL), not with the Odin code. The
Odin tests compare their own output byte for byte with the values printed here.

`cryptography` has no XChaCha20-Poly1305, so HChaCha20 (draft-irtf-cfrg-xchacha-03,
section 2.2) is written out below and checked against the draft's test vector; the AEAD is
then the IETF ChaCha20-Poly1305 of `cryptography`.

Usage (once; the output is pasted into common/e2ee_test.odin):

    python3 -m venv /tmp/e2ee-venv && /tmp/e2ee-venv/bin/pip install cryptography
    /tmp/e2ee-venv/bin/python -I dev/tools/e2ee-vectors.py

Every input is derived from a label with SHA-256, so the vectors need no randomness.
"""

import hashlib
import struct

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

RAW = serialization.Encoding.Raw
RAW_PUBLIC = serialization.PublicFormat.Raw


def label_bytes(label, size=32):
    return hashlib.sha256(label.encode()).digest()[:size]


def i64(value):
    return struct.pack("<q", value)


def u64(value):
    return struct.pack("<Q", value)


def u32(value):
    return struct.pack("<I", value)


def u16(value):
    return struct.pack("<H", value)


# HChaCha20 and XChaCha20-Poly1305 -----------------------------------------------------------


def rotl32(value, count):
    return ((value << count) & 0xFFFFFFFF) | (value >> (32 - count))


def quarter_round(state, a, b, c, d):
    state[a] = (state[a] + state[b]) & 0xFFFFFFFF
    state[d] = rotl32(state[d] ^ state[a], 16)
    state[c] = (state[c] + state[d]) & 0xFFFFFFFF
    state[b] = rotl32(state[b] ^ state[c], 12)
    state[a] = (state[a] + state[b]) & 0xFFFFFFFF
    state[d] = rotl32(state[d] ^ state[a], 8)
    state[c] = (state[c] + state[d]) & 0xFFFFFFFF
    state[b] = rotl32(state[b] ^ state[c], 7)


def hchacha20(key, nonce16):
    state = [0x61707865, 0x3320646E, 0x79622D32, 0x6B206574]
    state += list(struct.unpack("<8I", key))
    state += list(struct.unpack("<4I", nonce16))
    for _ in range(10):
        quarter_round(state, 0, 4, 8, 12)
        quarter_round(state, 1, 5, 9, 13)
        quarter_round(state, 2, 6, 10, 14)
        quarter_round(state, 3, 7, 11, 15)
        quarter_round(state, 0, 5, 10, 15)
        quarter_round(state, 1, 6, 11, 12)
        quarter_round(state, 2, 7, 8, 13)
        quarter_round(state, 3, 4, 9, 14)
    return struct.pack("<8I", *(state[0:4] + state[12:16]))


def xchacha_seal(key, nonce24, plaintext, aad):
    subkey = hchacha20(key, nonce24[:16])
    return ChaCha20Poly1305(subkey).encrypt(b"\0" * 4 + nonce24[16:], plaintext, aad or None)


def check_hchacha20():
    # draft-irtf-cfrg-xchacha-03, section 2.2.1
    key = bytes(range(32))
    nonce = bytes.fromhex("000000090000004a0000000031415927")
    expected = bytes.fromhex(
        "82413b4227b27bfed30e42508a877d73a0f9e4d58a74a853c12ec41326d3ecdc"
    )
    assert hchacha20(key, nonce) == expected, "HChaCha20 test vector failed"


# Building blocks ------------------------------------------------------------------------------


def hkdf_sha256(ikm, salt, info, length=32):
    return HKDF(algorithm=hashes.SHA256(), length=length, salt=salt, info=info).derive(ikm)


def ed25519_key(seed):
    private = Ed25519PrivateKey.from_private_bytes(seed)
    return private, private.public_key().public_bytes(RAW, RAW_PUBLIC)


def x25519_public(private_bytes):
    private = X25519PrivateKey.from_private_bytes(private_bytes)
    return private.public_key().public_bytes(RAW, RAW_PUBLIC)


def x25519(private_bytes, public_bytes):
    private = X25519PrivateKey.from_private_bytes(private_bytes)
    return private.exchange(X25519PublicKey.from_public_bytes(public_bytes))


def pad(plaintext):
    total = (len(plaintext) // 256 + 1) * 256
    return plaintext + b"\x80" + b"\0" * (total - len(plaintext) - 1)


def cbor_content(content):
    data = content.encode()
    if len(data) < 24:
        header = bytes([0x60 | len(data)])
    elif len(data) < 256:
        header = bytes([0x78, len(data)])
    else:
        header = bytes([0x79]) + struct.pack(">H", len(data))
    return b"\xa1\x67content" + header + data


# Fixtures shared with common/e2ee_test.odin ----------------------------------------------------

SERVER_SEED = label_bytes("haychat-e2ee-test-server-identity")
ALICE_SEED = label_bytes("haychat-e2ee-test-alice-identity")
BOB_SEED = label_bytes("haychat-e2ee-test-bob-identity")
CAROL_SEED = label_bytes("haychat-e2ee-test-carol-identity")
ALICE_ENCRYPTION = label_bytes("haychat-e2ee-test-alice-encryption")
BOB_ENCRYPTION = label_bytes("haychat-e2ee-test-bob-encryption")
CAROL_ENCRYPTION = label_bytes("haychat-e2ee-test-carol-encryption")
ALICE_ID, BOB_ID, CAROL_ID = 7, 9, 11
ROOM_ID = 42
CREATED_AT = 1_763_078_400  # 2025-11-14 00:00:00 UTC

_, SERVER_PUBLIC = ed25519_key(SERVER_SEED)
ALICE_PRIVATE, ALICE_PUBLIC = ed25519_key(ALICE_SEED)
BOB_PRIVATE, BOB_PUBLIC = ed25519_key(BOB_SEED)
CAROL_PRIVATE, CAROL_PUBLIC = ed25519_key(CAROL_SEED)
ALICE_ENCRYPTION_PUBLIC = x25519_public(ALICE_ENCRYPTION)
BOB_ENCRYPTION_PUBLIC = x25519_public(BOB_ENCRYPTION)
CAROL_ENCRYPTION_PUBLIC = x25519_public(CAROL_ENCRYPTION)


def show(name, value):
    """Prints an Odin string constant, split into 80-character pieces joined with +."""
    text = value.hex() if isinstance(value, bytes) else value
    if len(name) + len(text) + 10 <= 100:
        print(f'{name} :: "{text}"')
        return
    pieces = [text[i : i + 80] for i in range(0, len(text), 80)]
    print(f"{name} ::")
    for index, piece in enumerate(pieces):
        print(f'\t"{piece}"' + (" +" if index < len(pieces) - 1 else ""))


def bundle_vector():
    signed = (
        b"haychat-e2ee-encryption-key-v1" + ALICE_PUBLIC + ALICE_ENCRYPTION_PUBLIC + u64(CREATED_AT)
    )
    show("KAT_BUNDLE_SIGNATURE", ALICE_PRIVATE.sign(signed))


def direct_message_vector():
    client_message_id = label_bytes("haychat-e2ee-test-dm-client-message-id", 16)
    aad = (
        b"haychat-dm-v1"
        + SERVER_PUBLIC
        + i64(ALICE_ID)
        + i64(BOB_ID)
        + ALICE_PUBLIC
        + BOB_PUBLIC
        + client_message_id
    )
    message_key = label_bytes("haychat-e2ee-test-dm-message-key")
    ephemeral_private = label_bytes("haychat-e2ee-test-dm-ephemeral")
    nonce = label_bytes("haychat-e2ee-test-dm-nonce", 24)
    ephemeral_public = x25519_public(ephemeral_private)
    kind = 1

    envelope = bytes([1, kind]) + ephemeral_public + u16(2)
    wrap_keys = {}
    for user_id, encryption_public in (
        (ALICE_ID, ALICE_ENCRYPTION_PUBLIC),
        (BOB_ID, BOB_ENCRYPTION_PUBLIC),
    ):
        shared = x25519(ephemeral_private, encryption_public)
        wrap_key = hkdf_sha256(
            shared,
            ephemeral_public + encryption_public,
            b"haychat-e2ee-wrap-v1" + bytes([kind]) + aad,
        )
        wrap_keys[user_id] = wrap_key
        envelope += i64(user_id) + xchacha_seal(wrap_key, b"\0" * 24, message_key, b"")
    body = xchacha_seal(message_key, nonce, pad(cbor_content("hello, bob")), aad)
    envelope += nonce + u32(len(body)) + body
    envelope += ALICE_PRIVATE.sign(b"haychat-e2ee-envelope-v1" + aad + envelope)

    # The recipient's side of the wrap key, from bob's private key.
    assert x25519(BOB_ENCRYPTION, ephemeral_public) == x25519(
        ephemeral_private, BOB_ENCRYPTION_PUBLIC
    )
    show("KAT_DM_WRAP_KEY_BOB", wrap_keys[BOB_ID])
    show("KAT_DM_ENVELOPE", envelope)


def chain_vector():
    chain_key = label_bytes("haychat-e2ee-test-chain-key-0")
    message_keys = []
    for _ in range(1000):
        message_keys.append(hkdf_sha256(chain_key, None, b"haychat-room-msg-v1"))
        chain_key = hkdf_sha256(chain_key, None, b"haychat-room-chain-v1")
        if len(message_keys) == 1:
            show("KAT_CHAIN_KEY_1", chain_key)
    show("KAT_CHAIN_MESSAGE_KEY_0", message_keys[0])
    show("KAT_CHAIN_MESSAGE_KEY_1", message_keys[1])
    show("KAT_CHAIN_MESSAGE_KEY_5", message_keys[5])
    show("KAT_CHAIN_MESSAGE_KEY_999", message_keys[999])
    return message_keys


def room_message_vector(message_keys):
    chain_id = label_bytes("haychat-e2ee-test-chain-id", 16)
    client_message_id = label_bytes("haychat-e2ee-test-room-client-message-id", 16)
    nonce = label_bytes("haychat-e2ee-test-room-nonce", 24)
    epoch, index = 3, 5
    aad = (
        b"haychat-room-v1"
        + SERVER_PUBLIC
        + i64(ROOM_ID)
        + i64(ALICE_ID)
        + i64(epoch)
        + chain_id
        + u32(index)
        + client_message_id
    )
    body = xchacha_seal(message_keys[index], nonce, pad(cbor_content("hi room")), aad)
    message = bytes([1]) + i64(epoch) + chain_id + u32(index) + nonce + u32(len(body)) + body
    message += ALICE_PRIVATE.sign(b"haychat-room-message-v1" + aad + message)
    show("KAT_ROOM_MESSAGE", message)


def room_log_vector():
    entry = bytes([1]) + i64(ROOM_ID) + i64(1) + b"\0" * 32 + bytes([1])
    entry += i64(ALICE_ID) + ALICE_PUBLIC + i64(ALICE_ID) + ALICE_PUBLIC + u64(CREATED_AT)
    entry += bytes([1, 3, 2, 1]) + u16(2)
    entry += i64(ALICE_ID) + ALICE_PUBLIC + i64(CAROL_ID) + CAROL_PUBLIC
    entry += ALICE_PRIVATE.sign(b"haychat-room-log-v1" + SERVER_PUBLIC + entry)
    show("KAT_ROOM_LOG_CREATE", entry)
    show("KAT_ROOM_LOG_CREATE_HASH", hashlib.sha256(entry).digest())


def fallback_vector():
    client_message_id = label_bytes("haychat-e2ee-test-plain-client-message-id", 16)
    signed = (
        b"haychat-dm-plain-v1"
        + SERVER_PUBLIC
        + i64(ALICE_ID)
        + i64(BOB_ID)
        + client_message_id
        + "plain hello".encode()
    )
    show("KAT_PLAIN_SIGNATURE", ALICE_PRIVATE.sign(signed))


def safety_number_vector():
    first, second = sorted([ALICE_PUBLIC, BOB_PUBLIC])
    digest = hashlib.sha512(b"haychat-safety-number-v1" + first + second).digest()
    groups = [int.from_bytes(digest[i * 5 : i * 5 + 5], "big") % 100000 for i in range(12)]
    show("KAT_SAFETY_NUMBER", " ".join(f"{group:05d}" for group in groups))


def room_key_forward_vector():
    """bob forwards alice's chain (epoch 3, from index 0) to carol (design 6.6, protocol 20)."""
    chain_id = label_bytes("haychat-e2ee-test-chain-id", 16)
    chain_key = label_bytes("haychat-e2ee-test-chain-key-0")
    epoch, start_index = 3, 0
    aad = (
        b"haychat-room-key-forward-v1"
        + SERVER_PUBLIC
        + i64(ROOM_ID)
        + i64(epoch)
        + i64(ALICE_ID)
        + chain_id
        + i64(BOB_ID)
        + i64(CAROL_ID)
    )
    assert len(aad) == 115
    plaintext = bytes([1]) + i64(ROOM_ID) + i64(epoch) + chain_id + u32(start_index) + chain_key
    message_key = label_bytes("haychat-e2ee-test-forward-message-key")
    ephemeral_private = label_bytes("haychat-e2ee-test-forward-ephemeral")
    nonce = label_bytes("haychat-e2ee-test-forward-nonce", 24)
    ephemeral_public = x25519_public(ephemeral_private)
    kind = 3
    envelope = bytes([1, kind]) + ephemeral_public + u16(1)
    shared = x25519(ephemeral_private, CAROL_ENCRYPTION_PUBLIC)
    wrap_key = hkdf_sha256(
        shared,
        ephemeral_public + CAROL_ENCRYPTION_PUBLIC,
        b"haychat-e2ee-wrap-v1" + bytes([kind]) + aad,
    )
    envelope += i64(CAROL_ID) + xchacha_seal(wrap_key, b"\0" * 24, message_key, b"")
    body = xchacha_seal(message_key, nonce, pad(plaintext), aad)
    envelope += nonce + u32(len(body)) + body
    envelope += BOB_PRIVATE.sign(b"haychat-e2ee-envelope-v1" + aad + envelope)
    show("KAT_ROOM_KEY_FORWARD", envelope)


def main():
    check_hchacha20()
    print("// Generated by dev/tools/e2ee-vectors.py")
    show("KAT_SERVER_PUBLIC", SERVER_PUBLIC)
    show("KAT_ALICE_PUBLIC", ALICE_PUBLIC)
    show("KAT_ALICE_ENCRYPTION_PUBLIC", ALICE_ENCRYPTION_PUBLIC)
    bundle_vector()
    direct_message_vector()
    message_keys = chain_vector()
    room_message_vector(message_keys)
    room_log_vector()
    fallback_vector()
    safety_number_vector()
    room_key_forward_vector()


if __name__ == "__main__":
    main()
