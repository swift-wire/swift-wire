# Opaque type identity

## Purpose

How a binding takes part in the graph under an abstract identity without Wire resolving
conformances. `some P` is a nominal identity: a `@Provides` returning `some P`, or a type declared
`@Singleton(as: P.self)`, produces it. A generic `@Singleton` whose parameters are all constrained
and reached through its dependencies is a lift node, bridged to the `some P` bindings its parameters
name and never specialised. An `any P` consumer borrows a `some P` producer through one existential
alias, and every bare `some P` binding lifts a generic parameter onto the generated graph struct.

Rationale: [OpaqueTypesSupport](../../../Documentation/Notes/OpaqueTypesSupport.md), [OpaqueTypesInContext](../../../Documentation/Notes/OpaqueTypesInContext.md).
Documentation: [ChoosingAnAbstraction](../../../Sources/Wire/Wire.docc/ChoosingAnAbstraction.md), [ResolutionAndKeys](../../../Sources/Wire/Wire.docc/ResolutionAndKeys.md).

## Requirements

### Requirement: `some P` is an identity of its own
WireGen SHALL identify a binding whose type is written `some P` by the qualifier `some` and the
canonical text of `P`, and SHALL match it only to a dependency written `some P`, a lift node's bare
generic parameter constrained to `P` (see the bridge requirement below), or, by promotion, `any P`
and the optional forms of either. It SHALL NOT match a dependency on `P` or on any concrete type
conforming to `P`.

#### Scenario: a `some P` consumer
- **WHEN** `@Provides` binds `some Logger` and `Service` depends on `some Logger`
- **THEN** the dependency resolves and no existential promotion is recorded

Pinned by: `Tests/WireGenCoreTests/GraphTests.swift` (`promotionIsNotRecordedWithoutAnExistentialConsumer`), `Tests/WireGenCoreTests/BindingIdentityTests.swift` (`anyConsumerBorrowsTheSomeProducer`, `optionalAndExistentialPromotionsCompose`). That a `some P` producer does not satisfy a dependency on `P` or on a concrete type is pinned by nothing yet.

### Requirement: `@Singleton(as: P.self)` binds the type as `some P`
WireGen SHALL record a `@Singleton(as: P.self)` type with the identity `some P` and SHALL construct
it by its concrete type name. The `@Singleton` macro SHALL expand `as:` to the same members as a
plain `@Singleton`. The discovery report SHALL list the binding as `some P (from <Concrete>)`.

#### Scenario: an opaque repository
- **WHEN** `@Singleton(as: TaskRepository.self) struct DynamoDBTaskRepository<Table: DynamoDBTable & Sendable>` is discovered
- **THEN** its bound type is `some TaskRepository` and its type name is `DynamoDBTaskRepository`

#### Scenario: the topological report
- **WHEN** `SQLiteTodoRepository` declared `@Singleton(as: TodoRepository.self)` is reported
- **THEN** the report line reads `1. some TodoRepository (from SQLiteTodoRepository)`

Pinned by: `Tests/WireGenCoreTests/DiscoveryTests.swift` (`singletonAsDeclaresOpaqueGraphIdentity`, `singletonWithoutAsHasNoExplicitIdentity`, `singletonAsCoexistsWithAllowUnused`), `Tests/WireMacrosImplTests/SingletonMacroTests.swift` (`test_singletonWithAs_generatesSameMembers`), `Tests/WireGenCoreTests/GraphTests.swift` (`renderTopologicalOrderNamesOpaqueIdentityAndConcreteProducer`).

### Requirement: A lift node's bare constrained parameter bridges to `some P`
When a lift node (a `@Singleton(as:)` type or a determined generic `@Singleton`) has a dependency
whose type is exactly one of its generic parameters, constrained to `C`, WireGen SHALL resolve that
dependency against the `some C` binding under the dependency's own key. A binding that is not a lift
node SHALL NOT be bridged.

#### Scenario: an opaque chain
- **WHEN** `@Provides` binds `some DBTable & Sendable`, `Repo<Table: DBTable & Sendable>` is `@Singleton(as: TaskRepo.self)` injecting `table: Table`, and `Controller<Repository: TaskRepo>` is `@Singleton(as: API.self)` injecting `repository: Repository`
- **THEN** the order is `some DBTable & Sendable`, `some TaskRepo`, `some API` and no generic template is recorded

Pinned by: `Tests/WireGenCoreTests/GraphTests.swift` (`constrainedParameterBridgeResolvesOpaqueChain`), `Tests/WireGenCoreTests/TransitiveLiftTests.swift` (`bridgesBareParameterToSomeConstraint`, `leavesNonParameterDependencyUnchanged`), `Tests/WireGenCoreTests/BindingIdentityTests.swift` (`bridgesAReorderedConstraintToTheSameIdentity`). That a binding which is not a lift node is not bridged is pinned by nothing yet.

