# Multibindings

## Purpose

A multibinding is a binding whose value is assembled from many contributors. The `Wire` module
declares three aggregating key flavours, `CollectedKey<Element>`, `MappedKey<Key, Value>` and
`BuilderKey<Builder>`, and the `@Contributes(to:)` marker a producer carries to join one. WireGen
discovers the key declarations and the contributions, synthesises one aggregate binding per key per
partition, and validates the rules no single declaration can see. `FactoryKey`, the fourth member of
the key family, aggregates nothing and is specified in [factory-templates](../factory-templates/spec.md).

Rationale: [BuilderKeyDesign](../../../Documentation/Notes/BuilderKeyDesign.md), [MultiModuleComposition](../../../Documentation/Notes/MultiModuleComposition.md).
Documentation: [Multibindings](../../../Sources/Wire/Wire.docc/Multibindings.md).

## Requirements

### Requirement: The aggregating keys are phantom-typed markers with an `allowUnused:` initialiser
The `Wire` module SHALL export `CollectedKey<Element>`, `MappedKey<Key: Hashable, Value>` and
`BuilderKey<Builder>`, each a `Sendable` struct with no stored state and the single initialiser
`init(allowUnused: Bool = false)`. The `allowUnused:` value SHALL be read by WireGen from the
source text and SHALL have no runtime effect.

#### Scenario: a key that silences its liveness warning
- **WHEN** a module declares `static let all = CollectedKey<any Hook>(allowUnused: true)`
- **THEN** the declaration compiles against the `Wire` product and WireGen records the key with `allowUnused` set

Pinned by: `Tests/IntegrationTests/EmptyMultibindingExample.swift`, `Tests/WireGenCoreTests/MultibindingValidationTests.swift` (`allowUnusedKeyIsSilent`).

### Requirement: WireGen recognises a key declaration by its flavour name
WireGen SHALL recognise a multibinding key as a single-binding `let` at module scope or a
`static let` inside a type whose type annotation, or failing that whose constructor-call
initialiser, names `CollectedKey`, `MappedKey` or `BuilderKey`. It SHALL record the flavour, the
verbatim generic arguments, the canonical reference (the enclosing type names and the property name
joined by `.`) and the effective access level, which is the most restrictive of the declaration's
own access and every enclosing type's. A non-static stored property on a type SHALL NOT be a key.

#### Scenario: a key in an extension
- **WHEN** `extension App { static let services = CollectedKey<any Service>() }` is scanned
- **THEN** one key is recorded with reference `App.services`, flavour collected and type arguments `["any Service"]`

#### Scenario: the annotation form
- **WHEN** `enum App { static let services: CollectedKey<any Service> = .init() }` is scanned
- **THEN** the flavour and the type arguments are read from the annotation

#### Scenario: an enclosing type clamps access
- **WHEN** `public static let services = CollectedKey<any Service>()` sits inside `internal enum App`
- **THEN** the key's effective access is `internal`

Pinned by: `Tests/WireGenCoreTests/MultibindingKeyDiscoveryTests.swift` (`collectedKeyOnExtensionCapturesFlavourTypeAndReference`, `mappedKeyCapturesBothTypeArguments`, `builderKeyCapturesBuilderTypeArgument`, `moduleScopeKeyHasUnqualifiedReference`, `explicitTypeAnnotationFormIsCaptured`, `keyWithoutExplicitGenericsCapturesEmptyTypeArguments`, `effectiveAccessFoldsEnclosingTypeAccess`, `nonKeyDeclarationsAreIgnored`, `instanceLevelKeyDeclarationIsIgnored`).

### Requirement: Keys are discovered across every activated module
WireGen SHALL pool the key declarations discovered in every module of its parse set, so a
contribution or a consumer in one module can target a key declared in another activated module.

#### Scenario: a library declares the key and contributes to it
- **WHEN** a library declares `public static let contributors = CollectedKey<any HarnessRouteContributor>()` and a `@Singleton @Contributes(to: HarnessRouteKeys.contributors)` contributor, and the consuming application maps a graph conformance member to that key
- **THEN** the consumer's graph aggregates the library's contributor and `composable.contributors.map(\.label)` is `["external-route"]`

Pinned by: `CompositionHarness/Library/Sources/WireHarnessLibrary/ExternalService.swift` and `CompositionHarness/Consumer/Sources/WireHarnessConsumer/main.swift`, run by the `CompositionHarness` job in `.github/workflows/swift.yml`.

