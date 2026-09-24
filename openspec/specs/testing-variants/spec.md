# Testing variants

## Purpose

A testing variant is a second graph WireGen emits for a test target, selected by a `TestingKey`
and differing from the production graph only in the slots its `@BindType` markers substitute with
test-supplied doubles. This spec covers the `WireTesting` vocabulary (`TestingKey`, `@BindType`),
the `@TestScopable` marker in `Wire`, the generated names a test calls, the `--testing-variants`
gate and its errors, the cascade and seedless reconstruction rules, and how a variant is derived
from the production graph.

Rationale: [TestingModel](../../../Documentation/Notes/TestingModel.md).
Documentation: [TestingAGraph](../../../Sources/Wire/Wire.docc/TestingAGraph.md).

## Requirements

### Requirement: A `TestingKey` is identified by its declaration
At code-generation time a `TestingKey` SHALL be identified by the canonical text of its declaring
reference (`MyTests.testSetup`). At runtime `TestingKey()` SHALL capture `#fileID` and `#line` of
the `TestingKey()` call expression through defaulted `init(fileID:line:)` parameters, SHALL be
`Hashable` and `Sendable`, and SHALL compare equal only to a key with the same captured location.

#### Scenario: two declarations
- **WHEN** an enum declares `static let first = TestingKey()` and `static let second = TestingKey()` on separate lines
- **THEN** `Keys.first != Keys.second` and `Keys.first == Keys.first`

#### Scenario: an explicitly reconstructed key
- **WHEN** `TestingKey(fileID: #fileID, line: 17)` is constructed in the file where line 17 holds `Keys.first`'s `TestingKey()` call
- **THEN** it equals `Keys.first`

#### Scenario: a declaration split across lines
- **WHEN** `static let split =` is on one line and `TestingKey()` on the next
- **THEN** the key equals the reconstruction at the `TestingKey()` line, not the `static let` line

Pinned by: `Tests/WireTests/TestingKeyTests.swift` (`distinctDeclarationsAreDistinct`, `theSameDeclarationIsStable`, `anExplicitlyReconstructedKeyMatchesItsDeclaration`, `theLineIsTheInitCallNotTheDeclaration`, `keysAreUsableAsDictionaryKeys`), `Tests/WireGenCoreTests/BindTypeDiscoveryTests.swift` (`testingKeyFromInitialiserCapturesReferenceAndSubstitution`).

### Requirement: `@BindType` markers on a `TestingKey` are discovered syntactically
WireGen SHALL recognise a `TestingKey` as a `let` or `static let` initialised with `TestingKey()`
or annotated `: TestingKey`, and SHALL read every stacked `@BindType` attribute on it in source
order, each as either the type form `@BindType(Slot.self, Mock.self)` or the keyed form
`@BindType(Slot.key, Mock.self)`. `@BindType` and `@TestScopable` SHALL expand to no code.

#### Scenario: the initialiser form
- **WHEN** `enum MyTests { @BindType(BackendRepository.self, MockBackendRepository.self) static let testSetup = TestingKey() }`
- **THEN** discovery yields key reference `MyTests.testSetup` with one substitution of slot type `BackendRepository` to mock `MockBackendRepository`

#### Scenario: the keyed form
- **WHEN** a key carries `@BindType(Repo.primary, MockRepo.self)`
- **THEN** the substitution has slot key `Repo.primary`, no slot type, and mock `MockRepo`

#### Scenario: stacked markers
- **WHEN** a key carries two `@BindType` attributes
- **THEN** both substitutions are captured in attribute order

Pinned by: `Tests/WireGenCoreTests/BindTypeDiscoveryTests.swift` (`testingKeyFromInitialiserCapturesReferenceAndSubstitution`, `testingKeyFromExplicitAnnotationIsRecognised`, `stackedBindTypesAllCaptured`, `keyedBindTypeReadsKeyReference`, `nonTestingKeyDeclarationIsIgnored`). The empty macro expansions are pinned by nothing yet.

