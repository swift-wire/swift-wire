# Scope entry and generated names

## Purpose

An adapter's own code generator (wire-mvc's route emitter, wire-open-api's dispatch emitter) reads
and extends the types WireGen emits without ever seeing WireGen's output, so both sides derive the
same names from the same inputs. This spec states the SPI-tier naming contract: the `WireScopeEntry`
protocol and the synthesised `_WireScopeEntry_<Subject>` struct, the fields of a contributor proxy,
the scope-entry thunk's signature, synthesised factory types, the `Wire` facade's entry points,
graph and scope struct names, stored-property naming, the identifier sanitiser, and
`_WireBindingState`. The capabilities that cause these to be emitted are specified in
[adapter-annotations](../adapter-annotations/spec.md).

Rationale: [AdapterModel](../../../Documentation/Notes/AdapterModel.md), [TestingModel](../../../Documentation/Notes/TestingModel.md), [ConstructionScheduling](../../../Documentation/Notes/ConstructionScheduling.md).
Documentation: [WritingAnAdapter](../../../Sources/Wire/Wire.docc/WritingAnAdapter.md).

## Requirements

### Requirement: `WireScopeEntry` requires only the subject
The `Wire` module SHALL export `public protocol WireScopeEntry: Sendable` with exactly two
requirements: `associatedtype Subject` and `var _wireSubject: Subject { get }`. The protocol SHALL
carry no function-typed requirement; the teardown is read off the concrete entry struct, not the
protocol.

#### Scenario: recovering a subject's type from a thunk
- **WHEN** an adapter declares `func noSubject<Seed, Entry: WireScopeEntry>(_ thunk: @Sendable (Seed) async throws -> Entry) -> Entry.Subject? { nil }` and passes a bridged proxy's `_wireEnterScope`
- **THEN** `Entry.Subject` resolves to the concrete subject type without the adapter spelling it, including for a subject over an opaque backend

Pinned by: `Tests/IntegrationTests/ScopeEntryProjectionTests.swift` (`aSubjectsTypeIsRecoverableFromItsThunk`).

### Requirement: Every target is compiled with `NonisolatedNonsendingByDefault`
`Package.swift` SHALL apply `.enableUpcomingFeature("NonisolatedNonsendingByDefault")` to every
Swift target in the package.

#### Scenario: an adapter that enables the feature conforms a generated entry
- **WHEN** a consumer module with `NonisolatedNonsendingByDefault` enabled compiles a `_WireScopeEntry_<Subject>` struct whose `_wireScopeTeardown` is `@Sendable () async -> [any Error]`
- **THEN** the struct's `WireScopeEntry` conformance compiles, since the protocol names no function type

Pinned by: nothing yet.

### Requirement: A bridged subject's entry is a synthesised `_WireScopeEntry_<Subject>` struct
For each bridged subject, WireGen SHALL emit
`struct _WireScopeEntry_<Subject><generic clause>: Sendable, WireScopeEntry<where clause>` into the
consumer module, generic exactly as the subject, with these stored properties in this order:
`let _wireSubject: <Subject>`, one `let <identifierName(yield)>: <Yield>` per scope yield in
sorted order, and `let _wireScopeTeardown: @Sendable () async -> [any Error]` last. The struct
SHALL have no explicit initialiser. Under a testing variant the struct SHALL be named
`_WireScopeEntry_<Variant>_<Subject>`. Each entry struct SHALL be emitted before the proxy that
returns it.

#### Scenario: a subject with two yields
- **WHEN** `DocumentsController` is bridged and yields `AuthorizedDocument` and `Caller`
- **THEN** WireGen emits `struct _WireScopeEntry_DocumentsController: Sendable, WireScopeEntry { let _wireSubject: DocumentsController; let authorizedDocument: AuthorizedDocument; let caller: Caller; let _wireScopeTeardown: @Sendable () async -> [any Error] }` with one property per line

#### Scenario: a generic subject
- **WHEN** `MeController<Repository: TodoRepository, Manager: SessionManager>` is bridged
- **THEN** the entry is `struct _WireScopeEntry_MeController<Repository: TodoRepository, Manager: SessionManager>: Sendable, WireScopeEntry` with `_wireSubject: MeController<Repository, Manager>`