### Requirement: `@Contributes` has one overload per valid flavour and argument shape
The `Wire` module SHALL declare `@Contributes` as an attached peer macro with exactly five
overloads: `(to: CollectedKey<Element>)`, `(to: CollectedKey<Element>, withOrder: Int)`,
`(to: MappedKey<Key, Value>, atKey: Key)`, `(to: BuilderKey<Builder>)` and
`(to: BuilderKey<Builder>, withOrder: Int)`. A `MappedKey` contribution therefore SHALL require an
`atKey:` typed to the map's `Key` and SHALL NOT accept `withOrder:`.

#### Scenario: a keyed contribution
- **WHEN** `@Singleton @Contributes(to: StrategyRegistry.byName, atKey: "fast") struct FastStrategy` targets `MappedKey<String, any Strategy>`
- **THEN** the declaration type-checks against the `(to:atKey:)` overload

Pinned by: `Tests/IntegrationTests/MultibindingExample.swift`, `Tests/IntegrationTests/BuilderMultibindingExample.swift`. The rejection of a missing or wrong-typed `atKey:` and of `withOrder:` on a `MappedKey` is pinned by nothing yet.

### Requirement: The `@Contributes` macro expands to nothing
The `ContributesMacro` expansion SHALL produce no peer declarations for any argument shape.

#### Scenario: beside a producer macro
- **WHEN** `@Singleton @Contributes(to: App.services) struct AuthService {}` is expanded
- **THEN** the `@Contributes` attribute is removed and contributes no generated code

Pinned by: `Tests/WireMacrosImplTests/ContributesMacroTests.swift` (`test_contributesOnType_producesNoPeers`, `test_contributesWithOrder_producesNoPeers`, `test_contributesWithAtKey_producesNoPeers`, `test_contributesAlongsideSingleton_stripsOnlyContributes`).

### Requirement: Contributions are recorded on the producing binding
WireGen SHALL record each `@Contributes` attribute on a `@Singleton` or `@Scoped` type, or on a
`@Provides` property or function, as a contribution of that binding, capturing the key reference,
the `withOrder:` integer and the `atKey:` expression text verbatim. A declaration carrying several
`@Contributes` attributes SHALL contribute to each named key.

#### Scenario: one contributor, three builder keys
- **WHEN** `@Singleton` `LoggingMiddleware` carries `@Contributes(to:withOrder:)` for `MiddlewareRegistry.pipeline`, `.list` and `.composed`
- **THEN** it is folded into all three aggregates

Pinned by: `Tests/WireGenCoreTests/ContributionDiscoveryTests.swift` (`singletonContributionCapturesKeyReference`, `withOrderArgumentIsCaptured`, `atKeyArgumentIsCapturedVerbatim`, `multipleContributesAttributesYieldMultipleContributions`, `providesPropertyContributionIsCaptured`, `providesFunctionContributionIsCaptured`), `Tests/IntegrationTests/BootstrapTests.swift` (`builderMultibindingFoldsToConcreteResultInRankOrder`, `builderMultibindingFoldsToCollectionResult`, `builderMultibindingFoldsToExistentialResult`).

### Requirement: A contributor keeps its own binding identity
A contributing binding SHALL remain an ordinary binding under its own identity, and the aggregate
SHALL depend on it through an edge carrying that identity. Two bindings contributing to one key
SHALL NOT be reported as duplicates, and a contributor reached only through the aggregate SHALL be
constructed.

#### Scenario: two contributors to one key
- **WHEN** `Auth` and `Logging` both contribute to `App.services`
- **THEN** the graph has no validation errors and both precede the `[any Service]` aggregate in the topological order

Pinned by: `Tests/WireGenCoreTests/MultibindingFanInTests.swift` (`coContributorsAreNotDuplicates`, `aggregateSortsAfterAllContributors`, `contributorReachableOnlyViaAggregateIsConstructed`).

### Requirement: `@Contributes` requires a co-located producer macro
WireGen SHALL report an error at a `@Contributes` attribute on a type that carries neither
`@Singleton` nor `@Scoped`, reading
`@Contributes requires a co-located @Singleton or @Scoped — without a producer macro Wire can't construct the contributor.`,
and at one on a property or function without `@Provides`, reading
`@Contributes requires a co-located @Provides — without a producer macro Wire can't construct the contributor.`

#### Scenario: a bare contribution on a type
- **WHEN** `@Contributes(to: App.services) struct AuthService {}` carries no producer macro
- **THEN** the first error above is reported at the attribute

