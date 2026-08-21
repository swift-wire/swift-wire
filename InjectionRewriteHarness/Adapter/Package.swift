// swift-tools-version: 6.3
import PackageDescription

// A minimal, non-shipped Wire adapter fixture backing the injection-rewrite gate. It publishes
// `@FromSettings` — a property wrapper conforming to `WireInjectionRewrite` — plus a
// `WireAdapterAnnotationV1` definition declaring `.rewritesInjection(provider:)`.
//
// Deliberately NOT the real WireConfiguration adapter, and deliberately nothing to do with
// configuration: swift-wire must never depend on one of its own adapters (that is a package cycle, and it
// would make this gate depend on an external repo existing). A synthetic annotation over a made-up
// `SettingsSource` is also better evidence — if the pass can wire this, it never learned anything about
// swift-configuration. Same reasoning as AdapterHarness's `WireRouting`.
let package = Package(
    name: "WireHarnessSettings",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "WireHarnessSettings", targets: ["WireHarnessSettings"])
    ],
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        .target(
            name: "WireHarnessSettings",
            dependencies: [.product(name: "Wire", package: "swift-wire")]
        )
    ]
)
