// swift-tools-version: 6.3
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import CompilerPluginSupport
import PackageDescription

// A minimal, non-shipped Wire adapter fixture backing the injection-rewrite gate. It publishes
// `@FromSettings` under *two* declarations sharing one name — a property wrapper (the only mechanism that
// can attach to a parameter) and a peer macro (the only one that can attach to a `let` property) — plus a
// `WireAdapterAnnotationV1` definition declaring `.rewritesInjection(provider:)`. Swift resolves each use
// site to whichever declaration can apply there.
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
        .package(path: "../.."),
        .package(url: "https://github.com/swiftlang/swift-syntax", "603.0.0"..<"604.0.0"),
    ],
    targets: [
        // The peer macro half of `@FromSettings`. It generates nothing — like `@Container`, it exists so
        // the attribute is legal where a property wrapper is not, namely on a `let` property.
        .macro(
            name: "WireHarnessSettingsMacros",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),
        .target(
            name: "WireHarnessSettings",
            dependencies: [
                "WireHarnessSettingsMacros",
                .product(name: "Wire", package: "swift-wire"),
            ]
        ),
    ]
)
