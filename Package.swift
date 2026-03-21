// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "djay-pro-bridge",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "DjayBridge",
            path: "Sources/DjayBridge"
        ),
        .executableTarget(
            name: "Reader",
            dependencies: ["DjayBridge"],
            path: "Sources/Reader"
        ),
        .executableTarget(
            name: "Dump",
            dependencies: ["DjayBridge"],
            path: "Sources/Dump"
        ),
    ]
)
