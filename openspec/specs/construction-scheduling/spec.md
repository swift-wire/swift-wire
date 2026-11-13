# Effect-aware construction and scheduling

## Purpose

How the generated bootstrap builds a graph's bindings. Every construction line carries the `try` and
`await` its binding's declared effects call for, and the bootstrap is always `async throws`. A graph
with two async bindings that can overlap is split into a serial prefix, a scheduled group and a serial
suffix; the group runs in a `ThrowingTaskGroup` driven by a `~Copyable` building struct of
`_WireBindingState` cells. Once the group drains, the *seam* turns each group binding's cell back into
a local, and the suffix is built after it. Seeded scope-entry thunks are scheduled on the same terms.

Rationale: [ConstructionScheduling](../../../Documentation/Notes/ConstructionScheduling.md), [EffectAwareResolution](../../../Documentation/Notes/EffectAwareResolution.md).
Documentation: [LifecycleAndTeardown](../../../Sources/Wire/Wire.docc/LifecycleAndTeardown.md), [ConcurrencyAndIsolation](../../../Sources/Wire/Wire.docc/ConcurrencyAndIsolation.md).

## Requirements

### Requirement: The bootstrap is always `async throws`
WireGen SHALL declare every generated `_wireBootstrap` function and every graph or seed-scope
bootstrap entry on the `Wire` facade (`bootstrap`, `bootstrap<Name>`, `bootstrap<S>Scope`)
`async throws`, whatever the effects of the graph's bindings, and the facade SHALL call the bootstrap as
`try await`. This does not cover the test-variant `bootstrap…Contributor(wireGraph:)` facade methods,
which build a proxy from a graph that already exists and are synchronous and non-throwing.

#### Scenario: a wholly synchronous graph
- **WHEN** a graph's only binding is a `@Singleton` with a synchronous, non-throwing initialiser
- **THEN** `_wireBootstrap()` and `Wire.bootstrap()` are both still declared `async throws`, though nothing in the graph suspends or throws

Pinned by: `Tests/WireGenCoreTests/CodeEmissionTests.swift` (`propertyAssignmentMemberInjectionEmitsAsDirectAssignmentAfterConstruction`, `methodCallMemberInjectionEmitsAsMethodCallAfterConstruction`), `GoldenHarness/Golden/_WireGraph.swift.golden`.

### Requirement: Effects are read from the declaration's effect specifiers
Discovery SHALL record whether a binding's construction is async and whether it throws from the
effect specifiers of the `@Provides func`, the `@Inject init`, or the `get` accessor of a computed
`@Provides var`. A stored `@Provides` property and the shorthand getter `var x: T { expression }`
SHALL be treated as synchronous and non-throwing.

#### Scenario: an async throwing computed provider
- **WHEN** `@Provides var fetchedFoo: Foo { get async throws { … } }` is bound
- **THEN** it is recorded as async and throwing, so the bootstrap reads it with `try await`, as `try await fetchedFoo`

#### Scenario: an async throwing initialiser
- **WHEN** `@Singleton struct DatabasePool` declares `@Inject init() async throws`
- **THEN** it is recorded as async and throwing, so the bootstrap constructs it with `try await`, as `try await DatabasePool()`

Pinned by: `Tests/WireGenCoreTests/DiscoveryTests.swift` (`injectInitWithAsyncCapturesFlag`, `injectInitWithThrowsCapturesFlag`, `injectInitWithAsyncThrowsCapturesBothFlags`, `injectPropertySynthesizedInitIsSync`, `providesFunctionWithEffectsCapturesFlags`, `providesComputedPropertyWithEffectsCapturesFlags`, `providesStoredPropertyHasNoEffects`), `Tests/WireGenCoreTests/EffectAwareEmissionTests.swift` (`asyncThrowsComputedPropertyEmitsTryAwaitPrefix`, `asyncThrowsInitOnScopeBoundEmitsTryAwaitPrefix`, `asyncInitOnScopeBoundEmitsAwaitPrefix`), `Tests/IntegrationTests/BootstrapTests.swift` (`asyncThrowsProviderFunctionResolvesThroughBootstrap`, `asyncThrowsComputedPropertyResolvesThroughBootstrap`, `asyncThrowsInjectInitResolvesThroughBootstrap`). The shorthand-getter clause is pinned by nothing yet.

