import CoreAudio
import Foundation
import SonicRouterDSP

// MARK: - Realtime renderer

/// One volume engine's render state, implemented in C++ (`SonicRouterDSP`):
/// the IOProc is the C function `ioProc` with this object's `clientData`, so
/// the Core Audio render thread never enters the Swift runtime. It copies the
/// tapped audio scaled by gain × makeup, limits makeup boosts above unity,
/// spreads channels with an `OutputChannelMap` and runs the equalizer.
///
/// Owned by Swift: keep it alive until the IOProc has been stopped and
/// destroyed. Setters are lock-free and safe from any thread.
public final class RealtimeRenderer: @unchecked Sendable {
    private let handle: OpaquePointer

    /// The C IOProc to register with `AudioDeviceCreateIOProcID`.
    public static let ioProc: AudioDeviceIOProc = { device, now, input, inputTime, output, outputTime, client in
        sr_renderer_ioproc(device, now, input, inputTime, output, outputTime, client)
    }

    public init?(
        sampleRate: Double,
        gain: Float,
        makeup: Float,
        equalizer: AudioEqualizerSettings,
        channelMap: OutputChannelMap
    ) {
        let sources = channelMap.sources.map(Int32.init)
        guard let handle = sources.withUnsafeBufferPointer({ buffer in
            sr_renderer_create(
                sampleRate, gain, makeup,
                equalizer.bass, equalizer.mid, equalizer.treble,
                buffer.baseAddress, Int32(buffer.count), Int32(channelMap.deviceCount)
            )
        }) else { return nil }
        self.handle = handle
    }

    deinit { sr_renderer_destroy(handle) }

    /// Pass as the IOProc client data. Valid while this object lives.
    public var clientData: UnsafeMutableRawPointer { UnsafeMutableRawPointer(handle) }

    public func setGain(_ gain: Float) { sr_renderer_set_gain(handle, gain) }
    public func setMakeup(_ makeup: Float) { sr_renderer_set_makeup(handle, makeup) }
    public func setEqualizer(_ settings: AudioEqualizerSettings) {
        sr_renderer_set_equalizer(handle, settings.bass, settings.mid, settings.treble)
    }

    /// Renders one block, exactly as the IOProc does. For tests and benchmarks.
    public func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        sr_renderer_render(handle, input, output)
    }
}

/// The makeup limiter on its own (the renderer embeds one). Only engages for
/// boosts above unity: reduction is immediate and recovery smoothed. At or
/// below unity the requested gain passes through exactly.
public final class RealtimeGainLimiter: @unchecked Sendable {
    private var appliedGain: Float

    public init(initialGain: Float) {
        appliedGain = max(0, initialGain)
    }

    public func gain(requestedGain: Float, inputPeak: Float) -> Float {
        sr_limiter_step(&appliedGain, requestedGain, inputPeak)
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
