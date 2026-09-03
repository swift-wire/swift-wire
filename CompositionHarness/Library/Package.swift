// swift-tools-version: 6.3
import PackageDescription

// An external Wire-aware library package, used by the sibling Consumer
// package to exercise cross-*package* composition (iteration 7g). It lives
// in its own package (not a target of swift-wire) precisely so the
// consumer activates it as a `.product` from an external package — the
// `.product` path 7d can't test from within swift-wire's own `swift test`
// (a macro-using fixture that swift-wire depended on would form a cycle).
let package = Package(
    name: "WireHarnessLibrary",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "WireHarnessLibrary", targets: ["WireHarnessLibrary"])
    ],
    dependencies: [
        .package(path: "../.."),
        // A Wire-aware package the consumer never depends on — so it is transitive from there, and must
        // not be activated. See `../TransitiveLibrary/Package.swift`.
        .package(path: "../TransitiveLibrary"),
    ],
    targets: [
        // No build plugin: the library is consumed, not bootstrapped — the
        // consumer's plugin re-parses these sources. What marks it
        // Wire-aware is this target's own dependency on the `Wire` product;
        // the hand-declared `_WireExports.swift` marker it used to carry was
        // since retired.
        .target(
            name: "WireHarnessLibrary",
            dependencies: [
                .product(name: "Wire", package: "swift-wire"),
                .product(name: "WireHarnessTransitive", package: "TransitiveLibrary"),
            ]
        )
    ]
)
