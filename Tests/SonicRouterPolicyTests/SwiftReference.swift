import Accelerate
import CoreAudio
import Foundation
import SonicRouterCore

// Reference: the Swift realtime path as it was before CAM-003 moved it to C++
// (commit 2b8aa30, copied verbatim apart from the `Ref` names and the band
// constants inlined). The equivalence tests require the C++ core to produce
// bit-identical output to this code. Do not "fix" it: it is the oracle.

enum RefGainPolicy {
    static func headroomLimitedGain(requestedGain: Float, inputPeak: Float) -> Float {
        let requested = max(0, requestedGain)
        guard requested.isFinite else { return 0 }
        guard requested > 1 else { return requested }
        let peak = max(0, inputPeak)
        guard peak.isFinite, peak > 0 else { return requested }
        return min(requested, max(1, 1 / peak))
    }
}

// MARK: - Filter design

/// A biquad normalised so that a0 = 1.
struct RefBiquad: Equatable, Sendable {
    var b0: Double
    var b1: Double
    var b2: Double
    var a1: Double
    var a2: Double

    init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }

    static let identity = RefBiquad(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    /// Both poles strictly inside the unit circle (Jury's criterion).
    var isStable: Bool {
        abs(a2) < 1 && abs(a1) < 1 + a2
    }

    /// Linear magnitude of the response at `frequency`.
    func magnitude(at frequency: Double, sampleRate: Double) -> Double {
        let omega = 2 * Double.pi * frequency / sampleRate
        return magnitude(cos1: cos(omega), sin1: sin(omega), cos2: cos(2 * omega), sin2: sin(2 * omega))
    }

    /// `magnitude(at:sampleRate:)` with the trigonometry precomputed, so
    /// several filters can be probed at one frequency cheaply.
    func magnitude(cos1: Double, sin1: Double, cos2: Double, sin2: Double) -> Double {
        let numeratorReal = b0 + b1 * cos1 + b2 * cos2
        let numeratorImaginary = -(b1 * sin1 + b2 * sin2)
        let denominatorReal = 1 + a1 * cos1 + a2 * cos2
        let denominatorImaginary = -(a1 * sin1 + a2 * sin2)
        let numerator = numeratorReal * numeratorReal + numeratorImaginary * numeratorImaginary
        let denominator = denominatorReal * denominatorReal + denominatorImaginary * denominatorImaginary
        guard denominator > 0 else { return 0 }
        return (numerator / denominator).squareRoot()
    }
}

/// Filter formulas from Robert Bristow-Johnson's "Audio EQ Cookbook". A band
/// at 0 dB returns an exact identity, which keeps a flat equalizer
/// bit-transparent.
enum RefDesign {
    static func peaking(
        frequency: Double,
        gainDB: Double,
        q: Double,
        sampleRate: Double
    ) -> RefBiquad {
        guard isDesignable(gainDB: gainDB, sampleRate: sampleRate), q > 0 else { return .identity }
        let a = pow(10, gainDB / 40)
        let omega = 2 * Double.pi * designFrequency(frequency, sampleRate: sampleRate) / sampleRate
        let cosine = cos(omega)
        let alpha = sin(omega) / (2 * q)
        return normalized(
            b0: 1 + alpha * a,
            b1: -2 * cosine,
            b2: 1 - alpha * a,
            a0: 1 + alpha / a,
            a1: -2 * cosine,
            a2: 1 - alpha / a
        )
    }

    /// Shelf slope S = 1: the steepest slope without a bump in the response.
    static func lowShelf(frequency: Double, gainDB: Double, sampleRate: Double) -> RefBiquad {
        guard isDesignable(gainDB: gainDB, sampleRate: sampleRate) else { return .identity }
        let a = pow(10, gainDB / 40)
        let omega = 2 * Double.pi * designFrequency(frequency, sampleRate: sampleRate) / sampleRate
        let cosine = cos(omega)
        let shelf = 2 * a.squareRoot() * sin(omega) / sqrt(2.0)
        return normalized(
            b0: a * ((a + 1) - (a - 1) * cosine + shelf),
            b1: 2 * a * ((a - 1) - (a + 1) * cosine),
            b2: a * ((a + 1) - (a - 1) * cosine - shelf),
            a0: (a + 1) + (a - 1) * cosine + shelf,
            a1: -2 * ((a - 1) + (a + 1) * cosine),
            a2: (a + 1) + (a - 1) * cosine - shelf
        )
    }

