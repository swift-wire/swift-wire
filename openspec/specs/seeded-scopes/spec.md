# Seeded scopes

## Purpose

A seeded scope is a partition of a graph whose bindings live for one entry of the scope: one
request, one job, one tenant. It is identified by its seed type, whose runtime value opens it, and
it sits beside the app-scoped singletons of the default graph or of a `@Container`, never inside
another scope. This spec states how WireGen partitions bindings by container and seed, builds one
graph per seed scope that binds the seed and borrows the parent's singletons, routes a scope block's
`@Provides` into the scope, and diagnoses an injection that crosses a scope boundary. The generated
struct and facade names are specified in
[scope-entry-and-generated-names](../scope-entry-and-generated-names/spec.md). Separating a scope's
identity from its seed type is tracked in
[swift-wire#349](https://github.com/swift-wire/swift-wire/issues/349).

Rationale: [ScopeIdentityAndKeyModel](../../../Proposals/ScopeIdentityAndKeyModel.md).
Documentation: [ScopesAndLifetimes](../../../Sources/Wire/Wire.docc/ScopesAndLifetimes.md), [StructuringAnApp](../../../Sources/Wire/Wire.docc/StructuringAnApp.md).

## Requirements

### Requirement: Every binding is recorded in a `(container, scope)` partition
WireGen SHALL record each discovered binding under `Partition(container:scope:)`, where `container`
is the name of the nearest enclosing `@Container` declaration (`nil` outside one) and `scope` is the
binding's `ScopeKey` (`nil` for a `@Singleton` type and for a `@Provides` outside a scope block).

#### Scenario: a singleton beside a scoped type
- **WHEN** a module declares `@Singleton struct AppConfig` and `@Scoped(seed: RequestSeed.self) struct RequestLogger`
- **THEN** `AppConfig` is in `Partition(container: nil, scope: nil)` and `RequestLogger` is in `Partition(container: nil, scope: ScopeKey(seed: "RequestSeed"))`

#### Scenario: a scoped type inside a container
- **WHEN** `@Scoped(seed: RequestSeed.self) struct TestRequestLogger` is nested in `@Container enum TestContainer`
- **THEN** it is in `Partition(container: "TestContainer", scope: ScopeKey(seed: "RequestSeed"))` and in neither the default nor the container's singleton partition

Pinned by: `Tests/WireGenCoreTests/DiscoveryTests.swift` (`scopedTypeRoutedToPerSeedPartition`, `singletonAndScopedCoexistInSeparatePartitions`, `scopedInsideContainerRoutesToContainerAndSeedPartition`).

### Requirement: Two bindings share a scope if and only if their seed text matches
WireGen SHALL key a scope by `ScopeKey.seed`, the trimmed source text of the base of the `seed:`
argument's `.self` expression, with generic arguments kept verbatim. Bindings naming the same seed
text SHALL share one partition, and bindings naming different seed text SHALL get independent
partitions.

#### Scenario: two types, one seed
- **WHEN** `RequestLogger` and `RequestMetrics` are both `@Scoped(seed: RequestSeed.self)`
- **THEN** the `(nil, RequestSeed)` partition holds both

#### Scenario: two seeds
- **WHEN** `RequestLogger` is `@Scoped(seed: RequestSeed.self)` and `SQSWorker` is `@Scoped(seed: SQSMessage.self)`
- **THEN** each lands in its own partition

#### Scenario: a generic seed
- **WHEN** `TenantCache` is `@Scoped(seed: TenantSeed<String>.self)`
- **THEN** its partition's seed is `TenantSeed<String>`

Pinned by: `Tests/WireGenCoreTests/DiscoveryTests.swift` (`twoScopedTypesSameSeedShareAPartition`, `scopedTypesWithDifferentSeedsGetIndependentPartitions`, `scopedSeedExpressionPreservesGenericArgs`).

### Requirement: Scopes do not nest
Every `ScopeKey` WireGen constructs SHALL have `within == nil`. A `@Scoped(seed:)` type declared
inside a scope block of a different seed SHALL keep its own seed and SHALL NOT be recorded in the
block's partition.

#### Scenario: a scoped type in another seed's block
- **WHEN** `@Scoped(seed: InnerSeed.self) struct Worker` is declared inside `@Scoped(seed: OuterSeed.self) enum Block`
- **THEN** `Worker` is in the `InnerSeed` partition and no `OuterSeed` partition exists

#### Scenario: the discovered key
- **WHEN** `@Scoped(seed: RequestSeed.self) struct RequestLogger` is discovered
- **THEN** its `scopeKey.within` is `nil`

Pinned by: `Tests/WireGenCoreTests/DiscoveryTests.swift` (`scopedTypeRoutedToPerSeedPartition`, `scopedTypeInsideBlockKeepsItsOwnSeed`).

### Requirement: WireGen builds one graph per seed scope
For each container (the default graph included) and each seed with a non-empty partition in it,
WireGen SHALL build one dependency graph from the partition's bindings, one synthetic binding for
the seed, and one borrow binding per singleton of that container. The partition's scope graphs
SHALL be emitted in ascending order of their identifier suffix.

#### Scenario: two seeds in one module
- **WHEN** a module has bindings scoped to `RequestSeed` and to `JobSeed`
- **THEN** `_JobSeedWireScope` is emitted before `_RequestSeedWireScope`

Pinned by: `Tests/WireGenCoreTests/SeedScopeEmissionTests.swift` (`multipleSeedScopesEmitInSortedOrder`), `GoldenHarness/Golden/_WireGraph.swift.golden`.

### Requirement: The seed is bound in its own scope
WireGen SHALL satisfy a dependency on the seed type inside its scope from the bootstrap's `seed:`
parameter, whose internal name is `identifierName(forType:key:)` of the seed type, and SHALL store
the seed on the scope struct. No `let` line SHALL be emitted for the seed.

#### Scenario: a scoped binding that reads only the seed
- **WHEN** `RequestLogger` is `@Scoped(seed: HBRequestSeed.self)` and injects `HBRequestSeed`
- **THEN** the bootstrap is `private func _wireBootstrapHBRequestSeedScope(seed hBRequestSeed: HBRequestSeed, wireGraph _wireGraph: _WireGraph)` containing `let requestLogger = RequestLogger(seed: hBRequestSeed)`, and `_HBRequestSeedWireScope` stores `let hBRequestSeed: HBRequestSeed` and `let requestLogger: RequestLogger`

#### Scenario: reading the seed back
- **WHEN** a test enters `Wire.bootstrapTestRequestSeedScope(seed: TestRequestSeed(id: "req-1"), wireGraph: graph)`
- **THEN** `scope.testRequestSeed.id` is `"req-1"`

Pinned by: `Tests/WireGenCoreTests/SeedScopeOrchestrationTests.swift` (`scopeBindingDependingOnSeedOnlyValidates`), `Tests/WireGenCoreTests/SeedScopeEmissionTests.swift` (`seedScopeWithOnlySeedAliasingProducesScopeStruct`), `Tests/IntegrationTests/BootstrapTests.swift` (`seedScopeBootstrapInjectsSeedAndBorrowsSingleton`), `GoldenHarness/Golden/_WireGraph.swift.golden`.

### Requirement: Scoped bindings borrow singletons from the parent graph
Each singleton of the scope's container SHALL be available in the scope as a borrow whose access
path is `<parent graph local>.<property>` (`_wireGraph.<property>` over the default graph). WireGen
SHALL inline that access path at each consumer's argument site, and SHALL NOT construct the
singleton again, bind it to a local, or store it on the scope struct.

#### Scenario: a scoped logger over the app logger
- **WHEN** `@Scoped(seed: TestRequestSeed.self) struct RequestLogger` injects `TestRequestSeed` and the singleton `Logger`
- **THEN** the scope bootstrap contains `let requestLogger = RequestLogger(testRequestSeed: testRequestSeed, logger: _wireGraph.logger)` and `_TestRequestSeedWireScope` has no `logger` property

#### Scenario: an unused singleton
- **WHEN** the default graph holds `HTTPClient` and no scoped binding injects it
- **THEN** the scope graph lists it as borrowed (`hTTPClient`) and the emitted bootstrap does not mention it

Pinned by: `Tests/WireGenCoreTests/SeedScopeOrchestrationTests.swift` (`scopeBindingBorrowingSingletonValidates`, `unreferencedSingletonsStillAppearInTopologicalOrderButAreBorrowed`), `Tests/WireGenCoreTests/SeedScopeEmissionTests.swift` (`seedScopeBorrowingSingletonsExcludesThemFromStoredProperties`), `Tests/IntegrationTests/RequestLogger.swift`, `Tests/IntegrationTests/BootstrapTests.swift` (`seedScopeBootstrapInjectsSeedAndBorrowsSingleton`, `seedScopeBootstrapResolvesInScopeDependencies`), `GoldenHarness/Golden/_WireGraph.swift.golden`.

### Requirement: A container's seed scope borrows from that container's graph
A seed scope inside `@Container <C>` SHALL take `_<C>WireGraph` as its parent graph and SHALL borrow
only that container's singletons, through the access path `_<c>WireGraph.<property>`, where `<c>`
is `<C>` with its first letter lower-cased. It SHALL NOT borrow from the default graph.

#### Scenario: a job runner inside the test container
- **WHEN** `@Scoped(seed: TestJobSeed.self) struct JobRunner` inside `@Container enum TestContainer` injects `Banner`, which both the container and the default graph bind
- **THEN** the scope constructs `TestContainer.JobRunner(testJobSeed: testJobSeed, banner: _testContainerWireGraph.banner)` and `jobRunner.run()` reads the container's banner, `"[high] running on test container"`

Pinned by: `Tests/WireGenCoreTests/SeedScopeOrchestrationTests.swift` (`containerScopeOrchestrationCarriesContainerSpecificParentGraphType`), `Tests/WireGenCoreTests/SeedScopeEmissionTests.swift` (`containerScopeEmissionTargetsContainerWireGraphAsParent`), `Tests/IntegrationTests/BootstrapTests.swift` (`containerScopeBootstrapBorrowsFromContainerWireGraph`), `GoldenHarness/Golden/_WireGraph.swift.golden`.

### Requirement: Each scope entry constructs its bindings afresh
Each call of a seed scope's bootstrap SHALL construct every scoped binding again from the seed it is
given, while reading the same borrowed singletons from the graph it is passed.

#### Scenario: two entries over one graph
- **WHEN** `Wire.bootstrapTestRequestSeedScope` is called with seeds `"a"` and `"b"` over the same graph
- **THEN** the two scopes' loggers produce `"[log] [a] ping"` and `"[log] [b] ping"`

Pinned by: `Tests/IntegrationTests/BootstrapTests.swift` (`seedScopeEntriesProduceDistinctInstances`).

### Requirement: A singleton injecting a scoped binding is a missing binding with a cross-scope note
When a binding in a container's singleton partition depends on a type bound only in a seed scope of
the same container, WireGen SHALL report `error: no binding produces '<Type>'` at the dependency
site, followed by `note: '<Type>' is bound in @Scoped(seed: <Seed>.self) scope, not @Singleton` at
the binding's declaration and a note at the dependency site reading "scope '<consumer>' to
@Scoped(seed: <Seed>.self) too, or extract the scope-bound concern into a wrapper bound at the
wider scope". The consumer SHALL be named by its type name, or by its access path for a provider.

#### Scenario: a singleton storing a request logger
- **WHEN** `@Singleton struct Foo` has `@Inject var logger: RequestLogger` and `RequestLogger` is `@Scoped(seed: HBRequestSeed.self)`
- **THEN** the output contains `error: no binding produces 'RequestLogger'`, `note: 'RequestLogger' is bound in @Scoped(seed: HBRequestSeed.self) scope, not @Singleton` and `scope 'Foo' to @Scoped(seed: HBRequestSeed.self)`

#### Scenario: a provider function as the consumer
- **WHEN** `@Provides func makeWidget(logger: RequestLogger) -> Widget` is at module scope
- **THEN** the fix-it note contains `scope 'makeWidget'`

Pinned by: `Tests/WireGenCoreTests/CrossScopeDiagnosticsTests.swift` (`singletonStoringScopedBindingRendersCrossScopeNote`, `providerConsumerSurfacedInFixItAsAccessPath`).

### Requirement: Sibling seeded scopes are isolated
A seed scope's graph SHALL resolve only against its own partition, its seed and its container's
singletons. A dependency on a type bound only in another seed scope of the same container SHALL be
a missing binding whose notes name the other scope and read "sibling seeded scopes are isolated by
design; restructure so '<consumer>' lives in the same scope, or extract the cross-scope concern into
a wrapper bound at the singleton level".

#### Scenario: one seed's binding injects another's
- **WHEN** `@Scoped(seed: SeedA.self) struct AService` injects `BService`, which is `@Scoped(seed: SeedB.self)`
- **THEN** the `SeedA` graph reports `error: no binding produces 'BService'` with `note: 'BService' is bound in @Scoped(seed: SeedB.self) scope, not @Scoped(seed: SeedA.self)` and the isolation note

Pinned by: `Tests/WireGenCoreTests/CrossScopeDiagnosticsTests.swift` (`siblingSeededScopesProduceIsolationFixIt`).

### Requirement: A dependency bound nowhere carries no cross-scope note
When no other partition binds the missing `(type, key)`, WireGen SHALL report the missing binding
alone, without an `is bound in` note or a fix-it note.

#### Scenario: an unbound type
- **WHEN** `@Singleton struct Foo` injects `NotABinding` and nothing binds it
- **THEN** the output contains `error: no binding produces 'NotABinding'` and does not contain `is bound in`

#### Scenario: an unbound type inside a scope
- **WHEN** a `HBRequestSeed`-scoped binding depends on `MissingService` and neither the scope, the seed nor any borrow provides it
- **THEN** the scope graph fails validation with a missing binding

Pinned by: `Tests/WireGenCoreTests/CrossScopeDiagnosticsTests.swift` (`crossScopeHintIsAbsentForGenuinelyMissingBindings`), `Tests/WireGenCoreTests/SeedScopeOrchestrationTests.swift` (`scopeBindingMissingDependencyFails`).

### Requirement: A `@Scoped(seed:)` enum is a scope block for its `@Provides`
WireGen SHALL record each `@Provides` declared inside an `enum` carrying `@Scoped(seed: <Seed>.self)`,
directly or in a type nested in it, with `scopeKey` `ScopeKey(seed: "<Seed>")`, in the partition of
the enclosing container and that seed, and SHALL NOT record it in the singleton partition.

#### Scenario: function and property forms
- **WHEN** `@Scoped(seed: OrderSeed.self) enum OrderProviders` declares `@Provides static func makeContext(seed: OrderSeed, logger: Logger) -> OrderContext` and `@Provides static let auditTag: AuditTag`
- **THEN** both resolve inside the `OrderSeed` scope, the bootstrap contains `let orderContext = OrderProviders.makeContext(seed: orderSeed, logger: _wireGraph.logger)`, and `scope.orderProcessor.summary()` is `"[log] order:A-1 | audit | A-1"` for order `"A-1"`

#### Scenario: a block inside a container
- **WHEN** `@Scoped(seed: RequestSeed.self) enum Providers` is nested in `@Container enum App`
- **THEN** its `@Provides` is in `Partition(container: "App", scope: ScopeKey(seed: "RequestSeed"))`

Pinned by: `Tests/WireGenCoreTests/DiscoveryTests.swift` (`plainProvidesHasNoScopeKey`, `providesInScopeBlockInheritsTheBlockSeed`, `scopeBlockRoutesProvidersOutOfDefaultGraph`, `scopeBlockInContainerLandsInContainerSeedPartition`), `Tests/IntegrationTests/ScopedProvidesExample.swift`, `Tests/IntegrationTests/BootstrapTests.swift` (`scopeBlockProvidesResolveWithinSeedScope`), `GoldenHarness/Golden/_WireGraph.swift.golden`.

### Requirement: A `@Singleton` inside a scope block is an error
WireGen SHALL report an error at the type's name when a `@Singleton` type is declared inside a
`@Scoped(seed:)` scope block: "@Singleton '<Type>' can't live in the @Scoped(seed: <Seed>.self)
block — @Singleton is process-lifetime, not scoped. Use @Scoped(seed:) for a scoped self-producer,
or move it out of the block." A `@Scoped(seed:)` type in a block, and a `@Singleton` outside one,
SHALL NOT raise it.

#### Scenario: a singleton in a request block
- **WHEN** `@Singleton struct Worker` is declared inside `@Scoped(seed: RequestSeed.self) enum RequestProviders`
- **THEN** discovery reports exactly one error, containing `@Singleton 'Worker' can't live in` and `RequestSeed`

#### Scenario: a scoped type in a block
- **WHEN** `@Scoped(seed: InnerSeed.self) struct Worker` is declared inside `@Scoped(seed: OuterSeed.self) enum Block`
- **THEN** no `can't live in` diagnostic is reported

Pinned by: `Tests/WireGenCoreTests/DiscoveryTests.swift` (`singletonInScopeBlockIsError`, `scopedTypeInScopeBlockIsNotError`, `singletonOutsideScopeBlockIsNotError`).

## Related specifications

- [scope-entry-and-generated-names](../scope-entry-and-generated-names/spec.md)
- [binding-lifetimes](../binding-lifetimes/spec.md)
- [binding-identity-and-keys](../binding-identity-and-keys/spec.md)
- [containers](../containers/spec.md)
- [multibindings](../multibindings/spec.md)
- [factory-templates](../factory-templates/spec.md)
- [teardown](../teardown/spec.md)
- [reachability-and-retention](../reachability-and-retention/spec.md)
- [construction-scheduling](../construction-scheduling/spec.md)
- [concurrency-posture](../concurrency-posture/spec.md)
- [testing-variants](../testing-variants/spec.md)
- [adapter-annotations](../adapter-annotations/spec.md)
- [providers](../providers/spec.md)
