// swift-tools-version: 6.2
import PackageDescription

/// Approachable Concurrency: async fonksiyonlar çağıranın aktöründe çalışır,
/// arka plana geçiş yalnızca @concurrent ile açıkça yapılır.
let approachable: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

let package = Package(
    name: "SoundScript",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SoundScriptCore", targets: ["SoundScriptCore"]),
        .executable(name: "soundscript", targets: ["soundscript"]),
        .executable(name: "SoundScriptApp", targets: ["SoundScriptApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.1.1"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "SoundScriptCore",
            dependencies: [.product(name: "WhisperKit", package: "WhisperKit")],
            swiftSettings: approachable
        ),
        .executableTarget(
            name: "soundscript",
            dependencies: [
                "SoundScriptCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: approachable
        ),
        .executableTarget(
            name: "SoundScriptApp",
            dependencies: ["SoundScriptCore"],
            swiftSettings: approachable + [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "SoundScriptCoreTests", dependencies: ["SoundScriptCore"]),
    ]
)