Pinned by: `Tests/WireGenCoreTests/MultibindingValidationTests.swift` (`bareContributesOnTypeRequiresScopeProducer`, `bareContributesOnVariableRequiresProvides`, `pairedContributorHasNoBareDiagnostic`).

### Requirement: A contribution must name a declared key
WireGen SHALL report an error at every contribution whose key reference matches no discovered key
declaration, reading
`@Contributes(to: <reference>) references no multibinding key — declare a 'static let <reference> = CollectedKey/MappedKey/BuilderKey<…>()' or fix the reference.`

#### Scenario: an undeclared key
- **WHEN** `@Singleton @Contributes(to: App.missing) struct AuthService {}` is scanned and no `App.missing` key is declared
- **THEN** the error names `App.missing`

Pinned by: `Tests/WireGenCoreTests/MultibindingValidationTests.swift` (`contributionToUndeclaredKeyIsError`, `contributionToDeclaredKeyIsAccepted`).

### Requirement: Ordering is all-or-none per key
Within one partition, when any contribution to a key carries `withOrder:`, WireGen SHALL report an
error at each contribution to that key without one, reading
`@Contributes(to: <reference>) has no 'withOrder:' but other contributions to '<reference>' do — ordering is all-or-none. Add 'withOrder:' here or drop it from the others.`

#### Scenario: one ranked, one unranked
- **WHEN** two contributors target `App.services` and only one carries `withOrder:`
- **THEN** the unranked contribution is reported with the error above

Pinned by: `Tests/WireGenCoreTests/MultibindingValidationTests.swift` (`mixedWithOrderIsError`, `uniformWithOrderIsAccepted`).

### Requirement: Ranks on one key are unique
Within one partition, WireGen SHALL report an error at the second and later contributions to a key
that repeat a `withOrder:` value, reading
`duplicate withOrder: <n> on '<reference>' — contributor ranks must be unique.`, with a note
`withOrder: <n> first used here` at the first use. The same rank on the same key in different
partitions SHALL be accepted.

#### Scenario: two contributors at rank 1
- **WHEN** two contributions to `App.services` both carry `withOrder: 1`
- **THEN** the later one is reported with `duplicate withOrder: 1 on 'App.services' — contributor ranks must be unique.`

Pinned by: `Tests/WireGenCoreTests/MultibindingValidationTests.swift` (`duplicateWithOrderIsError`, `distinctWithOrderRanksAreAccepted`, `sameWithOrderInDifferentPartitionsIsAccepted`), `Tests/IntegrationTests/BootstrapTests.swift` (`containerPartitionsPickTheirOwnContributions`).

### Requirement: Map keys on one key are unique
Within one partition, WireGen SHALL report an error at the second and later contributions to a
`MappedKey` that repeat an `atKey:` expression text, reading
`duplicate atKey: <expression> on '<reference>' — map keys must be unique.`, with a note
`atKey: <expression> first used here` at the first use.

#### Scenario: two strategies at `"fast"`
- **WHEN** two contributions to `App.strategies` both carry `atKey: "fast"`
- **THEN** the later one is reported with `duplicate atKey: "fast" on 'App.strategies' — map keys must be unique.`

Pinned by: `Tests/WireGenCoreTests/MultibindingValidationTests.swift` (`duplicateMapKeyIsError`, `distinctMapKeysAreAccepted`).

### Requirement: WireGen synthesises one aggregate per used key per partition
For each partition (the default graph, each container, each seed scope) WireGen SHALL synthesise
an aggregate binding for every declared key that is contributed to or consumed by an `@Inject` in
that partition, from that partition's contributors only, and SHALL synthesise none for a key used
in neither way there. The aggregate SHALL sort after all of its contributors and before its
consumers.

#### Scenario: the production/test container pattern
- **WHEN** module-scope `ServiceRegistry.all` is contributed to by one service in `ProdContainer` and another in `TestEnvContainer`
- **THEN** `Wire.bootstrapProdContainer()` yields `["real"]` and `Wire.bootstrapTestEnvContainer()` yields `["mock"]`

#### Scenario: seed-scope contributors
- **WHEN** `@Scoped(seed: ReportSeed.self)` `HeaderSection` and `BodySection` contribute to `ReportRegistry.sections` and a scoped `Report` injects it
- **THEN** `scope.report.render()` is `["header:Q3", "body"]` for seed name `"Q3"`

