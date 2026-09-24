# Binding lifetimes

## Purpose

The lifetime macros that make a type its own producer. `@Singleton` and `@Scoped(seed:)` synthesise
the initialiser Wire calls and a `static key`, and WireGen records the type as a binding of the app
partition or of the seed's scope, with its injected members as dependencies. `@Factory(key)` is the
third lifetime macro and is exclusive with the other two. Producers declared with `@Provides` are
specified in [providers](../providers/spec.md), and what `allowUnused:` does in
[reachability-and-retention](../reachability-and-retention/spec.md).

Rationale: [VisibilityModel](../../../Documentation/Notes/VisibilityModel.md).
Documentation: [ScopesAndLifetimes](../../../Sources/Wire/Wire.docc/ScopesAndLifetimes.md), [InjectionPoints](../../../Sources/Wire/Wire.docc/InjectionPoints.md).

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
- [providers](../providers/spec.md)
