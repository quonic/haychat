#!/usr/bin/env bash
set -euo pipefail

# Checks the PipeWire configuration blocks in docs/voice-linux-audio.md (#173) in a throwaway
# container: a private PipeWire and WirePlumber with ALSA's null device as stand-in speakers,
# headset and microphones, never the host's sound server. Every block under a
# `<!-- pipewire-docs-check: NAME -->` comment is loaded, and a small SDL3 program opens
# streams the way the client does, to check the device names HayChat lists and the links the
# filters make. It checks configuration and routing only, not how much echo or noise is
# removed.
#
# Usage: dev/pipewire-docs-check.sh   (needs podman and network access for the image, the
#                                      packages and the two plugin downloads)
#
# Environment:
#   HAYCHAT_PIPEWIRE_CHECK_IMAGE   container image (default registry.fedoraproject.org/fedora:45)

IMAGE=${HAYCHAT_PIPEWIRE_CHECK_IMAGE:-registry.fedoraproject.org/fedora:45}
DOC_NAME=voice-linux-audio.md

# Plugins the page names, pinned by version and SHA-256.
RNNOISE_URL=https://github.com/werman/noise-suppression-for-voice/releases/download
RNNOISE_URL+=/v1.22/linux-rnnoise.zip
RNNOISE_SHA256=df97df45a4ce81709ec20db75d3f771e4fcad33c5b863d1c29a87e9a49f186aa
DEEPFILTER_URL=https://github.com/Rikorose/DeepFilterNet/releases/download
DEEPFILTER_URL+=/v0.5.6/libdeep_filter_ladspa-0.5.6-x86_64-unknown-linux-gnu.so
DEEPFILTER_SHA256=2ca3205c2911d389604a826a240e745597d50252b5cab81c8248252b335e2236

# Every block the page marks; a marker missing from this list, or a listed one missing from the
# page, fails the check so that a new block gets a scenario below.
EXPECTED_BLOCKS=(
	60-echo-cancel.conf
	echo-cancel-targets
	60-echo-cancel-smart.conf
	61-rnnoise.conf
	61-deepfilter.conf
	smart-noise-lines
	after-echo-cancel-line
)

# The page's example device names, replaced by the stand-in devices.
EXAMPLE_SPEAKERS=alsa_output.pci-0000_00_1f.3.analog-stereo
EXAMPLE_MICROPHONE=alsa_input.pci-0000_00_1f.3.analog-stereo

runHost() {
	local repoDir
	repoDir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
	if ! command -v podman >/dev/null; then
		echo "pipewire-docs-check: podman is required" >&2
		exit 1
	fi
	# SELinux labelling is disabled rather than relabelling the files with :z, as in dev.sh.
	exec podman run --rm --init --security-opt label=disable \
		-v "$repoDir/docs/$DOC_NAME:/check/$DOC_NAME:ro" \
		-v "$repoDir/dev/pipewire-docs-check.sh:/check/pipewire-docs-check.sh:ro" \
		"$IMAGE" bash /check/pipewire-docs-check.sh --in-container
}

# ---------------------------------------------------------------------------------------------
# Everything below runs inside the container, as root, with its own runtime and config dirs.

WORK=/work
BLOCKS=$WORK/blocks
LOGS=$WORK/logs
CONF_DIR=$WORK/config/pipewire/pipewire.conf.d
failures=0
scenario=""

log() {
	echo "==> $*"
}

fail() {
	echo "FAIL [$scenario]: $*" >&2
	failures=$((failures + 1))
}

pass() {
	echo "  ok: $*"
}

installTools() {
	log "installing PipeWire, WirePlumber and the SDL3 probe's build tools"
	mkdir -p "$WORK"
	if ! dnf install -y -q --setopt=install_weak_deps=False pipewire wireplumber \
		pipewire-utils alsa-lib dbus-daemon gcc SDL3-devel jq unzip procps-ng curl \
		>"$WORK/dnf.log" 2>&1; then
		cat "$WORK/dnf.log" >&2
		exit 1
	fi
	echo "  $(pipewire --version | tail -1), $(wireplumber --version | tail -1)"
	echo "  SDL3 $(pkg-config --modversion sdl3)"
}

