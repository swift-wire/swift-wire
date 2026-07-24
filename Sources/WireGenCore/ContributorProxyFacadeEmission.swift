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
/// production thunk uses, driven from `scope`), and constructs the variant proxy. The facade is not
/// `async`/`throws`: it only *builds* the proxy (the closure captures the graph's borrows and the doubles
/// ride the later `_wireEnterScope` call), so entering the scope stays on the consumer's per-request path.
///
/// `proxy` is the variant proxy binding (its `_wireEnterScope` dependency already re-typed to carry the
/// doubles); `scope` is the matching variant seed scope (carrying `doublesType` + `edges`);
/// `parentGraphTypeReference` is the opaque-erased reused graph type (`_WireGraph`, or `_WireGraph<some P>`
/// when the app graph lifts opaque axes); `facadeMethodName` is the `Wire` static-method name a consumer
/// calls to obtain the proxy.
package func renderContributorProxyFacade(
    proxy: DiscoveredScopeBoundType,
    scope: SeedScopeEmission,
    parentGraphTypeReference: String,
    facadeMethodName: String
) -> String {
    let wireGraphExternal = wireGraphParameterLabel(forType: scope.parentGraphType)
    let wireGraphInternal = wireGraphParameterInternalName(forType: scope.parentGraphType)

    // Borrows read off the `wireGraph` parameter (`_wireGraph.<prop>`) rather than reconstructing the app
    // singletons — the facade doesn't rebuild the graph, it borrows it. The thunk captures the parameter.
    let borrowAccessPaths = borrowedAccessPaths(in: scope)
    let resolveBorrow: (String) -> String? = { borrowAccessPaths[$0] }

    let thunkLines =
        scopeEntryThunkLines(
            forBridgeProxy: .scopeBound(proxy),
            scopes: [scope.seedTypeExpression: scope],
            resolvingLocal: resolveBorrow
        ) ?? []
    let construction = constructionExpression(for: .scopeBound(proxy), resolvingLocal: resolveBorrow)

    let signature =
        "\(facadeMethodName)(\(wireGraphExternal) \(wireGraphInternal): \(parentGraphTypeReference))"
    var lines: [String] = ["extension Wire {"]
    lines.append("    static func \(signature) -> \(variantProxyTypeReference(proxy)) {")
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
