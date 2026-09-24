# Concurrency posture

## Purpose

What the generated code demands of a binding's concurrency story, and what it leaves to the Swift
checker. Wire places no blanket `Sendable` requirement on bindings: the generated graph and scope
structs derive their conformance from their stored bindings. A binding is required to be `Sendable`
where it crosses a task boundary in a scheduled construction, where a generated `Sendable` struct
stores it, or where a generated `@Sendable` closure captures it. Actor consumers are reached through an
`await` the generated code emits, specified with the member-injection forms in
[injection-points](../injection-points/spec.md). `Lazy` requires a `Sendable` value. The package-wide
`NonisolatedNonsendingByDefault` setting is specified in
[scope-entry-and-generated-names](../scope-entry-and-generated-names/spec.md).

Rationale: [ConstructionScheduling](../../../Documentation/Notes/ConstructionScheduling.md), [LazyTypeSupport](../../../Documentation/Notes/LazyTypeSupport.md).
Documentation: [ConcurrencyAndIsolation](../../../Sources/Wire/Wire.docc/ConcurrencyAndIsolation.md).

## Requirements

### Requirement: The graph struct declares no `Sendable` conformance
WireGen SHALL declare each graph struct with the conformances `Introspectable, Teardownable` and no
explicit `Sendable`, so that Swift derives `Sendable` exactly when every stored binding is `Sendable`.

#### Scenario: the default graph's declaration
- **WHEN** WireGen renders a default graph of two singletons
- **THEN** the struct is declared `internal struct _WireGraph: Introspectable, Teardownable {`

Pinned by: `Tests/WireGenCoreTests/CodeEmissionTests.swift` (`propertyAssignmentMemberInjectionEmitsAsDirectAssignmentAfterConstruction`, `propertyAssignmentOnActorConsumerRoutesThroughGeneratedSetterExtension`), `GoldenHarness/Golden/_WireGraph.swift.golden`.

### Requirement: The seed scope struct declares no `Sendable` conformance
WireGen SHALL declare each seed scope struct it emits as `internal struct _<suffix>WireScope`, followed
only by any generic clause an opaque lift adds, with no conformance clause. The suffix is the seed's
type name, prefixed by the container or test variant name when the scope belongs to one.

#### Scenario: a request-seeded scope
- **WHEN** a `@Scoped(seed: HBRequestSeed.self)` scope is emitted
- **THEN** the struct is declared `internal struct _HBRequestSeedWireScope {`

#### Scenario: a container's seed scope
- **WHEN** `TestContainer` holds a `@Scoped(seed: TestJobSeed.self)` binding
- **THEN** the struct is declared `internal struct _TestContainer_TestJobSeedWireScope {`

Pinned by: `Tests/WireGenCoreTests/SeedScopeEmissionTests.swift` (`seedScopeWithOnlySeedAliasingProducesScopeStruct`), `GoldenHarness/Golden/_WireGraph.swift.golden`.

### Requirement: A non-`Sendable` binding builds when it does not cross a task boundary
A binding that is not `Sendable` SHALL be constructible, injectable and stored on the graph, in both
the linear and the scheduled construction forms, as long as it has none of the roles the following
requirements name as requiring `Sendable`: it is not an async binding in a scheduled group of the graph
or of a scope-entry thunk, not a binding such an async binding reads, not stored by a generated
`Sendable` struct, and not captured by a generated `@Sendable` closure.

#### Scenario: a non-`Sendable` class beside scheduled bindings
- **WHEN** `SchedulerContainer` holds the non-`Sendable` class `SchedulerCounter`, read by the group binding `SchedulerService` alongside two async bindings
- **THEN** `Wire.bootstrapSchedulerContainer()` succeeds and `graph.schedulerService.counter === graph.schedulerCounter`

