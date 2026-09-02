// M7c.2 — the construction state struct, driven sequentially.
//
// The cell itself is `Wire._WireBindingState`, not something emitted here: generated code already names
// Wire's public types (`Introspectable`, `Teardownable`, `WiringModel`), and a type whose failure modes
// pass `-typecheck` and fail at `-c` belongs somewhere it can be tested directly. This file emits the
// per-graph structure around it.
//
// `Documentation/Notes/ConstructionScheduling.md` § "The mechanism" replaces the linear `let` chain with
// one `~Copyable` state struct owned by the bootstrap frame: a cell per binding, an `add` per binding that
// fires when its dependencies have resolved, and a cascade from each resolution to its dependents. M7c.3
// moves async bindings into a `ThrowingTaskGroup`; **this step drives the same structure with no group at
// all**, so the whole cascade runs inline. That is the wholly-sync degenerate case, and it is deliberately
// first: it isolates every noncopyable spelling and the three cell read forms before any concurrency is
// involved.
//
// Two things the note records that shape everything here:
//
//   1. **The three read forms are the whole API.** `isResolved()` for readiness, `value()` for a copyable
//      dependency, `take()` for a move. The obvious spellings — `guard case .unmarked = self` in a
//      mutating method, multi-pattern case labels, `guard case .resolved(let x) = cell` — each consume
//      something they must not, and all three **pass `-typecheck` and fail at `-c`**. Re-verified against
//      the 6.3.3 floor while writing this file. Nothing here may be checked by diffing rendered text; the
//      gate has to compile the generated output.
//   2. **`Sendable` attaches to the task boundary, not to the binding.** No cell is shared across tasks
//      here, so a non-Sendable binding lives in one, is read as a dependency and constructed across
//      `await` points under `-strict-concurrency=complete`. It simply never enters a task.

/// The cell's stored-property name for a binding, and the name of the method that resolves it.
///
/// Both carry a `_wire` prefix rather than the note's bare `poolState`, and that is load-bearing. The
/// construction expressions inside these methods reference module-scope declarations by bare name (a
/// `@Provides let appName` is emitted as `appName`), and Swift checks the enclosing type's members before
/// module scope — the same shadow that put `_wireBootstrap` at module scope instead of on `_WireGraph`.
/// A cell named `appNameState` would still collide with a user binding whose own property name is
/// `appNameState`; a `_wire`-prefixed one cannot, because the prefix is reserved.
func stateCellName(for binding: DiscoveredBinding) -> String { "_wireState_\(propertyName(for: binding))" }
func stateAddName(for binding: DiscoveredBinding) -> String { "_wireAdd_\(propertyName(for: binding))" }

/// `_WireGraph` → `_WireBuilding`, `_TestContainerWireGraph` → `_TestContainerWireBuilding`.
func buildingStructName(forGraph structName: String) -> String {
    guard structName.hasSuffix("WireGraph") else { return "\(structName)WireBuilding" }
    return String(structName.dropLast("WireGraph".count)) + "WireBuilding"
}

/// The property names a binding's construction expression references as locals — exactly the set
/// `renderArguments` renders, resolved the same way, so the guards this file emits cannot drift from the
/// arguments the construction actually passes. `.scopeCapture` dependencies pass no argument and are
/// excluded there, so they are excluded here.
func constructionDependencyLocals(of binding: DiscoveredBinding) -> [String] {
    binding.dependencies
        .filter { $0.kind != .scopeCapture }
        .map { dependency in
            let identity = bridgedDependencyIdentity(dependency, in: binding)
            return identifierName(forType: identity.displayType, key: identity.key)
        }
}

/// Whether one graph takes the scheduled form.
///
/// **Positive half:** the graph contains an async binding. Parallelism only pays where there is a
/// suspension, and a wholly-sync graph gains nothing from the machinery — so those keep today's linear
/// chain, which is what holds `GoldenHarness` byte-identical for them. This is the per-*graph* predicate
/// the note insists on rather than a per-binding one, because a per-binding predicate would need to know
/// whether a type is `Sendable`, which a SwiftSyntax pipeline cannot answer.
///
/// **Negative half — the constructs M7c.4 owns.** Each is excluded because its *emission* has not been
/// translated into the `add` form yet, not because it cannot be:
///
/// - **builder aggregates**, which emit a `@resultBuilder`-annotated local function rather than a single
///   expression, so there is nothing to hand `asResolved`;
/// - **scope-entry thunks**, whose closure captures the bootstrap's singleton locals — locals the
///   scheduled form does not have;
/// - **existential-promotion aliases**, which bind one `any P` local *after* a construction for its
///   consumers to share, a second definition site per binding;
/// - **member injections**, which run as a post-construction block over every local at once, so they have
///   no single resolution to hang off;
/// - **`@Teardown`**, whose closure captures each binding's concrete local for the same reason;
/// - **opaque (`some P`) lifts**, which put a generic parameter on the graph struct that the building
///   struct would have to mirror and the bootstrap infer through both.
///
/// Listed as one predicate, in one place, so relaxing it in M7c.4 is a matter of deleting a clause and
/// its gate rather than hunting for what "simple" meant.
func schedulerApplies(
    to topologicalOrder: [DiscoveredBinding],
    seedScopes: [String: SeedScopeEmission],
    existentialPromotions: [ExistentialPromotion]
) -> Bool {
    guard topologicalOrder.contains(where: bindingIsAsync) else { return false }
    let promoted = Set(existentialPromotions.map(\.consumer))
    for binding in topologicalOrder {
        if case .aggregate(let aggregate) = binding, aggregate.flavour == .builder { return false }
        if scopeEntryThunkLines(forBridgeProxy: binding, scopes: seedScopes) != nil { return false }
        if promoted.contains(binding.identity) { return false }
        if !binding.memberInjections.isEmpty { return false }
        if binding.teardown != nil { return false }
        if binding.boundType.hasPrefix("some ") { return false }
    }
    return true
}

