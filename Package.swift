// swift-tools-version: 5.9

import PackageDescription
import Foundation

// Resolve absolute paths for whisper.cpp build artifacts
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let whisperInclude = "\(packageDir)/whisper.cpp/include"
let ggmlInclude = "\(packageDir)/whisper.cpp/ggml/include"
let whisperLibDir = "\(packageDir)/whisper.cpp/build/src"
let ggmlLibDir = "\(packageDir)/whisper.cpp/build/ggml/src"
let ggmlMetalLibDir = "\(packageDir)/whisper.cpp/build/ggml/src/ggml-metal"
let ggmlBlasLibDir = "\(packageDir)/whisper.cpp/build/ggml/src/ggml-blas"

let package = Package(
    name: "Speak",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Speak", targets: ["Speak"]),
        .executable(name: "SpeakBenchmark", targets: ["SpeakBenchmark"]),
    ],
    targets: [
        // C module wrapping whisper.cpp headers + prebuilt static libraries
        .target(
            name: "CWhisper",
            path: "Sources/CWhisper",
            cSettings: [
                .headerSearchPath("../../whisper.cpp/include"),
                .headerSearchPath("../../whisper.cpp/ggml/include"),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(whisperLibDir)",
                    "-L\(ggmlLibDir)",
                    "-L\(ggmlMetalLibDir)",
                    "-L\(ggmlBlasLibDir)",
                ]),
                .unsafeFlags([
                    "-lwhisper",
                    "-lggml",
                    "-lggml-base",
                    "-lggml-cpu",
                    "-lggml-metal",
                    "-lggml-blas",
                ]),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Foundation"),
                .linkedLibrary("c++"),
            ]
        ),

        // Main app
        .executableTarget(
            name: "Speak",
            dependencies: ["CWhisper"],
            path: "Sources/Speak",
            swiftSettings: [
                .unsafeFlags([
                    "-I\(whisperInclude)",
                    "-I\(ggmlInclude)",
                ]),
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Carbon"),
            ]
        ),

        // Benchmark CLI
        .executableTarget(
            name: "SpeakBenchmark",
            dependencies: ["CWhisper"],
            path: "Sources/SpeakBenchmark",
            swiftSettings: [
                .unsafeFlags([
                    "-I\(whisperInclude)",
                    "-I\(ggmlInclude)",
                ]),
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
            ]
        ),

        .testTarget(
            name: "SpeakTests",
            dependencies: ["Speak"],
            path: "Tests/SpeakTests"
        ),
    ]
)
