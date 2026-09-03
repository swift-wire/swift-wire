// Scope-entry thunk emission — the closure a bridging contributor proxy carries.
//
// A `.singleton` proxy over a `@Scoped(seed:)` subject takes a `_wireEnterScope` thunk. `appendStruct`
// emits it here, inside the bootstrap body, so the closure captures the singleton locals the subject's
// scope borrows. The construction reuses the ordinary per-binding emitter (`constructionExpression`),
// with the scope's borrows resolving to the captured locals (borrow property-name == singleton
// local-name) and the seed to the closure parameter. Its companion — the `.scopeCapture` ordering deps
// that make the proxy sort after those singletons — is `ScopeEntryLinking`.

/// Emit the scope-entry thunk for a bridging contributor proxy — a `@Sendable (Seed) async throws ->
/// Subject` closure that constructs the proxy's `@Scoped(seed:)` subject fresh from a seed and returns
/// it. Captures the singleton locals the scope borrows (they resolve to the same identity names the
/// enclosing bootstrap already bound). The proxy's `_wireEnterScope` argument resolves to this thunk's
/// local by identity naming, with no override. `scopes` maps seed-type expression → the seed scope's
/// emission for this graph; returns `nil` for a non-bridge proxy (no scope-entry dependency, or no
/// matching scope).
/// The scope-entry thunk lines for `binding` when it is a bridging contributor proxy (a scope-bound
/// type carrying a `_wireEnterScope` dependency), else `nil` — the entry point the bootstrap emitter
/// calls per binding. Borrowed app-singletons resolve to captured locals of the same identity name: in the
/// bootstrap body those are the singletons it already constructed; in the contributor-proxy facade they are
/// the `let <prop> = _wireGraph.<prop>` locals the facade binds outside this `@Sendable` thunk (see
/// `reachableBorrows(forBridgeProxy:scopes:)`), so the thunk captures Sendable values, not the graph.
func scopeEntryThunkLines(
    forBridgeProxy binding: DiscoveredBinding,
    scopes: [String: SeedScopeEmission]
) -> [String]? {
    guard case .scopeBound(let proxy) = binding else { return nil }
    // An **aggregate** proxy bridges into one scope per seeded subject, so every `.scopeEntryThunk`
    // dependency gets its own closure — each named after its own thunk type, which is what the proxy's
    // construction argument resolves to. A per-subject proxy has exactly one, so this is the shipped
    // single-thunk path unchanged.
    let scopeEntries = proxy.dependencies.filter { $0.kind == .scopeEntryThunk }
    guard !scopeEntries.isEmpty else { return nil }
    // A *generic* bridge proxy is a lift node: the graph specialised its subject at the opaque backend
    // (`MeController<Repository>` → `MeController<some TodoRepository>`). Apply the same lift substitution
    // to the thunk's declared type — format-preserving, unlike the whitespace-canonicalised identity form,
    // which `async throws` needs — so the emitted thunk's type, local name, and return match the proxy's
    // specialised construction argument, not the raw generic form (whose bare `Repository` isn't in scope
    // in `_wireBootstrap`). A non-generic proxy is not a lift node, so its thunk type is unchanged.
    let lines = scopeEntries.flatMap { entry -> [String] in
        guard let descriptor = entry.scopeEntry else { return [] }
        return scopeEntryThunkLines(
            descriptor: descriptor,
            thunkType: liftSpecialised(entry.type, in: binding),
            specialising: { liftSpecialised($0, in: binding) },
            scopes: scopes
        ) ?? []
    }
    return lines.isEmpty ? nil : lines
}

/// Substitute a lift node's determined generic parameters with their `some Constraint` form in `type`,
/// preserving the type's spelling (mirrors `bridgedDependencyIdentity`'s Rule 2b, format-preserving).
func liftSpecialised(_ type: String, in binding: DiscoveredBinding) -> String {
    guard binding.isLiftNode else { return type }
    let canonical = canonicalTypeName(type)
    var substitutions: [String: String] = [:]
    for (parameter, constraint) in binding.genericParameterConstraints
    where constraintIsDetermining(constraint) && parameterAppearsAsGenericArgument(parameter, in: canonical) {
        substitutions[parameter] = "some \(constraint)"
    }
    return substitutions.isEmpty ? type : substitutingIdentifierTokens(type, substitutions)
}