#### Scenario: a variant's entry
- **WHEN** the `FactoryProxyFixture.bindMock` testing key touches the bridged `FactoryProxyRouteController`
- **THEN** the variant proxy's thunk returns `_WireScopeEntry_FactoryProxyFixture_bindMock_FactoryProxyRouteController`

Pinned by: `Tests/WireGenCoreTests/ScopeYieldTests.swift` (`theThunkReturnsANamedStructRatherThanATuple`, `yieldsAreNamedFieldsOnTheEntryStruct`, `theEntryStructIsGenericExactlyAsItsSubject`, `aVariantsEntryStructCannotCollideWithTheProductionOne`, `aYieldIsReturnedAlongsideTheSubjectAndBeforeTheTeardown`), `GoldenHarness/Golden/_WireGraph.swift.golden`.

### Requirement: The scope-entry thunk has a fixed signature
A bridging proxy's `_wireEnterScope` field SHALL have type
`@Sendable (<Seed>) async throws -> _WireScopeEntry_<Subject>` in production, and
`@Sendable (<Seed>, _<Variant>_<Subject>Doubles) async throws -> _WireScopeEntry_<Variant>_<Subject>`
on a testing-variant proxy. The proxy's initialiser SHALL take it as `@escaping`. Calling it
SHALL construct the subject and its reachable subgraph in the seed's scope and return the entry,
whose `_wireScopeTeardown` runs the scope's `@Teardown` bindings in reverse construction order and
collects errors rather than throwing.

#### Scenario: a production bridge
- **WHEN** `SessionController<Repository>` is `@Scoped(seed: RequestSeed.self)` under a `.singleton` proxy
- **THEN** the proxy declares `let _wireEnterScope: @Sendable (RequestSeed) async throws -> _WireScopeEntry_SessionController<Repository>` and `init(_wireEnterScope: @escaping @Sendable (RequestSeed) async throws -> _WireScopeEntry_SessionController<Repository>)`

#### Scenario: entering with doubles under a variant
- **WHEN** a test calls `proxy._wireEnterScope(GenProxyRequestSeed(id: "projection"), doubles)` on a variant proxy
- **THEN** the returned entry's `_wireSubject` is the subject built against the doubles and `await entered._wireScopeTeardown()` returns `[]`

Pinned by: `Tests/WireGenCoreTests/ContributorProxyEmissionTests.swift` (`emitsScopeEntryThunkFieldAndNoSubject`), `Tests/WireGenCoreTests/ScopeYieldTests.swift` (`theThunkReturnsANamedStructRatherThanATuple`), `Tests/WireGenCoreTests/SeedScopeEmissionTests.swift` (`scopeEntryThunkTearsDownScopedBindings`), `Tests/IntegrationTests/BindTypeProxyContributorTests.swift` (`variantProxyEntersScopeWithDoubles`), `Tests/IntegrationTests/FactoryProxyContributorTests.swift` (`factoryCarryingProxyEntersScopeWithDoubles`), `Tests/IntegrationTests/ScopeEntryProjectionTests.swift` (`aSubjectsTypeIsRecoverableFromItsThunk`).

### Requirement: A per-subject proxy's fields are named by a fixed contract
A contributor proxy SHALL store its held subject as `_wireSubject`, taken positionally by its
initialiser (`init(_ _wireSubject: …)`), or its bridged subject's thunk as `_wireEnterScope`,
taken by label. Each lifted factory SHALL be stored as `_wireFactory_<sanitised key>`, each
by-type adapter dependency as `_wire<Type>` (the simple type name with generics and namespace
stripped and its first letter upper-cased), and each keyed adapter dependency as
`_wire<sanitised key>`. Fields SHALL appear in dependency order, subject or thunk first, and each
labelled field's name SHALL be its initialiser label.

#### Scenario: a held subject with one factory
- **WHEN** `TodosController<Repository: TodoRepository>` is held and demands `Keys.backend`
- **THEN** the proxy declares `let _wireSubject: TodosController<Repository>`, `let _wireFactory_Keys_backend: _WireFactory_Keys_backend` and `init(_ _wireSubject: TodosController<Repository>, _wireFactory_Keys_backend: _WireFactory_Keys_backend)`

