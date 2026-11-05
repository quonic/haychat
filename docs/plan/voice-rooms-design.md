# Voice rooms: design (work package E)

**Date:** 2026-11-05
**Base:** `main` at `60ea446`
**Status:** Design. H0 (server network loop, PR #8), H1 (per-channel transport keys and
replay window, protocol 9) and H2 (binary voice frames, TOC check, kind-bound voice AAD and the
voice control messages, protocol 10) are implemented; H3–H8 follow section 7.
**Audience:** HayChat maintainers and the agents that will implement package H

This document designs voice rooms for HayChat: audio I/O, codec, wire format, transport
crypto changes, server relay, client pipeline and UI, a test plan that runs headless, and a
PR-sized work breakdown. Each section makes a recommendation and lists the alternatives it
rejects. Section 8 lists open questions for the maintainer.

## Summary

| Decision | Recommendation |
| --- | --- |
| Audio I/O | SDL3 audio (`vendor:sdl3`), which the client already links. Push model on a new voice thread. One `SDL_AudioStream` per remote speaker, bound to one playback device, so SDL does the mixing and per-user volume. |
| Codec | Opus, 48 kHz mono, 20 ms frames, 24 kbit/s constrained VBR, in-band FEC, complexity 8. A small Odin binding that loads libopus at runtime with `core:dynlib`. |
| Packaging | Linux: the `opus` runtime package (`libopus.so.0`), not `opus-devel`. Windows: `libopus-0.dll` from `%ODIN_ROOT%\vendor\sdl3\mixer\`, copied next to `client.exe` like `SDL3.dll`. |
| Wire | Control messages stay CBOR on the reliable Chat channel. Voice frames use a compact binary envelope on ENet channel `Voice` (2), sent `UNSEQUENCED`. The binary envelope adds 38 bytes per frame; the CBOR envelope would add 214. |
| Transport crypto | Per-channel keys and sequence counters. The reliable channel keeps its strict counter. The Voice channel gets a 64-packet sliding replay window, checked before decryption and updated only after decryption succeeds. The nonce and AAD both bind the channel and the sequence. A bad voice packet is dropped and counted; it never tears the session down. |
| Server | The router is the control plane: join, leave, membership checks and participant fan-out. The network thread is the data plane: a `VoiceRelay` holds the Voice-channel crypto state for each peer and a room-to-peers table, opens each frame, and reseals it for each other participant. Voice frames never pass through the router, the IPC queue or the database. |
| Client | A `VoiceEngine` with its own thread runs capture → VAD/PTT → Opus → seal → send, and receive → jitter buffer → decode/PLC/FEC → per-speaker SDL stream. Its file source and file sink let the headless harness drive it without an audio device. |
| Tests | CI uses file sources and sinks (and SDL's `disk` audio driver) with no audio server: one headless client sends a 440 Hz tone, another records what it decodes, and an Odin Goertzel check verifies the frequency. Manual and host tests use PipeWire null sinks with `pw-cat`, `sox` and `ffmpeg`. |
| Prerequisite | Fix the server network loop first (step H0). Today it moves at most one outbound IPC message per ENet event, so voice fan-out would back up without limit. |

**Biggest risk:** the server network loop (section 0.3). Fan-out sends N−1 packets for every
packet received, but the loop drains one outbound message per received event. The send queue
would grow every second a room has three or more participants and someone talks.

## 0. What exists today

This section describes `main` at `60ea446`. Each finding names the file it comes from.

### 0.1 Protocol placeholders

- `common/protocol.odin` has `MessageType.ClientVoiceData`/`ServerVoiceData`,
  `RoomType.Voice`/`ChatAndVoice`, `RoomPermissions.groupsCanVoice`, and a `VoiceData`
  struct (`senderId: int`, `roomId: int`, `timestamp: datetime.DateTime`, `data: []u8`).
  Nothing uses them.
  `VoiceData` is not fit for the wire. A CBOR `datetime.DateTime` and two `int`s cost more
  than the Opus payload, and a wall-clock timestamp is the wrong clock for a jitter buffer.
  Replace it (section 3.3).
- The database has no room type. `rooms` has `id, name, description, created_by_user_id,
  created_at` (`server/database.odin`), and `common.RoomSummary` has `id, name, description`.
  `RoomType` exists only in the unused `common.Room`.
- `NetworkChannel` (`server/ipc.odin`) is `None = 0, Chat, Voice, Video, Screenshare,
  FileTransfer`. The server creates its ENet host with `channelLimit =
  uint(NetworkChannel.FileTransfer)`, which is 5 (`server/network.odin`). The client
  connects with `STARTUP_AUTH_CHANNEL_COUNT :: uint(5)` (`client/transport.odin`). So channels
  0–4 are usable: Voice (2) is fine. FileTransfer (5) is out of range; that doesn't matter
  here, but someone should fix it.

### 0.2 Transport crypto (`common/auth.odin`)

- `TransportState` has one `nextSendSequence` and one `nextReceiveSequence` per session.
  `TransportState_acceptReceiveSequence` accepts only `sequence == nextReceiveSequence`.
- `sealTransportPayload` generates a **random** 24-byte XChaCha20 nonce. It sends that nonce
  in the envelope and binds `sessionID || sequence` as AAD (`makeTransportAAD`,
  `TRANSPORT_AAD_SIZE = 16 + 8`). The nonce is not derived from the sequence, and the
  channel is in neither the nonce nor the AAD.
- `openPacketForSession` checks the sequence **before** it decrypts, and advances the
  counter as part of that check. With a strict counter on a reliable channel this is
  harmless. With a replay window it would let one forged packet move the window and lock out
  real traffic. A window must be checked first and committed only after the tag verifies.
- If the client fails to open a packet, it calls `ClientServerTransport_fail`, which tears
  down the ENet session (`client/transport.odin`,
  `ClientServerTransport_handleRuntimePacketBytes`). The server calls
  `MainRouterState_protocolViolation` (`server/main.odin`,
  `MainRouterState_handleEncryptedPacket`). Both responses are right for the reliable
  channel. For datagrams that ENet does not authenticate, they hand any off-path spoofer a
  way to disconnect people.
- Every encrypted packet is three nested CBOR values: `Packet{messageType, payload}`, which
  holds `EncryptedPacket{sessionID, sequence, nonce, tag, ciphertext}`, whose ciphertext is
  another `Packet`. Odin's CBOR encodes structs as maps with text keys. I measured it with
  `core:encoding/cbor` and the struct definitions copied from the repo: a 60-byte Opus frame
  in a `{roomId, frameSequence, timestampSamples, opus}` payload becomes **274 bytes**, which
  is **214 bytes of overhead**. At 50 frames per second that's 86 kbit/s of envelope around
  24 kbit/s of audio.

### 0.3 Server data path

- The server's "processes" are threads in one process. The IPC between them is a set of
  mutex-protected in-memory `[dynamic]` queues (`server/ipc.odin`). `IPC_Client_poll` pops
  one message with `ordered_remove(queue, 0)`, which costs O(n).
- `networkServerLoop` (`server/network.odin`) calls `ENet.host_service(host, &event, 100)`
  and then polls **one** IPC message per iteration. Outbound traffic (router →
  `NetworkSendData`) therefore drains at about one message per inbound ENet event, plus ten
  per second from the 100 ms timeout. If one speaker in a three-person room sends 50 frames
  per second, the router needs 100 sends per second but the loop drains only about 60. The
  queue and the latency grow without limit. Chat today hides this because it is
  request/response.
- Each send is `RELIABLE` and is followed by `host_flush` and a `printfln`
  (`handleNetworkSendData`). Each received packet is also queued to a worker thread
  (`NetworkThreadPool_enqueueToPeer`), and the worker only prints a line about it. The worker
  threads spin on `thread.yield()` when their queues are empty
  (`server/network_threading.odin`), so they use CPU even when idle.
- The router owns each peer's transport state (`RouterPeerSession.transport` in
  `server/main.odin`). It keeps a session by value, copying it out of the map, changing it,
  and writing it back. `MainRouterState_handleNetworkDataReceived` returns early when
  `msg.channel != .Chat`, so voice packets are dropped today. `MainRouterState_sendPeerPacket`
  always sends on `.Chat`.
- `mainLoop` handles one IPC message per iteration, then `thread.yield()`.

### 0.4 Client data path

- `ClientNetworkWorker` (`client/network_worker.odin`) holds one mutex over the ENet hosts,
  the transport crypto state and the event queue. Each pass calls `host_service(host, &event,
  0)` up to 16 times per server, then sleeps 5 ms **without** the lock.
  `ClientNetworkWorker_popEvent` also uses `ordered_remove(&events, 0)`.
- `ClientServerTransport_serviceRuntime` ignores `event.channelID`. Every send goes through
  `ClientServerTransport_sendENetPacket`, which always sets `{.RELIABLE}` and uses
  `STARTUP_AUTH_CHANNEL_CHAT` (1).
- `runApp` calls `SDL.Init({.VIDEO, .EVENTS})` (`client/app.odin`). It doesn't initialise
  audio. The UI loop waits on `SDL.WaitEventTimeout` and the worker wakes it with an SDL user
  event, so the UI thread is idle most of the time. Audio must not depend on the UI thread.

### 0.5 Toolchain and host

| Item | Finding | Checked in |
| --- | --- | --- |
| SDL3 audio binding | `GetAudioRecordingDevices`, `GetAudioPlaybackDevices`, `GetAudioDeviceName`, `GetAudioDeviceFormat`, `OpenAudioDeviceStream`, `CreateAudioStream`, `BindAudioStreams`, `PutAudioStreamData`, `GetAudioStreamData`, `GetAudioStreamAvailable`, `GetAudioStreamQueued`, `SetAudioStreamGain`, `SetAudioStreamFormat`, `ResumeAudioStreamDevice`, `LoadWAV`, `ConvertAudioSamples`, `AUDIO_DEVICE_DEFAULT_RECORDING`/`PLAYBACK` | `$HOME/Odin/vendor/sdl3/sdl3_audio.odin` |
| SDL3 audio hints | `HINT_AUDIO_DRIVER`, `HINT_AUDIO_DISK_INPUT_FILE`, `HINT_AUDIO_DISK_OUTPUT_FILE`, `HINT_AUDIO_DISK_TIMESCALE`, `HINT_AUDIO_DUMMY_TIMESCALE`, `HINT_AUDIO_DEVICE_STREAM_ROLE`, `HINT_AUDIO_DEVICE_SAMPLE_FRAMES` | `$HOME/Odin/vendor/sdl3/sdl3_hints.odin` |
| SDL3 hotplug events | `AUDIO_DEVICE_ADDED`, `AUDIO_DEVICE_REMOVED`, `AUDIO_DEVICE_FORMAT_CHANGED` | `$HOME/Odin/vendor/sdl3/sdl3_events.odin` |
| SDL3 on Fedora 44 | `SDL3-3.4.18-1.fc44` includes the drivers `pipewire`, `pulseaudio`, `alsa`, `jack`, `disk` and `dummy` | `strings /usr/lib64/libSDL3.so.0`, `rpm -q SDL3` |
| miniaudio binding | Version 0.11.26. Its backends are `wasapi … pulseaudio, alsa, jack … null`, with **no PipeWire backend**, so it would reach PipeWire through pipewire-pulse. On Linux it needs `lib/miniaudio.a` built with `vendor/miniaudio/src/build_miniaudio.sh`, and the binding `#panic`s if that file is missing. | `$HOME/Odin/vendor/miniaudio/device_io_types.odin`, `common.odin` |
| Opus binding | None in `$HOME/Odin/vendor` or `$HOME/Odin/shared` | `find $HOME/Odin -iname '*opus*'` |
| libopus on Windows | `$HOME/Odin/vendor/sdl3/mixer/libopus-0.dll` (shipped for SDL3_mixer) exports `opus_encoder_create`, `opus_encode_float`, `opus_encoder_ctl`, `opus_decoder_create`, `opus_decode_float`, `opus_decoder_ctl` and the rest. There is no import `.lib`. | `objdump -p libopus-0.dll` |
| libopus on Linux | `opus-1.6-2.fc44` is installed on the host. `opus-devel` is not, so there is no `libopus.so` link name, only `libopus.so.0`. | `rpm -q`, `nm -D /usr/lib64/libopus.so.0` |
| Opus constants | `OPUS_APPLICATION_VOIP = 2048`, `OPUS_SIGNAL_VOICE = 3001`, `OPUS_SET_BITRATE_REQUEST = 4002`, `OPUS_SET_VBR_REQUEST = 4006`, `OPUS_SET_COMPLEXITY_REQUEST = 4010`, `OPUS_SET_INBAND_FEC_REQUEST = 4012`, `OPUS_SET_PACKET_LOSS_PERC_REQUEST = 4014`, `OPUS_SET_DTX_REQUEST = 4016`, `OPUS_SET_VBR_CONSTRAINT_REQUEST = 4020`, `OPUS_SET_SIGNAL_REQUEST = 4024`, `OPUS_GET_LOOKAHEAD_REQUEST = 4027`, `OPUS_RESET_STATE = 4028`, `OPUS_GET_LAST_PACKET_DURATION_REQUEST = 4039`, `OPUS_GET_IN_DTX_REQUEST = 4049` | `xiph/opus` `include/opus_defines.h` and `opus.h` on `main`, fetched 2026-11-05 |
| ENet | `PacketFlag{RELIABLE = 0, UNSEQUENCED = 1, NO_ALLOCATE = 2, UNRELIABLE_FRAGMENT = 3}`, `HOST_DEFAULT_MTU :: 1392` | `$HOME/Odin/vendor/ENet/enet.odin` |
| Host audio tools | `pw-cli`, `pw-cat`, `pw-record`, `pw-play`, `pw-loopback`, `pactl`, `sox`, `ffmpeg`, `espeak-ng`, `python3` with numpy 2.4. The server is PipeWire 1.6.11 (`pactl info`). | `command -v`, `pactl info` |

