// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "djay-pro-bridge",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.38.1"),
    ],
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
        .target(
            name: "SystemOneProbeSupport",
            dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")],
            path: "Sources/SystemOneProbeSupport"
        ),
        .executableTarget(
            name: "SystemOneProbe",
            dependencies: ["SystemOneProbeSupport"],
            path: "Sources/SystemOneProbe"
        ),
        .executableTarget(
            name: "SystemOneInspector",
            dependencies: ["SystemOneProbeSupport"],
            path: "Sources/SystemOneInspector"
        ),
        .executableTarget(
            name: "SystemOneCapture",
            dependencies: ["SystemOneProbeSupport"],
            path: "Sources/SystemOneCapture"
        ),
        .testTarget(
            name: "SystemOneInspectorTests",
            dependencies: ["SystemOneInspector", "SystemOneProbeSupport"]
        ),
        .testTarget(
            name: "SystemOneProbeSupportTests",
            dependencies: ["SystemOneProbeSupport"],
            path: "Tests/SystemOneProbeSupportTests"
        ),
        .testTarget(
            name: "DjayBridgeTests",
            dependencies: ["DjayBridge"],
            path: "Tests/DjayBridgeTests"
        ),
    ]
)