#### Scenario: a by-type and a keyed dependency
- **WHEN** a proxied controller is annotated `@Middleware(SessionMiddlewareFactory.self)` and `@Middleware(Gates.primary)`
- **THEN** the proxy's fields are `_wireSessionMiddlewareFactory` and `_wireGates_primary`

Pinned by: `Tests/WireGenCoreTests/ContributorProxyEmissionTests.swift` (`subjectFieldNameIsTheDocumentedContract`, `factoryFieldNameMatchesFactoryDependencyName`, `emitsFactoryFieldsAfterSubject`, `emitsFactoryFieldsAfterScopeEntryThunk`, `multipleFactoriesEmitInDependencyOrder`, `emittedInitMatchesGraphConstructionCall`), `Tests/WireGenCoreTests/AdapterDependencyTests.swift` (`injectsSynthesizedDependency`, `injectsKeyedDependencyForBindingKeyArgument`), `GoldenHarness/Golden/_WireGraph.swift.golden`.

### Requirement: An aggregate proxy's fields carry the subject name
An aggregate proxy over more than one subject SHALL store each held subject as
`_wireSubject_<Subject>` and each bridged subject's thunk as `_wireEnterScope_<Subject>`, all
taken by label. An aggregate over exactly one subject SHALL use `_wireSubject` (positional) or
`_wireEnterScope` (labelled), byte-identical to a per-subject proxy.

#### Scenario: two held and one bridged subject
- **WHEN** `_WireAggregateContributor_alpha` collates `AggregateReportController`, `AggregateSearchController<Backend>` and the bridged `AggregateTaskController`
- **THEN** its fields are `_wireSubject_AggregateReportController`, `_wireSubject_AggregateSearchController` and `_wireEnterScope_AggregateTaskController: @Sendable (AggregateRequestSeed) async throws -> _WireScopeEntry_AggregateTaskController`

#### Scenario: one subject
- **WHEN** `_WireAggregateContributor_beta` collates only `BetaOnlyController`
- **THEN** its field is `_wireSubject` and its initialiser is `init(_ _wireSubject: BetaOnlyController)`

Pinned by: `Tests/IntegrationTests/AggregateProxyContributorTests.swift` (`oneProxyHoldsEveryAnnotatedSubject`, `aBridgedSubjectIsBuiltPerRequestWhileHeldPeersAreShared`, `aOneSubjectAggregateKeepsTheSingularFieldName`), `GoldenHarness/Golden/_WireGraph.swift.golden`.

### Requirement: A proxy is emitted as an internal `Sendable` struct with a body hole
WireGen SHALL emit each proxy as `struct <Name><generic clause>: Sendable<where clause>` with no
access keyword whatever the subject's access level, containing only its stored fields and one
initialiser. It SHALL declare no adapter-protocol conformance and no witness method; the adapter's
generator supplies both in an `extension` in the same module. `.scopeCapture` dependencies SHALL
NOT appear as fields or initialiser parameters.

#### Scenario: a public subject
- **WHEN** the subject is `public`
- **THEN** the proxy declaration begins `struct ` and contains neither `public ` nor `package `

#### Scenario: a non-generic subject
- **WHEN** the subject is `HealthController`
- **THEN** WireGen emits `struct _WireRouteContributor_HealthController: Sendable { let _wireSubject: HealthController; init(_ _wireSubject: HealthController) { self._wireSubject = _wireSubject } }` with one member per line and nothing else

Pinned by: `Tests/WireGenCoreTests/ContributorProxyEmissionTests.swift` (`emitsGenericStructWithSubjectFieldAndInit`, `nonGenericProxyOmitsGenericClause`, `emitsNoWitnessNorAdapterConformance`, `proxyIsAlwaysInternalRegardlessOfSubjectAccess`, `restatesSubjectWhereClause`).

### Requirement: Proxy type names are derived from the annotation and the subject
A `.contributesProxy` or `.liftsPeersToProxy` proxy SHALL be named `<proxyTypePrefix><Subject>`,
where `<Subject>` is the subject's unqualified type name. An aggregate proxy SHALL be named
`<proxyTypeName>_<group>` with every character of the group outside letters and digits replaced
by `_`. A testing variant's proxy SHALL be named `_<Variant><ProductionProxyName>`.

