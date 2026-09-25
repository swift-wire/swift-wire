# Providers

## Purpose

`@Provides` declares a producer: a property or function whose value becomes a binding of its
declared type. This spec covers where WireGen recognises one, how it determines the bound type and
the dependencies, how a provider is keyed, which graph a provider in an extension lands in, and how
a generic `@Provides func` stays a template that is specialised per instantiation a consumer asks
for. The lifetime macros for self-producing types are in
[binding-lifetimes](../binding-lifetimes/spec.md), identity matching and duplicate producers in
[binding-identity-and-keys](../binding-identity-and-keys/spec.md), and what `allowUnused:` does in
[reachability-and-retention](../reachability-and-retention/spec.md).

Rationale: [OpaqueTypesSupport](../../../Documentation/Notes/OpaqueTypesSupport.md).
Documentation: [ProvidingValues](../../../Sources/Wire/Wire.docc/ProvidingValues.md), [ResolutionAndKeys](../../../Sources/Wire/Wire.docc/ResolutionAndKeys.md).

## Requirements

### Requirement: `@Provides` is a marker that generates nothing
The `@Provides` macro SHALL expand to no peers on a property or function, at module scope or as a
`static` member.

#### Scenario: a static function
- **WHEN** `enum E { @Provides static func make() -> Foo { Foo() } }` is expanded
- **THEN** the source is unchanged

Pinned by: `Tests/WireMacrosImplTests/ProvidesMacroTests.swift` (`test_providesOnTopLevelLet_producesNoPeers`, `test_providesOnTopLevelFunc_producesNoPeers`, `test_providesOnStaticLet_producesNoPeers`, `test_providesOnStaticFunc_producesNoPeers`).

### Requirement: `@Provides` is recognised at module scope and on `static` members only
WireGen SHALL record a `@Provides` property or function declared at module scope, or declared
`static` inside a struct, class, enum, actor or extension, with an access path of the enclosing
type names and the member name joined by `.`. It SHALL ignore `@Provides` on an instance member.

#### Scenario: a nested static
- **WHEN** `enum Outer { enum Inner { @Provides static let foo: Foo = Foo() } }` is discovered
- **THEN** the provider's access path is `Outer.Inner.foo`

#### Scenario: an instance member
- **WHEN** `struct AppConfig { @Provides let logger: Logger = Logger() }` is discovered
- **THEN** no provider is recorded

Pinned by: `Tests/WireGenCoreTests/DiscoveryTests.swift` (`providesOnTopLevelLetIsDiscovered`, `providesOnStaticLetCapturesEnclosingTypeInAccessPath`, `providesOnStaticFuncCapturesEnclosingTypeInAccessPath`, `providesNestedInsideTypesProducesDottedAccessPath`, `providesOnInstanceMemberIsSkipped`), `Tests/IntegrationTests/BootstrapTests.swift` (`providersAtAllAttachmentSitesProduceWiredGraph`).

### Requirement: A `@Provides` property binds its annotated or constructed type
WireGen SHALL take a `@Provides` property's bound type from its type annotation, or, when there is
none, from an initialiser of the form `Foo(…)` or `Foo<Bar>(…)` whose called name starts with an
uppercase letter. A property whose type neither source determines, or a declaration with more than
one pattern binding, SHALL be skipped without a diagnostic.

#### Scenario: an inferred type
- **WHEN** `@Provides let logger = Logger()` is discovered
- **THEN** the provider's bound type is `Logger`

#### Scenario: a member access
- **WHEN** `@Provides let logger = Logger.shared` is discovered
- **THEN** no provider is recorded

Pinned by: `Tests/WireGenCoreTests/DiscoveryTests.swift` (`providesLetInferredFromConstructorCallIsDiscovered`, `providesLetInferredFromGenericConstructorCall`, `providesLetTypeAnnotationTakesPrecedenceOverConstructorCall`, `providesLetFromMemberAccessIsSkipped`, `providesLetFromLowercaseFunctionCallIsSkipped`, `providesLetFromLiteralIsSkipped`). The skip of a declaration with more than one pattern binding, and the absence of a diagnostic for any skip, are pinned by nothing yet.

### Requirement: A `@Provides` computed property carries its getter's effects
WireGen SHALL record a `@Provides` computed property with the `async` and `throws` specifiers of its
`get` accessor, and a stored `@Provides` property as neither.

#### Scenario: an async throwing getter
- **WHEN** `@Provides var fetchedFoo: Foo { get async throws { … } }` is bootstrapped
- **THEN** the graph awaits and tries the getter and injects its value

Pinned by: `Tests/WireGenCoreTests/DiscoveryTests.swift` (`providesComputedPropertyWithEffectsCapturesFlags`, `providesStoredPropertyHasNoEffects`), `Tests/IntegrationTests/BootstrapTests.swift` (`asyncThrowsComputedPropertyResolvesThroughBootstrap`).