### Requirement: A parameter inside a dependency's generic arguments bridges transitively
When a lift node's dependency mentions one of its determined generic parameters as a generic argument
(`Box<Element>`), WireGen SHALL substitute each such parameter with `some <constraint>` and resolve
the dependency against that structural identity. A parameter SHALL match only as a whole identifier
token.

#### Scenario: a proxy over a lift node
- **WHEN** `Proxy<Repository: TodoRepository>` depends on `TodosController<Repository>`
- **THEN** the dependency resolves against `TodosController<some TodoRepository>`

#### Scenario: a longer identifier
- **WHEN** `Proxy<Repository: TodoRepository>` depends only on `Holder<RepositoryStore>`
- **THEN** `Repository` is undetermined and `Proxy` is not a lift node

Pinned by: `Tests/WireGenCoreTests/TransitiveLiftTests.swift` (`parameterAsGenericArgumentDetermines`, `nestedParameterAsGenericArgumentDetermines`, `substringOccurrenceDoesNotDetermine`, `bridgesParameterisedDependencyToWrappedLiftNodeIdentity`), `Tests/WireGenCoreTests/CodeEmissionTests.swift` (`transitiveLiftNodeThreadsParameterThroughParameterisedDependency`).

### Requirement: A determined generic `@Singleton` has a structural identity
A generic `@Singleton` without `as:` whose every generic parameter is constrained to at least one
protocol other than `Sendable`, `AnyObject` or `Any`, and appears in its dependencies bare or as a
generic argument, SHALL be a lift node with the identity `<Type><some C1, …>`. WireGen SHALL resolve
it as a single graph node and SHALL NOT specialise it. Only a constraint written inline in the
generic parameter clause (`<R: TaskRepo>`) counts; a parameter constrained only in a `where` clause
is undetermined.

#### Scenario: a controller over an opaque repository
- **WHEN** plain `@Singleton Controller<Repository: TaskRepo>` injects `repository: Repository` and `some TaskRepo` is bound
- **THEN** the order ends `some TaskRepo`, `Controller<some TaskRepo>` and no generic template is recorded

#### Scenario: a `where`-clause constraint
- **WHEN** plain `@Singleton struct Controller<Repository>` declares `where Repository: TaskRepo` and injects `repository: Repository`
- **THEN** the graph fails with one invalid generic singleton whose undetermined parameters are `["Repository"]`

Pinned by: `Tests/WireGenCoreTests/GraphTests.swift` (`determinedGenericSingletonResolvesAsStructuralLiftNode`), `Tests/WireGenCoreTests/TransitiveLiftTests.swift` (`bareParameterDependencyStillDetermines`, `unconstrainedParameterNeverDetermines`). The marker-protocol-only constraint and the `where`-clause case are pinned by nothing yet.

### Requirement: An undetermined generic `@Singleton` is an error
A generic `@Singleton` without `as:` with any undetermined generic parameter SHALL fail the graph
before duplicate detection with "'@Singleton <Type>' can't be a single instance: generic parameter
'<P>' is unconstrained or unbound, so the type would vary per use. Constrain it to a protocol (so
it resolves to one binding), or use '@Provides func' for a parameterised factory." (pluralised as
"generic parameters '<P>', '<Q>' are … Constrain them …" for several).

#### Scenario: an unconstrained repository
- **WHEN** `@Singleton struct Repository<Model>` has no dependencies
- **THEN** the graph fails with one invalid generic singleton whose undetermined parameters are `["Model"]`

Pinned by: `Tests/WireGenCoreTests/GraphTests.swift` (`genericSingletonWithUndeterminedParameterIsError`). The rendered message is pinned by nothing yet.

### Requirement: `some P` satisfies `any P`, never the reverse
WireGen SHALL resolve an `any P` dependency whose slot is bound as `some P` to that `some P`
producer under the same key; a slot cannot be bound as both `any P` and `some P` (see the duplicate
requirement below). It SHALL NOT resolve a `some P` dependency to an `any P` producer.

#### Scenario: an existential consumer
- **WHEN** `some Logger` is bound and `Service` depends on `any Logger`
- **THEN** the graph orders `some Logger` before `Service` and records one promotion with alias name `anyLogger`

#### Scenario: the reverse
- **WHEN** only `any Logger` is bound and `Service` depends on `some Logger`
- **THEN** the dependency is a missing binding

Pinned by: `Tests/WireGenCoreTests/GraphTests.swift` (`anyConsumerResolvesToTheSomeProducer`, `aSomeConsumerIsNotSatisfiedByAnAnyProducer`), `Tests/WireGenCoreTests/BindingIdentityTests.swift` (`anyConsumerBorrowsTheSomeProducer`, `someConsumerNeverBorrowsTheAnyProducer`, `promotionRespectsKeys`).

