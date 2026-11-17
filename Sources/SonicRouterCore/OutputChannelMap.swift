import Foundation

// MARK: - Output channel map

/// Which tapped channel feeds each output channel of an aggregate that may
/// hold several devices (for example the display and the built-in speakers).
/// Built off the realtime thread and read-only afterwards.
public final class OutputChannelMap: @unchecked Sendable {
    public let deviceCount: Int
    private let sources: [Int]

    /// `deviceChannelCounts` lists each output device's channels in
    /// aggregate order. Every device gets L/R on its first two channels.
    public init(deviceChannelCounts: [Int]) {
        let counts = deviceChannelCounts.filter { $0 > 0 }
        deviceCount = max(1, counts.count)
        sources = counts.isEmpty
            ? [0, 1]
            : counts.flatMap { count in (0..<count).map { $0 < 2 ? $0 : -1 } }
    }

    /// The tapped channel for an output channel, or -1 for silence.
    public func source(forOutputChannel channel: Int) -> Int {
        channel < sources.count ? sources[channel] : -1
    }
}