private func scopeEntryThunkLines(
    descriptor: ScopeEntryDescriptor,
    thunkType: String,
    specialising liftSpecialised: (String) -> String,
    scopes: [String: SeedScopeEmission]
) -> [String]? {
    guard let scope = scopes[descriptor.seed] else { return nil }
    let seed = descriptor.seed
    let doubles = descriptor.doubles
    // The *construction locals* are named from the lift-specialised spelling (`MeController<some
    // TodoRepository>`), because that is what the bootstrap body binds them under. The entry struct's
    // *field* names come from the unspecialised descriptor, since the declaration is written once against
    // the proxy's own generic parameters. The two diverge only for a lift node — which is exactly the case
    // that would otherwise pair a field name with a local nothing bound.
    let thunkLocal = identifierName(forType: thunkType, key: nil)
    let seedLocal = identifierName(forType: seed, key: nil)
    let subjectLocal = identifierName(forType: liftSpecialised(descriptor.subject), key: nil)
    // A `.yieldsFromScope` binding is returned alongside the subject, so it is a construction root as much
    // as the subject is: nothing else in the scope depends on it, and pruning from the subject alone would
    // drop it and everything under it. Its local is named the same way every other binding's is, so the
    // `return` below references the line the loop already emits.
    let yieldLocals = descriptor.yields.map { identifierName(forType: liftSpecialised($0), key: nil) }

    // Emit the closure with its parameter, effects, and `@Sendable` inline, letting Swift infer the return
    // type from the body — rather than annotating the `let` with the return type. A subject generic over
    // the opaque backend then resolves to the *concrete* backend the body constructs
    // (`MeController<CouchDBTodoRepository>`) instead of an unspellable `some P` closure-return type, and
    // the proxy's generic parameter is inferred from the passed closure. (`thunkType` still names the local
    // so the proxy's construction argument resolves to it by identity.)
    // Per-root reachability: construct — and, below, tear down — only the bindings reachable from
    // the routed controller, so two controllers sharing a seed don't build each other's subgraphs. `nil`
    // means no pruning (the scope carried no edges, or no root binding was found): whole-scope, the
    // the unpruned behaviour. Yields widen the root *set* rather than replacing it — a yielded binding and
    // the subject are two independent entry points into the same scope, and the union is what both need.
    let reachable = reachableBindings(from: [subjectLocal] + yieldLocals, in: scope)

    // Rule 3 — existential aliases for the promotions this thunk actually constructs, so the pruned
    // set never binds an alias for a controller it doesn't serve. A promoted *borrowed* producer is
    // captured from the bootstrap body under its own name but its alias may not be (the bootstrap
    // binds one only if it promotes too), so that alias is bound up front here off the captured local.
    let aliases = scopeExistentialAliasPlan(
        scope,
        constructedHere: scope.topologicalOrder.filter { reachable?.contains($0.identity) ?? true }
    )

    // A test-graph variant threads a `doubles` value in alongside the seed; a `@BindType`d binding in the
    // scope resolves to a field on it (its construction line is `let <field> = doubles.<field>`, emitted by
    // the ordinary per-binding path since the binding is a `doubles.<field>` provider). The parameter's
    // local name is the fixed `doubles`, matching those providers' access paths. `nil` is the production
    // thunk (seed only). The `doubles` type rides the thunk type, so it survives the `liftSpecialised`.
    let parameterList = doubles.map { "\(seedLocal): \(seed), doubles: \($0)" } ?? "\(seedLocal): \(seed)"
    var body: [String] = []
    for alias in aliases.upFront {
        body.append(contentsOf: existentialAliasLines(alias, boundTo: alias.producerLocalName, indent: "        "))
    }
    // What this thunk actually constructs: the reachable set, minus the borrowed singletons (which resolve
    // to the captured bootstrap local of the same name) and minus the seed's redundant `let seed = seed`.
    let constructed = scope.topologicalOrder.filter { binding in
        if let reachable, !reachable.contains(binding.identity) { return false }
        let name = propertyName(for: binding)
        if scope.borrowedBindingPropertyNames.contains(name) { return false }
        return name != constructionExpression(for: binding)
    }
    // A request scope is scheduled on the same terms the bootstrap is, and for a better reason:
    // this runs per request rather than once. The regions are computed over the *pruned* set, so two roots
    // into one scope can reach different plans, which is correct — each builds only what it needs.
    // A group binding that reads a *closure* local — the seed, `doubles`, or a borrowed singleton — would
    // need that local as a stored property on the building struct, and its type is not something the region
    // computation can know: it is a local beside the struct, not a binding in the order. So a scope whose
    // scheduled region reaches outside the construction set keeps the chain. Every other exclusion is
    // `schedulerPlan`'s; this one is the seam's, and it is the price of declaring the struct locally.
    let plan = schedulerPlan(for: constructed, seedScopes: [:], existentialPromotions: [])
        .flatMap { $0.crossingLocals.isEmpty ? $0 : nil }
    // Issue #21 — the scope's own `@Teardown` bindings, recorded as they are built so a thunk that throws
    // partway can unwind them. Per *request*: the accumulator is declared inside the thunk, not beside it,
    // because two requests entering the same scope share nothing.
    let torn = constructed.contains { $0.teardown != nil }
    body.append(
        contentsOf: scopeConstructionLines(
            plan: plan,
            constructed: constructed,
            aliases: aliases,
            accumulatesTeardown: torn
        )
    )
    // When the scope schedules, everything after the seam — the teardown closure and the entry struct —
    // lives inside the group closure, whose value *is* the entry. So the tail indents one level further and
    // the closure is closed before the thunk's own brace.
    let tailIndent = plan == nil ? { (lines: [String]) in lines } : indentedForGroupBody
    // The scope's teardown closure — the reverse-order `@Teardown` walk for the scope's own bindings (not
    // the borrowed singletons, which are torn down at app scope), pruned to the reachable set so a request
    // to one controller never tears down a sibling's binding. Captures the construction locals above, so it
    // runs against each binding's concrete instance. Returned alongside the subject; the witness runs it
    // after the response. Consistent with the graph's captured `_wireTeardown`.
    body.append(
        contentsOf: tailIndent(
            torn
                ? accumulatedTeardownClosureLines(
                    indent: "        ",
                    local: scopeTeardownLocalName,
                    type: scopeEntryTeardownType,
                    accumulator: scopeTeardownAccumulator
                )
                : scopeTeardownClosureLines(scope, local: scopeTeardownLocalName, reachable: reachable)
        )
    )
    // The entry struct, constructed with labels. Its generic arguments are *inferred* from these values
    // rather than written: a subject over an opaque backend has no spellable name here, and annotating it
    // fails with two identically-printed opaque types refusing to convert to each other.
    let arguments =
        ([(scopeEntrySubjectFieldName, subjectLocal)]
        + zip(descriptor.yields, yieldLocals).map { (identifierName(forType: $0, key: nil), $1) }
        + [(scopeTeardownLocalName, scopeTeardownLocalName)])
        .map { "\($0): \($1)" }
        .joined(separator: ", ")
    body.append(contentsOf: tailIndent(["        return \(descriptor.entryStructName)(\(arguments))"]))
    if plan != nil { body.append(contentsOf: indentedForGroupBody(schedulerBootstrapClosingLines())) }

    // Same trigger as the bootstrap's: something to unwind, and something that can throw. A `do` whose body
    // cannot throw is `'catch' block is unreachable`, in generated code.
    var lines: [String] = ["    let \(thunkLocal) = { @Sendable (\(parameterList)) async throws in"]
    // The accumulator is declared whenever there is anything to tear down, because the *happy* path folds
    // it too. The `do`/`catch` is the narrower question: only a thunk that can throw has an unwind path,
    // and a `do` whose body cannot throw is `'catch' block is unreachable` in generated code.
    let unwinds = torn && constructionCanThrow(body)
    if torn {
        lines.append(
            contentsOf: teardownAccumulatorLines(indent: "        ", name: scopeTeardownAccumulator)
        )
    }
    if unwinds { lines.append("        do {") }
    lines.append(contentsOf: unwinds ? indentedForGroupBody(body) : body)
    if unwinds {
        lines.append(
            contentsOf: partialTeardownCatchLines(indent: "        ", accumulator: scopeTeardownAccumulator)
        )
    }
    lines.append("    }")
    return lines
}

