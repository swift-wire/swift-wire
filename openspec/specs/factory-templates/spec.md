# Factory templates

## Purpose

A factory template is a type annotated `@Factory(key)`, usually generic, whose `@Inject` members are
dependencies resolved from the graph and whose remaining generic parameters are assisted: supplied
per use as metatypes. The template is not a binding. WireGen synthesises one factory,
`_WireFactory_<key>`, for each `FactoryKey` a consumer demands, registers it as a binding carrying
the template's dependencies, and gives consumers a `create` call that constructs the template.
This spec covers the key, template discovery, what a template contributes to the graph, and the
diagnostics particular to templates. The macro expansion and the lifetime exclusion are specified in
[binding-lifetimes](../binding-lifetimes/spec.md), the emitted factory declaration in
[scope-entry-and-generated-names](../scope-entry-and-generated-names/spec.md), and the consumer
use-site and `.mapsFactoryRoles` role mapping in [adapter-annotations](../adapter-annotations/spec.md).

Documentation: [ScopesAndLifetimes](../../../Sources/Wire/Wire.docc/ScopesAndLifetimes.md), [Multibindings](../../../Sources/Wire/Wire.docc/Multibindings.md).

## Requirements

### Requirement: `FactoryKey` is an untyped namespace token
The `Wire` module SHALL export `FactoryKey` as a non-generic `Sendable` struct with the single
initialiser `init()`. Its identity in the graph SHALL be the canonical text of its declaring
reference, which `@Factory(_:)` and consumers both name.

#### Scenario: a key beside its template
- **WHEN** a module declares `enum FactoryProxyKeys { static let probe = FactoryKey() }` and `@Factory(FactoryProxyKeys.probe) struct ProbeMiddleware`
- **THEN** both compile against the `Wire` product and the template is recorded with key reference `FactoryProxyKeys.probe`

Pinned by: `Tests/IntegrationTests/FactoryProxyContributorExample.swift`, `Tests/WireGenCoreTests/FactoryTemplateTests.swift` (`discoversTemplateWithKeyAssistedParamsAndDeps`).

### Requirement: WireGen records a `@Factory` type as a template
WireGen SHALL record each type carrying `@Factory(<key>)` as a factory template with the key
argument's text, the simple and enclosing-qualified type names, the generic parameter names in
declaration order, each parameter's inheritance constraint, the `where`-clause requirements
verbatim without the `where` keyword, its `@Inject` dependencies (extracted as for a `@Singleton`)
and its declared access level. A type without `@Factory` SHALL yield no template.

#### Scenario: a template with three generic parameters
- **WHEN** `@Factory(MyMiddleware.session) struct SessionMiddleware<Ctx, Reader, Sender> { @Inject var store: SessionStore }` is scanned
- **THEN** a template is recorded with key `MyMiddleware.session`, type `SessionMiddleware`, generic parameters `["Ctx", "Reader", "Sender"]` and one dependency of type `SessionStore`

#### Scenario: a `where` clause
- **WHEN** the template is declared `struct Mw<Ctx, Reader> where Reader.ReadElement == UInt8, Reader: ~Copyable`
- **THEN** its recorded `where` clause is `Reader.ReadElement == UInt8, Reader: ~Copyable`

Pinned by: `Tests/WireGenCoreTests/FactoryTemplateTests.swift` (`discoversTemplateWithKeyAssistedParamsAndDeps`, `capturesWhereClause`, `capturesAssistedParameterConstraints`, `nonFactoryTypeYieldsNoTemplate`).

### Requirement: A template is not a binding
WireGen SHALL NOT record a `@Factory` template as a binding in any partition.

#### Scenario: a template alone
- **WHEN** a source file declares only `@Factory(MyMiddleware.session) struct SessionMiddleware<Ctx> { @Inject var store: SessionStore }`
- **THEN** discovery records one factory template and no bindings

Pinned by: `Tests/WireGenCoreTests/FactoryTemplateTests.swift` (`templateIsNotRecordedAsBinding`).