Pinned by: `Tests/WireGenCoreTests/MultibindingFanInTests.swift` (`aggregateSortsAfterAllContributors`, `consumerSortsAfterAggregate`, `mappedAggregateSortsAfterContributors`), `Tests/IntegrationTests/BootstrapTests.swift` (`moduleScopeKeyContributedPerContainer`, `containerMultibindingAggregatesContainerContributors`, `seedScopeMultibindingAggregatesScopeContributors`, `containerPartitionsPickTheirOwnContributions`).

### Requirement: Contributors are ordered by rank, else by source location
The aggregate SHALL list its contributors in ascending `withOrder:` when they are ranked, and
otherwise in source order by file, then line, then column.

#### Scenario: a three-way rank sort
- **WHEN** `AlphaService`, `BravoService` and `CharlieService`, declared in that order, contribute to `ServiceGate.ranked` with `withOrder:` 3, 1 and 2, and to `ServiceGate.sourceOrdered` unranked
- **THEN** `ranked` is `["bravo", "charlie", "alpha"]` and `sourceOrdered` is `["alpha", "bravo", "charlie"]`

Pinned by: `Tests/IntegrationTests/BootstrapTests.swift` (`collectedMultibindingAggregatesContributorsInRankOrder`, `collectedMultibindingRankSortsThreeContributors`, `collectedMultibindingPreservesSourceOrderWhenUnranked`).

### Requirement: A collected or mapped aggregate is a typed literal
The generated graph SHALL construct a `CollectedKey<Element>` aggregate as `[<contributors>] as [<Element>]`
and a `MappedKey<Key, Value>` aggregate as `[<atKey>: <contributor>, …] as [<Key>: <Value>]`, with
`[:] as [<Key>: <Value>]` when it has no contributors.

#### Scenario: a strategy map
- **WHEN** `FastStrategy` and `SlowStrategy` contribute to `StrategyRegistry.byName` at `"fast"` and `"slow"`
- **THEN** the injected `[String: any Strategy]` has two entries and `strategies["fast"]?.run()` is `"fast"`

Pinned by: `Tests/WireGenCoreTests/CodeEmissionTests.swift` (`collectedAggregateEmitsConstructionAndIntrospection`), `Tests/IntegrationTests/BootstrapTests.swift` (`mappedMultibindingKeysContributorsByAtKey`, `collectedMultibindingAggregatesContributorsInRankOrder`). The empty `[:]` literal is pinned by nothing yet.

### Requirement: A consumed collected key with no contributors is an empty aggregate
When a `CollectedKey` or `MappedKey` is consumed in a partition with no contributors there, WireGen
SHALL still synthesise its aggregate, so the consumer resolves to an empty collection.

#### Scenario: a hook registry nobody contributes to
- **WHEN** `HookHost` injects `HookRegistry.all` and nothing contributes to it
- **THEN** `graph.hookHost.hooks.isEmpty` is `true`

Pinned by: `Tests/WireGenCoreTests/MultibindingFanInTests.swift` (`emptyAggregateStillResolvesForConsumer`), `Tests/IntegrationTests/BootstrapTests.swift` (`emptyMultibindingBootstrapsToEmptyCollection`).

### Requirement: The builder result type is read from the `@resultBuilder` declaration
WireGen SHALL discover each `@resultBuilder` type and record as its result type the return type of
`buildFinalResult` when it declares one, otherwise of `buildBlock`. A `BuilderKey<Builder>`
aggregate SHALL have that type. A `BuilderKey` whose builder has no discovered result type, or which
has no contributors in the partition, SHALL produce no aggregate.

#### Scenario: `buildFinalResult` wins
- **WHEN** a `@resultBuilder` declares `buildBlock(_:) -> [Part]` and `buildFinalResult(_:) -> Chain`
- **THEN** its result type is `Chain`

#### Scenario: an empty builder key
- **WHEN** `App.pipeline = BuilderKey<PipelineBuilder>()` has no contributors
- **THEN** no aggregate is synthesised for `App.pipeline`

Pinned by: `Tests/WireGenCoreTests/ResultBuilderDiscoveryTests.swift` (`buildBlockResultTypeIsCaptured`, `buildFinalResultIsPreferredOverBuildBlock`, `nonResultBuilderTypeIsIgnored`), `Tests/WireGenCoreTests/MultibindingFanInTests.swift` (`builderAggregateUsesResultBuilderResultType`, `builderWithoutDiscoveredResultBuilderIsSkipped`, `emptyBuilderProducesNoAggregate`).

