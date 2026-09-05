// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

// Contributor-proxy emission — the *structural half* of a plugin-generated contributor proxy.
//
// `ContributorProxySynthesis` builds the proxy *binding* (how the graph constructs the proxy: a
// scope-bound `<prefix><Subject>` depending on the subject + its demanded factories). This file emits
// the proxy *type* — the `struct` declaration itself — into the consumer module, beside the graph.
//
// What's emitted is deliberately only the STRUCTURAL half: the stored fields (the subject +
// each lifted factory), the initialiser the graph's construction call targets, and `Sendable`. There
// is a **body hole** — no adapter-protocol conformance, no witness method. A domain codegen tool (an
// adapter's, e.g. WireMVC's route generator) fills the hole with an `extension` in the same module,
// meeting this struct only on the deterministic field names below. WireGen stays domain-free: it emits
// fields and a hole; it never learns what the witness does.
//
// The field-name contract — shared with the domain body generator, the successor to the old
// macro↔plugin handshake:
//   • the subject is stored as `_wireSubject` (its dependency is positional/unlabelled, so the graph
//     names no member — only the domain body references it, by this name);
//   • each lifted factory is stored as `_wireFactory_<sanitized key>` (see `factoryDependencyName`).

/// The stored-property name the emitted proxy holds its subject under. The subject dependency is
/// positional (unlabelled) in the graph's construction call — the graph names no member of the proxy —
/// so this name exists only as the contract the domain witness body references (`self._wireSubject`).
/// Domain-neutral and `_wire`-prefixed, like `_wireFactory_<key>`, so it can't collide with user code.
package let contributorProxySubjectFieldName = "_wireSubject"

/// The stored-property name a **bridging** proxy holds its scope-entry thunk under, in place of
/// `_wireSubject` — for a proxy whose subject is narrower-scoped than the proxy (a `@Scoped(seed:)`
/// subject under a `.singleton` proxy). The thunk `(Seed) async throws -> Subject` constructs the
/// subject fresh in the subject's scope; the domain witness body invokes it per request. Labelled,
/// so the emitted proxy stores/inits it by this name (unlike the positional subject). Its producer is
/// synthesised by the scope-entry pass, which also emits the field.
package let contributorProxyScopeEntryFieldName = "_wireEnterScope"

extension DiscoveredScopeBoundType {
    /// Every scope-entry thunk this proxy carries — one per `@Scoped(seed:)` subject it bridges into. A
    /// per-subject proxy has at most one (named `_wireEnterScope`); an aggregate proxy has one per seeded
    /// subject (named `_wireEnterScope_<Subject>`), so **detect by kind, never by field name**: the name is
    /// a contract with domain codegen, not a classifier.
    package var scopeEntryDependencies: [DependencyParameter] {
        dependencies.filter { $0.kind == .scopeEntryThunk }
    }

    /// Whether this proxy bridges into any narrower scope — i.e. carries at least one scope-entry thunk.
    package var isBridgeProxy: Bool { !scopeEntryDependencies.isEmpty }
}

/// The type of the reverse-order scope teardown a scope-entry thunk returns alongside its subject. The
/// caller (the generated witness) runs it after the response, in place of the app-scope teardown walk for
/// request-scoped bindings. Errors are collected, not thrown, matching the app-scope contract. A fixed
/// string (no generic parameters), so it is stripped verbatim when recovering the subject.
package let scopeEntryTeardownType = "@Sendable () async -> [any Error]"

