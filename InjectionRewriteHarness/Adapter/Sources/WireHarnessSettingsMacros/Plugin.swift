import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxMacros

/// `@FromSettings` on a *property* is a marker peer macro generating nothing, exactly as `@Container` is.
/// It exists so the attribute is legal on a `let` — a property wrapper "can only be applied to a 'var'",
/// which would otherwise force every property-site consumer to give up immutability. Wire reads the
/// attribute syntactically, before expansion, so the two declarations look identical to it.
public struct FromSettingsMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}

@main
struct WireHarnessSettingsPlugin: CompilerPlugin {
    let providingMacros: [any Macro.Type] = [FromSettingsMacro.self]
}
