import Foundation
import SonicRouterDSP
import Synchronization

// MARK: - Settings

/// The three tone-control bands of the per-app equalizer.
public enum EqualizerBand: Int, CaseIterable, Sendable {
    /// Low shelf: warmth and rumble.
    case bass
    /// Wide peak: body and voice presence.
    case mid
    /// High shelf: brightness and sibilance.
    case treble

    /// Shelf midpoint (bass, treble) or peak centre (mid), in hertz.
    public var frequency: Double {
        switch self {
        case .bass: 100
        case .mid: 1_000
        case .treble: 8_000
        }
    }

    /// This band's filter for `gainDB` at `sampleRate` (designed in C++,
    /// the same code the render thread uses).
    public func coefficients(gainDB: Double, sampleRate: Double) -> BiquadCoefficients {
        BiquadCoefficients(sr_band_design(Int32(rawValue), gainDB, sampleRate))
    }
}

/// Per-app tone control, in decibels per band. Every value is finite and
/// inside `gainRange`, including ones decoded from disk or from an imported
/// file, so no stored setting can produce an unstable filter.
public struct AudioEqualizerSettings: Codable, Hashable, Sendable {
    public static let gainRange: ClosedRange<Double> = -12...12
    public static let flat = AudioEqualizerSettings()

    public private(set) var bass: Double
    public private(set) var mid: Double
    public private(set) var treble: Double

    public init(bass: Double = 0, mid: Double = 0, treble: Double = 0) {
        self.bass = Self.clamped(bass)
        self.mid = Self.clamped(mid)
        self.treble = Self.clamped(treble)
    }

    public subscript(band: EqualizerBand) -> Double {
        get {
            switch band {
            case .bass: bass
            case .mid: mid
            case .treble: treble
            }
        }
        set {
            let value = Self.clamped(newValue)
            switch band {
            case .bass: bass = value
            case .mid: mid = value
            case .treble: treble = value
            }
        }
    }

    /// Every band is inaudibly close to 0 dB, so the app can keep its native,
    /// untouched path.
    public var isFlat: Bool {
        abs(bass) < 0.05 && abs(mid) < 0.05 && abs(treble) < 0.05
    }

    public static func clamped(_ gain: Double) -> Double {
        guard gain.isFinite else { return 0 }
        return min(max(gain, gainRange.lowerBound), gainRange.upperBound)
    }

    private enum CodingKeys: String, CodingKey {
        case bass, mid, treble
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            bass: try container.decodeIfPresent(Double.self, forKey: .bass) ?? 0,
            mid: try container.decodeIfPresent(Double.self, forKey: .mid) ?? 0,
            treble: try container.decodeIfPresent(Double.self, forKey: .treble) ?? 0
        )
    }
}

// MARK: - Filter design

/// A biquad normalised so that a0 = 1.
public struct BiquadCoefficients: Equatable, Sendable {
    public var b0: Double
    public var b1: Double
    public var b2: Double
    public var a1: Double
    public var a2: Double

    public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }

    public static let identity = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    /// Both poles strictly inside the unit circle (Jury's criterion).
    public var isStable: Bool {
        abs(a2) < 1 && abs(a1) < 1 + a2
    }

    /// Linear magnitude of the response at `frequency`.
    public func magnitude(at frequency: Double, sampleRate: Double) -> Double {
        let omega = 2 * Double.pi * frequency / sampleRate
        return magnitude(cos1: cos(omega), sin1: sin(omega), cos2: cos(2 * omega), sin2: sin(2 * omega))
    }

    /// `magnitude(at:sampleRate:)` with the trigonometry precomputed, so
    /// several filters can be probed at one frequency cheaply.
    public func magnitude(cos1: Double, sin1: Double, cos2: Double, sin2: Double) -> Double {
        sr_biquad_magnitude(raw, cos1, sin1, cos2, sin2)
    }

    init(_ raw: sr_biquad) {
        self.init(b0: raw.b0, b1: raw.b1, b2: raw.b2, a1: raw.a1, a2: raw.a2)
    }

    var raw: sr_biquad { sr_biquad(b0: b0, b1: b1, b2: b2, a1: a1, a2: a2) }
}

/// Filter formulas from Robert Bristow-Johnson's "Audio EQ Cookbook",
/// implemented in C++ (`SonicRouterDSP`). A band at 0 dB returns an exact
/// identity, which keeps a flat equalizer bit-transparent.
public enum BiquadDesign {
    public static func peaking(frequency: Double, gainDB: Double, q: Double, sampleRate: Double) -> BiquadCoefficients {
        BiquadCoefficients(sr_peaking(frequency, gainDB, q, sampleRate))
    }

    /// Shelf slope S = 1: the steepest slope without a bump in the response.
    public static func lowShelf(frequency: Double, gainDB: Double, sampleRate: Double) -> BiquadCoefficients {
        BiquadCoefficients(sr_low_shelf(frequency, gainDB, sampleRate))
    }