### Requirement: A `@Provides` function's parameters are its dependencies
WireGen SHALL record a `@Provides` function's return type as its bound type and each of its
parameters, in order, as a dependency resolved by type (or by `@Bind` key). A `@Provides` function
with no return clause SHALL be skipped.

#### Scenario: two parameters
- **WHEN** `@Provides func makeRepository(table: TaskTable, logger: Logger) -> Repository` is discovered
- **THEN** the provider binds `Repository` with dependencies `TaskTable` and `Logger`

#### Scenario: no return type
- **WHEN** `@Provides func sideEffect() { … }` is discovered
- **THEN** no provider is recorded

Pinned by: `Tests/WireGenCoreTests/DiscoveryTests.swift` (`providesOnTopLevelFuncWithoutParametersIsDiscovered`, `providesOnTopLevelFuncWithParametersBecomesDependencies`, `providesOnVoidReturningFuncIsSkipped`, `providesPreservesGenericInstantiationInBoundType`), `Tests/IntegrationTests/BootstrapTests.swift` (`providersAtAllAttachmentSitesProduceWiredGraph`).

### Requirement: `@Provides(key)` records the key's written text
WireGen SHALL record the positional first argument of `@Provides(…)` as the provider's key, as its
trimmed source text. A leading labelled argument SHALL mean the provider has no key.

#### Scenario: a keyed provider
- **WHEN** `@Provides(Foo.primary, allowUnused: true) let foo: Foo = Foo()` is discovered
- **THEN** the provider's key is `Foo.primary`

#### Scenario: a label only
- **WHEN** `@Provides(allowUnused: true) let foo: Foo = Foo()` is discovered
- **THEN** the provider has no key

Pinned by: `Tests/WireGenCoreTests/DiscoveryTests.swift` (`providesWithoutKeyArgumentHasNilKeyIdentifier`, `providesWithMemberAccessKeyExtractsCanonicalText`, `providesFunctionWithKeyExtractsCanonicalText`, `allowUnusedTrueIsCapturedOnProvides`, `keyedProvidesWithAllowUnusedCapturesBoth`).

### Requirement: A `@Singleton` or `@Scoped` binding carries no key
A `@Singleton` or `@Scoped` binding SHALL have no key in the graph; the `static key` its macro
synthesises SHALL NOT key it.

#### Scenario: a singleton's synthesised key
- **WHEN** `@Singleton struct Repo` is bound and a consumer declares `@Inject(Repo.key) var repo: Repo`
- **THEN** the consumer's keyed dependency does not resolve to `Repo`

Pinned by: `Tests/WireGenCoreTests/GraphTests.swift` (`keyedDependencyDoesNotMatchUnkeyedBinding`).

### Requirement: `@Provides` in an unannotated extension falls through to the default graph
A `@Provides` inside an `extension` that does not carry `@Container` SHALL be recorded in the
enclosing partition, not the extended type's container. For each `@Provides` declared directly in
such an extension, WireGen SHALL warn "@Provides '<name>' in an unannotated extension of '<Type>'
falls through to the default graph — mark the extension @Container to contribute to '<Type>'s
container instead." when the extended type is a `@Container` that has at least one binding of its
own. A `@Container` with no bindings of its own, and a `@Provides` in a type nested inside the
extension, get no warning, which is tracked as a defect in
https://github.com/swift-wire/swift-wire/issues/430.

#### Scenario: an extension of a container
- **WHEN** `@Container enum TestContainer` is declared and `extension TestContainer { @Provides static let extra: Extra = Extra() }` is discovered
- **THEN** `TestContainer.extra` is a default-graph binding and the extension site is recorded as a warning candidate

Pinned by: `Tests/WireGenCoreTests/DiscoveryTests.swift` (`providesInUnannotatedExtensionFallsThroughToDefault`, `unannotatedExtensionProvidesIsRecordedAsCandidate`, `containerAnnotatedExtensionProvidesIsNotACandidate`). The warning text is pinned by nothing yet.

### Requirement: `@Provides` in an extension of an undeclared type is a warning
When the extended type is neither a `@Container` nor a type name declared in the sources WireGen
scanned, and the extended type's recorded name contains no `.` or `<`, WireGen SHALL warn
"@Provides '<name>' in an extension of '<Type>' — '<Type>' isn't declared in this module, so the
binding falls through to the default graph and any @Container on '<Type>' elsewhere isn't visible
to discovery. …" A generic specialisation such as `extension Array<Int>` is recorded by its base
name `Array` and warns; a member type such as `extension Foo.Bar` is recorded as written and does
not. The declared names are taken from every module WireGen scanned in the run and matched by
simple name, which is tracked as a defect in https://github.com/swift-wire/swift-wire/issues/434.

#### Scenario: an imported type
- **WHEN** `extension Logger { @Provides static let appLogger: Logger = Logger() }` is discovered and no `Logger` is declared in the module
- **THEN** one warning containing "'Logger' isn't declared in this module" is reported

