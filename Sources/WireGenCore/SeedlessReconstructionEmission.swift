// Seedless reconstruction emission — the on-demand rebuild an app-scoped (`@Singleton`) route contributor
// gets under a `@BindType` variant when it's `@Scopable`'d.
//
// A `@Scoped(seed:)` subject reconstructs per request *from its seed* (the bridging proxy's
// `_wireEnterScope(seed, doubles)` thunk — `ScopeEntryEmission`). An app-scoped route contributor has no seed
// — it can't consume the request (it's a `@Singleton`; the request isn't available at its `init`) — so its
// per-request reconstruction needs *only the doubles*: `_wireEnterScope(doubles) -> (subject, teardown)`,
// rebuilding the subject with `doubles.<field>` substituted for the mocked slot and every non-mock binding
// borrowed from the variant graph. "Created on demand when the test needs it."
//
// The bridge machinery is keyed by seed throughout (`parsedContributorScopeEntryThunkType`, the `scopes[seed]`
// lookup), and a seedless `(Doubles)` thunk is indistinguishable from a production seed-only `(Seed)` one, so
// this is a distinct emitter rather than an overload — the seed path stays byte-for-byte unchanged.

/// The descriptor for a seedless reconstruction thunk — `@Sendable (Doubles) async throws -> EntryStruct`,
/// the doubles-only companion to the seeded scope entry.
///
/// It returns the **same entry struct** the seeded path does, which is the point: a variant harness reads
/// one shape whichever path built the subject, and an adapter's generated code needs no branch. The
/// `seed` slot carries the *doubles* type here — the thunk's sole parameter, and the key
/// `seedlessScopeKey` registers its reconstruction scope under, so the borrow-reachability lookup
/// resolves. There is no seed: this path exists precisely because the subject is app-scoped.
package func seedlessScopeEntryDescriptor(
    subject: String,
    doubles: String,
    entryStructName: String,
    genericParameterNames: [String] = [],
    genericParameterConstraints: [String: String] = [:],
    genericWhereClause: String? = nil
) -> ScopeEntryDescriptor {
    ScopeEntryDescriptor(
        seed: doubles,
        subject: subject,
        entryStructName: entryStructName,
        genericParameterNames: genericParameterNames,
        genericParameterConstraints: genericParameterConstraints,
        genericWhereClause: genericWhereClause
    )
}

/// Render the `Wire.bootstrap<Variant>_<Subject>Contributor(wireGraph:)` facade for a seedless variant proxy —
/// an `extension Wire` static that borrows the variant graph, emits the proxy's seedless `_wireEnterScope`
/// thunk (rebuilding the reconstruction scope's bindings — the doubles-sourced mock(s) + the substituted
/// subject + any mock-consuming hops — from `doubles`, borrowing the rest), and constructs the proxy. Mirrors
/// `renderContributorProxyFacade` minus the seed: no seed parameter, and the thunk is `(doubles)`-only.
///
/// `proxy` is the seedless variant proxy binding (its `_wireEnterScope` re-typed to `(Doubles) -> …`);
/// `scope` is the reconstruction scope (its `topologicalOrder` the bindings the thunk rebuilds, `doublesType`
/// naming the `_<Key>Doubles`); `parentGraphTypeReference` is the variant graph; `facadeMethodName` the `Wire`
/// static a consumer calls. `factoryConstructions` maps a lifted-factory local to the expression that *builds*
/// it (a mock-consuming factory's variant form, constructed from the non-mock graph deps) — those locals are
/// constructed rather than borrowed from the variant graph (which dropped the production factory).
package func renderSeedlessContributorFacade(
    proxy: DiscoveredScopeBoundType,
    scope: SeedScopeEmission,
    parentGraphTypeReference: String,
    facadeMethodName: String,
    factoryConstructions: [String: String] = [:]
) -> String {
    guard let doublesType = scope.doublesType else { return "" }
    let wireGraphInternal = "_wireGraph"

    // App-singletons the thunk borrows, bound as Sendable locals *outside* the `@Sendable` thunk (as the
    // bridge facade does), so the thunk captures the value rather than the non-Sendable graph.
    let borrows = reachableBorrows(forBridgeProxy: .scopeBound(proxy), scopes: seedlessScopeKey(scope))
    let factoryLocals = proxyGraphDependencyLocals(for: proxy)
    let thunkLines = seedlessScopeEntryThunkLines(proxy: proxy, scope: scope, doublesType: doublesType)
    let construction = constructionExpression(for: .scopeBound(proxy))

    let signature = "\(facadeMethodName)(wireGraph \(wireGraphInternal): \(parentGraphTypeReference))"
    var lines: [String] = ["extension Wire {"]
    lines.append("    static func \(signature) -> \(seedlessProxyTypeReference(proxy)) {")
    for borrow in borrows {
        lines.append("        let \(borrow.property) = \(borrow.accessPath)")
    }
    for local in factoryLocals {
        let value = factoryConstructions[local] ?? "\(wireGraphInternal).\(local)"
        lines.append("        let \(local) = \(value)")
    }
    for line in thunkLines {
        lines.append("    " + line)
    }
    lines.append("        return \(construction)")
    lines.append("    }")
    lines.append("}")
    return lines.joined(separator: "\n")
}

