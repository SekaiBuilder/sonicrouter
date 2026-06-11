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
        .executableTarget(
            name: "SonicRouter",
            path: "Sources/SonicRouter"
        )
    ]
)