### Requirement: A generic parameter is injected when an `@Inject` dependency's type uses it
WireGen SHALL classify a template's generic parameter as injected when it is, or appears as a
generic argument in, the type of one of the template's `@Inject` dependencies, and as assisted
otherwise. Injected parameters SHALL become the synthesised factory's own generic parameters, making
its binding a lift node; a template with no injected parameter SHALL produce a non-generic factory
binding.

#### Scenario: a concrete dependency
- **WHEN** a template generic over `Ctx, Reader, Sender` injects `APIKeyStore`
- **THEN** all three parameters are assisted

#### Scenario: a generic dependency
- **WHEN** `@Factory(Keys.audit) struct AuditGate<Ctx, Repository: TodoRepository>` injects `repository: Repository`
- **THEN** `Ctx` is assisted and the factory binding is generic over `Repository: TodoRepository` and is a lift node

Pinned by: `Tests/WireGenCoreTests/FactoryRoleMappingTests.swift` (`assistedParametersExcludeInjected`), `Tests/WireGenCoreTests/FactorySynthesisTests.swift` (`factoryBindingIsAGenericLiftNodeOverTheInjectedAxis`, `nonInjectedFactoryStaysNonGeneric`, `rendersFactoryGenericOverInjectedAxisCreateOverAssisted`).

### Requirement: A template contributes nothing to the graph until a consumer demands its key
WireGen SHALL synthesise a factory for a template only when an `.injectsFromGraph` use-site names
the template's key, and SHALL leave the bindings unchanged when none does. A use-site whose argument
ends in `.self` SHALL NOT demand a factory.

#### Scenario: a template with no consumer
- **WHEN** a `MyMiddleware.session` template exists and no use-site names that key
- **THEN** no factory is synthesised and the partition's bindings are unchanged

Pinned by: `Tests/WireGenCoreTests/FactorySynthesisTests.swift` (`noConsumersLeavesBindingsUnchanged`, `concreteSelfArgumentSynthesizesNoFactory`, `keyWithoutMatchingTemplateSynthesizesNoFactory`).

### Requirement: The factory binding carries the template's dependencies
The synthesised `_WireFactory_<sanitised key>` binding SHALL carry the template's `@Inject`
dependencies unchanged, keys included, so they resolve and are constructed as a `@Singleton`'s would
be, once, when the factory is constructed in the consuming partition. `create` SHALL construct the
template from the factory's held values on every call.

#### Scenario: the template's store resolves on the factory
- **WHEN** `AccountController` demands `MyMiddleware.session` and the template injects `SessionStore`
- **THEN** the registered `_WireFactory_MyMiddleware_session` binding depends on `SessionStore`

#### Scenario: a factory held by a scope-entry proxy
- **WHEN** `@Scoped(seed: FactoryProxyRequestSeed.self)` `FactoryProxyRouteController` carries `@RouteMiddleware(FactoryProxyKeys.probe)` and a testing variant enters its scope with a mock repository
- **THEN** the subject's `tag()` returns `"mock:routed"` and teardown reports no errors

Pinned by: `Tests/WireGenCoreTests/FactorySynthesisTests.swift` (`appendsFactoryEdgeAndRegistersBinding`, `synthesisFromDiscoveredSource`), `Tests/IntegrationTests/FactoryProxyContributorTests.swift` (`factoryCarryingProxyEntersScopeWithDoubles`).

### Requirement: Every consumed factory type is emitted internal in the consuming module
WireGen SHALL emit the declaration of every factory the module's graph consumes into that module's
generated file with no access keyword, whichever module declared the template, in ascending order of
key reference.

#### Scenario: an owned and a foreign template
- **WHEN** a graph consumes `Keys.session` from `MyLib` and `Keys.other` from `OtherLib`
- **THEN** it emits `struct _WireFactory_Keys_other: Sendable {` then `struct _WireFactory_Keys_session: Sendable {`, neither `public`

