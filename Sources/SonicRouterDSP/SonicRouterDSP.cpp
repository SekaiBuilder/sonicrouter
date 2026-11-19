// SonicRouter realtime DSP core. See include/SonicRouterDSP.h.
//
// Floating point is kept strict on purpose: no fused multiply-add
// contraction and no fast-math, so every operation rounds exactly like the
// Swift implementation it replaced and results stay reproducible across
// arm64 and x86_64.
#pragma clang fp contract(off)

#include "SonicRouterDSP.h"

#include <Accelerate/Accelerate.h>
#include <mach/mach_time.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <new>

namespace {

static_assert(std::atomic<float>::is_always_lock_free, "render parameters must be lock-free");
static_assert(std::atomic<double>::is_always_lock_free, "render parameters must be lock-free");

constexpr double kPi = 3.14159265358979323846;

// MARK: Filter design (Robert Bristow-Johnson, "Audio EQ Cookbook")

constexpr sr_biquad kIdentity = {1, 0, 0, 0, 0};

bool isDesignable(double gainDB, double sampleRate) {
    return std::isfinite(gainDB) && std::fabs(gainDB) > 1e-9 && std::isfinite(sampleRate) && sampleRate > 0;
}

/// Keeps the design frequency below Nyquist: call-mode Bluetooth outputs can
/// run at 8–16 kHz, where the treble corner would otherwise alias.
double designFrequency(double frequency, double sampleRate) {
    return std::min(std::max(frequency, 10.0), sampleRate * 0.45);
}

sr_biquad normalized(double b0, double b1, double b2, double a0, double a1, double a2) {
    return {b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0};
}

constexpr double kBandFrequency[3] = {100, 1000, 8000};

// MARK: Equalizer state

struct Equalizer {
    double sampleRate;
    std::atomic<double> target[3];
    double gains[3];          // dB in effect; trails the target while gliding
    double coefficients[15];  // b0 b1 b2 a1 a2 per band
    double memory[SR_EQ_MAX_CHANNELS * 6];  // TDF-II z1 z2 per band per channel
    double preampStart;
    double preampEnd;
    bool filtersRunning;
    int drainCycles;

    Equalizer(double rate, double bass, double mid, double treble)
        : sampleRate(std::isfinite(rate) && rate > 0 ? rate : 48000),
          gains{bass, mid, treble},
          coefficients{},
          memory{},
          preampStart(0),
          preampEnd(0),
          filtersRunning(false),
          drainCycles(0) {
        target[0].store(bass, std::memory_order_relaxed);
        target[1].store(mid, std::memory_order_relaxed);
        target[2].store(treble, std::memory_order_relaxed);
        // Start on the target curve so a new engine plays the chosen EQ at once.
        updateFilters();
        preampStart = preampEnd;
    }

    bool glide(int band, double goal) {
        const double current = gains[band];
        if (current == goal) return false;
        const double delta = goal - current;
        const double step = SR_EQ_MAX_STEP_DB;
        gains[band] = std::fabs(delta) <= step ? goal : current + (delta > 0 ? step : -step);
        return true;
    }

    void updateFilters() {
        const sr_biquad bass = sr_band_design(0, gains[0], sampleRate);
        const sr_biquad mid = sr_band_design(1, gains[1], sampleRate);
        const sr_biquad treble = sr_band_design(2, gains[2], sampleRate);
        store(bass, 0);
        store(mid, 1);
        store(treble, 2);
        preampEnd = sr_equalizer_preamp(bass, mid, treble, sampleRate);
    }

    void store(const sr_biquad &filter, int band) {
        double *base = coefficients + band * 5;
        base[0] = filter.b0;
        base[1] = filter.b1;
        base[2] = filter.b2;
        base[3] = filter.a1;
        base[4] = filter.a2;
    }

    bool beginCycle() {
        const bool bassChanged = glide(0, target[0].load(std::memory_order_relaxed));
        const bool midChanged = glide(1, target[1].load(std::memory_order_relaxed));
        const bool trebleChanged = glide(2, target[2].load(std::memory_order_relaxed));
        preampStart = preampEnd;
        if (bassChanged || midChanged || trebleChanged) updateFilters();

        if (gains[0] == 0 && gains[1] == 0 && gains[2] == 0) {
            // The filters are exact identities now. Run them for a couple more
            // cycles so their memory drains, then leave the samples untouched.
            if (drainCycles > 0) {
                drainCycles -= 1;
                return true;
            }
            if (filtersRunning) {
                std::memset(memory, 0, sizeof(memory));
                filtersRunning = false;
            }
            return false;
        }
        if (!filtersRunning) {
            // Coming out of bypass: start from clean filter memory.
            std::memset(memory, 0, sizeof(memory));
            filtersRunning = true;
        }
        drainCycles = 2;
        return true;
    }