### Requirement: A substituted slot becomes a doubles-sourced provider
For each substitution matching a binding, WireGen SHALL replace the binding with a property-form
provider of the same identity and scope whose access path is `doubles.<field>` and whose
dependencies are empty, and SHALL record a doubles field named from the slot identity, with any
`some ` or `any ` prefix stripped, typed to the mock.

#### Scenario: a concrete slot inside a seed scope
- **WHEN** `BackendRepository` is a `@Scoped(seed: RequestSeed.self)` provider and the key binds it to `MockBackendRepository`
- **THEN** the binding becomes a provider with access path `doubles.backendRepository`, scope `RequestSeed`, no dependencies, and the doubles field is `backendRepository: MockBackendRepository`

#### Scenario: an opaque slot
- **WHEN** the slot is bound as `some BackendRepository`
- **THEN** the doubles-sourced binding keeps identity `some BackendRepository` and the field is named `backendRepository`

#### Scenario: a keyed slot
- **WHEN** the substitution is `@BindType(Repo.primary, MockRepo.self)` and a provider carries key `Repo.primary`
- **THEN** that provider, and only it, is rewritten

Pinned by: `Tests/WireGenCoreTests/TestingGraphTests.swift` (`substitutionMakesSlotDoublesSourcedAndMockTyped`, `opaqueSlotKeepsIdentityFieldStripsSomePrefix`, `keyedSubstitutionMatchesByKey`).

### Requirement: The doubles struct is memberwise over every substituted slot
For a key `Enum.key` WireGen SHALL emit `internal struct _Enum_keyDoubles: Sendable` with one `let`
per doubles field and a memberwise `init` taking every field, so a missing double is a compile
error. For each routed subject the variant covers it SHALL also emit
`_Enum_key_<Subject>Doubles` carrying only the fields that subject reaches, with an argumentless
`init` when it reaches none.

#### Scenario: the key-wide struct
- **WHEN** `MyTests.testSetup` substitutes `backendRepository` and `clock`
- **THEN** the file contains `internal struct _MyTests_testSetupDoubles: Sendable {`, `let backendRepository: MockBackendRepository`, `let clock: FakeClock` and `init(backendRepository: MockBackendRepository, clock: FakeClock)`

#### Scenario: sibling subjects on one seed
- **WHEN** `SubjectDoublesFixture.bindBoth` mocks `SubjectAlphaBackend` and `SubjectBetaBackend` and three `@Scoped(seed: SubjectSeed.self)` controllers consume alpha, beta and neither
- **THEN** `_SubjectDoublesFixture_bindBoth_SubjectAlphaControllerDoubles(subjectAlphaBackend:)`, `_SubjectDoublesFixture_bindBoth_SubjectBetaControllerDoubles(subjectBetaBackend:)` and `_SubjectDoublesFixture_bindBoth_SubjectPlainControllerDoubles()` are each generated, and the key-wide `_SubjectDoublesFixture_bindBothDoubles` still takes both

Pinned by: `Tests/WireGenCoreTests/TestingGraphTests.swift` (`doublesStructTypeNameJoinsReferenceComponents`, `renderDoublesStructEmitsPackageFieldsAndInit`), `Tests/IntegrationTests/SubjectDoublesTests.swift` (`subjectDoublesCarryOnlyTheSlotsTheSubjectReaches`, `siblingSubjectsOnOneSeedGetDisjointDoubles`, `subjectReachingNoMockEntersScopeWithNoDoubles`, `keyWideDoublesStillCarriesEverySlot`).

### Requirement: Each key emits a variant app graph without the mocked bindings
For a key `Enum.key` WireGen SHALL emit `_Enum_keyWireGraph` with `Wire.bootstrapEnum_key()`, whose
order is the production default order minus the mocked and lifted bindings, every bridging
contributor proxy, and any production factory a variant factory replaces; a surviving aggregate
SHALL list only the contributors that survive. A mocked eager binding's initialiser SHALL NOT run
under the variant bootstrap.