#### Scenario: a non-`Sendable` struct in a linear graph
- **WHEN** `PluginContainer`, which has no async bindings, holds `PluginConsumer`, a struct storing `[any ContainerPlugin]` over the non-`Sendable` protocol `ContainerPlugin`
- **THEN** `Wire.bootstrapPluginContainer()` succeeds and `graph.pluginConsumer.plugins.map { $0.id() }` is `["alpha", "beta"]`

Pinned by: `Tests/IntegrationTests/SchedulerContainerTests.swift` (`aNonSendableBindingIsSharedNotReconstructed`), `Tests/IntegrationTests/BootstrapTests.swift` (`containerMultibindingAggregatesContainerContributors`).

### Requirement: In a graph's construction, only bindings crossing a scheduled task boundary are required to be `Sendable`
Within a graph's own construction, WireGen SHALL require `Sendable` only of an async binding in a
scheduled group, whose product the graph's `: Sendable` task-result enum carries (`_WireTaskResult` for
the default graph), and of each binding such a binding reads, through the `_check<T: Sendable>`
assertions specified in [construction-scheduling](../construction-scheduling/spec.md).

#### Scenario: group bindings that do not suspend
- **WHEN** the group holds async `Pool` and `Cache` and sync `Service`, and the suffix holds `Host`
- **THEN** there is no `_check((Service).self)` and no `_check((Host).self)`

#### Scenario: the task-result enum
- **WHEN** the default graph and the container `Other` each schedule async bindings
- **THEN** the output declares `private enum _WireTaskResult: Sendable {` and `private enum _OtherWireTaskResult: Sendable {`

Pinned by: `Tests/WireGenCoreTests/ConstructionSchedulingTests.swift` (`aFrontierValueCapturedByAScheduledBindingIsAssertedTooButOthersAreNot`, `theCellTypeComesFromTheLibraryRatherThanBeingEmitted`).

### Requirement: A scope-entry thunk's scheduled group requires `Sendable` without `_check`
A scope-entry thunk that schedules its own group SHALL declare a local `enum _WireScopeWireTaskResult:
Sendable` with a case carrying each async binding in that group, and SHALL emit no
`_wireSendableChecks` assertions for it.

#### Scenario: a thunk with two async scoped bindings
- **WHEN** the thunk for `AsyncScopeController`, seeded by `AsyncScopeSeed`, schedules the async bindings `AsyncScopeFast` and `AsyncScopeSlow`
- **THEN** the thunk body declares `enum _WireScopeWireTaskResult: Sendable {` with `case asyncScopeFast(AsyncScopeFast)` and `case asyncScopeSlow(AsyncScopeSlow)`

Pinned by: `GoldenHarness/Golden/_WireGraph.swift.golden`.

### Requirement: Generated structs that store bindings are `Sendable`
WireGen SHALL declare each contributor proxy, scope-entry struct, lifted factory and test doubles
struct `Sendable`, so a proxied subject, each scope-entry yield, each lifted factory's dependency and
each `@BindType` double stored in one is required to be `Sendable`.

#### Scenario: a contributor proxy
- **WHEN** a proxy is rendered for `HealthController`
- **THEN** it is declared `struct _WireRouteContributor_HealthController: Sendable {` with `let _wireSubject: HealthController`

#### Scenario: a scope-entry struct
- **WHEN** the entry struct is rendered for `DocumentsController` yielding `AuthorizedDocument` and `Caller`
- **THEN** it is declared `struct _WireScopeEntry_DocumentsController: Sendable, WireScopeEntry {` with `let authorizedDocument: AuthorizedDocument` and `let caller: Caller`

#### Scenario: a lifted factory
- **WHEN** the factory for `MyMiddleware.session` depends on `store: SessionStore`
- **THEN** it is declared `struct _WireFactory_MyMiddleware_session: Sendable {` with `let store: SessionStore`

#### Scenario: a test doubles struct
- **WHEN** the doubles struct `_MyTests_testSetupDoubles` holds `MockBackendRepository` and `FakeClock`
- **THEN** it is declared `internal struct _MyTests_testSetupDoubles: Sendable {` with a `let` field for each

