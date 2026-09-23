# Effect-aware construction and scheduling

## Purpose

How the generated bootstrap builds a graph's bindings. Every construction line carries the `try` and
`await` its binding's declared effects call for, and the bootstrap is always `async throws`. A graph
with two async bindings that can overlap is split into a serial prefix, a scheduled group and a serial
suffix; the group runs in a `ThrowingTaskGroup` driven by a `~Copyable` building struct of
`_WireBindingState` cells. Seeded scope-entry thunks are scheduled on the same terms.

Rationale: [ConstructionScheduling](../../../Documentation/Notes/ConstructionScheduling.md), [EffectAwareResolution](../../../Documentation/Notes/EffectAwareResolution.md).
Documentation: [LifecycleAndTeardown](../../../Sources/Wire/Wire.docc/LifecycleAndTeardown.md), [ConcurrencyAndIsolation](../../../Sources/Wire/Wire.docc/ConcurrencyAndIsolation.md).

## Requirements

### Requirement: The bootstrap is always `async throws`
WireGen SHALL declare every generated `_wireBootstrap` function and every `Wire` facade bootstrap
method `async throws`, whatever the effects of the graph's bindings, and the facade SHALL call the
bootstrap as `try await`.

#### Scenario: a wholly synchronous graph
- **WHEN** a graph's only binding is a `@Singleton` with a synchronous, non-throwing initialiser
- **THEN** WireGen emits `private func _wireBootstrap() async throws -> _WireGraph {` and `static func bootstrap() async throws -> _WireGraph {`

Pinned by: `Tests/WireGenCoreTests/CodeEmissionTests.swift` (`propertyAssignmentMemberInjectionEmitsAsDirectAssignmentAfterConstruction`, `methodCallMemberInjectionEmitsAsMethodCallAfterConstruction`), `GoldenHarness/Golden/_WireGraph.swift.golden`.

### Requirement: Effects are read from the declaration's effect specifiers
Discovery SHALL record whether a binding's construction is async and whether it throws from the
effect specifiers of the `@Provides func`, the `@Inject init`, or the `get` accessor of a computed
`@Provides var`. A stored `@Provides` property and the shorthand getter `var x: T { expression }`
SHALL be treated as synchronous and non-throwing.

#### Scenario: an async throwing computed provider
- **WHEN** `@Provides var fetchedFoo: Foo { get async throws { … } }` is bound
- **THEN** its construction line is `let foo = try await fetchedFoo`

#### Scenario: an async throwing initialiser
- **WHEN** `@Singleton struct DatabasePool` declares `@Inject init() async throws`
- **THEN** its construction line is `let databasePool = try await DatabasePool()`

Pinned by: `Tests/WireGenCoreTests/EffectAwareEmissionTests.swift` (`asyncThrowsComputedPropertyEmitsTryAwaitPrefix`, `asyncThrowsInitOnScopeBoundEmitsTryAwaitPrefix`, `asyncInitOnScopeBoundEmitsAwaitPrefix`), `Tests/IntegrationTests/BootstrapTests.swift` (`asyncThrowsProviderFunctionResolvesThroughBootstrap`, `asyncThrowsComputedPropertyResolvesThroughBootstrap`, `asyncThrowsInjectInitResolvesThroughBootstrap`).

### Requirement: Each construction line carries exactly its own binding's prefix
WireGen SHALL prefix a binding's construction expression with `try ` when it throws, `await ` when it
is async, `try await ` when both, and nothing when neither, independently of the effects of its
dependencies.

#### Scenario: one prefix per colour
- **WHEN** `@Provides func makeFoo() async`, `@Provides func makeBar() throws` and `@Provides func makeQux()` are bound
- **THEN** the lines are `let foo = await makeFoo()`, `let bar = try makeBar()` and `let qux = makeQux()`

#### Scenario: a mixed chain
- **WHEN** a synchronous `Logger` is consumed by an `async throws` `DatabasePool`, which is consumed by an `async throws` `Application`
- **THEN** the lines are `let logger = Logger()`, `let databasePool = try await DatabasePool(logger: logger)` and `let application = try await Application(pool: databasePool)`