    /// Filter memory decays towards zero forever; flush tiny or invalid values
    /// so the maths never slows down on denormals or stays stuck on a NaN.
    static inline double flushed(double value) {
        return std::isfinite(value) && std::fabs(value) >= 1e-30 ? value : 0;
    }

    void process(float *samples, int frameCount, int channelCount, int firstChannel) {
        if (frameCount <= 0 || channelCount <= 0 || firstChannel < 0) return;
        const double *c = coefficients;
        const double b00 = c[0], b01 = c[1], b02 = c[2], a01 = c[3], a02 = c[4];
        const double b10 = c[5], b11 = c[6], b12 = c[7], a11 = c[8], a12 = c[9];
        const double b20 = c[10], b21 = c[11], b22 = c[12], a21 = c[13], a22 = c[14];
        const double preampStep = (preampEnd - preampStart) / double(frameCount);

        for (int channel = 0; channel < channelCount; ++channel) {
            const int absoluteChannel = firstChannel + channel;
            if (absoluteChannel >= SR_EQ_MAX_CHANNELS) break;
            double *z = memory + absoluteChannel * 6;
            double z0 = z[0], z1 = z[1], z2 = z[2], z3 = z[3], z4 = z[4], z5 = z[5];
            double preamp = preampStart;
            float *sample = samples + channel;
            for (int frame = 0; frame < frameCount; ++frame) {
                const double x = double(*sample);
                const double y0 = b00 * x + z0;
                z0 = b01 * x - a01 * y0 + z1;
                z1 = b02 * x - a02 * y0;
                const double y1 = b10 * y0 + z2;
                z2 = b11 * y0 - a11 * y1 + z3;
                z3 = b12 * y0 - a12 * y1;
                const double y2 = b20 * y1 + z4;
                z4 = b21 * y1 - a21 * y2 + z5;
                z5 = b22 * y1 - a22 * y2;
                preamp += preampStep;
                *sample = float(y2 * preamp);
                sample += channelCount;
            }
            z[0] = flushed(z0);
            z[1] = flushed(z1);
            z[2] = flushed(z2);
            z[3] = flushed(z3);
            z[4] = flushed(z4);
            z[5] = flushed(z5);
        }
    }
};

// MARK: Renderer state

constexpr int kMaxMappedChannels = 64;

struct Renderer {
    std::atomic<float> gain;
    std::atomic<float> makeup;
    float appliedGain;
    Equalizer equalizer;
    int32_t sources[kMaxMappedChannels];
    int32_t sourceCount;
    int32_t deviceCount;

    Renderer(double rate, float initialGain, float initialMakeup, double bass, double mid, double treble,
             const int32_t *channelSources, int32_t channelSourceCount, int32_t devices)
        : appliedGain(std::max(0.0f, initialGain * initialMakeup)),
          equalizer(rate, bass, mid, treble),
          sources{},
          sourceCount(0),
          deviceCount(std::max<int32_t>(1, devices)) {
        gain.store(initialGain, std::memory_order_relaxed);
        makeup.store(initialMakeup, std::memory_order_relaxed);
        if (channelSources && channelSourceCount > 0) {
            sourceCount = std::min<int32_t>(channelSourceCount, kMaxMappedChannels);
            std::memcpy(sources, channelSources, sizeof(int32_t) * size_t(sourceCount));
        } else {
            sources[0] = 0;
            sources[1] = 1;
            sourceCount = 2;
        }
    }

    int32_t source(int outputChannel) const {
        return outputChannel < sourceCount ? sources[outputChannel] : -1;
    }

    static float peakMagnitude(const AudioBufferList *list) {
        float peak = 0;
        for (UInt32 index = 0; index < list->mNumberBuffers; ++index) {
            const AudioBuffer &buffer = list->mBuffers[index];
            if (!buffer.mData) continue;
            const vDSP_Length count = buffer.mDataByteSize / sizeof(float);
            if (count == 0) continue;
            float bufferPeak = 0;
            vDSP_maxmgv(static_cast<const float *>(buffer.mData), 1, &bufferPeak, count);
            peak = std::max(peak, bufferPeak);
        }
        return peak;
    }

