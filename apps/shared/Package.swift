// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SO101Protocol",
    platforms: [.iOS(.v17), .watchOS(.v10), .macOS(.v14)],
    products: [
        .library(name: "SO101Protocol", targets: ["SO101Protocol"]),
        .library(name: "SO101Voice", targets: ["SO101Voice"]),
        .library(name: "SO101Link", targets: ["SO101Link"]),
        .library(name: "SO101WatchKit", targets: ["SO101WatchKit"]),
    ],
    targets: [
        .target(name: "SO101Protocol"),
        .target(name: "SO101Voice", dependencies: ["SO101Protocol"]),
        .target(name: "SO101Link", dependencies: ["SO101Protocol", "SO101Voice"]),
        .target(name: "SO101WatchKit", dependencies: ["SO101Protocol", "SO101Voice", "SO101Link"]),
        .testTarget(
            name: "SO101ProtocolTests",
            dependencies: ["SO101Protocol"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "SO101VoiceTests", dependencies: ["SO101Voice"]),
        .testTarget(name: "SO101LinkTests", dependencies: ["SO101Link"]),
        .testTarget(name: "SO101WatchKitTests", dependencies: ["SO101WatchKit"]),
    ]
)