    /// Shelf slope S = 1: the steepest slope without a bump in the response.
    public static func highShelf(frequency: Double, gainDB: Double, sampleRate: Double) -> BiquadCoefficients {
        BiquadCoefficients(sr_high_shelf(frequency, gainDB, sampleRate))
    }
}

/// Automatic pre-gain for the equalizer.
public enum EqualizerHeadroom {
    /// Linear gain that undoes the loudest boost of the combined response, so
    /// the equalizer never lifts a peak above the source's own level and never
    /// needs hard clipping. Cuts are left alone: without boosts it returns 1.
    /// Probes DC, 31 log-spaced points from 20 Hz to 20 kHz, the three band
    /// frequencies and just below Nyquist (C++: `sr_equalizer_preamp`).
    public static func preampGain(
        _ bass: BiquadCoefficients,
        _ mid: BiquadCoefficients,
        _ treble: BiquadCoefficients,
        sampleRate: Double
    ) -> Double {
        sr_equalizer_preamp(bass.raw, mid.raw, treble.raw, sampleRate)
    }
}

// MARK: - Realtime processing

/// Target gains shared by the UI (writer) and the render thread (reader).
/// Each band is its own atomic, so the reader never sees a torn value; two
/// bands changed together may take effect one IO cycle apart, which is
/// inaudible.
public final class EqualizerParameters: Sendable {
    private let bassBits: Atomic<UInt64>
    private let midBits: Atomic<UInt64>
    private let trebleBits: Atomic<UInt64>

    public init(_ settings: AudioEqualizerSettings = .flat) {
        bassBits = Atomic(settings.bass.bitPattern)
        midBits = Atomic(settings.mid.bitPattern)
        trebleBits = Atomic(settings.treble.bitPattern)
    }

    public var settings: AudioEqualizerSettings {
        get {
            AudioEqualizerSettings(
                bass: Double(bitPattern: bassBits.load(ordering: .relaxed)),
                mid: Double(bitPattern: midBits.load(ordering: .relaxed)),
                treble: Double(bitPattern: trebleBits.load(ordering: .relaxed))
            )
        }
        set {
            bassBits.store(newValue.bass.bitPattern, ordering: .relaxed)
            midBits.store(newValue.mid.bitPattern, ordering: .relaxed)
            trebleBits.store(newValue.treble.bitPattern, ordering: .relaxed)
        }
    }
}

/// The equalizer on its own, implemented in C++ (`SonicRouterDSP`); the
/// volume engine's `RealtimeRenderer` embeds the same code. Gain changes
/// glide by at most `maxStepDB` per IO cycle to avoid zipper noise, and a
/// flat, settled equalizer is skipped entirely so the path stays bit-exact.
public final class RealtimeEqualizer: @unchecked Sendable {
    /// Channels beyond this pass through unfiltered.
    public static let maxChannels = Int(SR_EQ_MAX_CHANNELS)
    /// Largest gain change applied per IO cycle (about 10 ms), in decibels.
    public static let maxStepDB = SR_EQ_MAX_STEP_DB

    private let parameters: EqualizerParameters
    private let handle: OpaquePointer

    public init(parameters: EqualizerParameters, sampleRate: Double) {
        self.parameters = parameters
        let target = parameters.settings
        handle = sr_equalizer_create(sampleRate, target.bass, target.mid, target.treble)!
    }

    deinit { sr_equalizer_destroy(handle) }

    public var sampleRate: Double { sr_equalizer_sample_rate(handle) }

    /// Gains in effect right now; they trail the target while gliding.
    /// Render-thread state: read it only from the render thread or in tests.
    public var appliedSettings: AudioEqualizerSettings {
        var bass = 0.0, mid = 0.0, treble = 0.0
        sr_equalizer_applied(handle, &bass, &mid, &treble)
        return AudioEqualizerSettings(bass: bass, mid: mid, treble: treble)
    }

    /// Call once per IO cycle, before `process`. Returns false when the
    /// equalizer is flat and settled: skip `process` and the audio stays
    /// bit-exact.
    public func beginCycle() -> Bool {
        let target = parameters.settings
        sr_equalizer_set_target(handle, target.bass, target.mid, target.treble)
        return sr_equalizer_begin_cycle(handle)
    }

    /// Filters one buffer of interleaved Float32 samples in place.
    /// `firstChannel` is this buffer's first channel across the whole buffer
    /// list, so planar and interleaved layouts keep separate filter memory per
    /// channel in the same way.
    public func process(
        _ samples: UnsafeMutablePointer<Float>,
        frameCount: Int,
        channelCount: Int,
        firstChannel: Int
    ) {
        sr_equalizer_process(handle, samples, Int32(frameCount), Int32(channelCount), Int32(firstChannel))
    }
}