    /// Shelf slope S = 1: the steepest slope without a bump in the response.
    static func highShelf(frequency: Double, gainDB: Double, sampleRate: Double) -> RefBiquad {
        guard isDesignable(gainDB: gainDB, sampleRate: sampleRate) else { return .identity }
        let a = pow(10, gainDB / 40)
        let omega = 2 * Double.pi * designFrequency(frequency, sampleRate: sampleRate) / sampleRate
        let cosine = cos(omega)
        let shelf = 2 * a.squareRoot() * sin(omega) / sqrt(2.0)
        return normalized(
            b0: a * ((a + 1) + (a - 1) * cosine + shelf),
            b1: -2 * a * ((a - 1) + (a + 1) * cosine),
            b2: a * ((a + 1) + (a - 1) * cosine - shelf),
            a0: (a + 1) - (a - 1) * cosine + shelf,
            a1: 2 * ((a - 1) - (a + 1) * cosine),
            a2: (a + 1) - (a - 1) * cosine - shelf
        )
    }

    private static func isDesignable(gainDB: Double, sampleRate: Double) -> Bool {
        gainDB.isFinite && abs(gainDB) > 1e-9 && sampleRate.isFinite && sampleRate > 0
    }

    /// Keeps the design frequency below Nyquist. Call-mode Bluetooth outputs
    /// can run at 8–16 kHz, where the treble corner would otherwise alias.
    private static func designFrequency(_ frequency: Double, sampleRate: Double) -> Double {
        min(max(frequency, 10), sampleRate * 0.45)
    }

    private static func normalized(
        b0: Double,
        b1: Double,
        b2: Double,
        a0: Double,
        a1: Double,
        a2: Double
    ) -> RefBiquad {
        RefBiquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }
}

/// Automatic pre-gain for the equalizer.
enum RefHeadroom {
    /// Linear gain that undoes the loudest boost of the combined response, so
    /// the equalizer never lifts a peak above the source's own level and never
    /// needs hard clipping. Cuts are left alone: without boosts it returns 1.
    /// Allocation-free, so the render thread may call it.
    static func preampGain(
        _ bass: RefBiquad,
        _ mid: RefBiquad,
        _ treble: RefBiquad,
        sampleRate: Double
    ) -> Double {
        guard sampleRate.isFinite, sampleRate > 0 else { return 1 }
        let upper = sampleRate * 0.49
        var loudest = 1.0
        // DC, 31 log-spaced points from 20 Hz to 20 kHz (ten per decade), the
        // three band frequencies, and just below Nyquist, where shelves peak.
        for probe in 0..<36 {
            let frequency: Double
            switch probe {
            case 0: frequency = 0
            case 1...31: frequency = 20 * pow(10, Double(probe - 1) / 10)
            case 32: frequency = 100
            case 33: frequency = 1_000
            case 34: frequency = 8_000
            default: frequency = upper
            }
            let omega = 2 * Double.pi * min(frequency, upper) / sampleRate
            let cos1 = cos(omega)
            let sin1 = sin(omega)
            let cos2 = cos(2 * omega)
            let sin2 = sin(2 * omega)
            let response = bass.magnitude(cos1: cos1, sin1: sin1, cos2: cos2, sin2: sin2)
                * mid.magnitude(cos1: cos1, sin1: sin1, cos2: cos2, sin2: sin2)
                * treble.magnitude(cos1: cos1, sin1: sin1, cos2: cos2, sin2: sin2)
            if response.isFinite, response > loudest { loudest = response }
        }
        return 1 / loudest
    }
}

/// Applies the equalizer in place on the Core Audio render thread.
///
/// Everything the render callback touches is allocated up front behind raw
/// pointers, so processing never allocates, locks, or pays for Swift
/// exclusivity checks. Gain changes glide by at most `maxStepDB` per IO cycle
/// to avoid zipper noise, and a flat, settled equalizer is skipped entirely so
/// the default path stays bit-exact.
final class RefEqualizer: @unchecked Sendable {
    /// Channels beyond this pass through unfiltered.
    static let maxChannels = 16
    /// Largest gain change applied per IO cycle (about 10 ms), in decibels.
    static let maxStepDB = 1.5