Pinned by: `Tests/WireGenCoreTests/EffectAwareEmissionTests.swift` (`asyncFunctionProviderEmitsAwaitPrefix`, `throwsFunctionProviderEmitsTryPrefix`, `asyncThrowsFunctionProviderEmitsTryAwaitPrefix`, `syncFunctionProviderEmitsNoPrefix`, `syncInitOnScopeBoundEmitsNoPrefix`, `chainOfMixedEffectsRendersEachCallWithCorrectPrefix`).

### Requirement: A graph is scheduled only when two async bindings are independent
WireGen SHALL emit the scheduled form for a graph if and only if it has two async bindings neither of
which reaches the other through construction edges, sync bindings included. Otherwise the bootstrap
SHALL be the linear `let` chain and SHALL NOT reference `_WireBindingState`. Aggregates SHALL count as
synchronous.

#### Scenario: a single async binding
- **WHEN** the only async binding is `Pool` with `@Inject init() async`
- **THEN** the bootstrap contains `let pool = await Pool()` and no `_WireBindingState`

#### Scenario: async bindings joined through a sync one
- **WHEN** async `Pool` is read by sync `Bridge`, which is read by async `Cache`
- **THEN** the graph is not scheduled

#### Scenario: an independent async pair
- **WHEN** async `Pool` and async `Cache` share no dependency path
- **THEN** WireGen emits `private struct _WireBuilding: ~Copyable {` and `_wireGroup.addTask { .pool(await Pool()) }`, and no `let pool = await Pool()`

Pinned by: `Tests/WireGenCoreTests/ConstructionSchedulingTests.swift` (`aWhollySyncGraphKeepsTheLinearChain`, `aSingleAsyncBindingKeepsTheLinearChain`, `aChainOfAsyncBindingsKeepsTheLinearChain`, `independenceIsTransitiveThroughSyncBindings`, `twoIndependentAsyncBindingsAreScheduled`).

### Requirement: A scheduled graph is split into prefix, group and suffix
WireGen SHALL partition a scheduled graph's topological order into three regions. The overlap set is
every async binding with an independent async partner. A binding in the overlap set SHALL be in the
group; a binding with no overlap ancestor SHALL be in the prefix; a binding that waits on every member
of the overlap set SHALL be in the suffix; every other binding SHALL be in the group. The prefix SHALL
be built on the linear chain before the group opens and the suffix after the group drains.

#### Scenario: an upstream binding stays on the chain
- **WHEN** sync `Config` is read by async `Pool`, and async `Cache` is independent of `Pool`
- **THEN** `let config = Config()` is emitted before the group opens and there is no `_wireState_config`

#### Scenario: a binding waiting on only some async bindings is scheduled
- **WHEN** sync `Service` reads only `Pool`
- **THEN** the building struct declares `var _wireState_service: _WireBindingState<Service> = .unmarked`

#### Scenario: a binding waiting on every async binding returns to the chain
- **WHEN** `Host` reads `Service` and `Cache`
- **THEN** `let host = Host(service: service, cache: cache)` is emitted after the seam and there is no `_wireState_host`

Pinned by: `Tests/WireGenCoreTests/ConstructionSchedulingTests.swift` (`aBindingUpstreamOfEveryAsyncOneStaysOnTheChain`, `aBindingWaitingOnOnlySomeAsyncBindingsIsScheduled`, `aBindingWaitingOnEveryAsyncOneReturnsToTheChain`), `Tests/IntegrationTests/AsyncScopeEntryTests.swift` (`theScopeStillBuildsEveryBindingAndSeedsThem`).

### Requirement: The building struct holds one cell and one `add` per group binding
For a scheduled graph WireGen SHALL emit a `~Copyable` struct named from the graph struct with the
`WireGraph` suffix replaced by `WireBuilding` (`_WireGraph` becomes `_WireBuilding`). It SHALL declare
one `var _wireState_<name>: _WireBindingState<T> = .unmarked` per group binding and one
`mutating func _wireAdd_<name>(_ _wireGroup: inout ThrowingTaskGroup<…, any Error>) throws` per group
binding. The cell type SHALL come from the `Wire` module rather than being emitted.

