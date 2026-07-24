import SwiftSyntax
import SwiftSyntaxMacros

/// `@RouteController` is a bare marker peer macro used only by swift-wire's own IntegrationTests to stand in
/// for an adapter's proxy-contributing annotation (e.g. WireMVC's `@Controller`). Real adapters live in
/// their own repos; swift-wire ships no adapter, so this marker lets the framework's own tests exercise the
/// contributor-proxy codegen end-to-end. Like `@Scopable`/`@BindType`, it generates nothing — a `WireTestLibrary`
/// `WireAdapterAnnotationV1` declaration binds the name to a `.liftsPeersToProxy` directive the build plugin
/// reads from the parse.
public struct RouteControllerMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}