#### Scenario: a variant proxy
- **WHEN** the `WireProxyFixture.bindMock` key touches the subject of `_WireRouteContributor_ProxyRouteController`
- **THEN** the variant proxy is `_WireProxyFixture_bindMock_WireRouteContributor_ProxyRouteController`

Pinned by: `Tests/WireGenCoreTests/ContributorProxySynthesisTests.swift` (`synthesisesGenericProxyBesideController`, `synthesisesNonGenericProxy`), `Tests/WireGenCoreTests/LiftsPeersToProxyTests.swift` (`synthesisesAddressableProxyContributingToNothing`), `Tests/IntegrationTests/AggregateProxyContributorTests.swift` (`aSecondGroupOnTheSameAnnotationGetsItsOwnProxy`), `GoldenHarness/Golden/_WireGraph.swift.golden`.

### Requirement: A synthesised factory is `_WireFactory_<key>` with a metatype-taking `create`
For each consumed factory key, WireGen SHALL emit `struct _WireFactory_<sanitised key><injected generics>: Sendable`
with no access keyword, whose stored properties are the template's `@Inject` dependencies, whose
initialiser takes them by name, and whose `func create<Assisted…>(_: A.Type, …) -> Produced<…><where clause>`
is generic over the template's assisted parameters (or the canonical roles, when a mapping is
visible), takes one metatype per generic parameter, restates the per-parameter constraints then
the template's own `where` requirements, and constructs the produced type. The key sanitiser SHALL
replace every character outside letters, digits and `_` with `_`. A factory generic over an
injected axis SHALL be spelled on a generic proxy with the proxy's own matching parameter.

#### Scenario: a template with a constrained assisted parameter
- **WHEN** `@Factory(MyMiddleware.session) struct SessionMiddleware<Ctx: RequestContext, Reader, Sender>` injects `store: SessionStore`
- **THEN** WireGen emits `struct _WireFactory_MyMiddleware_session: Sendable` holding `let store: SessionStore` with `func create<Ctx, Reader, Sender>(_: Ctx.Type, _: Reader.Type, _: Sender.Type) -> SessionMiddleware<Ctx, Reader, Sender> where Ctx: RequestContext`

#### Scenario: a factory over an injected backend on a generic proxy
- **WHEN** `_WireFactory_GenAppKeys_audit<Backend: GenAppBackend>` is lifted onto a proxy generic over `Backend: GenAppBackend`
- **THEN** the proxy's field is `let _wireFactory_GenAppKeys_audit: _WireFactory_GenAppKeys_audit<Backend>`

Pinned by: `Tests/WireGenCoreTests/FactorySynthesisTests.swift` (`rendersFactoryDeclarationWithAssistedCreateAndConstraint`, `rendersTemplateWhereClauseAfterParameterConstraints`, `rendersEveryConsumedFactoryInternalRegardlessOfOriginModule`, `rendersFactoryGenericOverInjectedAxisCreateOverAssisted`, `nonInjectedFactoryStaysNonGeneric`, `proxyFactoryFieldIsParameterisedByTheSharedBackend`), `GoldenHarness/Golden/_WireGraph.swift.golden`.

### Requirement: Graph structs are `_WireGraph` and `_<Name>WireGraph`
WireGen SHALL emit the default graph as `internal struct _WireGraph<lift clause>: Introspectable, Teardownable`,
each `@Container` graph as `_<Container>WireGraph`, and each testing-variant app graph as
`_<Variant>WireGraph`, with `<Variant>` being the testing key's reference components joined by
`_`. A graph that lifts opaque axes SHALL declare `<T0: P0, T1: P1, …>` in binding order and be
referenced from outside as `_WireGraph<some P0, some P1, …>`.

#### Scenario: a container beside the default graph
- **WHEN** a module declares `@Container enum TestContainer`
- **THEN** the file contains both `internal struct _WireGraph` and `internal struct _TestContainerWireGraph`

#### Scenario: a variant graph
- **WHEN** a test target declares the testing key `WireProxyFixture.bindMock`
- **THEN** the file contains `_WireProxyFixture_bindMockWireGraph`

