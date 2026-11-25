/*
 * haychat_webrtc_apm: a minimal C API over webrtc-audio-processing 2.x (WebRTC's audio
 * processing module: AEC3 echo cancellation, noise suppression and the high-pass filter), for
 * HayChat's voice engine (#171). The library itself is C++ only, so HayChat ships this small
 * wrapper and loads it at runtime (client/webrtcapm), like libopus and RNNoise.
 *
 * Audio is 48 kHz mono float in [-1, 1], in 10 ms frames of HAYCHAT_APM_FRAME_SAMPLES samples.
 * Render (far-end, what is played) and capture (near-end, the microphone) frames must be fed
 * from the same thread or under one lock; nothing here locks.
 *
 * Copyright (c) 2026 the HayChat authors. Same licence as HayChat (see LICENSE).
 */
#ifndef HAYCHAT_WEBRTC_APM_H
#define HAYCHAT_WEBRTC_APM_H

#include <stdint.h>

#ifdef _WIN32
#define HAYCHAT_APM_EXPORT __declspec(dllexport)
#else
#define HAYCHAT_APM_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* Bumped on any change to the functions or structs below; the client refuses another. */
#define HAYCHAT_APM_ABI_VERSION 1
#define HAYCHAT_APM_SAMPLE_RATE 48000
#define HAYCHAT_APM_FRAME_SAMPLES 480

typedef struct HaychatApm HaychatApm;

typedef struct HaychatApmConfig {
	/* AEC3 echo cancellation (with its high-pass filter). */
	int32_t echoCancellation;
	/* WebRTC noise suppression, at noiseLevel: 0 low, 1 moderate, 2 high, 3 very high. */
	int32_t noiseSuppression;
	int32_t noiseLevel;
	/* The high-pass filter on its own (AEC3 turns it on regardless). */
	int32_t highPassFilter;
} HaychatApmConfig;

/* AudioProcessingStats; each has* says whether the value is set. */
typedef struct HaychatApmStats {
	int32_t hasEchoReturnLoss;
	int32_t hasEchoReturnLossEnhancement;
	int32_t hasDivergentFilterFraction;
	int32_t hasDelayMedian;
	int32_t hasDelay;
	int32_t hasResidualEchoLikelihood;
	/* ERL and ERLE in dB. */
	double echoReturnLoss;
	double echoReturnLossEnhancement;
	double divergentFilterFraction;
	double residualEchoLikelihood;
	int32_t delayMedianMS;
	int32_t delayStandardDeviationMS;
	/* AEC3's instantaneous delay estimate. */
	int32_t delayMS;
	int32_t reserved;
} HaychatApmStats;

HAYCHAT_APM_EXPORT int32_t haychat_apm_abi_version(void);
/* The webrtc-audio-processing version the wrapper was built against, e.g. "2.1". */
HAYCHAT_APM_EXPORT const char *haychat_apm_built_version(void);
/* NULL when the module cannot be created. */
HAYCHAT_APM_EXPORT HaychatApm *haychat_apm_create(const HaychatApmConfig *config);
HAYCHAT_APM_EXPORT void haychat_apm_destroy(HaychatApm *apm);
HAYCHAT_APM_EXPORT int32_t haychat_apm_apply_config(HaychatApm *apm,
	const HaychatApmConfig *config);
/* Resets the processing state (keeps the configuration). */
HAYCHAT_APM_EXPORT int32_t haychat_apm_reset(HaychatApm *apm);
/* Feeds one 10 ms render frame (unchanged). Returns 0 or a negative APM error. */
HAYCHAT_APM_EXPORT int32_t haychat_apm_process_render(HaychatApm *apm, const float *samples);
/* Processes one 10 ms capture frame in place. Returns 0 or a negative APM error. */
HAYCHAT_APM_EXPORT int32_t haychat_apm_process_capture(HaychatApm *apm, float *samples);
/* The delay hint: ms between a render frame being fed and its echo being captured. */
HAYCHAT_APM_EXPORT int32_t haychat_apm_set_stream_delay_ms(HaychatApm *apm, int32_t delayMS);
HAYCHAT_APM_EXPORT int32_t haychat_apm_get_stats(HaychatApm *apm, HaychatApmStats *stats);

#ifdef __cplusplus
}
#endif

#endif