/// Everything a bridging proxy's scope-entry thunk is, as a value rather than as a parsed string.
///
/// The thunk used to encode all of this in its own *type* — `@Sendable (Seed) async throws -> (Subject,
/// teardown)` — and every consumer parsed it back out. That worked while the return was a tuple of two
/// known things, and stopped working the moment the return became a named struct: a struct name can carry
/// the subject (it is derived from it) but not the yields, and not what the thunk is generic over. Rather
/// than re-encode a growing contract in a string, the contract rides beside the dependency and the type
/// string becomes only what is emitted.
///
/// Carried on ``DependencyParameter/scopeEntry``, alongside the `.scopeEntryThunk` dependency it
/// describes — the same shape `injectionRewrite` uses for its own kind of site.
package struct ScopeEntryDescriptor: Sendable, Equatable {
    /// The seed the thunk takes — which scope it enters.
    package let seed: String
    /// The subject it constructs, spelled with this proxy's generic parameters (an aggregate renames a
    /// subject's parameters where they collide with an earlier member's, and this is the renamed form).
    package let subject: String
    /// The `.yieldsFromScope` bindings handed back alongside the subject, sorted by type name.
    ///
    /// The sort is for *determinism of the emitted file*, not for correctness: the entry struct names its
    /// fields, so a reader is never reading by position and a re-order could not silently misread.
    package let yields: [String]
    /// The test-variant `_<Key>Doubles` threaded in alongside the seed, or `nil` for a production thunk.
    package let doubles: String?
    /// The struct the thunk returns — `_WireScopeEntry_<Subject>`, or the variant-prefixed form.
    package let entryStructName: String
    /// The entry struct's own generic parameters, taken from the **subject** rather than the proxy.
    ///
    /// An aggregate proxy is generic over the union of its members' parameters, and a struct declared with
    /// a parameter none of its fields mention could not be inferred at the construction site — so the
    /// thunk's return type would be ambiguous. Taking them from the subject gives exactly the parameters
    /// its fields use. For a per-subject proxy (generic exactly as its subject) this is the same list.
    package let genericParameterNames: [String]
    package let genericParameterConstraints: [String: String]
    package let genericWhereClause: String?

    package init(
        seed: String,
        subject: String,
        yields: [String] = [],
        doubles: String? = nil,
        entryStructName: String,
        genericParameterNames: [String] = [],
        genericParameterConstraints: [String: String] = [:],
        genericWhereClause: String? = nil
    ) {
        self.seed = seed
        self.subject = subject
        self.yields = yields
        self.doubles = doubles
        self.entryStructName = entryStructName
        self.genericParameterNames = genericParameterNames
        self.genericParameterConstraints = genericParameterConstraints
        self.genericWhereClause = genericWhereClause
    }

    /// The entry struct as written at a use site — `_WireScopeEntry_MeController<Repository, Manager>`.
    package var entryStructReference: String {
        genericParameterNames.isEmpty
            ? entryStructName
            : "\(entryStructName)<\(genericParameterNames.joined(separator: ", "))>"
    }

    /// The thunk's type: `@Sendable (Seed[, Doubles]) async throws -> <EntryStruct>`.
    ///
    /// The return is a single named type rather than a tuple, which is what lets a yield be *added*
    /// without changing the shape anything already reads. The closure that satisfies it still infers its
    /// own return type — annotating it is what makes a subject over an opaque backend unspellable, and the
    /// two opaque types then fail to convert to each other by name.
    package var thunkType: String {
        let parameters = doubles.map { "\(seed), \($0)" } ?? seed
        return "@Sendable (\(parameters)) async throws -> \(entryStructReference)"
    }
}

/// The entry struct's name for a subject — `_WireScopeEntry_MeController`. `variant` prefixes a
/// test-graph variant's, so a variant proxy's struct cannot collide with the production one it is derived
/// from (both are emitted into the same module).
package func scopeEntryStructName(subjectTypeName: String, variant: String? = nil) -> String {
    variant.map { "_WireScopeEntry_\($0)_\(subjectTypeName)" } ?? "_WireScopeEntry_\(subjectTypeName)"
}

/// The field name the entry struct holds the constructed subject under — the same `_wireSubject` a
/// *holding* proxy stores it as, so one name means "the subject" whichever side of the bridge you are on.
package let scopeEntrySubjectFieldName = contributorProxySubjectFieldName