### Requirement: A promoted producer is boxed once per body
For each `some P` producer that an `any P` consumer in a body resolved to, the generated body SHALL
declare one `let any<P>: <existential as written> = <producer>` and pass it to every such consumer,
where `<producer>` is the producer's local, or its access path on the parent graph when a seed
scope's bootstrap borrows it (`= _wireGraph.someGreeting`). It SHALL follow the producer's construction line, or open the body when the producer is
borrowed rather than constructed there, and SHALL be omitted when nothing in the body promotes.

#### Scenario: two consumers
- **WHEN** `Reporter` and `Auditor` both depend on `any Logger` and `some Logger` is bound
- **THEN** the bootstrap contains `let anyLogger: any Logger = someLogger` once, `Reporter(logger: anyLogger)` and `Auditor(logger: anyLogger)`

#### Scenario: the integration fixture
- **WHEN** `@Provides var greeting: some Greeting` feeds `GreetingReporter` and `GreetingAuditor`, which inject `any Greeting`
- **THEN** both use the one promoted binding and `graph.someGreeting` is still stored under its own identity

Pinned by: `Tests/WireGenCoreTests/CodeEmissionTests.swift` (`existentialPromotionBindsOneAliasSharedByItsConsumers`, `noAliasIsBoundWhenNothingInTheBodyPromotes`), `Tests/WireGenCoreTests/SeedScopeEmissionTests.swift` (`scopeEntryThunkBindsAnAliasForAPromotedBorrowedSingleton`), `Tests/IntegrationTests/BootstrapTests.swift` (`existentialConsumersShareOnePromotedOpaqueBinding`, `scopedExistentialConsumerBorrowsThePromotedSingleton`), `GoldenHarness/Golden/_WireGraph.swift.golden`.

### Requirement: `some P` and `any P` producers of one slot are a duplicate
When unkeyed, or same-keyed, producers of `some P` and `any P` are both bound, WireGen SHALL report
one duplicate binding for the slot, displayed as `any<P>`, listing both. Producers under different
keys SHALL coexist.

#### Scenario: both spellings bound
- **WHEN** `opaqueLogger: some Logger` and `boxedLogger: any Logger` are both bound unkeyed
- **THEN** one duplicate binding with bound type `anyLogger` and two bindings is reported

#### Scenario: keyed apart
- **WHEN** they are keyed `Log.opaque` and `Log.boxed`
- **THEN** the graph validates

Pinned by: `Tests/WireGenCoreTests/GraphTests.swift` (`someAndAnyProducersForOneProtocolAreDuplicates`, `keysSeparateSomeAndAnyProducers`).

### Requirement: A bare `P` producer is not folded into the `any P` slot
WireGen SHALL treat a producer whose type is written `P`, with no qualifier, as a slot separate from
`any P`, so producers of `P` and `any P` coexist without a duplicate binding.

#### Scenario: a bare and an existential producer
- **WHEN** `boxedLogger: any Logger` is bound and a producer whose bound type is written `Logger` is bound, both unkeyed
- **THEN** the graph validates

Pinned by: `Tests/WireGenCoreTests/GraphTests.swift` (`aConcreteBindingIsNotADuplicateOfTheExistential`).

### Requirement: Each bare `some P` binding lifts a parameter onto the graph struct
For each binding in a graph whose type is written with a leading `some `, in topological order, the
generated struct SHALL declare a generic parameter `T<n>: <P>`, store that binding as `T<n>` (except
for a second keyed binding of the same `some P`, described in the next requirement), and the
bootstrap and `Wire` facade SHALL return `<Struct><some P0, …>`. A graph with no such binding SHALL
keep the bare struct name.

#### Scenario: an opaque chain
- **WHEN** the graph holds `some DBTable & Sendable`, `some TaskRepo` and `some API` in that order
- **THEN** `_wireBootstrap()` and `Wire.bootstrap()` return `_WireGraph<some DBTable & Sendable, some TaskRepo, some API>`

#### Scenario: one opaque provider
- **WHEN** `@Provides` binds `some Greeting` alone
- **THEN** the output declares `internal struct _WireGraph<T0: Greeting>` and `let someGreeting: T0`

Pinned by: `Tests/WireGenCoreTests/CodeEmissionTests.swift` (`opaqueBindingsLiftGenericParametersOntoWireGraph`), `Tests/WireGenCoreTests/RetentionTests.swift` (`anOpaqueLiftedBindingIsStored`), `GoldenHarness/Golden/_WireGraph.swift.golden`.

### Requirement: Keyed bindings of one `some P` share the first one's parameter
When the same `some P` is bound more than once under different keys, the generated struct SHALL
declare a generic parameter for each binding but SHALL type every one of their stored properties with
the first binding's parameter, which is tracked as a defect in
https://github.com/swift-wire/swift-wire/issues/368.

