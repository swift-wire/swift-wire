# Reachability and retention

## Purpose

WireGen builds only the bindings reachable from a graph's declared roots, and stores on the generated
graph only a narrower subset of those. Reachability decides what the bootstrap constructs: the default
graph and every `@Container` graph are pruned to what their roots reach, and the unreached home-package
bindings are reported with the annotation that keeps them. Retention decides which constructed bindings
become stored properties; the rest are bootstrap locals, and the graph carries an unavailable stub in
place of each. Testing variants derive from the production retained set, as specified in
[testing-variants](../testing-variants/spec.md).

Rationale: [MultiModuleComposition](../../../Documentation/Notes/MultiModuleComposition.md).
Documentation: [WhatGetsBuilt](../../../Sources/Wire/Wire.docc/WhatGetsBuilt.md).

## Requirements

### Requirement: The default and container app graphs are pruned; seed scopes are not
WireGen SHALL build the default graph and every `@Container` app graph with reachability pruning, and
SHALL build seed-scope graphs without it. A graph built without pruning SHALL compute no reachable set
and emit every resolved binding.

#### Scenario: a graph with no pruning policy
- **WHEN** a graph is built from a rooted `Root` and an unreached library binding with no reachability policy
- **THEN** its reachable set is `nil` and both bindings are in the topological order

Pinned by: `Tests/WireGenCoreTests/ReachabilityTests.swift` (`noPolicyComputesNothing`).

### Requirement: A home-package `allowUnused: true` binding is a root
WireGen SHALL treat a binding written with `allowUnused: true` as a reachability root when its origin
module is not an `--external-module`, and SHALL root a multibinding key's aggregate the same way when
the key is declared with `allowUnused: true` in the home package.

#### Scenario: an allowUnused key in the home package
- **WHEN** a home-package collected key is declared with `allowUnused: true` and a library binding contributes to it
- **THEN** the contributor is reachable

Pinned by: `Tests/WireGenCoreTests/ReachabilityTests.swift` (`allowUnusedKeyIsARoot`, `libraryBindingLiveViaHomeRoot`).

### Requirement: `allowUnused:` counts only as a literal `true`
WireGen SHALL mark a `@Singleton`, `@Scoped` or `@Provides` binding as `allowUnused` only when the
attribute's `allowUnused:` argument is the boolean literal `true`. The macros SHALL expand the same
members whether or not `allowUnused:` is present.

#### Scenario: a literal flag
- **WHEN** `@Singleton(allowUnused: true) struct A {}` is discovered
- **THEN** the binding is marked `allowUnused`, and the macro adds the same `init()` and key as a plain `@Singleton`

Pinned by: `Tests/WireGenCoreTests/DiscoveryTests.swift` (`allowUnusedTrueIsCapturedOnSingleton`, `plainSingletonIsNotAllowUnused`, `allowUnusedTrueIsCapturedOnProvides`), `Tests/WireMacrosImplTests/SingletonMacroTests.swift` (`test_singletonWithAllowUnused_generatesSameMembers`). A non-literal argument is pinned by nothing yet.

### Requirement: A library's `allowUnused` is not a root
WireGen SHALL NOT root a binding or a key whose origin module is an `--external-module`, whatever its
`allowUnused:` argument. A library binding SHALL be live exactly when a home root reaches it.

#### Scenario: a library pins itself
- **WHEN** a library binding written `allowUnused: true` depends on another library binding and no home root reaches either
- **THEN** neither is reachable

Pinned by: `Tests/WireGenCoreTests/ReachabilityTests.swift` (`allowUnusedIsHomePackageOnly`, `allowUnusedKeyIsARoot`), `Tests/WireGenCoreTests/RetentionTests.swift` (`aLibrarysAllowUnusedDoesNotRetain`).

### Requirement: A conformance-named aggregate is a root
An aggregate that a graph conformance names SHALL be a reachability root of the default graph, as
specified in [graph-conformance](../graph-conformance/spec.md), and SHALL bring its contributors with it.

#### Scenario: an external contributor behind a conformance
- **WHEN** the composition harness consumer declares `HarnessComposableConformance` over a library key and nothing injects the aggregate
- **THEN** `composable.contributors.map(\.label)` is `["external-route"]` at run time

Pinned by: `Tests/WireGenCoreTests/ReachabilityTests.swift` (`conformanceNamedAggregateIsARoot`), `CompositionHarness/Consumer/Sources/WireHarnessConsumer/main.swift`, `.github/workflows/swift.yml` (`CompositionHarness`).

### Requirement: `@GraphInputs` properties are roots
WireGen SHALL fold each `@GraphInputs` property into a home-module provider carrying
`allowUnused: true`, which makes it a root under the home-package rule.

#### Scenario: two inputs
- **WHEN** a `@GraphInputs struct` declares two stored properties
- **THEN** both synthesised providers carry `allowUnused == true`

Pinned by: `Tests/WireGenCoreTests/GraphInputsDiscoveryTests.swift` (`eachInputBecomesAProviderReadingTheBootstrapParameter`).

