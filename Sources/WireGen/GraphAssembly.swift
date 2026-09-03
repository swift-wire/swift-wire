import WireGenCore

// The two per-container decisions `buildAllGraphs` makes before it builds a graph: what its seeded scopes
// resolve to, and how much of it reachability is allowed to prune. Both read only their arguments, and
// both are ordering-sensitive in the same way — the scopes are orchestrated first, because the app graph's
// pruning needs to know what they borrow.

/// Orchestrate one container's seeded scopes, in seed order. File scope rather than a member: it reads
/// only its arguments, like `partitionBindings` beside it.
///
/// Each scope is built against the container's over-generated borrow set and then enriched with the
/// cross-scope hints its missing bindings need.
func orchestrateSeedScopes(
    seedKeys: [ScopeKey],
    scopes: [ScopeKey?: [DiscoveredBinding]],
    containerKey: String?,
    borrows: [DiscoveredBinding],
    parentGraphType: String,
    in aggregate: DiscoveryAggregate
) -> [SeedScopeOrchestration] {
    seedKeys.map { seedKey in
        let orchestration = orchestrateSeedScope(
            seedKey: seedKey,
            containerName: containerKey,
            scopeBindings: scopes[seedKey] ?? [],
            borrowBindings: borrows,
            parentGraphType: parentGraphType,
            typealiases: aggregate.typealiases,
            multibindingKeys: aggregate.multibindingKeys,
            resultBuilders: aggregate.resultBuilders,
            module: aggregate.module,
            homeModule: aggregate.module,
            externalModules: aggregate.externalModules
        )
        return orchestration.withResult(
            enrichMissingBindingsWithCrossScopeHints(
                orchestration.result,
                consumerPartition: Partition(container: containerKey, scope: seedKey),
                allBindings: aggregate.allBindings
            )
        )
    }
}

/// The pruning policy for one container's app graph — drop every binding nothing reaches, home-module
/// bindings included. (The first cut of reachability pruning spared the home-module half; this does not.)
///
/// Conformances only on the default graph: that is where `appendAllGraphConformances` emits them, so a
/// `@Container`'s aggregate is never the witness for a protocol member. The borrow set is this
/// container's seed scopes', which are orchestrated before the app graph is built — and it is a retention
/// root because a request-scoped binding's use of an app singleton is an edge only the scope's own graph
/// carries, invisible to the graph being pruned. See `Reachability.swift`.
func pruningPolicy(
    containerKey: String?,
    in aggregate: DiscoveryAggregate,
    orchestrations: [SeedScopeOrchestration]
) -> ReachabilityPolicy {
    .prune(
        conformances: containerKey == nil ? aggregate.graphConformances : [],
        borrowedByScopes: Set(orchestrations.flatMap { usedBorrows(in: $0).map(\.identity) })
    )
}

/// The identities `result`'s reachability decided — retained and pruned together — or nothing when that
/// graph was not pruned at all. `deadBindingDiagnostics` judges what is *not* in this set, so a graph
/// built with `ReachabilityPolicy.none` (a seed scope) stays that pass's business and a pruned graph
/// becomes `prunedBindingDiagnostics`'.
func judged(_ result: GraphResult) -> Set<BindingIdentity> {
    guard let reachable = result.reachable else { return [] }
    return reachable.union(result.pruned.map(\.identity))
}