#### Scenario: two keyed opaque loggers
- **WHEN** `some Logger` is bound under `Log.a` and again under `Log.b`, in that topological order
- **THEN** the struct declares `T0: Logger, T1: Logger` and both stored properties are typed `T0`

Pinned by: nothing yet.

### Requirement: A structural lift node reuses its bridge targets' parameters
A determined generic `@Singleton` SHALL lift no parameter of its own; its stored property SHALL be
typed `<Type><T<n>, …>`, each argument the lifted parameter of the `some <constraint>` binding its
generic parameter bridges to.

#### Scenario: a controller over a lifted repository
- **WHEN** `Controller<Repository: TaskRepo>` is a structural lift node over the `some TaskRepo` binding lifted as `T1`
- **THEN** the graph struct stores it as `Controller<T1>` and has two generic parameters for the three-node chain

Pinned by: `Tests/WireGenCoreTests/CodeEmissionTests.swift` (`structuralLiftNodeReusesBridgeTargetParameterAsNestedField`, `multiParamStructuralLiftNodeSubstitutesEachParameterIndependently`), `GoldenHarness/Golden/_WireGraph.swift.golden`.

### Requirement: A constructed bare `some P` binding is always stored
A binding whose type is written with a leading `some ` that the graph constructs SHALL be a stored
property of the generated graph struct whether or not it is a declared root. Its `some P` type does
not make it a reachability root, so an opaque binding that no root reaches is pruned before emission
like any other binding.

#### Scenario: an opaque provider that is not a root
- **WHEN** the emitted order holds only `@Provides` of `some Greeting`, which is not a declared root
- **THEN** the struct stores `let someGreeting: T0`

Pinned by: `Tests/WireGenCoreTests/RetentionTests.swift` (`anOpaqueLiftedBindingIsStored`). The pruning of an unreachable opaque binding is pinned by nothing yet.

### Requirement: A seed scope's facade names its opaque parent graph by the erased type
When the parent graph lifts parameters, the seed scope's `Wire` facade SHALL take the parent graph
as `<Struct><some P0, …>` rather than the bare struct name, under the parent-graph label (`wireGraph:`
for `_WireGraph`, `testContainerWireGraph:` for `_TestContainerWireGraph`).

#### Scenario: an opaque parent
- **WHEN** the app graph is `_WireGraph<T0: TodoRepository>` and a seed scope `HBRequestSeed` borrows from it
- **THEN** the facade is `static func bootstrapHBRequestSeedScope(seed: HBRequestSeed, wireGraph: _WireGraph<some TodoRepository>)`

Pinned by: `Tests/WireGenCoreTests/SeedScopeEmissionTests.swift` (`seedScopeNamesOpaqueParentGraphWithItsLiftedParameters`), `GoldenHarness/Golden/_WireGraph.swift.golden`.

### Requirement: A seed scope's bootstrap function lifts the parent axes its stored bindings use
When the parent graph lifts parameters, the seed scope's private bootstrap function SHALL take the
parent graph as `<Struct><…>` in which each axis that one of the scope's stored bindings uses becomes
one of the function's own generic parameters `T<n>` and every other axis stays `some P`.

#### Scenario: no stored opaque binding
- **WHEN** the app graph is `_WireGraph<T0: TodoRepository>` and the seed scope `HBRequestSeed` stores only `RequestLogger`
- **THEN** the bootstrap function takes `wireGraph _wireGraph: _WireGraph<some TodoRepository>`

#### Scenario: a stored binding over one axis
- **WHEN** the seed scope `GenSeedRequestSeed` stores a binding over the parent's `some GenBackend` axis
- **THEN** the bootstrap function is `_wireBootstrapGenSeedRequestSeedScope<T0: GenBackend>` taking `wireGraph _wireGraph: _WireGraph<some AggregateSearchBackend, some GenAppBackend, T0, some GenProxyRepository, some GenSomethingElse, some Greeting, some TeardownResource>`

Pinned by: `Tests/WireGenCoreTests/SeedScopeEmissionTests.swift` (`seedScopeNamesOpaqueParentGraphWithItsLiftedParameters`), `GoldenHarness/Golden/_WireGraph.swift.golden`.

## Related specifications

- [binding-identity-and-keys](../binding-identity-and-keys/spec.md)
- [binding-lifetimes](../binding-lifetimes/spec.md)
- [optional-promotion](../optional-promotion/spec.md)
- [seeded-scopes](../seeded-scopes/spec.md)
- [reachability-and-retention](../reachability-and-retention/spec.md)
- [scope-entry-and-generated-names](../scope-entry-and-generated-names/spec.md)
- [build-plugin-and-wiregen-cli](../build-plugin-and-wiregen-cli/spec.md)
- [providers](../providers/spec.md)