/// Whether the binding's construction expression suspends — the positive half of the trigger. Aggregates
/// fold contributors that are already built, so they never suspend.
func bindingIsAsync(_ binding: DiscoveredBinding) -> Bool {
    switch binding {
    case .scopeBound(let scopeBound): return scopeBound.initIsAsync
    case .provider(let provider): return provider.isAsync
    case .aggregate: return false
    }
}

/// The building struct: one cell per binding, one `add` per binding.
///
/// Every `add` is `async throws` whatever its binding's own effects are, because a sync binding's `add`
/// cascades into dependents that may not be — and a uniform signature is what keeps the cascade a plain
/// call rather than a per-edge effect calculation. The enclosing bootstrap is already `async throws`, so
/// the widened contract costs nothing at the call site and no suspension where there is no `await`.
func schedulerBuildingStructLines(structName: String, topologicalOrder: [DiscoveredBinding]) -> [String] {
    let names = Set(topologicalOrder.map { propertyName(for: $0) })
    // Direct dependents, keyed by the producer's property name — the cascade's adjacency. Built from the
    // same local names the construction expressions reference, and kept in topological order so the
    // emitted cascade is deterministic.
    var dependents: [String: [DiscoveredBinding]] = [:]
    for binding in topologicalOrder {
        for local in Set(constructionDependencyLocals(of: binding)) where names.contains(local) {
            dependents[local, default: []].append(binding)
        }
    }

    var lines = ["", "private struct \(buildingStructName(forGraph: structName)): ~Copyable {"]
    for binding in topologicalOrder {
        lines.append(
            "    var \(stateCellName(for: binding)): _WireBindingState<\(binding.boundTypeReference)> = .unmarked"
        )
    }
    for binding in topologicalOrder {
        lines.append("")
        lines.append(contentsOf: schedulerAddMethodLines(for: binding, in: names, dependents: dependents))
    }
    lines.append("}")
    return lines
}

/// One binding's `add`: check the dependencies, claim the cell, construct, cascade.
///
/// The dependency check comes **before** the pending transition, deliberately. A dependent that is not yet
/// ready must leave itself unmarked so that whichever dependency resolves last can still fire it; claiming
/// the cell first would strand it.
private func schedulerAddMethodLines(
    for binding: DiscoveredBinding,
    in names: Set<String>,
    dependents: [String: [DiscoveredBinding]]
) -> [String] {
    let local = propertyName(for: binding)
    var lines = ["    mutating func \(stateAddName(for: binding))() async throws {"]

    // `value()` binds the dependency under the same local name the construction expression uses, so the
    // rendered arguments resolve unchanged. A copyable payload reads by copy and leaves the cell resolved;
    // a multi-consumer binding is therefore read once per consumer, exactly as the linear chain does.
    let dependencyLocals = constructionDependencyLocals(of: binding).filter { names.contains($0) }
    if !dependencyLocals.isEmpty {
        let guards = orderedUnique(dependencyLocals).map { "let \($0) = _wireState_\($0).value()" }
        lines.append("        guard \(guards.joined(separator: ", ")) else { return }")
    }
    lines.append("        guard \(stateCellName(for: binding)).asPending() else { return }")

    // A specialised generic `@Provides func` cannot be called with explicit type arguments, so its
    // concrete return type goes on a local and Swift infers them — there is no annotation slot on
    // `asResolved`.
    let construction = constructionExpression(for: binding)
    if case .provider(let provider) = binding, !provider.concreteGenericArguments.isEmpty {
        lines.append("        let \(local): \(binding.boundTypeReference) = \(construction)")
        lines.append("        \(stateCellName(for: binding)).asResolved(\(local))")
    } else {
        lines.append("        \(stateCellName(for: binding)).asResolved(\(construction))")
    }

    for dependent in dependents[local] ?? [] {
        lines.append("        try await \(stateAddName(for: dependent))()")
    }
    lines.append("    }")
    return lines
}

/// The scheduled bootstrap body: start every source binding, and let the cascade reach the rest.
///
/// Driving from the sources rather than calling every `add` in topological order is what makes the
/// cascade load-bearing instead of decorative — under the linear order each `add` would already find its
/// dependencies resolved and the cascade would be dead code, which is precisely the machinery M7c.3 needs
/// to be able to trust.
func schedulerBootstrapBodyLines(structName: String, topologicalOrder: [DiscoveredBinding]) -> [String] {
    let names = Set(topologicalOrder.map { propertyName(for: $0) })
    var lines = ["    var building = \(buildingStructName(forGraph: structName))()"]
    for binding in topologicalOrder
    where constructionDependencyLocals(of: binding).allSatisfy({ !names.contains($0) }) {
        lines.append("    try await building.\(stateAddName(for: binding))()")
    }
    return lines
}

/// Order-preserving dedup — a binding that names the same dependency twice guards it once.
private func orderedUnique(_ values: [String]) -> [String] {
    var seen: Set<String> = []
    return values.filter { seen.insert($0).inserted }
}
