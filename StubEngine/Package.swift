// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "StubEngine",
    targets: [
        // A deterministic stand-in for `turbo-engine serve`: the engine-vocabulary layer
        // without MLX or models. See docs/remote-protocol.md §Conformance.
        .executableTarget(
            name: "StubEngine",
            path: "Sources/StubEngine"
        ),
        // The wire linter: rejects client-resolved paths on the wire (path-hostility
        // rules, TurboRelay/docs/remote-protocol.md).
        .executableTarget(
            name: "RelayLint",
            path: "Sources/RelayLint"
        ),
    ]
)