### Requirement: What a seed scope borrows is a root of its app graph
WireGen SHALL root, in a container's app graph, every app singleton that one of that container's seed
scopes borrows, although the app graph has no edge to it.

#### Scenario: a request scope borrows a singleton
- **WHEN** an app graph holds a rooted `App`, a binding `BorrowedByRequestScope` a seed scope borrows, and `Unrelated`
- **THEN** the emitted set is `App` and `BorrowedByRequestScope`

Pinned by: `Tests/WireGenCoreTests/ReachabilityTests.swift` (`scopeBorrowedSingletonIsRetained`).

### Requirement: Nothing else is a root
WireGen SHALL NOT root a binding for carrying `@Teardown`, and SHALL NOT root an aggregate for its key's
visibility.

#### Scenario: an unreached teardown resource
- **WHEN** a library `Client` declares a `@Teardown` and depends on `Config`, and nothing reaches `Client`
- **THEN** neither is reachable

#### Scenario: a public key
- **WHEN** a library key is `public`, `open`, `package` or `internal` and nothing consumes its aggregate
- **THEN** the aggregate and its contributor are not reachable

Pinned by: `Tests/WireGenCoreTests/ReachabilityTests.swift` (`teardownDoesNotRoot`, `keyVisibilityDoesNotRoot`).

### Requirement: The walk follows sort edges, member injections and scope-entry thunks
WireGen SHALL walk from the roots over the graph's dependency edges, plus each member-injection
parameter (`@Inject weak var`, `@Inject func`) and each identity a bridging proxy's scope-entry thunk
constructs (its subject and its yields), all resolved through the same producer matching as ordinary
dependencies. These extra edges SHALL NOT be added to the topological sort.

#### Scenario: a binding consumed only by member injection
- **WHEN** a rooted `Root` receives `Late` only through a member injection
- **THEN** `Root` and `Late` are reachable and `Unreached` is not

#### Scenario: a proxy's subject and yield
- **WHEN** a bridging proxy's thunk constructs `MeController` and yields `Session`
- **THEN** the proxy, `MeController` and `Session` are reachable

Pinned by: `Tests/WireGenCoreTests/ReachabilityTests.swift` (`memberInjectionOnly`, `scopeEntryThunkConstructed`, `reachedAfterSpecialisation`, `diamond`, `reachableCycle`, `unreachableCycle`).

### Requirement: Unreached bindings are not emitted
WireGen SHALL restrict a pruned graph's bindings, edges, missing-binding reports and promotions to the
reachable set, home-module bindings included. The reachable set SHALL be closed under dependencies.

#### Scenario: an unreached home binding
- **WHEN** a home graph holds a rooted `DeclaredRoot` that depends on `Reached`, and an `UnreachedHomeBinding`
- **THEN** the emitted set is `DeclaredRoot` and `Reached`

#### Scenario: an unreached binding that traps on construction
- **WHEN** the composition harness consumer declares `UnreachedHomeBinding`, whose `init` calls `fatalError`, and nothing reaches it
- **THEN** the consumer bootstraps and prints `OK: unreached home binding was pruned`

Pinned by: `Tests/WireGenCoreTests/ReachabilityTests.swift` (`unreachedLibraryBindingIsNotEmitted`, `unreachedHomeBindingIsPruned`, `retentionIsClosedUnderDependencies`), `.github/workflows/swift.yml` (`CompositionHarness`).

### Requirement: A missing dependency inside a pruned binding is not an error
WireGen SHALL NOT report a missing binding whose consumer was pruned, and SHALL still report one whose
consumer is reachable. A cycle among pruned bindings is likewise not an error, as specified in
[dependency-cycles](../dependency-cycles/spec.md).

#### Scenario: an unreached library binding with an unresolvable dependency
- **WHEN** an unreached library binding depends on a type nothing in the build produces
- **THEN** the graph builds with only the rooted `App`

#### Scenario: a reached binding with an unresolvable dependency
- **WHEN** a rooted `App` depends on a library binding whose dependency nothing produces
- **THEN** the graph fails validation

Pinned by: `Tests/WireGenCoreTests/ReachabilityTests.swift` (`missingBindingInPrunedSubgraphIsNotAnError`, `missingBindingInRetainedSubgraphStillFails`, `cycleInPrunedSubgraphIsNotAnError`).

### Requirement: A pruned home binding warns with the fix
WireGen SHALL warn "'<Type>' is declared but nothing reachable from this graph's roots constructs it,
so it was not emitted. Inject it somewhere, or mark it 'allowUnused: true' if you read it from the
graph directly (as 'graph.<property>')." for each pruned binding whose origin module is not an
`--external-module`, at every access level. A keyed slot SHALL be rendered `'<Type>' (key <Key>)`.

#### Scenario: a pruned internal binding
- **WHEN** the default graph prunes an unconsumed `UserStore`
- **THEN** the warning contains `'UserStore' is declared but nothing reachable`, `'allowUnused: true'` and `graph.userStore`

#### Scenario: a pruned public binding
- **WHEN** the pruned binding is `public` or `open`
- **THEN** the warning is still reported