    let sampleRate: Double
    private let parameters: EqualizerParameters
    private let step: Double
    private let memoryCount: Int

    /// Current gain in dB per band (they trail the target while gliding).
    private let gains: UnsafeMutablePointer<Double>
    /// b0 b1 b2 a1 a2 per band.
    private let coefficients: UnsafeMutablePointer<Double>
    /// Transposed direct form II memory: z1 z2 per band per channel.
    private let memory: UnsafeMutablePointer<Double>
    /// [0] preamp at the start of the cycle, [1] preamp at its end,
    /// [2] 1 while the filters run, [3] cycles left to drain after going flat.
    private let control: UnsafeMutablePointer<Double>

    init(parameters: EqualizerParameters, sampleRate: Double) {
        self.parameters = parameters
        self.sampleRate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : 48_000
        step = Self.maxStepDB
        memoryCount = Self.maxChannels * 3 * 2
        gains = .allocate(capacity: 3)
        gains.initialize(repeating: 0, count: 3)
        coefficients = .allocate(capacity: 15)
        coefficients.initialize(repeating: 0, count: 15)
        memory = .allocate(capacity: memoryCount)
        memory.initialize(repeating: 0, count: memoryCount)
        control = .allocate(capacity: 4)
        control.initialize(repeating: 0, count: 4)

        // Start on the target curve so a new engine plays the chosen EQ at once.
        let target = parameters.settings
        gains[0] = target.bass
        gains[1] = target.mid
        gains[2] = target.treble
        updateFilters()
        control[0] = control[1]
    }

    deinit {
        gains.deallocate()
        coefficients.deallocate()
        memory.deallocate()
        control.deallocate()
    }

    /// Gains in effect right now; they trail the target while gliding.
    /// Render-thread state: read it only from the render thread or in tests.
    var appliedSettings: AudioEqualizerSettings {
        AudioEqualizerSettings(bass: gains[0], mid: gains[1], treble: gains[2])
    }

    /// Call once per IO cycle, before `process`. Returns false when the
    /// equalizer is flat and settled: skip `process` and the audio stays
    /// bit-exact.
    func beginCycle() -> Bool {
        let target = parameters.settings
        let bassChanged = glide(0, toward: target.bass)
        let midChanged = glide(1, toward: target.mid)
        let trebleChanged = glide(2, toward: target.treble)
        control[0] = control[1]
        if bassChanged || midChanged || trebleChanged { updateFilters() }

        if gains[0] == 0 && gains[1] == 0 && gains[2] == 0 {
            // The filters are exact identities now. Run them for a couple more
            // cycles so their memory drains, then leave the samples untouched.
            if control[3] > 0 {
                control[3] -= 1
                return true
            }
            if control[2] != 0 {
                memory.update(repeating: 0, count: memoryCount)
                control[2] = 0
            }
            return false
        }
        if control[2] == 0 {
            // Coming out of bypass: start from clean filter memory.
            memory.update(repeating: 0, count: memoryCount)
            control[2] = 1
        }
        control[3] = 2
        return true
    }

    /// Filters one buffer of interleaved Float32 samples in place.
    /// `firstChannel` is this buffer's first channel across the whole buffer
    /// list, so planar and interleaved layouts keep separate filter memory per
    /// channel in the same way.
    func process(
        _ samples: UnsafeMutablePointer<Float>,
        frameCount: Int,
        channelCount: Int,
        firstChannel: Int
    ) {
        guard frameCount > 0, channelCount > 0, firstChannel >= 0 else { return }
        let c = coefficients
        let b00 = c[0], b01 = c[1], b02 = c[2], a01 = c[3], a02 = c[4]
        let b10 = c[5], b11 = c[6], b12 = c[7], a11 = c[8], a12 = c[9]
        let b20 = c[10], b21 = c[11], b22 = c[12], a21 = c[13], a22 = c[14]
        let preampStart = control[0]
        let preampStep = (control[1] - preampStart) / Double(frameCount)

        for channel in 0..<channelCount {
            let absoluteChannel = firstChannel + channel
            guard absoluteChannel < Self.maxChannels else { break }
            let z = memory + absoluteChannel * 6
            var z0 = z[0], z1 = z[1], z2 = z[2], z3 = z[3], z4 = z[4], z5 = z[5]
            var preamp = preampStart
            var index = channel
            for _ in 0..<frameCount {
                let x = Double(samples[index])
                let y0 = b00 * x + z0
                z0 = b01 * x - a01 * y0 + z1
                z1 = b02 * x - a02 * y0
                let y1 = b10 * y0 + z2
                z2 = b11 * y0 - a11 * y1 + z3
                z3 = b12 * y0 - a12 * y1
                let y2 = b20 * y1 + z4
                z4 = b21 * y1 - a21 * y2 + z5
                z5 = b22 * y1 - a22 * y2
                preamp += preampStep
                samples[index] = Float(y2 * preamp)
                index += channelCount
            }
            z[0] = Self.flushed(z0)
            z[1] = Self.flushed(z1)
            z[2] = Self.flushed(z2)
            z[3] = Self.flushed(z3)
            z[4] = Self.flushed(z4)
            z[5] = Self.flushed(z5)
        }
    }