Pinned by: `Tests/WireGenCoreTests/CodeEmissionTests.swift` (`singleContainerEmitsItsOwnStructAlongsideEmptyDefault`, `defaultAndContainerBothEmitSideBySide`, `multipleContainersAreEmittedInSortedOrder`, `opaqueBindingsLiftGenericParametersOntoWireGraph`), `Tests/IntegrationTests/BindTypeProxyContributorTests.swift` (`variantProxyEntersScopeWithDoubles`), `GoldenHarness/Golden/_WireGraph.swift.golden`.

### Requirement: Seed scope structs are `_<Seed>WireScope`
WireGen SHALL emit a seeded scope over the default graph as `internal struct _<Seed>WireScope`,
over a container as `_<Container>_<Seed>WireScope`, and under a testing variant as
`_<Variant>_<Seed>WireScope`, where `<Seed>` is the seed type expression passed through the
identifier sanitiser.

#### Scenario: a generic seed
- **WHEN** the seed is written `TenantSeed<String>`
- **THEN** the suffix is `TenantSeedOfString`

#### Scenario: a container scope
- **WHEN** `HBRequestSeed` scopes bindings inside `TestContainer`
- **THEN** the struct is `_TestContainer_HBRequestSeedWireScope`

Pinned by: `Tests/WireGenCoreTests/SeedScopeEmissionTests.swift` (`seedScopeWithOnlySeedAliasingProducesScopeStruct`, `seedScopeGenericSeedTypeProducesSanitisedSuffix`, `containerScopeEmissionTargetsContainerWireGraphAsParent`), `Tests/WireGenCoreTests/SeedScopeOrchestrationTests.swift` (`identifierSuffixSanitisesGenericSeedExpressions`), `GoldenHarness/Golden/_WireGraph.swift.golden`.

### Requirement: The `Wire` facade is an internal enum of static bootstrap methods
WireGen SHALL emit `internal enum Wire` as the last block of the generated file, always
containing `static func bootstrap() async throws -> _WireGraph<…>` (with an `inputs:` parameter
when the module declares `@GraphInputs`), plus `bootstrap<Container>()` per container and
`bootstrap<Variant>()` per testing variant, each delegating to a private `_wireBootstrap<Name>()`
free function.

#### Scenario: an empty module
- **WHEN** a module declares no bindings
- **THEN** the file still ends with `internal enum Wire { static func bootstrap() async throws -> _WireGraph { try await _wireBootstrap() } }`

#### Scenario: a container
- **WHEN** a module declares `@Container enum TestContainer`
- **THEN** the facade also has `static func bootstrapTestContainer()`

Pinned by: `Tests/WireGenCoreTests/CodeEmissionTests.swift` (`emptyGraphProducesBareBootstrap`, `singleNoDependencySingleton`, `singleContainerEmitsItsOwnStructAlongsideEmptyDefault`), `Tests/IntegrationTests/BootstrapTests.swift` (`bootstrapWiresFullDependencyChain`, `testContainerProducesWiredGraphFromOwnBindings`), `Tests/IntegrationTests/BindTypeProxyContributorTests.swift` (`variantProxyEntersScopeWithDoubles`).

### Requirement: A seed scope facade is `bootstrap<Seed>Scope(seed:<graph>:)`
For each seed scope no bridging proxy enters, WireGen SHALL emit
`static func bootstrap<Suffix>Scope(seed: <Seed>, <graph label>: <ParentGraph>) async throws -> _<Suffix>WireScope`
where `<graph label>` is the parent graph's struct name with leading underscores stripped and
passed through the stored-property rule (`wireGraph` for `_WireGraph`, `testContainerWireGraph`
for `_TestContainerWireGraph`), and the private bootstrap's internal name for it is the label
prefixed with `_`. A testing variant's scope facade SHALL add a trailing `doubles: _<Variant>Doubles`
parameter. A seed that a bridging proxy enters SHALL have no whole-scope facade.

#### Scenario: a default-graph seed scope
- **WHEN** `HBRequestSeed` seeds a scope over the default graph
- **THEN** the facade is `static func bootstrapHBRequestSeedScope(seed: HBRequestSeed, wireGraph: _WireGraph) async throws -> _HBRequestSeedWireScope`

#### Scenario: a container seed scope
- **WHEN** the same seed scopes `TestContainer`
- **THEN** the facade is `static func bootstrapTestContainer_HBRequestSeedScope(seed: HBRequestSeed, testContainerWireGraph: _TestContainerWireGraph) async throws` and the private function binds the graph as `_testContainerWireGraph`