The host's Odin (`db92c6de`, 2026-11-03) is newer than the pin (`b76605be`).
`git diff b76605be..HEAD` touches only `vendor/miniaudio` among the files above, so the SDL3
audio and ENet bindings I read are the ones the pinned toolchain has.

I ran three prototypes in a scratch directory. None of them is committed.

1. **Runtime-loaded libopus.** `dynlib.initialize_symbols(&opus, "libopus.so.0", "opus_")`
   loaded 8 symbols from libopus 1.6. `opus_encoder_ctl` declared with
   `#c_vararg args: ..any` set the bitrate and FEC flag (both returned `OPUS_OK`). Encoding
   960 samples gave 57 bytes, decoding them gave 960 samples, and PLC
   (`opus_decode_float(dec, nil, 0, …)`) gave 960 samples.
2. **SDL3 `disk` driver as a capture source.** With `SDL_AUDIO_DRIVER=disk`,
   `SDL_AUDIO_DISK_INPUT_FILE=tone440.f32` (raw F32LE mono 48 kHz from `sox`) and
   `SDL_AUDIO_DISK_TIMESCALE=4`, `OpenAudioDeviceStream(AUDIO_DEVICE_DEFAULT_RECORDING,
   {F32, 1, 48000})` delivered the tone, and a zero-crossing count measured 439.5 Hz. No
   audio server was involved, so this works in a podman container.
3. **Opus round trip and frequency checks with host tools.** I encoded a `sox` 440 Hz tone
   with `ffmpeg -c:a libopus -b:a 24k -frame_duration 20 -application voip` and decoded it
   again. `sox … -n stat` reported `Rough frequency: 439` for both the original and the
   decoded file. `sox stat -freq` prints FFT bins (its peak was 445.3 Hz), which makes it a
   worse pass/fail check than `Rough frequency`.

## 1. Audio I/O

### 1.1 Recommendation: SDL3 audio

