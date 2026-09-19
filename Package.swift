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
        .target(
            name: "SonicRouterCore",
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
        )
    ]
)
