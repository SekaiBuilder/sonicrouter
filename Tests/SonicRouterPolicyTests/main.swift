import CoreAudio
import Darwin
import Foundation
import SonicRouterCore

private struct TestState {
    private(set) var failures: [String] = []
    private(set) var checks = 0

    mutating func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { failures.append(message) }
    }

    mutating func expectClose(_ value: Double, _ expected: Double, tolerance: Double, _ message: String) {
        expect(abs(value - expected) <= tolerance, "\(message) (got \(value), expected \(expected) ± \(tolerance))")
    }
}

private func decibels(_ linear: Double) -> Double {
    20 * log10(linear)
}

private func runPolicyTests(_ tests: inout TestState) {
    let normal = AudioControlIntent(volume: 1, muted: false)
    tests.expect(!normal.requiresEngine, "Normal playback must not allocate an engine")

    let routed = AudioControlIntent(volume: 1, muted: false, outputUID: "device.airpods")
    tests.expect(routed.wantsVolumeEngine, "A full-volume explicit route must keep its engine")

    var unmuted = AudioControlIntent(volume: 1, muted: true, outputUID: "device.airpods")
    unmuted.muted = false
    tests.expect(unmuted.outputUID == "device.airpods", "Unmuting must preserve outputUID")
    tests.expect(unmuted.wantsVolumeEngine, "Unmuting a routed app must restore its volume engine")

    let profile = AudioRouteProfile(
        name: "Music route",
        appName: "Music",
        bundleIdentifier: "com.apple.Music",
        outputDeviceUID: "device.usb",
        volume: 0.42
    )
    let restored = AudioControlIntent(profile: profile)
    tests.expect(restored.volume == 0.42, "Profile volume must be restored")
    tests.expect(restored.outputUID == "device.usb", "Profile output must be restored")
    tests.expect(restored.requiresEngine, "A non-default profile must create an engine")

    tests.expect(AudioControlIntent(volume: -2, muted: false).volume == 0, "Volume must clamp to zero")
    tests.expect(AudioControlIntent(volume: 3, muted: false).volume == 1, "Volume must clamp to one")

    let nilBundleProfile = AudioRouteProfile(
        name: "Unnamed route",
        appName: "Music",
        bundleIdentifier: nil,
        outputDeviceUID: nil,
        volume: 0.5
    )
    tests.expect(
        !AudioProfileMatcher.matches(nilBundleProfile, bundleIdentifier: nil, appName: "FaceTime"),
        "Two nil bundle identifiers must not match unrelated apps"
    )
    tests.expect(
        AudioProfileMatcher.matches(nilBundleProfile, bundleIdentifier: nil, appName: "Music"),
        "Matching app names must restore a bundle-less profile"
    )

    tests.expect(
        AudioProfileMatcher.matches(
            profile,
            bundleIdentifier: "com.apple.Music",
            appName: "Renamed Music"
        ),
        "Bundle identifiers must survive display-name changes"
    )
    tests.expect(
        !AudioProfileMatcher.matches(
            profile,
            bundleIdentifier: "com.example.different",
            appName: "Music"
        ),
        "Conflicting bundle identifiers must not fall back to the display name"
    )

    tests.expect(
        SonicRouterAudioIdentifiers.isInternalDeviceUID("local.sonicrouter.audio.device"),
        "The legacy virtual device must not be user-selectable"
    )
    tests.expect(
        SonicRouterAudioIdentifiers.isInternalDeviceUID("local.sonicrouter.agg.vol.test"),
        "Private aggregate devices must not be user-selectable"
    )
    tests.expect(
        !SonicRouterAudioIdentifiers.isInternalDeviceUID("BuiltInSpeakerDevice"),
        "A physical output must remain user-selectable"
    )

    tests.expect(
        AudioGainPolicy.headroomLimitedGain(requestedGain: 1, inputPeak: 1) == 1,
        "Unity gain must remain unchanged"
    )
    tests.expect(
        AudioGainPolicy.headroomLimitedGain(requestedGain: 1, inputPeak: 3) == 1,
        "Unity gain must pass hot input through at its native level"
    )
    tests.expect(
        AudioGainPolicy.headroomLimitedGain(requestedGain: 0.8, inputPeak: 2) == 0.8,
        "The volume slider must be an exact 1:1 attenuation, never ducked by peaks"
    )
    tests.expect(
        AudioGainPolicy.headroomLimitedGain(requestedGain: 1.8, inputPeak: 0.5) == 1.8,
        "Quiet material may use the requested makeup gain"
    )
    tests.expect(
        AudioGainPolicy.headroomLimitedGain(requestedGain: 1.8, inputPeak: 0.8) == 1.25,
        "Makeup gain must be reduced before a peak clips"
    )
    tests.expect(
        AudioGainPolicy.headroomLimitedGain(requestedGain: 1.8, inputPeak: 2) == 1,
        "The makeup limiter must never dip below the source's native level"
    )
}