    private func glide(_ band: Int, toward target: Double) -> Bool {
        let current = gains[band]
        guard current != target else { return false }
        let delta = target - current
        gains[band] = abs(delta) <= step ? target : current + (delta > 0 ? step : -step)
        return true
    }

    private func updateFilters() {
        let bass = RefDesign.lowShelf(frequency: 100, gainDB: gains[0], sampleRate: sampleRate)
        let mid = RefDesign.peaking(frequency: 1_000, gainDB: gains[1], q: 0.8, sampleRate: sampleRate)
        let treble = RefDesign.highShelf(frequency: 8_000, gainDB: gains[2], sampleRate: sampleRate)
        store(bass, band: 0)
        store(mid, band: 1)
        store(treble, band: 2)
        control[1] = RefHeadroom.preampGain(bass, mid, treble, sampleRate: sampleRate)
    }

    private func store(_ filter: RefBiquad, band: Int) {
        let base = coefficients + band * 5
        base[0] = filter.b0
        base[1] = filter.b1
        base[2] = filter.b2
        base[3] = filter.a1
        base[4] = filter.a2
    }

    /// Filter memory decays towards zero forever; flush tiny or invalid values
    /// so the maths never slows down on denormals or stays stuck on a NaN.
    @inline(__always)
    private static func flushed(_ value: Double) -> Double {
        value.isFinite && abs(value) >= 1e-30 ? value : 0
    }
}

/// Mutable only from one Core Audio render thread. Only engages for makeup
/// boosts above unity: gain reduction there is immediate and recovery is
/// smoothed so speech peaks do not turn into clipping or pumping. At or below
/// unity the slider value passes through exactly — the volume control must be
/// a transparent 1:1 attenuation, never an AGC.
final class RefLimiter: @unchecked Sendable {
    private var appliedGain: Float

    init(initialGain: Float) {
        appliedGain = max(0, initialGain)
    }

    func gain(requestedGain: Float, inputPeak: Float) -> Float {
        let requested = max(0, requestedGain)
        guard requested > 1 else {
            appliedGain = requested
            return requested
        }

        let target = RefGainPolicy.headroomLimitedGain(
            requestedGain: requested,
            inputPeak: inputPeak
        )
        if target < appliedGain {
            appliedGain = target
        } else {
            appliedGain += (target - appliedGain) * 0.08
        }
        appliedGain = min(appliedGain, requested)
        return appliedGain
    }
}

// MARK: - Realtime stereo copy

/// Copies an app's tapped audio into the output device buffers, scaled by gain,
/// then runs the app's equalizer over them in place. Handles interleaved and
/// planar Float32 layouts so it works across output devices. The fast path
/// (one device, matching layouts) does a straight vDSP scale with no
/// allocation; otherwise `channelMap` sends L/R to the first two channels of
/// every output device in the aggregate.
enum RefRender {
    static func copy(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>,
        requestedGain: Float,
        limiter: RefLimiter,
        equalizer: RefEqualizer,
        channelMap: OutputChannelMap
    ) {
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)

        for buffer in outList {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        guard requestedGain > 0, !inList.isEmpty else { return }
        // The peak scan only matters for makeup boosts; at or below unity the
        // limiter passes the requested gain through untouched.
        let gain = limiter.gain(
            requestedGain: requestedGain,
            inputPeak: requestedGain > 1 ? peakMagnitude(inList) : 0
        )
        guard gain > 0 else { return }

        if channelMap.deviceCount > 1 || !fastCopy(inList: inList, outList: outList, gain: gain) {
            copyMapped(inList: inList, outList: outList, gain: gain, channelMap: channelMap)
        }
        applyEqualizer(equalizer, to: outList)
    }