/// The scope's accumulator name. Distinct from the bootstrap's so the two never collide when a thunk is
/// emitted inside a bootstrap body that has one of its own — which is every scheduled graph with a
/// `@Teardown` binding.
let scopeTeardownAccumulator = "_wireScopeTeardownActions"

/// One scope entry's construction body — the linear chain, or the prefix / group / suffix split when the
/// scope has two async bindings that can overlap.
///
/// The scheduled form differs from the bootstrap's in one structural way, and it is what
/// `crossingLocals` exists for: the building struct is declared **inside the thunk**, beside the closure's
/// own locals rather than at module scope, so a bare name in a construction expression resolves to nothing
/// from inside its methods. The seed, `doubles` and every borrowed singleton therefore cross the seam as
/// stored properties exactly as a prefix binding does — where at app scope those same names would have
/// resolved to module-scope declarations and needed nothing.
private func scopeConstructionLines(
    plan: ConstructionRegions?,
    constructed: [DiscoveredBinding],
    aliases: ExistentialAliasPlan,
    accumulatesTeardown: Bool
) -> [String] {
    func chain(_ bindings: [DiscoveredBinding], indent: String) -> [String] {
        var lines: [String] = []
        for binding in bindings {
            let name = propertyName(for: binding)
            lines.append("\(indent)let \(name) = \(constructionExpression(for: binding))")
            lines.append(
                contentsOf: existentialAliasLines(
                    aliases.afterConstruction[binding.identity],
                    boundTo: name,
                    indent: indent
                )
            )
            if accumulatesTeardown {
                lines.append(
                    contentsOf: teardownActionAppendLines(
                        for: binding,
                        indent: indent,
                        accumulator: scopeTeardownAccumulator
                    )
                )
            }
        }
        return lines
    }
    guard let plan else { return chain(constructed, indent: "        ") }

    var lines = chain(plan.prefix, indent: "        ")
    let tornInGroup = plan.group.filter { $0.teardown != nil }
    // No `_wireSendableChecks` here, deliberately: `#sourceLocation` is a top-of-file directive and
    // derails the parse from inside a closure. What is lost is the *located* half of the diagnostic; the
    // marker enum's own error still names the case, the type and — in a note — the user's declaration,
    // which was measured as the better of the two anyway.
    // Two levels, not one: these are emitted for module scope, where the graph's own declarations sit at
    // column zero, and here they are two levels in — inside the thunk closure, inside the bootstrap body.
    lines.append(
        contentsOf: indentedForGroupBody(
            indentedForGroupBody(
                schedulerTaskResultEnumLines(structName: scopeSchedulerName, regions: plan, isLocal: true)
            )
        )
    )
    lines.append(
        contentsOf: indentedForGroupBody(
            indentedForGroupBody(
                schedulerBuildingStructLines(structName: scopeSchedulerName, regions: plan, isLocal: true)
            )
        )
    )
    lines.append(
        contentsOf: indentedForGroupBody(
            schedulerBootstrapOpeningLines(
                structName: scopeSchedulerName,
                regions: plan,
                tornInGroup: accumulatesTeardown ? tornInGroup : [],
                teardownAccumulator: scopeTeardownAccumulator
            )
        )
    )
    lines.append(contentsOf: indentedForGroupBody(schedulerSeamLines(regions: plan)))
    // A scheduled binding records its action after the seam, where it is a local again — the drain's own
    // `catch` covers the case where the throw came first.
    for binding in tornInGroup where accumulatesTeardown {
        lines.append(
            contentsOf: indentedForGroupBody(
                teardownActionAppendLines(
                    for: binding,
                    indent: "        ",
                    accumulator: scopeTeardownAccumulator
                )
            )
        )
    }
    lines.append(contentsOf: indentedForGroupBody(chain(plan.suffix, indent: "        ")))
    return lines
}

