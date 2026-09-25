# Dependency cycles

## Purpose

How WireGen orders construction and rejects a graph that cannot be constructed. Every binding's
init-time dependencies form the edges of a directed graph that is sorted dependency-first; a cycle
among those edges fails the build with a diagnostic naming the whole path. Post-construction member
injections (`@Inject weak var`, `@Inject func`) are not edges, so a cycle closed through one is
legal. Only the retained graph is sorted, so a cycle nothing reaches is not reported.

Rationale: [OptionalMatchingAndCycles](../../../Documentation/Notes/OptionalMatchingAndCycles.md), [WeakInjectionSupport](../../../Documentation/Notes/WeakInjectionSupport.md).
Documentation: [InjectionPoints](../../../Sources/Wire/Wire.docc/InjectionPoints.md).

## Requirements

### Requirement: Init-time dependencies are constructed first
`buildDependencyGraph` SHALL return, on success, a topological order of the retained bindings in
which every binding appears after each producer its init-time dependencies resolve to, and each
binding appears once.

#### Scenario: a chain
- **WHEN** `A` depends on `B` and `B` depends on `C`
- **THEN** the order is `C`, `B`, `A`

#### Scenario: a diamond
- **WHEN** `A` depends on `B` and `C`, and both depend on `D`
- **THEN** `D` appears once, before `B` and `C`, which both precede `A`

Pinned by: `Tests/WireGenCoreTests/GraphTests.swift` (`twoNodesOneDependencyDependencyConstructedFirst`, `threeNodeChainOrderedCorrectly`, `diamondDependencySingleConstructionOfShared`).

### Requirement: The order is deterministic
The topological sort SHALL visit bindings in sorted identity order, so the same set of bindings
yields the same order whatever order discovery produced them in.

#### Scenario: shuffled input
- **WHEN** independent bindings `C`, `A` and `B` with no dependencies are passed to `buildDependencyGraph` in any order
- **THEN** the topological order is `A`, `B`, `C`

Pinned by: nothing yet. `Tests/WireGenCoreTests/GraphTests.swift` (`topologicalOrderIsDeterministicAcrossInputOrders`) passes only a chain, which has a single valid order, so it does not measure the sorted visit.

### Requirement: A cycle through init-time edges fails validation
When the init-time edges contain a cycle, `buildDependencyGraph` SHALL return
`.validationFailed` with at least one entry in `cycles`. Each entry SHALL be a cycle closed by a back
edge of the depth-first traversal, written as the path from its first visited node back to that
node. Cycles with the same node set SHALL be listed once, and a cycle closed only through a node
the traversal has already finished SHALL NOT be listed, so not every elementary cycle is listed.

#### Scenario: two nodes
- **WHEN** `A` depends on `B` and `B` depends on `A`
- **THEN** `cycles` has one entry containing `A` and `B`

#### Scenario: a self-loop
- **WHEN** `A` depends on `A`
- **THEN** `cycles` has one entry whose first node is `A`

#### Scenario: a disjoint acyclic binding
- **WHEN** `A` and `B` form a cycle and an unrelated `C` has no dependencies
- **THEN** `cycles` has exactly one entry

#### Scenario: a second cycle through an already visited node
- **WHEN** `A` depends on `B` and `C`, `B` depends on `C`, and `C` depends on `A`
- **THEN** `cycles` has one entry, `A`, `B`, `C`, `A`, and the cycle `A`, `C`, `A` is not listed

Pinned by: `Tests/WireGenCoreTests/GraphTests.swift` (`twoNodeCycleDetected`, `threeNodeCycleDetected`, `selfLoopDetectedAsCycle`, `disjointGraphsSomeCyclesOnlyReportsCycles`). The omission of a second cycle through an already visited node is pinned by nothing yet.

### Requirement: The cycle error is anchored at the first node and names the path
`renderValidationErrors` SHALL render each cycle as one line
`<file>:<line>:<col>: error: dependency cycle: <path>`, located at the cycle's first node, where
`<path>` joins each node's display name (the type name for a scope-bound type, the access path for a
provider, the collection type for a multibinding aggregate) with ` → ` and repeats the first node at
the end. Cycle lines SHALL follow the duplicate-binding lines and precede the missing-binding lines;
`buildDependencyGraph` never returns duplicates and cycles together, so the duplicate half of that
order applies only to a hand-built `ValidationErrors`.

#### Scenario: two nodes
- **WHEN** `@Singleton struct A { @Inject var b: B }` and `@Singleton struct B { @Inject var a: A }` are in `AB.swift`
- **THEN** the output contains `AB.swift:2:8: error: dependency cycle: A → B → A`

#### Scenario: three nodes
- **WHEN** `A` injects `B`, `B` injects `C` and `C` injects `A` in `ABC.swift`
- **THEN** the output contains `ABC.swift:2:8: error: dependency cycle: A → B → C → A`

#### Scenario: a self-loop
- **WHEN** `@Singleton struct A { @Inject var a: A }` is in `A.swift`
- **THEN** the output contains `A.swift:2:8: error: dependency cycle: A → A`

#### Scenario: a cycle and a missing binding together
- **WHEN** the validation errors hold both a cycle and a missing binding
- **THEN** both `dependency cycle: A → B → A` and `no binding produces 'Missing'` are rendered

Pinned by: `Tests/WireGenCoreTests/DiagnosticGalleryTests.swift` (`twoNodeCycleRendersWithArrowsAtFirstNode`, `threeNodeCycleRendersFullPath`, `selfLoopRendersAsSingleArrow`), `Tests/WireGenCoreTests/GraphTests.swift` (`renderValidationErrorsCyclesOnly`, `renderValidationErrorsBothCyclesAndMissingBindings`, `renderValidationErrorsMultipleCyclesEachOnItsOwnLine`). The line order across categories and the aggregate display name are pinned by nothing yet.

