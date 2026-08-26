import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// The three lifetime macros are alternatives, and this is what says so at expansion time.
///
/// `@Singleton`, `@Scoped(seed:)` and `@Factory(key)` each name a lifetime, and a declaration has one:
///
/// - `@Singleton` — one instance for the process.
/// - `@Scoped(seed:)` — one instance per scope entry.
/// - `@Factory(key)` — **no scope at all.** The template is constructed per `create` call; what becomes a
///   graph binding is the factory the plugin synthesises for the key, and that is what has a lifetime.
///
/// Left unchecked, two of them on one declaration is not caught as a contradiction but as a name
/// collision: both synthesise an initialiser from the same `@Inject` members, so the compiler reports
/// `invalid redeclaration of 'init(…)'` — an error about the *symptom*, from which nothing about the
/// mistake can be read. That is dissolved rather than worked around: only one lifetime macro may
/// synthesise, so the second `init` is never emitted and the collision stops being reachable.
///
/// **Which one reports.** The first lifetime attribute in source order expands normally; every later one
/// reports and synthesises nothing. That yields exactly one diagnostic, pointing at the attribute to
/// remove, and exactly one initialiser — so the user is left with the error they should have had and no
/// cascade behind it. Wire's build plugin diagnoses the same contradiction from source
/// (`factoryWithScopeDiagnostics`), where it prevents a different symptom: the declaration being
/// discovered twice, as a binding and as a template.
enum LifetimeMacroExclusion {
    /// The attribute names that declare a lifetime, and so exclude one another.
    static let macroNames = ["Singleton", "Scoped", "Factory"]

    /// Report the contradiction and tell the caller to synthesise nothing, when `node` is not the first
    /// lifetime attribute on `declaration`. Returns `false` — carry on — when `node` is the first (or
    /// only) one, which is every well-formed declaration.
    ///
    /// **Matched by attribute name, not by position.** The obvious spelling — compare `node.position`
    /// against the first lifetime attribute's — silently never fires: the `node` a macro is handed is
    /// detached from the declaration's tree, so its `position` is `0` whatever attribute it is, while the
    /// first attribute in `declaration.attributes` is also at `0`. The two therefore compare *equal* for
    /// every expansion, and every macro concludes it is the first. It is worth spelling out because the
    /// failure is invisible on one toolchain and not another, and it fails in the safe-looking direction:
    /// no diagnostic and no suppression, so the only symptom is the `invalid redeclaration` this exists to
    /// dissolve, exactly as before.
    static func isSupersededLifetimeMacro(
        node: AttributeSyntax,
        declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) -> Bool {
        let lifetimeNames = declaration.attributes.compactMap { element -> String? in
            guard case .attribute(let attribute) = element else { return nil }
            let name = attribute.attributeName.trimmedDescription
            return macroNames.contains(name) ? name : nil
        }
        // The common case: one lifetime macro, nothing to say.
        guard lifetimeNames.count > 1, let first = lifetimeNames.first else { return false }
        let thisName = node.attributeName.trimmedDescription
        // The first lifetime attribute in source order expands; every later one reports. Two attributes
        // of the *same* name are left alone: that is a duplicate attribute, which Swift rejects on its
        // own, and there is no "which one is this" to answer by name.
        guard thisName != first else { return false }
        context.diagnose(
            Diagnostic(
                node: node,
                message: WireDiagnostic.multipleLifetimeMacros(this: thisName, first: first)
            )
        )
        return true
    }
}
