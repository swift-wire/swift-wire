// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

/// One dependency that the synthesised (or user-marked) initialiser takes
/// — i.e. one parameter Wire must resolve from the graph at construction
/// time.
///
/// `name` is the external argument label used at the call site. `nil`
/// represents a wildcard label (the `_` form, e.g. `init(_ a: A)`),
/// where the call site omits the label entirely. Property-based
/// injection always produces a concrete label (the property name);
/// only `@Inject init(_ x: Foo)` produces a `nil` name.
package struct DependencyParameter: Sendable {
    package let name: String?
    /// `private(set) var` so `retyped(_:)` can copy `self` and change only this; see that method.
    package private(set) var type: String
    package let kind: DependencyKind
    /// Position of the parameter or property identifier in source — the
    /// `@Inject` site (or `@Provides func` parameter) the diagnostic
    /// should point at when this dependency can't be resolved.
    package let location: SourceLocation
    /// A `.rewritesInjection` annotation on this site (`@ConfigProperty(forKey:…)`), or `nil` for an
    /// ordinary dependency. Present ⇒ the site does not resolve by its own type: `applyInjectionRewrites`
    /// synthesises a producer from it and re-points this dependency at that.
    package let injectionRewrite: InjectionRewriteSite?
    /// Canonical text of the `@Inject(<expr>)` argument when the
    /// consumer is selecting a keyed binding, or `nil` for the unkeyed
    /// form. Unkeyed deps match only unkeyed bindings; keyed deps
    /// match only same-key bindings (Dagger-style — keys partition the
    /// binding space).
    package let keyIdentifier: String?
    /// The *non-owning* form this init-time dependency was written as
    /// (`@Inject weak let` or `@Inject unowned …`), or `nil` for an
    /// ordinary owning dependency. Diagnostic-only metadata: a non-owning
    /// init edge that closes a cycle can be broken by converting it to
    /// `weak var` (post-construct delivery), so the cyclic-dependency error
    /// points at it. Doesn't affect resolution or codegen. See
    /// `OptionalMatchingAndCycles.md`.
    package let nonOwningInitForm: NonOwningInitForm?
    /// What this `.scopeEntryThunk` dependency enters and hands back, or `nil` for every other kind.
    /// Present ⇒ `type` is a rendering of this and nothing needs to read it back; see
    /// ``ScopeEntryDescriptor``, which says why the contract stopped living in the type string.
    package let scopeEntry: ScopeEntryDescriptor?

    package init(
        name: String?,
        type: String,
        kind: DependencyKind,
        location: SourceLocation,
        keyIdentifier: String? = nil,
        nonOwningInitForm: NonOwningInitForm? = nil,
        injectionRewrite: InjectionRewriteSite? = nil,
        scopeEntry: ScopeEntryDescriptor? = nil
    ) {
        self.name = name
        self.type = type
        self.kind = kind
        self.location = location
        self.keyIdentifier = keyIdentifier
        self.nonOwningInitForm = nonOwningInitForm
        self.injectionRewrite = injectionRewrite
        self.scopeEntry = scopeEntry
    }

    /// This dependency resolving as `newType` instead, with every other field — label, kind,
    /// location, key, non-owning form, injection-rewrite site, scope-entry descriptor — carried over.
    /// Copying `self` rather than calling the initialiser means a field added to this struct later is
    /// carried too; generic specialisation once rebuilt the parameter by hand and silently dropped
    /// three of them (swift-wire#428).
    func retyped(_ newType: String) -> DependencyParameter {
        var copy = self
        copy.type = newType
        return copy
    }
}

/// How a non-owning, *constructor-injected* dependency was spelled. Both
/// forms are delivered at init (not post-construct), so they participate
/// in cycle detection — they are NOT cycle-breakers. `weak let` nils on
/// the target's deallocation; `unowned` is non-optional and traps. The
/// `description` is what the cyclic-dependency note calls the edge.
package enum NonOwningInitForm: Sendable, Equatable {
    case weakLet
    case unowned

    package var description: String {
        switch self {
        case .weakLet: return "weak let"
        case .unowned: return "unowned"
        }
    }
}
