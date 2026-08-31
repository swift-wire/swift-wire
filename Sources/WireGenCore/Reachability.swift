// Reachability — the walk M7b prunes with (M7b.1: computed, not yet applied).
//
// A dependency should cost only what the consumer reaches, so codegen wants the bindings reachable from
// the graph's *roots* rather than every binding in the merged parse set. Wire reads syntax, never use —
// `_WireGraph` is `internal` and its bindings are read as ordinary `graph.userService` expressions no
// discovery pass sees — so roots have to be **declared**. The complete set, and the rationale for each,
// is `Documentation/Notes/MultiModuleComposition.md` § "Reachability roots (M7b.0)"; this file is that
// note in code.
//
// Two things to keep straight, both of which the note argues at length:
//
//   1. **The walk's edges are not the sort's edges.** `dependencyEdges` deliberately omits member
//      injections (so cycles through them stay legal) and scope-entry thunks (whose identity is a
//      function type matching no producer). Both consume bindings that are genuinely constructed, so
//      `reachabilityEdges` unions them back in — over the same node set, as a *separate* map. Widening
//      the sort's edges instead would turn a legal member-injection cycle into a build failure.
//   2. **Roots are per graph.** These are the app/container graph's. A seed scope's roots are the subject
//      and yields its bridging proxy's thunk names, and M5.4.6 already prunes with them at emission
//      (`reachableBindings(from:in:)`) — the same concept one layer down, deliberately sharing vocabulary.
//
// The traversal itself is `reachable(from:over:)` (`TestingGraph.swift`), which already walks this map
// shape for the seedless-reconstruction cone.

/// What a graph build does about reachability. `.none` is the default: a graph whose construction set is
/// already bounded some other way (a seed scope, pruned per routed root at emission; a testing variant,
/// derived from a production graph) neither computes nor prunes.
package enum ReachabilityPolicy: Sendable {
    /// No reachability computed — `GraphResult.reachable` is `nil` and every resolved binding is emitted.
    case none
    /// Drop every binding unreachable from the declared roots, home-module bindings included (M7b.3).
    ///
    /// M7b.2 retained the home half wholesale, which made the first cut incapable of regressing an app.
    /// Dropping that union is the behaviour change: a binding the app reaches only through `graph.x` —
    /// an expression Wire never sees — is now gone unless it says `allowUnused: true`. That is why the
    /// pruned set is reported rather than silently applied; see `prunedBindingDiagnostics`.
    ///
    /// `conformances` are the ones emitted onto *this* graph — the default graph's, since
    /// `appendAllGraphConformances` puts them on the default graph and its testing variants, never on a
    /// `@Container`'s. `borrowedByScopes` are the app singletons this container's seed scopes genuinely
    /// borrow: a scope's use of a singleton is an edge in the *scope's* graph, invisible to this one, so
    /// it has to be carried in as a root or a request-scoped binding's dependency is pruned out from
    /// under it.
    case prune(
        conformances: [DiscoveredGraphConformance],
        borrowedByScopes: Set<BindingIdentity>
    )
}

