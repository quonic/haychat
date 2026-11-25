# Spike: Windows WASAPI Capture in the Communications Category

Issue #172, part of #46 (recommendation 3). Status: spike done; the decision on a real backend
waits for the desktop run in [Desktop Checklist](#desktop-checklist). Related: #170 (RNNoise),
#171 (WebRTC echo canceller, AEC3), #173 (PipeWire docs), #71 (Windows checklist).

## Summary

- **The SDL finding is confirmed.** SDL's WASAPI backend
  (`src/audio/wasapi/SDL_wasapi.c`, `WASAPI_PrepDevice`) has the stream role code under
  `#if 0` in 3.4.0, 3.4.18 (we ship it) and `main`. Every SDL stream, capture and playback,
  gets `AudioCategory_Other`. The code inside matches `"Communications"`, so our
  `"Communication"` would not have matched either. The client now passes the role per platform
  (`voiceSDLStreamRole`), which changes nothing on Windows until SDL turns the code back on.
- **The USB microphone breakage was GameChat, not Communications.** SDL added the role on
  2025-10-13 (libsdl-org/SDL#14091, PR #14235, commit a58ae3a) and disabled it 17 days later,
  before 3.4.0 (commit a7147f3): "Setting AudioCategory_GameChat breaks audio on several
  devices, including Behringer U-PHORIA UM2 and RODE NT-USB Mini". No public report names
  Communications. The probe compares six categories on one microphone, so a desktop run with
  such a microphone can tell them apart.
- **A WASAPI capture of our own works and is cheap to call.** `dev/tools/wasapi-probe` opens
  the endpoint in shared mode, sets the category, and captures 48 kHz mono float with
  `AUTOCONVERTPCM`. Under Wine it got 100 % of the expected frames in 10 ms packets for every
  category. On the `runepad-win` VM it builds and enumerates, but the VM has no audio
  endpoint at all, so nothing past enumeration ran on real Windows.
- **What Windows does with the stream can be read, but only on Windows 11.**
  `IAudioEffectsManager` (build 22000+) lists the stream's effects (AEC, noise suppression,
  AGC, deep noise suppression) and says whether the app may turn each off.
  `IAcousticEchoCancellationControl` (build 22621+) sets the echo reference to a render
  endpoint. On Windows 10 an app cannot see which processing a stream gets.
- **Recommendation: not yet.** A real backend is about 700 to 900 lines of Odin COM code that
  no CI runner can run and that behaves differently with each driver. Ship #170 and #171 on
  SDL's capture first, with the rules in [No Double Processing](#no-double-processing). Build
  the backend only if the desktop checklist shows three things: communications effects on
  common hardware, a working echo reference to SDL's playback device, and no USB breakage.
  If it is built, it is for Windows 11 only and opt-in.

## What SDL Does Today

From SDL 3.4.18's `SDL_wasapi.c` and `SDL_immdevice.c`:

- For each device it opens, SDL queries `IAudioClient2` and calls `SetClientProperties` with
  a zeroed `AudioClientProperties` (`AudioCategory_Other`). With
  `SDL_HINT_AUDIO_DEVICE_RAW_STREAM` set, it adds `AUDCLNT_STREAMOPTIONS_RAW`. That hint is
  **live** in 3.4.18, outside the `#if 0`.
- The format is the endpoint's mix format, with `AUTOCONVERTPCM | SRC_DEFAULT_QUALITY` when the
  rate differs from the one asked for. The stream is event driven, and SDL uses
  `IAudioClient3::InitializeSharedAudioStream` when it can.
- The default device follows the **console** role (`SDL_IMMDevice_role = eConsole`).
  Windows' "default communication device" is never used.
- SDL names devices by `PKEY_Device_FriendlyName` and exposes no endpoint ID, so an endpoint
  can be matched to an SDL device only by name.
- SDL reads the hints whenever it opens a device, including when it reopens one after the
  default changes. So setting a hint for one open and changing it for the next is not robust.

When a future SDL turns the role code back on, our `"Communications"` hint applies to the
**playback** device as well as capture, because the hint is process-wide. Communications
render streams can get render-side processing and may count as a communication session for
ducking. A comment next to `SDL3_DLL_SHA256` in `deploy/release-artifacts.sh` asks whoever
bumps SDL to check this file and this note first. Otherwise an SDL update could turn on
Windows' processing underneath #170 and #171 without anyone noticing.

## The Prototype

`dev/tools/wasapi-probe` (Odin, `core:sys/windows` plus `vendor:windows/wasapi`). The pinned
Odin's `vendor:windows/wasapi` already declares `IMMDeviceEnumerator`, `IMMDevice`,
`IMMNotificationClient` and `IAudioClient` to `IAudioClient3`. The probe declares the rest
itself from the Windows SDK 10.0.26100 headers: `IAudioCaptureClient`,
`IAudioEffectsManager`, `IAcousticEchoCancellationControl` and the effect GUIDs. C was not
needed. Two gaps in the bindings are worth knowing:

- `windows.PROPVARIANT` is a 16-byte `DECIMAL`, but the real `PROPVARIANT` is 24 bytes on
  x64. `IPropertyStore::GetValue` would write past it, so the probe declares its own.
- `wasapi.WAVE_FORMAT` has no `PCM` (1) member.

For each of Other, Other + RAW, Communications, Communications + RAW, Speech and GameChat, the
probe opens one stream and reports:

- what `SetClientProperties` returned;
- the mix format, device periods and shared engine periods;
- whether 48 kHz mono float is native or needs `AUTOCONVERTPCM`;
- what `Initialize` returned, the buffer size and the stream latency;
- the effects list and the processing rule's verdict for it (`processingAdvice`);
- whether the AEC reference control exists and accepts the render endpoint and NULL;
- one second of capture: frames against the expected count, silent and discontinuity flags,
  first packet time, longest event gap, peak and RMS.

Then it runs a main capture (`--category`, `--seconds`, `--out FILE`, F32LE mono like
`voice-sink`). It counts device notifications during the capture, stops on
`AUDCLNT_E_DEVICE_INVALIDATED`, and can play a tone through SDL during the capture
(`--play-tone HZ`), so `voice-check` shows how much of the tone the stream's echo canceller
removes. The usage text is at the top of `main.odin`. `./check.sh` type-checks the tool for
Windows and runs its tests (arguments, effect GUIDs, the processing rule, downmixing,
statistics) on Linux.

Building: `odin build dev/tools/wasapi-probe -target:windows_amd64 -linker:lld
-windows-sdk-root:SYSROOT` cross-builds it like `deploy/release-artifacts.sh --windows`. That
needs the xwin sysroot, which asks you to accept Microsoft's licence, so the spike did not
download it. It was built natively on the VM instead, with `odin build
dev/tools/wasapi-probe -out:wasapi-probe.exe` (Odin nightly `dev-2026-11` and MSVC). Put
`SDL3.dll` from Odin's `vendor/sdl3` next to the executable.

### Results

| Where | What ran | What it showed |
| --- | --- | --- |
| `runepad-win` (Server 2025, build 26100, SSH and desktop session) | `--list`, a default run | Builds, COM and the enumerator work, the build gates read yes. **0 capture and 0 render endpoints** (`E_NOTFOUND`): the VM has no sound device, and the spike was not allowed to add one. Nothing about streams, effects, the echo reference or latency can be measured there. |
| Wine 11.21 on the Fedora host (winepulse on PipeWire), a sink monitor endpoint, no microphone | `--list`, the six-category comparison, a 2 s main capture to a file | The endpoint list and properties are read correctly. `SetClientProperties` returns S_OK for every category. The mix format is 2 ch 48 kHz float, so mono needs `AUTOCONVERTPCM`, and `Initialize` with it returns S_OK. Period 10 ms (min 5.33), buffer 30 ms, latency 20 ms. 100 to 102 % of the expected frames, no discontinuities. Effects and the AEC control return `E_NOINTERFACE`, since Wine has neither. This checks the COM declarations and the capture loop, not Windows' behaviour. |

Not measured anywhere yet: real effects lists, the echo reference, the latency a
communications APO adds, Voice Clarity, ducking, the USB breakage, and device changes. These
are the desktop checklist.

## No Double Processing

The rule for #170 (RNNoise) and #171 (AEC3) on Windows: **for each capture stream, each job
(echo cancellation, noise suppression, gain control) has one owner, Windows or HayChat.
Echo cancellation and noise suppression have the same owner.** An echo canceller placed after
another stage's nonlinear noise suppression cancels worse, and two noise suppressors in a row
add artefacts and remove speech. `processingAdvice` in the probe encodes the per-job part, and
its tests pin it.

On SDL's capture (today, and the path #170 and #171 build on):

1. SDL's capture is `AudioCategory_Other`, Windows' default mode. In default mode, drivers
   normally do no echo cancellation, but some apply OEM noise suppression or beamforming
   (Realtek, Intel, laptop arrays). SDL gives no way to read a stream's effects.
2. For #171, set `SDL_HINT_AUDIO_DEVICE_RAW_STREAM` on Windows while in-app echo cancellation
   or noise suppression is on. Microsoft's mode documentation says raw capture "must not
   include any time varying or adaptive processing, such as echo control, automatic gain
   control, or noise suppression". RAW also drops beamforming and OEM gain, so laptop array
   microphones get quieter; the voice gate and input gain must cope with that. Where
   `RawProcessingSupported` is false, `SetClientProperties` fails, SDL logs it and keeps
   default mode. The hint is process-wide and SDL applies it to playback too, so measure
   that first (render effects such as speaker protection). If that is a problem, drop RAW
   and accept the small risk of OEM default-mode noise suppression.
3. To *know* what default mode does on an endpoint (Windows 11 only), the client can open a
   second, never-started `IAudioClient` on the same endpoint with the same category, read
   `IAudioEffectsManager`, and release it. That is about 150 lines of the probe's COM code
   and costs a few milliseconds when voice starts. Effects are per stream and mode, so this
   gives the same answer SDL's stream would get.
4. While SDL's role code is under `#if 0`, the `"Communications"` role cannot turn
   processing on. After an SDL bump that turns it on, either remove the Windows role (keep
   Other) or gate #170 and #171 on the effects as in the backend rules below.

With our own communications backend (if built):

1. Open in `AudioCategory_Communications`, read the effects after `Initialize`, and register
   `IAudioEffectsChangedNotificationClient`. The user can turn enhancements or Voice Clarity
   off while voice runs.
2. If AEC and NS are both on, Windows owns everything: #170 and #171 stay off for this stream,
   and HayChat's voice gate runs on the processed signal.
3. If AEC is missing, or the effects cannot be read (Windows 10, `E_NOINTERFACE`), reopen the
   stream as Other + RAW and let #170 and #171 own everything. Do not run AEC3 behind Windows'
   noise suppression.
4. If Windows does NS but not AEC (common on default-mode USB devices), the app either turns
   Windows' NS off where `canSetState` allows (`SetAudioEffectState`) and runs both itself,
   or reopens in RAW.
5. Windows' AEC uses a loopback of a render endpoint as its reference, so it cancels every
   app's sound, not just HayChat's (AEC3 only has HayChat's mix). If its reference is a
   different device from the one SDL plays to, it cancels nothing useful. On build 22621+,
   with an AEC that supports it, point the reference at SDL's playback endpoint (found by
   friendly name, see above), and again whenever SDL's playback device changes. Pass NULL
   when SDL follows the system default and Windows' own choice tracks it. When the control is
   missing (`E_NOINTERFACE`), Windows picks the reference. The desktop checklist measures
   whether that works with SDL playback.

Detecting double processing after the fact: with a tone played through SDL (`--play-tone`),
compare `voice-check` levels of the same capture in Other + RAW and in Communications. If the
tone falls by 20 dB or more, Windows' echo canceller is working. For noise suppression,
compare the floor (RMS with nobody speaking) the same way.

## Cost and Risk of a Real Backend

Estimated size, from the probe (about 1,050 lines in `probe_windows.odin`, most of it
reporting):

| Part | Lines |
| --- | --- |
| COM declarations: capture client, effects manager and its notification client, AEC control, PROPVARIANT, IIDs | 200 |
| Endpoint lookup by SDL name and ID, default role, notifications that hand reopen requests to the voice thread | 200 |
| Stream open (category, RAW, AUTOCONVERTPCM, period), reading the effects, the echo reference, the ducking opt-out | 200 |
| A `VoiceSourceKind.WASAPI` in `voice_engine.odin`: drain packets on the voice thread each 20 ms step into the existing capture ring, with a 100 ms buffer and no extra thread; reopen on invalidation, fall back to SDL capture on failure | 150 |
| Settings switch and status ("Windows voice processing: on, AEC and NS by Windows") | 50 to 100 |
| Linux-testable parts and their tests (the rule, conversion, matching) | 200 |

That is about 700 to 900 lines of client code, plus tests. Risks:

- **No Windows audio in CI or on the VM.** Every COM path is only type-checked in CI. A
  vtable mistake crashes the client. The probe's first Wine run crashed
  too, on a null pointer in the tool's own code.
- **Driver variance.** Microsoft's documentation says apps cannot find out which mode a stream
  really gets. Drivers that lack communications mode fall back to "the next best matching
  mode". Effects lists differ by vendor and Windows build.
- **USB microphones.** The SDL report (GameChat on a UM2 and an NT-USB Mini) is unexplained.
  Both are class-compliant USB microphones with no vendor APO, so Windows' own processing or
  its format negotiation in communications mode is the likely cause, and Communications could
  be affected too. Bound it with the probe's per-category comparison on such a microphone. A
  backend must detect the failure: under 90 % of the expected frames, only silent packets, or
  digital silence in the first second. On failure it falls back to SDL capture and remembers
  that per device.
- **Ducking.** Windows by default lowers other sounds by 80 % during a "communication
  session". Microsoft's pages describe the session but not exactly what starts one (the
  communications device role or the category). A backend should opt out with
  `IAudioSessionControl2::SetDuckingPreference(TRUE)`, which takes effect after the stream
  restarts. The desktop checklist checks it.
