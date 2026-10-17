import Foundation

/// An output that can join a native multi-output device.
public struct MultiOutputMember: Equatable, Sendable {
    public let uid: String
    public let name: String
    public let isBuiltIn: Bool
    /// Nominal rates the device accepts, as CoreAudio reports them.
    public let supportedSampleRates: [ClosedRange<Double>]

    public init(uid: String, name: String, isBuiltIn: Bool, supportedSampleRates: [ClosedRange<Double>]) {
        self.uid = uid
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.supportedSampleRates = supportedSampleRates
    }

    func supports(_ rate: Double) -> Bool {
        supportedSampleRates.contains { $0.contains(rate) }
    }
}

/// How SonicRouter builds the system-wide multi-output device: a stacked,
/// public aggregate that macOS plays natively on every member, with no tap and
/// no re-emission in between.
public enum MultiOutputPlan {
    /// Not under `aggregateDeviceUIDPrefix`: launch cleanup must leave the
    /// user's multi-output device alone, and the device lists must show it.
    public static let deviceUID = "local.sonicrouter.multioutput"
    /// Tried in order; 48 kHz first because HDMI/DisplayPort displays and
    /// most USB/Bluetooth outputs run there natively.
    public static let preferredSampleRates: [Double] = [48_000, 44_100, 96_000, 88_200]

    /// Members in aggregate order. The first one is the clock: the built-in
    /// output when present (its clock is the steadiest), otherwise the
    /// selection order. Every later member gets drift compensation.
    public static func orderedMembers(_ members: [MultiOutputMember]) -> [MultiOutputMember] {
        var seen = Set<String>()
        let unique = members.filter { seen.insert($0.uid).inserted }
        guard unique.count >= 2 else { return [] }
        guard let clockIndex = unique.firstIndex(where: \.isBuiltIn) else { return unique }
        var ordered = unique
        ordered.insert(ordered.remove(at: clockIndex), at: 0)
        return ordered
    }

    /// A rate every member accepts, so no member has to resample. `nil` when
    /// they share none of the preferred rates; drift compensation still
    /// keeps them in sync, just with resampling.
    public static func sharedSampleRate(for members: [MultiOutputMember]) -> Double? {
        guard !members.isEmpty else { return nil }
        return preferredSampleRates.first { rate in members.allSatisfy { $0.supports(rate) } }
    }
}