installPlugins() {
	log "downloading the RNNoise and DeepFilterNet plugins"
	mkdir -p "$WORK/download" "$HOME/.local/lib/ladspa"
	curl -sSfL -o "$WORK/download/linux-rnnoise.zip" "$RNNOISE_URL"
	curl -sSfL -o "$WORK/download/libdeep_filter_ladspa.so" "$DEEPFILTER_URL"
	(
		cd "$WORK/download"
		printf '%s  %s\n' "$RNNOISE_SHA256" linux-rnnoise.zip \
			"$DEEPFILTER_SHA256" libdeep_filter_ladspa.so | sha256sum -c --quiet
		# The page's commands: the LADSPA plugin out of the zip, both into ~/.local/lib/ladspa.
		unzip -oq linux-rnnoise.zip linux-rnnoise/ladspa/librnnoise_ladspa.so
	)
	cp "$WORK/download/linux-rnnoise/ladspa/librnnoise_ladspa.so" "$HOME/.local/lib/ladspa/"
	cp "$WORK/download/libdeep_filter_ladspa.so" "$HOME/.local/lib/ladspa/"
}

# A small SDL3 program that lists devices by the names SDL_GetAudioDeviceName gives, as the
# client's Settings -> Voice does, or opens a playback and a recording stream (by name or the
# system default) with the client's "Communication" stream role.
buildProbe() {
	log "building the SDL3 probe"
	cat >"$WORK/sdlprobe.c" <<'EOF'
#include <SDL3/SDL.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static SDL_AudioDeviceID findDevice(const char *name, int recording) {
	if (strcmp(name, "default") == 0) {
		return recording ? SDL_AUDIO_DEVICE_DEFAULT_RECORDING : SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK;
	}
	int count = 0;
	SDL_AudioDeviceID *ids = recording ? SDL_GetAudioRecordingDevices(&count)
		: SDL_GetAudioPlaybackDevices(&count);
	SDL_AudioDeviceID found = 0;
	for (int index = 0; ids != NULL && index < count; index++) {
		const char *deviceName = SDL_GetAudioDeviceName(ids[index]);
		if (deviceName != NULL && strcmp(deviceName, name) == 0) {
			found = ids[index];
		}
	}
	SDL_free(ids);
	return found;
}

int main(int argc, char **argv) {
	SDL_SetHint(SDL_HINT_AUDIO_DEVICE_STREAM_ROLE, "Communication");
	SDL_SetHint(SDL_HINT_APP_NAME, "sdlprobe");
	if (!SDL_Init(SDL_INIT_AUDIO)) {
		fprintf(stderr, "SDL_Init: %s\n", SDL_GetError());
		return 1;
	}
	if (argc == 2 && strcmp(argv[1], "list") == 0) {
		for (int recording = 0; recording < 2; recording++) {
			int count = 0;
			SDL_AudioDeviceID *ids = recording ? SDL_GetAudioRecordingDevices(&count)
				: SDL_GetAudioPlaybackDevices(&count);
			for (int index = 0; ids != NULL && index < count; index++) {
				printf("%s: %s\n", recording ? "recording" : "playback",
					SDL_GetAudioDeviceName(ids[index]));
			}
			SDL_free(ids);
		}
		SDL_Quit();
		return 0;
	}
	if (argc != 5 || strcmp(argv[1], "open") != 0) {
		fprintf(stderr, "usage: sdlprobe list | open PLAYBACK RECORDING SECONDS\n");
		return 2;
	}
	SDL_AudioSpec spec = {SDL_AUDIO_F32, 1, 48000};
	SDL_AudioDeviceID playbackID = findDevice(argv[2], 0);
	SDL_AudioDeviceID recordingID = findDevice(argv[3], 1);
	if (playbackID == 0 || recordingID == 0) {
		fprintf(stderr, "sdlprobe: device not found\n");
		return 1;
	}
	SDL_AudioStream *playback = SDL_OpenAudioDeviceStream(playbackID, &spec, NULL, NULL);
	SDL_AudioStream *recording = SDL_OpenAudioDeviceStream(recordingID, &spec, NULL, NULL);
	if (playback == NULL || recording == NULL) {
		fprintf(stderr, "sdlprobe: open: %s\n", SDL_GetError());
		return 1;
	}
	SDL_ResumeAudioStreamDevice(playback);
	SDL_ResumeAudioStreamDevice(recording);
	static float silence[960];
	static float input[960];
	int seconds = atoi(argv[4]);
	for (int tick = 0; tick < seconds * 50; tick++) {
		SDL_PutAudioStreamData(playback, silence, sizeof silence);
		SDL_GetAudioStreamData(recording, input, sizeof input);
		SDL_Delay(20);
	}
	SDL_DestroyAudioStream(playback);
	SDL_DestroyAudioStream(recording);
	SDL_Quit();
	return 0;
}
EOF
	# shellcheck disable=SC2046 # pkg-config prints separate flags
	gcc -O1 -Wall -Werror -o /usr/local/bin/sdlprobe "$WORK/sdlprobe.c" \
		$(pkg-config --cflags --libs sdl3)
}

