// swift-tools-version: 6.3
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import PackageDescription

// The consumer for the injection-rewrite gate. It depends on swift-wire (macros + build plugin) and on
// the synthetic `WireHarnessSettings` adapter, and applies WireBuildPlugin. Running it bootstraps the
// generated graph and asserts each annotated site resolved to the producer Wire synthesised for it.
let package = Package(
    name: "InjectionRewriteHarnessConsumer",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../.."),
        .package(path: "../Adapter"),
    ],
    targets: [
        .executableTarget(
            name: "InjectionRewriteHarnessConsumer",
            dependencies: [
                .product(name: "Wire", package: "swift-wire"),
                .product(name: "WireHarnessSettings", package: "Adapter"),
            ],
            plugins: [.plugin(name: "WireBuildPlugin", package: "swift-wire")]
        )
    ]
)
