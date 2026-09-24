# Teardown and lifecycle

## Purpose

How a binding declares a shutdown action and how the generated code runs it. `@Teardown` marks either
a method on an owned `@Singleton` or `@Scoped` type or, with an action argument, a `@Provides`
declaration. Every generated graph conforms to `Teardownable`; its `teardown()` runs the built
bindings' actions in reverse construction order and returns the errors it collected. The same
accumulated actions unwind a bootstrap or a scope entry that throws partway. Running app-scope
teardown is left to the caller; wire-mvc's generated entry point does not yet do so
(https://github.com/swift-wire/wire-mvc/issues/177).

Rationale: [TeardownDesign](../../../Documentation/Notes/TeardownDesign.md), [ConstructionScheduling](../../../Documentation/Notes/ConstructionScheduling.md).
Documentation: [LifecycleAndTeardown](../../../Sources/Wire/Wire.docc/LifecycleAndTeardown.md).

## Requirements

### Requirement: `@Teardown` is a marker macro with two overloads
The `Wire` module SHALL declare `@attached(peer) macro Teardown()` and
`@attached(peer) macro Teardown<Value>(_ action: @Sendable (Value) async throws -> Void)`, both
implemented by `TeardownMacro`, which SHALL expand to no declarations.

#### Scenario: the bare form on a method
- **WHEN** `@Teardown func teardown() async throws { }` is expanded
- **THEN** the expansion is the method unchanged, with no peers

#### Scenario: the action form on a producer
- **WHEN** `@Teardown({ (client: HTTPClient) in try await client.shutdown() })` is attached to `func makeClient() -> HTTPClient` and expanded
- **THEN** the expansion is the function unchanged, with no peers

Pinned by: `Tests/WireMacrosImplTests/TeardownMacroTests.swift` (`test_bareTeardownOnMethod_producesNoPeers`, `test_teardownClosureOnFunction_producesNoPeers`, `test_teardownFunctionReferenceOnFunction_producesNoPeers`).

### Requirement: The member form records the method name and its effects
WireGen SHALL record a bare `@Teardown` on an instance method of a `@Singleton` or `@Scoped` type as
that binding's teardown, keeping the method's name, which may be any name, and whether it is `async`
and whether it `throws`.

#### Scenario: an async throwing teardown method
- **WHEN** `@Singleton struct Pool` declares `@Teardown func teardown() async throws {}`
- **THEN** the binding's teardown is the member `teardown` with `isAsync` and `isThrowing` both true, and no error is reported

#### Scenario: a synchronous method with another name
- **WHEN** `@Singleton final class Cache` declares `@Teardown func close() { }`
- **THEN** the binding's teardown is the member `close` with neither effect

Pinned by: `Tests/WireGenCoreTests/TeardownDiscoveryTests.swift` (`memberTeardownRecordsMethodNameAndEffects`, `syncMemberTeardownHasNoEffects`, `scopedTypeMemberTeardownIsRecorded`).

### Requirement: A malformed member teardown is an error and records nothing
WireGen SHALL report an error and record no teardown when a member `@Teardown` method is `static`,
takes parameters, carries an argument, or is the second `@Teardown` on the type; the second case keeps
the first method and adds a note `first @Teardown declared here` at it.

#### Scenario: a static method
- **WHEN** `@Teardown static func teardown() {}` is declared
- **THEN** the error is `@Teardown method 'teardown' is 'static' — teardown runs on the constructed instance, so the method must be an instance method.`

#### Scenario: a method with parameters
- **WHEN** `@Teardown func teardown(other: Int) {}` is declared
- **THEN** the error is `@Teardown method 'teardown' takes parameters — a teardown method must take none (it is called on the instance with no resolved dependencies).`

#### Scenario: an argument on the member form
- **WHEN** `@Teardown({ (p: Pool) in }) func teardown() {}` is declared on a `@Singleton`
- **THEN** the error is `the owned-type @Teardown takes no argument — it marks the teardown method on a @Singleton/@Scoped type. Remove the argument; the action-carrying form '@Teardown({ ... })' belongs on a @Provides.`

#### Scenario: two teardown methods
- **WHEN** a type declares `@Teardown func first() {}` and `@Teardown func second() {}`
- **THEN** the error is `more than one @Teardown on this type — a binding may declare at most one teardown method.` and the recorded teardown is `first`

Pinned by: `Tests/WireGenCoreTests/TeardownDiscoveryTests.swift` (`staticMemberTeardownIsAnError`, `memberTeardownWithParametersIsAnError`, `argumentOnMemberTeardownIsAnError`, `twoMemberTeardownsIsAnError`).

### Requirement: A member teardown method must be at least `internal`
WireGen SHALL report an error for a member `@Teardown` method that is `private` or `fileprivate`, and
SHALL still record its teardown.

#### Scenario: a private teardown method
- **WHEN** `@Teardown private func teardown() async {}` is declared
- **THEN** the error is `@Teardown method 'teardown' is 'private' but must be at least 'internal' — Wire's generated bootstrap calls it at scope teardown and lives in a separate file. Change to 'internal', 'package', or 'public'.` and the binding's teardown is recorded

Pinned by: `Tests/WireGenCoreTests/TeardownDiscoveryTests.swift` (`tooPrivateMemberTeardownErrorsButStillRecords`).

### Requirement: `@Teardown` on the type declaration is an error
WireGen SHALL report an error for `@Teardown` attached to a `@Singleton` or `@Scoped` type declaration
itself, and SHALL record no teardown from it.

#### Scenario: the attribute on the type
- **WHEN** `@Singleton @Teardown struct Pool` is declared
- **THEN** the error is `@Teardown on a @Singleton/@Scoped type has no effect — mark the type's teardown method with @Teardown instead (e.g. '@Teardown func teardown() async throws { ... }').`

Pinned by: `Tests/WireGenCoreTests/TeardownDiscoveryTests.swift` (`teardownOnTheTypeItselfIsAnError`).

### Requirement: The producer form records its action expression verbatim
WireGen SHALL record `@Teardown(<action>)` on a `@Provides` function or property as that binding's
teardown, keeping the first argument's expression text, a closure or a function reference.

#### Scenario: a function reference
- **WHEN** `@Provides @Teardown(shutdownClient) func makeClient() -> HTTPClient` is declared
- **THEN** the recorded action expression is `shutdownClient`

#### Scenario: a property provider
- **WHEN** `@Provides @Teardown({ (c: HTTPClient) in c.close() }) var client: HTTPClient { HTTPClient() }` is declared
- **THEN** the recorded action expression contains `c.close()` and no error is reported

Pinned by: `Tests/WireGenCoreTests/TeardownDiscoveryTests.swift` (`producerClosureTeardownRecordsActionExpression`, `producerFunctionReferenceTeardownRecordsActionExpression`, `providesPropertyTeardownIsRecorded`, `providesWithoutTeardownRecordsNoAction`).

### Requirement: A malformed producer teardown is an error
WireGen SHALL report an error, and record nothing, for a bare `@Teardown` on a `@Provides`, and SHALL
report an error for a second `@Teardown` on one `@Provides` while keeping the first.

#### Scenario: the bare form on a producer
- **WHEN** `@Provides @Teardown func makeClient() -> HTTPClient` is declared
- **THEN** the error is `@Teardown on a @Provides requires a teardown action — a closure '@Teardown({ (value: T) in ... })' or a free/static function reference '@Teardown(shutdown)'. Bare @Teardown marks the teardown method on a @Singleton/@Scoped type.`

#### Scenario: two producer actions
- **WHEN** a `@Provides` carries `@Teardown({ (c: HTTPClient) in c.close() })` and then a second `@Teardown`
- **THEN** the error is `more than one @Teardown on this @Provides — a binding may declare at most one teardown action.` and the recorded action contains `c.close()`

Pinned by: `Tests/WireGenCoreTests/TeardownDiscoveryTests.swift` (`bareTeardownOnProvidesIsAnError`, `twoProducerTeardownsIsAnError`).

### Requirement: Every generated graph conforms to `Teardownable`
The `Wire` module SHALL declare `public protocol Teardownable { func teardown() async -> [any Error] }`
with a default implementation returning `[]`. WireGen SHALL conform every graph struct to
`Teardownable`, and SHALL emit a `teardown()` member only when the graph has at least one `@Teardown`
binding.

#### Scenario: a graph with teardown bindings, driven generically
- **WHEN** the default graph holds `@Teardown` bindings and is passed to a function taking `some Teardownable`
- **THEN** it compiles, and the graph declares `let _wireTeardown: @Sendable () async -> [any Error]` and `func teardown() async -> [any Error] {` whose body is `await _wireTeardown()`

#### Scenario: a graph with none
- **WHEN** a graph has no `@Teardown` binding
- **THEN** it is declared `: Introspectable, Teardownable` with no `teardown()` member and no `_wireTeardown` property

Pinned by: `Tests/WireGenCoreTests/TeardownDiscoveryTests.swift` (`teardownActionsEmitReverseOrderCalls`), `Tests/WireGenCoreTests/CodeEmissionTests.swift` (`propertyAssignmentMemberInjectionEmitsAsDirectAssignmentAfterConstruction`), `Tests/IntegrationTests/TeardownTests.swift` (`teardownRunsActionsInReverseDependencyOrder`).

### Requirement: Each built binding records its action where it is constructed
The bootstrap SHALL declare `var _wireTeardownActions: [@Sendable () async -> [any Error]] = []` and,
immediately after constructing each `@Teardown` binding on the linear chain, append a closure that runs
that binding's action against the construction local. A member action SHALL be called as
`<prefix><local>.<method>()` with the prefix from the method's effects; a producer action SHALL be
bound as `let action: @Sendable (<T>) async throws -> Void = <expression>` and called as
`try await action(<local>)`.

#### Scenario: both forms in one graph
- **WHEN** `Pool` has `@Teardown func teardown() async throws` and `makeClient()` has a producer action for `HTTPClient`
- **THEN** the bootstrap contains `try await pool.teardown()` and `try await action(hTTPClient)`, the pool's action is appended before the client's, and the struct stores `_wireTeardown` passed as `_wireTeardown: _wireTeardown)`

#### Scenario: an opaquely bound resource
- **WHEN** `@Singleton(as: TodoRepository.self) class PostgresTodoRepository` has `@Teardown func close() async throws`
- **THEN** the action calls `try await someTodoRepository.close()` on the concrete local and never `self.someTodoRepository`

Pinned by: `Tests/WireGenCoreTests/TeardownDiscoveryTests.swift` (`teardownActionsEmitReverseOrderCalls`, `opaqueLiftTeardownCallsConcreteLocalNotLiftedProperty`), `GoldenHarness/Golden/_WireGraph.swift.golden`.

### Requirement: `teardown()` runs actions in reverse construction order and collects errors
The captured `_wireTeardown` SHALL run the accumulated actions `.reversed()`, appending each action's
returned errors to the result. Within an action, a throwing member call or a producer action SHALL be
wrapped in `do { … } catch { errors.append(error) }`, so a failing action does not stop later ones;
a non-throwing member call SHALL be a bare call with `let errors`.

#### Scenario: dependents before dependencies
- **WHEN** `TeardownConsumer` holds `TeardownDatabasePool` and `TeardownHTTPClient`, all with teardown actions, and `graph.teardown()` runs
- **THEN** the log contains `consumer`, `pool`, `client` and `opaque`, `consumer` precedes both `pool` and `client`, and the returned errors are empty

#### Scenario: a non-throwing member teardown
- **WHEN** the only teardown is `@Teardown func close() async` on `Cache`
- **THEN** the action declares `let errors: [any Error] = []`, calls `await cache.close()`, and contains no `errors.append(error)`

Pinned by: `Tests/IntegrationTests/TeardownTests.swift` (`teardownRunsActionsInReverseDependencyOrder`), `Tests/WireGenCoreTests/TeardownDiscoveryTests.swift` (`teardownActionsEmitReverseOrderCalls`, `nonThrowingMemberTeardownBindsErrorsWithLet`).

### Requirement: A bootstrap that throws unwinds what it built and rethrows
When a graph has a `@Teardown` binding and its construction can throw, the bootstrap SHALL wrap
construction in `do { … } catch { for action in _wireTeardownActions.reversed() { _ = await action() }; throw error }`,
discarding teardown errors and rethrowing the construction's original error.

#### Scenario: a throwing initialiser after a built resource
- **WHEN** `ChainResource` is built and `ChainFailingConsumer`'s initialiser then throws `PartialTeardownFailure`
- **THEN** `Wire.bootstrapPartialTeardownContainer()` throws `PartialTeardownFailure` and the recorded events are `["chain.built", "chain.closed"]`

Pinned by: `Tests/IntegrationTests/PartialTeardownTests.swift` (`aThrowingInitTearsDownWhatTheChainAlreadyBuilt`, `theOriginalErrorPropagatesRatherThanATeardownOne`).

### Requirement: A scheduled `@Teardown` binding is recovered from its cell on a throw
For each `@Teardown` binding in a scheduled group, the bootstrap SHALL append its action after the seam,
and SHALL wrap the drive and drain in a `do` whose `catch` appends the action of each such binding
whose cell `isResolved()`, taken with `building._wireState_<name>.take()`, and then rethrows so the
outer unwind runs it.

#### Scenario: a sibling child task throws
- **WHEN** `ScheduledResource` resolves in the group and an independent async sibling throws
- **THEN** `Wire.bootstrapScheduledPartialTeardownContainer()` throws `PartialTeardownFailure` and the recorded events are `["scheduled.built", "scheduled.closed"]`

Pinned by: `Tests/IntegrationTests/PartialTeardownTests.swift` (`aThrowingInitTearsDownAScheduledBindingTheDrainHadResolved`), `Tests/WireGenCoreTests/ConstructionSchedulingTests.swift` (`aTeardownBindingNoLongerBlocksScheduling`), `GoldenHarness/Golden/_WireGraph.swift.golden`.

### Requirement: A scope entry carries its own teardown
Each scope-entry thunk SHALL build a `_wireScopeTeardown: @Sendable () async -> [any Error]` over the
`@Teardown` bindings it constructed, restricted to those its subject reaches and excluding borrowed
singletons, and SHALL return it on the entry struct. Each call of the thunk SHALL have its own
teardown.

#### Scenario: a scoped resource beside a borrowed singleton
- **WHEN** the scope builds `RequestConn` with `@Teardown func close() async` and borrows `TodoRepository`
- **THEN** the thunk emits `let _wireScopeTeardown: @Sendable () async -> [any Error] = {` containing `await requestConn.close()` and no `todoRepository.close()`

#### Scenario: two entries
- **WHEN** two entries are made and only the first's `_wireScopeTeardown()` is awaited
- **THEN** the first entry's session is closed and the second's is not

Pinned by: `Tests/WireGenCoreTests/SeedScopeEmissionTests.swift` (`scopeEntryThunkTearsDownScopedBindings`, `scopeEntryThunkPrunesUnreachableBindings`), `Tests/IntegrationTests/AsyncScopeEntryTests.swift` (`eachEntryGetsItsOwnScopeAndItsOwnTeardown`).

### Requirement: A scope entry that throws unwinds what it built and rethrows
A scope-entry thunk with a `@Teardown` binding SHALL declare its own
`var _wireScopeTeardownActions: [@Sendable () async -> [any Error]] = []` inside the thunk and, when its
construction can throw, unwind it in reverse and rethrow on a throw, in both the chain and the scheduled
form, the latter recovering resolved cells as the bootstrap does.

#### Scenario: the chain form
- **WHEN** `ChainScopeResource` is built and the controller's initialiser throws `ScopeEntryFailure`
- **THEN** `_wireEnterScope(ChainScopeSeed(id: "chain"))` throws `ScopeEntryFailure` and the events are `["chain.built", "chain.closed"]`

#### Scenario: the scheduled form
- **WHEN** `GroupScopeResource` resolves in the thunk's group and a sibling task throws
- **THEN** `_wireEnterScope(GroupScopeSeed(id: "group"))` throws `ScopeEntryFailure` and the events are `["group.built", "group.closed"]`

Pinned by: `Tests/IntegrationTests/ScopePartialTeardownTests.swift` (`aThrowingScopeEntryTearsDownWhatTheChainAlreadyBuilt`, `aThrowingScopeEntryTearsDownAScheduledBindingTheDrainHadResolved`, `eachFailedEntryUnwindsOnlyItsOwn`).

### Requirement: The seed scope struct has no teardown
WireGen SHALL declare the seed scope struct returned by `bootstrap<Seed>Scope` with no `Teardownable`
conformance and no teardown member; scope teardown is carried only by a scope entry's
`_wireScopeTeardown`.

#### Scenario: a request-seeded scope
- **WHEN** a `@Scoped(seed: HBRequestSeed.self)` scope struct is emitted
- **THEN** it is declared `internal struct _HBRequestSeedWireScope {`

Pinned by: `Tests/WireGenCoreTests/SeedScopeEmissionTests.swift` (`seedScopeWithOnlySeedAliasingProducesScopeStruct`).

### Requirement: `@Teardown` does not root a binding
Reachability SHALL NOT treat a `@Teardown` binding as a root: a `@Teardown` binding nothing reaches
SHALL NOT be constructed, and a reached one SHALL be constructed with everything it holds.

#### Scenario: an unreached resource
- **WHEN** a library binding `Client` with a teardown reads `Config` and nothing reaches `Client`
- **THEN** neither is reachable

#### Scenario: a reached resource
- **WHEN** the rooted `Consumer` reads `Client`, which reads `Config`
- **THEN** `Consumer`, `Client` and `Config` are reachable and an unrelated binding is not

Pinned by: `Tests/WireGenCoreTests/ReachabilityTests.swift` (`teardownDoesNotRoot`, `teardownRidesReachability`).

### Requirement: A built `@Teardown` binding is retained on the graph
WireGen SHALL keep every constructed `@Teardown` binding as a stored property of the graph, whether or
not it is otherwise a root or read off the graph.

#### Scenario: a teardown binding without `allowUnused`
- **WHEN** `Pool` carries `@Teardown func close() async` and is the only binding
- **THEN** the graph declares `let pool: Pool` and is constructed with `pool: pool`

Pinned by: `Tests/WireGenCoreTests/RetentionTests.swift` (`aTeardownBindingIsStoredWithoutAllowUnused`).

## Related specifications

- [construction-scheduling](../construction-scheduling/spec.md)
- [concurrency-posture](../concurrency-posture/spec.md)
- [reachability-and-retention](../reachability-and-retention/spec.md)
- [scope-entry-and-generated-names](../scope-entry-and-generated-names/spec.md)
- [seeded-scopes](../seeded-scopes/spec.md)
- [binding-lifetimes](../binding-lifetimes/spec.md)
- [injection-points](../injection-points/spec.md)
- [build-plugin-and-wiregen-cli](../build-plugin-and-wiregen-cli/spec.md)
