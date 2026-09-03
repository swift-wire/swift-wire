// swift-tools-version: 6.3
import PackageDescription

// The third package in the composition harness: Wire-aware, but only ever a *transitive* dependency of
// the consumer (Consumer → WireHarnessLibrary → WireHarnessTransitive). It exists to hold two properties
// marker retirement rests on, both of which were previously enforced by the `_WireExports.swift` marker's absence
// and are now enforced by the activation rule itself:
//
//   1. A transitive Wire-aware package is **not** activated. Only direct dependencies are.
//   2. A library binding whose own dependency lives in a package the consumer never depended on is a
//      **non-event**, because reachability strips it before the missing-binding check. That is precisely
//      what made retiring the marker safe: without a bound, an incidentally-scanned binding like that
//      would break the build.
let package = Package(
    name: "WireHarnessTransitive",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "WireHarnessTransitive", targets: ["WireHarnessTransitive"])
    ],
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        // No build plugin, like the other harness library: it is consumed, not bootstrapped.
        .target(
            name: "WireHarnessTransitive",
            dependencies: [.product(name: "Wire", package: "swift-wire")]
        )
    ]
)
