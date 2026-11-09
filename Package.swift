// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Speak",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Speak", path: "Sources/Speak"),
    ]
)
