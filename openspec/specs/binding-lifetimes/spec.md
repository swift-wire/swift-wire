# Binding lifetimes

## Purpose

The declarations that put a binding in a graph. `@Singleton` and `@Scoped(seed:)` make a type its
own producer: the macro synthesises the initialiser Wire calls and a `static key`, and WireGen
records the type as a binding of the app partition or of the seed's scope. `@Factory(key)` is the
third lifetime macro and is exclusive with the other two. `@Provides` is a marker on a property or
function that WireGen records as a producer of its declared type, with a function's parameters as
its dependencies.

Rationale: [OpaqueTypesSupport](../../../Documentation/Notes/OpaqueTypesSupport.md), [VisibilityModel](../../../Documentation/Notes/VisibilityModel.md).
Documentation: [ProvidingValues](../../../Sources/Wire/Wire.docc/ProvidingValues.md), [InjectionPoints](../../../Sources/Wire/Wire.docc/InjectionPoints.md), [ScopesAndLifetimes](../../../Sources/Wire/Wire.docc/ScopesAndLifetimes.md).

## Requirements

### Requirement: `@Singleton` synthesises an initialiser and a static key
The `@Singleton` macro SHALL add to the primary declaration the initialiser described in
[injection-points](../injection-points/spec.md) (from `@Inject` stored properties in declaration
order, or none when a single `@Inject init` is written) and a
`static let key = BindingKey<<Type>>()`, both carrying the host type's access keyword with
`internal` omitted.

#### Scenario: an empty singleton
- **WHEN** `@Singleton struct A {}` is expanded
- **THEN** the expansion adds `init() {}` and `static let key = BindingKey<A>()`

#### Scenario: a package singleton
- **WHEN** `@Singleton package struct` is expanded
- **THEN** the synthesised initialiser and key are both declared `package`

Pinned by: `Tests/WireMacrosImplTests/SingletonMacroTests.swift` (`test_singletonOnEmptyStruct_generatesEmptyInitAndKey`, `test_singletonOnPublicStruct_emitsPublicInitAndKey`, `test_singletonOnPackageStruct_emitsPackageInitAndKey`, `test_singletonSkipsInitGenerationWhenInjectInitProvided`).

### Requirement: A generic type's key is a computed static property
When the host type declares a generic parameter clause, the `@Singleton` macro SHALL emit
`static var key: BindingKey<<Type><<Params>>> { BindingKey<<Type><<Params>>>() }` in place of the
stored `static let key`.

#### Scenario: a generic repository
- **WHEN** `@Singleton struct Repository<Model> { @Inject var store: Store<Model> }` is expanded
- **THEN** the expansion adds `init(store: Store<Model>)` and `static var key: BindingKey<Repository<Model>> { BindingKey<Repository<Model>>() }`

Pinned by: `Tests/WireMacrosImplTests/SingletonMacroTests.swift` (`test_singletonOnGenericStruct_specialisesKeyToGenericInstance`), `Tests/WireMacrosImplTests/ScopedMacroTests.swift` (`test_scopedOnGenericStruct_keyIsComputedAndCarriesGenericParameters`).

### Requirement: A user-declared `key` suppresses the synthesised one
When the primary declaration has a `static` or `class` property named `key`, the `@Singleton`
macro SHALL NOT emit a `key` of its own.

#### Scenario: a user key
- **WHEN** `@Singleton struct A` declares `@Inject var b: B` and `static let key = …`
- **THEN** the expansion adds only `init(b: B)`

Pinned by: `Tests/WireMacrosImplTests/SingletonMacroTests.swift` (`test_singletonSkipsKeyGenerationWhenUserProvided`, `test_singletonGeneratesNothingWhenUserProvidesBoth`).

### Requirement: `@Singleton` applies to a struct, class or actor
The `@Singleton` macro SHALL expand on a struct, class or actor, and SHALL fail on any other
declaration with "@Singleton can only be applied to a struct, class, or actor."

#### Scenario: an actor
- **WHEN** `@Singleton actor A` is expanded
- **THEN** the expansion adds the initialiser and key

