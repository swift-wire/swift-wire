import SwiftCompilerPlugin
import SwiftSyntaxMacros

/// The test-only macro plugin. Hosts `@RouteController` alone, so swift-wire's own IntegrationTests can
/// induce a contributor proxy without that marker riding in the production `WireMacrosImpl` plugin every
/// consumer builds.
@main
struct WireTestMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        RouteControllerMacro.self
    ]
}