### Requirement: Each construction line carries exactly its own binding's prefix
WireGen SHALL prefix a binding's construction expression with `try ` when it throws, `await ` when it
is async, `try await ` when both, and nothing when neither, independently of the effects of its
dependencies.

#### Scenario: one prefix per colour
- **WHEN** `@Provides func makeFoo() async -> Foo`, `@Provides func makeBar() throws -> Bar` and `@Provides func makeQux() -> Qux` are bound
- **THEN** `makeFoo()` is awaited, `makeBar()` is tried, and `makeQux()` is called with neither

#### Scenario: a mixed chain
- **WHEN** a synchronous `Logger` is injected as `logger` into an `async throws` `DatabasePool`, which is injected as `pool` into an `async throws` `Application`
- **THEN** `Logger` is constructed with neither keyword, and `DatabasePool` and `Application` each with `try await`, none taking its prefix from the bindings it reads

Pinned by: `Tests/WireGenCoreTests/EffectAwareEmissionTests.swift` (`asyncFunctionProviderEmitsAwaitPrefix`, `throwsFunctionProviderEmitsTryPrefix`, `asyncThrowsFunctionProviderEmitsTryAwaitPrefix`, `syncFunctionProviderEmitsNoPrefix`, `syncInitOnScopeBoundEmitsNoPrefix`, `chainOfMixedEffectsRendersEachCallWithCorrectPrefix`).

### Requirement: A graph is scheduled only when two async bindings are independent
WireGen SHALL emit the scheduled form for a graph only if it has two async bindings neither of which
reaches the other through construction edges, sync bindings included; the exclusions in "Constructs the
scheduler has not yet translated keep the whole graph on the chain" and "A scope-entry thunk in the
group keeps the graph on the chain" can still keep such a graph on the chain. A graph without such a pair SHALL be
built as the linear `let` chain and SHALL NOT reference `_WireBindingState`. Aggregates SHALL count as
synchronous.

#### Scenario: a single async binding
- **WHEN** the only async binding is `Pool` with `@Inject init() async`
- **THEN** the graph is not scheduled: `Pool` is awaited on the linear chain and no cell is declared

#### Scenario: async bindings joined through a sync one
- **WHEN** async `Pool` is read by sync `Bridge`, which is read by async `Cache`
- **THEN** the graph is not scheduled

#### Scenario: an independent async pair
- **WHEN** async `Pool` and async `Cache` share no dependency path
- **THEN** the graph is scheduled: the file declares `_WireBuilding`, and `Pool` is constructed in a child task of the bootstrap's task group instead of being awaited on the chain

Pinned by: `Tests/WireGenCoreTests/ConstructionSchedulingTests.swift` (`aWhollySyncGraphKeepsTheLinearChain`, `aSingleAsyncBindingKeepsTheLinearChain`, `aChainOfAsyncBindingsKeepsTheLinearChain`, `independenceIsTransitiveThroughSyncBindings`, `twoIndependentAsyncBindingsAreScheduled`).

### Requirement: A scheduled graph is split into prefix, group and suffix
WireGen SHALL partition a scheduled graph's topological order into three regions. The overlap set is
every async binding with an independent async partner. A binding in the overlap set SHALL be in the
group; a binding with no overlap ancestor SHALL be in the prefix; a binding that waits on every member
of the overlap set SHALL be in the suffix; every other binding SHALL be in the group. The prefix SHALL
be built on the linear chain before the group opens and the suffix after the group drains.

#### Scenario: an upstream binding stays on the chain
- **WHEN** sync `Config` is read by async `Pool`, async `Cache` is independent of `Pool`, sync `Service` reads only `Pool`, and sync `Host` injects `service: Service` and `cache: Cache`
- **THEN** `Config` is in the prefix: it is constructed on the chain before the group opens, and it has no cell