/// The scope scheduler's type names. One thunk declares them, locally, so there is exactly one of each in
/// scope and no per-(scope, root) naming problem to solve.
private let scopeSchedulerName = "_WireScopeWireGraph"

/// The binding identities reachable from the routed controller over the scope's resolved edges — a BFS
/// rooted at the subject binding (found by its construction-local name). Returns `nil` (no pruning) when
/// the scope carries no edges or the subject binding isn't found, preserving whole-scope construction.
///
/// Also the basis of a subject's doubles set: a seed scope is shared by every controller on that seed, so
/// "which doubles does *this* controller consume" is this set intersected with the scope's doubles-sourced
/// bindings.
package func reachableBindings(from subjectLocal: String, in scope: SeedScopeEmission) -> Set<BindingIdentity>? {
    reachableBindings(from: [subjectLocal], in: scope)
}

/// The multi-root form: the union of what is reachable from each root. A scope entry that yields bindings
/// alongside its subject has several independent entry points — nothing in the scope depends on a yielded
/// binding, so it is a root in its own right and pruning from the subject alone would drop it.
///
/// A root that names no binding in this scope is **skipped rather than fatal**: the union of the rest is
/// still the right construction set, and a yield naming an unbound type is reported by
/// `scopeYieldDiagnostics`, which can say something useful about it. Failing here would trade one good
/// diagnostic for whole-scope construction and a compile error in generated code.
///
/// `nil` (no pruning at all) when the scope carries no edges or *no* root was found, which is the
/// single-root behaviour unchanged.
package func reachableBindings(from roots: [String], in scope: SeedScopeEmission) -> Set<BindingIdentity>? {
    guard !scope.edges.isEmpty else { return nil }
    let rootIdentities = roots.compactMap { root in
        scope.topologicalOrder.first(where: { propertyName(for: $0) == root })?.identity
    }
    guard !rootIdentities.isEmpty else { return nil }
    var reachable: Set<BindingIdentity> = []
    var queue = rootIdentities
    while let identity = queue.popLast() {
        guard reachable.insert(identity).inserted else { continue }
        queue.append(contentsOf: scope.edges[identity] ?? [])
    }
    return reachable
}

