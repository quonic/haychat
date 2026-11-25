# Voice on Linux: Echo Cancellation and Noise Suppression

HayChat has its own echo cancellation and noise suppression (Settings → Voice; see
[Echo cancellation](user-guide.md#echo-cancellation) and
[Noise suppression](user-guide.md#noise-suppression)), when its libraries are installed. On
Linux, PipeWire can do the same before HayChat gets the sound, for every app, or where
HayChat's echo canceller is unavailable (Debian 13 and Ubuntu ship only webrtc-audio-processing
1.3, which HayChat cannot use). For that you add a small configuration file to PipeWire,
restart it, pick the new devices in HayChat, and turn HayChat's own switches off.

This page is for Linux with PipeWire, the default sound server on current Fedora, Ubuntu,
Debian and Arch desktops. The files here were checked with PipeWire 1.6.11 and WirePlumber
0.5.19 on Fedora 45 (see [What Was Checked](#what-was-checked)).

## Which One Do You Need?

| Your setup | What helps |
| --- | --- |
| Headphones or a headset in a quiet room | Nothing. Headphones are still the best fix for echo. |
| Headphones or a headset in a noisy room (a fan, typing, a street) | [Noise suppression](#noise-suppression): RNNoise, or DeepFilterNet for stronger suppression |
| Speakers (the others hear themselves) | HayChat's **Echo cancellation** (on by default), or else PipeWire's [echo cancellation](#echo-cancellation), which also removes some noise. |
| Speakers sometimes, a headset other times | [Echo cancellation that switches itself on](#automatic-echo-cancellation-smart-filters) |
| You prefer a window with switches to configuration files | [EasyEffects](#easyeffects) |

Use **one** noise suppressor at a time, and **one echo canceller**: HayChat's or PipeWire's.
Two in a row do not clean the sound more; they make your voice sound worse, and a second echo
canceller behind the first has nothing left to learn from. See
[HayChat's Own Settings](#haychats-own-settings).

## Before You Start

Check that PipeWire is your sound server:

```sh
pactl info | grep 'Server Name'     # "PulseAudio (on PipeWire 1.6.11)" or similar
```

Every file on this page goes into `~/.config/pipewire/pipewire.conf.d/`. Create the folder
once:

```sh
mkdir -p ~/.config/pipewire/pipewire.conf.d
```

After you add, change or remove a file, leave voice in HayChat and restart PipeWire. Sound in
every app stops for a moment:

```sh
systemctl --user restart pipewire pipewire-pulse wireplumber
```

Then join voice again. HayChat lists the devices again each time you open **Settings → Voice**.

- **Undo:** delete the file and restart PipeWire again. Nothing else changes.
- **A mistake in a file:** PipeWire may not start, and you have no sound at all. Run
  `journalctl --user -u pipewire -b | tail -20` to see the error, fix or delete the file, and
  restart PipeWire.
- **Device names:** some steps need the name PipeWire gives your speakers or microphone, not the
  one you see in menus. `wpctl status -n` shows the names under **Sinks** (speakers and
  headphones) and **Sources** (microphones), for example
  `alsa_output.pci-0000_00_1f.3.analog-stereo`. `wpctl status` shows the same list with the
  usual descriptions, so you can compare the two.

## Echo Cancellation

PipeWire's echo canceller (`module-echo-cancel`) uses the WebRTC audio processing library, the
same one web browsers use for calls. It adds two devices: a microphone that has the echo
removed, and speakers that feed what you hear to the canceller. The canceller can only remove
sound that it knows about, so **HayChat must play through those speakers and record from that
microphone**. Sound that other apps play straight to your speakers is not removed.

Check that your PipeWire has the WebRTC canceller (Fedora ships it in `pipewire-libs`):

```sh
ls /usr/lib*/spa-0.2/aec/ /usr/lib/*/spa-0.2/aec/ 2>/dev/null   # libspa-aec-webrtc.so
```

### Echo Cancellation for HayChat Only

Save this as `~/.config/pipewire/pipewire.conf.d/60-echo-cancel.conf` and restart PipeWire:

<!-- pipewire-docs-check: 60-echo-cancel.conf -->
```
# Echo cancellation: pick "Echo-cancelled microphone" and
# "Echo-cancelled speakers" in HayChat's Settings -> Voice.
context.modules = [
    {   name = libpipewire-module-echo-cancel
        args = {
            library.name = aec/libspa-aec-webrtc
            aec.args = {
                # WebRTC's own noise suppression (on unless set to false).
                webrtc.noise_suppression = true
                # Removes rumble below the voice range.
                webrtc.high_pass_filter = true
                # Automatic gain: leave it off, HayChat has its own input gain.
                webrtc.gain_control = false
            }
            source.props = {
                node.name = "echo-cancel-source"
                node.description = "Echo-cancelled microphone"
            }
            sink.props = {
                node.name = "echo-cancel-sink"
                node.description = "Echo-cancelled speakers"
            }
        }
    }
]
```

In HayChat, open **Settings → Voice** and choose:

- **Microphone:** Echo-cancelled microphone
- **Speakers:** Echo-cancelled speakers

Your system's default devices do not change, so other apps keep playing and recording as before.
The canceller records from your default microphone and plays to your default speakers. To tie it
to particular devices instead, add `target.object` with the device's name (from `wpctl status -n`)
to the capture and playback sides:

<!-- pipewire-docs-check: echo-cancel-targets -->
```
            capture.props = {
                target.object = "alsa_input.pci-0000_00_1f.3.analog-stereo"
            }
            playback.props = {
                target.object = "alsa_output.pci-0000_00_1f.3.analog-stereo"
            }
```

The `aec.args` options are the ones PipeWire reads for the WebRTC library
(`webrtc.noise_suppression` and `webrtc.high_pass_filter` are on unless you turn them off,
`webrtc.gain_control` is off unless you turn it on). PipeWire ignores options it does not know,
so check the spelling. With speakers, keep their volume moderate: very loud speakers close to the
microphone leave more echo than the canceller can remove.

### Automatic Echo Cancellation (Smart Filters)

WirePlumber 0.5 (`wireplumber --version`) can put the echo canceller in front of one particular
pair of speakers and microphone by itself. This is called a smart filter. HayChat then keeps
**System default** for both devices: while your laptop speakers are the default, its sound goes
through the canceller; when you switch the default to a headset, HayChat plays and records
straight through the headset and the canceller is left out. Every app that uses those speakers
and that microphone gets echo cancellation, not only HayChat.

Use this file **instead of** `60-echo-cancel.conf`, not with it. Replace the two device names
with yours from `wpctl status -n`: the speakers you want echo cancellation for under **Sinks**,
and the microphone next to them under **Sources**.

<!-- pipewire-docs-check: 60-echo-cancel-smart.conf -->
```
# Echo cancellation that WirePlumber puts in front of these speakers and
# this microphone by itself. Keep "System default" in HayChat.
context.modules = [
    {   name = libpipewire-module-echo-cancel
        args = {
            library.name = aec/libspa-aec-webrtc
            aec.args = {
                webrtc.noise_suppression = true
                webrtc.high_pass_filter = true
                webrtc.gain_control = false
            }
            source.props = {
                node.name = "echo-cancel-source"
                node.description = "Echo-cancelled microphone"
                filter.smart = true
                filter.smart.name = "echo-cancel-source"
                # Your microphone, from "wpctl status -n" (Sources).
                filter.smart.target = { node.name = "alsa_input.pci-0000_00_1f.3.analog-stereo" }
            }
            sink.props = {
                node.name = "echo-cancel-sink"
                node.description = "Echo-cancelled speakers"
                filter.smart = true
                filter.smart.name = "echo-cancel-sink"
                # Your speakers, from "wpctl status -n" (Sinks).
                filter.smart.target = { node.name = "alsa_output.pci-0000_00_1f.3.analog-stereo" }
            }
        }
    }
]
```

The name must match exactly. If the speakers' name changes (another profile in your desktop's
sound settings, for example), WirePlumber stops using the filter until you update the file.

## Noise Suppression

These remove steady and sudden background noise (fans, keyboards, traffic) from your microphone.
They add a new microphone that you pick in HayChat. The echo canceller above already does some
noise suppression; use one of these with a headset, or when you want stronger suppression.

Both plugins are separate projects that you download yourself. Put them in
`~/.local/lib/ladspa/`:

```sh
mkdir -p ~/.local/lib/ladspa
echo "$HOME"        # the start of the plugin path in the files below
```

PipeWire does not expand `~` or `$HOME` in these files, so the files below spell the path out:
replace `/home/YOUR_NAME` with what `echo "$HOME"` printed.

### RNNoise

[noise-suppression-for-voice](https://github.com/werman/noise-suppression-for-voice) (GPL-3.0)
wraps RNNoise, a small neural noise suppressor, as a plugin. It is light on the CPU. Download
`linux-rnnoise.zip` from its
[releases](https://github.com/werman/noise-suppression-for-voice/releases) (checked with v1.22)
and copy out the LADSPA plugin:

```sh
cd ~/Downloads
unzip -o linux-rnnoise.zip linux-rnnoise/ladspa/librnnoise_ladspa.so
cp linux-rnnoise/ladspa/librnnoise_ladspa.so ~/.local/lib/ladspa/
```

Save this as `~/.config/pipewire/pipewire.conf.d/61-rnnoise.conf` and restart PipeWire:

<!-- pipewire-docs-check: 61-rnnoise.conf -->
```
# RNNoise noise suppression: pick "Noise-suppressed microphone (RNNoise)"
# in HayChat's Settings -> Voice.
context.modules = [
    {   name = libpipewire-module-filter-chain
        args = {
            node.description = "Noise-suppressed microphone (RNNoise)"
            media.name = "Noise-suppressed microphone (RNNoise)"
            filter.graph = {
                nodes = [
                    {
                        type = ladspa
                        name = rnnoise
                        plugin = "/home/YOUR_NAME/.local/lib/ladspa/librnnoise_ladspa.so"
                        label = noise_suppressor_mono
                        control = {
                            "VAD Threshold (%)" = 50.0
                            "VAD Grace Period (ms)" = 200
                            "Retroactive VAD Grace (ms)" = 0
                        }
                    }
                ]
            }
            audio.rate = 48000
            audio.position = [ MONO ]
            capture.props = {
                node.name = "capture.rnnoise_source"
                node.passive = true
            }
            playback.props = {
                node.name = "rnnoise_source"
                media.class = Audio/Source
            }
        }
    }
]
```

In HayChat, choose **Microphone:** Noise-suppressed microphone (RNNoise). It records from your
default microphone.

The plugin has its own voice gate: it passes sound only while it is at least **VAD Threshold**
percent sure that you are speaking, and keeps it open for **VAD Grace Period** milliseconds after
you stop. If the start or end of your words is cut off, lower the threshold (0 turns this gate
off) before you change HayChat's voice activity threshold. **Retroactive VAD Grace** keeps the
start of words too, but adds that many milliseconds of delay; leave it at 0 for voice chat.

### DeepFilterNet

[DeepFilterNet](https://github.com/Rikorose/DeepFilterNet) (MIT or Apache-2.0) removes more
noise and sounds more natural than RNNoise, but uses noticeably more CPU and adds at least
20 ms of delay. Its last release, v0.5.6, is from 2023. Download
`libdeep_filter_ladspa-0.5.6-x86_64-unknown-linux-gnu.so` from its
[releases](https://github.com/Rikorose/DeepFilterNet/releases/tag/v0.5.6) and copy it:

```sh
cp ~/Downloads/libdeep_filter_ladspa-0.5.6-x86_64-unknown-linux-gnu.so \
	~/.local/lib/ladspa/libdeep_filter_ladspa.so
```

Save this as `~/.config/pipewire/pipewire.conf.d/61-deepfilter.conf` and restart PipeWire:

<!-- pipewire-docs-check: 61-deepfilter.conf -->
```
# DeepFilterNet noise suppression: pick "Noise-suppressed microphone
# (DeepFilterNet)" in HayChat's Settings -> Voice.
context.modules = [
    {   name = libpipewire-module-filter-chain
        args = {
            node.description = "Noise-suppressed microphone (DeepFilterNet)"
            media.name = "Noise-suppressed microphone (DeepFilterNet)"
            filter.graph = {
                nodes = [
                    {
                        type = ladspa
                        name = deepfilter
                        plugin = "/home/YOUR_NAME/.local/lib/ladspa/libdeep_filter_ladspa.so"
                        label = deep_filter_mono
                        control = {
                            # 100 means no limit; 18-24 removes a medium amount of
                            # noise, 6-12 a little.
                            "Attenuation Limit (dB)" = 100
                        }
                    }
                ]
            }
            audio.rate = 48000
            audio.position = [ MONO ]
            capture.props = {
                node.name = "capture.deepfilter_source"
                node.passive = true
            }
            playback.props = {
                node.name = "deepfilter_source"
                media.class = Audio/Source
            }
        }
    }
]
```

In HayChat, choose **Microphone:** Noise-suppressed microphone (DeepFilterNet).

### Noise Suppression for Every App

To have WirePlumber put the noise suppressor in front of your default microphone for every app,
make it a smart filter: add these two lines inside `playback.props`, after
`media.class = Audio/Source` (use `"deepfilter"` as the name in the DeepFilterNet file), and keep
**System default** in HayChat.

<!-- pipewire-docs-check: smart-noise-lines -->
```
                filter.smart = true
                filter.smart.name = "rnnoise"
```

### Noise Suppression After the Echo Canceller

With speakers and a noisy room, you can run RNNoise or DeepFilterNet on the echo-cancelled
microphone. Use `60-echo-cancel.conf` (not the smart one), set
`webrtc.noise_suppression = false` in it so that only one noise suppressor runs, and add this
line inside `capture.props` of the noise suppressor's file, after `node.passive = true`:

<!-- pipewire-docs-check: after-echo-cancel-line -->
```
                target.object = "echo-cancel-source"
```

In HayChat, choose the noise-suppressed microphone and **Echo-cancelled speakers**.

## EasyEffects

[EasyEffects](https://github.com/wwmm/easyeffects) (GPL-3.0) is an app that does the same
through a window with switches: its input effects include an echo canceller, noise reduction
(RNNoise) and a deep noise remover (DeepFilterNet). Install it with `sudo dnf install
easyeffects` on Fedora, or from [Flathub](https://flathub.org/apps/com.github.wwmm.easyeffects)
(`com.github.wwmm.easyeffects`) elsewhere. Its README warns not to make its own virtual devices
the system default, so leave HayChat on **System default** for the microphone. EasyEffects was
not part of the checks on this page.

## HayChat's Own Settings

- **Test microphone** in **Settings → Voice** encodes your microphone with the same codec as a
  call and plays it back, so you hear what the others will hear. After you add a filter, set the
  **voice activity threshold** again against the meter: noise suppression makes silence quieter,
  so a lower threshold usually works.
- **One noise suppressor:** turn **Noise suppression** in **Settings → Voice** off while you use
  RNNoise, DeepFilterNet or EasyEffects' noise reduction. With PipeWire's echo canceller's own
  noise suppression on (`webrtc.noise_suppression = true`), also turn HayChat's off, or set that
  option to `false` and keep HayChat's.
- **One echo canceller:** HayChat has its own (**Echo cancellation** in **Settings → Voice**,
  on by default, the same WebRTC canceller). While you use PipeWire's echo-cancelled devices,
  turn HayChat's off; or keep HayChat's and use your ordinary devices. HayChat's cancels only
  what HayChat plays; PipeWire's cancels every app played through the echo-cancelled speakers.
- **Gain:** leave `webrtc.gain_control` off. Automatic gain changes your level while you talk,
  which moves it against HayChat's voice activity threshold; use HayChat's **input gain**
  instead.
- **Only listed microphones:** HayChat lists PipeWire's sources (`media.class = Audio/Source`).
  A source made with `Audio/Source/Virtual` does not appear in **Settings → Voice**; use it
  through **System default**, or change its class to `Audio/Source`.

## When It Does Not Work

- **The new device is not in Settings → Voice:** close and open Settings → Voice again. Check
  `wpctl status` for the device. If it is missing, `journalctl --user -u pipewire -b | grep -i
  'error\|ladspa\|echo'` shows why, often a wrong plugin path.
- **The others still hear an echo:** both of HayChat's devices must be the echo-cancelled ones
  (or System default with the smart filter while those speakers are the default). Turn the
  speakers down a little and move them away from the microphone.
- **No sound at all after a change:** a mistake in a file can stop PipeWire. Delete the file and
  restart PipeWire (see [Before You Start](#before-you-start)).
- **Choppy or robotic voice after adding DeepFilterNet:** your CPU may be too slow for it; use
  RNNoise.

## What Was Checked

`dev/pipewire-docs-check.sh` takes every configuration block on this page (the ones under a
`pipewire-docs-check` comment in the source of this page) and loads it into a private PipeWire
1.6.11 and WirePlumber 0.5.19 in a throwaway Fedora 45 container, with ALSA's `null` device as
stand-in speakers, headset and microphones. It downloads the two plugins (RNNoise v1.22,
DeepFilterNet v0.5.6) and checks their files against pinned SHA-256 sums. For each file it
checks that PipeWire starts with it, that the new devices appear under the names on this page in
SDL (the audio library HayChat uses), that the plugin controls named here exist, and that a
stream opened the way HayChat opens one is linked through the filter: to the echo-cancelled
devices, through the smart filter while the stand-in speakers are the default and around it
while the headset is, through each noise suppressor, and through RNNoise after the echo
canceller.

It does not check how much echo or noise is actually removed, the sound quality, the delay or
the CPU cost on real speakers and microphones, other distributions, or EasyEffects. The option
names and defaults of `aec.args` come from PipeWire 1.6.11's source
(`spa/plugins/aec/aec-webrtc.cpp`); PipeWire does not report options it ignores.

The check never touches the host's sound: it needs only podman. Run it after changing a block
on this page:

```sh
dev/pipewire-docs-check.sh
```

## Sources

- PipeWire [echo-cancel module](https://docs.pipewire.org/page_module_echo_cancel.html) and
  [filter-chain module](https://docs.pipewire.org/page_module_filter_chain.html)
- WirePlumber [smart filters](https://pipewire.pages.freedesktop.org/wireplumber/policies/smart_filters.html),
  and Collabora's [introduction to them](https://www.collabora.com/news-and-blog/blog/2024/06/26/smart-audio-filters-with-wireplumber-0.5)
- [noise-suppression-for-voice](https://github.com/werman/noise-suppression-for-voice) (RNNoise
  plugin) and [DeepFilterNet's LADSPA plugin](https://github.com/Rikorose/DeepFilterNet/tree/main/ladspa)
- [EasyEffects](https://github.com/wwmm/easyeffects)