### Requirement: `weak let` and `unowned` edges participate in cycle detection
An `@Inject weak let` or `@Inject unowned` property SHALL be an init-time edge like an owning
property, so a cycle closed through it SHALL fail validation. A `weak let` of type `T?` SHALL form
its edge to the `T` producer it is promoted to.

#### Scenario: a cycle through an optional init-time dependency
- **WHEN** `A` has an init-time dependency `b: B?` and `B` depends on `A`
- **THEN** `cycles` has one entry

Pinned by: `Tests/WireGenCoreTests/GraphTests.swift` (`weakLetInitDependencyParticipatesInCycleDetection`), `Tests/WireGenCoreTests/DiagnosticGalleryTests.swift` (`weakLetClosingCycleRendersBreakWithWeakVarNote`, `unownedClosingCycleRendersBreakWithWeakVarNote`).

### Requirement: The cycle error notes each non-owning edge that closes it
For each consecutive pair `X → Y` in a rendered cycle path, and each `weak let` or `unowned`
init-time dependency of `X` that resolves to `Y`, the cycle error SHALL be followed by
`<dependency location>: note: '<name>' is an '@Inject <form>' that closes this cycle; change it to
'weak var' to break the cycle (the bootstrap then delivers it post-construct, off the init-time
edge)`, where `<form>` is `weak let` or `unowned`. An acyclic `weak let` or `unowned` property SHALL
produce no diagnostic.

#### Scenario: a `weak let` back-edge
- **WHEN** `A` declares `@Inject weak let b: B?` and `B` declares `@Inject var a: A`
- **THEN** the output contains `error: dependency cycle: A → B → A` and `note: 'b' is an '@Inject weak let' that closes this cycle`

#### Scenario: both edges `weak let`
- **WHEN** `A` declares `@Inject weak let b: B?` and `B` declares `@Inject weak let a: A?`
- **THEN** one cycle is reported with a note for `'b'` and a note for `'a'`

#### Scenario: an `unowned` back-edge
- **WHEN** `A` declares `@Inject unowned let b: B` and `B` declares `@Inject var a: A`
- **THEN** the output contains `note: 'b' is an '@Inject unowned' that closes this cycle` and `change it to 'weak var' to break the cycle`

Pinned by: `Tests/WireGenCoreTests/DiagnosticGalleryTests.swift` (`weakLetClosingCycleRendersBreakWithWeakVarNote`, `cycleThroughTwoWeakLetEdgesNotesBoth`, `unownedClosingCycleRendersBreakWithWeakVarNote`), `Tests/WireGenCoreTests/DiscoveryTests.swift` (`weakInjectLetEmitsNoBlanketDiagnostic`, `unownedInjectBecomesInitDependencyFlaggedNonOwning`).

### Requirement: `@Inject weak var` edges are excluded from cycle detection
The parameter of an `@Inject weak var` member injection SHALL NOT be an edge of the sorted graph,
so a cycle closed only through `weak var` edges SHALL validate, with the weak-holding binding
ordered before its target when the target depends on it at init.

#### Scenario: one weak back-edge
- **WHEN** `A` depends on `B` at init and `B` holds a weak member injection of `A`
- **THEN** the graph validates with order `B`, `A`

#### Scenario: both edges weak
- **WHEN** `A` and `B` each hold a weak member injection of the other
- **THEN** the graph validates with both in the order

#### Scenario: end to end
- **WHEN** `Coordinator` takes `View` in its `@Inject init` and `View` declares `@Inject package weak var coordinator: Coordinator?`
- **THEN** `Wire.bootstrap()` succeeds and `graph.coordinator.view === graph.view`

Pinned by: `Tests/WireGenCoreTests/GraphTests.swift` (`cycleThroughWeakInjectIsLegal`, `cycleEntirelyThroughWeakEdgesIsLegal`), `Tests/IntegrationTests/BootstrapTests.swift` (`weakInjectionBreaksSingletonCycle`, `iuoWeakVarBreaksSingletonCycle`, `weakInjectionOnActorRoutesThroughGeneratedSetterExtension`).

### Requirement: `@Inject func` edges are excluded from cycle detection
The parameters of an `@Inject func` member injection SHALL NOT be edges of the sorted graph, so a
cycle closed through an `@Inject func` parameter SHALL validate.

#### Scenario: a method back-edge
- **WHEN** `Coordinator` depends on `View` at init and `View` declares `@Inject func receiveCoordinator(_ coordinator: Coordinator)`
- **THEN** the graph validates with `View` before `Coordinator`

Pinned by: nothing yet.

### Requirement: A cycle outside the retained graph is not an error
When a reachability policy restricts the graph, the topological sort SHALL run over the retained
bindings only, so a cycle among bindings no root reaches SHALL NOT be reported.

#### Scenario: an unreached library cycle
- **WHEN** a root `App` is declared with `allowUnused: true` and dependency-module bindings `A` and `B` depend on each other but nothing reaches them
- **THEN** the graph validates

Pinned by: `Tests/WireGenCoreTests/ReachabilityTests.swift` (`cycleInPrunedSubgraphIsNotAnError`, `unreachableCycle`).

## Related specifications

- [injection-points](../injection-points/spec.md)
- [optional-promotion](../optional-promotion/spec.md)
- [reachability-and-retention](../reachability-and-retention/spec.md)
- [binding-identity-and-keys](../binding-identity-and-keys/spec.md)