#### Scenario: an enum
- **WHEN** `@Singleton enum A { case b }` is expanded
- **THEN** the macro reports "@Singleton can only be applied to a struct, class, or actor." at the attribute

Pinned by: `Tests/WireMacrosImplTests/SingletonMacroTests.swift` (`test_singletonOnClass_works`, `test_singletonOnActor_works`, `test_singletonOnEnum_throwsUnsupportedDeclarationError`, `test_singletonOnProtocol_throwsUnsupportedDeclarationError`).

### Requirement: `@Scoped(seed:)` expands exactly as `@Singleton` on a type
On a struct, class or actor the `@Scoped(seed:)` macro SHALL add the same members `@Singleton`
adds, whatever the seed type.

#### Scenario: two seed types
- **WHEN** `@Scoped(seed: A.self)` and `@Scoped(seed: B.self)` are applied to identical structs
- **THEN** both expansions add the same `init` and `static let key`

Pinned by: `Tests/WireMacrosImplTests/ScopedMacroTests.swift` (`test_scopedOnEmptyStruct_generatesEmptyInitAndKey`, `test_scopedWithOneInject_generatesParameterisedInit`, `test_scopedWithDifferentSeedType_producesIdenticalMembers`).

### Requirement: `@Scoped(seed:)` on an enum is an inert scope-block marker
The `@Scoped(seed:)` macro SHALL add nothing to an `enum`, and SHALL fail on any declaration that
is not a struct, class, actor or enum with "@Scoped can only be applied to a struct, class, or
actor, or a namespace enum (as a scope block)."

#### Scenario: a scope block
- **WHEN** `@Scoped(seed: RequestSeed.self) enum RequestProviders { static let tag: Tag = Tag() }` is expanded
- **THEN** the enum is unchanged

#### Scenario: a protocol
- **WHEN** `@Scoped(seed: RequestSeed.self) protocol A` is expanded
- **THEN** the macro reports the scope-block error message at the attribute

Pinned by: `Tests/WireMacrosImplTests/ScopedMacroTests.swift` (`test_scopedOnNamespaceEnum_emitsNothingAsScopeBlock`, `test_scopedOnProtocol_throwsUnsupportedDeclarationError`).

### Requirement: `@Factory(key)` synthesises an initialiser and no key
The `@Factory` macro SHALL add the same initialiser as `@Singleton` to a struct, class or actor and
SHALL NOT add a `key`. On any other declaration it SHALL fail with "@Factory can only be applied
to a struct, class, or actor."

#### Scenario: a generic template
- **WHEN** `@Factory(MyMiddleware.session) struct SessionMiddleware<Ctx, Reader, Sender> { @Inject var store: SessionStore }` is expanded
- **THEN** the expansion adds `init(store: SessionStore)` and nothing else

Pinned by: `Tests/WireMacrosImplTests/FactoryMacroTests.swift` (`test_factoryWithInjectProperty_generatesInitFromInjectMembers`, `test_factoryWithNoInject_generatesEmptyInit`, `test_publicFactory_generatesPublicInit`).

### Requirement: An uninitialised non-injected stored property is an error
When the lifetime macro synthesises the initialiser, it SHALL report "Stored property '<name>' must
have a default value, be a computed property, or be marked @Inject." at each non-`static`
stored property binding that has no `@Inject`, no initial value and no accessor block. It SHALL
NOT report this when the declaration has a user-written initialiser.

#### Scenario: a bare `let`
- **WHEN** `@Singleton struct A` declares `@Inject var injected: Dep` and `let uninitialised: String`
- **THEN** the macro reports the stored-property error at `uninitialised` and still adds `init(injected: Dep)`

#### Scenario: a static property
- **WHEN** a `@Singleton` declares a `static` property without a default
- **THEN** no stored-property error is reported

Pinned by: `Tests/WireMacrosImplTests/SingletonMacroTests.swift` (`test_singletonReportsUninitialisedStoredProperty`, `test_singletonReportsMultipleUninitialisedProperties`, `test_singletonAllowsStaticPropertyWithoutDefault`, `test_singletonSuppressesUninitialisedDiagnosticWhenInjectInitProvided`), `Tests/WireMacrosImplTests/WireDiagnosticTests.swift` (`test_uninitialisedStoredProperty_diagnosticID`).

