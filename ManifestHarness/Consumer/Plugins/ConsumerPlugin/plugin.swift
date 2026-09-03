import Foundation
import PackagePlugin

/// The consumer half: derives the path of each dependency's plugin output,
/// declares it as an input, and hands it to the generator.
///
/// Two things are being pinned here, and both are undocumented SPM behaviour
/// rather than API — which is why this is a gate and why the manifest route is deferred rather
/// than adopted (#338):
///
/// 1. **The layout.** A plugin's outputs live at
///    `<build>/plugins/outputs/<package-id>/<target>/<destination>/<PluginName>/`.
///    Nothing in `PluginContext` exposes another target's work directory, so the
///    path is reconstructed from this plugin's own by string surgery. The
///    `<destination>` component is taken from our own path rather than assumed,
///    so a host-tools build resolves correctly.
/// 2. **The ordering.** Declaring that derived path in `inputFiles` is what
///    makes llbuild order the producing command first. Without it the two
///    commands are unordered and the read is a race — the producer's delay in
///    `ManifestGen` is what makes that race deterministic rather than lucky.
///
/// Note what is *not* here: any check that a dependency actually emits a
/// manifest. Nothing in the plugin API can answer it — a dependency package's
/// plugin target does not appear in its `targets` — so this plugin hardcodes
/// the one dependency it knows about. A real implementation needs a predicate,
/// and an input nothing produces is a hard build failure.
@main
struct ConsumerPlugin: BuildToolPlugin {
    /// The producing plugin's name is part of the path, so the consumer has to
    /// know it. Another face of the same predicate gap.
    static let producingPlugin = "ManifestPlugin"
    static let manifestName = "wire-manifest.json"

    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        guard let module = target.sourceModule else { return [] }

        // …/plugins/outputs/<consumer-package>/<target>/<destination>/ConsumerPlugin
        let workDirectory = context.pluginWorkDirectoryURL
        let destination = workDirectory.deletingLastPathComponent().lastPathComponent
        let outputsRoot =
            workDirectory
            .deletingLastPathComponent()  // <destination>
            .deletingLastPathComponent()  // <target>
            .deletingLastPathComponent()  // <consumer-package-id>
            .deletingLastPathComponent()  // outputs

        // The modules this target directly depends on — the same "activation is
        // the dependency" rule WireBuildPlugin applies.
        var directModules: Set<String> = []
        for dependency in target.dependencies {
            switch dependency {
            case .target(let dependencyTarget):
                dependencyTarget.sourceModule.map { directModules.insert($0.moduleName) }
            case .product(let dependencyProduct):
                for dependencyTarget in dependencyProduct.targets {
                    dependencyTarget.sourceModule.map { directModules.insert($0.moduleName) }
                }
            @unknown default:
                break
            }
        }

        var manifests: [URL] = []
        for packageDependency in context.package.dependencies {
            let dependencyPackage = packageDependency.package
            for dependencyTarget in dependencyPackage.targets {
                guard let dependencyModule = dependencyTarget.sourceModule,
                    directModules.contains(dependencyModule.moduleName)
                else { continue }
                manifests.append(
                    outputsRoot
                        .appendingPathComponent(dependencyPackage.id)
                        .appendingPathComponent(dependencyTarget.name)
                        .appendingPathComponent(destination)
                        .appendingPathComponent(Self.producingPlugin)
                        .appendingPathComponent(Self.manifestName)
                )
            }
        }

        let generator = try context.tool(named: "ConsumerGen")
        let output = context.pluginWorkDirectoryURL.appendingPathComponent("_WireManifests.swift")

        return [
            .buildCommand(
                displayName: "ConsumerGen \(module.moduleName)",
                executable: generator.url,
                arguments: [output.path] + manifests.map(\.path),
                // The dependency's manifests are declared as inputs. This is
                // the whole gate: it is what orders the producer first.
                inputFiles: module.sourceFiles(withSuffix: "swift").map(\.url) + manifests,
                outputFiles: [output]
            )
        ]
    }
}