/// Render the structural declaration for one contributor-proxy binding — the `struct` with its stored
/// fields + initialiser + `Sendable`, generic exactly as the subject, with a body hole (no conformance,
/// no witness). `proxy` is the fully-formed proxy binding *after* factory synthesis has appended the
/// lifted-factory dependencies, so its `dependencies` are the complete field set: the positional subject
/// first, then each labelled factory (and any adapter-injected dependency).
///
///     public struct _WireRouteContributor_TodosController<Repository: TodoRepository>: Sendable {
///         public let _wireSubject: TodosController<Repository>
///         public let _wireFactory_Keys_backend: _WireFactory_Keys_backend
///         public init(_ _wireSubject: TodosController<Repository>, _wireFactory_Keys_backend: _WireFactory_Keys_backend) {
///             self._wireSubject = _wireSubject
///             self._wireFactory_Keys_backend = _wireFactory_Keys_backend
///         }
///     }
// The proxy is emitted `internal` (no access keyword), never the subject's access. It's a consumer-local
// coordination type — emitted into the consumer module, constructed by that module's graph, consumed only
// there as `any <ContributorProtocol>` — so it is never public API. Emitting it `public` (mirroring a
// `public` subject) would force every type it references to be public *from the consumer*, which fails
// under `InternalImportsByDefault`: the generated file imports a shared controllers library internally, so
// a `public` proxy couldn't expose that library's (public) controller / factory types. `internal`
// sidesteps that — an internal declaration may freely reference internally-imported types.
package func renderContributorProxyDeclaration(_ proxy: DiscoveredScopeBoundType) -> String {
    // Each bridged subject's entry struct is emitted *with* the proxy that returns it, so every caller —
    // the graph file, and both test-variant emitters — gets them without having to remember to ask.
    let entryStructs = proxy.scopeEntryDependencies.compactMap(\.scopeEntry)
        .map(renderScopeEntryStructDeclaration)
    let genericClause = renderProxyGenericClause(
        names: proxy.genericParameterNames,
        constraints: proxy.genericParameterConstraints
    )
    let whereClause = proxy.genericWhereClause.map { " where \($0)" } ?? ""

    // One stored field + one init parameter + one assignment per dependency, in dependency order. A
    // dependency with no label is the subject (stored as `_wireSubject`, taken positionally so the
    // construction call — which passes it unlabelled — matches); a labelled dependency (each lifted
    // factory) keeps its label as both field name and init label.
    var fields: [String] = []
    var initParameters: [String] = []
    var assignments: [String] = []
    for dependency in proxy.dependencies {
        // Capture dependencies exist only to order the proxy after the singletons its scope-entry thunk
        // captures — they are not stored fields or init parameters (the thunk references the captured
        // locals directly). See `DependencyKind.scopeCapture`.
        if dependency.kind == .scopeCapture { continue }
        let fieldName = dependency.name ?? contributorProxySubjectFieldName
        fields.append("let \(fieldName): \(dependency.type)")
        // The scope-entry thunk is a closure stored on the proxy, so its init parameter is `@escaping`.
        let parameterType =
            dependency.kind == .scopeEntryThunk ? "@escaping \(dependency.type)" : dependency.type
        // Unlabelled (subject) → `_ name`; labelled (factory / scope-entry thunk) → `name`.
        let parameter =
            dependency.name == nil
            ? "_ \(fieldName): \(parameterType)"
            : "\(fieldName): \(parameterType)"
        initParameters.append(parameter)
        assignments.append("self.\(fieldName) = \(fieldName)")
    }

    var lines: [String] = []
    // `Sendable` (structural — a proxy holds graph bindings, all `Sendable` in Wire's model). The
    // adapter protocol conformance (`RouteContributor`) is NOT stated here — it arrives with the witness
    // in the domain tool's extension, in this same module.
    lines.append("struct \(proxy.typeName)\(genericClause): Sendable\(whereClause) {")
    for field in fields {
        lines.append("    \(field)")
    }
    lines.append("    init(\(initParameters.joined(separator: ", "))) {")
    for assignment in assignments {
        lines.append("        \(assignment)")
    }
    lines.append("    }")
    // Body hole: the witness method (and the adapter-protocol conformance) are emitted by the domain
    // codegen tool as an `extension` on this type, in the same module, referencing the fields above.
    lines.append("}")
    // The entry structs come first: each is the return type of a field declared below it, and a reader
    // following `_wireEnterScope` should meet the shape before the thing that hands it back.
    return (entryStructs + [lines.joined(separator: "\n")]).joined(separator: "\n\n")
}