Pinned by: `Tests/WireGenCoreTests/ContributorProxyEmissionTests.swift` (`nonGenericProxyOmitsGenericClause`), `Tests/WireGenCoreTests/ScopeYieldTests.swift` (`yieldsAreNamedFieldsOnTheEntryStruct`), `Tests/WireGenCoreTests/FactorySynthesisTests.swift` (`rendersFactoryDeclarationWithAssistedCreateAndConstraint`), `Tests/WireGenCoreTests/TestingGraphTests.swift` (`renderDoublesStructEmitsPackageFieldsAndInit`), `GoldenHarness/Golden/_WireGraph.swift.golden`.

### Requirement: Generated `@Sendable` closures capture bindings
The graph's `_wireTeardown` closure SHALL capture the local of each `@Teardown` binding it tears down,
and each scope-entry thunk SHALL capture the local of each app singleton it borrows, so each such
binding is required to be `Sendable`.

#### Scenario: a `@Teardown` binding
- **WHEN** the graph holds `Pool`, whose `@Teardown` is its async throwing `teardown()` method
- **THEN** the output contains `let _wireTeardown: @Sendable () async -> [any Error] = {` and `try await pool.teardown()` on the bootstrap's `pool` local

#### Scenario: a borrowed singleton
- **WHEN** a bridging proxy's subject `SessionController`, seeded by `RequestSeed`, reads the app singleton `TodoRepository`
- **THEN** the thunk constructs `SessionController(seed: requestSeed, repository: todoRepository)` from the captured `todoRepository` local and never emits `let todoRepository = _wireGraph.todoRepository`

Pinned by: `Tests/WireGenCoreTests/TeardownDiscoveryTests.swift` (`teardownActionsEmitReverseOrderCalls`), `Tests/WireGenCoreTests/SeedScopeEmissionTests.swift` (`bridgingProxyEmitsScopeEntryThunkCapturingSingletons`).

### Requirement: `Lazy` requires a `Sendable` value
`Lazy` SHALL be declared `public struct Lazy<Value: Sendable>: Sendable` and its factory SHALL be an
`@escaping @Sendable () async throws -> Value`, so a `Lazy` can be shared across tasks.

#### Scenario: concurrent first callers
- **WHEN** 100 child tasks call `get()` on one `Lazy<Int>`
- **THEN** every task receives `99` and the factory ran once

Pinned by: `Tests/WireTests/LazyTests.swift` (`factoryCalledOnceAcrossConcurrentFirstCallers`).

### Requirement: Teardown and scope-entry closures are `@Sendable`
The graph's captured `_wireTeardown`, each accumulated teardown action and each scope entry's
`_wireScopeTeardown` SHALL be typed `@Sendable () async -> [any Error]`, and each scope-entry thunk
SHALL be a `@Sendable` closure.

#### Scenario: a scope-entry thunk
- **WHEN** a bridging proxy's subject is seeded by `RequestSeed`
- **THEN** the thunk is emitted as `{ @Sendable (requestSeed: RequestSeed) async throws in` and its teardown as `let _wireScopeTeardown: @Sendable () async -> [any Error] = {`

Pinned by: `Tests/WireGenCoreTests/SeedScopeEmissionTests.swift` (`bridgingProxyEmitsScopeEntryThunkCapturingSingletons`, `scopeEntryThunkTearsDownScopedBindings`), `GoldenHarness/Golden/_WireGraph.swift.golden`.

## Related specifications

- [construction-scheduling](../construction-scheduling/spec.md)
- [lazy](../lazy/spec.md)
- [teardown](../teardown/spec.md)
- [injection-points](../injection-points/spec.md)
- [scope-entry-and-generated-names](../scope-entry-and-generated-names/spec.md)
- [seeded-scopes](../seeded-scopes/spec.md)
- [binding-lifetimes](../binding-lifetimes/spec.md)
- [build-plugin-and-wiregen-cli](../build-plugin-and-wiregen-cli/spec.md)
