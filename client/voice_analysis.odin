package client

// Tone analysis for voice tests (voice-rooms-design.md section 6.1). The code lives in the
// client/toneanalysis package, which dev/tools/voice-check shares; these names keep the
// client's tests reading as before.
//
// Pass criteria: the dominant frequency within ±5 Hz of the target, the target bin at least
// 20 dB above the median bin, and the RMS level within 6 dB of the expected level.

import "toneanalysis"

VOICE_TONE_TOLERANCE_HZ :: toneanalysis.TOLERANCE_HZ
VOICE_TONE_MIN_SNR_DB :: toneanalysis.MIN_SNR_DB
VOICE_TONE_RMS_TOLERANCE_DB :: toneanalysis.RMS_TOLERANCE_DB
VOICE_TONE_MAX_SAMPLES :: toneanalysis.MAX_SAMPLES

VoiceToneAnalysis :: toneanalysis.ToneAnalysis

goertzelPower :: toneanalysis.goertzelPower
voiceHannWindow :: toneanalysis.hannWindow
voicePowerDB :: toneanalysis.powerDB
voiceRMSDB :: toneanalysis.rmsDB
analyzeVoiceTone :: toneanalysis.analyze
voiceToneRMSDB :: toneanalysis.sineRMSDB

voiceTonePasses :: proc(analysis: VoiceToneAnalysis, targetHz: f64, expectedRMSDB: f64) -> bool {
	return toneanalysis.passes(analysis, {targetHz = targetHz, expectedRMSDB = expectedRMSDB})
}
