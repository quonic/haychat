/*
 * haychat_webrtc_apm: see haychat_webrtc_apm.h. Built by deploy/build-linux-webrtc-apm.sh
 * (against the system's webrtc-audio-processing-2) and deploy/build-windows-webrtc-apm.sh
 * (against a pinned source build, linked statically into the DLL).
 *
 * Copyright (c) 2026 the HayChat authors. Same licence as HayChat (see LICENSE).
 */
#include "haychat_webrtc_apm.h"

#include <new>

#include "api/audio/audio_processing.h"
#include "api/scoped_refptr.h"

#ifndef HAYCHAT_APM_BUILT_VERSION
#define HAYCHAT_APM_BUILT_VERSION "2.x"
#endif

// The layouts client/webrtcapm mirrors.
static_assert(sizeof(HaychatApmConfig) == 16, "HaychatApmConfig layout");
static_assert(sizeof(HaychatApmStats) == 72, "HaychatApmStats layout");

struct HaychatApm {
	webrtc::scoped_refptr<webrtc::AudioProcessing> apm;
	webrtc::StreamConfig stream{HAYCHAT_APM_SAMPLE_RATE, 1};
};

namespace {

webrtc::AudioProcessing::Config makeConfig(const HaychatApmConfig *in) {
	webrtc::AudioProcessing::Config config;
	config.pipeline.maximum_internal_processing_rate = HAYCHAT_APM_SAMPLE_RATE;
	config.pipeline.multi_channel_render = false;
	config.pipeline.multi_channel_capture = false;
	config.echo_canceller.enabled = in->echoCancellation != 0;
	config.echo_canceller.mobile_mode = false;
	config.noise_suppression.enabled = in->noiseSuppression != 0;
	switch (in->noiseLevel) {
	case 0:
		config.noise_suppression.level = webrtc::AudioProcessing::Config::NoiseSuppression::kLow;
		break;
	case 1:
		config.noise_suppression.level =
			webrtc::AudioProcessing::Config::NoiseSuppression::kModerate;
		break;
	case 3:
		config.noise_suppression.level =
			webrtc::AudioProcessing::Config::NoiseSuppression::kVeryHigh;
		break;
	default:
		config.noise_suppression.level = webrtc::AudioProcessing::Config::NoiseSuppression::kHigh;
		break;
	}
	config.high_pass_filter.enabled = in->highPassFilter != 0;
	// HayChat has its own input gain: no automatic gain control, no pre-amplifier.
	config.gain_controller1.enabled = false;
	config.gain_controller2.enabled = false;
	config.pre_amplifier.enabled = false;
	config.capture_level_adjustment.enabled = false;
	return config;
}

} // namespace

extern "C" {

int32_t haychat_apm_abi_version(void) {
	return HAYCHAT_APM_ABI_VERSION;
}

const char *haychat_apm_built_version(void) {
	return HAYCHAT_APM_BUILT_VERSION;
}

HaychatApm *haychat_apm_create(const HaychatApmConfig *config) {
	if (config == nullptr) {
		return nullptr;
	}
	HaychatApm *handle = new (std::nothrow) HaychatApm();
	if (handle == nullptr) {
		return nullptr;
	}
	webrtc::AudioProcessingBuilder builder;
	builder.SetConfig(makeConfig(config));
	handle->apm = builder.Create();
	if (!handle->apm) {
		delete handle;
		return nullptr;
	}
	webrtc::ProcessingConfig processing;
	processing.input_stream() = handle->stream;
	processing.output_stream() = handle->stream;
	processing.reverse_input_stream() = handle->stream;
	processing.reverse_output_stream() = handle->stream;
	if (handle->apm->Initialize(processing) != webrtc::AudioProcessing::kNoError) {
		delete handle;
		return nullptr;
	}
	return handle;
}

void haychat_apm_destroy(HaychatApm *apm) {
	delete apm;
}

int32_t haychat_apm_apply_config(HaychatApm *apm, const HaychatApmConfig *config) {
	if (apm == nullptr || config == nullptr) {
		return webrtc::AudioProcessing::kNullPointerError;
	}
	apm->apm->ApplyConfig(makeConfig(config));
	return webrtc::AudioProcessing::kNoError;
}

int32_t haychat_apm_reset(HaychatApm *apm) {
	if (apm == nullptr) {
		return webrtc::AudioProcessing::kNullPointerError;
	}
	return apm->apm->Initialize();
}

int32_t haychat_apm_process_render(HaychatApm *apm, const float *samples) {
	if (apm == nullptr || samples == nullptr) {
		return webrtc::AudioProcessing::kNullPointerError;
	}
	const float *channels[1] = {samples};
	return apm->apm->AnalyzeReverseStream(channels, apm->stream);
}

int32_t haychat_apm_process_capture(HaychatApm *apm, float *samples) {
	if (apm == nullptr || samples == nullptr) {
		return webrtc::AudioProcessing::kNullPointerError;
	}
	float *channels[1] = {samples};
	return apm->apm->ProcessStream(channels, apm->stream, apm->stream, channels);
}

int32_t haychat_apm_set_stream_delay_ms(HaychatApm *apm, int32_t delayMS) {
	if (apm == nullptr) {
		return webrtc::AudioProcessing::kNullPointerError;
	}
	return apm->apm->set_stream_delay_ms(delayMS);
}

int32_t haychat_apm_get_stats(HaychatApm *apm, HaychatApmStats *stats) {
	if (apm == nullptr || stats == nullptr) {
		return webrtc::AudioProcessing::kNullPointerError;
	}
	webrtc::AudioProcessingStats in = apm->apm->GetStatistics();
	*stats = HaychatApmStats{};
	if (in.echo_return_loss) {
		stats->hasEchoReturnLoss = 1;
		stats->echoReturnLoss = *in.echo_return_loss;
	}
	if (in.echo_return_loss_enhancement) {
		stats->hasEchoReturnLossEnhancement = 1;
		stats->echoReturnLossEnhancement = *in.echo_return_loss_enhancement;
	}
	if (in.divergent_filter_fraction) {
		stats->hasDivergentFilterFraction = 1;
		stats->divergentFilterFraction = *in.divergent_filter_fraction;
	}
	if (in.delay_median_ms) {
		stats->hasDelayMedian = 1;
		stats->delayMedianMS = *in.delay_median_ms;
		stats->delayStandardDeviationMS = in.delay_standard_deviation_ms.value_or(0);
	}
	if (in.delay_ms) {
		stats->hasDelay = 1;
		stats->delayMS = *in.delay_ms;
	}
	if (in.residual_echo_likelihood) {
		stats->hasResidualEchoLikelihood = 1;
		stats->residualEchoLikelihood = *in.residual_echo_likelihood;
	}
	return webrtc::AudioProcessing::kNoError;
}

} // extern "C"