#### Scenario: a variant seed scope
- **WHEN** the `ComposeFixture.bindMock` key substitutes a binding in the `ComposeRequestSeed` scope
- **THEN** the facade is `bootstrapComposeFixture_bindMock_ComposeRequestSeedScope(seed:wireGraph:doubles:)` taking `_ComposeFixture_bindMockDoubles`

Pinned by: `Tests/WireGenCoreTests/SeedScopeEmissionTests.swift` (`seedScopeWithOnlySeedAliasingProducesScopeStruct`, `containerScopeEmissionTargetsContainerWireGraphAsParent`), `Tests/IntegrationTests/EagerSingletonBindTypeTests.swift` (`eagerBindTypedBindingIsDroppedFromTheVariantAppGraph`), `Tests/IntegrationTests/GenericSeedFacadeBindTypeTests.swift` (`genericSeedSubjectConcretizesToMockOverTheVariantGraph`), `GoldenHarness/Golden/_WireGraph.swift.golden`. The omission of the facade for a proxy-entered seed is pinned by nothing yet.

### Requirement: A variant contributor facade is `bootstrap<Variant>_<Subject>Contributor(wireGraph:)`
For each bridging proxy whose subject a testing variant touches, WireGen SHALL emit
`static func bootstrap<Variant>_<Subject>Contributor(wireGraph _wireGraph: <ReusedGraph>) -> <VariantProxy>`
on the facade, neither `async` nor `throws`, that binds the borrowed singletons and lifted
factories as locals off `_wireGraph` outside the thunk and returns the variant proxy. The
per-subject doubles struct SHALL be `_<Variant>_<Subject>Doubles` and the key-wide one
`_<Variant>Doubles`.

#### Scenario: a routed controller under a key
- **WHEN** the `GenProxyFixture.bindMock` key touches `GenProxyRouteController`
- **THEN** `Wire.bootstrapGenProxyFixture_bindMock_GenProxyRouteControllerContributor(wireGraph:)` returns a proxy whose `_wireEnterScope` takes `_GenProxyFixture_bindMock_GenProxyRouteControllerDoubles`

Pinned by: `Tests/WireGenCoreTests/ContributorProxyFacadeEmissionTests.swift` (`facadeThreadsDoublesPrunesAndTearsDown`, `facadeBindsBorrowedSingletonsAsLocalsOutsideTheThunk`, `facadeBindsLiftedFactoryInstanceFromTheGraph`), `Tests/WireGenCoreTests/TestingGraphTests.swift` (`doublesStructTypeNameJoinsReferenceComponents`), `Tests/IntegrationTests/ScopeEntryProjectionTests.swift` (`aSubjectsTypeIsRecoverableFromItsThunk`), `Tests/IntegrationTests/SubjectDoublesTests.swift` (`subjectDoublesCarryOnlyTheSlotsTheSubjectReaches`), `GoldenHarness/Golden/_WireGraph.swift.golden`.

### Requirement: Stored properties and locals are named from the binding's identity
WireGen SHALL name every graph stored property, bootstrap local, scope-entry yield field and
construction argument by `identifierName(forType:key:)`: the sanitised bound type with its first
character lower-cased, and for a keyed binding that name followed by `Keyed` and the key's
sanitised components with each segment's first letter upper-cased. A leading `some` or `any`
qualifier SHALL be kept as the first segment.

#### Scenario: a plain type
- **WHEN** `DynamoDBTaskRepository` is bound
- **THEN** the property is `dynamoDBTaskRepository`

#### Scenario: a generic instantiation
- **WHEN** `Repository<TaskTable>` is bound
- **THEN** the property is `repositoryOfTaskTable`

#### Scenario: a dotted key
- **WHEN** `Database` is bound under the key `Module.shared.primary`
- **THEN** the property is `databaseKeyedModuleSharedPrimary`

#### Scenario: opaque and existential qualifiers
- **WHEN** `some TaskRepo` is bound and read by an `any Logger` consumer elsewhere
- **THEN** the properties are `someTaskRepo` and the alias local `anyLogger`