    /// Filters the rendered output in place. A flat, settled equalizer returns
    /// straight away, so the default path stays a bit-exact scaled copy.
    private static func applyEqualizer(
        _ equalizer: RefEqualizer,
        to outList: UnsafeMutableAudioBufferListPointer
    ) {
        guard equalizer.beginCycle() else { return }
        var firstChannel = 0
        for buffer in outList {
            let channels = max(1, Int(buffer.mNumberChannels))
            if let data = buffer.mData {
                let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.stride * channels)
                equalizer.process(
                    data.assumingMemoryBound(to: Float.self),
                    frameCount: frames,
                    channelCount: channels,
                    firstChannel: firstChannel
                )
            }
            firstChannel += channels
        }
    }

    private static func peakMagnitude(_ list: UnsafeMutableAudioBufferListPointer) -> Float {
        var peak: Float = 0
        for buffer in list {
            guard let data = buffer.mData else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.stride
            guard count > 0 else { continue }
            var bufferPeak: Float = 0
            vDSP_maxmgv(
                data.assumingMemoryBound(to: Float.self),
                1,
                &bufferPeak,
                vDSP_Length(count)
            )
            peak = max(peak, bufferPeak)
        }
        return peak
    }

    /// Straight scaled copy when input and output share the same buffer layout.
    private static func fastCopy(
        inList: UnsafeMutableAudioBufferListPointer,
        outList: UnsafeMutableAudioBufferListPointer,
        gain: Float
    ) -> Bool {
        guard inList.count == outList.count else { return false }
        for index in 0..<outList.count where inList[index].mNumberChannels != outList[index].mNumberChannels {
            return false
        }

        var scalar = gain
        for index in 0..<outList.count {
            guard let inData = inList[index].mData, let outData = outList[index].mData else { continue }
            let count = min(Int(inList[index].mDataByteSize), Int(outList[index].mDataByteSize)) / MemoryLayout<Float>.stride
            guard count > 0 else { continue }
            vDSP_vsmul(
                inData.assumingMemoryBound(to: Float.self), 1,
                &scalar,
                outData.assumingMemoryBound(to: Float.self), 1,
                vDSP_Length(count)
            )
        }
        return true
    }

    /// Allocation-free copy driven by `channelMap`: each output device gets
    /// L/R on its first two channels; extra channels stay silent instead of
    /// receiving duplicated left-channel audio.
    private static func copyMapped(
        inList: UnsafeMutableAudioBufferListPointer,
        outList: UnsafeMutableAudioBufferListPointer,
        gain: Float,
        channelMap: OutputChannelMap
    ) {
        let inputChannels = inList.reduce(0) { $0 + max(1, Int($1.mNumberChannels)) }
        guard inputChannels > 0 else { return }

        var outputChannel = 0
        for buffer in outList {
            guard let data = buffer.mData else {
                outputChannel += max(1, Int(buffer.mNumberChannels))
                continue
            }
            let channels = max(1, Int(buffer.mNumberChannels))
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.stride * channels)
            let samples = data.assumingMemoryBound(to: Float.self)

            for channel in 0..<channels {
                let mapped = channelMap.source(forOutputChannel: outputChannel + channel)
                guard mapped >= 0 else { continue }
                let sourceChannel = mapped < inputChannels ? mapped : 0
                for frame in 0..<frames {
                    samples[frame * channels + channel] = sample(
                        from: inList,
                        channel: sourceChannel,
                        frame: frame
                    ) * gain
                }
            }
            outputChannel += channels
        }
    }

    private static func sample(
        from list: UnsafeMutableAudioBufferListPointer,
        channel requestedChannel: Int,
        frame: Int
    ) -> Float {
        var remainingChannel = requestedChannel
        for buffer in list {
            guard let data = buffer.mData else { continue }
            let channels = max(1, Int(buffer.mNumberChannels))
            guard remainingChannel < channels else {
                remainingChannel -= channels
                continue
            }
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.stride * channels)
            guard frame < frames else { return 0 }
            return data.assumingMemoryBound(to: Float.self)[frame * channels + remainingChannel]
        }
        return 0
    }
}