#### Scenario: two scheduled graphs in one file
- **WHEN** the default graph and a `@Container` graph named `Other` are both scheduled
- **THEN** the file declares `private struct _WireBuilding: ~Copyable {` and `private struct _OtherWireBuilding: ~Copyable {` and no `enum _WireBindingState`

Pinned by: `Tests/WireGenCoreTests/ConstructionSchedulingTests.swift` (`theCellTypeComesFromTheLibraryRatherThanBeingEmitted`, `twoIndependentAsyncBindingsAreScheduled`), `Tests/WireTests/BindingStateTests.swift` (`onlyTheFirstClaimantConstructs`), `GoldenHarness/Golden/_WireGraph.swift.golden`.

### Requirement: An `add` checks its group dependencies before claiming its cell
Each `_wireAdd_<name>` SHALL first bind every group dependency with
`guard let <dep> = _wireState_<dep>.value() else { return }`, then claim its own cell with
`guard _wireState_<name>.asPending() else { return }`. An async binding SHALL then hand its
construction to `_wireGroup.addTask { .<name>(<construction>) }`; a synchronous binding SHALL construct
in place with `_wireState_<name>.asResolved(<construction>)` and then call `try _wireAdd_<dependent>(&_wireGroup)`
for each direct group dependent.

#### Scenario: a fan-in dependent is fired from each dependency
- **WHEN** group binding `Service` reads two scheduled bindings
- **THEN** `try _wireAdd_service(&_wireGroup)` appears twice and its dependency guard precedes its `asPending()` guard

#### Scenario: a fan-in consumer at run time
- **WHEN** `SchedulerService` reads two async bindings and one synchronous non-`Sendable` class and `Wire.bootstrapSchedulerContainer()` runs
- **THEN** `graph.schedulerService.describe() == "config:scheduled:0"` and `graph.schedulerService.counter === graph.schedulerCounter`

Pinned by: `Tests/WireGenCoreTests/ConstructionSchedulingTests.swift` (`aDependentIsFiredFromEveryDependencyAndGuardedUntilAllResolve`, `aCollectedAggregateInTheGroupRegionIsScheduled`), `Tests/IntegrationTests/SchedulerContainerTests.swift` (`fanInConsumerSeesEveryDependencyResolved`, `aNonSendableBindingIsSharedNotReconstructed`, `anAggregateResolvesThroughTheCascadeInContributorOrder`).

### Requirement: Child results return to the parent through `_wireUpdate`
WireGen SHALL emit an enum named with the `WireTaskResult` suffix (`_WireTaskResult` for `_WireGraph`)
declared `: Sendable`, with one case per async group binding carrying its value, and a
`mutating func _wireUpdate(_ _wireResult: …, _ _wireGroup: inout …) throws` on the building struct
that resolves the matching cell and fires that binding's direct group dependents. Synchronous group
bindings SHALL NOT have a case.

#### Scenario: a scheduled binding cascades from the drain
- **WHEN** async `Pool` has group dependent `Service`
- **THEN** `_wireUpdate` contains `case .pool(let _wireValue):`, `_wireState_pool.asResolved(_wireValue)` and `try _wireAdd_service(&_wireGroup)`

#### Scenario: the marker carries only suspending bindings
- **WHEN** the group holds async `Pool` and `Cache` and sync `Service`
- **THEN** the enum declares `case pool(Pool)` and `case cache(Cache)` and no `case service(Service)`

Pinned by: `Tests/WireGenCoreTests/ConstructionSchedulingTests.swift` (`aScheduledBindingCascadesFromTheDrainRatherThanFromItsOwnAdd`, `theTaskResultMarkerCarriesOnlyTheScheduledBindingsThatSuspend`, `theCellTypeComesFromTheLibraryRatherThanBeingEmitted`).