/// Render the structural declaration for every synthesised contributor proxy, once each — the plugin's
/// Plugin-owned emission into the consumer graph file. `proxyIdentities` are the qualified names
/// `applyContributorProxies` created; a proxy binding is registered in every partition that consumes it,
/// so it's deduped by qualified name here (the *type* is declared once at module scope, like a factory
/// type). Deterministic order by type name. Reads the proxy bindings *after* factory synthesis, so each
/// carries its complete field set (subject + lifted factories).
package func renderContributorProxyTypes(
    proxyIdentities: Set<String>,
    in allBindings: [Partition: [DiscoveredBinding]]
) -> [String] {
    guard !proxyIdentities.isEmpty else { return [] }
    var proxiesByName: [String: DiscoveredScopeBoundType] = [:]
    for bindings in allBindings.values {
        for binding in bindings {
            guard case .scopeBound(let type) = binding,
                proxyIdentities.contains(type.qualifiedTypeName)
            else { continue }
            proxiesByName[type.qualifiedTypeName] = type  // same type across partitions → one declaration
        }
    }
    return proxiesByName.values
        .sorted { $0.typeName < $1.typeName }
        .map(renderContributorProxyDeclaration)
}

/// The entry struct a bridging proxy's scope-entry thunk returns — one per scope-entry dependency, so a
/// per-subject proxy declares one and an aggregate declares one per bridged member.
///
///     struct _WireScopeEntry_MeController<Repository: TodoRepository, Manager: SessionManager>: Sendable {
///         let _wireSubject: MeController<Repository, Manager>
///         let authorizedDocument: AuthorizedDocument
///         let _wireScopeTeardown: @Sendable () async -> [any Error]
///     }
///
/// **A struct rather than a tuple**, because the thunk's return is a contract read by an adapter's
/// generated code. A tuple is read by position, so adding a yield moves every element after it and the
/// reader goes on compiling while reading the wrong one; named fields make an addition additive. It also
/// dissolves the need for yields to be *ordered* at all, which a positional return made load-bearing.
///
/// **`Sendable`**, because the thunk is `@Sendable` and this crosses an async boundary out of it — and
/// **`WireScopeEntry`**, whose whole purpose is to let an adapter emitting a *generic* declaration recover
/// this subject's type without naming it. That was structural while the thunk returned a tuple and is not
/// once it returns a named struct, so the struct carries the projection. `Subject` infers from the field.
///
/// **No explicit initialiser.** The implicit memberwise one is `internal`, which is this struct's own
/// access level and the module it is constructed in — and leaving it implicit is what lets the generic
/// arguments be *inferred* at the construction site. Writing them is not an option for a subject over an
/// opaque backend: the two `some P` types print identically and refuse to convert to one another.
package func renderScopeEntryStructDeclaration(_ descriptor: ScopeEntryDescriptor) -> String {
    let genericClause = renderProxyGenericClause(
        names: descriptor.genericParameterNames,
        constraints: descriptor.genericParameterConstraints
    )
    let whereClause = descriptor.genericWhereClause.map { " where \($0)" } ?? ""
    var lines = [
        "struct \(descriptor.entryStructName)\(genericClause): Sendable, WireScopeEntry\(whereClause) {"
    ]
    lines.append("    let \(scopeEntrySubjectFieldName): \(descriptor.subject)")
    for yield in descriptor.yields {
        lines.append("    let \(identifierName(forType: yield, key: nil)): \(yield)")
    }
    lines.append("    let \(scopeTeardownLocalName): \(scopeEntryTeardownType)")
    lines.append("}")
    return lines.joined(separator: "\n")
}

/// The proxy's generic-parameter clause restated from the subject's parameters and per-parameter
/// constraints — `<Repository: TodoRepository>`, or `<A, B: P>` when only some are constrained, or `""`
/// for a non-generic subject. The subject's `where` clause (associated-type / same-type / `~Copyable`
/// requirements) is rendered separately, after the `Sendable` inheritance clause.
private func renderProxyGenericClause(names: [String], constraints: [String: String]) -> String {
    guard !names.isEmpty else { return "" }
    let parameters = names.map { name in
        constraints[name].map { "\(name): \($0)" } ?? name
    }
    return "<\(parameters.joined(separator: ", "))>"
}
