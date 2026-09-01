/// Emission of one graph *struct* and its `_wireBootstrap` free function — the shape the default graph,
/// every `@Container` graph and every testing-variant app graph all share. Split out of
/// `CodeEmission.swift` (file-length) but part of the same `renderWireGraph` pipeline, alongside
/// `IntrospectionEmission.swift`; the shared `propertyName` helper lives there.
///
/// The pair is emitted together because the struct's stored properties and the bootstrap's memberwise
/// init have to agree exactly, and since M7c.1 neither is decided here — both are reserved as placeholder
/// lines and filled by `resolveStoragePatches` once the whole file exists. See `Retention.swift`.

/// The inputs every graph struct in one generated file shares. The default graph, each `@Container`
/// graph and each testing-variant app graph are the same emission over a different binding order, so
/// these are named once here rather than threaded through every call.
///
/// `isDefaultOrVariant` is the one per-graph decision that lives here rather than at the call site,
/// because it selects from `graphConformances`: conformances are emitted onto the default graph and its
/// variants, never onto a `@Container`'s (`appendAllGraphConformances` puts them there), so only those
/// graphs carry a conformance-named aggregate as a root. It mirrors `pruningPolicy`'s
/// `containerKey == nil` test.
struct GraphEmissionContext {
    /// The seed scopes borrowing from a given parent graph type, keyed by seed type expression.
    let seedScopes: (String) -> [String: SeedScopeEmission]
    let existentialPromotions: [ExistentialPromotion]
    let graphInputsType: String?
    let graphConformances: [DiscoveredGraphConformance]
    let multibindingKeys: [DiscoveredMultibindingKey]
    let externalModules: Set<String>

    /// The M7b root model for one graph — what it must construct even though nothing in it consumes
    /// them, and since M7c.1 the core of what it *stores*. See `Retention.swift`.
    func roots(for order: [DiscoveredBinding], isDefaultOrVariant: Bool) -> Set<BindingIdentity> {
        declaredRoots(
            in: bindingsByIdentity(order),
            multibindingKeys: multibindingKeys,
            conformances: isDefaultOrVariant ? graphConformances : [],
            externalModules: externalModules
        )
    }
}

/// The generated file as it is being built: the source lines, the `Wire` façade entry each graph
/// contributes, and the storage decision each graph defers to `resolveStoragePatches`.
///
/// One value rather than three `inout` parameters, because every emission that appends a line may also
/// append an entry and a patch, and keeping them together is what lets `appendStruct` reserve a line now
/// and fill it after the whole file exists.
struct WireFileBuffer {
    var lines: [String] = []
    var bootstrapEntries: [BootstrapEntry] = []
    var storagePatches: [GraphStoragePatch] = []
}