- **Device changes.** A named device that is unplugged, a format change, or another app
  taking exclusive mode ends the stream (`AUDCLNT_E_DEVICE_INVALIDATED`,
  `AUDCLNT_E_DEVICE_IN_USE`). "System default" must follow `OnDefaultDeviceChanged(eCapture,
  eConsole)`, plus the render default for the echo reference. Callbacks run on a Windows
  thread and may not reenter the enumerator, so they only post to the voice thread. SDL
  already does all of this for its own streams, and the backend must match it, including the
  "(not connected)" fallback in Settings → Voice.
- **The default device.** SDL follows eConsole. A communications backend could follow
  Windows' default communication device instead. Do not switch silently: "System default"
  must stay the same device for capture and playback.
- **Latency.** Communications APOs, especially echo cancellers, add delay. The probe reports
  stream latency and the first packet time; compare Other and Communications on a desktop.

## Desktop Checklist

Run on desktop Windows 11 (22H2 or later, 24H2 for Voice Clarity) and, if possible, Windows 10,
with a real microphone, speakers (not headphones, for the echo steps), and a USB microphone if
you have one. Build the probe as above and put `SDL3.dll` next to it. In PowerShell, in its
folder:

1. **Inventory:** `winver` and the device names. In Settings → System → Sound → each
   microphone → note the "Audio enhancements" setting and whether **Voice clarity** is offered
   and on. Then run `.\wasapi-probe.exe --list` and keep the output.