#### Scenario: the harness build log
- **WHEN** `CompositionHarness/run-harness.sh` builds the consumer
- **THEN** the build log contains `'UnreachedHomeBinding' is declared but nothing reachable` and `mark it 'allowUnused: true'`

Pinned by: `Tests/WireGenCoreTests/PrunedBindingDiagnosticsTests.swift` (`internalPrunedIsReported`, `visibilityDoesNotGateTheReport`, `transitivelyDeadBindingIsReported`), `CompositionHarness/run-harness.sh`.

### Requirement: A pruned `@Teardown` binding says so
WireGen SHALL render a pruned binding that declares a teardown as "'<Type>', which declares a
'@Teardown'," in the pruned-binding warning.

#### Scenario: a pruned resource
- **WHEN** a home `Client` with a `@Teardown` is pruned
- **THEN** the warning contains `which declares a '@Teardown'`

Pinned by: `Tests/WireGenCoreTests/PrunedBindingDiagnosticsTests.swift` (`teardownIsNamed`).

### Requirement: Library bindings and aggregates are pruned silently
WireGen SHALL NOT warn for a pruned binding whose origin module is an `--external-module`, nor for a
pruned synthesised aggregate. A home contributor pruned along with its aggregate SHALL be reported.

#### Scenario: a package-local contributor to an unconsumed public key
- **WHEN** a `package` contributor folds into a `public` key's aggregate that nothing consumes
- **THEN** the contributor is reported and the aggregate is not

Pinned by: `Tests/WireGenCoreTests/PrunedBindingDiagnosticsTests.swift` (`libraryPrunedIsSilent`, `aggregateIsSilent`, `packageLocalContributorToUnconsumedPublicKeyIsReported`).

### Requirement: A reached but unretained binding is a bootstrap local
The generated bootstrap SHALL construct every reachable binding, and the graph struct SHALL store only
the retained ones; the memberwise initialiser SHALL take only retained properties.

#### Scenario: a leaf reached through a root
- **WHEN** a rooted `Consumer` depends on an unrooted `Leaf`
- **THEN** the output contains `let leaf = Leaf()` and `return _WireGraph(consumer: consumer)` and no stored `let leaf: Leaf`

Pinned by: `Tests/WireGenCoreTests/RetentionTests.swift` (`aReachedButUnrootedBindingIsConstructedAndNotStored`).

### Requirement: Roots, `@Teardown` bindings and `some P` bindings are stored
The graph struct SHALL store a property for each binding that is a declared root, each binding with a
teardown action, and each binding whose bound type begins `some `.

#### Scenario: a teardown resource without allowUnused
- **WHEN** a built `Pool` declares a `@Teardown` and no `allowUnused:`
- **THEN** the struct declares `let pool: Pool` and the initialiser takes `pool: pool`

#### Scenario: an opaque binding
- **WHEN** a provider binds `some Greeting`
- **THEN** the struct is `internal struct _WireGraph<T0: Greeting>` with `let someGreeting: T0`

Pinned by: `Tests/WireGenCoreTests/RetentionTests.swift` (`anAllowUnusedHomeBindingIsStored`, `aTeardownBindingIsStoredWithoutAllowUnused`, `anOpaqueLiftedBindingIsStored`, `anAggregateAGraphConformanceNamesIsStored`).

### Requirement: A property generated code reads off a graph is stored
The graph struct SHALL store every property that the emitted file reads as `<graph local>.<name>` for
any graph local, or as `self.<name>` inside an `extension <GraphStruct>` block.

#### Scenario: a seed scope borrows a singleton
- **WHEN** a contributor-proxy facade reads `_wireGraph.storeService`
- **THEN** the parent graph stores `storeService`

Pinned by: nothing yet.

### Requirement: An unretained property is an unavailable stub
For each constructed binding it does not store, the graph struct SHALL declare, on one line,
`@available(*, unavailable, message: "'<property>' is constructed by the graph but not a direct property of it. To read it as 'graph.<property>', mark its binding at <file>:<line> 'allowUnused: true'.") internal var <property>: <Type> { fatalError() }`.

#### Scenario: an unrooted leaf
- **WHEN** a graph holds only an unrooted `Leaf` declared at `Leaf.swift:1`
- **THEN** the output contains `mark its binding at Leaf.swift:1 'allowUnused: true'`, `internal var leaf: Leaf { fatalError() }` and `return _WireGraph()`

Pinned by: `Tests/WireGenCoreTests/RetentionTests.swift` (`aDroppedPropertyLeavesAnUnavailableStubNamingItsFix`, `theStubIsLineForLineWhatTheStoredPropertyWas`).

## Related specifications

- [visibility-and-access](../visibility-and-access/spec.md)
- [graph-conformance](../graph-conformance/spec.md)
- [dependency-cycles](../dependency-cycles/spec.md)
- [teardown](../teardown/spec.md)
- [testing-variants](../testing-variants/spec.md)
- [multi-module-composition](../multi-module-composition/spec.md)
- [binding-lifetimes](../binding-lifetimes/spec.md)
- [providers](../providers/spec.md)