#### Scenario: a binding waiting on only some async bindings is scheduled
- **WHEN** sync `Config` is read by async `Pool`, async `Cache` is independent of `Pool`, sync `Service` reads only `Pool`, and sync `Host` injects `service: Service` and `cache: Cache`
- **THEN** `Service` is in the group: it has a cell in the building struct, and it is fired once `Pool` resolves rather than after the group drains

#### Scenario: a binding waiting on every async binding returns to the chain
- **WHEN** sync `Config` is read by async `Pool`, async `Cache` is independent of `Pool`, sync `Service` reads only `Pool`, and sync `Host` injects `service: Service` and `cache: Cache`
- **THEN** `Host` is in the suffix: it is constructed on the chain after the seam, from the locals the seam binds, and it has no cell

Pinned by: `Tests/WireGenCoreTests/ConstructionSchedulingTests.swift` (`aBindingUpstreamOfEveryAsyncOneStaysOnTheChain`, `aBindingWaitingOnOnlySomeAsyncBindingsIsScheduled`, `aBindingWaitingOnEveryAsyncOneReturnsToTheChain`).

### Requirement: The building struct holds one cell and one `add` per group binding
For a scheduled graph WireGen SHALL emit a `~Copyable` struct named from the graph struct with the
`WireGraph` suffix replaced by `WireBuilding` (`_WireGraph` becomes `_WireBuilding`). It SHALL declare
one `var _wireState_<name>: _WireBindingState<T> = .unmarked` per group binding and one
`mutating func _wireAdd_<name>(_ _wireGroup: inout ThrowingTaskGroup<…, any Error>) throws` per group
binding. The cell type SHALL come from the `Wire` module rather than being emitted.

#### Scenario: two scheduled graphs in one file
- **WHEN** the default graph and a `@Container` graph named `Other` are both scheduled
- **THEN** each graph gets its own building struct, `_WireBuilding` and `_OtherWireBuilding`, and both use the `_WireBindingState` cell type from `Wire` rather than a copy declared in the file

Pinned by: `Tests/WireGenCoreTests/ConstructionSchedulingTests.swift` (`theCellTypeComesFromTheLibraryRatherThanBeingEmitted`, `twoIndependentAsyncBindingsAreScheduled`), `Tests/WireTests/BindingStateTests.swift` (`onlyTheFirstClaimantConstructs`), `GoldenHarness/Golden/_WireGraph.swift.golden`.

### Requirement: An `add` checks its group dependencies before claiming its cell
Each `_wireAdd_<name>` SHALL first bind every group dependency with
`guard let <dep> = _wireState_<dep>.value() else { return }`, then claim its own cell with
`guard _wireState_<name>.asPending() else { return }`. An async binding SHALL then hand its
construction to `_wireGroup.addTask { .<name>(<construction>) }`; a synchronous binding SHALL construct
in place with `_wireState_<name>.asResolved(<construction>)` and then call `try _wireAdd_<dependent>(&_wireGroup)`
for each direct group dependent. A specialised generic `@Provides func` is instead first bound to a
type-annotated local, `let <name>: <T> = <construction>`, which the task returns as `.<name>(<name>)` or
the cell resolves with as `asResolved(<name>)`.

#### Scenario: a fan-in dependent is fired from each dependency
- **WHEN** group binding `Service` reads the scheduled bindings `Pool` and `Cache`, and a third independent async binding, `Spare`, keeps `Service` out of the suffix
- **THEN** `Service`'s `add` is fired when `Pool` resolves and again when `Cache` does, and it checks that both have resolved before it claims its cell, so it is constructed only once both are ready

Pinned by: `Tests/WireGenCoreTests/ConstructionSchedulingTests.swift` (`aDependentIsFiredFromEveryDependencyAndGuardedUntilAllResolve`, `aCollectedAggregateInTheGroupRegionIsScheduled`). The specialised generic form is pinned by nothing yet.

