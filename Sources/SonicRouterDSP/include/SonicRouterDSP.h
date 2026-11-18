// SonicRouter realtime DSP core (C++ behind a plain C interface).
//
// Everything that runs on the Core Audio render thread lives here: the gain
// copy, the makeup limiter, the three-band equalizer and the design of its
// filters (recomputed on the render thread while a gain glides). The render
// path never allocates, locks, or calls into the Swift runtime; parameters
// arrive through lock-free atomics.
//
// Swift owns every object: it creates it off the render thread, hands the
// pointer to Core Audio, and destroys it only after the IOProc has stopped.

#ifndef SONICROUTER_DSP_H
#define SONICROUTER_DSP_H

#include <CoreAudioTypes/CoreAudioTypes.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// MARK: Gain policy

/// Requested gain capped to the headroom of a block whose peak is
/// `inputPeak`. Gains at or below unity come back untouched.
float sr_headroom_limited_gain(float requestedGain, float inputPeak);

/// One step of the makeup limiter. `appliedGain` is its state (one per
/// render thread). At or below unity it passes `requestedGain` through.
float sr_limiter_step(float *appliedGain, float requestedGain, float inputPeak);

// MARK: Filter design

typedef struct {
    double b0, b1, b2, a1, a2;
} sr_biquad;

/// Bands: 0 bass (low shelf 100 Hz), 1 mid (peak 1 kHz, Q 0.8),
/// 2 treble (high shelf 8 kHz). 0 dB returns an exact identity.
sr_biquad sr_band_design(int band, double gainDB, double sampleRate);
sr_biquad sr_peaking(double frequency, double gainDB, double q, double sampleRate);
sr_biquad sr_low_shelf(double frequency, double gainDB, double sampleRate);
sr_biquad sr_high_shelf(double frequency, double gainDB, double sampleRate);
double sr_biquad_magnitude(sr_biquad filter, double cos1, double sin1, double cos2, double sin2);
/// Linear pre-gain that undoes the loudest boost of the three filters.
double sr_equalizer_preamp(sr_biquad bass, sr_biquad mid, sr_biquad treble, double sampleRate);

// MARK: Equalizer

enum { SR_EQ_MAX_CHANNELS = 16 };
#define SR_EQ_MAX_STEP_DB 1.5

typedef struct sr_equalizer sr_equalizer;

sr_equalizer *sr_equalizer_create(double sampleRate, double bass, double mid, double treble);
void sr_equalizer_destroy(sr_equalizer *equalizer);
/// Any thread: sets the target gains in dB (clamped by the caller).
void sr_equalizer_set_target(sr_equalizer *equalizer, double bass, double mid, double treble);
/// Render thread, once per IO cycle. False: flat and settled, skip process.
bool sr_equalizer_begin_cycle(sr_equalizer *equalizer);
/// Render thread: filters interleaved Float32 in place.
void sr_equalizer_process(sr_equalizer *equalizer, float *samples, int frameCount, int channelCount, int firstChannel);
/// Render-thread state, for tests: the gains in effect right now.
void sr_equalizer_applied(const sr_equalizer *equalizer, double *bass, double *mid, double *treble);
double sr_equalizer_sample_rate(const sr_equalizer *equalizer);

// MARK: Renderer (one per volume engine)

typedef struct sr_renderer sr_renderer;

/// `channelSources[i]` is the tapped channel for output channel i, or -1 for
/// silence; `deviceCount` > 1 forces the mapped path. Both are copied.
sr_renderer *sr_renderer_create(
    double sampleRate,
    float gain,
    float makeup,
    double bass, double mid, double treble,
    const int32_t *channelSources,
    int32_t channelSourceCount,
    int32_t deviceCount
);
void sr_renderer_destroy(sr_renderer *renderer);
void sr_renderer_set_gain(sr_renderer *renderer, float gain);
void sr_renderer_set_makeup(sr_renderer *renderer, float makeup);
void sr_renderer_set_equalizer(sr_renderer *renderer, double bass, double mid, double treble);

/// Copies `input` into `output` scaled by gain × makeup, then equalizes.
/// Output buffers are always fully written.
void sr_renderer_render(sr_renderer *renderer, const AudioBufferList *input, AudioBufferList *output);

/// An `AudioDeviceIOProc`; pass the renderer as client data.
OSStatus sr_renderer_ioproc(
    uint32_t device,
    const AudioTimeStamp *now,
    const AudioBufferList *inputData,
    const AudioTimeStamp *inputTime,
    AudioBufferList *outputData,
    const AudioTimeStamp *outputTime,
    void *clientData
);

#ifdef __cplusplus
}
#endif

#endif