#### Scenario: a mocked eager provider
- **WHEN** `EagerFixture.bindMock` mocks `any EagerWidget`, whose production provider counts its initialisations
- **THEN** `Wire.bootstrapEagerFixture_bindMock()` records zero initialisations and its `introspect()` omits `any EagerWidget`, while `Wire.bootstrap()` records one and includes it

#### Scenario: an aggregate with a dropped contributor
- **WHEN** an aggregate lists a contributor the variant drops
- **THEN** the variant's aggregate keeps the surviving contributors only, and an aggregate with nothing dropped is unchanged

Pinned by: `Tests/IntegrationTests/EagerSingletonBindTypeTests.swift` (`eagerBindTypedBindingIsDroppedFromTheVariantAppGraph`), `Tests/IntegrationTests/BindTypeProxyContributorTests.swift` (`eagerSingletonInitDoesNotRunUnderTheVariantGraph`), `Tests/WireGenCoreTests/TestingGraphTests.swift` (`variantAggregateShedsDroppedContributorsAndKeepsSurvivors`, `variantAggregateRewriteIsANoOpWhenNothingDropped`).

### Requirement: A variant seed scope is entered through a doubles-taking facade
For each seed scope a key's substitutions or lifts touch, WireGen SHALL emit
`_Enum_key_<Seed>WireScope` and `Wire.bootstrapEnum_key_<Seed>Scope(seed:wireGraph:doubles:)`,
where `wireGraph:` is typed to the variant app graph and `doubles:` to `_Enum_keyDoubles`; the
scope's thunk SHALL construct each doubles-sourced binding as `let <field> = doubles.<field>`.

#### Scenario: a direct substitution inside the scope
- **WHEN** `WireDoublesFixture.bindMockRepo` mocks `any TodoRepository` consumed by a `@Scoped(seed: TodoRequestSeed.self)` controller
- **THEN** `Wire.bootstrapWireDoublesFixture_bindMockRepo_TodoRequestSeedScope(seed:wireGraph:doubles:)` returns a scope whose `todoController` calls the supplied `MockTodoRepository` instance

#### Scenario: a generic seed subject over an opaque mocked backend
- **WHEN** `GenSeedFixture.bindMock` mocks `GenBackend` for a generic `@Scoped(seed:)` consumer
- **THEN** `Wire.bootstrapGenSeedFixture_bindMock_GenSeedRequestSeedScope(seed:wireGraph:doubles:)` yields `genSeedConsumerOfSomeGenBackend` reading the mock

Pinned by: `Tests/IntegrationTests/BindTypeDoublesTests.swift` (`suppliedMockInstanceFlowsThroughScopeEntry`), `Tests/IntegrationTests/GenericSeedFacadeBindTypeTests.swift` (`genericSeedSubjectConcretizesToMockOverTheVariantGraph`), `Tests/WireGenCoreTests/BindTypeSeedScopeTests.swift` (`scopeEntryThunkThreadsDoublesAndSourcesBindType`, `discoveredControllerBindsMockThroughVariantGraph`), `GoldenHarness/Golden/_WireGraph.swift.golden`.

### Requirement: A routed subject is entered through a per-subject contributor facade
For each production bridging contributor proxy whose seed scope the variant touches, WireGen SHALL
emit a variant proxy and `Wire.bootstrapEnum_key_<Subject>Contributor(wireGraph:)` returning it;
the proxy's `_wireEnterScope(seed, doubles)` SHALL take the per-subject doubles and return the same
entry struct as production, including its teardown.

#### Scenario: a `@Scoped(seed:)` route controller
- **WHEN** `WireProxyFixture.bindMock` mocks `any ProxyRepository` reached by `ProxyRouteController`
- **THEN** `Wire.bootstrapWireProxyFixture_bindMock_ProxyRouteControllerContributor(wireGraph:)._wireEnterScope(ProxyRequestSeed(id: "req-1"), doubles)` yields a subject whose `tag()` reads the mock, and its teardown records on the same mock