Pinned by: `Tests/WireGenCoreTests/FactorySynthesisTests.swift` (`rendersEveryConsumedFactoryInternalRegardlessOfOriginModule`).

### Requirement: A scoped dependency of a template is reported against the template
When a synthesised factory's dependency is missing from its partition but is bound in a narrower
one, WireGen SHALL name the template, not the synthesised factory, in the missing-binding hint, with
the suggestion
`` '<Template>' is a @Factory template, so it has no scope of its own: it is constructed per `create` call, and its @Inject members resolve once — where the factory Wire synthesises for its key is constructed, in <consumer scope>. A <binding scope> binding can't be one of them. Produce '<Type>' at <consumer scope>, or move the scope-bound concern out of the template and into a binding that lives in the scope. Annotating '<Template>' with a scope is not a move: @Factory is itself a lifetime, and a declaration has one. ``
where `<binding scope>` is the one scope the type is bound in followed by a space, or `a narrower `
when it is bound in several. A declared consumer SHALL keep the ordinary cross-scope advice.

#### Scenario: a template injecting a request-scoped caller
- **WHEN** `@Factory(ControllerMiddleware.screenAccess) struct ScreenAccess<Ctx>` injects `@Scoped(seed: HTTPRequest.self)` `Caller` and `@Singleton` `DocumentsController` carries `@Middleware(ControllerMiddleware.screenAccess)`
- **THEN** the build reports `error: no binding produces 'Caller'` with a hint containing `'ScreenAccess' is a @Factory template`, `A @Scoped(seed: HTTPRequest.self) binding can't be one of them` and `Produce 'Caller' at @Singleton`, and not naming `_WireFactory_ControllerMiddleware_screenAccess`

Pinned by: `Tests/WireGenCoreTests/FactoryLifetimeDiagnosticsTests.swift` (`aTemplateInjectingAScopedBindingIsNamedByTheTemplate`, `theNoteStatesTheConstraintThatActuallyBites`, `theNoteOffersOnlyMovesThatCanBeWritten`, `aDeclaredConsumerStillGetsTheOrdinaryAdvice`).

### Requirement: An unconsumed internal template warns
WireGen SHALL warn at an `internal` template declared in the module being built whose key no
use-site names, reading
`@Factory '<Template>' (key <reference>) is declared but nothing in the build consumes it. Reference it from a consumer, raise it to 'package'/'public' if it's consumed outside this target, or remove it.`
WireGen SHALL NOT warn for a `package` or `public` template or for one declared in another module,
and a use-site argument ending in `.self` SHALL NOT count as consuming a template.

#### Scenario: a dead internal template
- **WHEN** internal `@Factory(Keys.factory) struct RequireAPIKey<Ctx>` is declared and nothing names `Keys.factory`
- **THEN** the warning begins `@Factory 'RequireAPIKey' (key Keys.factory)`

#### Scenario: a public template
- **WHEN** the same template is `public` or `package`
- **THEN** no warning is reported

Pinned by: `Tests/WireGenCoreTests/DeadFactoryDiagnosticsTests.swift` (`internalTemplateWithNoConsumerWarns`, `consumedInternalTemplateIsSilent`, `publicAndPackageTemplatesAreSilent`, `templateOwnedByAnotherModuleIsSkipped`, `aSelfArgumentUseSiteDoesNotCountAsConsuming`).

## Related specifications

- [binding-lifetimes](../binding-lifetimes/spec.md)
- [adapter-annotations](../adapter-annotations/spec.md)
- [scope-entry-and-generated-names](../scope-entry-and-generated-names/spec.md)
- [multibindings](../multibindings/spec.md)
- [binding-identity-and-keys](../binding-identity-and-keys/spec.md)
- [seeded-scopes](../seeded-scopes/spec.md)
- [containers](../containers/spec.md)
- [visibility-and-access](../visibility-and-access/spec.md)
- [reachability-and-retention](../reachability-and-retention/spec.md)
- [testing-variants](../testing-variants/spec.md)
