import Foundation
import PackagePlugin

/// The producer half (see #338): emits a per-library manifest into this target's plugin
/// work directory, alongside a generated Swift marker.
///
/// The marker exists to keep the command *needed*. A build command whose only
/// output is a `.json` may be pruned — nothing consumes it within this target —
/// while a generated `.swift` is compiled into the target and so must be
/// produced. The consumer reads the JSON; the marker is what guarantees the
/// JSON gets written at all.
@main
struct ManifestPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        guard let module = target.sourceModule else { return [] }

        let generator = try context.tool(named: "ManifestGen")
        let sources = module.sourceFiles(withSuffix: "swift").map(\.url)
        let manifest = context.pluginWorkDirectoryURL.appendingPathComponent("wire-manifest.json")
        let marker = context.pluginWorkDirectoryURL.appendingPathComponent("_WireExports.swift")

        return [
            .buildCommand(
                displayName: "WireManifest \(module.moduleName)",
                executable: generator.url,
                arguments: [manifest.path, marker.path] + sources.map(\.path),
                inputFiles: sources,
                outputFiles: [manifest, marker]
            )
        ]
    }
}