Pinned by: `Tests/IntegrationTests/BindTypeProxyContributorTests.swift` (`variantProxyEntersScopeWithDoubles`), `Tests/IntegrationTests/SubjectDoublesTests.swift` (`subjectDoublesCarryOnlyTheSlotsTheSubjectReaches`). Mock-consumption detection through more than one hop is https://github.com/swift-wire/swift-wire/issues/331; several factories on one proxy is https://github.com/swift-wire/swift-wire/issues/332; the keyed-slot mock-consuming factory is https://github.com/swift-wire/swift-wire/issues/329; the box-role variant factory is https://github.com/swift-wire/swift-wire/issues/333.

### Requirement: Variants are emitted only under `--testing-variants`
When the run did not receive `--testing-variants`, `WireGen` SHALL fail with one error per distinct
key the consumer declares, at the key's location, with the message
`'<key>' declares a test-graph variant, but this WireGen run did not opt into them (--testing-variants was not passed). Variants substitute @BindType doubles into the graph, so they are emitted only for a test target — otherwise the variant graph and the mock types it names compile into the shipping binary. If '<module>' is a production target, move the TestingKey into a test target; if it is already a test target, its build plugin is not passing --testing-variants.`

#### Scenario: a key without the flag
- **WHEN** `ProdFixture.bindMock` is declared in the consumer and the flag is absent
- **THEN** the error names `'ProdFixture.bindMock'`, `--testing-variants`, `If '<module>' is a production target` and `its build plugin is not passing`

Pinned by: `Tests/WireGenCoreTests/BindTypeDiscoveryTests.swift` (`keyWithoutOptInNamesTheFlagAndBothExplanations`).

### Requirement: A key from a dependency module is refused
Whether or not `--testing-variants` was passed, `WireGen` SHALL fail with one error per distinct
key whose origin module is not the consumer, with the message
`'<key>' declares a test-graph variant but is composed into '<consumer>' from module '<origin>'. Only the target that declares a TestingKey emits its variant graph, so this key cannot take effect here — and a Wire-aware library's key reaches every consumer that re-parses it, production ones included. Move the TestingKey out of '<origin>' and into the test target that uses it.`

#### Scenario: a library key
- **WHEN** `LibFixture.bindMock` is discovered in module `SharedLib` while the consumer is `App`
- **THEN** the error contains `composed into 'App' from module 'SharedLib'` and `Move the TestingKey out of 'SharedLib'`

Pinned by: `Tests/WireGenCoreTests/BindTypeDiscoveryTests.swift` (`foreignKeyNamesTheOriginModule`).

### Requirement: A `@BindType` slot nothing produces is an error
For each substitution matching no binding across the production app singletons and every seed
scope, `WireGen` SHALL emit an error at the attribute with the message
`@BindType(<slot>, <Mock>.self) substitutes a slot no binding under test produces — check the slot type or key.`

#### Scenario: a mistyped slot
- **WHEN** a key carries `@BindType(NotBound.self, MockNotBound.self)` and no binding produces `NotBound`
- **THEN** the error reads `@BindType(NotBound, MockNotBound.self) substitutes a slot no binding under test produces — check the slot type or key.`

Pinned by: `Tests/WireGenCoreTests/TestingGraphTests.swift` (`unmatchedSubstitutionIsReported`), `Tests/WireGenCoreTests/ScopableCascadeTests.swift` (`unmatchedSubstitutionIsDiagnosed`).

### Requirement: The `@TestScopable` cascade lifts app-scoped hops into the scope
When a mocked app-scoped binding reaches a seed scope's roots through app-scoped consumers,
WireGen SHALL lift the mocked leaf and every app singleton on the path into the scope, constructing
them per entry rather than borrowing them. Each intermediate hop SHALL carry `@TestScopable` on its
type declaration; an unmarked hop SHALL fail the run with
`<Slot> is bound per-scope-entry under test, but reaches the scope root through singleton '<Hop>'. Mark <Hop> with @TestScopable to allow it to be lifted into the scope under test.`
at the `@BindType` attribute.

