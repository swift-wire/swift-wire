// swift-tools-version: 6.3
import PackageDescription

// The producer half of the plugin-output gate. It deliberately does *not*
// depend on swift-wire: the claim under test is an SPM/llbuild capability —
// whether a consumer's build command can read a dependency's build-tool-plugin
// output — not anything about Wire's own codegen. Keeping Wire out means the
// gate fails only when the toolchain behaviour changes.
let package = Package(
    name: "ManifestHarnessLibrary",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ManifestHarnessLibrary", targets: ["ManifestHarnessLibrary"])
    ],
    targets: [
        // Applying the plugin is what makes this target emit a manifest. That
        // fact is invisible to a consumer — a dependency package's plugin
        // target does not appear in its `targets` at all — which is the
        // predicate gap #338 records.
        .target(
            name: "ManifestHarnessLibrary",
            plugins: [.plugin(name: "ManifestPlugin")]
        ),
        .plugin(
            name: "ManifestPlugin",
            capability: .buildTool(),
            dependencies: ["ManifestGen"]
        ),
        .executableTarget(name: "ManifestGen"),
    ]
)