### Requirement: A builder aggregate is a `@<Builder>` fold function
The generated graph SHALL construct a `BuilderKey` aggregate as a local function annotated
`@<Builder>`, named `_wireFold` followed by the upper-camel-cased sanitised key reference, taking no
parameters, returning the builder's result type and listing the contributor locals in contributor
order, followed by a `let` binding the aggregate local to its call. The result type SHALL be the
written type, so the fold produces a concrete or existential result and not an opaque one; the
parameterised-opaque fold is tracked by https://github.com/swift-wire/swift-wire/issues/356.

#### Scenario: the emitted fold
- **WHEN** `Keys.routes` is a builder key over `[any Route]` with contributor `AlphaRoute`
- **THEN** the graph contains `func _wireFoldKeysRoutes() -> [any Route] {`

#### Scenario: a ranked middleware pipeline
- **WHEN** `AuthMiddleware` (`withOrder: 1`) and `LoggingMiddleware` (`withOrder: 2`) contribute to `BuilderKey<PipelineBuilder>`, `BuilderKey<MiddlewareListBuilder>` and `BuilderKey<ComposedMiddlewareBuilder>`
- **THEN** `pipeline.steps` is `["auth", "log"]`, `list.map(\.step)` is `["auth", "log"]` and `composed.step` is `"auth>log"`

Pinned by: `Tests/WireGenCoreTests/ConstructionSchedulingTests.swift` (`aBuilderFoldInThePrefixDoesNotBlockScheduling`), `Tests/IntegrationTests/BootstrapTests.swift` (`builderMultibindingFoldsToConcreteResultInRankOrder`, `builderMultibindingFoldsToCollectionResult`, `builderMultibindingFoldsToExistentialResult`).

### Requirement: An unconsumed key warns
WireGen SHALL warn at the declaration of an `internal` or `package` key without `allowUnused: true`
that no `@Inject` in any partition and no graph conformance consumes, reading
`multibinding key '<reference>' has no consumer — nothing @Injects it. Inject it somewhere, raise the key to 'public', or declare it 'allowUnused: true'.`
A `public` or `open` key SHALL NOT warn.

#### Scenario: a dead internal key
- **WHEN** an internal `App.services` key is declared and nothing injects it
- **THEN** the warning above is reported at the key declaration

#### Scenario: a public key in an extension
- **WHEN** `extension App { public static let services = CollectedKey<any Service>() }` extends `public enum App` and nothing injects the key
- **THEN** no warning is reported

Pinned by: `Tests/WireGenCoreTests/MultibindingValidationTests.swift` (`deadKeyWarns`, `liveMultibindingIsSilent`, `publicKeyInExtensionIsSilent`, `internalKeyInExtensionStillWarns`, `allowUnusedKeyIsSilent`, `keyConsumedByGraphConformanceIsSilent`).

### Requirement: A consumed key with no contributors warns
WireGen SHALL warn at the declaration of an `internal` or `package` key without `allowUnused: true`
that is consumed in some partition with no contributors to it there, reading
`multibinding key '<reference>' is consumed but has no @Contributes contributors — the consumer receives an empty collection. Add a contributor, or declare the key 'allowUnused: true'.`

#### Scenario: an empty consumed key
- **WHEN** a consumer injects an internal `App.services` and nothing contributes to it
- **THEN** the warning above is reported at the key declaration

#### Scenario: consumed and contributed in two containers
- **WHEN** a key is consumed in two containers and each container contributes to it
- **THEN** no warning is reported

Pinned by: `Tests/WireGenCoreTests/MultibindingValidationTests.swift` (`emptyMultibindingWarns`, `publicEmptyKeyIsSilent`, `keyConsumedInTwoContainersEachContributedIsLive`).

## Related specifications

- [factory-templates](../factory-templates/spec.md)
- [binding-identity-and-keys](../binding-identity-and-keys/spec.md)
- [binding-lifetimes](../binding-lifetimes/spec.md)
- [seeded-scopes](../seeded-scopes/spec.md)
- [containers](../containers/spec.md)
- [visibility-and-access](../visibility-and-access/spec.md)
- [reachability-and-retention](../reachability-and-retention/spec.md)
- [graph-conformance](../graph-conformance/spec.md)
- [adapter-annotations](../adapter-annotations/spec.md)
- [construction-scheduling](../construction-scheduling/spec.md)