### Requirement: The bootstrap drives ready bindings and drains the group
The scheduled bootstrap SHALL open `return try await withThrowingTaskGroup(of: <TaskResult>.self) { _wireGroup in`,
construct `var building = <Building>(…)`, call `try building._wireAdd_<name>(&_wireGroup)` only for
group bindings with no group dependency, and loop
`while let _wireResult = try await _wireGroup.next() { try building._wireUpdate(_wireResult, &_wireGroup) }`
until the group is empty.

#### Scenario: only ready bindings are driven
- **WHEN** the group holds `Pool`, `Cache` and `Service`, which reads `Pool`
- **THEN** the bootstrap calls `try building._wireAdd_pool(&_wireGroup)` and `try building._wireAdd_cache(&_wireGroup)` and not `try building._wireAdd_service(&_wireGroup)`

#### Scenario: a dependent of the fast binding is built while the slow one is in flight
- **WHEN** `Wire.bootstrapParallelSchedulerContainer()` builds `FastDependent` from `makeFastSignal()` while `makeSlowSignal(clock:)` waits for it
- **THEN** `graph.fastDependent.sawSlowAlready == false` and `graph.constructionClock.timeline == ["dependent", "slow"]`

Pinned by: `Tests/WireGenCoreTests/ConstructionSchedulingTests.swift` (`onlyReadyBindingsAreDrivenFromTheBootstrap`, `theDrainRunsUntilTheGroupEmpties`), `Tests/IntegrationTests/ParallelSchedulerTests.swift` (`aDependentOfTheFastBindingRunsBeforeTheSlowOneFinishes`, `bothIndependentAsyncBindingsStillResolve`).

### Requirement: Prefix bindings a group binding reads cross as stored properties
Each prefix binding a group binding reads SHALL be a stored `let` on the building struct, passed to its
initialiser by label, copied to a local inside the `add` that reads it, and not read through a cell.

#### Scenario: a frontier value
- **WHEN** group binding `Pool` reads prefix binding `Config`
- **THEN** the struct declares `let config: Config`, the bootstrap constructs `var building = _WireBuilding(config: config)`, `_wireAdd_pool` contains `let config = self.config`, and no `_wireState_config.value()` is emitted

Pinned by: `Tests/WireGenCoreTests/ConstructionSchedulingTests.swift` (`aPrefixBindingAScheduledOneReadsCrossesAsAStoredProperty`).

### Requirement: The seam turns every group binding back into a local
After the drain, the scheduled bootstrap SHALL emit `let <name> = building._wireState_<name>.take()`
for every group binding, and the suffix, member injections, teardown closure and memberwise
initialiser SHALL be emitted over those locals inside the group closure.

#### Scenario: the graph is returned from locals
- **WHEN** the independent pair `Pool` and `Cache` is scheduled
- **THEN** the bootstrap contains `let pool = building._wireState_pool.take()`, `let cache = building._wireState_cache.take()` and `return _WireGraph(pool: pool, cache: cache)`

Pinned by: `Tests/WireGenCoreTests/ConstructionSchedulingTests.swift` (`theSeamTurnsEveryScheduledBindingBackIntoALocal`, `aMemberInjectionNoLongerBlocksScheduling`, `aTeardownBindingNoLongerBlocksScheduling`), `Tests/IntegrationTests/SchedulerContainerTests.swift` (`aScheduledGraphStillIntrospectsEveryBinding`).

### Requirement: Constructs the group cannot hold keep the whole graph on the chain
WireGen SHALL NOT schedule a graph whose group region contains a builder aggregate, a binding with an
opaque `some` bound type, or either endpoint of an existential promotion. The same constructs in the
prefix or suffix SHALL NOT prevent scheduling, and collected and mapped aggregates SHALL be scheduled.

#### Scenario: a builder fold in the prefix
- **WHEN** a builder aggregate reads only a synchronous contributor and two independent async bindings exist
- **THEN** the graph is scheduled and the fold is emitted as `func _wireFoldKeysRoutes() -> [any Route] {`

#### Scenario: a builder fold in the group
- **WHEN** a builder aggregate reads an async contributor that is independent of another async binding
- **THEN** the graph is not scheduled