/// The borrowed app-singletons the pruned scope-entry thunk for `binding` references — the borrows in the
/// reachable set from the routed subject, as `(property, accessPath)` pairs (`accessPath` is the graph read,
/// e.g. `_wireGraph.userStore`). The contributor-proxy facade binds each as a Sendable local **outside** its
/// `@Sendable` thunk (`let userStore = _wireGraph.userStore`), so the thunk captures the borrowed value, not
/// the non-Sendable graph. Pruned to the reachable set so an unreferenced borrow produces no dead local. The
/// bootstrap body needs none of this — its borrows are already singleton locals. Empty when `binding` isn't
/// a bridge proxy, its scope is absent, or the reachable set borrows nothing.
func reachableBorrows(
    forBridgeProxy binding: DiscoveredBinding,
    scopes: [String: SeedScopeEmission]
) -> [(property: String, accessPath: String)] {
    guard case .scopeBound(let proxy) = binding,
        let descriptor = proxy.scopeEntryDependencies.first?.scopeEntry,
        let scope = scopes[descriptor.seed]
    else { return [] }
    // The same root set the thunk itself prunes with — a borrow reached only through a yielded binding is
    // still referenced by the emitted body, so the facade must bind a local for it.
    let roots = ([descriptor.subject] + descriptor.yields).map {
        identifierName(forType: liftSpecialised($0, in: binding), key: nil)
    }
    let reachable = reachableBindings(from: roots, in: scope)
    var borrows: [(property: String, accessPath: String)] = []
    for scopeBinding in scope.topologicalOrder {
        let property = propertyName(for: scopeBinding)
        guard scope.borrowedBindingPropertyNames.contains(property),
            reachable?.contains(scopeBinding.identity) ?? true,
            case .provider(let provider) = scopeBinding
        else { continue }
        borrows.append((property: property, accessPath: provider.accessPath))
    }
    return borrows
}

/// The scope-entry thunk's teardown-closure local name. `wireMVC`-free (this is swift-wire), just a
/// bootstrap-local identifier the thunk returns.
let scopeTeardownLocalName = "_wireScopeTeardown"

/// The lines for the scope's teardown closure, emitted inside the scope-entry thunk. Mirrors the graph's
/// captured `_wireTeardown` (reverse construction order, errors collected not thrown) but scoped to the
/// seed scope's own `@Teardown` bindings and indented for the thunk body. Always emitted (an empty scope
/// yields `{ … return errors }` with no calls) so the thunk's return type stays uniform.
func scopeTeardownClosureLines(
    _ scope: SeedScopeEmission,
    local: String,
    reachable: Set<BindingIdentity>?
) -> [String] {
    let torn = scope.topologicalOrder.reversed().filter { binding in
        binding.teardown != nil
            && !scope.borrowedBindingPropertyNames.contains(propertyName(for: binding))
            && (reachable?.contains(binding.identity) ?? true)
    }
    let mutatesErrors = torn.contains { binding in
        switch binding.teardown?.kind {
        case .member(_, _, let isThrowing): return isThrowing
        case .action: return true
        case nil: return false
        }
    }
    var lines: [String] = [
        "        let \(local): \(scopeEntryTeardownType) = {",
        "            \(mutatesErrors ? "var" : "let") errors: [any Error] = []",
    ]
    for binding in torn {
        lines.append(contentsOf: teardownCallLines(for: binding).map { "    " + $0 })
    }
    lines.append("            return errors")
    lines.append("        }")
    return lines
}