/// The seedless proxy's return-type reference — the bare name for a non-generic proxy, or the opaque-erased
/// form for a generic one (mirroring the seed-scope façade's erasure).
private func seedlessProxyTypeReference(_ proxy: DiscoveredScopeBoundType) -> String {
    guard !proxy.genericParameterNames.isEmpty else { return proxy.typeName }
    let erased = proxy.genericParameterNames.map { name in
        proxy.genericParameterConstraints[name].map { "some \($0)" } ?? name
    }
    return "\(proxy.typeName)<\(erased.joined(separator: ", "))>"
}

/// The reconstruction scope keyed for the borrow-reachability helper. That helper parses the proxy's
/// `_wireEnterScope` type for a scope key; a seedless `(Doubles)` thunk parses to the doubles type as its
/// (sole) parameter, so the scope is keyed by `doublesType` for the lookup to resolve.
private func seedlessScopeKey(_ scope: SeedScopeEmission) -> [String: SeedScopeEmission] {
    scope.doublesType.map { [$0: scope] } ?? [:]
}

/// The seedless `_wireEnterScope` thunk body — `{ @Sendable (doubles: Doubles) async throws in … }`
/// reconstructing the scope's bindings (borrows resolve to the captured locals bound outside), then
/// returning the entry struct. The doubles-only analog of `scopeEntryThunkLines`.
private func seedlessScopeEntryThunkLines(
    proxy: DiscoveredScopeBoundType,
    scope: SeedScopeEmission,
    doublesType: String
) -> [String] {
    // The thunk local is named by the thunk *type*'s identity form (as the bridge path does), so the proxy
    // construction — which passes `_wireEnterScope: <that local>` — resolves to it. A generic proxy is a lift
    // node, so the type is lift-specialised (`Backend` → `some GenAppBackend`) to match the construction's.
    let scopeEntry = proxy.scopeEntryDependencies.first
    let thunkType = liftSpecialised(scopeEntry?.type ?? "", in: .scopeBound(proxy))
    let thunkLocal = identifierName(forType: thunkType, key: nil)
    // The subject is read out of the thunk's own return type, as the seeded path does. It used to be
    // taken positionally — `topologicalOrder.last` — on the assumption that the routed controller is
    // always constructed last. Anything that appends an app-scope binding the scope borrows can land
    // after it and silently become the returned value: an injection rewrite (`@ConfigProperty`) did
    // exactly that, and the thunk returned a config string where a controller belonged.
    let subjectLocal =
        scopeEntry?.scopeEntry
        .map { identifierName(forType: liftSpecialised($0.subject, in: .scopeBound(proxy)), key: nil) }
        ?? scope.topologicalOrder.last.map { propertyName(for: $0) } ?? ""

    var lines: [String] = ["    let \(thunkLocal) = { @Sendable (doubles: \(doublesType)) async throws in"]
    for binding in scope.topologicalOrder {
        let name = propertyName(for: binding)
        if scope.borrowedBindingPropertyNames.contains(name) { continue }
        let construction = constructionExpression(for: binding)
        if name == construction { continue }
        lines.append("        let \(name) = \(construction)")
    }
    lines.append(
        contentsOf: scopeTeardownClosureLines(scope, local: scopeTeardownLocalName, reachable: nil)
    )
    // Returns the same entry struct the seeded path does — a variant harness reads one shape, whichever
    // path built the subject, and the adapter's generated code needs no branch between them.
    guard let descriptor = scopeEntry?.scopeEntry else { return lines }
    let arguments =
        ([(scopeEntrySubjectFieldName, subjectLocal)]
        + descriptor.yields.map {
            let field = identifierName(forType: $0, key: nil)
            return (field, identifierName(forType: liftSpecialised($0, in: .scopeBound(proxy)), key: nil))
        }
        + [(scopeTeardownLocalName, scopeTeardownLocalName)])
        .map { "\($0): \($1)" }
        .joined(separator: ", ")
    lines.append("        return \(descriptor.entryStructName)(\(arguments))")
    lines.append("    }")
    return lines
}