/// The **declared roots** — what a graph must construct even though nothing in it consumes them. This is
/// the M7b.0 model, independent of how much of the graph a given pass is willing to prune.
///
/// Two rules, and the second has a key form:
///
/// - **Aggregates a graph conformance names** — an adapter-driven app's routes reach their framework
///   through `extension _WireGraph: <Protocol>`, never through an `@Inject`. The only root whose omission
///   is *silent*: a conformance member whose key has no aggregate falls back to an empty accessor by
///   design, so pruning one yields a graph that compiles, boots, and serves nothing.
/// - **`allowUnused: true` in the home package** — "I'm a root, keep me", the annotation for a binding
///   that leaves through `graph.x`. It roots a multibinding *key* the same way, for the same reason. A
///   *library's* `allowUnused` is ignored here: it keeps its diagnostic meaning only, so a library
///   binding is live iff a home root reaches it. `@GraphInputs` properties need no rule of their own —
///   `graphInputBindings` folds each into a home-module provider carrying `allowUnused: true`, for
///   exactly the reason that makes the annotation a root.
///
/// Everything else that looks like a root is *reached* instead, and the note says why for each:
/// contributors (adapter-annotated ones included) and contributor proxies through their aggregate,
/// borrowed app singletons through the `.scopeCapture` edges, synthesised factories through the input
/// edge appended onto each consumer.
///
/// Two things are deliberately **not** roots, both settled against an earlier reading:
///
/// - **`@Teardown` does not root a binding.** Teardown is a property of a *constructed* binding, not a
///   reason to construct one: a resource nothing reaches is never made, so there is nothing to shut down,
///   and the teardown rides the binding either way. Rooting on the annotation would also pin every
///   dependency's `@Teardown` binding into every consumer's graph — construct-everything by annotation,
///   the failure the `allowUnused` rule exists to avoid. A resource whose *construction* is the point
///   says so with `allowUnused: true`.
/// - **A `public` key does not root its aggregate.** Visibility gates diagnostics, not construction. The
///   dead-binding gate stays silent on `public` because Wire cannot see every consumer — but the only
///   thing that can read an aggregate's product is this graph, and `_WireGraph` is `internal` to the
///   module. A downstream reader is impossible; a local one is an edge, a conformance, or `allowUnused`.
package func declaredRoots(
    in bindings: [BindingIdentity: DiscoveredBinding],
    multibindingKeys: [DiscoveredMultibindingKey],
    conformances: [DiscoveredGraphConformance],
    externalModules: Set<String>
) -> Set<BindingIdentity> {
    // Key reference → the key's declaration, for the aggregate rules below.
    var keysByReference: [String: DiscoveredMultibindingKey] = [:]
    for key in multibindingKeys { keysByReference[key.keyReference] = key }
    let conformanceKeys = Set(conformances.flatMap { $0.members.map(\.keyReference) })

    var roots: Set<BindingIdentity> = []
    for (identity, binding) in bindings {
        let isRoot =
            (binding.allowUnused && !externalModules.contains(binding.originModule))
            || aggregateIsRoot(
                binding,
                keysByReference: keysByReference,
                conformanceKeys: conformanceKeys,
                externalModules: externalModules
            )
        if isRoot { roots.insert(identity) }
    }
    return roots
}

/// The identities the walk starts from under `policy` — `nil` when the policy prunes nothing.
///
/// The declared roots, plus everything this container's seed scopes borrow. **M7b.2 also unioned in every
/// home-module binding**; M7b.3 is exactly the change of dropping that union, so the declared roots now
/// carry the whole graph and the migration diagnostic earns its keep. Nothing else moved: the same walk
/// over the same edges from a smaller set.
package func retentionRoots(
    in bindings: [BindingIdentity: DiscoveredBinding],
    multibindingKeys: [DiscoveredMultibindingKey],
    externalModules: Set<String>,
    policy: ReachabilityPolicy
) -> Set<BindingIdentity>? {
    guard case .prune(let conformances, let borrowedByScopes) = policy else { return nil }
    var roots = declaredRoots(
        in: bindings,
        multibindingKeys: multibindingKeys,
        conformances: conformances,
        externalModules: externalModules
    )
    roots.formUnion(borrowedByScopes.intersection(bindings.keys))
    return roots
}

/// Whether `binding` is a synthesised multibinding aggregate that survives with no local consumer: one a
/// graph conformance names (its members read the aggregate off the emitted graph), or one whose key is
/// marked `allowUnused:` in the home package — the key form of "I'm a root, keep me", for a collection
/// the app pulls out through `graph.x`.
///
/// The key's *visibility* is not consulted, deliberately. A `public` key silences the dead-binding
/// warning, because Wire cannot see every consumer of a public declaration — but nothing outside this
/// graph can read an aggregate's product in the first place (`_WireGraph` is `internal` to the module),
/// so there is no downstream reader for the silence to be protecting. Visibility gates diagnostics;
/// consumption gates construction.
private func aggregateIsRoot(
    _ binding: DiscoveredBinding,
    keysByReference: [String: DiscoveredMultibindingKey],
    conformanceKeys: Set<String>,
    externalModules: Set<String>
) -> Bool {
    guard case .aggregate = binding, let keyReference = binding.keyIdentifier else { return false }
    if conformanceKeys.contains(keyReference) { return true }
    guard let key = keysByReference[keyReference] else { return false }
    return key.allowUnused && !externalModules.contains(key.originModule)
}

