# Client Configuration

The client keeps its settings, its identity key, and its list of servers in one `config.json`
per profile. The client writes it itself (Settings and Server settings); editing it by hand is
rarely needed. How to use those screens is in the [user guide](user-guide.md).

## Location

- **Linux:** `$XDG_CONFIG_HOME/haychat/config.json`, or `$HOME/.config/haychat/config.json` when
  `XDG_CONFIG_HOME` is unset.
- **Windows:** `%APPDATA%\haychat\config.json`.

The file holds the client's private identity and encryption keys and is written with mode `0600`,
atomically (to `config.json.tmp`, then renamed over the old file). Never share it or attach it to
a bug report. It is the only copy of those keys: a profile that loses it is a new account on
every server, and its end-to-end encrypted messages cannot be read again (see
[Encryption keys](user-guide.md#encryption-keys)).

Older Linux clients wrote to a malformed path, `$HOME$XDG_CONFIG_HOME/haychat/config.json`
(`$HOME$HOME/.config/haychat/config.json` with the default). Startup moves a config found there
to the right place.

## Keys

| Key | Purpose |
| --- | --- |
| `display_name` | The nickname sent to every server that has no `servers[].display_name` of its own. A server's account belongs to the identity key: a new key gets an account under this name, and a new name renames that key's account (see [Display names](rooms-and-accounts.md#display-names)) |
| `private_key`, `public_key` | The client's Ed25519 identity, generated on first start |
| `servers[]` | Configured servers: `id`, `name`, `short_name` (rail label), `host`, `port` |
| `servers[].pinned_server_public_key`, `servers[].pinned_server_fingerprint` | The server identity pinned on first connect. Cleared when the server's address changes or by **Forget key** in Server settings; replaced by **Trust the new key** |
| `servers[].display_name` | The display name used on this server only, set in Server settings. Default unset: the global `display_name`. Surrounding spaces are dropped when the config is read; a name of the wrong length is refused by the client like a bad global name ("Choose another name") |
| `servers[].user_voice[]` | Voice playback per user of this server, set in Server settings → Voice: `user_id` (the server's account ID), `volume` (linear, 0 to 2, i.e. 0 to 200 %; unset is 1) and `muted` (Mute for me: this client does not play that user). Only entries that differ from the default are written, at most 256 per server. When the config is read, entries without a valid `user_id` or equal to the default are dropped, volumes are clamped, and of repeated users the last entry wins. Local only: the server never learns about them |
| `encryption_private_key`, `encryption_public_key` | This profile's X25519 encryption key pair in hex (64 characters each), generated on first start. The private half is a secret like `private_key` and is never printed. One key for every server |
| `encryption_key_signature`, `encryption_key_created_at` | The identity key's Ed25519 signature (hex, 128 characters) over the encryption key bundle, and the bundle's creation time in Unix seconds. The client publishes the bundle to every server it signs in to. At start, a missing key, one that does not parse, a public key that is not the private key's, or a signature that does not verify against `public_key` (for example after the identity key was replaced) is replaced with a new key; other users then see "<name> set up encryption again" |
| `device_id` | This profile's voice device ID: 32 lowercase hex characters, random, generated on first start and sent with every voice join. The server compares it only when the client re-joins voice by itself after a reconnect, to tell this device's stale voice session (replaced) from another device's (left alone). Not a secret, but not logged either. A missing or malformed value is replaced with a new one at start, so deleting the key resets it. A profile directory copied to another machine keeps the same ID, and the two then count as one device for re-joins: delete `device_id` in the copy |
| `voice_input_device` | Microphone, by SDL device name. Default `""`: the system default. A name that is not connected falls back to the system default |
| `voice_output_device` | Speakers or headphones, by SDL device name. Default `""`: the system default |
| `voice_mode` | `"voice_activity"` (default: send while louder than the threshold) or `"push_to_talk"` (send while the push-to-talk key is held) |
| `voice_ptt_key` | The push-to-talk key as an SDL key name, e.g. `"Space"`. Default `"Left Ctrl"`; an unknown name uses the default |
| `voice_ptt_global` | `true` (default: push-to-talk also works while another window has focus, see [Push-to-talk](user-guide.md#push-to-talk)) or `false` (only while the HayChat window has focus) |
| `voice_vad_threshold_db` | Voice activity threshold in dBFS, −80 to 0. Default −45 |
| `voice_input_gain` | Linear microphone gain, 0 to 4. Default 1 |
| `voice_output_volume` | Linear output volume, 0 to 2. Default 1 |
| `voice_bitrate` | Opus bitrate in bit/s, 12000 to 64000. Default 24000 |

Settings → Voice writes the voice keys only when they differ from the default, so a later change
of a default reaches everyone who did not choose otherwise. When the config is read,
out-of-range numbers are clamped and invalid strings fall back to the default.

Server settings (`servers[].display_name`, labels, `servers[].user_voice[]`) live in this one
profile and are not synced between devices.

## Key Store

The other accounts' keys this profile has pinned live in one key store file per server, in a
`keys` directory next to `config.json`:

- **Linux:** `$XDG_CONFIG_HOME/haychat/keys/<server fingerprint>.json`
- **Windows:** `%APPDATA%\haychat\keys\<server fingerprint>.json`

The fingerprint is `servers[].pinned_server_fingerprint`, so a server whose key changed and was
trusted again gets a new, empty key store and its accounts are pinned again. The file is written
with mode `0600` (the directory `0700`), atomically like `config.json`, by the GUI and by the
headless harness (`--config-dir`), never by tests.

```json
{
  "format": 2,
  "server_public_key": "<the server's identity key, hex>",
  "users": [
    {
      "user_id": 4,
      "identity_public_key": "<hex>",
      "encryption_public_key": "<hex>",
      "encryption_key_created_at": 1731600000,
      "verified": false,
      "first_seen": 1731600000
    }
  ],
  "rooms": [],
  "direct_conversations": [
    {"peer_user_id": 4, "encrypted": true}
  ]
}
```

| Key | Purpose |
| --- | --- |
| `format` | The file format, 2 (protocol 17 added `direct_conversations`; a format 1 file loads as is and is written back as 2). A client that finds a newer format uses the file read-only and never writes it, so a newer client's data survives |
| `server_public_key` | The server the file belongs to; a file for another key is not used for writing |
| `users[]` | One pin per account (see [Encryption keys](user-guide.md#encryption-keys)): the account's identity and encryption keys as first seen (or as last accepted or trusted), the encryption key's creation time (an older key is refused), whether you marked it verified, and when it was first seen |
| `direct_conversations[]` | The accounts (`peer_user_id`) with whom an encrypted direct message was sent or opened on this server (`encrypted` true). Such a conversation is never treated as an ordinary unencrypted one again (no silent downgrade); entries are only ever added |
| `rooms[]` | Reserved for encrypted rooms in a later version; empty today |

Pins are security state: a file that does not parse, has an entry that does not validate, or
belongs to another server key is used read-only for the session and left exactly as it is, and
the client says so under the composer. Deleting the file (or the `keys` directory) only means the
next contact with each account is a first contact again, and the encrypted conversations are
marked again as their messages open; it does not lose messages, because they are sealed to the
encryption key in `config.json`.
