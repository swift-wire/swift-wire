// M7c.3 — the construction state struct, driven by a `ThrowingTaskGroup`.
//
// The cell itself is `Wire._WireBindingState`, not something emitted here: generated code already names
// Wire's public types (`Introspectable`, `Teardownable`, `WiringModel`), and a type whose failure modes
// pass `-typecheck` and fail at `-c` belongs somewhere it can be tested directly. This file emits the
// per-graph structure around it.
//
// `Documentation/Notes/ConstructionScheduling.md` § "The mechanism" replaces the linear `let` chain with
// one `~Copyable` state struct owned by the bootstrap frame: a cell per binding, an `add` per binding that
// fires when its dependencies have resolved, and a cascade from each resolution to its dependents. M7c.2
// drove that structure with no group at all, so the whole cascade ran inline; **M7c.3 puts the async
// bindings into child tasks**, and the parent — suspended on the group's iterator — applies each result
// and fires its dependents. Child tasks never schedule; they return a marker.
//
// Three things the note records that shape everything here:
//
//   1. **The three read forms are the whole API.** `isResolved()` for readiness, `value()` for a copyable
//      dependency, `take()` for a move. The obvious spellings — `guard case .unmarked = self` in a
//      mutating method, multi-pattern case labels, `guard case .resolved(let x) = cell` — each consume
//      something they must not, and all three **pass `-typecheck` and fail at `-c`**. Nothing here may be
//      checked by diffing rendered text; the gate has to compile the generated output.
//   2. **`Sendable` attaches to the task boundary, not to the binding.** A binding that never enters a
//      task lives in its cell, is read as a dependency and is constructed across `await` points under
//      `-strict-concurrency=complete` whether or not it is `Sendable`. Only what crosses into a child
//      task — the scheduled binding's own product, and each dependency its closure captures — is bound
//      by `ChildTaskResult: Sendable` and by `addTask`'s `sending` closure.
//   3. **Wire cannot compute (2).** It reads syntax and never sees a conformance — implicit `Sendable`
//      derivation, a conformance declared in an extension and an external type are all invisible to it.
//      So the requirement is *asserted* rather than decided: `schedulerSendableCheckLines` emits one
//      `_check` per binding that crosses the boundary, wrapped in `#sourceLocation`, which is the same
//      instrument `_WireKeyChecks.swift` uses to attribute a generated type error to the user's own line.

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

/// The group's parameter name, and the drain loop's result local.
///
/// Reserved-prefix for the reason above: both are in scope inside method bodies that reference module-scope
/// bindings by bare name, so a plain `group` would shadow a user's `@Provides let group`.
private let groupParameterName = "_wireGroup"
private let resultParameterName = "_wireResult"

/// `_WireGraph` → `_WireBuilding`, `_TestContainerWireGraph` → `_TestContainerWireBuilding`.
func buildingStructName(forGraph structName: String) -> String {
    replacingGraphSuffix(structName, with: "WireBuilding")
}

/// `_WireGraph` → `_WireTaskResult` — the marker a child task returns, one case per scheduled binding.
func taskResultEnumName(forGraph structName: String) -> String {
    replacingGraphSuffix(structName, with: "WireTaskResult")
}

