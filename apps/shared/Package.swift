// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SO101Protocol",
    platforms: [.iOS(.v17), .watchOS(.v10), .macOS(.v14)],
    products: [
        .library(name: "SO101Protocol", targets: ["SO101Protocol"]),
        .library(name: "SO101Voice", targets: ["SO101Voice"]),
    ],
    targets: [
        .target(name: "SO101Protocol"),
        .target(name: "SO101Voice", dependencies: ["SO101Protocol"]),
        .testTarget(
            name: "SO101ProtocolTests",
            dependencies: ["SO101Protocol"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "SO101VoiceTests", dependencies: ["SO101Voice"]),
    ]
)