    /// Straight scaled copy when input and output share the same buffer layout.
    static bool fastCopy(const AudioBufferList *in, AudioBufferList *out, float scale) {
        if (in->mNumberBuffers != out->mNumberBuffers) return false;
        for (UInt32 index = 0; index < out->mNumberBuffers; ++index) {
            if (in->mBuffers[index].mNumberChannels != out->mBuffers[index].mNumberChannels) return false;
        }
        for (UInt32 index = 0; index < out->mNumberBuffers; ++index) {
            const AudioBuffer &source = in->mBuffers[index];
            AudioBuffer &destination = out->mBuffers[index];
            if (!source.mData || !destination.mData) continue;
            const vDSP_Length count = std::min(source.mDataByteSize, destination.mDataByteSize) / sizeof(float);
            if (count == 0) continue;
            // vDSP multiplies each sample once, exactly like `from[i] * scale`.
            vDSP_vsmul(static_cast<const float *>(source.mData), 1, &scale,
                       static_cast<float *>(destination.mData), 1, count);
        }
        return true;
    }

    /// Where one tapped channel lives: its buffer, first sample, stride and
    /// frame count. Null-data buffers are skipped without consuming channels,
    /// as the Swift implementation did.
    struct Lane {
        const float *data;
        int stride;
        int frames;
    };

    static Lane lane(const AudioBufferList *list, int requestedChannel) {
        int remaining = requestedChannel;
        for (UInt32 index = 0; index < list->mNumberBuffers; ++index) {
            const AudioBuffer &buffer = list->mBuffers[index];
            if (!buffer.mData) continue;
            const int channels = std::max(1, int(buffer.mNumberChannels));
            if (remaining >= channels) {
                remaining -= channels;
                continue;
            }
            const int frames = int(buffer.mDataByteSize / (sizeof(float) * size_t(channels)));
            return {static_cast<const float *>(buffer.mData) + remaining, channels, frames};
        }
        return {nullptr, 0, 0};
    }

    /// Each output device gets L/R on its first two channels; extra channels
    /// stay silent. The source of each output channel is resolved once per
    /// block, then copied with a strided loop.
    void copyMapped(const AudioBufferList *in, AudioBufferList *out, float scale) const {
        int inputChannels = 0;
        for (UInt32 index = 0; index < in->mNumberBuffers; ++index) {
            inputChannels += std::max(1, int(in->mBuffers[index].mNumberChannels));
        }
        if (inputChannels <= 0) return;

        int outputChannel = 0;
        for (UInt32 index = 0; index < out->mNumberBuffers; ++index) {
            AudioBuffer &buffer = out->mBuffers[index];
            const int channels = std::max(1, int(buffer.mNumberChannels));
            if (!buffer.mData) {
                outputChannel += channels;
                continue;
            }
            const int frames = int(buffer.mDataByteSize / (sizeof(float) * size_t(channels)));
            float *samples = static_cast<float *>(buffer.mData);
            for (int channel = 0; channel < channels; ++channel) {
                const int32_t mapped = source(outputChannel + channel);
                if (mapped < 0) continue;
                const Lane from = lane(in, mapped < inputChannels ? mapped : 0);
                if (!from.data) continue;
                const int count = std::min(frames, from.frames);
                if (count <= 0) continue;
                vDSP_vsmul(from.data, from.stride, &scale, samples + channel, channels, vDSP_Length(count));
            }
            outputChannel += channels;
        }
    }

    void applyEqualizer(AudioBufferList *out) {
        if (!equalizer.beginCycle()) return;
        int firstChannel = 0;
        for (UInt32 index = 0; index < out->mNumberBuffers; ++index) {
            AudioBuffer &buffer = out->mBuffers[index];
            const int channels = std::max(1, int(buffer.mNumberChannels));
            if (buffer.mData) {
                const int frames = int(buffer.mDataByteSize / (sizeof(float) * size_t(channels)));
                equalizer.process(static_cast<float *>(buffer.mData), frames, channels, firstChannel);
            }
            firstChannel += channels;
        }
    }