private func replacingGraphSuffix(_ structName: String, with suffix: String) -> String {
    guard structName.hasSuffix("WireGraph") else { return "\(structName)\(suffix)" }
    return String(structName.dropLast("WireGraph".count)) + suffix
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

/// The construction plan for one graph, or `nil` when it keeps today's linear `let` chain end to end.
///
/// **Positive half: the graph has two async bindings neither of which depends on the other**, which is
/// what `constructionRegions` computes as Overlap. A single async binding in a group is one child task the
/// parent immediately blocks on, and a *chain* of async bindings is sequential however it is scheduled;
/// both would take the `Sendable` requirement below for no gain. This is the per-*graph* half of the
/// predicate, and it stays per-graph because a per-binding one would need to know whether a type is
/// `Sendable`, which a SwiftSyntax pipeline cannot answer.
///
/// **Negative half — the constructs M7c.4 has not translated, tested against the *group region* only.**
/// M7c.3 asked whether the construct appeared anywhere in the graph, which is what made every large graph
/// in the corpus fail on five clauses at once. A construct in the prefix or the suffix is emitted by the
/// linear chain exactly as it always was, so it is not the scheduler's business:
///
/// - **builder aggregates**, which emit a `@resultBuilder`-annotated local function rather than a single
///   expression, so there is nothing to hand `asResolved`. (A *collected* or *mapped* aggregate is a
///   single expression and has always worked, including one folding async contributors.)
/// - **scope-entry thunks**, whose *escaping* closure captures the bootstrap's singleton locals — and
///   whose capture set is `.scopeCapture` dependencies, which `constructionDependencyLocals` excludes, so
///   the readiness guard would not cover them;
/// - **existential-promotion aliases**, which bind one `any P` local *after* a construction for consumers
///   to share, a second definition site per binding. Tested on **either** endpoint: a promotion whose
///   producer is scheduled would need its alias emitted after the seam rather than after the construction.
/// - **opaque (`some P`) lifts**, which put a generic parameter on the graph struct that the building
///   struct would have to mirror and the bootstrap infer through both.
///
/// Two clauses M7c.3 carried are **gone rather than narrowed**, because both name post-construction blocks
/// that run after the seam, where every binding is a local again: **member injection** (which cannot be
/// region-scoped at all — its parameters are not construction edges) and **`@Teardown`** (whose closure is
/// built at the end of the bootstrap over each binding's concrete local). Twelve corpus graphs exercise
/// both.
func schedulerPlan(
    for topologicalOrder: [DiscoveredBinding],
    seedScopes: [String: SeedScopeEmission],
    existentialPromotions: [ExistentialPromotion]
) -> ConstructionRegions? {
    guard let regions = constructionRegions(for: topologicalOrder) else { return nil }
    let promoted = Set(existentialPromotions.flatMap { [$0.consumer, $0.producer] })
    for binding in regions.group {
        if case .aggregate(let aggregate) = binding, aggregate.flavour == .builder { return nil }
        if scopeEntryThunkLines(forBridgeProxy: binding, scopes: seedScopes) != nil { return nil }
        if promoted.contains(binding.identity) { return nil }
        if binding.boundType.hasPrefix("some ") { return nil }
    }
    return regions
}

/// Whether the binding's construction expression suspends — which is what puts it in a child task.
/// Aggregates fold contributors that are already built, so they never suspend.
func bindingIsAsync(_ binding: DiscoveredBinding) -> Bool {
    switch binding {
    case .scopeBound(let scopeBound): return scopeBound.initIsAsync
    case .provider(let provider): return provider.isAsync
    case .aggregate: return false
    }
}

/// The bindings that cross the task boundary, and therefore have to be `Sendable`: every scheduled binding
/// that suspends (its product is a `ChildTaskResult`) and every binding one of those reads as a dependency
/// (its value is captured by a `sending` closure), whichever region that dependency lives in. Returned in
/// the group's order, deduplicated.
private func sendableRequiredBindings(in regions: ConstructionRegions) -> [DiscoveredBinding] {
    let scheduled = regions.group.filter(bindingIsAsync)
    var required = Set(scheduled.map { propertyName(for: $0) })
    let reachable = regions.group + regions.frontier
    let names = Set(reachable.map { propertyName(for: $0) })
    for binding in scheduled {
        for local in constructionDependencyLocals(of: binding) where names.contains(local) {
            required.insert(local)
        }
    }
    return reachable.filter { required.contains(propertyName(for: $0)) }
}

/// The `Sendable` assertions for one scheduled graph.
///
/// Without these, a non-Sendable *dependency* fails the build as `sending closure risks causing data
/// races`, pointing inside an `addTask` closure the user never wrote and naming a generated local. The
/// check moves it to the binding's own declaration, which is where the fix goes, using the
/// `#sourceLocation` instrument `_WireKeyChecks.swift` already uses for a keyed binding's type mismatch —
/// and it is reported *instead of*, not alongside, the generated one. It is emitted here rather than in
/// that file because the requirement is a property of *this graph's construction plan* — which bindings
/// were scheduled — and the key-check file is rendered from a flat binding list that has no notion of one.
///
/// A scheduled binding's own *product* is asserted too, and there the marker enum's conformance failure
/// wins instead; see ``schedulerTaskResultEnumLines`` for why that one is the better error to leave in
/// place.
///
/// The function is never called. `_check` unifies nothing; the constraint on its generic parameter is the
/// whole assertion, and a type that does not satisfy it fails at the call site.
func schedulerSendableCheckLines(structName: String, regions: ConstructionRegions) -> [String] {
    let required = sendableRequiredBindings(in: regions)
    guard !required.isEmpty else { return [] }

    var lines = [
        "",
        "// Every binding this graph builds in a child task, and every dependency such a binding captures,",
        "// must be Sendable — `ThrowingTaskGroup`'s result and `addTask`'s closure both require it. These",
        "// assertions exist so that requirement is reported at the binding rather than inside the",
        "// generated scheduler below. Never called.",
        "private func \(sendableCheckFunctionName(forGraph: structName))() {",
        "    func _check<T: Sendable>(_: T.Type) {}",
    ]
    for binding in required {
        let location = binding.location
        lines.append("")
        lines.append("    #sourceLocation(file: \"\(location.file)\", line: \(location.line))")
        // Parenthesised because a bare `any P.self` parses as `any (P.self)`, and an aggregate's
        // `[any P]` needs the parentheses for the same reason.
        lines.append("    _check((\(binding.boundTypeReference)).self)")
        lines.append("    #sourceLocation()")
    }
    lines.append("}")
    return lines
}

private func sendableCheckFunctionName(forGraph structName: String) -> String {
    "_wireSendableChecks\(structName)"
}

/// The marker a child task returns — one case per scheduled binding, carrying the constructed value.
///
/// Explicitly `: Sendable` rather than left to derivation, and that is the better failure — measured, not
/// assumed. Declared, a non-Sendable product fails *here*, naming the case (which is the binding's own
/// property name), the type, and — in a note — the user's type declaration. Derived, it fails at
/// `withThrowingTaskGroup(of:)` and at each `addTask` as "type '…WireTaskResult' does not conform to
/// 'Sendable'", three errors against generated code that name nothing.
///
/// The trade is that this diagnostic is a module-level one, so it aborts before function bodies are
/// type-checked and suppresses ``schedulerSendableCheckLines``'s located assertion for the same binding.
/// That assertion earns its place on the other half — a non-Sendable *dependency*, where nothing is wrong
/// with the marker and the native failure is `sending closure risks causing data races` inside a closure
/// the user never wrote.
func schedulerTaskResultEnumLines(
    structName: String,
    regions: ConstructionRegions,
    isLocal: Bool = false
) -> [String] {
    var lines = ["", "\(isLocal ? "" : "private ")enum \(taskResultEnumName(forGraph: structName)): Sendable {"]
    for binding in regions.group where bindingIsAsync(binding) {
        lines.append("    case \(propertyName(for: binding))(\(binding.boundTypeReference))")
    }
    lines.append("}")
    return lines
}

/// The building struct: the frontier as plain stored properties, a cell per scheduled binding, an `add`
/// per scheduled binding, and one `update` over the child-result marker.
///
/// Every `add` is `throws` whatever its binding's own effects are, because a sync binding's `add` cascades
/// into dependents that may not be — and a uniform signature is what keeps the cascade a plain call rather
/// than a per-edge effect calculation. None is `async`: an async binding's suspension moved into its child
/// task, and the parent's only `await` is the drain loop's `next()`.
func schedulerBuildingStructLines(
    structName: String,
    regions: ConstructionRegions,
    isLocal: Bool = false
) -> [String] {
    let names = Set(regions.group.map { propertyName(for: $0) })
    // Direct dependents *within the group*, keyed by the producer's property name — the cascade's
    // adjacency. Built from the same local names the construction expressions reference, and kept in the
    // group's order so the emitted cascade is deterministic. A frontier binding has no dependents to
    // record: it is already resolved before the struct exists.
    var dependents: [String: [DiscoveredBinding]] = [:]
    for binding in regions.group {
        for local in Set(constructionDependencyLocals(of: binding)) where names.contains(local) {
            dependents[local, default: []].append(binding)
        }
    }
    let groupType = "ThrowingTaskGroup<\(taskResultEnumName(forGraph: structName)), any Error>"

    var lines = ["", "\(isLocal ? "" : "private ")struct \(buildingStructName(forGraph: structName)): ~Copyable {"]
    // The seam, inbound. A frontier value is already constructed, so it is a `let`, not a cell: a cell
    // would add a state transition that can never fail and a `value()` that can never return `nil`. The
    // property name is the binding's own, so the construction expressions inside the methods below resolve
    // it exactly as they would a bootstrap local.
    for binding in regions.frontier {
        lines.append("    let \(propertyName(for: binding)): \(binding.boundTypeReference)")
    }
    if !regions.frontier.isEmpty { lines.append("") }
    for binding in regions.group {
        lines.append(
            "    var \(stateCellName(for: binding)): _WireBindingState<\(binding.boundTypeReference)> = .unmarked"
        )
    }
    for binding in regions.group {
        lines.append("")
        lines.append(
            contentsOf: schedulerAddMethodLines(
                for: binding,
                in: names,
                frontier: Set(regions.frontier.map { propertyName(for: $0) }),
                dependents: dependents,
                groupType: groupType
            )
        )
    }
    lines.append("")
    lines.append(
        contentsOf: schedulerUpdateMethodLines(
            structName: structName,
            group: regions.group,
            dependents: dependents,
            groupType: groupType
        )
    )
    lines.append("}")
    return lines
}

/// One binding's `add`: check the dependencies, claim the cell, then either hand the construction to a
/// child task or run it here and cascade.
///
/// The dependency check comes **before** the pending transition, deliberately. A dependent that is not yet
/// ready must leave itself unmarked so that whichever dependency resolves last can still fire it; claiming
/// the cell first would strand it. Only *group* dependencies are checked — a frontier one is a stored
/// property that was constructed before the struct existed, so there is nothing to wait for. A scheduled
/// binding does not cascade from here either: its value does not exist yet, and `_wireUpdate` cascades
/// when the child returns.
private func schedulerAddMethodLines(
    for binding: DiscoveredBinding,
    in names: Set<String>,
    frontier: Set<String>,
    dependents: [String: [DiscoveredBinding]],
    groupType: String
) -> [String] {
    let local = propertyName(for: binding)
    var lines = [
        "    mutating func \(stateAddName(for: binding))(_ \(groupParameterName): inout \(groupType)) throws {"
    ]

    // `value()` binds the dependency under the same local name the construction expression uses, so the
    // rendered arguments resolve unchanged. A copyable payload reads by copy and leaves the cell resolved;
    // a multi-consumer binding is therefore read once per consumer, exactly as the linear chain does.
    let dependencyLocals = constructionDependencyLocals(of: binding).filter { names.contains($0) }
    if !dependencyLocals.isEmpty {
        let guards = orderedUnique(dependencyLocals).map { "let \($0) = _wireState_\($0).value()" }
        lines.append("        guard \(guards.joined(separator: ", ")) else { return }")
    }
    lines.append("        guard \(stateCellName(for: binding)).asPending() else { return }")

    // A frontier value is a stored property, and naming one inside `addTask`'s escaping closure would
    // capture `self` — which is `inout` here, so the compiler refuses it. Copy it to a local first, which
    // is also what the closure should capture: the property is a `let` that nothing mutates. Bound after
    // the guards so the early-return paths do no work.
    for local in orderedUnique(constructionDependencyLocals(of: binding).filter { frontier.contains($0) }) {
        lines.append("        let \(local) = self.\(local)")
    }

    let construction = constructionExpression(for: binding)
    // A specialised generic `@Provides func` cannot be called with explicit type arguments, so its
    // concrete return type goes on a local and Swift infers them — there is no annotation slot on
    // `asResolved`, nor on an enum case's payload.
    let annotation: String? = {
        guard case .provider(let provider) = binding, !provider.concreteGenericArguments.isEmpty else {
            return nil
        }
        return binding.boundTypeReference
    }()

    if bindingIsAsync(binding) {
        if let annotation {
            lines.append("        \(groupParameterName).addTask {")
            lines.append("            let \(local): \(annotation) = \(construction)")
            lines.append("            return .\(local)(\(local))")
            lines.append("        }")
        } else {
            lines.append("        \(groupParameterName).addTask { .\(local)(\(construction)) }")
        }
    } else {
        if let annotation {
            lines.append("        let \(local): \(annotation) = \(construction)")
            lines.append("        \(stateCellName(for: binding)).asResolved(\(local))")
        } else {
            lines.append("        \(stateCellName(for: binding)).asResolved(\(construction))")
        }
        lines.append(contentsOf: cascadeLines(from: local, dependents: dependents, indent: "        "))
    }
    lines.append("    }")
    return lines
}

/// The parent's half of the task boundary: apply one child's result to its cell and fire its dependents.
///
/// This is where the cascade decision runs for a scheduled binding, rather than inside the child that
/// produced it. The hop costs nothing — the parent is suspended on the iterator anyway — and it is what
/// keeps all cell mutation on one frame, which is why no cell needs a lock.
private func schedulerUpdateMethodLines(
    structName: String,
    group: [DiscoveredBinding],
    dependents: [String: [DiscoveredBinding]],
    groupType: String
) -> [String] {
    var lines = [
        "    mutating func _wireUpdate("
            + "_ \(resultParameterName): \(taskResultEnumName(forGraph: structName)), "
            + "_ \(groupParameterName): inout \(groupType)"
            + ") throws {",
        "        switch \(resultParameterName) {",
    ]
    for binding in group where bindingIsAsync(binding) {
        let local = propertyName(for: binding)
        lines.append("        case .\(local)(let _wireValue):")
        lines.append("            \(stateCellName(for: binding)).asResolved(_wireValue)")
        lines.append(contentsOf: cascadeLines(from: local, dependents: dependents, indent: "            "))
    }
    lines.append("        }")
    lines.append("    }")
    return lines
}

/// The cascade from one resolution into its direct dependents. Each is a plain call: the dependent's own
/// guard decides whether it is ready, so a dependent with several dependencies is simply fired by each.
private func cascadeLines(
    from local: String,
    dependents: [String: [DiscoveredBinding]],
    indent: String
) -> [String] {
    (dependents[local] ?? []).map { dependent in
        "\(indent)try \(stateAddName(for: dependent))(&\(groupParameterName))"
    }
}

/// Opening the group: hand the building struct its frontier values, start every group binding that is
/// ready, and drain.
///
/// Driving from the ready bindings rather than calling every `add` in order is what makes the cascade
/// load-bearing instead of decorative — walked in the group's own order, each `add` would already find its
/// dependencies resolved and the cascade would be dead code. "Ready" means no *group* dependency: a
/// frontier one is a stored property that is already resolved. The loop is `while let … = try await
/// next()` rather than `for try await … in`, because the body needs the group `inout` and iterating it
/// while mutating it is an overlapping access.
///
/// The caller appends the seam, the suffix and the memberwise init after this, then
/// `schedulerBootstrapClosingLines`.
func schedulerBootstrapOpeningLines(
    structName: String,
    regions: ConstructionRegions,
    tornInGroup: [DiscoveredBinding]
) -> [String] {
    let names = Set(regions.group.map { propertyName(for: $0) })
    let arguments = regions.frontier
        .map { "\(propertyName(for: $0)): \(propertyName(for: $0))" }
        .joined(separator: ", ")
    var lines = [
        "    return try await withThrowingTaskGroup("
            + "of: \(taskResultEnumName(forGraph: structName)).self"
            + ") { \(groupParameterName) in",
        "        var building = \(buildingStructName(forGraph: structName))(\(arguments))",
    ]
    // M7c.5 — a scheduled `@Teardown` binding is built inside a method of the building struct, where the
    // accumulator is out of scope, so a throw during the drain is where its cell has to be read instead.
    // The `do` is emitted only when there is such a binding; otherwise the outer `catch` is the whole story.
    let recovers = !tornInGroup.isEmpty
    let bodyIndent = recovers ? "            " : "        "
    if recovers { lines.append("        do {") }
    for binding in regions.group
    where constructionDependencyLocals(of: binding).allSatisfy({ !names.contains($0) }) {
        lines.append("\(bodyIndent)try building.\(stateAddName(for: binding))(&\(groupParameterName))")
    }
    lines.append("\(bodyIndent)while let \(resultParameterName) = try await \(groupParameterName).next() {")
    lines.append("\(bodyIndent)    try building._wireUpdate(\(resultParameterName), &\(groupParameterName))")
    lines.append("\(bodyIndent)}")
    lines.append(contentsOf: groupTeardownRecoveryLines(tornInGroup: tornInGroup, indent: "        "))
    return lines
}

/// The seam, outbound: every scheduled binding becomes a local again.
///
/// This is what keeps M7c.4 small. After these lines the suffix chain, the member-injection block, the
/// captured teardown closure and the memberwise init are all standing on locals, which is the ground every
/// one of them was written against — so none of them has to know a scheduler exists.
func schedulerSeamLines(regions: ConstructionRegions) -> [String] {
    regions.group.map { "        let \(propertyName(for: $0)) = building.\(stateCellName(for: $0)).take()" }
}

/// Closes the group closure the opening above began.
func schedulerBootstrapClosingLines() -> [String] { ["    }"] }

/// The indent everything inside the group closure takes, which is one level deeper than the linear chain's
/// because the whole tail of the bootstrap moved inside it.
let schedulerReturnIndent = "        "

/// Re-indent lines an existing emitter produced for the bootstrap frame so they can sit inside the group
/// closure. Blank lines stay blank, so the emitted body keeps its paragraphing.
func indentedForGroupBody(_ lines: [String]) -> [String] {
    lines.map { $0.isEmpty ? $0 : "    " + $0 }
}

/// Order-preserving dedup — a binding that names the same dependency twice guards it once.
private func orderedUnique(_ values: [String]) -> [String] {
    var seen: Set<String> = []
    return values.filter { seen.insert($0).inserted }
}