### Requirement: A declaration carries one lifetime macro
When a declaration carries more than one of `@Singleton`, `@Scoped` and `@Factory`, the first in
source order SHALL expand normally and each later one SHALL synthesise nothing and report
"@<this> and @<first> both declare a lifetime, and a declaration has one. @Singleton is one
instance for the process, @Scoped(seed:) one per scope entry, and @Factory no scope at all — its
template is constructed per `create` call, and the binding with a lifetime is the factory Wire
synthesises for the key. Remove @<this>." at its attribute.

#### Scenario: `@Singleton` then `@Factory`
- **WHEN** `@Singleton @Factory(ControllerMiddleware.screenAccess) struct ScreenAccess<Ctx>` is expanded
- **THEN** one `init` and one `static var key` are added and the error names `@Factory` for removal, at line 2

#### Scenario: `@Factory` then `@Scoped`
- **WHEN** `@Factory(…)` precedes `@Scoped(seed: HTTPRequest.self)` on one struct
- **THEN** one `init` and no key are added and the error names `@Scoped` for removal

Pinned by: `Tests/WireMacrosImplTests/LifetimeMacroExclusionTests.swift` (`test_singletonThenFactory_diagnosesOnceAndSynthesisesOneInit`, `test_factoryThenSingleton_reportsTheLaterAttribute`, `test_scopedAndFactory_isTheCombinationTheFixItUsedToRecommend`, `test_oneLifetimeMacro_isUnaffected`), `Tests/WireMacrosImplTests/WireDiagnosticTests.swift` (`test_multipleLifetimeMacros_diagnosticID`).

### Requirement: WireGen refuses `@Factory` combined with a scope macro
WireGen SHALL report the error "'<Type>' carries both @Factory and @<Scope> — two lifetime macros
on one declaration, and a declaration has one lifetime. …" at a type carrying `@Factory` and
`@Singleton` or `@Scoped`, and SHALL record that type as neither a binding nor a factory template.

#### Scenario: a scoped template
- **WHEN** a type is declared `@Factory(…) @Scoped(seed: …)`
- **THEN** discovery reports the error containing "carries both @Factory and @Scoped" and records no binding and no template for it

Pinned by: `Tests/WireGenCoreTests/FactoryLifetimeDiagnosticsTests.swift` (`aScopeMacroOnAFactoryTemplateIsRefused`, `aRefusedDeclarationIsRecordedAsNeitherRoleRatherThanBoth`, `aTemplateWithNoScopeMacroIsUnaffected`).

### Requirement: WireGen records a scope-bound type with its dependencies
WireGen SHALL record each struct, class or actor carrying `@Singleton` or `@Scoped(seed:)` as a
binding whose dependencies are the parameters of its `@Inject init` when it has one, and otherwise
its `@Inject` stored properties in declaration order. A `@Singleton` SHALL be recorded in the app
partition and a `@Scoped(seed: S.self)` in the partition of seed `S`.

#### Scenario: an `@Inject init` wins
- **WHEN** a `@Singleton` declares `@Inject` properties and an `@Inject init` with different parameters
- **THEN** the recorded dependencies are the initialiser's parameters

#### Scenario: a scoped type
- **WHEN** `@Scoped(seed: RequestSeed.self) struct RequestLogger` is discovered
- **THEN** it is recorded in the `RequestSeed` partition and not in the default graph

Pinned by: `Tests/WireGenCoreTests/DiscoveryTests.swift` (`singletonOnStructIsDiscovered`, `singletonOnClassIsDiscovered`, `singletonOnActorIsDiscovered`, `injectInitParametersTakePrecedenceOverProperties`, `multipleInjectPropertiesInOrder`, `unannotatedTypeIsIgnored`, `scopedTypeRoutedToPerSeedPartition`, `singletonAndScopedCoexistInSeparatePartitions`), `Tests/IntegrationTests/BootstrapTests.swift` (`bootstrapWiresFullDependencyChain`).

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