    void render(const AudioBufferList *in, AudioBufferList *out) {
        if (!out) return;
        for (UInt32 index = 0; index < out->mNumberBuffers; ++index) {
            AudioBuffer &buffer = out->mBuffers[index];
            if (buffer.mData) std::memset(buffer.mData, 0, buffer.mDataByteSize);
        }
        const float requested = gain.load(std::memory_order_relaxed) * makeup.load(std::memory_order_relaxed);
        if (!(requested > 0) || !in || in->mNumberBuffers == 0) return;
        // The peak scan only matters for makeup boosts; at or below unity the
        // limiter passes the requested gain through untouched.
        const float applied = sr_limiter_step(&appliedGain, requested, requested > 1 ? peakMagnitude(in) : 0);
        if (!(applied > 0)) return;

        if (deviceCount > 1 || !fastCopy(in, out, applied)) copyMapped(in, out, applied);
        applyEqualizer(out);
    }
};

}  // namespace

// MARK: - C interface

extern "C" {

float sr_headroom_limited_gain(float requestedGain, float inputPeak) {
    const float requested = std::max(0.0f, requestedGain);
    if (!std::isfinite(requested)) return 0;
    if (!(requested > 1)) return requested;
    const float peak = std::max(0.0f, inputPeak);
    if (!std::isfinite(peak) || !(peak > 0)) return requested;
    return std::min(requested, std::max(1.0f, 1 / peak));
}

float sr_limiter_step(float *appliedGain, float requestedGain, float inputPeak) {
    const float requested = std::max(0.0f, requestedGain);
    if (!(requested > 1)) {
        *appliedGain = requested;
        return requested;
    }
    const float target = sr_headroom_limited_gain(requested, inputPeak);
    if (target < *appliedGain) {
        *appliedGain = target;
    } else {
        *appliedGain += (target - *appliedGain) * 0.08f;
    }
    *appliedGain = std::min(*appliedGain, requested);
    return *appliedGain;
}

sr_biquad sr_peaking(double frequency, double gainDB, double q, double sampleRate) {
    if (!isDesignable(gainDB, sampleRate) || !(q > 0)) return kIdentity;
    const double a = std::pow(10.0, gainDB / 40);
    const double omega = 2 * kPi * designFrequency(frequency, sampleRate) / sampleRate;
    const double cosine = std::cos(omega);
    const double alpha = std::sin(omega) / (2 * q);
    return normalized(1 + alpha * a, -2 * cosine, 1 - alpha * a, 1 + alpha / a, -2 * cosine, 1 - alpha / a);
}

sr_biquad sr_low_shelf(double frequency, double gainDB, double sampleRate) {
    if (!isDesignable(gainDB, sampleRate)) return kIdentity;
    const double a = std::pow(10.0, gainDB / 40);
    const double omega = 2 * kPi * designFrequency(frequency, sampleRate) / sampleRate;
    const double cosine = std::cos(omega);
    const double shelf = 2 * std::sqrt(a) * std::sin(omega) / std::sqrt(2.0);
    return normalized(a * ((a + 1) - (a - 1) * cosine + shelf),
                      2 * a * ((a - 1) - (a + 1) * cosine),
                      a * ((a + 1) - (a - 1) * cosine - shelf),
                      (a + 1) + (a - 1) * cosine + shelf,
                      -2 * ((a - 1) + (a + 1) * cosine),
                      (a + 1) + (a - 1) * cosine - shelf);
}

sr_biquad sr_high_shelf(double frequency, double gainDB, double sampleRate) {
    if (!isDesignable(gainDB, sampleRate)) return kIdentity;
    const double a = std::pow(10.0, gainDB / 40);
    const double omega = 2 * kPi * designFrequency(frequency, sampleRate) / sampleRate;
    const double cosine = std::cos(omega);
    const double shelf = 2 * std::sqrt(a) * std::sin(omega) / std::sqrt(2.0);
    return normalized(a * ((a + 1) + (a - 1) * cosine + shelf),
                      -2 * a * ((a - 1) + (a + 1) * cosine),
                      a * ((a + 1) + (a - 1) * cosine - shelf),
                      (a + 1) - (a - 1) * cosine + shelf,
                      2 * ((a - 1) - (a + 1) * cosine),
                      (a + 1) - (a - 1) * cosine - shelf);
}

sr_biquad sr_band_design(int band, double gainDB, double sampleRate) {
    switch (band) {
    case 0: return sr_low_shelf(kBandFrequency[0], gainDB, sampleRate);
    case 1: return sr_peaking(kBandFrequency[1], gainDB, 0.8, sampleRate);
    case 2: return sr_high_shelf(kBandFrequency[2], gainDB, sampleRate);
    default: return kIdentity;
    }
}

double sr_biquad_magnitude(sr_biquad f, double cos1, double sin1, double cos2, double sin2) {
    const double numeratorReal = f.b0 + f.b1 * cos1 + f.b2 * cos2;
    const double numeratorImaginary = -(f.b1 * sin1 + f.b2 * sin2);
    const double denominatorReal = 1 + f.a1 * cos1 + f.a2 * cos2;
    const double denominatorImaginary = -(f.a1 * sin1 + f.a2 * sin2);
    const double numerator = numeratorReal * numeratorReal + numeratorImaginary * numeratorImaginary;
    const double denominator = denominatorReal * denominatorReal + denominatorImaginary * denominatorImaginary;
    if (!(denominator > 0)) return 0;
    return std::sqrt(numerator / denominator);
}

double sr_equalizer_preamp(sr_biquad bass, sr_biquad mid, sr_biquad treble, double sampleRate) {
    if (!std::isfinite(sampleRate) || !(sampleRate > 0)) return 1;
    const double upper = sampleRate * 0.49;
    double loudest = 1.0;
    // DC, 31 log-spaced points from 20 Hz to 20 kHz (ten per decade), the
    // three band frequencies, and just below Nyquist, where shelves peak.
    for (int probe = 0; probe < 36; ++probe) {
        double frequency;
        if (probe == 0) frequency = 0;
        else if (probe <= 31) frequency = 20 * std::pow(10.0, double(probe - 1) / 10);
        else if (probe == 32) frequency = kBandFrequency[0];
        else if (probe == 33) frequency = kBandFrequency[1];
        else if (probe == 34) frequency = kBandFrequency[2];
        else frequency = upper;
        const double omega = 2 * kPi * std::min(frequency, upper) / sampleRate;
        const double cos1 = std::cos(omega);
        const double sin1 = std::sin(omega);
        const double cos2 = std::cos(2 * omega);
        const double sin2 = std::sin(2 * omega);
        const double response = sr_biquad_magnitude(bass, cos1, sin1, cos2, sin2)
            * sr_biquad_magnitude(mid, cos1, sin1, cos2, sin2)
            * sr_biquad_magnitude(treble, cos1, sin1, cos2, sin2);
        if (std::isfinite(response) && response > loudest) loudest = response;
    }
    return 1 / loudest;
}

struct sr_equalizer : Equalizer {
    using Equalizer::Equalizer;
};

sr_equalizer *sr_equalizer_create(double sampleRate, double bass, double mid, double treble) {
    return new (std::nothrow) sr_equalizer(sampleRate, bass, mid, treble);
}

void sr_equalizer_destroy(sr_equalizer *equalizer) { delete equalizer; }

void sr_equalizer_set_target(sr_equalizer *equalizer, double bass, double mid, double treble) {
    equalizer->target[0].store(bass, std::memory_order_relaxed);
    equalizer->target[1].store(mid, std::memory_order_relaxed);
    equalizer->target[2].store(treble, std::memory_order_relaxed);
}

bool sr_equalizer_begin_cycle(sr_equalizer *equalizer) { return equalizer->beginCycle(); }

void sr_equalizer_process(sr_equalizer *equalizer, float *samples, int frameCount, int channelCount, int firstChannel) {
    equalizer->process(samples, frameCount, channelCount, firstChannel);
}

void sr_equalizer_applied(const sr_equalizer *equalizer, double *bass, double *mid, double *treble) {
    *bass = equalizer->gains[0];
    *mid = equalizer->gains[1];
    *treble = equalizer->gains[2];
}

double sr_equalizer_sample_rate(const sr_equalizer *equalizer) { return equalizer->sampleRate; }

/// Written only by the render thread (single writer, relaxed); read by
/// anyone. Kept outside `Renderer` so rendering itself is unchanged.
struct RenderStats {
    std::atomic<bool> enabled{false};
    std::atomic<uint64_t> callbacks{0};
    std::atomic<uint64_t> totalNs{0};
    std::atomic<uint64_t> maxNs{0};
    std::atomic<uint64_t> overHalf{0};
    std::atomic<uint64_t> overBudget{0};
    std::atomic<uint64_t> buckets[SR_STATS_BUCKETS] = {};
    double nsPerTick = 1;

    RenderStats() {
        mach_timebase_info_data_t timebase{};
        if (mach_timebase_info(&timebase) == KERN_SUCCESS && timebase.denom != 0) {
            nsPerTick = double(timebase.numer) / double(timebase.denom);
        }
    }

    static void add(std::atomic<uint64_t> &counter, uint64_t value) {
        counter.store(counter.load(std::memory_order_relaxed) + value, std::memory_order_relaxed);
    }

    void record(uint64_t elapsedNs, double budgetNs) {
        add(callbacks, 1);
        add(totalNs, elapsedNs);
        if (elapsedNs > maxNs.load(std::memory_order_relaxed)) maxNs.store(elapsedNs, std::memory_order_relaxed);
        if (budgetNs > 0 && double(elapsedNs) > budgetNs * 0.5) add(overHalf, 1);
        if (budgetNs > 0 && double(elapsedNs) > budgetNs) add(overBudget, 1);
        int bucket = 0;
        const uint64_t micros = elapsedNs / 1000;
        while (bucket < SR_STATS_BUCKETS - 1 && micros >= (uint64_t(4) << bucket)) ++bucket;
        add(buckets[bucket], 1);
    }
};
static_assert(std::atomic<uint64_t>::is_always_lock_free, "render stats must be lock-free");

struct sr_renderer : Renderer {
    using Renderer::Renderer;
    RenderStats stats;
};

sr_renderer *sr_renderer_create(double sampleRate, float gain, float makeup, double bass, double mid, double treble,
                                const int32_t *channelSources, int32_t channelSourceCount, int32_t deviceCount) {
    return new (std::nothrow)
        sr_renderer(sampleRate, gain, makeup, bass, mid, treble, channelSources, channelSourceCount, deviceCount);
}

void sr_renderer_destroy(sr_renderer *renderer) { delete renderer; }

void sr_renderer_set_stats_enabled(sr_renderer *renderer, bool enabled) {
    renderer->stats.enabled.store(enabled, std::memory_order_relaxed);
}

void sr_renderer_read_stats(const sr_renderer *renderer, sr_render_stats *out) {
    const RenderStats &stats = renderer->stats;
    out->callbacks = stats.callbacks.load(std::memory_order_relaxed);
    out->total_ns = stats.totalNs.load(std::memory_order_relaxed);
    out->max_ns = stats.maxNs.load(std::memory_order_relaxed);
    out->over_half_budget = stats.overHalf.load(std::memory_order_relaxed);
    out->over_budget = stats.overBudget.load(std::memory_order_relaxed);
    for (int i = 0; i < SR_STATS_BUCKETS; ++i) out->buckets[i] = stats.buckets[i].load(std::memory_order_relaxed);
}

void sr_renderer_set_gain(sr_renderer *renderer, float gain) { renderer->gain.store(gain, std::memory_order_relaxed); }

void sr_renderer_set_makeup(sr_renderer *renderer, float makeup) {
    renderer->makeup.store(makeup, std::memory_order_relaxed);
}

void sr_renderer_set_equalizer(sr_renderer *renderer, double bass, double mid, double treble) {
    renderer->equalizer.target[0].store(bass, std::memory_order_relaxed);
    renderer->equalizer.target[1].store(mid, std::memory_order_relaxed);
    renderer->equalizer.target[2].store(treble, std::memory_order_relaxed);
}

void sr_renderer_render(sr_renderer *renderer, const AudioBufferList *input, AudioBufferList *output) {
    renderer->render(input, output);
}

OSStatus sr_renderer_ioproc(uint32_t, const AudioTimeStamp *, const AudioBufferList *inputData, const AudioTimeStamp *,
                            AudioBufferList *outputData, const AudioTimeStamp *, void *clientData) {
    if (!clientData) return 0;
    auto *renderer = static_cast<sr_renderer *>(clientData);
    if (!renderer->stats.enabled.load(std::memory_order_relaxed)) {
        renderer->render(inputData, outputData);
        return 0;
    }
    const uint64_t start = mach_absolute_time();
    renderer->render(inputData, outputData);
    const uint64_t elapsed = mach_absolute_time() - start;
    double budgetNs = 0;
    if (outputData && outputData->mNumberBuffers > 0 && outputData->mBuffers[0].mNumberChannels > 0) {
        const double frames = double(outputData->mBuffers[0].mDataByteSize) /
                              (sizeof(float) * outputData->mBuffers[0].mNumberChannels);
        budgetNs = frames / renderer->equalizer.sampleRate * 1e9;
    }
    renderer->stats.record(uint64_t(double(elapsed) * renderer->stats.nsPerTick), budgetNs);
    return 0;
}

}  // extern "C"
