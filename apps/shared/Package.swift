// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SO101Protocol",
    platforms: [.iOS(.v17), .watchOS(.v10), .macOS(.v14)],
    products: [
        .library(name: "SO101Protocol", targets: ["SO101Protocol"]),
    ],
    targets: [
        .target(name: "SO101Protocol"),
        .testTarget(
            name: "SO101ProtocolTests",
            dependencies: ["SO101Protocol"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