| Criterion | SDL3 audio | `vendor:miniaudio` | Direct PipeWire/WASAPI |
| --- | --- | --- | --- |
| Already linked | Yes: the client links SDL3 for video, so only `.AUDIO` has to be added to `SDL.Init` | No: a second audio stack in the process | No: two code paths |
| Linux backend | Native `pipewire` driver, falling back to `pulseaudio`, `alsa` and `jack` (verified in Fedora's SDL3 3.4.18) | PulseAudio, ALSA or JACK; reaches PipeWire through pipewire-pulse | Native, but Linux-only code |
| Windows backend | WASAPI | WASAPI | WASAPI, Windows-only code |
| Build impact | None | `build_miniaudio.sh` in `dev/bootstrap-odin.sh` and CI; the binding `#panic`s without `lib/miniaudio.a` | Large |
| Format, rate and channel conversion | Built into `SDL_AudioStream`: the app asks for F32 mono 48 kHz and SDL converts from whatever the device uses | `ma_data_converter`/`ma_resampler` | Hand-written |
| Mixing | Every stream bound to a device is mixed by SDL; `SetAudioStreamGain` gives per-stream volume | `ma_engine` or a hand-written mix | Hand-written |
| Hotplug | `AUDIO_DEVICE_ADDED`/`REMOVED` events, which the UI loop already pumps | Notification callback | Per platform |
| Headless test path | `disk` driver: a raw file in and a raw file out, faster than real time with `DISK_TIMESCALE` (verified); `dummy` driver | `null` backend (no file I/O) | None |
| Extra DSP (AEC, noise suppression) | None | None worth using (it has filters, no AEC) | PipeWire's `module-echo-cancel` can be used from outside the app with either option |

Rejected:

- **miniaudio.** It duplicates what SDL3 already gives us, adds a build step to the image
  and CI, and its Linux path goes through PulseAudio emulation. It would be worth using only
  if we dropped SDL, and we won't.
- **Direct platform APIs.** Too much code for no gain at this stage.

### 1.2 Devices

- Enumerate with `GetAudioRecordingDevices` and `GetAudioPlaybackDevices` and label each
  device with `GetAudioDeviceName`. The list starts with a "System default" entry that maps
  to `AUDIO_DEVICE_DEFAULT_RECORDING`/`AUDIO_DEVICE_DEFAULT_PLAYBACK`. Default devices follow
  the system default when it changes, which is the behaviour most users want.
- **Persist the device name, not the ID.** `AudioDeviceID`s are not stable across runs. The
  config stores `voice_input_device` and `voice_output_device` as names, with `""` meaning
  the system default. At open time the client matches the name exactly and falls back to the
  default device if no name matches (and shows a notice saying so).
- Refresh the list on `AUDIO_DEVICE_ADDED`/`REMOVED`. If the open device is removed, reopen
  on the default device and show a notice. These events reach the UI loop in `app.odin`,
  which forwards them to the `VoiceEngine` as commands. The UI thread doesn't touch audio
  streams itself.
- Set `HINT_AUDIO_DEVICE_STREAM_ROLE` to `"Communication"` before opening, so PipeWire and
  WASAPI can route and duck the stream correctly. Set `HINT_AUDIO_DEVICE_STREAM_NAME` to
  `"HayChat voice"` so the stream is recognisable in `pavucontrol` and `pw-top`.
- Ask for small device buffers with `HINT_AUDIO_DEVICE_SAMPLE_FRAMES = "480"` (10 ms). SDL
  treats it as a hint, and PipeWire usually honours it. On my host's default device the disk
  driver reported 1024 frames and `S16LE` 44.1 kHz. The app's 48 kHz F32 stream is converted
  either way.

### 1.3 Formats

- The application format is **F32, mono, 48 kHz** everywhere. That's Opus's native rate, so
  the codec never resamples. All conversion happens inside SDL streams.
- Capture: `OpenAudioDeviceStream(recordingDevice, &{.F32, 1, 48000}, nil, nil)` returns a
  stream whose output side is our spec. SDL resamples and downmixes the device's native
  format into it.
- Playback: one logical playback device opened with `OpenAudioDevice(playbackDevice,
  &{.F32, 2, 48000})` (stereo leaves room for panning later). Each remote speaker gets
  `CreateAudioStream(&{.F32, 1, 48000}, &{.F32, 2, 48000})`, bound with `BindAudioStream`.
  SDL mixes every bound stream. Per-user volume is `SetAudioStreamGain` and master volume is
  `SetAudioDeviceGain`.
- No SDL audio callbacks. The voice thread **pushes** to and **pulls** from the streams (see
  1.4). Callbacks would run on SDL's audio thread, and we would then have to make the codec
  and jitter-buffer state safe for that thread. The push model keeps all of it on one thread
  we own. The SDL stream functions are documented as thread safe.

### 1.4 Threads

The client gets one new thread. The table lists every thread that touches voice.

| Thread | Owns | Voice work |
| --- | --- | --- |
| UI (SDL loop, `app.odin`) | `State` | Issues commands (join, leave, mute, deafen, PTT key down/up, device change) to `VoiceEngine` through a small locked command queue, and reads a snapshot of speaking flags and levels each frame. It does no audio or crypto work. |
| Network worker (`network_worker.odin`) | ENet hosts, control-channel crypto, **Voice-channel receive crypto** | On a `channelID == Voice` receive: replay-window check, open, parse, push `(senderUserID, frameSequence, flags, opus bytes)` into `VoiceEngine`'s inbound queue. No decoding. |
| **Voice thread (new, `client/voice_engine.odin`)** | Capture stream, playback device and per-speaker streams, Opus encoder and decoders, jitter buffers, VAD, **Voice-channel send crypto** | Ticks about every 5 ms. Capture: while the capture stream has at least 960 samples available, read one frame, run VAD/PTT, encode, seal, then send under `ClientNetworkWorker_lock` (just `peer_send`). Playback: for each speaker whose stream has less than `targetQueued` buffered, pop or conceal one frame from its jitter buffer, decode it and put it. |
| SDL audio thread (internal) | Device I/O | Pulls from and pushes to SDL streams. None of our code runs on it. |

Why the send side doesn't go through the worker queue: the worker sleeps 5 ms between passes.
Holding its mutex only for `ENet.peer_send` takes microseconds and adds no delay. ENet hosts
are not thread safe, so the lock is required. `host_flush` happens on the worker's next
`host_service`, within 5 ms; or the voice thread calls `host_flush` while it holds the lock.
Step H4 measures which is better.

Because voice crypto is split into its own per-channel state (section 3.2), the voice thread
owns the Voice **send** counter outright and the worker owns the Voice **receive** window.
Neither ever touches the control channel's state, so the voice thread takes the worker lock
only around ENet calls.

### 1.5 Echo, noise and gain

- SDL does no acoustic echo cancellation (AEC) and neither does Opus. For user testing,
  **recommend headphones** and document PipeWire's `module-echo-cancel`
  (`pactl load-module module-echo-cancel`) for speaker users on Linux. Windows
  "communications" devices often have AEC in the driver.
- Use a simple noise gate and level meter in v1 (section 5.3). RNNoise or speexdsp (both C
  libraries, either loadable the same way as libopus) can come later: open question Q6.

## 2. Codec: Opus

### 2.1 Parameters

| Parameter | Value | Why |
| --- | --- | --- |
| Sample rate, channels | 48 000 Hz, mono | Opus's native rate; voice doesn't need stereo |
| Frame | 20 ms, 960 samples | The usual VoIP trade-off; 50 packets per second |
| Application | `OPUS_APPLICATION_VOIP` (2048) | Tuned for speech intelligibility |
| Signal | `OPUS_SIGNAL_VOICE` (3001) | Biases mode decisions toward SILK/hybrid |
| Bitrate | 24 kbit/s by default; config range 12–64 kbit/s | Clear wideband/super-wideband speech; about 60 bytes per frame |
| VBR | Constrained VBR (`OPUS_SET_VBR(1)`, `OPUS_SET_VBR_CONSTRAINT(1)`) | Keeps packet sizes steady. Full VBR leaks phoneme information through packet lengths (see Q5). |
| Complexity | 8 (`OPUS_SET_COMPLEXITY`) | A tiny CPU cost on desktops |
| In-band FEC | On (`OPUS_SET_INBAND_FEC(1)`) with `OPUS_SET_PACKET_LOSS_PERC(10)` | Each packet carries a low-bitrate copy of the previous one, so a single loss can be recovered |
| DTX | Off in v1 | Our VAD gate already stops sending during silence (2.3). DTX also sends occasional 1–2 byte frames, which would complicate the speaking indicator. Revisit with Q4. |
| Maximum packet size | Encode buffer 1275 bytes (Opus's maximum for one frame); the relay rejects frames over 512 bytes | 64 kbit/s × 20 ms = 160 bytes, so 512 leaves room and still blocks abuse |

Bandwidth for one stream in one direction, at 24 kbit/s:

| Envelope | Bytes per frame (Opus + envelope + ENet ≈ 12 + IPv4/UDP 28) | kbit/s |
| --- | --- | --- |
| Proposed binary voice envelope (section 3.3) | 60 + 38 + 12 + 28 = 138 | 55 |
| Today's CBOR `Packet{EncryptedPacket{Packet}}` (measured) | 274 + 12 + 28 = 314 | 126 |

### 2.2 Binding: `client/opus/opus.odin`, loaded with `core:dynlib`

Put a small binding in its own package, `client/opus`. Like `client/ui`, it must not import
HayChat types. It is a symbol table filled by `dynlib.initialize_symbols`, plus thin wrappers.
This shape was prototyped and works against libopus 1.6:

```odin
package opus

import "core:c"
import "core:dynlib"

Encoder :: struct {}
Decoder :: struct {}

APPLICATION_VOIP :: 2048
SIGNAL_VOICE :: 3001
SET_BITRATE_REQUEST :: 4002
SET_VBR_REQUEST :: 4006
SET_COMPLEXITY_REQUEST :: 4010
SET_INBAND_FEC_REQUEST :: 4012
SET_PACKET_LOSS_PERC_REQUEST :: 4014
SET_DTX_REQUEST :: 4016
SET_VBR_CONSTRAINT_REQUEST :: 4020
SET_SIGNAL_REQUEST :: 4024
GET_LOOKAHEAD_REQUEST :: 4027
RESET_STATE :: 4028
OK :: 0

Symbols :: struct {
	encoder_create:     proc "c" (fs: i32, channels: c.int, application: c.int, error: ^c.int) -> ^Encoder,
	encoder_ctl:        proc "c" (st: ^Encoder, request: c.int, #c_vararg args: ..any) -> c.int,
	encode_float:       proc "c" (st: ^Encoder, pcm: [^]f32, frame_size: c.int, data: [^]u8, max_data_bytes: i32) -> i32,
	encoder_destroy:    proc "c" (st: ^Encoder),
	decoder_create:     proc "c" (fs: i32, channels: c.int, error: ^c.int) -> ^Decoder,
	decoder_ctl:        proc "c" (st: ^Decoder, request: c.int, #c_vararg args: ..any) -> c.int,
	decode_float:       proc "c" (st: ^Decoder, data: [^]u8, len: i32, pcm: [^]f32, frame_size: c.int, decode_fec: c.int) -> c.int,
	decoder_destroy:    proc "c" (st: ^Decoder),
	packet_get_nb_samples: proc "c" (data: [^]u8, len: i32, fs: i32) -> c.int,
	strerror:           proc "c" (error: c.int) -> cstring,
	get_version_string: proc "c" () -> cstring,
	__handle:           dynlib.Library,
}

LIBRARY_NAMES :: [?]string{"libopus.so.0", "libopus-0.dll", "opus.dll", "libopus.0.dylib"}

// load tries each library name in turn. Voice is unavailable, not fatal, when it fails.
load :: proc(symbols: ^Symbols) -> bool
```

(The struct above is laid out for reading. The real file wraps lines at 100 characters.)

Functions needed and how they are used:

| Function | Use |
| --- | --- |
| `opus_encoder_create(48000, 1, VOIP, &err)` | One encoder per voice session |
| `opus_encoder_ctl` | Bitrate, VBR, VBR constraint, complexity, signal, in-band FEC, loss percentage, DTX; `RESET_STATE` when a talk spurt starts after a long gap |
| `opus_encode_float(enc, pcm, 960, out, 1275)` | Returns the number of bytes, or a negative error |
| `opus_decoder_create(48000, 1, &err)` | One decoder per remote speaker |
| `opus_decode_float(dec, data, len, pcm, 960, 0)` | Normal decode |
| `opus_decode_float(dec, next, nextLen, pcm, 960, 1)` | FEC: rebuild lost frame N from the redundant data in packet N+1. `frame_size` must be exactly the missing duration (opus.h). |
| `opus_decode_float(dec, nil, 0, pcm, 960, 0)` | PLC when neither the frame nor its successor has arrived |
| `opus_packet_get_nb_samples` | Validates that a received packet is exactly 960 samples before decoding it |
| `opus_encoder_destroy`, `opus_decoder_destroy` | Cleanup; leak-checked tests cover both |
| `opus_strerror`, `opus_get_version_string` | Diagnostics and the `voice status` harness command |

Why load at runtime instead of `foreign import`:

- **Windows has no import library.** Odin's vendor tree ships `libopus-0.dll` but no `.lib`.
  We would have to generate and commit one, or add a build step.
- **Linux needs only the runtime package.** Fedora's `opus` package provides
  `libopus.so.0`. Linking with `foreign import "system:opus"` would need `opus-devel` for the
  `libopus.so` symlink in every build environment, including people who never use voice.
- **Missing libopus doesn't stop the client.** The client still starts and chats, and the
  voice UI says "Voice unavailable: libopus not found". `odin check client
  -target:windows_amd64` in `check.sh` keeps working because nothing new is linked.
- **Variadic `ctl` works.** `#c_vararg` on a procedure-type field compiles and calls
  `opus_encoder_ctl` correctly; this was tested. Pass `i32` values explicitly, because Opus
  reads `opus_int32`.

Rejected:

- **Static or `system:` linking.** Needs `-devel` packages and a Windows `.lib`, for no
  benefit at our scale.
- **A pure-Odin Opus port.** Months of work.
- **Another codec** (Speex, raw PCM, G.722). Speex is superseded by Opus. Raw PCM costs
  768 kbit/s. Opus is the obvious choice.

### 2.3 VAD and push-to-talk

- **Voice activity** (the default): RMS in dBFS for each 20 ms frame, with an attack of two
  frames above the threshold (default −45 dBFS, configurable, shown against a live level
  meter in Settings) and a hangover of 300 ms (15 frames) below it. While the gate is closed
  the client sends nothing. The last frame of a talk spurt carries `FLAG_END_OF_SPURT`.
- **Push-to-talk:** the gate is open only while the PTT key is held. The key is read through
  SDL keyboard events while the window has focus. A global hotkey that works while the
  window is unfocused needs per-platform code (X11 has no portable answer and Wayland needs
  the global-shortcuts portal), so it is open question Q3. Release has a 200 ms tail so the
  last syllable isn't clipped.
- **Mute:** the gate is forced closed. Capture stays open so the level meter keeps working
  and unmuting is instant.
- **Deafen:** implies mute. Playback streams are paused and the server stops relaying to the
  peer (section 4.4).
- The gate state also drives the local "you are speaking" indicator.

## 3. Wire protocol and transport

### 3.1 Channels

| ENet channel | `NetworkChannel` | Packet flags | Carries |
| --- | --- | --- | --- |
| 1 | `Chat` (rename to `Control` later) | `RELIABLE` | Everything CBOR, including the new voice control messages |
| 2 | `Voice` | `UNSEQUENCED` (unreliable, unordered) | Voice frames in the binary envelope, nothing else |

Why `UNSEQUENCED` rather than ENet's default unreliable-sequenced mode: in sequenced mode
ENet drops any packet older than the newest it has received on that channel. The jitter
buffer could still use such a packet, either as a late frame or as an FEC source. Ordering is
the jitter buffer's job, and replay protection is the crypto layer's job (ENet's own
unsequenced window is not authenticated). ENet's packet throttle still applies to unreliable
packets, which is what we want under congestion.

Voice frames are always smaller than `HOST_DEFAULT_MTU` (1392), so `UNRELIABLE_FRAGMENT` is
never needed. The relay rejects frames over 512 bytes.

### 3.2 Transport changes in `common/auth.odin`

Goals: each channel has its own key, counter and replay policy. The nonce and AAD bind the
channel and sequence. A voice packet that fails any check is dropped and counted, never
fatal. The control channel keeps its current behaviour. This is a breaking wire change:
bump `protocolVersion`.

**Key derivation.** Expand the HKDF output from 2 keys to 4: control c→s, control s→c,
voice c→s, voice s→c. Separate keys per channel give domain separation, so voice can use
deterministic nonces with no risk of colliding with control traffic.

```odin
TransportChannel :: enum u8 {
	Control = 1, // same number as NetworkChannel.Chat and ENet channel 1
	Voice   = 2, // same number as NetworkChannel.Voice and ENet channel 2
}

TransportKeySet :: struct {
	clientToServer:      [TransportChannel]TransportKey,
	serverToClient:      [TransportChannel]TransportKey,
}

DirectionalTransportKeys :: struct {
	sendKey:    [TransportChannel]TransportKey,
	receiveKey: [TransportChannel]TransportKey,
}
```

`deriveTransportKeySet` keeps its salt (`sessionID || transcriptHash`) and IKM. It expands
`TRANSPORT_KEY_SIZE * 4` bytes in a fixed order with HKDF info `"haychat transport v2"`.

**Replay window.**

```odin
REPLAY_WINDOW_SIZE :: 64

ReplayWindow :: struct {
	highest: u64, // highest accepted sequence
	bitmap:  u64, // bit i set: sequence (highest - i) was accepted
	hasAny:  bool,
}

// Pure check, no mutation. False for duplicates and for sequences at or below
// highest - REPLAY_WINDOW_SIZE.
ReplayWindow_check :: proc(window: ^ReplayWindow, sequence: u64) -> bool

// Called only after AEAD open succeeded. Shifts the bitmap when sequence > highest.
ReplayWindow_commit :: proc(window: ^ReplayWindow, sequence: u64)
```

A 64-frame window is 1.28 s of voice at 50 packets per second, far more reordering than any
jitter buffer would wait for. Anything older is useless and is dropped.

**Per-channel state.** The control channel and the voice channel get separate structs, so
different threads can own them (section 1.4 on the client, section 4.3 on the server):

```odin
ChannelSendState :: struct {
	key:          TransportKey,
	nextSequence: u64,
}

ControlReceiveState :: struct {
	key:          TransportKey,
	nextSequence: u64, // strict: reliable and ordered, so any gap is an attack or a bug
}

VoiceReceiveState :: struct {
	key:    TransportKey,
	window: ReplayWindow,
	stats:  VoiceReceiveStats, // dropped: replay, too old, bad tag, bad format
}

TransportState :: struct {
	role:           SessionRole,
	phase:          HandshakePhase,
	peerTrustState: PeerTrustState,
	sessionID:      SessionID,
	controlSend:    ChannelSendState,
	controlReceive: ControlReceiveState,
	// Moved out to the thread that owns voice after activation; see
	// TransportState_takeVoiceState.
	voiceSend:      ChannelSendState,
	voiceReceive:   VoiceReceiveState,
}
```

`TransportState_activate` fills all four from `DirectionalTransportKeys`.
`TransportState_takeVoiceState(state) -> (ChannelSendState, VoiceReceiveState)` copies the
voice halves out and zeroes them in `state`. The server router hands them to the network
thread (4.3). The client keeps both in the transport, but they are touched only by the voice
thread (send) and the worker (receive). Wipe keys with `crypto.zero_explicit` on reset.

**Nonce and AAD.**

```odin
TRANSPORT_AAD_SIZE :: SESSION_ID_SIZE + 1 + 8 // sessionID || channel || sequence (LE)

makeTransportAAD :: proc(sessionID: SessionID, channel: TransportChannel, sequence: u64) -> TransportAAD

// Voice only: XChaCha20 24-byte nonce = channel (1) || sequence LE (8) || zeros (15).
// Safe because the voice key is unique per session and direction and the sequence never
// repeats under it. The send counter refuses to wrap.
makeVoiceNonce :: proc(channel: TransportChannel, sequence: u64) -> TransportNonce
```

- Control keeps a random nonce sent in the envelope. Only its AAD changes, to include the
  channel byte. Keeping the random nonce keeps the change to the existing reliable path
  small.
- Voice uses the deterministic nonce, which is never sent. That saves 24 bytes per frame.

**Seal and open APIs.**

```odin
// Unchanged signatures, now using controlSend/controlReceive and the channel-bound AAD.
sealPacketForSession :: proc(state: ^TransportState, messageType: MessageType, payload: any) -> (Packet, bool)
openPacketForSession :: proc(state: ^TransportState, outerPacket: Packet) -> (Packet, bool)

// New. Writes the binary voice datagram into dst. No allocation, so it is safe on the
// voice thread every 20 ms.
sealVoiceDatagram :: proc(send: ^ChannelSendState, sessionID: SessionID, plaintext: []u8, dst: []u8) -> (n: int, ok: bool)

VoiceOpenResult :: enum u8 { Ok, Malformed, Replayed, TooOld, BadTag }

// check window → open with the derived nonce → commit window. Writes the plaintext into dst.
openVoiceDatagram :: proc(receive: ^VoiceReceiveState, sessionID: SessionID, datagram: []u8, dst: []u8) -> (n: int, result: VoiceOpenResult)
```

Fix `openPacketForSession` at the same time so the strict counter, too, is checked first and
advanced only after the tag verifies. A forged packet on the control channel disconnects the
peer anyway, but the check-then-commit order should be the same everywhere.

**Tests** (`common/auth_test.odin`; leak-checked): a round trip on each channel; reordering
inside the window is accepted; duplicates are rejected; anything older than 64 packets is
rejected; a forged high sequence with a bad tag does not move the window; voice and control
packets with the same sequence decrypt only on their own channel (shows that AAD and key
separation work); flipping a channel byte, a sequence byte or a session byte breaks the tag;
the send counter refuses to wrap.

### 3.3 Voice datagram (binary, ENet channel 2)

All integers are little-endian.

```text
Voice datagram (both directions)
 offset  size  field
 0       1     kind          0x01 = voice frame (other values reserved; drop unknown kinds)
 1       8     sequence      transport sequence for this direction's voice channel
 9       n     ciphertext    XChaCha20-Poly1305(voiceKey, nonce(channel, sequence),
                             aad = sessionID || 0x02 || sequence || kind)
 9+n     16    tag

Plaintext, client → server (ClientVoiceFrame)
 0       4     roomId        u32
 4       4     frameSequence u32, the sender's 20 ms tick counter for this talk session
 8       1     flags         bit0 END_OF_SPURT, bit1 FEC_PRESENT (informational)
 9       m     opus          1..512 bytes

Plaintext, server → client (ServerVoiceFrame)
 0       4     roomId        u32
 4       4     senderUserId  u32
 8       4     frameSequence u32, copied from the sender unchanged
 12      1     flags
 13      m     opus
```

Overhead: 25 bytes of envelope plus 9 (c→s) or 13 (s→c) bytes of header.

- **`frameSequence` is the media clock.** It increments every 20 ms tick while the
  participant is joined, **including** ticks when the gate is closed and nothing is sent. The
  jitter buffer can therefore tell silence from loss, and timestamps are always
  `frameSequence × 960` samples, so there is no separate timestamp field. A u32 wraps after
  2.7 years of continuous talk, and the receiver uses wrapping comparison anyway.
- **The transport `sequence` is separate from `frameSequence`.** The server reseals each
  frame for each recipient with that recipient's own counter, so a recipient's transport
  sequence has nothing to do with the sender's frame numbering.
- **Why not CBOR:** 214 bytes against 38 (section 0.2), 50 times a second per speaker. The
  format is fixed and tiny, so a hand-written encoder/decoder in `common/voice_wire.odin` with
  bounds-checked readers is less code than the CBOR ownership rules. It also allocates
  nothing, which matters on the voice thread.
- `roomId` is in the c→s frame even though the server knows the peer's current room. The
  relay drops frames whose `roomId` doesn't match the peer's joined room, so a late frame
  sent before a room switch can't leak into the new room.

### 3.4 Control messages (CBOR, reliable channel 1)

As implemented in H2 (protocol 10): the six new members are appended at the end of
`MessageType` and pinned (`ClientJoinVoice` 141 through `ServerVoiceLeft` 146).
`ClientVoiceData`/`ServerVoiceData` stay as retired placeholders that are never sent, because
`ClientDirectMessage` and `ServerDirectMessage` follow them on the wire. The voice AAD also
binds the datagram's kind byte (`makeVoiceAAD`), so a later second kind cannot be relabelled.

```odin
ClientJoinVoicePayload :: struct {
	roomId:   int,
	muted:    bool,
	deafened: bool,
}

ClientLeaveVoicePayload :: struct {}

ClientVoiceStatePayload :: struct { // mute/deafen changes while joined
	muted:    bool,
	deafened: bool,
}

VoiceParticipant :: struct {
	userId:   int,
	nickname: string, // owned
	muted:    bool,
	deafened: bool,
}

// Sent to every live session of every room member whenever the participant set or any
// participant's state changes, and to a joiner as the join acknowledgement.
ServerVoiceParticipantsPayload :: struct {
	roomId:       int,
	participants: [dynamic]VoiceParticipant, // owned
}

ServerVoiceJoinRejectedPayload :: struct {
	roomId: int,
	reason: string, // owned: "not a room member", "voice room is full", ...
}

// Sent when the server removes the session from voice: removed from the room, the room was
// deleted, or the same session joined another room.
ServerVoiceLeftPayload :: struct {
	roomId: int,
	reason: string, // owned
}
```

New `MessageType` values: `ClientJoinVoice`, `ClientLeaveVoice`, `ClientVoiceState`,
`ServerVoiceParticipants`, `ServerVoiceJoinRejected`, `ServerVoiceLeft`. Retire the
datetime-based `VoiceData` struct (H2 deleted it). Binary frames don't need a `MessageType`, so
`ClientVoiceData`/`ServerVoiceData` are never sent; they keep their place only to hold the wire
values after them.

**Speaking indicators are not a protocol message.** Each client derives them: a remote
participant is "speaking" when a frame from them was played in the last 250 ms, or until a
frame with `END_OF_SPURT` arrives. A server-side speaking broadcast would add a reliable
message per talk spurt per member, and a reliable message can arrive after the audio it
describes.

Ownership follows `AGENTS.md`: `nickname` and `reason` are owned by the decoded payload and
moved into the runtime event, then into `State`. Each of them needs a case in
`ClientTransportRuntimeEvent_deinit`.
`common/protocol.odin` has `VoiceParticipant_deinit`, `ServerVoiceParticipantsPayload_deinit`,
`ServerVoiceJoinRejectedPayload_deinit` and `ServerVoiceLeftPayload_deinit` for payloads that
are decoded and then dropped.

### 3.5 Changes to `MainRouterState_handleNetworkDataReceived`

With the recommended design, voice datagrams never reach the router: the network thread
consumes channel 2 (section 4.3). The router function changes only to make that explicit:

```odin
MainRouterState_handleNetworkDataReceived :: proc(pm: ^ProcessManager, state: ^MainRouterState, msg: NetworkDataReceived) {
	switch msg.channel {
	case .Chat:
		// existing path
	case .Voice:
		// Should not happen: the network thread's VoiceRelay consumes channel 2.
		// Count it and drop it. Never protocolViolation: the datagram is unauthenticated.
		state.unexpectedVoiceDatagrams += 1
		return
	case .None, .Video, .Screenshare, .FileTransfer:
		return
	}
	...
}
```

If the fallback in 4.3 (router-side relay) is chosen instead, this `case .Voice:` calls
`MainRouterState_handleVoiceDatagram`. That procedure opens the datagram with the peer's
`VoiceReceiveState`, checks participation, and sends one `NetworkSendData{channel = .Voice,
flags = .Unreliable}` per recipient. `NetworkSendData` needs a `reliable: bool` (or flags)
field either way, because `handleNetworkSendData` hard-codes `RELIABLE` today.

## 4. Server

### 4.1 Split: router as control plane, network thread as data plane

```text
              reliable channel 1 (CBOR)                      channel 2 (binary datagrams)
 client ──► ENet ──► network thread ──IPC──► router      client ──► ENet ──► network thread
                                               │                                 │
            ClientJoinVoice: membership check  │                     VoiceRelay: window, open,
            via DatabaseRoomMemberListRequest  │                     participation check,
            ──► update VoiceRoom state ────────┼──IPC──► VoiceRelay  rate limit, reseal per
            ──► ServerVoiceParticipants        │   (route updates)  recipient, peer_send
                to room members                ▼                    UNSEQUENCED
```

- The router stays the single source of truth for who is in which voice room, because
  joining needs the database membership check and the participant list goes to room members
  over the reliable channel.
- The network thread forwards frames using a routing table the router pushes to it. Voice
  frames never enter the IPC queues, the router loop or the database.

Rejected:

- **Relaying voice in the router** (decrypt in the router, send `NetworkSendData` per
  recipient). It is the simplest change, but every frame makes two hops through the in-memory
  IPC queue and waits on a router thread that also does database continuations and chat
  fan-out. It also turns one inbound frame into N−1 `NetworkSendData` messages with their
  allocations. It stays as the fallback if Q8 rules out moving crypto state to the network
  thread.
- **A separate UDP socket or service for voice.** It would need a second authentication
  handshake, a second NAT/firewall rule and its own key exchange. ENet channels already give
  us one connection with per-channel reliability.

### 4.2 Router state and handlers (`server/main.odin`, new `server/voice.odin`)

```odin
VoiceParticipantState :: struct {
	peerID:   u32,
	userID:   int,
	muted:    bool,
	deafened: bool,
}

VoiceRoomState :: struct {
	roomID:       int,
	participants: [dynamic]VoiceParticipantState, // small: linear scans are fine
}

// Added to MainRouterState:
//   voiceRooms:    map[int]VoiceRoomState // roomID → state, removed when empty
//   peerVoiceRoom: map[u32]int            // peerID → roomID it is in
```

New `PendingDBRequestType` values: `JoinVoiceMemberCheck` and `ListVoiceRoomRecipients`.
Both reuse the existing `DatabaseRoomMemberListRequest`, so no new SQL or union variant is
needed.

| Event | Router action |
| --- | --- |
| `ClientJoinVoice{roomId}` | Reject if unauthenticated or `roomId <= 0`. Enqueue `DatabaseRoomMemberListRequest{roomId}` with pending `JoinVoiceMemberCheck{roomID, peerID}`. |
| Member-list result for `JoinVoiceMemberCheck` | If `authenticatedUserID ∉ userIDs`: send `ServerVoiceJoinRejected{"not a room member"}`. If the room is at `voiceMaxParticipants`: reject with "voice room is full". Otherwise remove the peer from any previous voice room (with fan-out for that room), add it, send `NetworkVoiceRoute` to the network thread, and send `ServerVoiceParticipants` to every live session of every user in `userIDs`, the joiner included. |
| `ClientLeaveVoice` | Remove, send the route update, fan out to the room's members. The member IDs come from a `ListVoiceRoomRecipients` member-list request, or from a short-lived cache of the last member list per voice room (step H5 decides). |
| `ClientVoiceState{muted, deafened}` | Update the participant, send the route update (deafened peers get no frames), fan out. |
| `NetworkPeerDisconnected` | Before `MainRouterState_removePeerSession`: if the peer is in voice, remove it and fan out. The network thread has already dropped its own state for the peer (4.3). |
| Room member removed (`RemoveRoomMember` result) or room deleted (`DeleteRoom` result) | For each affected session in that room's voice: remove it, send `ServerVoiceLeft{reason}`, send the route update, fan out. |
| Network service restart (`MainRouterState_prepareForProcessStop(.Network)`) | Clear all voice state; peers are disconnected anyway. |

`ServerVoiceParticipants` goes to **room members**, not only to participants. That way the
channel list can show who is in voice before you join, as most voice chat apps do.

Nicknames: the router has `RouterPeerSession.clientNickname` for every live peer, so filling
`VoiceParticipant.nickname` needs no database query.

When a client lists rooms or reconnects, the server also sends a `ServerVoiceParticipants`
for each of the client's rooms that has active voice, so sidebars are correct right after
connecting.

### 4.3 Network-thread `VoiceRelay` (`server/voice_relay.odin`)

New IPC messages (router → network thread). Add them to the `Message` union, to
`IPC__route_to`, and to `IPC__message_deinit`:

```odin
// Sent right after auth success, with the voice halves taken out of the router's
// TransportState. The router never touches voice crypto again.
NetworkVoiceSessionOpen :: struct {
	peerId:    u32,
	userId:    int,
	sessionID: common.SessionID,
	send:      common.ChannelSendState,
	receive:   common.VoiceReceiveState,
}

// Full replacement of one room's recipient set. Sent on every join, leave or state change.
NetworkVoiceRoute :: struct {
	roomId:       int,
	members:      []NetworkVoiceRouteMember, // owned
}

NetworkVoiceRouteMember :: struct {
	peerId:   u32,
	muted:    bool, // the relay drops frames from muted peers
	deafened: bool, // the relay sends nothing to deafened peers
}
```

The network-thread state is owned by `networkServerLoop` and needs no mutex:

```odin
VoiceRelayPeer :: struct {
	userId:    int,
	sessionID: common.SessionID,
	send:      common.ChannelSendState,
	receive:   common.VoiceReceiveState,
	roomId:    int, // 0 when not in voice
	muted:     bool,
	deafened:  bool,
	bucket:    TokenBucket,
}

VoiceRelay :: struct {
	peers:   map[u32]VoiceRelayPeer,
	rooms:   map[int][dynamic]u32,
	scratch: [2048]u8, // plaintext/ciphertext buffers, so frames cost no allocations
	stats:   VoiceRelayStats,
}
```

Per inbound datagram on channel 2 (in `handlePeerData`, before any IPC):

1. Look up the peer by `enetPeer.data`. Drop if unknown or not in a room.
2. Rate-limit with a token bucket (`HAYCHAT_VOICE_MAX_PACKETS_PER_SECOND`, default 60, burst
   20). Drop when it is empty.
3. `openVoiceDatagram`. On anything but `.Ok`, count it and drop it.
4. Parse `ClientVoiceFrame`. Drop if `roomId != peer.roomId`, if the peer is muted, if the
   Opus length is 0 or over `HAYCHAT_VOICE_MAX_FRAME_BYTES` (default 512), or if the TOC byte
   says the packet isn't 20 ms. The relay checks the TOC byte itself (RFC 6716 §3.1), so the
   server needs no libopus: `decodeClientVoiceFrame` gives `.Truncated`, `.EmptyOpus` or
   `.OpusTooLarge` for the length cases, and `opusPacketIsVoiceFrameDuration(frame.opus)` is
   the TOC check.
5. Build `ServerVoiceFrame{roomId, senderUserId = peer.userId, frameSequence, flags, opus}`
   with `encodeServerVoiceFrame`, which may write over the buffer the client frame was
   decoded from.
6. For each other peer in `rooms[roomId]` that is not deafened: `sealVoiceDatagram` with
   that peer's `send`, then `ENet.packet_create(…, {.UNSEQUENCED})` and `peer_send(…, 2, …)`.
   Don't echo the frame back to the sender.
7. Destroy the inbound packet. **Don't** forward it to the router over IPC, and **don't**
   enqueue it to the worker pool. Log nothing per packet; the counters cover it.

`handlePeerDisconnect` deletes `peers[peerId]` and removes the peer from its room's list
straight away, so frames stop flowing before the router has even seen
`NetworkPeerDisconnected`.

ENet flushes queued sends on the next `host_service`. After the H0 fix (4.5) the loop calls
`host_service` at least every few milliseconds, so there is no explicit flush per frame.
Instead there is one `host_flush` after each batch of inbound events.

Cost: XChaCha20-Poly1305 on about 100 bytes is in the low microseconds. A 20-person room
with 3 people talking needs 150 opens and 2,850 seals per second, a few milliseconds of CPU
per second. Single-threaded relay is fine far beyond the sizes we will test.

### 4.4 Limits, abuse and disconnects

| Concern | Handling |
| --- | --- |
| Joining a room you aren't a member of | Database membership check on join; the route table only contains members |
| Membership revoked while in voice | Removal and deletion handlers evict the participant (4.2) |
| Flooding | Per-peer token bucket in the relay; ENet's bandwidth throttle; frame size cap |
| Spoofed or replayed datagrams | AEAD plus a replay window per peer and direction. Failures are counted and dropped, never disconnecting. |
| Muted peer still sending | The relay drops its frames (the client also stops sending) |
| Deafened peer | Receives nothing, which saves bandwidth |
| Room size | `HAYCHAT_VOICE_MAX_PARTICIPANTS` (default 25) |
| Disconnect or ENet timeout | The relay drops the peer at once. The router removes the participant and fans out. Until ENet notices a dead peer (its timeout is seconds), that peer appears silent in the participant list. |
| Server restart | Voice state is in memory only. Clients reconnect (package C) and re-join if the user was in voice (5.1). |
| Logging | Counters only: frames in/out/dropped by reason, per room. Expose them via web admin `/status` later (Q9). |

New server config keys. Follow `AGENTS.md` "Configuration": `server/config.odin`,
`config_test.odin`, README and `.env.example`.

| Key | Default | Purpose |
| --- | --- | --- |
| `HAYCHAT_VOICE_ENABLED` | `true` | Turns voice off server-wide. Joins are rejected with "voice is disabled". |
| `HAYCHAT_VOICE_MAX_PARTICIPANTS` | `25` | Participants per voice room (1–200) |
| `HAYCHAT_VOICE_MAX_PACKETS_PER_SECOND` | `60` | Per-peer token bucket rate (the burst is a third of this) |
| `HAYCHAT_VOICE_MAX_FRAME_BYTES` | `512` | Largest Opus payload the relay forwards (64–1275) |

### 4.5 Prerequisite H0: fix the network loop

Voice can't land before this, and chat latency benefits from it too:

1. Drain **all** pending IPC messages each iteration, not one.
2. Use a much shorter `host_service` timeout (2 ms), or better, process every ENet event
   available (`host_check_events` until none remain) and then wait on the IPC queue with a
   condition variable or `core:sync/chan` (assessment item 9). The condition-variable rework
   can be a later PR; draining everything with a 2 ms timeout is enough for voice.
3. Replace `ordered_remove(queue, 0)` in `IPC_Client_poll` with a ring buffer or a swap of
   the whole queue.
4. Remove the `printfln` per send and per receive (or put them behind `HAYCHAT_LOG_LEVEL`
   debug).
5. Stop queueing every received packet to `NetworkThreadPool`. The workers do nothing but
   print, and they spin on `thread.yield()`. Either park them on a condition variable or
   remove the pool until it has a job (Q8).
6. Add `reliable: bool` to `NetworkSendData` and `NetworkBroadcast`, and pass the channel
   through in `handleNetworkSendData` as today.

## 5. Client

### 5.1 State and actions

Add to `State` (`client/main.odin`):

```odin
VoiceSessionState :: enum { Idle, Joining, Joined, Unavailable }

ClientVoiceState :: struct {
	status:        VoiceSessionState,
	serverID:      int, // voice is active on at most one server at a time
	roomID:        int,
	muted:         bool,
	deafened:      bool,
	lastError:     string, // owned
	// (serverID, roomID) → participants, filled by ServerVoiceParticipants for every room,
	// joined or not, so the sidebar can show them.
	roomParticipants: [dynamic]VoiceRoomParticipants, // owned
	engine:        ^VoiceEngine, // nil when libopus or audio failed to load
}
```

Actions (`client/actions.odin`), each holding `ClientNetworkWorker_lock` around its
transport send, like the chat actions:

| Action | Effect |
| --- | --- |
| `State_joinVoice(state, serverID, roomID)` | Leave any current voice session first, then send `ClientJoinVoice`, status `Joining`. On `ServerVoiceParticipants` with self in it: `Joined`, start the engine (open devices, reset counters). |
| `State_leaveVoice(state)` | Send `ClientLeaveVoice`, stop the engine, status `Idle`. |
| `State_setVoiceMuted`, `State_setVoiceDeafened` | Update the engine immediately (local gate), send `ClientVoiceState`. |
| `State_setVoiceDevices`, `State_setVoiceMode`, … | Persist with `saveConfig`, reopen devices in the engine. |

On `Disconnected`, the engine stops and status becomes `Idle`, but `wantVoiceRoomID` is
kept. When package C's `Connected` event arrives, the client re-joins automatically.

New runtime event kinds in `client/transport.odin`: `VoiceParticipants`,
`VoiceJoinRejected`, `VoiceLeft`. Voice **frames** are not runtime events: the worker pushes
them straight into the engine's inbound queue (5.2), so they never wake or touch the UI loop.

### 5.2 Pipelines (`client/voice_engine.odin`, `client/voice_jitter.odin`)

**Capture → send** (voice thread, about every 5 ms):

```text
capture stream (SDL converts device format → F32 mono 48 kHz)
  └─ while GetAudioStreamAvailable >= 960 * 4 bytes:
       read 960 samples
       ├─ input gain, clip
       ├─ level meter (RMS dBFS) → atomic snapshot for the UI
       ├─ gate: muted? PTT held? VAD open (attack/hangover)?
       ├─ frameSequence += 1  (always, even when the gate is closed)
       └─ if open: opus_encode_float → ClientVoiceFrame → sealVoiceDatagram
                   → lock worker → peer_send(channel 2, UNSEQUENCED) → unlock
```

If the capture stream builds up more than 3 frames (the voice thread was stalled), drop the
oldest so latency doesn't creep up.

**Receive → play:**

```text
worker: ENet RECEIVE on channel 2
  └─ openVoiceDatagram (receive window) → parse ServerVoiceFrame
     → VoiceEngine_pushInbound(senderUserID, frameSequence, flags, opus) (mutex, bounded)

voice thread, each tick:
  for each remote speaker (created on first frame, destroyed after 10 s idle):
    move inbound frames into that speaker's jitter buffer
    while GetAudioStreamQueued(speakerStream) < target:
       slot := JitterBuffer_next(speaker)
       ├─ have frame N           → opus_decode_float(…, fec = 0)
       ├─ missing N, have N+1    → opus_decode_float(N+1, fec = 1)   (FEC)
       ├─ missing, mid-spurt     → opus_decode_float(nil)            (PLC, at most 5 in a row)
       └─ missing, gap/end       → put nothing (the stream underruns into silence)
       PutAudioStreamData(speakerStream, pcm)
```

**Jitter buffer** (one per speaker, pure code so it can be unit-tested without audio):

- A ring of 32 slots indexed by `frameSequence mod 32`, each holding up to 512 bytes of Opus.
  There's no allocation per frame.
- **Playout:** the first frame of a talk spurt sets `playoutSeq = frameSequence −
  targetDepth`. The default target depth is 3 frames (60 ms), adapted between 2 and 8 from
  the interarrival jitter the buffer measures (an RFC 3550-style estimate). Depth changes
  only between talk spurts.
- Frames older than `playoutSeq` are dropped as late. Frames beyond `playoutSeq + 32` reset
  the buffer, which happens after a long pause or a sender restart.
- `END_OF_SPURT`, or more than 10 frames with nothing arriving, ends the spurt. The next
  frame starts a new one.
- The SDL stream adds its own buffering. Keep `GetAudioStreamQueued` around 2 frames
  (40 ms), so the expected end-to-end delay is about: 20 ms frame + about 5 ms encode/tick +
  network + 60 ms jitter + 40 ms output + device buffer ≈ **130–150 ms plus network**. The
  first target for testing is under 200 ms on a LAN (section 6.4).

Rejected: **decoding in the SDL audio callback.** It is lower latency, but it puts libopus
and the jitter buffer on SDL's thread, which needs locking against the worker, and it can
glitch if a decode is ever slow.

### 5.3 UI

| Place | Element |
| --- | --- |
| Channel list (`viewChannelList`) | Each room row shows a speaker icon when anyone is in its voice. The participants are listed under the row, indented, with a green ring while speaking and mute/deafen icons. If voice is a per-room setting (Q1), only voice-enabled rooms show it. |
| Room header (`viewRoomChat`) | A "Join voice" button. While joined, a "Leave" button. |
| Voice bar (bottom of the sidebar, shown while joined) | "Voice connected: #room on Server", plus Mute, Deafen and Leave buttons, your own speaking indicator and a small input level bar. Errors ("Voice unavailable: libopus not found", "Microphone not available") show here. |
| Settings (package C's screen, a new "Voice" section) | Input device, output device (lists plus "System default"), mode (voice activity or push-to-talk), PTT key capture, VAD threshold slider over a live level meter, input gain, output volume, a "Test microphone" loopback that plays your own capture back locally. |

The view reads only `State` and a per-frame snapshot from the engine (speaking flags and
levels, taken under the engine's lock). Because speaking state changes without network
events, the UI needs redraws while voice is active. While joined, set a UI deadline of about
100 ms (`ctx.nextDeadlineMS`) so indicators update. When not joined there's no extra
wake-up.

`client/ui` stays free of HayChat types: the participant rows use existing button and label
widgets, plus at most one generic `ui.levelMeter`.

Client config keys (`client/config.odin`, `config_test.odin`, README):

| Key | Default | Purpose |
| --- | --- | --- |
| `voice_input_device` | `""` | Recording device name; empty means the system default |
| `voice_output_device` | `""` | Playback device name; empty means the system default |
| `voice_mode` | `"voice_activity"` | `"voice_activity"` or `"push_to_talk"` |
| `voice_ptt_key` | `"Left Ctrl"` | SDL key name (`SDL_GetKeyName`) |
| `voice_vad_threshold_db` | `-45` | Gate threshold in dBFS (−80 to 0) |
| `voice_input_gain` | `1.0` | Linear input gain (0–4) |
| `voice_output_volume` | `1.0` | Master output gain (0–2) |
| `voice_bitrate` | `24000` | Opus bitrate in bit/s (12000–64000) |

### 5.4 Headless harness (package D) integration

The engine has a source/sink abstraction, so the harness and the tests can bypass devices:

```odin
VoiceSource :: union {
	VoiceSourceDevice, // SDL recording stream
	VoiceSourceFile,   // WAV via SDL.LoadWAV, converted to F32 mono 48k with ConvertAudioSamples
	VoiceSourceTone,   // sine at N Hz, amplitude A
	VoiceSourceSilence,
}

VoiceSink :: union {
	VoiceSinkDevice,   // SDL playback device + per-speaker streams
	VoiceSinkFile,     // mixed F32 mono 48k → WAV file written on stop
	VoiceSinkNull,     // decode, discard (stats only)
}
```

- File and tone sources are paced by the voice thread's clock (one frame per 20 ms), so
  they behave like a real microphone. A `--voice-fast` test flag can drop the pacing for
  unit tests.
- The file sink mixes all speakers into one track. It writes silence when nobody is
  speaking, so delay measurements stay on one time base. It also records an optional
  per-speaker track (`FILE.<userID>.wav`).
- In headless mode the default source and sink are `Silence` and `Null`, and SDL audio is
  never initialised unless `voice-source device` or `voice-sink device` is asked for.

Harness commands. They use package D's command table and add only lines:

| Command | Result line (JSON) |
| --- | --- |
| `voice-join ROOM_ID` | `{"result":"voice-join","ok":true}`, then the event `{"event":"voice_participants","roomId":1,"participants":[…]}` |
| `voice-leave` | `{"result":"voice-leave","ok":true}` |
| `voice-source tone:440[:AMP]` \| `file:PATH.wav` \| `silence` \| `device[:NAME]` | `{"result":"voice-source","ok":true}` |
| `voice-sink file:PATH.wav` \| `null` \| `device[:NAME]` | `{"result":"voice-sink","ok":true}` |
| `voice-mute on\|off`, `voice-deafen on\|off`, `voice-ptt down\|up` | ok |
| `voice-stats` | `{"result":"voice-stats","sent":…,"received":…,"lost":…,"fec":…,"plc":…,"late":…,"jitterMs":…,"depth":…,"speakers":[…]}` |
| `voice-flush` | Writes the file sink now and replies when it is on disk, so a script can analyse it without quitting |

Events: `voice_participants`, `voice_join_rejected`, `voice_left`, and
`voice_speaking {userId, speaking}` (emitted on each edge, which makes speaking indicators
testable too).

## 6. Test plan

### 6.1 Unit tests (CI, no audio, no server)

| Package | Tests |
| --- | --- |
| `common` | Replay window (3.2); voice datagram encode/decode with bounds (truncated, oversize, unknown kind); key derivation gives four distinct keys; nonce layout; a fixed test vector so client and server can't drift |
| `client` | Jitter buffer: in order, reordered, duplicate, late, gap followed by FEC, gap followed by PLC, spurt end and restart, wrap-around, adaptive depth; VAD attack/hangover on synthetic frames; Opus binding: encode a 440 Hz tone, decode, check with Goertzel (below); skipped with a clear message if libopus can't be loaded; engine with tone source → loopback (no network) → file sink |
| `server` | `VoiceRelay`: frames reach all other participants and not the sender; nothing goes to deafened peers; muted senders are dropped; non-members are rejected; rate limit; oversize frames; wrong `roomId`; disconnect clears the peer. Router: join requires membership (router test with a stubbed database result); member removal evicts; disconnect fans out a participant update |

**Frequency check in Odin.** CI needs no `sox` or numpy: a Goertzel filter at 440 Hz against
neighbouring bins (or a 4096-point DFT over 1 s) runs in microseconds. Pass criteria: the
dominant frequency within ±5 Hz of the target, energy in the target bin at least 20 dB above
the median bin, and RMS within 6 dB of the source. The same helper (`client/voice_analysis.odin`,
test-only) backs the live proof.

### 6.2 Live proof in CI (podman, no audio device)

`dev/live-proof.sh --voice` (and part of `--all`), using package D's harness:

```sh
# Client A speaks a tone; client B records. Both are headless, isolated profiles.
client --headless --name voice-a --config-dir "$tmp/a" <<'EOF' > "$tmp/a.jsonl" &
voice-source tone:440:0.5
voice-join 1
sleep 5000
voice-leave
quit
EOF
client --headless --name voice-b --config-dir "$tmp/b" <<'EOF' > "$tmp/b.jsonl"
voice-sink file:$tmp/b.wav
voice-join 1
wait voice_speaking 3000
sleep 4000
voice-stats
voice-flush
quit
EOF
odin run dev/tools/voice-check -- "$tmp/b.wav" --freq 440 --tolerance 5 --min-seconds 3
```

(Simplified. The real script uses FIFOs for stdin so it can sequence A and B and wait on
events rather than fixed sleeps.)

- `voice-check` is a small Odin program that uses the same Goertzel helper. CI doesn't need
  numpy or sox.
- It also asserts on `voice-stats` from B: `received ≥ 0.95 × expected`, and `plc + fec`
  stays low on loopback.
- An extra SDL-path test: run client A with `voice-source device` under
  `SDL_AUDIO_DRIVER=disk`, `SDL_AUDIO_DISK_INPUT_FILE=tone.f32` (raw F32 mono 48k, generated
  by the Odin test helper or by `sox` on the host), and client B with `voice-sink device`
  under `SDL_AUDIO_DISK_OUTPUT_FILE`. This covers SDL device open, format conversion and the
  stream binding with no audio server. The disk driver opened with the requested spec in the
  prototype (`format=F32LE channels=1 freq=48000`); the output file's format must be read from
  the same spec. One open item: whether the disk output device mixes several bound streams the
  same way the real backends do. Verify it in H4.
- Feasibility: the image needs the `opus` runtime package (`dev/install-packages.sh`
  `build_packages`, so CI gets it too). No PipeWire, no `--device /dev/snd`, no new
  capabilities. Both clients are headless and need no display.

### 6.3 Manual and host tests with PipeWire

These run on a developer machine (or in `./dev.sh shell` with the host's PipeWire socket
passed in, which is not set up today). The steps create virtual devices that leave the
user's real ones alone, and remove them afterwards.

```sh
# 1. Two virtual sinks and a virtual mic for client A
pactl load-module module-null-sink sink_name=hc_a_out sink_properties=device.description=HC-A-Out
pactl load-module module-null-sink sink_name=hc_b_out sink_properties=device.description=HC-B-Out
pactl load-module module-null-sink sink_name=hc_a_mic media.class=Audio/Source/Virtual \
	sink_properties=device.description=HC-A-Mic

# 2. Generate test material
sox -n -r 48000 -c 1 -b 16 tone440.wav synth 10 sine 440 vol 0.5
espeak-ng -w speech.wav "The quick brown fox jumps over the lazy dog"   # intelligibility

# 3. Play into A's virtual mic, record B's output
pw-cat --playback --target hc_a_mic tone440.wav &
pw-record --target hc_b_out.monitor --rate 48000 --channels 1 b_out.wav &

# 4. Run two GUI clients (or harness clients with voice-source/voice-sink device:NAME),
#    selecting HC-A-Mic / HC-A-Out for A and the default mic / HC-B-Out for B. Join the same
#    room.

# 5. Analyse
sox b_out.wav -n stat 2>&1 | grep 'Rough   frequency'           # expect ≈ 440
python3 -c 'import numpy as n,wave as w;f=w.open("b_out.wav");x=n.frombuffer(f.readframes(f.getnframes()),n.int16);s=n.abs(n.fft.rfft(x));print(n.argmax(s)*f.getframerate()/len(x))'

# 6. Clean up
pactl list short modules | awk '/hc_/ {print $1}' | xargs -r -n1 pactl unload-module
```

`sox … stat` reports `Rough frequency` from zero crossings. On my machine it read 439 Hz for
a clean 440 Hz tone and for the same tone after an Opus 24 kbit/s round trip through
`ffmpeg`. `sox stat -freq` dumps FFT bins rather than one answer, so the `Rough frequency`
line or the numpy line above is the better check.

`pw-loopback` can connect a real microphone to a virtual source for quick listening tests
(`pw-loopback --capture-props='node.target=<mic>' --playback-props='media.class=Audio/Source'`).

### 6.4 Latency

- **Method:** source A plays a click train (a 5 ms 1 kHz burst every 1 s, made with `sox` or
  the tone source with a gate pattern). Record B's output and the source on the same clock,
  either with harness timestamps or with PipeWire (`pw-record` on A's virtual mic monitor and
  B's sink monitor at once, `sox -M` to merge them as stereo). Cross-correlate (numpy) or
  detect onsets to get mouth-to-ear delay.
- **In CI**, the file source and file sink share the harness clock. Each client logs
  `frameSequence` and its wall time at encode and at playout (`voice-stats` exposes
  `meanPlayoutDelayMs`). That covers everything except the device buffers, which is enough to
  catch regressions.
- **Targets:** under 150 ms on loopback, under 200 ms on a LAN. Report the 50th and 95th
  percentile.

### 6.5 Packet loss and jitter

- **Unit level:** the jitter-buffer tests inject loss, reordering and jitter patterns
  deterministically.
- **System level:** `tc qdisc add dev lo root netem delay 30ms 10ms loss 5% reorder 2%`.
  This needs `CAP_NET_ADMIN`. It works in a rootful podman container on its own network
  namespace, or on the host's loopback during a manual run. In rootless CI it is not
  available, so the CI equivalent is a **test-only fault-injection hook in the client's
  voice receive path** (`HAYCHAT_TEST_VOICE_LOSS=0.05`, `HAYCHAT_TEST_VOICE_JITTER_MS=20`,
  compiled in only with `-define:HAYCHAT_TEST_FAULTS=true`).
- **Pass criteria at 5% random loss:** frequency check passes, `fec + plc ≈ lost`, and no
  sequence of more than 2 silent frames inside a spurt.

## 7. Work breakdown

Effort: S is under a day, M is one to two days, L is three to five days of agent work
including tests. Arrows show dependencies.

| Step | PR | Scope | Effort | Depends on |
| --- | --- | --- | --- | --- |
| **H0** | Server network loop and IPC throughput | Section 4.5: drain all IPC per iteration, 2 ms service timeout, a ring-buffer IPC queue, no per-packet logs, workers park or are removed, a `reliable` flag on `NetworkSendData`. A test that sends 1,000 `NetworkSendData` messages and checks they all drain promptly. | M | none (independent of A–D; also helps chat) |
| **H1** | Transport per-channel keys and replay window | Section 3.2 in `common/auth.odin` plus tests; check-then-commit for the control channel; bump `protocolVersion`; client and server compile against the new `TransportState` with the control path unchanged in behaviour | M | none (coordinate the version number with A/B) |
| **H2** | Voice wire format and control protocol | `common/voice_wire.odin` (binary frames, TOC check) plus tests; the CBOR control payloads in `protocol.odin`; retire `VoiceData`; cleanup cases | S | H1 |
| **H3** | Server voice: router control plane and network-thread relay | Section 4: `server/voice.odin`, `server/voice_relay.odin`, the IPC messages and their cleanup, the hand-off of voice crypto state at auth success, eviction on membership changes, the config keys and docs, router and relay tests | L | H0, H2 |
| **H4** | Client audio and Opus foundation | `client/opus` dynlib binding plus a tone round-trip test; `VoiceEngine` with device/file/tone sources and device/file/null sinks; jitter buffer, VAD and tests; `opus` in `dev/install-packages.sh`; Windows DLL note in the README. No networking yet: a local loopback mode feeds encode into decode. | L | none (can run in parallel with H0–H3) |
| **H5** | Client voice networking and actions | The worker's channel-2 receive path into the engine; the voice thread's send path; runtime events; `State` voice fields and actions; auto re-join on reconnect | M | H2, H3, H4, package C (connect lifecycle) |
| **H6** | Client voice UI | Channel list participants, voice bar, join/leave/mute/deafen, Settings voice section (devices, mode, PTT key, threshold with meter), client config keys and tests | M | H5, package C (settings screen) |
| **H7** | Harness commands and live voice proof | Section 5.4 commands; `dev/tools/voice-check`; `dev/live-proof.sh --voice` in `--all` and CI; `docs/testing-harness.md` voice section | M | H5, package D |
| **H8** | Manual test kit and tuning | `dev/voice-manual-test.sh` (PipeWire null-sink setup and cleanup, tone and speech playback, recording, analysis, latency click test), a short tester guide, tuning of jitter depth and VAD defaults from the measurements | S | H6, H7 |

Critical path: H1 → H2 → H3 → H5 → H7. H0 and H4 run in parallel with it. That is roughly
three to four weeks for one agent, or about two weeks with H4 and H0 in parallel with
H1–H3. H6 and H7 can also run in parallel once H5 lands.

Later, out of scope for H: per-user volume UI (the engine already supports it through
stream gain), noise suppression, AEC, global PTT hotkeys, DTX, E2E voice keys, video on
channel 3 (it reuses the per-channel transport from H1), and server metrics.

## 8. Open questions for the maintainer

| # | Question | Recommendation |
| --- | --- | --- |
| Q1 | Which rooms carry voice? The schema has no room type. | **v1: every room can carry voice** (chat-and-voice). No schema change, no admin UI. Add a `voice_enabled` column with package F's admin room management if you want text-only rooms later. |
| Q2 | One voice session per **user** or per **session** (device)? | Per session, which is simpler. Show a user once in the participant list even if two of their devices are joined, and mark it. |
| Q3 | Push-to-talk while the window is unfocused? | Not in v1: PTT works while the window has focus; voice activity is the default. Global hotkeys need X11/Wayland-portal/Windows code; schedule them after testers ask. |
| Q4 | Opus DTX on? | Off in v1; the VAD gate covers silence. Revisit if bandwidth on idle open mics matters. |
| Q5 | Constrained VBR or CBR? VBR packet sizes leak some speech content to network observers. | Constrained VBR. CBR costs about 10% more bandwidth; add `voice_cbr` if anyone needs it. |
| Q6 | Noise suppression and echo cancellation in v1? | No. Recommend headphones and PipeWire `module-echo-cancel`; consider RNNoise (loaded like libopus) after first feedback. |
| Q7 | End-to-end voice encryption? Today the server can hear everything, just as it can read chat (assessment item 2). | Keep hop-by-hop for v1, consistent with chat. The binary envelope leaves room for an SFrame-style inner layer with per-room keys later. |
| Q8 | May the network thread own per-peer voice crypto state? This is the data-plane split in 4.3, and it means the router no longer holds every key. What should happen to the unused `NetworkThreadPool`? | Yes to the split; it is what removes voice from the router path. Remove or park the worker pool in H0; it does nothing today but log and spin. |
| Q9 | Should voice metrics go on web admin `/status`? | Yes, as counters only (frames in/out/dropped, rooms, participants). It's cheap and helps testers report problems. |
| Q10 | Ship libopus with Windows builds from Odin's `vendor/sdl3/mixer/libopus-0.dll` (Xiph BSD licence, `LICENSE.opus.txt` next to it)? | Yes. Copy it with `SDL3.dll`, and ship the licence file with it. Package G's release build should do this. |

## 9. Risks

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Server loop drains outbound IPC too slowly (0.3) | Voice latency grows without limit as soon as a room has fan-out; chat suffers too | H0 lands first, with a throughput test |
| Moving voice crypto out of the router (Q8) | A design change in a part of the server that the router tests don't cover today | The relay is a pure state machine with injected send and clock; test it without ENet |
| AEC missing | Speaker users hear themselves echo; bad first impression | Recommend headphones in the tester guide; document PipeWire echo-cancel |
| PipeWire/WASAPI device quirks (exclusive mode, Bluetooth headsets switching profile when the mic opens) | Devices fail to open or audio quality drops | Fall back to default devices; show a clear error; the "Test microphone" button finds problems before a call |
| Windows is only type-checked, never run, in CI | DLL loading or WASAPI behaviour is untested until a person tries it | A manual Windows checklist in H8; libopus is loaded at runtime with a clear error |
| `protocolVersion` bumps from A, B and H1/H2 collide | Merge conflicts, renumbered message types | Take the next free version at merge time; package A's numbering-pin test catches accidental renumbering |
| Clock drift between sender capture and receiver playout | Slowly growing or shrinking delay in long talk spurts | The jitter buffer re-anchors at each spurt; a long-spurt drift correction (drop or duplicate a frame when depth leaves the band) is a tuning item in H8 |

## Appendix: files and sources checked

- Repository (`main` at `60ea446`): `common/protocol.odin`, `common/auth.odin`,
  `server/network.odin`, `server/network_peer.odin`, `server/network_threading.odin`,
  `server/ipc.odin`, `server/main.odin`, `server/database.odin`,
  `server/network_event_handler_test.odin`, `client/transport.odin`,
  `client/network_worker.odin`, `client/app.odin`, `client/main.odin`, `client/view.odin`,
  `client/AGENTS.md`, `server/AGENTS.md`, `docs/assessment-2026-10.md` (items 6 and 9),
  `dev/Containerfile`, `dev/install-packages.sh`, `dev/bootstrap-odin.sh`,
  `dev/live-proof.sh`, `check.sh`, `README.md`.
- Odin vendor (host `db92c6de`; SDL3 audio and ENet are unchanged since the pinned
  `b76605be`): `vendor/sdl3/sdl3_audio.odin`, `sdl3_hints.odin`, `sdl3_events.odin`,
  `sdl3_init.odin`, `vendor/sdl3/mixer/` (`libopus-0.dll` exports via `objdump -p`),
  `vendor/miniaudio/common.odin`, `device_io_types.odin`, `device_io_procs.odin`,
  `data_conversion.odin`, `vendor/ENet/enet.odin`, `core/dynlib/lib.odin`,
  `core/encoding/cbor/marshal.odin`.
- System: `rpm -q SDL3 opus opus-devel`, `nm -D /usr/lib64/libopus.so.0`,
  `strings /usr/lib64/libSDL3.so.0`, `pactl info`, `command -v` for the PipeWire, sox, ffmpeg
  and espeak-ng tools.
- Upstream: `xiph/opus` `include/opus_defines.h` and `include/opus.h` (`main`, fetched
  2026-11-05) for the request codes, the prototypes and the `decode_fec`/`frame_size` rules.
- Prototypes (scratch only, not committed): the CBOR envelope size, libopus through
  `core:dynlib` with `#c_vararg` ctl, SDL3 `disk` driver capture, and the
  `sox`/`ffmpeg` Opus round trip.
