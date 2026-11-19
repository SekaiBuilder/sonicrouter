// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SonicRouter",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "SonicRouter", targets: ["SonicRouter"])
    ],
    targets: [
        // Realtime DSP in C++ behind a C interface: everything the Core Audio
        // render thread runs (gain copy, limiter, equalizer and its filter
        // design). See specs/changes/CAM-003-nucleo-tiempo-real-cpp.md.
        .target(
            name: "SonicRouterDSP",
            path: "Sources/SonicRouterDSP",
            linkerSettings: [.linkedFramework("Accelerate")]
        ),
        .target(
            name: "SonicRouterCore",
            dependencies: ["SonicRouterDSP"],
            path: "Sources/SonicRouterCore"
        ),
        .executableTarget(
            name: "SonicRouter",
            dependencies: ["SonicRouterCore"],
            path: "Sources/SonicRouter"
        ),
        // Deliberately an executable rather than a `.testTarget`: SonicRouter
        // builds with just the Command Line Tools, which ship neither XCTest nor
        // the `Testing` module where SwiftPM looks for them (there is no
        // platform path), so `swift test` cannot run there. `Scripts/test.sh`
        // builds and runs this binary instead.
        .executableTarget(
            name: "SonicRouterPolicyTests",
            dependencies: ["SonicRouterCore"],
            path: "Tests/SonicRouterPolicyTests"
        ),
        // Realtime render benchmark with synthetic buffers:
        // `swift run -c release SonicRouterBench`.
        .executableTarget(
            name: "SonicRouterBench",
            dependencies: ["SonicRouterCore"],
            path: "Tests/SonicRouterBench"
        ),
        // Null test with real audio (CAM-001 T4): `swift run SonicRouterNullTest`.
        // Needs the audio-capture permission; `--selftest` does not.
        .executableTarget(
            name: "SonicRouterNullTest",
            path: "Tests/SonicRouterNullTest"
        ),
        // Read-only checks of SonicRouter's Core Audio objects (CAM-002-A17):
        // `swift run SonicRouterAudioTools orphans`.
        .executableTarget(
            name: "SonicRouterAudioTools",
            path: "Tests/SonicRouterAudioTools"
        )
    ],
    cxxLanguageStandard: .cxx20
)