# Writes each marked fenced block of the page to $BLOCKS/NAME.
extractBlocks() {
	log "extracting the marked blocks from docs/$DOC_NAME"
	mkdir -p "$BLOCKS"
	awk -v dir="$BLOCKS" '
		/^<!-- pipewire-docs-check: [A-Za-z0-9._-]+ -->$/ {
			name = $3
			if (getline line <= 0 || line !~ /^```/) {
				print "marker " name " is not followed by a fenced block" > "/dev/stderr"
				exit 1
			}
			out = dir "/" name
			printf "" > out
			while ((getline line) > 0 && line !~ /^```/) {
				print line > out
			}
			close(out)
		}
	' "/check/$DOC_NAME"
	local name found
	for name in "${EXPECTED_BLOCKS[@]}"; do
		if [[ ! -s $BLOCKS/$name ]]; then
			echo "pipewire-docs-check: block $name is missing from the page" >&2
			exit 1
		fi
	done
	for found in "$BLOCKS"/*; do
		name=$(basename "$found")
		if [[ " ${EXPECTED_BLOCKS[*]} " != *" $name "* ]]; then
			echo "pipewire-docs-check: block $name has no scenario in this script" >&2
			exit 1
		fi
	done
	echo "  ${#EXPECTED_BLOCKS[@]} blocks"
}

# Prints a block with the page's placeholders replaced: the plugin path's home directory and
# the example device names (speakers and microphone, or with "headset" the headset's).
localBlock() {
	local name=$1 speakers=test-speakers microphone=test-mic
	if [[ ${2:-} == headset ]]; then
		speakers=test-headset
		microphone=test-headset-mic
	fi
	sed -e "s#/home/YOUR_NAME#$HOME#g" -e "s#$EXAMPLE_SPEAKERS#$speakers#g" \
		-e "s#$EXAMPLE_MICROPHONE#$microphone#g" "$BLOCKS/$name"
}

# Prints FILE with SNIPPET inserted after the first line whose trimmed text is LINE, as the page
# tells the reader to; fails when the line is not there.
insertAfter() {
	local file=$1 line=$2 snippet=$3
	if ! awk -v line="$line" -v snippetFile="$snippet" '
		{ print }
		!done {
			trimmed = $0
			gsub(/^[ \t]+|[ \t]+$/, "", trimmed)
			if (trimmed == line) {
				while ((getline extra < snippetFile) > 0) print extra
				done = 1
			}
		}
		END { exit done ? 0 : 1 }
	' "$file"; then
		echo "pipewire-docs-check: no line '$line' in $file" >&2
		return 1
	fi
}

# Stand-in hardware: ALSA's null PCM as two playback and two capture devices, plain
# Audio/Sink and Audio/Source nodes without a link group, like real sound cards.
writeTestDevices() {
	local factory name description class priority
	{
		echo "context.objects = ["
		while read -r factory name description class priority; do
			cat <<EOF
    {   factory = adapter
        args = {
            factory.name = $factory
            api.alsa.path = "null"
            node.name = "$name"
            node.description = "${description//_/ }"
            media.class = $class
            audio.rate = 48000
            priority.session = $priority
            object.linger = true
        }
    }
EOF
		done <<'EOF'
api.alsa.pcm.sink test-speakers Test_speakers Audio/Sink 2000
api.alsa.pcm.sink test-headset Test_headset Audio/Sink 1000
api.alsa.pcm.source test-mic Test_microphone Audio/Source 2000
api.alsa.pcm.source test-headset-mic Test_headset_microphone Audio/Source 1000
EOF
		echo "]"
	} >"$CONF_DIR/10-test-devices.conf"
}

stopAudio() {
	pkill -x sdlprobe 2>/dev/null || true
	pkill -x wireplumber 2>/dev/null || true
	pkill -x pipewire 2>/dev/null || true
	local tries=0
	while pgrep -x 'pipewire|wireplumber' >/dev/null && ((tries < 50)); do
		sleep 0.1
		tries=$((tries + 1))
	done
}

nodeID() {
	pw-dump | jq -r --arg name "$1" \
		'.[] | select(.type == "PipeWire:Interface:Node")
			| select(.info.props["node.name"] == $name) | .id'
}

# Starts PipeWire and WirePlumber with the stand-in devices and the given drop-in files
# (pairs of FILE NAME: the content's path and the name it gets in pipewire.conf.d).
startAudio() {
	stopAudio
	rm -rf "$XDG_CONFIG_HOME" "$XDG_STATE_HOME"
	mkdir -p "$CONF_DIR" "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR" "$LOGS"
	chmod 700 "$XDG_RUNTIME_DIR"
	writeTestDevices
	while (($# > 0)); do
		cp "$1" "$CONF_DIR/$2"
		shift 2
	done
	if [[ ! -S $XDG_RUNTIME_DIR/bus ]]; then
		dbus-daemon --session --fork --address="$DBUS_SESSION_BUS_ADDRESS"
	fi
	local logName=${scenario// /-}
	pipewire >"$LOGS/$logName.pipewire.log" 2>&1 &
	local tries=0
	until pw-cli info 0 >/dev/null 2>&1; do
		if ((tries >= 50)) || ! pgrep -x pipewire >/dev/null; then
			fail "PipeWire did not start with these files"
			tail -20 "$LOGS/$logName.pipewire.log" >&2
			return 1
		fi
		sleep 0.1
		tries=$((tries + 1))
	done
	wireplumber >"$LOGS/$logName.wireplumber.log" 2>&1 &
	tries=0
	until [[ -n $(nodeID test-mic) ]] &&
		pw-metadata -n default 0 default.audio.source | grep -q "key:'default.audio.source'"; do
		if ((tries >= 100)); then
			fail "WirePlumber did not pick a default source"
			return 1
		fi
		sleep 0.1
		tries=$((tries + 1))
	done
	# Errors other than the missing realtime support of a container mean a bad file.
	if grep -E '^E ' "$LOGS/$logName.pipewire.log" | grep -v 'mod\.rt' >&2; then
		fail "PipeWire logged errors"
		return 1
	fi
	pass "PipeWire and WirePlumber started"
}

setDefaults() {
	wpctl set-default "$(nodeID "$1")"
	wpctl set-default "$(nodeID "$2")"
	local tries=0
	until pw-metadata -n default 0 default.audio.sink | grep -q "\"$1\"" &&
		pw-metadata -n default 0 default.audio.source | grep -q "\"$2\""; do
		if ((tries >= 50)); then
			fail "default devices did not change to $1 and $2"
			return 1
		fi
		sleep 0.1
		tries=$((tries + 1))
	done
}

expectDefaults() {
	if pw-metadata -n default 0 default.audio.sink | grep -q "\"$1\"" &&
		pw-metadata -n default 0 default.audio.source | grep -q "\"$2\""; then
		pass "the defaults are still $1 and $2"
	else
		fail "the defaults changed from $1 and $2"
	fi
}

nodeExists() {
	if [[ -n $(nodeID "$1") ]]; then
		pass "node $1"
	else
		fail "no node $1"
	fi
}

# expectSDLDevice playback|recording NAME
expectSDLDevice() {
	if sdlprobe list | grep -qxF "$1: $2"; then
		pass "SDL lists $1 device \"$2\""
	else
		fail "SDL does not list $1 device \"$2\""
		sdlprobe list >&2 || true
	fi
}

# Prints "OUTPUT -> INPUT" per pair of linked nodes, by node name.
links() {
	pw-dump | jq -r '
		(map(select(.type == "PipeWire:Interface:Node")
			| {key: (.id | tostring), value: .info.props["node.name"]}) | from_entries) as $names
		| .[] | select(.type == "PipeWire:Interface:Link")
		| "\($names[.info["output-node-id"] | tostring]) -> \($names[.info["input-node-id"] | tostring])"
	' | sort -u
}

# expectLinks PLAYBACK RECORDING LINK... [! LINK...]: opens SDL streams on the two devices
# (names or "default") and checks that each LINK ("out -> in") appears, and that the links
# after "!" do not.
expectLinks() {
	local playback=$1 recording=$2
	shift 2
	local want=() unwanted=() negate=0 link
	for link in "$@"; do
		if [[ $link == "!" ]]; then
			negate=1
		elif ((negate)); then
			unwanted+=("$link")
		else
			want+=("$link")
		fi
	done
	timeout -s KILL 30 sdlprobe open "$playback" "$recording" 25 >/dev/null &
	local probe=$! tries=0 current missing before=$failures
	while :; do
		current=$(links)
		missing=0
		for link in "${want[@]}"; do
			grep -qxF "$link" <<<"$current" || missing=1
		done
		if ((missing == 0)) || ((tries >= 100)); then
			break
		fi
		sleep 0.1
		tries=$((tries + 1))
	done
	# Let the session manager settle before looking for links that must not be there.
	sleep 0.5
	current=$(links)
	for link in "${want[@]}"; do
		if grep -qxF "$link" <<<"$current"; then
			pass "$link"
		else
			fail "missing link $link"
		fi
	done
	for link in "${unwanted[@]}"; do
		if grep -qxF "$link" <<<"$current"; then
			fail "unexpected link $link"
		else
			pass "no $link"
		fi
	done
	if ((failures > before)); then
		echo "  links now:" >&2
		while read -r link; do
			echo "    $link"
		done <<<"$current" >&2
	fi
	pkill -9 -x sdlprobe 2>/dev/null || true
	wait "$probe" 2>/dev/null || true
}

# expectControls NODE BLOCK: every control the block sets exists on the filter's capture node.
expectControls() {
	local node=$1 block=$2 pluginName control names
	pluginName=$(awk '/type = ladspa/ { found = 1 } found && /name = / { print $3; exit }' \
		"$BLOCKS/$block")
	names=$(pw-dump | jq -r --arg name "$node" \
		'.[] | select(.info.props["node.name"]? == $name) | .info.params.PropInfo[]?.name // empty')
	while read -r control; do
		if grep -qxF "$pluginName:$control" <<<"$names"; then
			pass "control \"$control\""
		else
			fail "the plugin has no control \"$control\""
		fi
	done < <(sed -n 's/^ *"\([^"]*\)" = .*/\1/p' "$BLOCKS/$block")
}