### Requirement: Child results return to the parent through `_wireUpdate`
WireGen SHALL emit an enum named with the `WireTaskResult` suffix (`_WireTaskResult` for `_WireGraph`)
declared `: Sendable`, with one case per async group binding carrying its value, and a
`mutating func _wireUpdate(_ _wireResult: …, _ _wireGroup: inout …) throws` on the building struct
that resolves the matching cell and fires that binding's direct group dependents. Synchronous group
bindings SHALL NOT have a case.

#### Scenario: a scheduled binding cascades from the drain
- **WHEN** async `Pool` has group dependent `Service`
- **THEN** when `Pool`'s child task returns, `_wireUpdate` resolves `Pool`'s cell with the returned value and fires `Service`'s `add`

#### Scenario: the marker carries only suspending bindings
- **WHEN** the group holds async `Pool` and `Cache` and sync `Service`
- **THEN** the task-result enum has a case for `Pool` and one for `Cache`, and none for `Service`, which is constructed in place rather than in a child task

Pinned by: `Tests/WireGenCoreTests/ConstructionSchedulingTests.swift` (`aScheduledBindingCascadesFromTheDrainRatherThanFromItsOwnAdd`, `theTaskResultMarkerCarriesOnlyTheScheduledBindingsThatSuspend`, `theCellTypeComesFromTheLibraryRatherThanBeingEmitted`).

### Requirement: The bootstrap drives ready bindings and drains the group
The scheduled bootstrap SHALL open `return try await withThrowingTaskGroup(of: <TaskResult>.self) { _wireGroup in`,
construct `var building = <Building>(…)`, call `try building._wireAdd_<name>(&_wireGroup)` only for
group bindings with no group dependency, and loop
`while let _wireResult = try await _wireGroup.next() { try building._wireUpdate(_wireResult, &_wireGroup) }`
until the group is empty.

#### Scenario: only ready bindings are driven
- **WHEN** the group holds `Pool`, `Cache` and `Service`, which reads `Pool`
- **THEN** the bootstrap drives `Pool` and `Cache` directly, and leaves `Service` to be fired when `Pool` resolves

#### Scenario: a dependent of the fast binding is built while the slow one is in flight
- **WHEN** `ParallelSchedulerContainer` holds the independent async providers `makeFastSignal()` and `makeSlowSignal(clock:)` and the sync `FastDependent`, which reads only `makeFastSignal()`'s value
- **THEN** `Wire.bootstrapParallelSchedulerContainer()` constructs `FastDependent` once `makeFastSignal()` returns, without waiting for `makeSlowSignal(clock:)` to return, the order the linear chain would invert

Pinned by: `Tests/WireGenCoreTests/ConstructionSchedulingTests.swift` (`onlyReadyBindingsAreDrivenFromTheBootstrap`, `theDrainRunsUntilTheGroupEmpties`), `Tests/IntegrationTests/ParallelSchedulerTests.swift` (`aDependentOfTheFastBindingRunsBeforeTheSlowOneFinishes`, `bothIndependentAsyncBindingsStillResolve`).

### Requirement: Prefix bindings a group binding reads cross as stored properties
Each prefix binding a group binding reads, a *frontier* binding, SHALL be a stored `let` on the building struct, passed to its
initialiser by label, copied to a local inside the `add` that reads it, and not read through a cell.

#### Scenario: a frontier value
- **WHEN** group binding `Pool` reads prefix binding `Config`
- **THEN** `Config` is handed to the building struct's initialiser and stored as a plain `let`, `Pool`'s `add` copies it to a local before its child task captures it, and `Pool` does not wait on a cell for it

Pinned by: `Tests/WireGenCoreTests/ConstructionSchedulingTests.swift` (`aPrefixBindingAScheduledOneReadsCrossesAsAStoredProperty`).

### Requirement: The seam turns every group binding back into a local
After the drain, the scheduled bootstrap SHALL emit `let <name> = building._wireState_<name>.take()`
for every group binding, and the suffix, member injections, teardown closure and memberwise
initialiser SHALL be emitted over those locals inside the group closure.

