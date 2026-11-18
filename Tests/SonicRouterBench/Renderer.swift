import CoreAudio
import SonicRouterCore

/// The only file that changes between implementations: it drives whatever
/// render path the core exposes, so the workloads in `main.swift` stay equal.
/// Today: the C++ `RealtimeRenderer` (CAM-003). The Swift baseline drove
/// `StereoRender.copy` with a `RealtimeGainLimiter` and `RealtimeEqualizer`.
final class BenchRenderer {
    private let renderer: RealtimeRenderer

    init(_ item: Case) {
        renderer = RealtimeRenderer(
            sampleRate: 48_000,
            gain: item.gain,
            makeup: item.makeup,
            equalizer: item.equalizer,
            channelMap: OutputChannelMap(deviceChannelCounts: item.deviceChannels)
        )!
    }

    func render(_ input: UnsafeMutableAudioBufferListPointer, _ output: UnsafeMutableAudioBufferListPointer) {
        renderer.render(input: UnsafePointer(input.unsafePointer), output: output.unsafeMutablePointer)
    }
}
