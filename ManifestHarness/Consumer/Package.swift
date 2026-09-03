// swift-tools-version: 6.3
import PackageDescription

// The consumer half of the plugin-output gate. It depends on the library
// package and applies its own build-tool plugin, whose command reads the
// library's *plugin output* — the channel a binding manifest would travel
// over. No swift-wire dependency: see the Library manifest for why.
let package = Package(
    name: "ManifestHarnessConsumer",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../Library")],
    targets: [
        .executableTarget(
            name: "ManifestHarnessConsumer",
            dependencies: [
                .product(name: "ManifestHarnessLibrary", package: "Library")
            ],
            plugins: [.plugin(name: "ConsumerPlugin")]
        ),
        .plugin(
            name: "ConsumerPlugin",
            capability: .buildTool(),
            dependencies: ["ConsumerGen"]
        ),
        .executableTarget(name: "ConsumerGen"),
    ]
)