#### Scenario: the graph is returned from locals
- **WHEN** the independent pair `Pool` and `Cache` is scheduled
- **THEN** once the group drains, `Pool` and `Cache` are each taken out of their cells into locals, and the graph is returned from those locals

Pinned by: `Tests/WireGenCoreTests/ConstructionSchedulingTests.swift` (`theSeamTurnsEveryScheduledBindingBackIntoALocal`, `aMemberInjectionNoLongerBlocksScheduling`, `aTeardownBindingNoLongerBlocksScheduling`), `Tests/IntegrationTests/ParallelSchedulerTests.swift` (`bothIndependentAsyncBindingsStillResolve`).

### Requirement: Constructs the scheduler has not yet translated keep the whole graph on the chain
WireGen SHALL NOT schedule a graph whose group region contains a builder aggregate, a binding with an
opaque `some` bound type, or either endpoint of an existential promotion. The same constructs in the
prefix or suffix SHALL NOT prevent scheduling, and collected and mapped aggregates SHALL be scheduled.
None of the three is a limit of the scheduled form: each lacks a translation into it, and each
translation is to be written when a graph needs it. They are tracked in
https://github.com/swift-wire/swift-wire/issues/458.

#### Scenario: a builder fold in the prefix
- **WHEN** a builder aggregate for `Keys.routes` over `any Route` reads only a synchronous contributor and two independent async bindings exist
- **THEN** the graph is still scheduled, and the fold is emitted as the chain always emits it, as the local function `_wireFoldKeysRoutes()`

#### Scenario: a builder fold in the group
- **WHEN** a builder aggregate reads an async contributor that is independent of another async binding
- **THEN** the graph is not scheduled

Pinned by: `Tests/WireGenCoreTests/ConstructionSchedulingTests.swift` (`aBuilderFoldInThePrefixDoesNotBlockScheduling`, `aBuilderFoldInTheGroupRegionStillBlocksScheduling`, `aCollectedAggregateInTheGroupRegionIsScheduled`, `anOpaqueLiftInTheGroupRegionBlocksScheduling`, `anExistentialPromotionInTheGroupRegionBlocksScheduling`).

### Requirement: A scope-entry thunk in the group keeps the graph on the chain
WireGen SHALL NOT schedule an app graph whose group region contains a bridging proxy that carries a
scope-entry thunk. Regions are computed over construction edges only, and a proxy's link to the app
singletons its thunk borrows is a `.scopeCapture` dependency, which is not one. So a proxy whose only
path to a scheduled binding is its thunk's borrow lands in the prefix, this rule does not apply, and the
thunk is emitted before the group opens, ahead of the seam that binds the captured local. That
placement is tracked as a possible defect in https://github.com/swift-wire/swift-wire/issues/408.
The exclusion itself is a translation not yet written, not a limit of the scheduled form, and is
tracked with the others in https://github.com/swift-wire/swift-wire/issues/458.

#### Scenario: a proxy whose construction arguments reach an async binding
- **WHEN** a bridging proxy with a scope-entry thunk reaches a scheduled async binding through an ordinary construction argument, so it lands in the group region of an otherwise scheduled graph
- **THEN** the graph is not scheduled, and the bootstrap is the linear chain

Pinned by: nothing yet.

### Requirement: Bindings crossing the task boundary are asserted `Sendable` at their declaration
For a scheduled app graph WireGen SHALL emit `private func _wireSendableChecks<GraphStruct>()`
(`_wireSendableChecks_WireGraph` for `_WireGraph`), never called, declaring
`func _check<T: Sendable>(_: T.Type) {}` and, for each async group binding and each group or frontier
binding such a binding reads, `_check((<T>).self)` wrapped in
`#sourceLocation(file: "<declaring file>", line: <line>)` and `#sourceLocation()`. No other binding
SHALL be asserted.