/// The adjacency the reachability walk traverses: `dependencyEdges` plus the two consumption edges the
/// topological sort deliberately drops.
///
/// - **Member-injection parameters.** `@Inject weak var` / `@Inject func` deliver post-init, so they are
///   excluded from the sort to keep cycles through them legal — that is the cycle-breaking feature. The
///   value is still constructed and delivered, so a binding consumed *only* this way is live.
/// - **Scope-entry thunks.** A `.scopeEntryThunk` dependency's identity is a function type matching no
///   producer, so `resolveDependencies` skips it — but the thunk constructs the proxy's subject and every
///   binding it yields out of the scope.
///
/// Both resolve through `matchProducer`, so optional promotion is honoured exactly as an ordinary edge's
/// is (a `T?` consumer keeps the `T` producer live). `DeadBindingDiagnostics` unions the same two sets for
/// the same reason; this is that union expressed as edges rather than as a consumed set.
package func reachabilityEdges(
    in bindings: [BindingIdentity: DiscoveredBinding],
    dependencyEdges: [BindingIdentity: [BindingIdentity]]
) -> [BindingIdentity: [BindingIdentity]] {
    var edges = dependencyEdges
    for (identity, binding) in bindings {
        var extra: [BindingIdentity] = []
        for injection in binding.memberInjections {
            for parameter in injection.parameters {
                if case .resolved(let producer) = matchProducer(
                    for: bridgedDependencyIdentity(parameter, in: binding),
                    in: bindings
                ) {
                    extra.append(producer)
                }
            }
        }
        for dependency in binding.dependencies {
            for constructed in scopeEntryConstructedIdentities(of: dependency) {
                if case .resolved(let producer) = matchProducer(for: constructed, in: bindings) {
                    extra.append(producer)
                }
            }
        }
        guard !extra.isEmpty else { continue }
        let existing = edges[identity] ?? []
        edges[identity] = existing + extra.filter { !existing.contains($0) }
    }
    return edges
}

/// The retained set for one graph build, or `nil` when `policy` is `.none` — `retentionRoots` followed by
/// the walk, over the widened adjacency rather than the sort's own edges.
///
/// Called from `buildDependencyGraph` between `resolveDependencies` and `topologicalSort`, which is where
/// the pruning stage lands: it needs resolved edges to walk, and everything after it consumes the reduced
/// node set unchanged.
package func computeReachability(
    in bindings: [BindingIdentity: DiscoveredBinding],
    dependencyEdges: [BindingIdentity: [BindingIdentity]],
    multibindingKeys: [DiscoveredMultibindingKey],
    externalModules: Set<String>,
    policy: ReachabilityPolicy
) -> Set<BindingIdentity>? {
    guard
        let roots = retentionRoots(
            in: bindings,
            multibindingKeys: multibindingKeys,
            externalModules: externalModules,
            policy: policy
        )
    else { return nil }
    return reachable(
        from: Array(roots),
        over: reachabilityEdges(in: bindings, dependencyEdges: dependencyEdges)
    )
}

/// One graph build's resolution: the node set and edges the sort runs over, and the reports that go with
/// them. `restricted(_:to:)` returns the pruned form of the same thing.
package struct ResolvedGraph {
    package let bindings: [BindingIdentity: DiscoveredBinding]
    package let edges: [BindingIdentity: [BindingIdentity]]
    package let missing: [MissingBinding]
    package let promotions: [ExistentialPromotion]
}

/// One graph build's resolution restricted to `retained` — the pruning step itself.
///
/// Everything downstream of resolution consumes the reduced set unchanged, which is why the restriction
/// lands here rather than in emission: the sort, the cycle report and the missing-binding report are all
/// about the graph that is actually built. A dependency the consumer cannot satisfy inside a binding it
/// never constructs stops being an error, and a cycle among bindings nothing constructs stops failing the
/// build — both correct, and both load-bearing once composition is bounded by reachability instead of by
/// the `_WireExports.swift` marker.
///
/// Retention is closed under dependencies (see `retentionRoots`), so no retained binding is left pointing
/// at a pruned one; `edges` is filtered only to drop the pruned consumers' own rows.
func restricted(
    bindings: [BindingIdentity: DiscoveredBinding],
    edges: [BindingIdentity: [BindingIdentity]],
    missing: [MissingBinding],
    promotions: [ExistentialPromotion],
    to retained: Set<BindingIdentity>
) -> ResolvedGraph {
    ResolvedGraph(
        bindings: bindings.filter { retained.contains($0.key) },
        edges: edges.filter { retained.contains($0.key) },
        missing: missing.filter { retained.contains($0.consumer.identity) },
        promotions: promotions.filter { retained.contains($0.consumer) }
    )
}
