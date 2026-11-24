# Voice: Manual Test Kit

For maintainers. `dev/voice-manual-test.sh` measures voice on real audio devices on a Linux
host with PipeWire. It covers what CI cannot: SDL's PipeWire driver, device buffers, the voice
activity gate on speech, and the delay from one person's microphone to another person's
speakers. It creates virtual devices for the test and removes them afterwards. Nothing plays on
your speakers, and nothing is read from your microphone.

CI covers the rest without audio hardware: `dev/voice-proof.sh` (file sinks and SDL's disk
driver), and the unit tests of the gate, the jitter buffer and the engine. The design is
`docs/plan/voice-rooms-design.md`, sections 6.3 and 6.4.

## Running It

```sh
./dev.sh up                          # or any running server
dev/voice-manual-test.sh             # default server 127.0.0.1:12345
dev/voice-manual-test.sh host:port   # another server
```

It needs `pactl`, `pw-cat`, `pw-record` and `pw-link` (PipeWire's tools, with pipewire-pulse),
plus `sox`, and stops unless `pactl info` reports a PipeWire server. Without `espeak-ng` it
skips the speech phase. Without `python3` and numpy it skips the analysis of the tone's
dropouts, the speech, the bursts and the clicks, but still runs voice-check on the tone. It
builds the client and `dev/tools/voice-check` with the host's `odin`; if that fails, it builds
them in the dev image (`./dev.sh shell`). The client is the same one users run: SDL's PipeWire
driver, and the default voice settings of a fresh profile.

A run takes about two and a half minutes. Each run makes two throwaway accounts on the server
(`voice-mt-a-…` and `voice-mt-b-…`), which join room 1's voice. Use the dev pod, not the
tester server. If either client leaves voice or loses its connection during the run (a server
restart, for example), the run stops, because a re-join starts fresh counters.

Settings, all optional, as environment variables:

| Variable | Default | Meaning |
| --- | --- | --- |
| `HAYCHAT_VOICE_MANUAL_ROOM` | `1` | Room to join (ignored in encrypted mode) |
| `HAYCHAT_VOICE_MANUAL_ENCRYPTED` | `0` | `1` measures voice in an encrypted room instead (below) |
| `HAYCHAT_VOICE_MANUAL_PSQL` | `dev.sh psql` | psql command that encrypted mode uses to make A an admin |
| `HAYCHAT_VOICE_MANUAL_PHASES` | `tone speech taps bursts clicks` | Phases to run |
| `HAYCHAT_VOICE_MANUAL_LEVELS` | `-6 -18 -30` | Peak levels of the speech, in dBFS |
| `HAYCHAT_VOICE_MANUAL_NOISE_DB` | `-60` | Pink noise under the speech, RMS in dBFS |
| `HAYCHAT_VOICE_MANUAL_THRESHOLD_DB` | the client's default | A's voice activity threshold |
| `HAYCHAT_VOICE_MANUAL_CLICKS` | `20` | Clicks in the latency train, and taps in the `taps` phase |
| `HAYCHAT_VOICE_MANUAL_CLIENT` | build one | Use this client binary, for example one built with a changed constant, to compare |
| `HAYCHAT_VOICE_MANUAL_KEEP` | `0` | `1` keeps the work directory with every recording and log |

### Encrypted Rooms

Voice in an encrypted room (protocol 21, `docs/plan/e2ee-voice-design.md`) seals every frame
and pads every Opus packet to one size per bitrate, so its quality is measured separately.
The first version used constant bitrate, which this comparison caught dropping a steady tone
(design section 8). Run the kit twice and compare the summaries:

```sh
dev/voice-manual-test.sh                                  # unencrypted baseline, room 1
HAYCHAT_VOICE_MANUAL_ENCRYPTED=1 dev/voice-manual-test.sh # encrypted room, padded packets
```

In encrypted mode A signs in once without audio, is made an admin with
`deploy/sql/make-admin.sql` through `HAYCHAT_VOICE_MANUAL_PSQL` (by default `./dev.sh psql`,
because the dev pod does not publish its database; another server needs its own psql
command), and signs in again. It then creates an encrypted Admin invite room named
`voice-mt-e2ee-…` and adds B. Once both have verified the room's member log, the phases run
as usual in that room. The kit checks that both joins report `encrypted` and that each client
accepted the other's voice key. The summary gets an `encrypted:` line with the frames B opened
and its drops: bad tag, no key, unknown key ID. All three should be 0. The room stays on the
server afterwards, like the accounts.

### What It Sets Up

| Node | What it is | Used by |
| --- | --- | --- |
| `HC-MT-Feed` (`hc_mt_feed`) | A null sink | The kit plays test material into it with `pw-cat` |
| `HC-MT-Mic` (`hc_mt_mic`) | `module-remap-source` on HC-MT-Feed's monitor: a virtual microphone | Client A: `voice-source device:HC-MT-Mic` |
| `HC-MT-B-Out` (`hc_mt_b_out`) | A null sink | Client B: `voice-sink device:HC-MT-B-Out` |
| `HC-MT-Probe` (`hc_mt_probe`) | A stereo null sink. HC-MT-Mic is linked to its left channel and HC-MT-B-Out's monitor to its right (`pw-link`) | One `pw-record` per phase |

The probe matters for timing. Two separate `pw-record` processes start at different moments,
so their files cannot be compared sample by sample. With one recorder, what A heard and what B
played are on the same clock, and the difference between the channels is the delay through
HayChat. It does not include the sound card's own output buffer, which adds the same few
milliseconds to any application.

A null sink with `media.class=Audio/Source/Virtual` (the recipe in design 6.3) does not work
as a microphone here: WirePlumber does not link a playback stream to a source, and `pw-cat`
then falls back to the default sink. That is why the kit uses a null sink plus a remap
source.

### Safety

- Every stream the kit starts names its virtual target and sets `node.dont-fallback = true`.
  A missing target is then an error instead of the default device. Without that property,
  `pw-cat --target` with a missing or unsuitable target plays on your default sink.
- The clients run with `SDL_AUDIO_DRIVER=pipewire`, `PIPEWIRE_NODE` set to their virtual node,
  and `PIPEWIRE_PROPS='{ node.dont-fallback = true }'`. If SDL resolved the device name to the
  default device, PipeWire would still connect the stream to the virtual node or refuse it.
- Before any sound plays, the kit checks with `pactl` that B's playback stream is on
  HC-MT-B-Out and A's capture stream is on HC-MT-Mic, and stops if either is not.
- It records the default sink and source first, and puts them back at once if loading a module
  changed them. It never sets them otherwise.
- The exit trap runs on success, failure and Ctrl-C. It closes the clients' input (EOF stops a
  client, with SIGKILL after 5 s; an older `HAYCHAT_VOICE_MANUAL_CLIENT` build with SDL audio
  open ignores SIGTERM, #36), stops
  `pw-cat` and `pw-record`, unloads every module the kit loaded, and compares the module list
  with the one from the start. The last line says whether they match:
  `cleanup: unloaded 4 modules; module list and default devices are as before`. When another
  program loaded or unloaded modules meanwhile, it says so and lists them instead; that is not
  the kit's to undo. A module of the kit's still loaded, or an `hc_mt_*` node still present,
  prints a `WARNING: still loaded:` line and makes the run fail.
- If a run is killed with SIGKILL, nothing can clean up. The next run refuses to start while a
  `hc_mt_*` node exists. Remove leftovers with
  `pactl list short modules | awk '/hc_mt_/ {print $1}' | xargs -r -n1 pactl unload-module`.

## Reading the Output

Every phase prints both clients' counter changes (`voice-stats` before and after), and then
its analysis. A summary at the end has one line per phase:

```text
==> [voice-manual] summary
    tone: voice-check pass: 7.51 s recorded, 6.00 s of tone from 0.70 s (1 run(s), 11
      window(s)); 440.00 Hz (worst +0.00 Hz, target 440.00 ± 5.00); level -9.03 dBFS
      (expected -9.03 ± 6.00); SNR 73.4 dB (worst 68.3, min 20.0); dropouts 0; A sent 315,
      B received 315, FEC 0, PLC 0, late 0
    speech peak -6 dBFS (speech -24.2 dBFS): heard 99.6 % of speech frames, starts clipped
      0/9 (mean 4 ms), ends clipped 0, background sent 0 ms; A sent 698 gated 700, B spurts
      6, FEC 0 PLC 0
    speech peak -18 dBFS (speech -36.1 dBFS): heard 98.3 % of speech frames, starts clipped
      4/9 (mean 21 ms), ends clipped 0, background sent 0 ms; A sent 673 gated 720, B spurts
      6, FEC 0 PLC 0
    speech peak -30 dBFS (speech -47.0 dBFS): heard 80.7 % of speech frames, starts clipped
      8/10 (mean 111 ms), ends clipped 0, background sent 0 ms; A sent 541 gated 856, B
      spurts 15, FEC 0 PLC 0
    taps: 5 of 20 taps opened the gate; A sent 80 frames
    bursts: spurt-start delay p50 150.4 ms, p95 158.2 ms (10/10 heard), B spurts 10
    clicks: mouth-to-ear p50 135.8 ms, p95 135.8 ms (20/20 heard), B late 0, FEC 0 PLC 0,
      depth 3
==> [voice-manual] done
==> [voice-manual] cleanup: unloaded 4 modules; module list and default devices are as before
```

(Long lines are wrapped here.)

| Phase | What it plays into A's microphone | What it reports |
| --- | --- | --- |
| `tone` | 440 Hz at amplitude 0.5 for 6 s | voice-check on B's output: frequency, level, SNR. Also *dropouts*: runs of digital silence of 1 ms or more inside the tone, meaning B's playout queue ran dry |
| `speech` | Six espeak-ng sentences, 1.5 s apart, at each peak level, over a pink noise floor, with A on voice activity | Speech level at A's microphone; share of speech frames that reached B; words whose start or end was clipped by more than 20 ms; background noise sent more than a hangover after any speech |
| `taps` | 5 ms clicks 1.007 s apart (so they fall at every position within a 20 ms frame), as many as `HAYCHAT_VOICE_MANUAL_CLICKS`, on voice activity | How many taps opened the gate (B's talk spurts). An open gate sends at least one hangover of background |
| `bursts` | Ten 300 ms 1 kHz bursts, 1.507 s apart (every frame position again), on voice activity | Delay from a burst's start at A to its start at B. This is the delay of a talk spurt's first syllable: the gate's attack plus the jitter buffer's pre-roll |
| `clicks` | The click train, with A's gate held open | Steady-state mouth-to-ear delay per click, p50 and p95 |

Counters: `A sent` and `gated` are frames A encoded and frames the gate held back (20 ms each).
`capture dropped` counts frames A threw away because its capture queue backed up. `B received`
counts frames that reached B's jitter buffer. `FEC` and `PLC` count frames B rebuilt or
concealed. `late` counts frames that arrived after their playout time, and `spurts` counts
talk spurts B heard. `jitter` is B's interarrival jitter estimate in milliseconds, and `depth`
its jitter buffer target in frames of 20 ms.

How the speech analysis decides: a 10 ms frame is *speech* when the clean (noise-free)
material is within 40 dB of its loudest frame and not under the noise floor. It is *heard*
when B's output in that frame, shifted by the measured delay, is not digital silence. B plays
nothing at all while A's gate is closed, so heard and not heard are easy to tell apart. Words
are speech runs merged across gaps under 150 ms.

## What Good Numbers Look Like

On a loopback server (the dev pod on the same machine):

| Measure | Good | Investigate |
| --- | --- | --- |
| Tone | voice-check PASS: 440 Hz ±1, level within 1 dB of −9 dBFS, SNR above 60 dB, 0 dropouts | Any dropout, or a level more than 3 dB off |
| FEC, PLC, late on loopback | 0 | Any: packets were lost or late with no network in the way |
| `capture dropped` | 0 | Any: the voice thread fell behind the microphone |
| Speech at −24 dBFS (a normal microphone) | ≥ 99 % heard, no clipped starts or ends | Under 98 % |
| Speech at −36 dBFS (a quiet microphone) | ≥ 95 % heard, a few starts clipped by one frame | Under 90 %: the threshold is too high for quiet microphones |
| Speech at −47 dBFS (below the default threshold) | Partly heard; the user has to raise gain or lower the threshold | — |
| Background sent beyond the hangover | 0 ms at a −60 dBFS floor | Anything: the gate lets silence through |
| Click delay (`clicks`) | p50 under 150 ms, p95 within 10 ms of p50 | p50 over 150 ms (design 6.4's loopback target), or a wide p95: jitter |
| Spurt start (`bursts`) | Within about 40 ms of the click delay | More: the attack or the pre-roll is too long |

Over a LAN, add the network's round trip to the delays; the design's target is under 200 ms.

## Measurements and Tuning (H8)

Measured on 2026-11-05 on the maintainer's Fedora 44 host: PipeWire 1.6.11 with a quantum of
2048 (min-quantum 1024), SDL 3.4's PipeWire driver, and a server from `main` at `c484ed7` in a
local pod (loopback); runs 7 and 8 use `main` after H8a and V1 (protocol 13), client and
server. Each line is one run of the kit. A variant is a client built with one
constant changed (`HAYCHAT_VOICE_MANUAL_CLIENT`), or the default client at another threshold
(`HAYCHAT_VOICE_MANUAL_THRESHOLD_DB`).

Delay and losses, with the defaults:

| Run | Tone | Clicks p50 / p95 | Spurt start p50 / p95 | B jitter, depth | FEC, PLC, late |
| --- | --- | --- | --- | --- | --- |
| 1 | PASS, 440.00 Hz, −9.04 dBFS, SNR 73.9 dB, 0 dropouts | 128.0 / 128.0 ms | 157.7 / 167.1 ms | 2.3 ms, 3 | 0, 0, 0 |
| 2 | PASS, 440.00 Hz, −9.04 dBFS, SNR 72.6 dB, 0 dropouts | 133.1 / 133.1 ms | 147.1 / 155.1 ms | 2.2 ms, 3 | 0, 0, 0 |
| 3 | PASS, 440.00 Hz, −9.04 dBFS, SNR 74.2 dB, 0 dropouts | 143.8 / 143.8 ms | 150.4 / 162.0 ms | 2.0 ms, 3 | 0, 0, 0 |
| 4 | PASS, 440.00 Hz, −9.03 dBFS, SNR 73.4 dB, 0 dropouts | 135.8 / 135.8 ms | 150.4 / 158.2 ms | 2.4 ms, 3 | 0, 0, 0 |
| 5 | PASS, 440.00 Hz, −9.03 dBFS, SNR 74.1 dB, 0 dropouts | 131.8 / 131.8 ms | 148.2 / 160.3 ms | 2.1 ms, 3 | 0, 0, 0 |
| 6 | PASS, 440.00 Hz, −9.05 dBFS, SNR 73.6 dB, 0 dropouts | 141.1 / 141.1 ms | 150.5 / 162.5 ms | 2.9 ms, 3 | 0, 0, 0 |
| 7 | PASS, 440.00 Hz, −9.04 dBFS, SNR 73.4 dB, 0 dropouts | 145.1 / 145.1 ms | 150.5 / 162.0 ms | 2.4 ms, 3 | 0, 0, 0 |
| 8 | PASS, 440.00 Hz, −9.03 dBFS, SNR 75.1 dB, 0 dropouts | 146.5 / 146.5 ms | 150.4 / 162.0 ms | 2.5 ms, 3 | 0, 0, 0 |

Runs 1 and 2 spaced the bursts exactly 1.5 s apart, so every burst of a run started at the
same position in a frame; later runs use 1.507 s, and their p95 covers every position. The
click delay does not vary within a run (p50 = p95), but it moves between runs by up to 19 ms.
That depends on where A's capture and B's playback quanta happen to fall relative to the 20 ms
frames, which is fixed when the devices open. A spurt starts 4 to 30 ms later than the steady
state of the same run: the gate drops the first loud frame (its attack), and where the onset
falls inside a frame adds up to one frame more.

Voice activity: speech over a −60 dBFS pink noise floor unless a row says otherwise. Each
cell gives three numbers:

- the share of speech frames heard at B;
- how many words had their start clipped (of about 9 words, but 27 at the quietest level over
  −50 dBFS noise, where the noise splits words), with the mean clip in brackets;
- how much background was sent beyond the hangover.

All rows come from one session (run 3 and its variants). Across runs 3 to 8 the defaults heard
99.6–99.9 % of the −24 dBFS speech, 97.7–98.3 % at −36 dBFS and 66–81 % at −47 dBFS, with
the same clipping, and 4 or 5 of 20 taps opened the gate.

| Gate | Speech −24 dBFS | Speech −36 dBFS | Speech −47 dBFS (−43 over −50 noise) | Taps opening the gate |
| --- | --- | --- | --- | --- |
| **Default:** −45 dBFS, attack 2, hangover 300 ms | 99.7 %, 0, 0 ms | 98.0 %, 4 (24 ms), 0 ms | 70.7 %, 8, 0 ms | 5 of 20 |
| Default over −50 dBFS noise | 99.7 %, 0, 0 ms | 97.9 %, 3, 0 ms | 89.8 %, 7, 0 ms | 5 of 20 |
| Threshold −50 dBFS | 99.7 %, 0, 0 ms | 98.5 %, 2, 0 ms | 94.4 %, 6, 0 ms | 4 of 20 |
| Threshold −50 dBFS over −50 dBFS noise | 100 %, 0, **11.7 s** | 100 %, 0, **11.7 s** | 100 %, 0, **12.6 s** (the gate never closed: 1 spurt) | 4 of 20 |
| Attack 1 frame | 100 %, 0, 0 ms | 98.7 %, 3 (16 ms), 0 ms | 87.3 %, 8, 0 ms | **20 of 20** |
| Attack 1 frame over −50 dBFS noise | 100 %, 0, **330 ms** | 98.9 %, 1, **330 ms** | 96.0 %, 1, **660 ms** | **20 of 20** |
| Hangover 200 ms | 99.9 %, 0, 0 ms | 96.6 %, 5 (30 ms), 0 ms | 62.2 %, 10, 0 ms (26 spurts, not 14) | — |

No configuration had word ends clipped. The hangover covers every word's tail even at
200 ms. Its real job is to hold a sentence together: at 200 ms the quiet sentences broke into
almost twice as many spurts, and each new spurt loses its first frame to the attack.

Other variants:

- **Playout queue of 1 frame** (`VOICE_PLAYBACK_TARGET_FRAMES`): the tone failed voice-check
  with 290 dropouts in 6 s (SNR 15.5 dB, 459.5 Hz), and the click delay rose to 397 / 657 ms
  with 2 of 20 clicks lost. One frame (960 samples) is less than PipeWire's smallest quantum
  (1024), so every device pull empties the queue.
- **The attack** with one frame starts a spurt 10 ms sooner (139.8 / 147.9 ms against
  150.4 / 162.0 ms in the same session).

Decisions. No default changed, so `client/config.odin` and `config_test.odin` stay as they are.

- **Voice activity threshold stays at −45 dBFS** (`voice_vad_threshold_db`). It passes 98 % of
  speech from a quiet microphone (−36 dBFS) and sends no background over a −50 dBFS floor.
  −50 dBFS would hear more of a very quiet voice (94 % against 71 % at −47 dBFS), but with a
  −50 dBFS floor (a fan, a laptop microphone) the gate never closed. Sending a room's noise
  all the time is worse than asking a quiet user to raise the gain: they can see the problem
  on the meter, and the tester guide tells them what to do.
- **Attack stays at 2 frames** (`VOICE_VAD_ATTACK_FRAMES`). One frame gains 1–2 % of quiet
  speech and 10 ms at a spurt's start, but every tap opened the gate (20 of 20 against 5 of 20),
  and with a −50 dBFS floor it sent 0.3–0.7 s of background where two frames sent none.
- **Hangover stays at 300 ms** (`VOICE_VAD_HANGOVER_FRAMES`): no clipped word ends in any run,
  and fewer, longer spurts than 200 ms.
- **Jitter buffer default depth stays at 3** (`JITTER_DEFAULT_DEPTH`): on loopback the
  measured jitter was 1.9 to 3.4 ms, which the buffer's own adaptation (`jitterDepthForJitter`)
  also maps to 3, with no late, FEC or PLC frames in any run. A smaller default would only
  apply to a speaker's first 16 frames before the buffer adapts.
- **Playout queue stays at 2 frames** (`VOICE_PLAYBACK_TARGET_FRAMES`): see above.

What the numbers leave open: a word's first 20 ms is lost when the gate opens (the attack
frame is dropped, not delayed). A one-frame look-back, sending the frame before the one that
opened the gate, would recover it without the attack-1 problems. That is an engine change for
later. The spurt-start delay sits at the design's 150 ms loopback target, and the steady state
is under it.

## Listening Yourself

The kit never plays anything you can hear. To listen to what B receives, connect HC-MT-B-Out to
your headphones yourself, only while you want to, and turn the volume down first:

Start the kit in one terminal. Once it prints `creating the virtual devices`, run this in
another terminal. It fails, rather than falling back to another device, while HC-MT-B-Out
does not exist:

```sh
pw-loopback \
	--capture-props='target.object=hc_mt_b_out stream.capture.sink=true node.dont-fallback=true' \
	--playback-props='target.object=YOUR_HEADPHONES_SINK node.dont-fallback=true'
```

`pactl list short sinks` lists sink names. Stop `pw-loopback` with Ctrl-C; it removes its
streams when it exits. To hear the kept recordings later, play a probe file's right channel:
`sox WORK_DIR/probe-speech-18.wav -d remix 2`. You can also test by hand with two GUI clients:
run `pactl load-module module-null-sink sink_name=hc_listen` and choose it as one client's
output, then loop that to your headphones the same way. Unload the module afterwards.

## Windows Manual Checklist

CI only type-checks the Windows client (`./check.sh`), so a person runs this list on Windows
before a release that changes voice (design section 9). Use the release zip, or a build with
the DLLs copied as the README says.

1. **libopus:** `libopus-0.dll` sits next to `haychat-client.exe`, and its licence is in
   `licenses\opus-LICENSE.txt`.
   Start the client and join voice: the voice bar says "Voice connected", not "Voice
   unavailable: libopus not found". Rename the DLL and restart: chat still works, and voice
   says libopus is missing. Put the DLL back.
2. **Device lists (WASAPI):** in **Settings → Voice**, the input and output lists show
   "System default" first and then every enabled Windows recording and playback device, with
   the names from the Sound control panel.
3. **Test microphone:** the meter moves when you speak, and you hear yourself through the codec
   with a short delay. The threshold line sits on the meter.
4. **Join with a second person:** you hear each other, and the speaking ring follows whoever
   talks. Check both voice activity and push-to-talk.
5. **Mute and deafen:** mute stops sending at once, and the other side sees "muted". Deafen
   stops playback at once and also mutes. Undo both.
6. **Push-to-talk while focused:** hold the key with the HayChat window focused, and you are
   heard. With **In other windows too** off, click another window while holding the key,
   and sending stops.
7. **Push-to-talk in another window:** with **In other windows too** on (the default),
   Settings → Voice says push-to-talk also works in other windows. Join voice, focus another
   application (a browser, a game in windowed and in fullscreen mode, and an elevated
   window such as Task Manager), and hold the key: you are heard, and the speaking ring
   shows. Release it, and sending stops. Choose a letter key: typing it in a HayChat text
   field does not open the microphone, typing it in another window does. Note any game or
   elevated window where the key is not seen.
8. **Switching devices while joined:** choose another microphone and then another output. The
   session stays joined, and audio continues on the new device after a short gap.
9. **Unplugging a headset while joined:** voice moves to the system default, and the chosen
   device stays listed in Settings → Voice as "(not connected)". Plug it back in: voice
   returns to it.
10. **Bluetooth headset (if you have one):** opening the microphone can switch the headset to
    its hands-free profile, which changes the sound quality. Note what Windows does, and
    whether HayChat keeps playing.
11. **Reconnect:** disconnect the network for a few seconds. The voice bar says "Rejoining
    voice…", and voice comes back without a click.

Report anything that differs, with the Windows version and the device names.

## Global Push-To-Talk On Linux

`odin test client/hotkey` covers the X11 poller on Xvfb (with XTest pressing the key) and
the portal client against a mock GlobalShortcuts portal. Real desktops differ in what they
accept, so check by hand on each you can reach. Run the client from a terminal: the portal
works for an unsandboxed app only once it has registered its app ID (`chat.haychat.client`).

1. **X11 session** (`echo $XDG_SESSION_TYPE` says `x11`): choose push-to-talk, join voice,
   focus another window and hold the key. You are heard while it is held. Settings → Voice
   says push-to-talk also works in other windows.
2. **Wayland, KDE Plasma:** choose push-to-talk with F13 (or any non-modifier key) and join
   voice. A Plasma dialog asks to confirm the shortcut. Accept it: Settings → Voice names the
   shortcut, and holding it in another window sends. **Change shortcut** opens Plasma's
   dialog; a new key works at once. Leave and join again: no second dialog. Restart HayChat
   and join: Plasma remembers the shortcut.
3. **Wayland, KDE, Left Ctrl:** with the default Left Ctrl, nothing is proposed. Pick a key
   in the dialog, or cancel it: Settings → Voice then says the desktop cancelled the
   binding, and push-to-talk still works inside the window.
4. **Wayland, GNOME 48 or later:** the same as 2. On GNOME 47 or older, or Sway, Settings →
   Voice says the desktop has no GlobalShortcuts portal, and push-to-talk works inside the
   window.
5. **Release while switching windows:** hold the key in another window, alt-tab to HayChat
   and back while still holding it, then release. Sending stops on release, not before.

Report the desktop, its version, and what the dialog offered.

## Jitter Buffer Edges To Check By Hand

Two edges from the review of PR #17 (`docs/plan/2026-11-05-after-first-testers.md`) are hard
to reach on loopback. Check them by hand with two clients:

- **Fast push-to-talk re-press.** In push-to-talk mode, release the key and press it again
  within about 200 ms while speaking a long vowel. The listener should hear no gap or clipped
  syllable at the re-press.
- **Sender restart.** While both are joined, quit the speaker's client, start it again, join
  the same room's voice, and talk. The listener's `voice-stats` `depth`
  should come back to the loopback value (3) within a few spurts rather than staying high.