#### Scenario: a scheduled binding and the frontier value it captures
- **WHEN** sync `Config` is read by async `Pool`, async `Cache` is independent of `Pool`, sync `Service` reads only `Pool`, and sync `Host` injects `service: Service` and `cache: Cache`, so `Pool` and `Cache` are scheduled with `Service` in the group and `Host` in the suffix
- **THEN** `Pool` and `Cache`, which return from child tasks, and `Config`, which `Pool`'s task captures, are asserted `Sendable`, and `Service` and `Host`, which never leave the parent, are not

#### Scenario: the directive names the declaring line
- **WHEN** `Pool` is declared at line 1 of `Pool.swift`
- **THEN** its `Sendable` assertion is attributed to `Pool.swift:1`, so a non-`Sendable` `Pool` is reported at its own declaration

Pinned by: `Tests/WireGenCoreTests/ConstructionSchedulingTests.swift` (`everyBindingCrossingTheTaskBoundaryIsAssertedSendableAtItsOwnSourceLine`, `aFrontierValueCapturedByAScheduledBindingIsAssertedTooButOthersAreNot`), `GoldenHarness/Golden/_WireGraph.swift.golden`.

### Requirement: A scope-entry thunk schedules its own construction
A seeded scope-entry thunk SHALL apply the same trigger and regions to the scope bindings it
constructs, over the set pruned to what its subject and its yielded bindings reach, declaring a local `enum _WireScopeWireTaskResult: Sendable`
and a local `struct _WireScopeWireBuilding: ~Copyable` inside the thunk and returning the entry struct
from inside `withThrowingTaskGroup(of: _WireScopeWireTaskResult.self)`. It SHALL NOT emit sendable checks.

#### Scenario: two independent async scope bindings
- **WHEN** `AsyncScopeController`, a `@Scoped(seed: AsyncScopeSeed.self)` subject that the `@AggregateController` proxy `_WireAggregateContributor_async` bridges, has a scope that reaches `AsyncScopeFast` and `AsyncScopeSlow`, neither reading the other, each with an `async throws` initialiser, and `AsyncScopeDependent`, which reads only `AsyncScopeFast`
- **THEN** a single call to `_WireAggregateContributor_async`'s `_wireEnterScope` starts both initialisers before it constructs `AsyncScopeDependent`, with both in flight at once

Pinned by: `Tests/IntegrationTests/AsyncScopeEntryTests.swift` (`bothIndependentAsyncBindingsAreInFlightAtOnce`, `theScopeStillBuildsEveryBindingAndSeedsThem`, `eachEntryGetsItsOwnScopeAndItsOwnTeardown`), `GoldenHarness/Golden/_WireGraph.swift.golden`. That both initialisers are in flight at once is not yet pinned on its own, since the test would also pass under serial construction: https://github.com/swift-wire/swift-wire/issues/451.

### Requirement: A scope whose group reads a closure local keeps the chain
WireGen SHALL keep a scope-entry thunk on the linear chain when any binding in its group region reads a
local that is not a constructed scope binding: the seed or a borrowed singleton. A `@BindType`d field of
the `doubles` parameter is itself a constructed binding (`let <field> = doubles.<field>`), so a group
binding that reads one does not keep the chain; the field crosses as a frontier value instead.

#### Scenario: a group binding reads the seed
- **WHEN** two independent async scope bindings exist and one of them takes the seed as an initialiser parameter
- **THEN** the thunk is not scheduled: it constructs every scope binding on the linear chain

Pinned by: nothing yet.

## Related specifications

- [concurrency-posture](../concurrency-posture/spec.md)
- [teardown](../teardown/spec.md)
- [scope-entry-and-generated-names](../scope-entry-and-generated-names/spec.md)
- [seeded-scopes](../seeded-scopes/spec.md)
- [binding-lifetimes](../binding-lifetimes/spec.md)
- [injection-points](../injection-points/spec.md)
- [reachability-and-retention](../reachability-and-retention/spec.md)
- [build-plugin-and-wiregen-cli](../build-plugin-and-wiregen-cli/spec.md)