#### Scenario: a marked hop
- **WHEN** `AccountController` is `@TestScopable @Singleton`, reads `any AccountRepository` in `init`, and a seed root injects it
- **THEN** both `AccountController` and the repository are lifted, no diagnostic is raised, and `AccountController` is scope-bound rather than borrowed

#### Scenario: an unmarked hop
- **WHEN** the same `AccountController` is not marked
- **THEN** the error reads `AccountRepository is bound per-scope-entry under test, but reaches the scope root through singleton 'AccountController'. Mark AccountController with @TestScopable to allow it to be lifted into the scope under test.`

#### Scenario: an unreached singleton
- **WHEN** an app singleton neither reaches the mock nor is reached from the seed's roots
- **THEN** it is not lifted

Pinned by: `Tests/WireGenCoreTests/ScopableCascadeTests.swift` (`testScopableMarkersDiscoveredOnTypeDeclarations`, `typeWithoutTestScopableIsNotMarked`, `cascadeLiftsMockedLeafAndMarkedHop`, `unreachableSingletonIsNotLifted`, `unmarkedHopFiresGuidedDiagnostic`, `markingHopClearsTheDiagnostic`, `liftedSingletonIsScopeBoundNotBorrowed`).

### Requirement: Lifted hops leave the variant app graph and are rebuilt per entry
A lifted singleton SHALL be absent from the variant app graph and reconstructed inside the variant
seed scope on each entry, so a read of the mocked slot in its `init` sees the double.

#### Scenario: an init-time read
- **WHEN** `WireScopableFixture.bindMockRepo` mocks `any AccountRepository` and `AccountController` reads `repository.tag("init")` in `init`
- **THEN** `Wire.bootstrapWireScopableFixture_bindMockRepo().introspect()` lists neither `AccountController` nor `any AccountRepository`, `Wire.bootstrap().introspect()` lists both, and the variant scope's `accountController.tag` is `"mock:init"`

Pinned by: `Tests/IntegrationTests/ScopableCascadeTests.swift` (`liftedSingletonReadsDoubleAtInit`).

### Requirement: An app-scoped route contributor is reconstructed seedlessly
For each hold proxy whose `@Singleton` subject is `@TestScopable` and transitively consumes a
mocked slot, WireGen SHALL drop the subject, its hold proxy and the mock-consuming hops from the
variant app graph and emit `Wire.bootstrapEnum_key_<Subject>Contributor(wireGraph:)` returning a
proxy whose `_wireEnterScope(doubles)` rebuilds the subject from the doubles alone. An unmarked
subject SHALL fail the run with
`<Subject> is an app-scoped route contributor that consumes '<Slot>', which is bound per-request under test — so it can't be constructed under the mock. Mark <Subject> with @TestScopable to rebuild it per request so it sees the double.`

#### Scenario: a marked app-scoped controller with a lifted factory
- **WHEN** `AppScopedFixture.bindMock` mocks `any AppScopedRepository` and `AppScopedController` is `@TestScopable @Singleton @RouteController` with a mock-consuming `@RouteMiddleware` factory
- **THEN** `Wire.bootstrapAppScopedFixture_bindMock_AppScopedControllerContributor(wireGraph:)._wireEnterScope(doubles)` yields a subject and a factory product both reading the mock

#### Scenario: a generic app-scoped controller
- **WHEN** `GenAppController<Backend>` is bound over `some GenAppBackend` and the key mocks `GenAppBackend`
- **THEN** the seedless facade concretises the subject to `GenAppController<MockGenAppBackend>`

#### Scenario: an unmarked subject
- **WHEN** `TodosController` consumes mocked `TodoRepository` and is not `@TestScopable`
- **THEN** the error contains `TodosController is an app-scoped route contributor`, `consumes 'TodoRepository'` and `Mark TodosController with @TestScopable`

Pinned by: `Tests/IntegrationTests/ScopableRouteContributorTests.swift` (`appScopedRouteContributorRebuildsSeedlesslyWithTheMock`, `genericAppScopedRouteContributorConcretizesToTheMock`), `Tests/WireGenCoreTests/ScopableCascadeTests.swift` (`unmarkedSeedlessRootFiresGuidedDiagnostic`).

