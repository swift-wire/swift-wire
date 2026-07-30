// Contributor-proxy facade emission — the test-graph variant's doubles-threaded reach into request scope.
//
// A shipped M6a variant emits only a seed-scope *facade* (`Wire.bootstrap<Variant>_<Seed>Scope`) returning
// a scope *struct*, which loses the teardown and the per-root pruning an HTTP adapter reaches request scope
// through in production (the M5.4 contributor proxy's `_wireEnterScope(seed)` thunk). This file emits the
// missing piece: for a bridging contributor proxy over a `@Scoped(seed:)` subject that a variant touches,
// a *distinct* variant proxy (`_<Variant>_<ProductionProxy>`) whose `_wireEnterScope` thunk threads the
// variant's `_<Key>Doubles` alongside the seed, plus a `Wire.bootstrap<Variant>_<Subject>Contributor`
// facade that builds it against the reused production `_WireGraph`.
//
// The variant proxy is distinct from the production proxy (not an overload on it): `_wireEnterScope` is a
// stored closure whose single type is fixed per struct, and the production proxy and variant proxy both
// land in the same generated module, so they cannot share a name. A consumer (a re-composing test target's
// domain codegen) reaches request scope with `variantProxy._wireEnterScope(seed, doubles:)` — the doubles
// ride the *call*, so the facade builds the proxy once (like production) and the consumer enters per
// request. The production seed-only path is untouched.

/// Render the `Wire.bootstrap<...>Contributor(wireGraph:)` facade for one doubles-threaded variant proxy —
/// an `extension Wire` whose static method borrows the reused production graph, emits the proxy's
/// doubles-threaded scope-entry thunk (the same tuple + per-root pruning + Phase-2 `@Scopable` cascade the
/// production thunk uses, driven from `scope`), and constructs the variant proxy. The app-singletons the
/// thunk borrows — and the proxy's own lifted input edges (its `_wireFactory_<key>` / adapter dependencies)
/// — are bound as `let <local> = _wireGraph.<local>` locals *outside* the `@Sendable` thunk, so the thunk
/// captures Sendable borrowed values rather than the non-Sendable graph, and the proxy construction resolves
/// each lifted-factory reference to the graph's instance rather than the bare type. The facade is not
/// `async`/`throws`:
/// it only *builds* the proxy (the closure captures the borrow locals and the doubles ride the later
/// `_wireEnterScope` call), so entering the scope stays on the consumer's per-request path.
///
/// `proxy` is the variant proxy binding (its `_wireEnterScope` dependency already re-typed to carry the
/// doubles); `scope` is the matching variant seed scope (carrying `doublesType` + `edges`);
/// `parentGraphTypeReference` is the opaque-erased reused graph type (`_WireGraph`, or `_WireGraph<some P>`
/// when the app graph lifts opaque axes); `facadeMethodName` is the `Wire` static-method name a consumer
/// calls to obtain the proxy. `factoryConstructions` overrides a lifted-factory local's value: a
/// mock-consuming factory is dropped from the variant graph, so its local is built here from the variant
/// factory type instead of read off `_wireGraph`.
package func renderContributorProxyFacade(
    proxy: DiscoveredScopeBoundType,
    scope: SeedScopeEmission,
    parentGraphTypeReference: String,
    facadeMethodName: String,
    factoryConstructions: [String: String] = [:]
) -> String {
    let wireGraphExternal = wireGraphParameterLabel(forType: scope.parentGraphType)
    let wireGraphInternal = wireGraphParameterInternalName(forType: scope.parentGraphType)

    // The app-singletons the thunk borrows, bound as locals *outside* the thunk: `let <prop> =
    // _wireGraph.<prop>`. The `@Sendable` thunk then references the bare Sendable local (mirroring the
    // bootstrap body's captured singleton locals) rather than reading `_wireGraph.<prop>` inside itself —
    // which would capture the non-Sendable `_WireGraph` and fail to compile. Pruned to the thunk's reachable
    // set, so no borrow the routed subject doesn't reach leaves a dead local.
    let borrows = reachableBorrows(forBridgeProxy: .scopeBound(proxy), scopes: [scope.seedTypeExpression: scope])
    // The proxy's lifted input edges (its `_wireFactory_<key>` / adapter dependencies) are graph bindings its
    // construction references by bare name. Bind each off the graph too (`let <local> = _wireGraph.<local>`),
    // so the construction resolves to the graph's instance rather than the bare type — the production
    // bootstrap body binds the same locals before constructing the proxy. A mock-consuming factory is the
    // exception: it is dropped from the variant graph, so `factoryConstructions` supplies its variant
    // factory's construction in place of the graph read.
    let factoryLocals = proxyGraphDependencyLocals(for: proxy)
    let thunkLines =
        scopeEntryThunkLines(forBridgeProxy: .scopeBound(proxy), scopes: [scope.seedTypeExpression: scope]) ?? []
    let construction = constructionExpression(for: .scopeBound(proxy))

    let signature =
        "\(facadeMethodName)(\(wireGraphExternal) \(wireGraphInternal): \(parentGraphTypeReference))"
    var lines: [String] = ["extension Wire {"]
    lines.append("    static func \(signature) -> \(variantProxyTypeReference(proxy)) {")
    for borrow in borrows {
        lines.append("        let \(borrow.property) = \(borrow.accessPath)")
    }
    for local in factoryLocals {
        let value = factoryConstructions[local] ?? "\(wireGraphInternal).\(local)"
        lines.append("        let \(local) = \(value)")
    }
    // The thunk lines are indented for a `_wireBootstrap()` body (4 spaces); one more level nests them
    // inside the facade's static method.
    for line in thunkLines {
        lines.append("    " + line)
    }
    lines.append("        return \(construction)")
    lines.append("    }")
    lines.append("}")
    return lines.joined(separator: "\n")
}

/// The variant proxy's type reference for the facade's return type — the bare name for a non-generic proxy,
/// or the opaque-erased form (`_<Variant>_<Proxy><some Constraint>`) for a generic one, mirroring how the
/// seed-scope façade erases its opaque axes. The proxy's generic parameter is inferred from the constructed
/// closure at the `return` site; the annotation names the erased shape so the field's `some P` closure
/// return doesn't leak an unspellable type.
private func variantProxyTypeReference(_ proxy: DiscoveredScopeBoundType) -> String {
    guard !proxy.genericParameterNames.isEmpty else { return proxy.typeName }
    let erased = proxy.genericParameterNames.map { name in
        proxy.genericParameterConstraints[name].map { "some \($0)" } ?? name
    }
    return "\(proxy.typeName)<\(erased.joined(separator: ", "))>"
}