Pinned by: `Tests/WireGenCoreTests/DiscoveryTests.swift` (`providesLetInferredFromConstructorCallIsDiscovered`, `providesLetInferredFromGenericConstructorCall`, `providesLetTypeAnnotationTakesPrecedenceOverConstructorCall`, `providesLetFromMemberAccessIsSkipped`, `providesLetFromLowercaseFunctionCallIsSkipped`, `providesLetFromLiteralIsSkipped`).

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

### Requirement: `@Provides` in an unannotated extension falls through to the default graph
A `@Provides` inside an `extension` that does not carry `@Container` SHALL be recorded in the
enclosing partition, not the extended type's container. When the extended type is a `@Container`,
WireGen SHALL warn "@Provides '<name>' in an unannotated extension of '<Type>' falls through to the
default graph — mark the extension @Container to contribute to '<Type>'s container instead."

#### Scenario: an extension of a container
- **WHEN** `@Container enum TestContainer` is declared and `extension TestContainer { @Provides static let extra: Extra = Extra() }` is discovered
- **THEN** `TestContainer.extra` is a default-graph binding and the extension site is recorded as a warning candidate

Pinned by: `Tests/WireGenCoreTests/DiscoveryTests.swift` (`providesInUnannotatedExtensionFallsThroughToDefault`, `unannotatedExtensionProvidesIsRecordedAsCandidate`, `containerAnnotatedExtensionProvidesIsNotACandidate`). The warning text is pinned by nothing yet.

### Requirement: `@Provides` in an extension of an undeclared type is a warning
When the extended type is neither a `@Container` nor a type declared in the module, and its written
name contains no `.` or `<`, WireGen SHALL warn "@Provides '<name>' in an extension of '<Type>' —
'<Type>' isn't declared in this module, so the binding falls through to the default graph and any
@Container on '<Type>' elsewhere isn't visible to discovery. …"

#### Scenario: an imported type
- **WHEN** `extension Logger { @Provides static let appLogger: Logger = Logger() }` is discovered and no `Logger` is declared in the module
- **THEN** one warning containing "'Logger' isn't declared in this module" is reported

Pinned by: `Tests/WireGenCoreTests/DiscoveryTests.swift` (`crossModuleExtensionWarningFiresForUndeclaredType`, `crossModuleExtensionWarningSkipsLocallyDeclaredType`, `crossModuleExtensionWarningDefersToContainerWarning`, `crossModuleExtensionWarningSkipsMemberTypeTargets`).

### Requirement: `allowUnused:` counts only as a literal `true`
WireGen SHALL mark a `@Singleton`, `@Scoped` or `@Provides` binding as `allowUnused` only when the
attribute's `allowUnused:` argument is the boolean literal `true`. The macros SHALL expand the same
members whether or not `allowUnused:` is present.

#### Scenario: a literal flag
- **WHEN** `@Singleton(allowUnused: true) struct A {}` is discovered
- **THEN** the binding is marked `allowUnused`, and the macro adds the same `init()` and key as a plain `@Singleton`

Pinned by: `Tests/WireGenCoreTests/DiscoveryTests.swift` (`allowUnusedTrueIsCapturedOnSingleton`, `plainSingletonIsNotAllowUnused`, `allowUnusedTrueIsCapturedOnProvides`), `Tests/WireMacrosImplTests/SingletonMacroTests.swift` (`test_singletonWithAllowUnused_generatesSameMembers`). A non-literal argument is pinned by nothing yet.

## Related specifications

- [injection-points](../injection-points/spec.md)
- [binding-identity-and-keys](../binding-identity-and-keys/spec.md)
- [opaque-type-identity](../opaque-type-identity/spec.md)
- [seeded-scopes](../seeded-scopes/spec.md)
- [containers](../containers/spec.md)
- [factory-templates](../factory-templates/spec.md)
- [visibility-and-access](../visibility-and-access/spec.md)
- [reachability-and-retention](../reachability-and-retention/spec.md)
- [build-plugin-and-wiregen-cli](../build-plugin-and-wiregen-cli/spec.md)
