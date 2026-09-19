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

private var tests = TestState()
runPolicyTests(&tests)
runEqualizerSettingsTests(&tests)
runFilterDesignTests(&tests)
runRealtimeEqualizerTests(&tests)
runProfileArchiveTests(&tests)

if tests.failures.isEmpty {
    print("SonicRouter policy tests passed: \(tests.checks) checks")
} else {
    for failure in tests.failures { fputs("FAIL: \(failure)\n", stderr) }
    exit(EXIT_FAILURE)
}