### Requirement: The production graph is untouched
`Wire.bootstrap()`, every production `@Container` graph and every production seed facade SHALL be
emitted exactly as they are without the key, and SHALL never read a doubles value.

#### Scenario: the keyless graph beside a variant
- **WHEN** `EagerFixture.bindMock` mocks `any EagerWidget`
- **THEN** `Wire.bootstrapEagerRequestSeedScope(seed:wireGraph:)` still exists without a `doubles:` parameter and its consumer reads the real widget

Pinned by: `Tests/IntegrationTests/EagerSingletonBindTypeTests.swift` (`eagerBindTypedBindingIsDroppedFromTheVariantAppGraph`), `Tests/IntegrationTests/ReplacesBindTypeComposeTests.swift` (`replacesAndBindTypeComposeWithCorrectPrecedence`). The byte-identical-output claim for a module with no key is pinned by nothing yet.

### Requirement: Variants derive from the `@Replaces`-resolved production set
Before substituting, WireGen SHALL resolve `@Replaces` over each partition exactly as the
production graphs do, so a `@BindType` supersedes the `@Replaces` fake rather than a raw pair, and
the precedence per slot is the real binding, then `@Replaces` in every graph, then `@BindType` in
its keyed variant only.

#### Scenario: a replaced slot that is also mocked
- **WHEN** a library's `ComposeWidget` is superseded by the target's `@Replaces` fake and `ComposeFixture.bindMock` mocks `ComposeWidget`
- **THEN** the production scope's consumer reads `"fake"`, the variant scope's consumer reads `"mock"`, and the library's real widget is never constructed

Pinned by: `Tests/IntegrationTests/ReplacesBindTypeComposeTests.swift` (`replacesAndBindTypeComposeWithCorrectPrecedence`).

### Requirement: Variants derive from the production retained set
A variant SHALL borrow and derive only from bindings the production default graph retained, so a
dependency-module binding reachability pruned from production is never referenced as
`_wireGraph.<property>` by generated test code.

#### Scenario: a pruned library binding
- **WHEN** a library binding is unreachable in the production graph and a key is declared
- **THEN** no variant scope or facade borrows it

Pinned by: nothing yet.

### Requirement: `@Replaces` is the whole-target alternative
`@Replaces` SHALL substitute a binding by type in every graph of the target that declares it, with
Wire constructing the replacement; `@BindType` SHALL substitute a slot in one key's variant only,
with the test supplying the instance.

#### Scenario: choosing by granularity
- **WHEN** a test target needs one stateless fake with no handle on the instance
- **THEN** `@Replaces` on the fake suffices and no `TestingKey` is declared

Pinned by: `Tests/WireGenCoreTests/ReplacesTests.swift` (`providesReplacesSupersedesConcreteSingleton`, `homeModuleReplacesIsHonoured`), `Tests/IntegrationTests/ReplacesBindTypeComposeTests.swift` (`replacesAndBindTypeComposeWithCorrectPrecedence`). One `TestingKey` per target as served by an adapter is https://github.com/swift-wire/swift-wire/issues/336.

## Related specifications

- [seeded-scopes](../seeded-scopes/spec.md)
- [scope-entry-and-generated-names](../scope-entry-and-generated-names/spec.md)
- [binding-lifetimes](../binding-lifetimes/spec.md)
- [binding-identity-and-keys](../binding-identity-and-keys/spec.md)
- [reachability-and-retention](../reachability-and-retention/spec.md)
- [multi-module-composition](../multi-module-composition/spec.md)
- [graph-conformance](../graph-conformance/spec.md)
- [build-plugin-and-wiregen-cli](../build-plugin-and-wiregen-cli/spec.md)
- [wire-mvc testing-harness](https://github.com/swift-wire/wire-mvc/blob/main/openspec/specs/testing-harness/spec.md)
