// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TurboRelay",
    platforms: [.macOS(.v15)],
    targets: [
        // The server core: config, HTTP+WebSocket listener, engine supervision,
        // the wire⇄engine bridge, model resolution (TurboRelay/docs/remote-protocol.md).
        .target(name: "TurboRelayCore"),
        .executableTarget(
            name: "RelayServer",
            dependencies: ["TurboRelayCore"]
        ),
        .executableTarget(
            name: "TurboRelayApp",
            dependencies: ["TurboRelayCore"]
        ),
        .testTarget(
            name: "TurboRelayTests",
            dependencies: ["TurboRelayCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
