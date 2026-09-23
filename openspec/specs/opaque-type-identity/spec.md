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
canonical text of `P`, and SHALL match it only to a dependency written `some P` or, by promotion,
`any P`. It SHALL NOT match a dependency on `P` or on any concrete type conforming to `P`.

#### Scenario: a `some P` consumer
- **WHEN** `@Provides` binds `some Logger` and `Service` depends on `some Logger`
- **THEN** the dependency resolves and no existential promotion is recorded

Pinned by: `Tests/WireGenCoreTests/GraphTests.swift` (`promotionIsNotRecordedWithoutAnExistentialConsumer`, `constrainedParameterBridgeResolvesOpaqueChain`), `Tests/WireGenCoreTests/BindingIdentityTests.swift` (`aConcreteProducerNeverSatisfiesAnExistential`).

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

Pinned by: `Tests/WireGenCoreTests/GraphTests.swift` (`constrainedParameterBridgeResolvesOpaqueChain`), `Tests/WireGenCoreTests/TransitiveLiftTests.swift` (`bridgesBareParameterToSomeConstraint`, `doesNotBridgeForNonLiftNode`, `leavesNonParameterDependencyUnchanged`), `Tests/WireGenCoreTests/BindingIdentityTests.swift` (`bridgesAReorderedConstraintToTheSameIdentity`).

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
it as a single graph node and SHALL NOT specialise it.

#### Scenario: a controller over an opaque repository
- **WHEN** plain `@Singleton Controller<Repository: TaskRepo>` injects `repository: Repository` and `some TaskRepo` is bound
- **THEN** the order ends `some TaskRepo`, `Controller<some TaskRepo>` and no generic template is recorded

Pinned by: `Tests/WireGenCoreTests/GraphTests.swift` (`determinedGenericSingletonResolvesAsStructuralLiftNode`), `Tests/WireGenCoreTests/TransitiveLiftTests.swift` (`bareParameterDependencyStillDetermines`, `unconstrainedParameterNeverDetermines`). The marker-protocol-only constraint is pinned by nothing yet.

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
WireGen SHALL resolve an `any P` dependency to an `any P` producer when one exists and otherwise to
a `some P` producer under the same key. It SHALL NOT resolve a `some P` dependency to an `any P`
producer.

#### Scenario: an existential consumer
- **WHEN** `some Logger` is bound and `Service` depends on `any Logger`
- **THEN** the graph orders `some Logger` before `Service` and records one promotion with alias name `anyLogger`

#### Scenario: the reverse
- **WHEN** only `any Logger` is bound and `Service` depends on `some Logger`
- **THEN** the dependency is a missing binding

Pinned by: `Tests/WireGenCoreTests/GraphTests.swift` (`anyConsumerResolvesToTheSomeProducer`, `aSomeConsumerIsNotSatisfiedByAnAnyProducer`), `Tests/WireGenCoreTests/BindingIdentityTests.swift` (`anyConsumerBorrowsTheSomeProducer`, `someConsumerNeverBorrowsTheAnyProducer`, `anExactAnyProducerWinsOverThePromotion`, `promotionRespectsKeys`).

### Requirement: A promoted producer is boxed once per body
For each `some P` producer that an `any P` consumer in a body resolved to, the generated body SHALL
declare one `let any<P>: <existential as written> = <producer local>` and pass it to every such
consumer. It SHALL follow the producer's construction line, or open the body when the producer is
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

Pinned by: `Tests/WireGenCoreTests/GraphTests.swift` (`someAndAnyProducersForOneProtocolAreDuplicates`, `keysSeparateSomeAndAnyProducers`, `aConcreteBindingIsNotADuplicateOfTheExistential`).

### Requirement: Each bare `some P` binding lifts a parameter onto the graph struct
For each binding in a graph whose type is written with a leading `some `, in topological order, the
generated struct SHALL declare a generic parameter `T<n>: <P>`, store that binding as `T<n>`, and the
bootstrap and `Wire` facade SHALL return `<Struct><some P0, …>`. A graph with no such binding SHALL
keep the bare struct name.

#### Scenario: an opaque chain
- **WHEN** the graph holds `some DBTable & Sendable`, `some TaskRepo` and `some API` in that order
- **THEN** `_wireBootstrap()` and `Wire.bootstrap()` return `_WireGraph<some DBTable & Sendable, some TaskRepo, some API>`

#### Scenario: one opaque provider
- **WHEN** `@Provides` binds `some Greeting` alone
- **THEN** the output declares `internal struct _WireGraph<T0: Greeting>` and `let someGreeting: T0`

Pinned by: `Tests/WireGenCoreTests/CodeEmissionTests.swift` (`opaqueBindingsLiftGenericParametersOntoWireGraph`), `Tests/WireGenCoreTests/RetentionTests.swift` (`anOpaqueLiftedBindingIsStored`), `GoldenHarness/Golden/_WireGraph.swift.golden`.

### Requirement: A structural lift node reuses its bridge targets' parameters
A determined generic `@Singleton` SHALL lift no parameter of its own; its stored property SHALL be
typed `<Type><T<n>, …>`, each argument the lifted parameter of the `some <constraint>` binding its
generic parameter bridges to.

#### Scenario: a controller over a lifted repository
- **WHEN** `Controller<Repository: TaskRepo>` is a structural lift node over the `some TaskRepo` binding lifted as `T1`
- **THEN** the graph struct stores it as `Controller<T1>` and has two generic parameters for the three-node chain

Pinned by: `Tests/WireGenCoreTests/CodeEmissionTests.swift` (`structuralLiftNodeReusesBridgeTargetParameterAsNestedField`, `multiParamStructuralLiftNodeSubstitutesEachParameterIndependently`), `GoldenHarness/Golden/_WireGraph.swift.golden`.

### Requirement: A bare `some P` binding is always stored
A binding whose type is written with a leading `some ` SHALL be a stored property of the generated
graph struct whether or not a root reaches it.

#### Scenario: an unrooted opaque provider
- **WHEN** the only binding is `@Provides` of `some Greeting`
- **THEN** the struct stores `let someGreeting: T0`

Pinned by: `Tests/WireGenCoreTests/RetentionTests.swift` (`anOpaqueLiftedBindingIsStored`).

### Requirement: A seed scope names its opaque parent graph by the erased type
When the parent graph lifts parameters, the seed scope's bootstrap function and facade SHALL take
`wireGraph: <Struct><some P0, …>` rather than the bare struct name.

#### Scenario: an opaque parent
- **WHEN** the app graph is `_WireGraph<T0: TodoRepository>` and a seed scope `HBRequestSeed` borrows from it
- **THEN** the facade is `static func bootstrapHBRequestSeedScope(seed: HBRequestSeed, wireGraph: _WireGraph<some TodoRepository>)`

Pinned by: `Tests/WireGenCoreTests/SeedScopeEmissionTests.swift` (`seedScopeNamesOpaqueParentGraphWithItsLiftedParameters`).

## Related specifications

- [binding-identity-and-keys](../binding-identity-and-keys/spec.md)
- [binding-lifetimes](../binding-lifetimes/spec.md)
- [optional-promotion](../optional-promotion/spec.md)
- [seeded-scopes](../seeded-scopes/spec.md)
- [reachability-and-retention](../reachability-and-retention/spec.md)
- [scope-entry-and-generated-names](../scope-entry-and-generated-names/spec.md)
- [build-plugin-and-wiregen-cli](../build-plugin-and-wiregen-cli/spec.md)