2. **Effects per category:** `.\wasapi-probe.exe --seconds 0` (default microphone, 1 s per
   category). For each category note the effects list and their state (on/off, may change),
   the AEC control lines, `Initialize`, and the capture line. Repeat with
   `--default-role communications` if Windows' default communication microphone differs.
3. **Echo, Windows' processing against none:** put the microphone near the speakers, stay
   quiet, and run
   `.\wasapi-probe.exe --category other --raw --seconds 10 --play-tone 440 --out raw.f32`,
   then the same with `--category communications --out comms.f32` (no `--raw`). Check both
   with `odin run dev/tools/voice-check -- FILE --freq 440 --min-seconds 5` from a checkout
   and note the printed level. The tone should be clearly weaker, or gone, in `comms.f32`.
   Listen to both (Audacity: File → Import → Raw Data, 32-bit float, little-endian, 1
   channel, 48000 Hz).
4. **Talking over the echo:** repeat step 3 while you count aloud. Your voice should survive
   in `comms.f32` (listen for clipped or pumping speech).
5. **The echo reference:** with two outputs (speakers and a headset), run step 3 with
   `--render "SPEAKERS NAME"` and then with `--render "SPEAKERS NAME" --echo-reference
   windows`. Note the `SetEchoCancellationRenderEndpoint` results and whether the tone is
   cancelled in both. Then make the headset the Windows default output and repeat both: this
   shows whether Windows' own choice follows SDL's device.
