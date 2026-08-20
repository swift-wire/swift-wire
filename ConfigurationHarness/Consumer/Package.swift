// swift-tools-version: 6.0
import PackageDescription

// The gate for `.rewritesInjection` — swift-wire's generic injection-rewrite pass, exercised through the
// WireConfiguration adapter. Its own package because the adapter lives outside swift-wire (as every
// adapter does) and a fixture inside swift-wire's own tests would cycle, the same reason AdapterHarness is
// separate.
let package = Package(
    name: "ConfigurationHarnessConsumer",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../../"),
        .package(path: "../../../wire-configuration"),
    ],
    targets: [
        .executableTarget(
            name: "ConfigurationHarnessConsumer",
            dependencies: [
                .product(name: "Wire", package: "swift-wire"),
                .product(name: "WireConfiguration", package: "wire-configuration"),
            ],
            plugins: [.plugin(name: "WireBuildPlugin", package: "swift-wire")]
        )
    ]
)