#### Scenario: a generic specialisation
- **WHEN** `extension Array<Int> { @Provides static let empty: [Int] = [] }` is discovered
- **THEN** one warning containing "'Array' isn't declared in this module" is reported

Pinned by: `Tests/WireGenCoreTests/DiscoveryTests.swift` (`crossModuleExtensionWarningFiresForUndeclaredType`, `crossModuleExtensionWarningSkipsLocallyDeclaredType`, `crossModuleExtensionWarningDefersToContainerWarning`, `crossModuleExtensionWarningSkipsMemberTypeTargets`, `crossModuleExtensionWarningTreatsGenericExtensionAsBaseName`).

### Requirement: A generic `@Provides func` is specialised per requested instantiation
WireGen SHALL keep a `@Provides func` with generic parameters out of the graph as a template. A
template matches a dependency `<Base><A1, …, An>` when its return type's base name is `<Base>`, it
declares exactly n generic parameters, and its key is the dependency's key. For a dependency that
no binding written in source already satisfies and exactly one template matches, WireGen SHALL add
one specialised binding of that concrete type, substituting `Ai` for the template's i-th generic
parameter, and repeat until no new specialisation arises. Consumers of the same instantiation SHALL
share one specialised binding. Because matching counts generic parameters and substitutes by
position, a return type that does not list the generic parameters in declaration order is never
matched or is specialised with the wrong substitution, which is tracked as a defect in
https://github.com/swift-wire/swift-wire/issues/432.

#### Scenario: one parameter
- **WHEN** `@Provides func makeContainer<T: Sendable>(item: T) -> Container<T>` is declared and `GenericConsumer` injects `Container<DataPoint>`
- **THEN** the graph calls `makeContainer` with `T = DataPoint` and exposes `containerOfDataPoint`

#### Scenario: no consumer
- **WHEN** a generic `@Provides func` has no consumer of any instantiation
- **THEN** it appears among the generic templates and not in the topological order

Pinned by: `Tests/WireGenCoreTests/GraphTests.swift` (`singleParamGenericProviderSpecialisedForConcreteConsumer`, `multiParamGenericProviderSpecialisedForConcreteConsumer`, `genericProviderFunctionSpecialisedCarriesConcreteArguments`, `multipleConsumersOfSameSpecialisationShareOneBinding`, `specialisedBindingDepThatIsAlsoGenericChainsThroughFixpoint`, `specialisationHonoursWhitespaceCanonicalisation`, `genericProviderFunctionIsSkippedFromGraph`), `Tests/IntegrationTests/BootstrapTests.swift` (`genericSingletonSpecialisedForConcreteConsumer`).

### Requirement: A generic template that competes for an instantiation is a duplicate binding
When a binding written in source already has a dependency's identity and a generic template also
matches it, or when two or more templates match it, WireGen SHALL report a duplicate binding listing
the competing producers instead of specialising, as described in
[binding-identity-and-keys](../binding-identity-and-keys/spec.md).

#### Scenario: a concrete binding and a template
- **WHEN** a concrete binding of `Repository<DynamoDBTable>` and `makeRepository<T>(table: T) -> Repository<T>` are declared and `App` depends on `Repository<DynamoDBTable>`
- **THEN** one duplicate binding for `Repository<DynamoDBTable>` lists the concrete binding and the template

#### Scenario: two templates
- **WHEN** `makeRepoA<T>() -> Repository<T>` and `makeRepoB<T>() -> Repository<T>` are declared and `App` depends on `Repository<DynamoDBTable>`
- **THEN** one duplicate binding for `Repository<DynamoDBTable>` lists both templates

Pinned by: `Tests/WireGenCoreTests/GraphTests.swift` (`concreteAndGenericForSameInstantiationIsAmbiguous`, `multipleGenericCandidatesProduceAmbiguityError`).

### Requirement: Specialisation substitutes bare parameters only
When specialising, WireGen SHALL replace a dependency's type only when it is exactly one of the
template's generic parameter names. A dependency that mentions a parameter inside a larger type
SHALL pass through unchanged.

#### Scenario: a nested parameter
- **WHEN** `makeWrapper<T>(box: Box<T>) -> Wrapper<T>` is specialised for `Wrapper<Int>`
- **THEN** the specialised binding still depends on `Box<T>`, which is reported as a missing binding

Pinned by: `Tests/WireGenCoreTests/GraphTests.swift` (`nestedSubstitutionInDepTypeStaysUnsubstitutedAndMissingBindingFires`).

## Related specifications

- [binding-lifetimes](../binding-lifetimes/spec.md)
- [binding-identity-and-keys](../binding-identity-and-keys/spec.md)
- [injection-points](../injection-points/spec.md)
- [opaque-type-identity](../opaque-type-identity/spec.md)
- [containers](../containers/spec.md)
- [teardown](../teardown/spec.md)
- [construction-scheduling](../construction-scheduling/spec.md)
- [reachability-and-retention](../reachability-and-retention/spec.md)
- [multi-module-composition](../multi-module-composition/spec.md)