private func runEqualizerSettingsTests(_ tests: inout TestState) {
    tests.expect(AudioEqualizerSettings.flat.isFlat, "The default equalizer must be flat")
    tests.expect(
        AudioEqualizerSettings(bass: 40, mid: -40, treble: .nan) == AudioEqualizerSettings(bass: 12, mid: -12, treble: 0),
        "Equalizer gains must be clamped to ±12 dB and finite"
    )
    var edited = AudioEqualizerSettings.flat
    edited[.mid] = 99
    tests.expect(edited.mid == 12, "Band edits must be clamped")

    let boosted = AudioControlIntent(volume: 1, muted: false, equalizer: AudioEqualizerSettings(bass: 4))
    tests.expect(boosted.wantsVolumeEngine, "A non-flat equalizer must keep the re-emit engine at full volume")
    let mutedBoost = AudioControlIntent(volume: 1, muted: true, equalizer: AudioEqualizerSettings(bass: 4))
    tests.expect(mutedBoost.wantsMute && !mutedBoost.wantsVolumeEngine, "Mute must win over the equalizer")
    tests.expect(
        !AudioControlIntent(volume: 1, muted: false, equalizer: AudioEqualizerSettings(treble: 0.01)).requiresEngine,
        "An inaudible equalizer must keep the native path"
    )

    let profile = AudioRouteProfile(
        name: "Podcasts route",
        appName: "Podcasts",
        bundleIdentifier: "com.apple.podcasts",
        outputDeviceUID: nil,
        volume: 1,
        equalizer: AudioEqualizerSettings(treble: -3)
    )
    tests.expect(AudioControlIntent(profile: profile).equalizer.treble == -3, "Profiles must restore the equalizer")

    let legacyJSON = Data(#"{"id":"6F1E1C8A-4C62-4A4E-9C1D-2B7A51C8D001","name":"Music route","appName":"Music","bundleIdentifier":"com.apple.Music","volume":0.5}"#.utf8)
    let legacy = try? JSONDecoder().decode(AudioRouteProfile.self, from: legacyJSON)
    tests.expect(legacy != nil && legacy?.equalizer == nil, "Profiles saved before the equalizer must still decode, as flat")

    let hostileJSON = Data(#"{"bass":30,"treble":-99}"#.utf8)
    let hostile = try? JSONDecoder().decode(AudioEqualizerSettings.self, from: hostileJSON)
    tests.expect(
        hostile == AudioEqualizerSettings(bass: 12, mid: 0, treble: -12),
        "Decoded equalizer gains must be clamped and missing bands default to 0 dB"
    )
}

private func runFilterDesignTests(_ tests: inout TestState) {
    for band in EqualizerBand.allCases {
        tests.expect(
            band.coefficients(gainDB: 0, sampleRate: 48_000) == .identity,
            "A 0 dB \(band) band must be an exact identity"
        )
    }

    var everyFilterStable = true
    for rate in [8_000.0, 16_000, 22_050, 44_100, 48_000, 96_000, 192_000] {
        for band in EqualizerBand.allCases {
            for gain in stride(from: -12.0, through: 12.0, by: 1.5) {
                let filter = band.coefficients(gainDB: gain, sampleRate: rate)
                let finite = [filter.b0, filter.b1, filter.b2, filter.a1, filter.a2].allSatisfy(\.isFinite)
                if !finite || !filter.isStable { everyFilterStable = false }
            }
        }
    }
    tests.expect(everyFilterStable, "Every band must stay stable at every gain and sample rate, including 8 kHz call audio")

    let rate = 48_000.0
    let mid = EqualizerBand.mid.coefficients(gainDB: 6, sampleRate: rate)
    tests.expectClose(decibels(mid.magnitude(at: 1_000, sampleRate: rate)), 6, tolerance: 0.01, "The mid band must reach its gain at 1 kHz")
    tests.expectClose(decibels(mid.magnitude(at: 20, sampleRate: rate)), 0, tolerance: 0.1, "The mid band must leave deep bass alone")

    let bass = EqualizerBand.bass.coefficients(gainDB: 9, sampleRate: rate)
    tests.expectClose(decibels(bass.magnitude(at: 0, sampleRate: rate)), 9, tolerance: 0.01, "The bass shelf must reach its gain at DC")
    tests.expectClose(decibels(bass.magnitude(at: 100, sampleRate: rate)), 4.5, tolerance: 0.05, "The bass shelf must be halfway at 100 Hz")
    tests.expectClose(decibels(bass.magnitude(at: 5_000, sampleRate: rate)), 0, tolerance: 0.05, "The bass shelf must leave the treble alone")

    let treble = EqualizerBand.treble.coefficients(gainDB: -6, sampleRate: rate)
    tests.expectClose(decibels(treble.magnitude(at: 23_999, sampleRate: rate)), -6, tolerance: 0.05, "The treble shelf must reach its gain at Nyquist")
    tests.expectClose(decibels(treble.magnitude(at: 8_000, sampleRate: rate)), -3, tolerance: 0.05, "The treble shelf must be halfway at 8 kHz")
    tests.expectClose(decibels(treble.magnitude(at: 200, sampleRate: rate)), 0, tolerance: 0.05, "The treble shelf must leave the bass alone")

    let identity = BiquadCoefficients.identity
    tests.expect(
        EqualizerHeadroom.preampGain(identity, identity, identity, sampleRate: rate) == 1,
        "A flat equalizer must not change the level"
    )
    let cuts = EqualizerHeadroom.preampGain(
        EqualizerBand.bass.coefficients(gainDB: -6, sampleRate: rate),
        EqualizerBand.mid.coefficients(gainDB: -3, sampleRate: rate),
        identity,
        sampleRate: rate
    )
    tests.expectClose(cuts, 1, tolerance: 1e-9, "Cuts alone must never raise or lower the overall level")
    let boost = EqualizerHeadroom.preampGain(
        EqualizerBand.bass.coefficients(gainDB: 12, sampleRate: rate),
        identity,
        identity,
        sampleRate: rate
    )
    tests.expectClose(decibels(boost), -12, tolerance: 0.01, "The preamp must undo the loudest boost")
    let overlapping = EqualizerHeadroom.preampGain(
        EqualizerBand.bass.coefficients(gainDB: 12, sampleRate: rate),
        EqualizerBand.mid.coefficients(gainDB: 12, sampleRate: rate),
        EqualizerBand.treble.coefficients(gainDB: 12, sampleRate: rate),
        sampleRate: rate
    )
    tests.expect(decibels(overlapping) <= -12, "Overlapping boosts must be compensated by at least the largest band")
}

/// Runs a steady sine through `processor` in 512-frame cycles and returns the
/// output/input RMS ratio measured after the start-up transient.
private func measuredGain(of processor: RealtimeEqualizer, at frequency: Double) -> Double {
    let frames = 512
    let cycles = 200
    var phase = 0.0
    let increment = 2 * Double.pi * frequency / processor.sampleRate
    var inputEnergy = 0.0
    var outputEnergy = 0.0
    var buffer = [Float](repeating: 0, count: frames * 2)
    for cycle in 0..<cycles {
        for frame in 0..<frames {
            let sample = Float(0.5 * sin(phase))
            phase += increment
            buffer[frame * 2] = sample
            buffer[frame * 2 + 1] = sample
        }
        let input = buffer
        if processor.beginCycle() {
            buffer.withUnsafeMutableBufferPointer { pointer in
                processor.process(pointer.baseAddress!, frameCount: frames, channelCount: 2, firstChannel: 0)
            }
        }
        if cycle >= cycles / 2 {
            for frame in 0..<frames {
                inputEnergy += Double(input[frame * 2] * input[frame * 2])
                outputEnergy += Double(buffer[frame * 2] * buffer[frame * 2])
            }
        }
    }
    return (outputEnergy / inputEnergy).squareRoot()
}

private func runRealtimeEqualizerTests(_ tests: inout TestState) {
    let rate = 48_000.0
    let settings = AudioEqualizerSettings(bass: 12)
    let bassFilter = EqualizerBand.bass.coefficients(gainDB: 12, sampleRate: rate)
    let preamp = EqualizerHeadroom.preampGain(bassFilter, .identity, .identity, sampleRate: rate)
    for frequency in [60.0, 400, 5_000] {
        let processor = RealtimeEqualizer(parameters: EqualizerParameters(settings), sampleRate: rate)
        let expected = decibels(bassFilter.magnitude(at: frequency, sampleRate: rate) * preamp)
        tests.expectClose(
            decibels(measuredGain(of: processor, at: frequency)),
            expected,
            tolerance: 0.05,
            "The render path must match the designed response at \(Int(frequency)) Hz"
        )
    }

    // Planar buffers (one per channel) and interleaved stereo must filter alike.
    let curve = AudioEqualizerSettings(bass: 6, mid: -4, treble: 3)
    let interleaved = RealtimeEqualizer(parameters: EqualizerParameters(curve), sampleRate: rate)
    let planar = RealtimeEqualizer(parameters: EqualizerParameters(curve), sampleRate: rate)
    var seed: UInt32 = 0x5EED
    func noise() -> Float {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        return Float(seed >> 8) / Float(1 << 24) * 2 - 1
    }
    var identical = true
    for _ in 0..<6 {
        let frames = 256
        var stereo = [Float](repeating: 0, count: frames * 2)
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        for frame in 0..<frames {
            left[frame] = noise()
            right[frame] = noise()
            stereo[frame * 2] = left[frame]
            stereo[frame * 2 + 1] = right[frame]
        }
        if interleaved.beginCycle() {
            stereo.withUnsafeMutableBufferPointer {
                interleaved.process($0.baseAddress!, frameCount: frames, channelCount: 2, firstChannel: 0)
            }
        }
        if planar.beginCycle() {
            left.withUnsafeMutableBufferPointer {
                planar.process($0.baseAddress!, frameCount: frames, channelCount: 1, firstChannel: 0)
            }
            right.withUnsafeMutableBufferPointer {
                planar.process($0.baseAddress!, frameCount: frames, channelCount: 1, firstChannel: 1)
            }
        }
        for frame in 0..<frames where stereo[frame * 2] != left[frame] || stereo[frame * 2 + 1] != right[frame] {
            identical = false
        }
    }
    tests.expect(identical, "Planar and interleaved layouts must produce identical output")

    // Gliding in and out, then a bit-exact bypass.
    let parameters = EqualizerParameters(.flat)
    let glide = RealtimeEqualizer(parameters: parameters, sampleRate: rate)
    tests.expect(!glide.beginCycle(), "A flat equalizer must be bypassed")
    parameters.settings = AudioEqualizerSettings(treble: -9)
    tests.expect(glide.beginCycle(), "Changing a band must engage the filters")
    tests.expect(glide.appliedSettings.treble == -RealtimeEqualizer.maxStepDB, "Gain changes must glide instead of jumping")
    for _ in 0..<10 { _ = glide.beginCycle() }
    tests.expect(glide.appliedSettings.treble == -9, "The glide must reach its target")
    parameters.settings = .flat
    var activeCycles = 0
    while glide.beginCycle(), activeCycles < 100 { activeCycles += 1 }
    tests.expect(activeCycles < 20, "Returning to flat must end in a bit-exact bypass")

    // Hostile input must never turn into NaN, Inf or runaway gain.
    let stress = RealtimeEqualizer(
        parameters: EqualizerParameters(AudioEqualizerSettings(bass: 12, mid: 12, treble: 12)),
        sampleRate: 8_000
    )
    var bounded = true
    for cycle in 0..<50 {
        var block = (0..<256).map { index -> Float in
            cycle.isMultiple(of: 2) ? 1 : (index.isMultiple(of: 2) ? 1 : -1)
        }
        if stress.beginCycle() {
            block.withUnsafeMutableBufferPointer {
                stress.process($0.baseAddress!, frameCount: 256, channelCount: 1, firstChannel: 0)
            }
        }
        if !block.allSatisfy({ $0.isFinite && abs($0) < 4 }) { bounded = false }
    }
    tests.expect(bounded, "Full-scale DC and Nyquist input must stay finite and bounded")
}

private func runProfileArchiveTests(_ tests: inout TestState) {
    let music = AudioRouteProfile(
        name: "Music route",
        appName: "Music",
        bundleIdentifier: "com.apple.Music",
        outputDeviceUID: "device.usb",
        volume: 0.4,
        equalizer: AudioEqualizerSettings(bass: 3)
    )
    let chrome = AudioRouteProfile(
        name: "Chrome route",
        appName: "Google Chrome",
        bundleIdentifier: "com.google.Chrome",
        outputDeviceUID: nil,
        volume: 0.8
    )

    let exported = try? AudioProfileArchive(profiles: [music, chrome]).encoded()
    let roundTrip = exported.flatMap { try? AudioProfileArchive.decodeProfiles(from: $0) }
    tests.expect(roundTrip == [music, chrome], "An export must import back unchanged")

    let bareArray = try? JSONEncoder().encode([chrome])
    tests.expect(
        bareArray.flatMap { try? AudioProfileArchive.decodeProfiles(from: $0) } == [chrome],
        "A bare JSON array of profiles must be accepted"
    )

    func error(for json: String) -> AudioProfileArchiveError? {
        do {
            _ = try AudioProfileArchive.decodeProfiles(from: Data(json.utf8))
            return nil
        } catch {
            return error as? AudioProfileArchiveError
        }
    }
    tests.expect(error(for: "not json") == .unrecognizedFormat, "Garbage must be rejected")
    tests.expect(
        error(for: #"{"format":"com.example.other","version":1,"profiles":[]}"#) == .unrecognizedFormat,
        "Another app's file must be rejected"
    )
    tests.expect(
        error(for: #"{"format":"local.sonicrouter.profiles","version":2,"profiles":[]}"#) == .unsupportedVersion(2),
        "A file from a newer SonicRouter must be rejected with its version"
    )
    tests.expect(
        error(for: #"{"format":"local.sonicrouter.profiles","version":1,"profiles":[]}"#) == .noProfiles,
        "An export with no profiles must be reported as empty"
    )

    var loud = chrome
    loud.volume = 7
    var nameless = chrome
    nameless.appName = "  "
    nameless.bundleIdentifier = ""
    var duplicate = chrome
    duplicate.volume = 0.3
    let cleaned = AudioProfileArchive.sanitized([loud, nameless, duplicate])
    tests.expect(cleaned.count == 1, "Nameless entries must be dropped and duplicates collapsed")
    tests.expect(cleaned.first?.volume == 0.3, "The last duplicate must win")
    tests.expect(AudioProfileArchive.sanitized([loud]).first?.volume == 1, "Imported volumes must be clamped")

    var importedMusic = music
    importedMusic.id = UUID()
    importedMusic.volume = 0.2
    let safari = AudioRouteProfile(
        name: "Safari route",
        appName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        outputDeviceUID: nil,
        volume: 0.6
    )
    let merged = AudioProfileMerge.merge(existing: [music, chrome], imported: [importedMusic, safari])
    tests.expect(merged.added == 1 && merged.replaced == 1, "Merging must count added and replaced profiles")
    tests.expect(merged.profiles.count == 3, "Merging must not duplicate an app")
    tests.expect(
        merged.profiles.first { $0.bundleIdentifier == "com.apple.Music" }?.volume == 0.2,
        "Imported settings must win over saved ones"
    )
    tests.expect(
        merged.profiles.first { $0.bundleIdentifier == "com.apple.Music" }?.id == music.id,
        "A replaced profile must keep its identity"
    )
    let again = AudioProfileMerge.merge(existing: merged.profiles, imported: [importedMusic, safari])
    tests.expect(again.added == 0 && again.profiles.count == 3, "Importing the same file twice must not add rows")
}

private func runMultiOutputPlanTests(_ tests: inout TestState) {
    let lg = MultiOutputMember(uid: "hdmi.lg", name: "LG HDR WFHD", isBuiltIn: false, supportedSampleRates: [48_000...48_000])
    let speakers = MultiOutputMember(
        uid: "builtin.speakers",
        name: "MacBook Air Speakers",
        isBuiltIn: true,
        supportedSampleRates: [44_100...44_100, 48_000...48_000, 88_200...88_200, 96_000...96_000]
    )
    let ordered = MultiOutputPlan.orderedMembers([lg, speakers])
    tests.expect(ordered.map(\.uid) == ["builtin.speakers", "hdmi.lg"], "The built-in output must be the clock")
    tests.expect(MultiOutputPlan.orderedMembers([lg]).isEmpty, "One output is not a multi-output device")
    tests.expect(MultiOutputPlan.orderedMembers([lg, lg]).isEmpty, "Duplicates must not count as two outputs")
    tests.expect(MultiOutputPlan.sharedSampleRate(for: ordered) == 48_000, "LG + MacBook must share 48 kHz")

    let cd = MultiOutputMember(uid: "usb.cd", name: "USB DAC", isBuiltIn: false, supportedSampleRates: [44_100...44_100])
    tests.expect(MultiOutputPlan.sharedSampleRate(for: [speakers, cd]) == 44_100, "The first shared rate must win")
    tests.expect(MultiOutputPlan.sharedSampleRate(for: [lg, cd]) == nil, "No shared rate must be reported as nil")
    tests.expect(
        !SonicRouterAudioIdentifiers.isInternalDeviceUID(MultiOutputPlan.deviceUID),
        "The multi-output device must stay visible and survive launch cleanup"
    )
}

private func runOutputChannelMapTests(_ tests: inout TestState) {
    let single = OutputChannelMap(deviceChannelCounts: [2])
    tests.expect(single.deviceCount == 1, "One device must keep the fast path")
    tests.expect(single.source(forOutputChannel: 0) == 0 && single.source(forOutputChannel: 1) == 1, "Stereo must map 1:1")
    tests.expect(single.source(forOutputChannel: 2) == -1, "Channels past the device must stay silent")

    let pair = OutputChannelMap(deviceChannelCounts: [2, 2])
    tests.expect(pair.deviceCount == 2, "Two devices must fan out")
    tests.expect(
        (0..<4).map(pair.source(forOutputChannel:)) == [0, 1, 0, 1],
        "Each device must get L/R on its own first two channels"
    )

    let surround = OutputChannelMap(deviceChannelCounts: [2, 6])
    tests.expect(
        (0..<8).map(surround.source(forOutputChannel:)) == [0, 1, 0, 1, -1, -1, -1, -1],
        "Extra channels on a multichannel device must stay silent"
    )

    let unknown = OutputChannelMap(deviceChannelCounts: [])
    tests.expect(unknown.deviceCount == 1 && unknown.source(forOutputChannel: 1) == 1, "Unknown layouts must fall back to stereo")
}

// MARK: - CAM-001: transparent re-emission

/// Deterministic test signal: full-scale edges, tiny and subnormal values,
/// signed zero and a pseudo-random spread in [-1, 1].
private func renderTestSamples(count: Int, seed: UInt32) -> [Float] {
    let edges: [Float] = [1, -1, 0, -0.0, .leastNonzeroMagnitude, -.leastNormalMagnitude, 0.5, -0.999_999_9, 1e-30]
    var state = seed
    return (0..<count).map { index in
        if index < edges.count { return edges[index] }
        state = state &* 1_664_525 &+ 1_013_904_223
        return Float(Int32(bitPattern: state)) / Float(Int32.max)
    }
}

/// Owns a buffer list with one buffer per entry of `layout` (channels per
/// buffer) and `frames` frames each, filled from `samples` or zeroed.
private final class TestBufferList {
    let list: UnsafeMutableAudioBufferListPointer
    private let storage: [UnsafeMutablePointer<Float>]

    init(layout: [Int], frames: Int, samples: [[Float]]? = nil) {
        list = AudioBufferList.allocate(maximumBuffers: layout.count)
        var owned: [UnsafeMutablePointer<Float>] = []
        for (index, channels) in layout.enumerated() {
            let count = channels * frames
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: count)
            pointer.initialize(repeating: 0x1p-3, count: count) // garbage the renderer must overwrite
            if let samples { for i in 0..<count { pointer[i] = samples[index][i] } }
            list[index] = AudioBuffer(
                mNumberChannels: UInt32(channels),
                mDataByteSize: UInt32(count * MemoryLayout<Float>.stride),
                mData: UnsafeMutableRawPointer(pointer)
            )
            owned.append(pointer)
        }
        storage = owned
    }

    deinit {
        for pointer in storage { pointer.deallocate() }
        free(list.unsafeMutablePointer)
    }

    func samples(_ buffer: Int) -> [Float] {
        let count = Int(list[buffer].mDataByteSize) / MemoryLayout<Float>.stride
        return Array(UnsafeBufferPointer(start: storage[buffer], count: count))
    }
}

private func render(
    input: TestBufferList,
    output: TestBufferList,
    gain: Float,
    channelMap: OutputChannelMap = OutputChannelMap(deviceChannelCounts: [2])
) {
    let equalizer = RealtimeEqualizer(parameters: EqualizerParameters(.flat), sampleRate: 48_000)
    StereoRender.copy(
        input: UnsafePointer(input.list.unsafePointer),
        output: output.list.unsafeMutablePointer,
        requestedGain: gain,
        limiter: RealtimeGainLimiter(initialGain: gain),
        equalizer: equalizer,
        channelMap: channelMap
    )
}

private func bits(_ values: [Float]) -> [UInt32] { values.map(\.bitPattern) }

private func runRealtimeRenderTests(_ tests: inout TestState) {
    let frames = 512

    // CAM-001-A01: unity gain, flat EQ → byte-identical, interleaved and planar.
    let interleaved = [renderTestSamples(count: 2 * frames, seed: 1)]
    let inInterleaved = TestBufferList(layout: [2], frames: frames, samples: interleaved)
    let outInterleaved = TestBufferList(layout: [2], frames: frames)
    render(input: inInterleaved, output: outInterleaved, gain: 1)
    tests.expect(bits(outInterleaved.samples(0)) == bits(interleaved[0]), "CAM-001-A01: interleaved unity copy must be bit-exact")

    let planar = [renderTestSamples(count: frames, seed: 2), renderTestSamples(count: frames, seed: 3)]
    let inPlanar = TestBufferList(layout: [1, 1], frames: frames, samples: planar)
    let outPlanar = TestBufferList(layout: [1, 1], frames: frames)
    render(input: inPlanar, output: outPlanar, gain: 1)
    tests.expect(
        bits(outPlanar.samples(0)) == bits(planar[0]) && bits(outPlanar.samples(1)) == bits(planar[1]),
        "CAM-001-A01: planar unity copy must be bit-exact"
    )

    let multichannel = [renderTestSamples(count: 6 * frames, seed: 4)]
    let inSix = TestBufferList(layout: [6], frames: frames, samples: multichannel)
    let outSix = TestBufferList(layout: [6], frames: frames)
    render(input: inSix, output: outSix, gain: 1)
    tests.expect(bits(outSix.samples(0)) == bits(multichannel[0]), "CAM-001-A01: matching 6-channel layout must copy bit-exact")

    // CAM-001-A02 / R04: gain g ≤ 1 → every sample is exactly input × g.
    for gain: Float in [0.5, 0.37, 0.99, 0.000_1] {
        let out = TestBufferList(layout: [2], frames: frames)
        render(input: inInterleaved, output: out, gain: gain)
        tests.expect(
            bits(out.samples(0)) == bits(interleaved[0].map { $0 * gain }),
            "CAM-001-A02: interleaved samples must be exactly input × \(gain)"
        )
        let outP = TestBufferList(layout: [1, 1], frames: frames)
        render(input: inPlanar, output: outP, gain: gain)
        tests.expect(
            bits(outP.samples(0)) == bits(planar[0].map { $0 * gain })
                && bits(outP.samples(1)) == bits(planar[1].map { $0 * gain }),
            "CAM-001-A02: planar samples must be exactly input × \(gain)"
        )
    }

    // Multi-output map: each device gets L/R scaled exactly, extra channels silent.
    let outPair = TestBufferList(layout: [2, 2], frames: frames)
    render(input: inInterleaved, output: outPair, gain: 0.5, channelMap: OutputChannelMap(deviceChannelCounts: [2, 2]))
    let expectedPair = bits(interleaved[0].map { $0 * 0.5 })
    tests.expect(
        bits(outPair.samples(0)) == expectedPair && bits(outPair.samples(1)) == expectedPair,
        "Multi-output: both devices must receive input × gain bit-exact"
    )

    // Zero gain renders silence; output never keeps stale buffer contents.
    let silent = TestBufferList(layout: [2], frames: frames)
    render(input: inInterleaved, output: silent, gain: 0)
    tests.expect(silent.samples(0).allSatisfy { $0 == 0 }, "Zero gain must render silence")

    // The limiter passes every gain at or below unity through untouched.
    let limiter = RealtimeGainLimiter(initialGain: 1)
    tests.expect(
        [Float(1), 0.99, 0.5, 0].allSatisfy { limiter.gain(requestedGain: $0, inputPeak: 1) == $0 },
        "CAM-001-R04: the limiter must not touch gains ≤ 1"
    )
}

private func floatFormat(channels: UInt32, planar: Bool = false) -> AudioStreamBasicDescription {
    var flags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
    if planar { flags |= kAudioFormatFlagIsNonInterleaved }
    let sampleBytes: UInt32 = 4
    return AudioStreamBasicDescription(
        mSampleRate: 48_000,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: flags,
        mBytesPerPacket: planar ? sampleBytes : sampleBytes * channels,
        mFramesPerPacket: 1,
        mBytesPerFrame: planar ? sampleBytes : sampleBytes * channels,
        mChannelsPerFrame: channels,
        mBitsPerChannel: 32,
        mReserved: 0
    )
}

private func runRenderFormatCheckTests(_ tests: inout TestState) {
    let stereo = floatFormat(channels: 2)
    tests.expect(RenderFormatCheck.problem(tap: stereo, outputs: [stereo]) == nil, "Float32 stereo must be accepted")
    tests.expect(
        RenderFormatCheck.problem(tap: stereo, outputs: [floatFormat(channels: 2, planar: true)]) == nil,
        "Planar Float32 output must be accepted"
    )
    tests.expect(
        RenderFormatCheck.problem(tap: stereo, outputs: [stereo, floatFormat(channels: 6)]) == nil,
        "Mixdown tap may fan out to more output channels"
    )

    // CAM-001-A06 / R05: anything StereoRender cannot copy verbatim is refused.
    var int16 = stereo
    int16.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
    int16.mBitsPerChannel = 16
    int16.mBytesPerFrame = 4
    tests.expect(RenderFormatCheck.problem(tap: int16, outputs: [stereo]) == .tapNotFloat32, "CAM-001-A06: Int16 tap must be refused")
    tests.expect(RenderFormatCheck.problem(tap: stereo, outputs: [int16]) == .outputNotFloat32, "CAM-001-A06: Int16 output must be refused")

    var float64 = stereo
    float64.mBitsPerChannel = 64
    float64.mBytesPerFrame = 16
    tests.expect(RenderFormatCheck.problem(tap: float64, outputs: [stereo]) == .tapNotFloat32, "CAM-001-A06: Float64 tap must be refused")

    var bigEndian = stereo
    bigEndian.mFormatFlags |= kAudioFormatFlagIsBigEndian
    tests.expect(RenderFormatCheck.problem(tap: stereo, outputs: [bigEndian]) == .outputNotFloat32, "CAM-001-A06: big-endian output must be refused")

    var badFrame = stereo
    badFrame.mBytesPerFrame = 4
    tests.expect(RenderFormatCheck.problem(tap: badFrame, outputs: [stereo]) == .tapNotFloat32, "CAM-001-A06: inconsistent frame size must be refused")

    var encoded = stereo
    encoded.mFormatID = kAudioFormatAC3
    tests.expect(RenderFormatCheck.problem(tap: stereo, outputs: [encoded]) == .outputNotFloat32, "CAM-001-A06: encoded output must be refused")

    tests.expect(RenderFormatCheck.problem(tap: stereo, outputs: []) == .noChannels, "No output streams must be refused")

    tests.expect(
        RenderFormatCheck.problem(tap: floatFormat(channels: 6), outputs: [stereo], oneToOne: true)
            == .channelMismatch(tap: 6, output: 2),
        "CAM-001-R05: one-to-one rendering must refuse a channel mismatch"
    )
    tests.expect(
        RenderFormatCheck.problem(tap: floatFormat(channels: 6), outputs: [floatFormat(channels: 6)], oneToOne: true) == nil,
        "One-to-one rendering must accept matching channels"
    )
}

private var tests = TestState()
runPolicyTests(&tests)
runEqualizerSettingsTests(&tests)
runFilterDesignTests(&tests)
runRealtimeEqualizerTests(&tests)
runProfileArchiveTests(&tests)
runMultiOutputPlanTests(&tests)
runOutputChannelMapTests(&tests)
runRealtimeRenderTests(&tests)
runRenderFormatCheckTests(&tests)

if tests.failures.isEmpty {
    print("SonicRouter policy tests passed: \(tests.checks) checks")
} else {
    for failure in tests.failures { fputs("FAIL: \(failure)\n", stderr) }
    exit(EXIT_FAILURE)
}
