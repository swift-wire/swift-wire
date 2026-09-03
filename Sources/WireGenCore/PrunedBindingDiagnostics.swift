// Telling the developer what reachability pruning dropped.
//
// The first cut of pruning took only dependency-module bindings, which no consumer could notice. Pruning
// the home module too *is* noticeable: a binding the app reaches only through `graph.x` — an expression
// Wire never sees — is gone unless it says `allowUnused: true`. The pruned set is exactly the information
// the developer needs, so it is reported rather than applied in silence.
//
// **This does not use the dead-binding visibility gate**, and the reason is worth stating because the
// first cut did. That gate stays silent on `public` because Wire cannot see every consumer of a
// public declaration — and here it can: the only thing that constructs a binding is this graph, and
// `_WireGraph` is `internal` to its own module, so no downstream consumer can be the reason a public
// binding is absent. Visibility gates diagnostics about *consumption*; this one is about *construction*,
// which is the same distinction that keeps a `public` key from rooting its aggregate.
//
// The noise this was supposed to prevent does not exist either. A target only has a graph if it applies
// `WireBuildPlugin`, and a Wire-aware *library* deliberately does not — it is re-parsed by its consumer,
// which is what `CompositionHarness/Library/Package.swift` and `WireTestLibrary` both say in as many
// words. A target with a graph is one that bootstraps, and there a pruned `public` binding is exactly as
// surprising as a pruned `internal` one: silence buys a "has no member" error at the use site instead of
// a message naming the fix.
//
// The one shape that would rather stay quiet is a target that both bootstraps *and* exports bindings for
// a downstream Wire target to compose. Its public bindings are legitimately absent from its own graph,
// and `allowUnused: true` silences by pinning them in — a slightly wasteful answer rather than a wrong
// one. That is a real cost, taken deliberately: it is rarer than the app that reads its own binding off
// the graph, and its failure is a warning rather than a confusing compile error.
//
// This supersedes the dead-binding warning for anything it reports. The two describe one fact — nothing
// reaches this binding — and this one says more, so `deadBindingDiagnostics` skips what was pruned; the
// merge is finished by reachability replacing the first-order consumption check itself.

/// Warn for each home-module binding the graph pruned, at every visibility, with the `allowUnused`
/// fix-it. Output is sorted by source location for stable build output.
///
/// Dependency-module bindings are never reported: a library binding a consumer does not reach is the
/// pruning working, not a problem to fix, and the consumer cannot act on it anyway.
///
/// Synthesised aggregates are skipped — the multibinding liveness diagnostics speak for a key that
/// nothing consumes, and in the aggregate's own vocabulary. A *contributor* pruned along with its
/// aggregate is reported, which is the interesting case: a package-local contributor folded
/// into a `public` aggregate nothing consumes is genuinely dead, while the aggregate itself stays silent.
package func prunedBindingDiagnostics(
    _ pruned: [DiscoveredBinding],
    externalModules: Set<String>
) -> [Diagnostic] {
    pruned
        .filter { shouldReportPruned($0, externalModules: externalModules) }
        .map { binding in
            Diagnostic(
                location: binding.location,
                message:
                    "\(describePruned(binding)) is declared but nothing reachable from this graph's roots constructs it, so it was not emitted. Inject it somewhere, or mark it 'allowUnused: true' if you read it from the graph directly (as 'graph.\(propertyName(for: binding))').",
                severity: .warning
            )
        }
        .sorted { $0.location < $1.location }
}

/// Whether a pruned binding is worth reporting: home-module, and a real declaration rather than a
/// synthesised aggregate. Visibility is deliberately not consulted — see the note above. `allowUnused`
/// never appears here either, since it is a root and so is never pruned, and neither do generic
/// templates, which are not graph nodes at all.
private func shouldReportPruned(_ binding: DiscoveredBinding, externalModules: Set<String>) -> Bool {
    guard !externalModules.contains(binding.originModule) else { return false }
    if case .aggregate = binding { return false }
    return true
}

/// Human-facing identifier for the pruned binding — the bound type, with a keyed slot rendered as
/// `T (key)`, matching the dead-binding warning's shape. A `@Teardown` binding says so: its intent
/// ("this exists to be shut down") is the least visible in the code and the most surprising to lose,
/// since a resource nothing reaches is never constructed and so never torn down.
private func describePruned(_ binding: DiscoveredBinding) -> String {
    let slot = binding.keyIdentifier.map { "'\(binding.boundType)' (key \($0))" } ?? "'\(binding.boundType)'"
    return binding.teardown != nil ? "\(slot), which declares a '@Teardown'," : slot
}