6. **Noise:** with a fan or typing near the microphone, record 10 s in `other --raw` and in
   `communications` without a tone. Compare the RMS in the capture lines and listen.
7. **USB microphone and categories:** `.\wasapi-probe.exe --device "USB MIC NAME"
   --probe-seconds 3 --seconds 0` while speaking steadily. For each category note the frame
   percentage, silent packets, levels and any `Initialize` error. GameChat and Communications
   are the two to compare. Breakage looks like under 90 % of the frames, all silent packets,
   or −200 dBFS.
8. **Device changes:** start `.\wasapi-probe.exe --device "USB MIC NAME" --seconds 30`, then
   unplug the microphone. Expect `stopped by ... AUDCLNT_E_DEVICE_INVALIDATED` and a removed
   or state count. Run it again with the default device and change the default microphone in
   Sound settings during the capture: note the "default changed (capture N)" count.
9. **Ducking:** play music in a browser, then run `.\wasapi-probe.exe --seconds 20` (and with
   `--default-role communications`). Does the music get quieter? Note the setting under
   Sound control panel → Communications.
10. **Latency:** compare the "stream latency" and "first packet" values between Other and
    Communications from step 2.
11. **Microphone privacy:** turn off Settings → Privacy → Microphone → "Let desktop apps access
    your microphone" and run step 2 once. Note what fails or whether the capture is silent.
    Turn it back on.
12. **HayChat itself:** with the release zip, steps 2 to 4 of the Windows Manual Checklist in
    `docs/voice-manual-test.md` still pass. The role change does nothing with SDL 3.4.18.

Report the outputs with the Windows version, device names and driver vendor (Device Manager →
the device → Driver) on #172.