Pinned by: `Tests/WireGenCoreTests/ConstructionSchedulingTests.swift` (`aBuilderFoldInThePrefixDoesNotBlockScheduling`, `aBuilderFoldInTheGroupRegionStillBlocksScheduling`, `aCollectedAggregateInTheGroupRegionIsScheduled`, `anOpaqueLiftInTheGroupRegionBlocksScheduling`, `anExistentialPromotionInTheGroupRegionBlocksScheduling`).

### Requirement: A scope-entry thunk in the group keeps the graph on the chain
WireGen SHALL NOT schedule an app graph whose group region contains a bridging proxy that carries a
scope-entry thunk.

#### Scenario: a proxy downstream of an async binding
- **WHEN** a bridging proxy's thunk is constructed in the group region of an otherwise scheduled graph
- **THEN** the bootstrap is the linear chain

Pinned by: nothing yet.

### Requirement: Bindings crossing the task boundary are asserted `Sendable` at their declaration
For a scheduled app graph WireGen SHALL emit `private func _wireSendableChecks<GraphStruct>()`
(`_wireSendableChecks_WireGraph` for `_WireGraph`), never called, declaring
`func _check<T: Sendable>(_: T.Type) {}` and, for each async group binding and each group or frontier
binding such a binding reads, `_check((<T>).self)` wrapped in
`#sourceLocation(file: "<declaring file>", line: <line>)` and `#sourceLocation()`. No other binding
SHALL be asserted.

#### Scenario: a scheduled binding and the frontier value it captures
- **WHEN** the three-region graph schedules `Pool` (reading `Config`) and `Cache`, with `Service` in the group and `Host` in the suffix
- **THEN** the checks contain `_check((Config).self)`, `_check((Pool).self)` and `_check((Cache).self)` and neither `_check((Service).self)` nor `_check((Host).self)`

#### Scenario: the directive names the declaring line
- **WHEN** `Pool` is declared at line 1 of `Pool.swift`
- **THEN** its check is preceded by `#sourceLocation(file: "Pool.swift", line: 1)`

Pinned by: `Tests/WireGenCoreTests/ConstructionSchedulingTests.swift` (`everyBindingCrossingTheTaskBoundaryIsAssertedSendableAtItsOwnSourceLine`, `aFrontierValueCapturedByAScheduledBindingIsAssertedTooButOthersAreNot`), `GoldenHarness/Golden/_WireGraph.swift.golden`.

### Requirement: A scope-entry thunk schedules its own construction
A seeded scope-entry thunk SHALL apply the same trigger and regions to the scope bindings it
constructs, over the set pruned to what its subject reaches, declaring a local `enum _WireScopeWireTaskResult: Sendable`
and a local `struct _WireScopeWireBuilding: ~Copyable` inside the thunk and returning the entry struct
from inside `withThrowingTaskGroup(of: _WireScopeWireTaskResult.self)`. It SHALL NOT emit sendable checks.

#### Scenario: two independent async scope bindings
- **WHEN** `AsyncScopeFast` and `AsyncScopeSlow` each have an `async throws` initialiser and neither reads the other
- **THEN** a single `_wireEnterScope(AsyncScopeSeed(id: "overlap"))` call has both in flight at once, so `entry._wireSubject.slow.sawPartner` is `true`

Pinned by: `Tests/IntegrationTests/AsyncScopeEntryTests.swift` (`bothIndependentAsyncBindingsAreInFlightAtOnce`, `theScopeStillBuildsEveryBindingAndSeedsThem`, `eachEntryGetsItsOwnScopeAndItsOwnTeardown`), `GoldenHarness/Golden/_WireGraph.swift.golden`.

### Requirement: A scope whose group reads a closure local keeps the chain
WireGen SHALL keep a scope-entry thunk on the linear chain when any binding in its group region reads a
local that is not a constructed scope binding: the seed, the `doubles` parameter or a borrowed
singleton.

#### Scenario: a group binding reads the seed
- **WHEN** two independent async scope bindings exist and one of them takes the seed as an initialiser parameter
- **THEN** the thunk constructs every scope binding as a `let` chain and declares no `_WireScopeWireBuilding`

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