runScenarios() {
	local tmp=$WORK/variants
	mkdir -p "$tmp"

	scenario="echo cancellation for HayChat"
	log "$scenario (60-echo-cancel.conf)"
	localBlock 60-echo-cancel.conf >"$tmp/echo.conf"
	if startAudio "$tmp/echo.conf" 60-echo-cancel.conf; then
		expectDefaults test-speakers test-mic
		nodeExists echo-cancel-source
		nodeExists echo-cancel-sink
		expectSDLDevice playback "Echo-cancelled speakers"
		expectSDLDevice recording "Echo-cancelled microphone"
		expectLinks "Echo-cancelled speakers" "Echo-cancelled microphone" \
			"sdlprobe -> echo-cancel-sink" "echo-cancel-playback -> test-speakers" \
			"test-mic -> echo-cancel-capture" "echo-cancel-source -> sdlprobe"
	fi

	scenario="echo cancellation tied to devices"
	log "$scenario (60-echo-cancel.conf with the target.object lines)"
	localBlock echo-cancel-targets headset >"$tmp/targets"
	# The page puts the two blocks into the module's args, next to source.props.
	awk -v snippetFile="$tmp/targets" '
		/^            source\.props = \{$/ && !done {
			while ((getline extra < snippetFile) > 0) print extra
			done = 1
		}
		{ print }
	' "$tmp/echo.conf" >"$tmp/echo-targets.conf"
	if startAudio "$tmp/echo-targets.conf" 60-echo-cancel.conf; then
		expectLinks "Echo-cancelled speakers" "Echo-cancelled microphone" \
			"echo-cancel-playback -> test-headset" "test-headset-mic -> echo-cancel-capture" \
			! "echo-cancel-playback -> test-speakers" "test-mic -> echo-cancel-capture"
	fi

	scenario="smart echo cancellation, speakers"
	log "$scenario (60-echo-cancel-smart.conf, System default in HayChat)"
	localBlock 60-echo-cancel-smart.conf >"$tmp/echo-smart.conf"
	if startAudio "$tmp/echo-smart.conf" 60-echo-cancel-smart.conf; then
		setDefaults test-speakers test-mic
		expectLinks default default \
			"sdlprobe -> echo-cancel-sink" "echo-cancel-playback -> test-speakers" \
			"test-mic -> echo-cancel-capture" "echo-cancel-source -> sdlprobe" \
			! "sdlprobe -> test-speakers" "test-mic -> sdlprobe"

		scenario="smart echo cancellation, headset"
		log "$scenario (the default switched to the headset)"
		setDefaults test-headset test-headset-mic
		expectLinks default default \
			"sdlprobe -> test-headset" "test-headset-mic -> sdlprobe" \
			! "sdlprobe -> echo-cancel-sink" "echo-cancel-source -> sdlprobe"
	fi

	scenario="RNNoise"
	log "$scenario (61-rnnoise.conf)"
	localBlock 61-rnnoise.conf >"$tmp/rnnoise.conf"
	if startAudio "$tmp/rnnoise.conf" 61-rnnoise.conf; then
		nodeExists rnnoise_source
		expectControls capture.rnnoise_source 61-rnnoise.conf
		expectSDLDevice recording "Noise-suppressed microphone (RNNoise)"
		expectLinks default "Noise-suppressed microphone (RNNoise)" \
			"test-mic -> capture.rnnoise_source" "rnnoise_source -> sdlprobe"
	fi

	scenario="DeepFilterNet"
	log "$scenario (61-deepfilter.conf)"
	localBlock 61-deepfilter.conf >"$tmp/deepfilter.conf"
	if startAudio "$tmp/deepfilter.conf" 61-deepfilter.conf; then
		nodeExists deepfilter_source
		expectControls capture.deepfilter_source 61-deepfilter.conf
		expectSDLDevice recording "Noise-suppressed microphone (DeepFilterNet)"
		expectLinks default "Noise-suppressed microphone (DeepFilterNet)" \
			"test-mic -> capture.deepfilter_source" "deepfilter_source -> sdlprobe"
	fi

	scenario="RNNoise for every app"
	log "$scenario (61-rnnoise.conf with the smart filter lines, System default in HayChat)"
	localBlock smart-noise-lines >"$tmp/smart-lines"
	if insertAfter "$tmp/rnnoise.conf" "media.class = Audio/Source" "$tmp/smart-lines" \
		>"$tmp/rnnoise-smart.conf" &&
		startAudio "$tmp/rnnoise-smart.conf" 61-rnnoise.conf; then
		setDefaults test-headset test-headset-mic
		expectLinks default default \
			"test-headset-mic -> capture.rnnoise_source" "rnnoise_source -> sdlprobe" \
			! "test-headset-mic -> sdlprobe"
	fi

	scenario="RNNoise after the echo canceller"
	log "$scenario (60-echo-cancel.conf without WebRTC noise suppression, 61-rnnoise.conf)"
	localBlock after-echo-cancel-line >"$tmp/after-line"
	sed 's/webrtc\.noise_suppression = true/webrtc.noise_suppression = false/' \
		"$tmp/echo.conf" >"$tmp/echo-no-ns.conf"
	if ! grep -q 'webrtc.noise_suppression = false' "$tmp/echo-no-ns.conf"; then
		fail "60-echo-cancel.conf has no webrtc.noise_suppression line to turn off"
	elif insertAfter "$tmp/rnnoise.conf" "node.passive = true" "$tmp/after-line" \
		>"$tmp/rnnoise-after.conf" &&
		startAudio "$tmp/echo-no-ns.conf" 60-echo-cancel.conf \
			"$tmp/rnnoise-after.conf" 61-rnnoise.conf; then
		expectLinks "Echo-cancelled speakers" "Noise-suppressed microphone (RNNoise)" \
			"test-mic -> echo-cancel-capture" "echo-cancel-source -> capture.rnnoise_source" \
			"rnnoise_source -> sdlprobe" "sdlprobe -> echo-cancel-sink" \
			"echo-cancel-playback -> test-speakers" ! "test-mic -> capture.rnnoise_source"
	fi
	scenario=""
	stopAudio
}

runContainer() {
	# Only here: on the host these would point podman at the container's directories.
	export HOME=/root
	export XDG_RUNTIME_DIR=$WORK/run
	export XDG_CONFIG_HOME=$WORK/config
	export XDG_STATE_HOME=$WORK/state
	export DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus
	export SDL_AUDIO_DRIVER=pipewire
	installTools
	installPlugins
	buildProbe
	extractBlocks
	runScenarios
	if ((failures > 0)); then
		echo "pipewire-docs-check: $failures check(s) failed" >&2
		exit 1
	fi
	log "every block on the page loads and routes as described"
}

if [[ ${1:-} == --in-container ]]; then
	runContainer
else
	runHost
fi
