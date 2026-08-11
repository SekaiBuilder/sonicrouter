import Darwin
import SonicRouterCore

private struct TestState {
    private(set) var failures: [String] = []
    private(set) var checks = 0

    mutating func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { failures.append(message) }
    }
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

private var tests = TestState()
runPolicyTests(&tests)

if tests.failures.isEmpty {
    print("SonicRouter policy tests passed: \(tests.checks) checks")
} else {
    for failure in tests.failures { fputs("FAIL: \(failure)\n", stderr) }
    exit(EXIT_FAILURE)
}