/// The seed scopes of `orders` grouped by the parent graph they borrow from, as a lookup keyed by seed
/// type expression — a bridging contributor proxy in a given graph builds its subject from the seed
/// scope over that same graph.
func seedScopeLookup(_ orders: [SeedScopeEmission]) -> (String) -> [String: SeedScopeEmission] {
    let byParent = Dictionary(grouping: orders, by: { $0.parentGraphType })
    return { parent in
        Dictionary(
            (byParent[parent] ?? []).map { ($0.seedTypeExpression, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }
}

/// The stored-property type for a binding on the generated `_WireGraph` struct:
/// - a bare `some P` lift node uses its own lifted parameter (`T0`);
/// - a structural lift node reuses its dependencies' parameters, spelled
///   `Controller<T1>` — each `some <constraint>` sub-term replaced by the lifted
///   parameter of the matching bridge target;
/// - everything else uses its concrete `boundTypeReference` (qualified for a
///   nested `@Singleton`).
func wireGraphFieldType(
    for binding: DiscoveredBinding,
    liftedParameterForIdentity: [String: String]
) -> String {
    if let parameter = liftedParameterForIdentity[canonicalTypeName(binding.boundType)] {
        return parameter
    }
    guard binding.allGenericParametersDetermined else {
        return binding.boundTypeReference
    }
    let arguments = binding.genericParameterNames.map { parameter -> String in
        let constraint = binding.genericParameterConstraints[parameter] ?? ""
        return liftedParameterForIdentity[canonicalTypeName("some \(constraint)")]
            ?? "some \(constraint)"
    }
    return "\(binding.boundTypeReference)<\(arguments.joined(separator: ", "))>"
}

/// Emit one `_<Name>WireGraph` struct + matching `_wireBootstrap<Name>`
/// free function pair. Called once for the default graph and once per
/// container; the same shape carries through for both.
/// The opaque-erased type reference for a graph struct: `\(structName)<some P0, …>` when the
/// graph has opaquely-bound (`@Singleton(as:)`) bindings that lift generic parameters, or the
/// bare `structName` otherwise. This is the type the bootstrap/façade returns, and the type any
/// seed scope borrowing from this graph must name for its `wireGraph:` parameter — a bare
/// `_WireGraph` there fails to compile once the graph is generic.
package func openGraphTypeReference(structName: String, topologicalOrder: [DiscoveredBinding]) -> String {
    let liftedConstraints =
        topologicalOrder
        .filter { $0.boundType.hasPrefix("some ") }
        .map { String($0.boundType.dropFirst("some ".count)) }
    guard !liftedConstraints.isEmpty else { return structName }
    return "\(structName)<" + liftedConstraints.map { "some \($0)" }.joined(separator: ", ") + ">"
}

/// The generic parameters an opaquely-bound (`@Singleton(as:)`) graph lifts onto its struct.
///
/// Each `some P` binding lifts one, so a stored `some P` property refers to one concrete type rather than
/// a fresh opaque type per access; the parameter's constraint is the binding's declared protocol, and the
/// bootstrap's structural opaque return type binds it. `openGraphTypeReference` is the erased form of the
/// same lift — what callers outside the struct name it by.
struct GraphLift {
    /// `<T0: Greeting, T1: TaskRepo>`, or empty when the graph lifts nothing.
    let genericClause: String
    /// Each bare `some P` identity to its lifted parameter (`some TaskRepo` → `T1`), so a structural lift
    /// node can reuse it and spell itself `Controller<T1>`.
    let parameterForIdentity: [String: String]

    init(_ topologicalOrder: [DiscoveredBinding]) {
        let opaqueBindings = topologicalOrder.filter { $0.boundType.hasPrefix("some ") }
        let constraints = opaqueBindings.map { String($0.boundType.dropFirst("some ".count)) }
        parameterForIdentity = Dictionary(
            opaqueBindings.enumerated().map { (canonicalTypeName($0.element.boundType), "T\($0.offset)") },
            uniquingKeysWith: { first, _ in first }
        )
        genericClause =
            constraints.isEmpty
            ? ""
            : "<" + constraints.enumerated().map { "T\($0.offset): \($0.element)" }.joined(separator: ", ") + ">"
    }
}

func appendStruct(
    structName: String,
    bootstrapFunction: String,
    bootstrapMethod: String,
    topologicalOrder: [DiscoveredBinding],
    isDefaultOrVariant: Bool = true,
    context: GraphEmissionContext,
    into file: inout WireFileBuffer
) {
    let seedScopes = context.seedScopes(structName)
    let existentialPromotions = context.existentialPromotions
    // A container graph is a separate wiring whose bindings never include the `@GraphInputs` providers,
    // so its bootstrap takes no `inputs:` parameter.
    let graphInputsType = isDefaultOrVariant ? context.graphInputsType : nil
    let roots = context.roots(for: topologicalOrder, isDefaultOrVariant: isDefaultOrVariant)
    let lift = GraphLift(topologicalOrder)
    // The `_wireBootstrap` free function and the `Wire` façade both return the
    // opaque-erased form `\(structName)<some P0, …>`; Swift infers each parameter
    // from the concrete values the bootstrap returns.
    let openReturnType = openGraphTypeReference(structName: structName, topologicalOrder: topologicalOrder)

    // The bootstrap entry point lives on the `Wire` façade, not on the struct
    // — a non-generic call site that stays `Wire.\(bootstrapMethod)()` whether
    // or not the struct carries lifted parameters.
    // `@GraphInputs` adds the one parameter: values the graph cannot construct for itself, supplied by
    // the caller. Absent, the signature is unchanged — every existing call site still reads
    // `Wire.bootstrap()`.
    let inputsParameter = graphInputsType.map { "inputs \(graphInputsParameterName): \($0)" } ?? ""
    let inputsArgument = graphInputsType == nil ? "" : "inputs: \(graphInputsParameterName)"
    file.bootstrapEntries.append(
        BootstrapEntry(
            signature: "\(bootstrapMethod)(\(inputsParameter)) async throws -> \(openReturnType)",
            body: "try await \(bootstrapFunction)(\(inputsArgument))"
        )
    )

    file.lines.append("")
    // No explicit `Sendable` — see the matching comment in
    // `appendSeedScopeStruct` for the rationale. Auto-derivation
    // handles the conformance when all bindings are Sendable; the
    // user gets compile-time feedback at their use site if one
    // isn't.
    // Conforms to `Introspectable` and `Teardownable` (the `introspect()` and — when
    // there are `@Teardown` bindings — `teardown()` below satisfy them; the empty
    // teardown falls back to a protocol default) so a facade can accept `some
    // Introspectable`/`some Teardownable` without naming the concrete graph type.
    file.lines.append("internal struct \(structName)\(lift.genericClause): Introspectable, Teardownable {")

    // Stored properties — one per binding, type-derived name, no
    // prefix. Users access these as `graph.logger`, `graph.userService`.
    // A bare `some P` lift node uses its lifted parameter (`T0`); a structural
    // lift node reuses its dependencies' parameters (`Controller<T1>`); the rest
    // use `boundTypeReference` so nested `@Singleton`s inside a `@Container`
    // qualify with the enclosing path (`TestContainer.MockService`) — required
    // because this struct lives at module scope.
    // Bindings carrying `@Teardown`, in reverse construction order (dependents before the
    // dependencies they hold) — computed once and reused across the emission below: the graph
    // gets a captured `_wireTeardown` property only when this is non-empty, the bootstrap builds
    // that closure from it, and `teardown()` delegates to it.
    let torn = topologicalOrder.reversed().filter { $0.teardown != nil }
    // M7c.1 — which of these are *stored* depends on what the rest of the file reads off this graph, and
    // that text does not exist yet. Reserve the slot and let `resolveStoragePatches` fill it once every
    // scope, facade and conformance has been emitted. Same for the memberwise-init call below, whose
    // argument list has to match the property list exactly.
    let propertyBlockIndex = file.lines.count
    file.lines.append(storagePlaceholder)
    // The captured teardown, built at bootstrap where each binding's concrete type is
    // live (see `bootstrapTeardownClosureLines`). Only emitted when something needs
    // tearing down; the `teardown()` method below delegates to it.
    if !torn.isEmpty {
        file.lines.append("    let _wireTeardown: @Sendable () async -> [any Error]")
    }
    file.lines.append(contentsOf: introspectionMethodLines(topologicalOrder))
    file.lines.append(contentsOf: teardownMethodLines(torn))
    file.lines.append("}")

    // Free function at module scope — does the actual construction.
    // Module-scope context means bare `appName` / `logger` references
    // resolve cleanly to module-scope `@Provides` declarations,
    // bypassing the type-member shadow that would happen inside
    // the struct's `static func bootstrap()` directly.
    file.lines.append("")
    file.lines.append("private func \(bootstrapFunction)(\(inputsParameter)) async throws -> \(openReturnType) {")

    guard !topologicalOrder.isEmpty else {
        // Empty graph — no bindings, return the empty memberwise init. No patch is recorded, so the
        // reserved property slot stays a placeholder and the resolver's final sweep drops it.
        file.lines.append("    \(structName)()")
        file.lines.append("}")
        return
    }

    let aliases = bootstrapExistentialAliasPlan(existentialPromotions, constructedIn: topologicalOrder)

    // Construction body — bare local names. `let logger = logger`
    // works because Swift resolves the RHS in the outer scope before
    // binding the LHS local, so the local shadows cleanly.
    for binding in topologicalOrder {
        // A builder aggregate emits a `@resultBuilder`-annotated local
        // function (capturing the contributor locals) plus its call —
        // the attribute can't sit on a closure, so it can't be a single
        // expression like the other forms.
        if case .aggregate(let aggregate) = binding, aggregate.flavour == .builder {
            file.lines.append(contentsOf: builderFoldLines(aggregate))
            continue
        }
        // A bridging contributor proxy (`.contributesProxy` over a `@Scoped(seed:)` subject) takes a
        // `_wireEnterScope` scope-entry thunk. Emit that closure here — in the bootstrap body, so it
        // captures the singleton locals the scope borrows — right before the proxy's own construction
        // line, whose `_wireEnterScope` argument resolves to the thunk's local.
        if let thunkLines = scopeEntryThunkLines(forBridgeProxy: binding, scopes: seedScopes) {
            file.lines.append(contentsOf: thunkLines)
        }
        let local = propertyName(for: binding)
        let construction = constructionExpression(for: binding)
        // A specialised generic `@Provides func` can't be called with explicit
        // type arguments, so annotate the local with the concrete return type
        // and let Swift infer them (`let repo: Repository<DynamoDBTable> =
        // makeRepo()`). Harmless when the value arguments already determine them.
        if case .provider(let provider) = binding, !provider.concreteGenericArguments.isEmpty {
            file.lines.append("    let \(local): \(binding.boundTypeReference) = \(construction)")
        } else {
            file.lines.append("    let \(local) = \(construction)")
        }
        // Rule 3 — this binding is read by an `any P` consumer somewhere in this
        // body. Bind the existential once, here, so the boxing is a single visible
        // line the consumers share rather than a conversion repeated at each
        // argument site. See `ExistentialPromotion`.
        file.lines.append(
            contentsOf: existentialAliasLines(aliases.afterConstruction[binding.identity], boundTo: local)
        )
    }

    // Post-init member injection block — emits after all locals
    // are bound so each injection's target references are in
    // scope. Empty when no `@Inject weak var` sugar or
    // `@Inject func` member injections exist in the graph.
    file.lines.append(contentsOf: renderMemberInjections(for: topologicalOrder))

    // Captured teardown — built here, where each binding's local carries its
    // concrete type, then handed to the graph. This is what lets `@Teardown`
    // work on an opaquely-bound (`@Singleton(as:)`) type: the graph stores it as
    // a lifted `some P` (no concrete member visible), but the closure closes over
    // the concrete local, so the member call type-checks.
    file.lines.append(contentsOf: bootstrapTeardownClosureLines(torn))

    // Final return — memberwise init takes one argument per stored
    // property in declaration order. Label is the property name;
    // value is the matching local. The captured teardown, when present,
    // is the trailing stored property and is passed last.
    let returnLineIndex = file.lines.count
    file.lines.append(storagePlaceholder)

    file.lines.append("}")

    file.storagePatches.append(
        GraphStoragePatch(
            structName: structName,
            parentLocal: wireGraphParameterInternalName(forType: structName),
            topologicalOrder: topologicalOrder,
            roots: roots,
            liftedParameterForIdentity: lift.parameterForIdentity,
            hasTeardown: !torn.isEmpty,
            propertyBlockIndex: propertyBlockIndex,
            returnLineIndex: returnLineIndex
        )
    )
}

/// Emit a per-container / per-`TestingKey`-variant graph for each named order — the same struct +
/// `_wireBootstrap<Name>` + `Wire.bootstrap<Name>()` shape as the default graph, the name discriminating
/// them at module scope. Container and variant names are disjoint, so the merge is collision-free and
/// deterministic. A variant order is production minus the dropped (`@BindType`'d/lifted + proxy) bindings,
/// so a mocked eager binding's init never runs under `Wire.bootstrap<Variant>()`.
func appendNamedGraphs(
    container: [String: [DiscoveredBinding]],
    variant: [String: [DiscoveredBinding]],
    context: GraphEmissionContext,
    into file: inout WireFileBuffer
) {
    let named = container.merging(variant, uniquingKeysWith: { first, _ in first })
    for (name, order) in named.sorted(by: { $0.key < $1.key }) {
        // A *variant* graph is the default graph's order with the mocked bindings dropped, so it still
        // contains the input providers, needs the same `inputs:` parameter, and carries the graph
        // conformances. A *container* graph is a separate wiring that does none of those.
        appendStruct(
            structName: "_\(name)WireGraph",
            bootstrapFunction: "_wireBootstrap\(name)",
            bootstrapMethod: "bootstrap\(name)",
            topologicalOrder: order,
            isDefaultOrVariant: variant[name] != nil,
            context: context,
            into: &file
        )
    }
}

/// Each parent graph's bindings, keyed by its struct name — what a seed scope needs to spell its
/// `wireGraph:` parameter, since a parent that lifts generic parameters (an `@Singleton(as:)` opaque
/// binding) cannot be named by the bare struct name.
func bindingsByParentGraph(
    default defaultOrder: [DiscoveredBinding],
    containers: [String: [DiscoveredBinding]]
) -> [String: [DiscoveredBinding]] {
    var byGraph: [String: [DiscoveredBinding]] = ["_WireGraph": defaultOrder]
    for (containerName, order) in containers {
        byGraph["_\(containerName)WireGraph"] = order
    }
    return byGraph
}
