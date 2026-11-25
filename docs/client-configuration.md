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
| `servers[].use_invite_code` | Server settings → Signing up → **Use an invite code** (protocol 25): connect with `registering` set, so a server that would let anyone sign up shows the sign-up screen instead, to enter a code that grants roles or a room. Default off (`false` or absent). It changes nothing for an identity key that already has an account there, and an invite link sets it for its own connection without saving it. The code itself is never saved: it lives in memory until the server answers or the sign-up screen goes away |
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
| `voice_noise_suppression` | `true` (default: background noise is removed from the microphone, and in voice activity mode only speech opens it; see [Noise suppression](user-guide.md#noise-suppression)) or `false`. RNNoise does it, or WebRTC's suppressor while echo cancellation runs (see `voice_echo_cancellation`) or when RNNoise is missing (`librnnoise.so.0` on Linux, `rnnoise.dll` next to the executable on Windows); with neither, voice works without it |
| `voice_echo_cancellation` | `true` (default: WebRTC's AEC3 removes the voices HayChat plays from the microphone, so others do not hear themselves; see [Echo cancellation](user-guide.md#echo-cancellation)) or `false` (for headphones). It takes effect only when WebRTC audio processing loads (`libhaychat-webrtc-apm.so` next to the executable plus the system's `libwebrtc-audio-processing-2.so.1` on Linux, `haychat-webrtc-apm.dll` next to the executable on Windows); otherwise voice works without it. On Windows, while this or noise suppression is on, the audio devices open in raw mode (no Windows processing) |

Settings → Voice writes the voice keys only when they differ from the default, so a later change
of a default reaches everyone who did not choose otherwise. When the config is read,
out-of-range numbers are clamped and invalid strings fall back to the default.

Server settings (`servers[].display_name`, labels, `servers[].user_voice[]`,
`servers[].use_invite_code`) live in this one profile and are not synced between devices.

`haychat://` links (protocol 25, plan D19) are handed from the process the link starts to a
HayChat window that already runs through a file only the user can read: `link-handoff` in
`$XDG_RUNTIME_DIR/haychat/` (or, without a runtime directory, the config directory; on Windows
`%APPDATA%\haychat\`), created new with mode 0600 and deleted once read. The window records
its process ID in `instance` there so the second process knows it runs. Only one window owns
that file: a second window started while the first runs leaves it alone (and does not take
links), a window removes it at exit only while it still names its own process ID, and a file
naming a process that is gone is replaced by the next window. Neither is config.

A confirmed invite link's code stays in memory until the server has used it (you signed in,
the request is waiting for approval, or it was declined), another link replaces it, or the
server is removed or its pinned key changes (changing the address clears the pin). Until then a
settings change that reconnects the server, such as a new display name, still signs up with the
code. It is never written to `config.json` or a log.

`haychat-client --register-url-handler` registers this executable as the handler for
`haychat://` links for the current user and exits:

- **Linux:** writes `haychat.desktop` (`MimeType=x-scheme-handler/haychat;`,
  `Exec="EXECUTABLE" %u`) to `$XDG_DATA_HOME/applications/` (by default
  `~/.local/share/applications/`), runs `xdg-mime default haychat.desktop
  x-scheme-handler/haychat`, and `update-desktop-database` on that directory where it is
  installed.
- **Windows:** writes `HKEY_CURRENT_USER\Software\Classes\haychat` (no administrator rights
  needed): the default value `URL:HayChat Protocol`, an empty `URL Protocol` value, and
  `shell\open\command` = `"EXECUTABLE" "%1"`.

Run it again after moving the client to another folder.

## One Client per Profile

Every client that uses a profile directory (the window, `--ui-script` and `--headless`) first
takes an exclusive lock on `haychat.lock` in it (`$XDG_CONFIG_HOME/haychat/haychat.lock`,
`%APPDATA%\haychat\haychat.lock`): `flock` on Linux, `LockFileEx` on Windows. Two clients on
one profile would each save `config.json` and the key store from their own memory, and the
last save would win: pins, verifications, verified room heads and the "this conversation is
encrypted" flags could be lost (#81).

A second client on a locked profile does not start and reads or writes nothing in it:

- The window shows "HayChat is already running with this profile" in an error dialog (and on
  stderr) and exits with code 1. A second start that only passes a `haychat://` link to the
  running window (above) does so before it would take the lock, so links still work.
- `--headless` prints `{"event":"startup_failed","message":"HayChat is already running with
  this profile","failure":"ProfileLocked"}` and exits with code 3; `--ui-script` prints
  `{"ok":false,"cmd":"start","error":"HayChat is already running with this profile"}` and
  exits with code 1.

The operating system releases the lock when the process ends, a crash or `kill -9` included,
so there is no stale lock to clear and the file holds nothing (deleting it is harmless while
no client runs). A lock that cannot be taken for another reason, such as a file system without
locks, only logs a warning and the client starts as before. To run two clients as the same
user, copy the profile directory while no client runs on it, and give the copy its own
`device_id` (see the table above).

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
  "format": 4,
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
  "rooms": [
    {"room_id": 5, "log_version": 3, "log_head_hash": "<hex SHA-256 of entry 3>"}
  ],
  "room_chains": [
    {"room_id": 5, "epoch": 3, "sender_user_id": 4, "chain_id": "<hex, 16 bytes>",
     "start_index": 0, "chain_key": "<hex, 32 bytes>"}
  ],
  "direct_conversations": [
    {"peer_user_id": 4, "encrypted": true}
  ]
}
```

| Key | Purpose |
| --- | --- |
| `format` | The file format, 4 (protocol 17 added `direct_conversations`, protocol 18 `rooms` entries, protocol 19 `room_chains`; an older file loads as is and is written back as 4). A client that finds a newer format uses the file read-only and never writes it, so a newer client's data survives |
| `server_public_key` | The server the file belongs to; a file for another key is not used for writing |
| `users[]` | One pin per account (see [Encryption keys](user-guide.md#encryption-keys)): the account's identity and encryption keys as first seen (or as last accepted or trusted), the encryption key's creation time (an older key is refused), whether you marked it verified, and when it was first seen |
| `direct_conversations[]` | The accounts (`peer_user_id`) with whom an encrypted direct message was sent or opened on this server (`encrypted` true). Such a conversation is never treated as an ordinary unencrypted one again (no silent downgrade); entries are only ever added |
| `rooms[]` | One entry per encrypted room whose member log this profile verified: the newest verified entry's version (`log_version`) and SHA-256 (`log_head_hash`). A log the server later serves without that exact entry (a fork) or ending before it (a rollback) is refused with "This room's member list was changed on the server". Heads only move forward and are never removed, even when the room is deleted |

| `room_chains[]` | The sender chains of encrypted rooms this profile holds (protocol 19): for a room, an epoch (member log version), a sender and a chain ID, the chain key at `start_index`, from which every later message key of that chain is derived. They come from verified key distributions (this profile's own chains included) and are secret like the private keys in `config.json`. This section is a cache: the server keeps every distribution sealed to its recipients, so a lost file is rebuilt by fetching them again, and old room messages open again. The sending side of a chain is never stored: every run of the client starts new chains, so a message index is never used twice |

A client keeps the key store in memory and saves it whole, so only one client may run on a
profile directory at a time; the [profile lock](#one-client-per-profile) makes sure of it.

Pins are security state: a file that does not parse, has an entry that does not validate, or
belongs to another server key is used read-only for the session and left exactly as it is, and
the client says so under the composer. Deleting the file (or the `keys` directory) only means the
next contact with each account is a first contact again, the encrypted conversations are
marked again as their messages open, and encrypted rooms' member logs are verified again from
the start and their chains fetched again; it does not lose messages, because they are sealed to
the encryption key in `config.json`.
