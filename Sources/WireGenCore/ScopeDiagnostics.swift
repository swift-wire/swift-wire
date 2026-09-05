// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import SwiftSyntax

// Axis A validation diagnostics — scope blocks. Run by the discovery
// visitor while processing scope-bound types.

/// A `@Singleton` type declared inside a `@Scoped(seed:)` scope block.
/// `@Singleton` is process-lifetime, so it can't live in a seed scope —
/// left unflagged it would silently route to the process graph, ignoring
/// the block. A `@Scoped(seed:)` type carries its own scope (`ownScope`
/// non-nil) and is fine; this only fires for the unscoped self-producer.
func singletonInScopeBlockDiagnostics(
    typeName: String,
    ownScope: ScopeKey?,
    blockSeed: ScopeKey?,
    location: SourceLocation
) -> [Diagnostic] {
    guard ownScope == nil, let blockSeed else { return [] }
    return [
        Diagnostic(
            location: location,
            message:
                "@Singleton '\(typeName)' can't live in the @Scoped(seed: \(blockSeed.seed).self) block — @Singleton is process-lifetime, not scoped. Use @Scoped(seed:) for a scoped self-producer, or move it out of the block.",
            severity: .error
        )
    ]
}

/// `@Factory` plus `@Singleton` or `@Scoped(seed:)` on the same type is **two lifetime macros on one
/// declaration**, which is a contradiction rather than a combination — and reporting it as one is what
/// stops it surfacing as the two unrelated errors it used to.
///
/// Left undiagnosed, both macros synthesise an initialiser from the same `@Inject` members, so the user
/// gets `invalid redeclaration of 'init(…)'` from the compiler — a name collision standing in for a
/// contradiction. Supplying the init by hand (which both macros defer to) then gets past that and the
/// declaration is discovered *twice*, in incompatible roles: once as a binding, whose generic parameters
/// must be bound, and once as a factory template, whose generic parameters are assisted by definition —
/// which surfaces as a generic-arity error about a type the user never asked to be a singleton.
///
/// The three are alternatives because each names a *lifetime*, and a declaration has one:
///
/// - `@Singleton` — one instance for the process.
/// - `@Scoped(seed:)` — one instance per scope entry.
/// - `@Factory(key)` — **no scope at all.** The template is constructed per `create` call; what becomes a
///   graph binding is the factory the plugin synthesises for the key, and *that* has the lifetime. So a
///   template is neither a singleton nor scoped, and there is nothing for a scope macro to say about it.
///
/// Dagger, which Wire borrows assisted parameters from, states the same rule outright: "@AssistedInject
/// types cannot be scoped."
///
/// An `.error`, not a warning: there is no reading of the combination that produces a working graph.
/// `WireMacrosImpl`'s `LifetimeMacroExclusion` reports the same contradiction at expansion time, so the
/// macro half stops synthesising the second `init`; this half stops the double discovery. Both exist
/// because they prevent different symptoms of the one mistake.
func factoryWithScopeDiagnostics(
    nameToken: TokenSyntax,
    attributes: AttributeListSyntax,
    sourcePath: String,
    converter: SourceLocationConverter
) -> [Diagnostic] {
    guard hasAttribute(attributes, named: "Factory") else { return [] }
    guard let scope = scopeMacroNames.first(where: { hasAttribute(attributes, named: $0) })
    else { return [] }
    return [
        Diagnostic(
            location: makeSourceLocation(
                of: nameToken,
                sourcePath: sourcePath,
                converter: converter
            ),
            message:
                "'\(nameToken.text)' carries both @Factory and @\(scope) — two lifetime macros on one declaration, and a declaration has one lifetime. A @Factory template has no scope of its own: it is constructed per `create` call, and the binding with a lifetime is the factory the plugin synthesises for the key. Drop @\(scope); if the concern really is scoped, it belongs in a @\(scope) binding the template injects, not on the template.",
            severity: .error
        )
    ]
}

/// `@Container` plus a scope macro on the same type is almost always a
/// user error: `@Container` routes the type's static members into a
/// separate graph, while a scope macro makes the type a binding in the
/// *default* graph — the two roles can't both happen on one type, and
/// neither does what the user probably wants. Warn with a fix-it
/// pointing at the split.
func containerWithScopeDiagnostics(
    nameToken: TokenSyntax,
    attributes: AttributeListSyntax,
    sourcePath: String,
    converter: SourceLocationConverter
) -> [Diagnostic] {
    guard hasAttribute(attributes, named: "Container") else { return [] }
    guard let scope = scopeMacroNames.first(where: { hasAttribute(attributes, named: $0) })
    else { return [] }
    return [
        Diagnostic(
            location: makeSourceLocation(
                of: nameToken,
                sourcePath: sourcePath,
                converter: converter
            ),
            message:
                "'\(nameToken.text)' carries both @Container and @\(scope) — the two roles end up in separate graphs. Split into two declarations: a @\(scope) type for the binding, and a separate @Container type for the grouping."
        )
    ]
}
