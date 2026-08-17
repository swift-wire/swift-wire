// swift-tools-version: 6.3
import PackageDescription

// The consumer for the graph-inputs gate. `@GraphInputs` changes the *signature* of
// `Wire.bootstrap`, so a fixture for it cannot live in swift-wire's shared
// `IntegrationTests` module: one graph per module means every other test's
// `Wire.bootstrap()` would have to pass inputs it does not care about. A separate
// package gives it a graph of its own, the same reason CompositionHarness and
// AdapterHarness are separate.
let package = Package(
    name: "GraphInputsHarnessConsumer",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "GraphInputsHarnessConsumer",
            dependencies: [
                .product(name: "Wire", package: "swift-wire")
            ],
            plugins: [.plugin(name: "WireBuildPlugin", package: "swift-wire")]
        )
    ]
)
