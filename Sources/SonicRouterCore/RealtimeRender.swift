import Accelerate
import CoreAudio
import Foundation
import Synchronization

// MARK: - Gain box

/// Holds realtime parameters as atomic Float bit patterns. The UI can update
/// them without racing the Core Audio callback and the callback never takes a
/// lock or allocates memory.
public final class GainBox: Sendable {
    private let gainBits: Atomic<UInt32>
    private let makeupBits: Atomic<UInt32>

    public var gain: Float {
        get { Float(bitPattern: gainBits.load(ordering: .relaxed)) }
        set { gainBits.store(newValue.bitPattern, ordering: .relaxed) }
    }

    /// Makeup gain that lifts the re-emitted signal back up to the app's original
    /// loudness (the capture→re-emit path comes out quieter). Live-adjustable.
    public var makeup: Float {
        get { Float(bitPattern: makeupBits.load(ordering: .relaxed)) }
        set { makeupBits.store(newValue.bitPattern, ordering: .relaxed) }
    }

    public init(_ gain: Float, makeup: Float = 1) {
        gainBits = Atomic(gain.bitPattern)
        makeupBits = Atomic(makeup.bitPattern)
    }
}

/// Mutable only from one Core Audio render thread. Only engages for makeup
/// boosts above unity: gain reduction there is immediate and recovery is
/// smoothed so speech peaks do not turn into clipping or pumping. At or below
/// unity the slider value passes through exactly — the volume control must be
/// a transparent 1:1 attenuation, never an AGC.
public final class RealtimeGainLimiter: @unchecked Sendable {
    private var appliedGain: Float

    public init(initialGain: Float) {
        appliedGain = max(0, initialGain)
    }

    public func gain(requestedGain: Float, inputPeak: Float) -> Float {
        let requested = max(0, requestedGain)
        guard requested > 1 else {
            appliedGain = requested
            return requested
        }

        let target = AudioGainPolicy.headroomLimitedGain(
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
public enum StereoRender {
    public static func copy(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>,
        requestedGain: Float,
        limiter: RealtimeGainLimiter,
        equalizer: RealtimeEqualizer,
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
        _ equalizer: RealtimeEqualizer,
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

// MARK: - Format check

/// Decides, off the realtime thread and before an engine starts, whether
/// `StereoRender` can handle the tap and output formats. `StereoRender`
/// reads and writes raw Float32 samples, so anything else would play as
/// noise: the engine must refuse to start and leave the app on its native
/// path instead (CAM-001-R05).
public enum RenderFormatCheck {
    public enum Problem: Equatable, Sendable {
        /// The tap does not deliver native-endian, packed 32-bit linear float.
        case tapNotFloat32
        /// An output stream does not take native-endian, packed 32-bit linear float.
        case outputNotFloat32
        /// The tap or the output reports no channels at all.
        case noChannels
        /// One-to-one rendering needs as many output channels as the tap has.
        case channelMismatch(tap: Int, output: Int)
    }

    /// `outputs` holds the virtual format of every output stream of the
    /// aggregate, in order. `oneToOne` is for a device-stream tap that must
    /// land channel for channel (CAM-001-R01); the stereo mixdown tap is
    /// spread by `OutputChannelMap`, so any output channel count works.
    public static func problem(
        tap: AudioStreamBasicDescription,
        outputs: [AudioStreamBasicDescription],
        oneToOne: Bool = false
    ) -> Problem? {
        guard isRenderableFloat32(tap) else { return .tapNotFloat32 }
        guard outputs.allSatisfy(isRenderableFloat32) else { return .outputNotFloat32 }
        let outputChannels = outputs.reduce(0) { $0 + Int($1.mChannelsPerFrame) }
        guard tap.mChannelsPerFrame > 0, !outputs.isEmpty, outputChannels > 0 else { return .noChannels }
        if oneToOne, Int(tap.mChannelsPerFrame) != outputChannels {
            return .channelMismatch(tap: Int(tap.mChannelsPerFrame), output: outputChannels)
        }
        return nil
    }

    /// Linear PCM, float, 32 bits, packed, native (little) endian, with the
    /// frame size that matches its interleaving.
    public static func isRenderableFloat32(_ format: AudioStreamBasicDescription) -> Bool {
        let flags = format.mFormatFlags
        guard format.mFormatID == kAudioFormatLinearPCM,
              flags & kAudioFormatFlagIsFloat != 0,
              flags & kAudioFormatFlagIsBigEndian == 0,
              flags & kAudioFormatFlagIsNonMixable == 0,
              format.mBitsPerChannel == 32,
              format.mChannelsPerFrame > 0 else { return false }
        let sampleBytes = UInt32(MemoryLayout<Float>.stride)
        let nonInterleaved = flags & kAudioFormatFlagIsNonInterleaved != 0
        let expectedFrameBytes = nonInterleaved ? sampleBytes : sampleBytes * format.mChannelsPerFrame
        return format.mBytesPerFrame == expectedFrameBytes
    }
}