Pinned by: `Tests/IntegrationTests/BootstrapTests.swift` (`storedPropertiesAreNamedByLowerCamelCasedTypeName`), `Tests/WireGenCoreTests/CodeEmissionTests.swift` (`acronymsArePreservedInPropertyNames`, `genericInstantiationProducesOfSeparatedPropertyName`, `multipleGenericParametersUseAndSeparator`, `keyedProviderInGraphGetsKeyedAccessorName`, `keyedBindingWithDottedKeyCapitalizesEachSegment`, `keyedBindingWithBareKeyAppendsCapitalizedSuffix`, `opaqueBindingsLiftGenericParametersOntoWireGraph`, `existentialPromotionBindsOneAliasSharedByItsConsumers`).

### Requirement: The identifier sanitiser has four rules
`sanitizeIdentifier` SHALL map `<` to `Of` and `,` to `And`, upper-casing the next character after
either; keep letters, digits and `_` unchanged; and drop every other character (whitespace, `>`,
`?`, `!`, `[`, `]`, `&`, `:`, `.`, `(`, `)`, `-`). The key sanitiser SHALL drop `.` and
upper-case the character after it, and drop every other non-identifier character.

#### Scenario: two generic arguments
- **WHEN** `Pair<Left, Right>` is sanitised
- **THEN** the result is `PairOfLeftAndRight`

#### Scenario: an opaque argument
- **WHEN** `Controller<some TaskRepo>` is sanitised
- **THEN** the result is `ControllerOfSomeTaskRepo`

Pinned by: `Tests/WireGenCoreTests/CodeEmissionTests.swift` (`genericInstantiationProducesOfSeparatedPropertyName`, `multipleGenericParametersUseAndSeparator`, `keyedBindingWithDottedKeyCapitalizesEachSegment`, `structuralLiftNodeReusesBridgeTargetParameterAsNestedField`), `Tests/WireGenCoreTests/SeedScopeOrchestrationTests.swift` (`identifierSuffixSanitisesGenericSeedExpressions`).

### Requirement: `_WireBindingState` is the public per-binding construction cell
The `Wire` module SHALL export `public enum _WireBindingState<Value: ~Copyable>: ~Copyable` with
cases `unmarked`, `pending`, `resolved(Value)` and `consumed`, the borrowing reads `isUnmarked()`
and `isResolved()`, the mutating `asPending()` returning whether the caller claimed the cell,
`asResolved(_:)`, `take()` which moves the payload out and leaves the cell `consumed`, and, for
`Copyable` payloads only, the borrowing `value()` returning the payload or `nil`.

#### Scenario: claiming a cell twice
- **WHEN** `asPending()` is called on a fresh cell and then again
- **THEN** the first call returns `true` and the second `false`

#### Scenario: taking a resolved cell
- **WHEN** `take()` is called on a cell holding a class instance
- **THEN** the same reference is returned and the cell is no longer resolved

Pinned by: `Tests/WireTests/BindingStateTests.swift` (`aFreshCellIsUnmarkedAndNotResolved`, `onlyTheFirstClaimantConstructs`, `aResolvedCellCannotBeClaimedAgain`, `valueReadsWithoutDisturbingTheCell`, `valueIsNilBeforeResolution`, `takeMovesThePayloadOutAndConsumesTheCell`, `takeHandsBackTheSameReferenceRatherThanACopy`, `aCellCarriesANoncopyablePayload`).

## Related specifications

- [adapter-annotations](../adapter-annotations/spec.md)
- [binding-identity-and-keys](../binding-identity-and-keys/spec.md)
- [seeded-scopes](../seeded-scopes/spec.md)
- [factory-templates](../factory-templates/spec.md)
- [testing-variants](../testing-variants/spec.md)
- [teardown](../teardown/spec.md)
- [binding-lifetimes](../binding-lifetimes/spec.md)
- [injection-points](../injection-points/spec.md)
- [graph-conformance](../graph-conformance/spec.md)
- [build-plugin-and-wiregen-cli](../build-plugin-and-wiregen-cli/spec.md)
- [wire-mvc route-builder-contract](https://github.com/swift-wire/wire-mvc/blob/main/openspec/specs/route-builder-contract/spec.md)
- [wire-open-api controller-collation](https://github.com/swift-wire/wire-open-api/blob/main/openspec/specs/controller-collation/spec.md)
