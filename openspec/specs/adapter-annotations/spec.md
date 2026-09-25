# Adapter annotations

## Purpose

An adapter annotation is how a third-party package (wire-mvc, wire-open-api, wire-configuration)
teaches Wire one graph edge around a declaration its own attribute sits on, without Wire learning
what the attribute means. This spec covers the `WireAdapterAnnotationV1` carrier and its
`WireAdapterCapability` cases, how WireGen discovers definitions and use-sites, what each capability
makes WireGen synthesise, the scope yields a bridged proxy infers, and the order of the pre-graph
passes. The names of what is synthesised are specified in
[scope-entry-and-generated-names](../scope-entry-and-generated-names/spec.md).

Rationale: [AdapterModel](../../../Documentation/Notes/AdapterModel.md), [WireHummingbirdDesign](../../../Documentation/Notes/WireHummingbirdDesign.md), [MultiModuleComposition](../../../Documentation/Notes/MultiModuleComposition.md).
Documentation: [WritingAnAdapter](../../../Sources/Wire/Wire.docc/WritingAnAdapter.md), [StructuringAnApp](../../../Sources/Wire/Wire.docc/StructuringAnApp.md).

## Requirements

### Requirement: An annotation is declared as a `WireAdapterAnnotationV1` value
The `Wire` module SHALL export `WireAdapterAnnotationV1(annotation:capability:)`, whose
`annotation` is the attribute's spelling without the leading `@`, together with the
`WireAdapterCapability` enum with exactly seven cases (`.contributes(to:)`,
`.contributesProxy(to:proxyTypePrefix:proxyScope:)`,
`.contributesAggregateProxy(to:proxyTypeName:proxyScope:groupedByAttribute:)`,
`.liftsPeersToProxy(proxyTypePrefix:proxyScope:)`, `.injectsFromGraph`,
`.mapsFactoryRoles(roles:)` and `.rewritesInjection(provider:selector:)`), the
`WireProviderSelector` struct with the single factory `.labelled(_:)`, and the `WireProxyScope`
enum with the single case `.singleton`. The carrier SHALL store only `annotation`; the
`capability` argument is not retained at runtime.

#### Scenario: an adapter declares a collating annotation
- **WHEN** an adapter package declares `static let harnessRoute = WireAdapterAnnotationV1(annotation: "HarnessRoute", capability: .contributes(to: RoutingKeys.controllers))`
- **THEN** the declaration compiles against the `Wire` product

Pinned by: `AdapterHarness/Adapter/Sources/WireRouting/HarnessRoute.swift` and `InjectionRewriteHarness/Adapter/Sources/WireHarnessSettings/Settings.swift`, compiled by the `AdapterHarness` and `InjectionRewriteHarness` jobs in `.github/workflows/swift.yml`. That the carrier stores `annotation` and nothing else is pinned by nothing yet.

### Requirement: Definitions are discovered syntactically and recognised by type name
WireGen SHALL recognise a definition as a single-binding `let` or `var` at module scope, or a
`static` one inside a type, whose initialiser is an unqualified call `WireAdapterAnnotationV1(...)`
carrying both an `annotation:` string literal and a `capability:` argument; a module-qualified
`Wire.WireAdapterAnnotationV1(...)` call or a `.init(...)` spelling compiles but is not recognised.
WireGen SHALL read the capability from the written syntax: a key argument is captured as its source
text, `proxyScope:` is not parsed because `.singleton` is its only value, so every proxy capability
is read as `.singleton`, `roles:` is read from an array literal of string literals, and a
`selector:` argument that is not `.labelled` applied to a string literal is read as no selector. A
declaration missing either argument SHALL be ignored. The declaration SHALL never be executed.

#### Scenario: a nested static definition
- **WHEN** a source file declares `enum HummingbirdAdapter { static let route = WireAdapterAnnotationV1(annotation: "HummingbirdRoute", capability: .contributes(to: HummingbirdKeys.routes)) }`
- **THEN** discovery yields an annotation named `HummingbirdRoute` with capability `.contributes(key: "HummingbirdKeys.routes")`

#### Scenario: a bare capability
- **WHEN** a definition is written with `capability: .injectsFromGraph`
- **THEN** discovery yields the `.injectsFromGraph` capability

Pinned by: `Tests/WireGenCoreTests/ContributionAliasTests.swift` (`discoversContributesToForm`), `Tests/WireGenCoreTests/AdapterDependencyTests.swift` (`discoversInjectsDependencyCapability`), and for a `selector: .labelled("source")` definition read from source, `InjectionRewriteHarness/run-injection-rewrite-harness.sh` (`InjectionRewriteHarness/Adapter/Sources/WireHarnessSettings/Settings.swift`). Reading `roles:`, reading a `selector:` that is not `.labelled` applied to a string literal, and ignoring a qualified or `.init` call are pinned by nothing yet.

### Requirement: Definitions reach a consumer from any activated module
The build plugin SHALL pass to WireGen the sources of every Wire-aware library the target directly
depends on, as `--module` for a same-package target and `--external-module` for an external
product, and WireGen SHALL apply a definition found in any of those groups to use-sites in every
group. The defining module and the using module need not be the same.

#### Scenario: an annotation defined in an external package
- **WHEN** a consumer depends on the external `WireRouting` product, which defines `@HarnessRoute` as `.contributes(to: RoutingKeys.controllers)`, and annotates three `@Singleton` types `@HarnessRoute`
- **THEN** `Wire.bootstrap()` collates all three into the `RoutingKeys.controllers` aggregate

Pinned by: `AdapterHarness/run-adapter-harness.sh` (`AdapterHarness/Consumer/Sources/AdapterHarnessConsumer/main.swift`), run by the `AdapterHarness` job in `.github/workflows/swift.yml`.

### Requirement: Use-sites are captured name-agnostically and classified after aggregation
WireGen SHALL capture every attribute on a scope-bound type declaration and on a `@Provides`
function or property as a candidate use-site, tagged with the binding's identity (the qualified
type name, or the provider's access path) and carrying the attribute's arguments verbatim with
their labels. An attribute on a member method that is not `@Provides` SHALL attribute to the
enclosing type. Candidates SHALL be matched against declared annotations by name after all
modules are aggregated, and a candidate matching no declared annotation SHALL have no effect.

#### Scenario: an attribute on a type
- **WHEN** a type is declared `@Singleton @HummingbirdRoute("todos") struct TodoController {}`
- **THEN** a use-site named `HummingbirdRoute` with target identity `TodoController` is captured

#### Scenario: an attribute on a provider function
- **WHEN** a function is declared `@Provides @HummingbirdRoute func makeController() -> TodoController`
- **THEN** a use-site named `HummingbirdRoute` with target identity `makeController` is captured

#### Scenario: an attribute on a route method
- **WHEN** `@Middleware(MyMiddleware.session)` sits on a method of a `@Singleton` controller rather than on the type
- **THEN** the factory demand lands on the controller's binding

Pinned by: `Tests/WireGenCoreTests/ContributionAliasTests.swift` (`capturesAliasUseSitesNameAgnostically`, `capturesAliasUseSitesOnProviderFunctions`, `nonAliasAttributesAreNotInjected`), `Tests/WireGenCoreTests/FactorySynthesisTests.swift` (`routeScopeMiddlewareAttributesToEnclosingController`).

### Requirement: `.contributes(to:)` aliases `@Contributes(to:)`
For each use-site of a `.contributes(to: key)` annotation, WireGen SHALL append a synthetic
contribution to `key` on the matched binding, so the binding flows through the ordinary
multibinding fan-in. No emission specific to the annotation SHALL exist.

#### Scenario: an aliased type
- **WHEN** `@HummingbirdRoute` is declared `.contributes(to: HummingbirdKeys.routes)` and sits on a `@Singleton` type
- **THEN** the type's binding carries a contribution to `HummingbirdKeys.routes`

#### Scenario: an aliased provider
- **WHEN** the same attribute sits on a `@Provides` function
- **THEN** the provider binding carries the contribution

Pinned by: `Tests/WireGenCoreTests/ContributionAliasTests.swift` (`injectsContributionForAliasedBinding`, `injectsContributionForAliasedProvider`), `AdapterHarness/run-adapter-harness.sh`.

### Requirement: `.contributesProxy` synthesises one proxy binding per subject
For each scope-bound subject (`@Singleton` or `@Scoped`) bearing a
`.contributesProxy(to: key, proxyTypePrefix: prefix, proxyScope:)` annotation, WireGen SHALL
synthesise a scope-bound `struct` binding named `<prefix><Subject>`, generic exactly as the subject
and restating its `where` clause, that contributes to `key` in the subject's place. The subject
SHALL receive no contribution. A `@Provides` provider bearing the annotation SHALL receive neither a
proxy nor a contribution. The proxy SHALL be placed in the app (scope-nil) partition of the
subject's container and SHALL be exempt from the dead-binding diagnostic. Where a subject carries
more than one proxy annotation, the last use-site seen SHALL win, which is tracked as a defect in
https://github.com/swift-wire/swift-wire/issues/399.

#### Scenario: a generic controller
- **WHEN** `@Singleton @Controller struct TodosController<Repository: TodoRepository>` is annotated with a `.contributesProxy(to: Keys.routes, proxyTypePrefix: "_WireRouteContributor_", proxyScope: .singleton)` annotation
- **THEN** a binding `_WireRouteContributor_TodosController<Repository: TodoRepository>` is synthesised contributing to `Keys.routes`, and `TodosController` contributes to nothing

#### Scenario: no proxy annotation
- **WHEN** no declared annotation carries `.contributesProxy`
- **THEN** the bindings and use-sites pass through unchanged

Pinned by: `Tests/WireGenCoreTests/ContributorProxySynthesisTests.swift` (`synthesisesGenericProxyBesideController`, `synthesisesNonGenericProxy`, `noProxyAnnotationsLeavesEverythingUnchanged`, `aContributesProxySubjectIsNotRooted`), `Tests/WireGenCoreTests/ContributorProxyEmissionTests.swift` (`restatesSubjectWhereClause`). The dead-binding exemption is pinned for a `.liftsPeersToProxy` proxy by `synthesisedProxyDoesNotWarnAsDead` in `Tests/WireGenCoreTests/ContributorProxySynthesisTests.swift`; for a `.contributesProxy` proxy it is pinned by nothing yet. The provider case and the duplicate-annotation rule are pinned by nothing yet.

### Requirement: A proxy holds a subject at its own scope and bridges into a narrower one
WireGen SHALL compare `proxyScope` against the subject's scope. A `.singleton` proxy over a
subject with no scope key (`@Singleton`) SHALL hold it: the proxy's first dependency is the subject,
unlabelled. A `.singleton` proxy over a `@Scoped(seed:)` subject SHALL bridge: the proxy's first
dependency is a labelled `_wireEnterScope` scope-entry thunk of type
`@Sendable (Seed) async throws -> _WireScopeEntry_<Subject>`, and the subject stays in its seeded
partition. The thunk SHALL be emitted inside the bootstrap body immediately before the proxy's
construction line, constructing only the subject's reachable subgraph per call and returning its
teardown alongside it.

#### Scenario: a request-scoped controller under an app-scoped proxy
- **WHEN** `@Scoped(seed: RequestSeed.self) struct SessionController` bears a `.contributesProxy(…, proxyScope: .singleton)` annotation
- **THEN** the proxy binding's first dependency is named `_wireEnterScope` with type `@Sendable (RequestSeed) async throws -> _WireScopeEntry_SessionController` and the proxy joins the app partition

#### Scenario: two entries through one thunk
- **WHEN** a bridged proxy's `_wireEnterScope` is called twice with different seeds
- **THEN** each call constructs its own subject and returns its own `_wireScopeTeardown`

Pinned by: `Tests/WireGenCoreTests/ContributorProxySynthesisTests.swift` (`bridgesSeededControllerViaScopeEntryThunk`), `Tests/WireGenCoreTests/SeedScopeEmissionTests.swift` (`bridgingProxyEmitsScopeEntryThunkCapturingSingletons`, `scopeEntryThunkPrunesUnreachableBindings`, `scopeEntryThunkTearsDownScopedBindings`), `Tests/IntegrationTests/AsyncScopeEntryTests.swift` (`eachEntryGetsItsOwnScopeAndItsOwnTeardown`).

### Requirement: A bridging proxy is ordered after the singletons its thunk captures
For every singleton a bridged subject's scope genuinely borrows, WireGen SHALL add a
`.scopeCapture` dependency to the proxy, resolved by the graph for ordering but never emitted as a
field or construction argument. A borrow reached only through a generic scope binding's
constrained parameter SHALL count as used.

#### Scenario: a proxy over a scope that borrows a repository
- **WHEN** a bridged subject depends on the app singleton `TodoRepository`
- **THEN** the proxy gains a `.scopeCapture` dependency on `TodoRepository` and sorts after it

Pinned by: `Tests/WireGenCoreTests/SeedScopeOrchestrationTests.swift` (`bridgeProxyResolvesAndSortsAfterItsBorrowedSingleton`, `bridgeProxyCapturesBorrowReachedThroughAGenericScopeBinding`).

### Requirement: Input edges on a proxied subject are lifted onto its proxy
After proxies are synthesised, WireGen SHALL re-point every `.injectsFromGraph` use-site whose
target is a proxied subject at that subject's proxy, so the adapter-dependency and
factory-synthesis passes append their edges to the proxy and the subject stays a plain binding.

#### Scenario: a middleware factory on a proxied controller
- **WHEN** `@Middleware(Keys.session)` sits on a controller that has a contributor proxy
- **THEN** the `_wireFactory_Keys_session` dependency is appended to the proxy and not to the controller

Pinned by: `Tests/WireGenCoreTests/ContributorProxySynthesisTests.swift` (`reattributesFactoryUseSitesToProxy`, `factorySynthesisLandsFactoryEdgeOnProxyNotController`).

### Requirement: `.contributesAggregateProxy` synthesises one proxy per group
For a `.contributesAggregateProxy(to: key, proxyTypeName: name, proxyScope:, groupedByAttribute:
label)` annotation, WireGen SHALL partition its use-sites by the value of the argument labelled
`label` (a string literal's quotes stripped) and, for a use-site without that argument, by the
module the attribute is written in. Each group SHALL yield one `struct` binding named
`<name>_<group>` with the group sanitised to letters, digits and `_`, holding every scope-bound
subject in the group as a labelled dependency, each held or bridged by its own scope. With exactly one subject the
dependency SHALL be positional (held) or labelled `_wireEnterScope` (bridged), exactly as
`.contributesProxy` produces. Generic parameters SHALL be the union of the subjects', renamed with
a numeric suffix on collision.

#### Scenario: three subjects in one group
- **WHEN** two `@Singleton` controllers and one `@Scoped(seed:)` controller are annotated `@Aggregate(spec: "alpha")`
- **THEN** one binding `_WireAggregateContributor_alpha` is synthesised with fields `_wireSubject_AggregateReportController`, `_wireSubject_AggregateSearchController` and `_wireEnterScope_AggregateTaskController`, and the multibinding receives one element for the three subjects

#### Scenario: a second group value
- **WHEN** another controller is annotated `@Aggregate(spec: "beta")`
- **THEN** a separate `_WireAggregateContributor_beta` binding is synthesised

#### Scenario: a one-subject group
- **WHEN** a group has exactly one held subject
- **THEN** the proxy's field is `_wireSubject`, taken positionally

Pinned by: `Tests/IntegrationTests/AggregateProxyContributorTests.swift` (`oneProxyHoldsEveryAnnotatedSubject`, `aBridgedSubjectIsBuiltPerRequestWhileHeldPeersAreShared`, `aSecondGroupOnTheSameAnnotationGetsItsOwnProxy`, `aOneSubjectAggregateKeepsTheSingularFieldName`, `perRootReachabilitySurvivesTheAggregate`), `GoldenHarness/Golden/_WireGraph.swift.golden`. The module-named default group is pinned by `aOneSubjectAggregateKeepsTheSingularFieldName` (`_WireSoloAggregateContributor_IntegrationTests`) and the golden file.

### Requirement: `.liftsPeersToProxy` synthesises an addressable proxy that contributes to nothing
For each subject bearing a `.liftsPeersToProxy(proxyTypePrefix: prefix, proxyScope:)` annotation,
WireGen SHALL synthesise the same `<prefix><Subject>` proxy as `.contributesProxy` with an empty
contribution list, and SHALL mark the subject `allowUnused` so the graph stores it for the
adapter's generated code to read.

#### Scenario: a composition root with global middleware
- **WHEN** `@Singleton @WireMVCBootstrap struct AppBootstrap` bears a `.liftsPeersToProxy(proxyTypePrefix: "_WireGlobalMiddleware_", proxyScope: .singleton)` annotation and a `@Middleware(Keys.factory)` peer
- **THEN** `_WireGlobalMiddleware_AppBootstrap` is synthesised holding `AppBootstrap` positionally, contributing to no key, with the `_wireFactory_Keys_factory` edge on the proxy and nothing injected onto `AppBootstrap`

Pinned by: `Tests/WireGenCoreTests/LiftsPeersToProxyTests.swift` (`synthesisesAddressableProxyContributingToNothing`, `liftsGlobalMiddlewareFactoryOntoTheProxyNotTheRoot`), `Tests/WireGenCoreTests/ContributorProxySynthesisTests.swift` (`aLiftsPeersToProxySubjectIsRootedSoTheGraphStoresIt`).

### Requirement: `.injectsFromGraph` dispatches on the argument's kind
For a use-site `@X(argument)` of an `.injectsFromGraph` annotation on a scope-bound binding,
WireGen SHALL append an init-time dependency chosen by the argument: `T.self` appends an unkeyed
dependency on `T` named `_wire<T>` (the simple type name, generics and namespace stripped, first
letter upper-cased); a reference matching a discovered `BindingKey<T>` appends a dependency on `T`
keyed by that reference and named `_wire<sanitised key>`; any other reference is left to factory
synthesis. Providers and aggregates SHALL receive no dependency. An annotation of another
capability SHALL inject nothing.

#### Scenario: a by-type argument
- **WHEN** a controller is annotated `@Middleware(SessionMiddlewareFactory.self)`
- **THEN** the controller's binding gains a dependency on `SessionMiddlewareFactory` named `_wireSessionMiddlewareFactory`

#### Scenario: a binding-key argument
- **WHEN** a controller is annotated `@Middleware(Gates.primary)` and `Gates.primary` is a `BindingKey<AuthGate>`
- **THEN** the binding gains a dependency on `AuthGate` keyed `Gates.primary` and named `_wireGates_primary`

#### Scenario: a factory-key argument
- **WHEN** the argument is `Keys.session` and no `BindingKey` of that name exists
- **THEN** the adapter-dependency pass appends nothing

Pinned by: `Tests/WireGenCoreTests/AdapterDependencyTests.swift` (`injectsSynthesizedDependency`, `injectsKeyedDependencyForBindingKeyArgument`, `leavesFactoryKeyArgumentToFactorySynthesis`, `contributesCapabilityInjectsNoDependency`, `capturesUseSiteArgument`).

### Requirement: A factory-key argument synthesises a factory from the matching template
For every `.injectsFromGraph` use-site whose argument is not a `.self` reference and matches a
`@Factory(key)` template, WireGen SHALL synthesise one factory per distinct key, register its
binding once in every partition that consumes it, and append a dependency named
`_wireFactory_<sanitised key>` of the factory's type to each consuming binding, deduplicated per
key per consumer. A key with no matching template SHALL synthesise nothing.

#### Scenario: two consumers of one key
- **WHEN** two controllers each carry `@Middleware(MyMiddleware.session)` and a `@Factory(MyMiddleware.session)` template exists
- **THEN** exactly one `_WireFactory_MyMiddleware_session` binding is registered in the partition and both controllers gain a `_wireFactory_MyMiddleware_session` dependency

#### Scenario: a key without a template
- **WHEN** `@Middleware(Keys.unknown)` names a key no `@Factory` declares
- **THEN** no factory is synthesised and no edge is appended

Pinned by: `Tests/WireGenCoreTests/FactorySynthesisTests.swift` (`synthesizesOneFactoryPerConsumedKeyDeduped`, `concreteSelfArgumentSynthesizesNoFactory`, `keyWithoutMatchingTemplateSynthesizesNoFactory`, `appendsFactoryEdgeAndRegistersBinding`, `registersFactoryBindingOncePerPartitionDespiteMultipleConsumers`, `nonFactoryCapabilityIsIgnored`, `synthesisFromDiscoveredSource`).

### Requirement: `.mapsFactoryRoles(roles:)` supplies the order of a factory's assisted parameters
WireGen SHALL join a `.mapsFactoryRoles(roles:)` use-site to the `@Factory` template of the type
it sits on. A bare `@X` SHALL map the template's assisted generic parameters (those not appearing
in any `@Inject` dependency's type) to `roles` by position; `@X(.a, .b, …)` SHALL map them to the
listed roles, each referenced as `.` followed by the role name with its first letter lower-cased.
The synthesised `create` SHALL be generic over every canonical role in the declared order, with a
role no parameter maps to left as a phantom parameter. For a template in the consumer's own
module with an assisted parameter left unmapped, WireGen SHALL report an error
`@Factory '<Template>': assisted generic parameter '<P>' has no role. The role mapping must assign one role per assisted parameter (a bare mapping assigns them in order; the custom form lists a role per parameter).`
A template with no visible mapping SHALL keep a positional `create` and SHALL NOT be validated.

#### Scenario: a reordered custom mapping
- **WHEN** a template `Reordered<S, R, C>` is annotated `@MiddlewareFactory(.responseSender, .reader, .requestContext)` against roles `["RequestContext", "Reader", "ResponseSender"]`
- **THEN** `create<RequestContext, Reader, ResponseSender>(_: RequestContext.Type, _: Reader.Type, _: ResponseSender.Type) -> Reordered<ResponseSender, Reader, RequestContext>` is emitted

#### Scenario: an unrecognised role reference
- **WHEN** the custom list names a role that is not in `roles`
- **THEN** the parameter is unmapped and the error above is reported at the template

Pinned by: `Tests/WireGenCoreTests/FactoryRoleMappingTests.swift` (`bareMappingIsPositional`, `customMappingReorders`, `customMappingSubsets`, `assistedParametersExcludeInjected`, `joinsMappingToTemplateByTypeIdentity`, `validatesEveryAssistedParameterHasARole`, `unrecognisedRoleReferenceIsAnError`, `validMappingHasNoDiagnostics`, `templateWithoutMappingIsNotValidated`, `rendersCanonicalRoleOrderedCreate`, `rendersReorderedCreate`, `rendersSubsetCreateWithPhantomRole`).

### Requirement: A `.rewritesInjection` site is any non-Wire attribute at an injection point
WireGen SHALL capture, on an `@Inject` init parameter, an `@Inject` property or a `@Provides`
function parameter, the first attribute whose name is not `Bind`, `Inject`, `Provides` or
`Teardown`, with its arguments split by label but otherwise verbatim, and SHALL treat it as a
rewrite only if a declared `.rewritesInjection` annotation has that name. A dependency without
such an attribute, or whose attribute matches no declared annotation, SHALL be untouched.

#### Scenario: an undeclared attribute
- **WHEN** a parameter is annotated `@Unrelated("x")` and no `.rewritesInjection` annotation is named `Unrelated`
- **THEN** the dependency resolves by its own type as before

Pinned by: `Tests/WireGenCoreTests/InjectionRewriteTests.swift` (`anUnannotatedDependencyIsUntouched`, `anUndeclaredAnnotationIsNotARewrite`, `noRewritingAnnotationsIsANoOp`) for classification against declared annotations; `InjectionRewriteHarness/run-injection-rewrite-harness.sh` (`InjectionRewriteHarness/Consumer/Sources/InjectionRewriteHarnessConsumer/main.swift`) for capture at all three site kinds, including an `@Inject @FromSettings` property whose `Inject` is skipped. Skipping `Bind`, `Provides` and `Teardown` is pinned by nothing yet.

### Requirement: A rewritten site resolves to a synthesised keyed producer
For a site of type `T` annotated `@X(<args>)` under a `.rewritesInjection(provider: P)`
annotation, WireGen SHALL synthesise
`private func _wireRewrite_<suffix>(_wireProvider: P) throws -> T { try _wireRewritten(X<T>.wireValue(from: _wireProvider, <args>)) }`
with `<args>` copied verbatim after `from:`, emit the helper
`private func _wireRewritten<Value>(_ value: @autoclosure () throws -> Value) throws -> Value` once
per generated file, register the producer as a throwing function provider in the app partition
keyed `_wireRewriteKey_<suffix>`, and re-point the site's dependency at that key so it cannot
match a plain binding of `T`.

#### Scenario: a defaulted string site
- **WHEN** a `@Provides` function declares `@Configuration(forKey: "a", default: "x") host: String` under a `.rewritesInjection(provider: "ConfigReader")` annotation
- **THEN** the producer's body is `try _wireRewritten(Configuration<String>.wireValue(from: _wireProvider, forKey: "a", default: "x"))` and its parameter is `_wireProvider: ConfigReader`

#### Scenario: the site's dependency
- **WHEN** the same site is inspected after the pass
- **THEN** its dependency keeps type `String` and carries the producer's `keyIdentifier`

Pinned by: `Tests/WireGenCoreTests/InjectionRewriteTests.swift` (`synthesisesAProducerCallingTheWrappersOwnValue`, `theProducerCarriesATryThatIsCorrectEitherWay`, `theHelperIsPrivateAndAlwaysThrowing`, `theAnnotatedSiteResolvesToTheSynthesisedProducer`), `InjectionRewriteHarness/run-injection-rewrite-harness.sh` (`InjectionRewriteHarness/Consumer/Sources/InjectionRewriteHarnessConsumer/main.swift`).

### Requirement: Rewrite producers are deduplicated by annotation, provider key, arguments and type
WireGen SHALL synthesise one producer per distinct (annotation name, selected provider key,
rendered arguments, canonical value type), and SHALL anchor the producer at the first site
encountered, in source order within a partition; the order across partitions is unspecified.

#### Scenario: the same site written twice
- **WHEN** `@Configuration(forKey: "a", default: "x") value: String` appears at two injection points
- **THEN** one producer is synthesised

#### Scenario: the same key at a different type
- **WHEN** `forKey: "PORT"` is written once at `Int` and once at `String`
- **THEN** two producers are synthesised

#### Scenario: the same arguments from different providers
- **WHEN** two sites select different provider keys through the declared selector and are otherwise identical
- **THEN** two producers are synthesised

Pinned by: `Tests/WireGenCoreTests/InjectionRewriteTests.swift` (`identicalSitesShareOneProducer`, `differentArgumentsOrTypesStayDistinct`, `sameArgumentsFromDifferentProvidersAreDistinctBindings`), and `theSynthesisedProviderIsAnchoredAtARealSite` for the producer taking a site's location. That every deduplicated site is re-keyed to the shared producer, and that the anchor is the first such site, are pinned by nothing yet.

### Requirement: A selector names the provider by argument label
When an annotation declares `selector: .labelled(L)`, WireGen SHALL remove the site argument
labelled `L` from the spliced argument list and use its text as the key of the producer's
`_wireProvider` dependency. Without a declared selector, or at a site that does not write the
label, the provider dependency SHALL be unkeyed and every argument SHALL be spliced.

#### Scenario: a selected reader
- **WHEN** `@ConfigProperty(reader: ConfigKeys.testReader, forKey: "PORT")` is written under `selector: .labelled("reader")`
- **THEN** the producer depends on the provider keyed `ConfigKeys.testReader` and the call is `wireValue(from: _wireProvider, forKey: "PORT")`

#### Scenario: a label that is not the declared selector
- **WHEN** no selector is declared and a site writes `reader: ConfigKeys.testReader`
- **THEN** `reader: ConfigKeys.testReader` is spliced into the call like any other argument

Pinned by: `Tests/WireGenCoreTests/InjectionRewriteTests.swift` (`aDeclaredSelectorKeysTheProviderAndLeavesTheArgumentList`, `anUndeclaredSelectorLabelIsJustAnArgument`, `omittingTheSelectorLeavesTheProviderUnkeyed`), `InjectionRewriteHarness/run-injection-rewrite-harness.sh`.

### Requirement: Scope yields are inferred from a bridged subject's parameter attributes
For a bridged subject, WireGen SHALL yield through its scope entry every binding in the subject's
own seed partition whose type name equals an attribute written on a parameter of one of the
subject's methods, or, when the attribute is not itself a binding, the type the attribute's own
`.injectsFromGraph(T.self)` use-site names (one hop, direct match preferred). The subject SHALL
never yield itself. Yields SHALL be deduplicated and sorted by type name, and each SHALL be a
construction root of the thunk. A subject that is not scoped SHALL yield nothing.

#### Scenario: a parameter naming a scope binding
- **WHEN** a `@Scoped(seed: RequestSeed.self)` controller declares `func route(@AuthorizedDocument document: …)` and `AuthorizedDocument` is bound in the same seed
- **THEN** `_WireScopeEntry_<Controller>` gains a field `authorizedDocument: AuthorizedDocument`

#### Scenario: a wrapper attribute naming a worker
- **WHEN** the parameter attribute is `@Attribute`, which is not a binding but whose declaration carries `@X(Worker.self)` under an `.injectsFromGraph` annotation, and `Worker` is bound in the seed
- **THEN** `Worker` is yielded

#### Scenario: two routes naming the same binding
- **WHEN** two methods each take a parameter annotated with the same scope binding
- **THEN** the entry struct has one field for it

Pinned by: `Tests/WireGenCoreTests/ScopeYieldTests.swift` (`aParameterNamingAScopeBindingIsTheRequest`, `anAttributeThatIsNoBindingIsIgnored`, `aBindingInAnotherScopeIsNotYielded`, `anUnscopedSubjectYieldsNothing`, `aSubjectNeverYieldsItself`, `yieldsAreDeduplicatedAndOrderedByTypeName`, `aYieldIsAConstructionRootAndPullsItsOwnSubgraphIn`, `withoutTheYieldNeitherIsConstructed`, `anAttributeThatIsNotABindingYieldsWhatItsDeclarationNames`, `aDirectMatchIsPreferredOverTheHop`, `theHopIsFollowedOnlyOnce`, `anArgumentThatIsNotATypeReferenceIsNoHop`, `aRouteParameterIsDetectedThroughDiscoveryAndSynthesis`).

### Requirement: A yield the subject's scope cannot construct is an error
WireGen SHALL report, once per (subject, binding), a parameter attribute on a member method that
is not `@Provides` of any scope-bound type, whether or not that type bears a proxy annotation, when
the attribute names a `@Scoped` binding outside the type's own seed partition. Firing on a type with
no proxy annotation is tracked as a defect in https://github.com/swift-wire/swift-wire/issues/400.
For a subject with no scope the message SHALL be
`<B> is bound in @Scoped(seed: <S>.self), but '<Subject>' is not scoped — its contributor proxy holds it directly and enters no scope, so there is nothing to construct it in. Mark '<Subject>' @Scoped(seed:) with the same seed.`
For a subject in a different seed the message SHALL be
`<B> is bound in @Scoped(seed: <S>.self), but '<Subject>' is in @Scoped(seed: <T>.self) — sibling seeded scopes are isolated by design, so its scope entry constructs only its own. Bind it in @Scoped(seed: <T>.self), or move '<Subject>' to the other seed.`
`<B>` SHALL be `'<Binding>'`, or, when the binding was reached through a hop,
`'<Binding>' (named by '@<Attribute>')`. Both messages assume a proxy, whether or not the type has
one. An attribute naming no binding anywhere SHALL be silent.

#### Scenario: an unscoped controller asking for a request binding
- **WHEN** a `@Singleton` `DocumentsController` declares a parameter `@AuthorizedDocument` and `AuthorizedDocument` is `@Scoped(seed: RequestSeed.self)`
- **THEN** an error at the parameter contains `'DocumentsController' is not scoped`

#### Scenario: a sibling seed
- **WHEN** `DocumentsController` is `@Scoped(seed: RequestSeed.self)` and `AuthorizedDocument` is `@Scoped(seed: OtherSeed.self)`
- **THEN** an error at the parameter contains `sibling seeded scopes are isolated`

Pinned by: `Tests/WireGenCoreTests/ScopeYieldTests.swift` (`aScopeBindingAskedForByAnUnscopedControllerIsRefused`, `aScopeBindingFromASiblingSeedIsRefused`, `anAttributeThatIsNoBindingIsNeverReported`, `aYieldThatWorksIsSilent`, `oneMistakeIsReportedOnceAcrossSeveralRoutes`, `aHoppedBindingInTheWrongScopeNamesBothTypes`).

### Requirement: The pre-graph passes run in a fixed order
Before any graph is built, WireGen SHALL apply the adapter passes in this order: injection
rewrites, then contribution aliases, then contributor and aggregate proxy synthesis (with
input-edge reattribution), then adapter dependencies, then factory synthesis. Each pass SHALL
consume the previous pass's output.

#### Scenario: a factory demanded by a proxied subject
- **WHEN** a subject has both a `.contributesProxy` annotation and a `@Middleware(key)` factory demand
- **THEN** the factory edge is appended to the proxy synthesised in the earlier pass

Pinned by: `Tests/WireGenCoreTests/ContributorProxySynthesisTests.swift` (`factorySynthesisLandsFactoryEdgeOnProxyNotController`) for proxies before factory synthesis. The full order is pinned by nothing yet.

### Requirement: The contract has a public tier and an SPI tier
The package SHALL treat `WireAdapterAnnotationV1`, `WireAdapterCapability`,
`WireProviderSelector`, `WireProxyScope`, `WireGraphConformanceV1`, the key types,
`Introspectable`, `Teardownable` and `@Teardown` as public API, where a breaking change is a major
version, and SHALL treat the names and shape of generated proxies, the generated bootstrap
structure, plugin internals and the scope-entry types an adapter's codegen reads as SPI, free to
change within a major version. A change to the carrier's shape SHALL ship as a new
`WireAdapterAnnotationV2` type beside `WireAdapterAnnotationV1`; adding a capability SHALL add a
case without a new carrier type.

#### Scenario: an adapter built against the public tier
- **WHEN** an adapter declares only `WireAdapterAnnotationV1` values and reads its products through a `WireGraphConformanceV1`
- **THEN** a change to generated proxy field names does not break it

Pinned by: nothing yet.

## Related specifications

- [scope-entry-and-generated-names](../scope-entry-and-generated-names/spec.md)
- [multibindings](../multibindings/spec.md)
- [factory-templates](../factory-templates/spec.md)
- [seeded-scopes](../seeded-scopes/spec.md)
- [binding-identity-and-keys](../binding-identity-and-keys/spec.md)
- [multi-module-composition](../multi-module-composition/spec.md)
- [graph-conformance](../graph-conformance/spec.md)
- [reachability-and-retention](../reachability-and-retention/spec.md)
- [teardown](../teardown/spec.md)
- [testing-variants](../testing-variants/spec.md)
- [build-plugin-and-wiregen-cli](../build-plugin-and-wiregen-cli/spec.md)
- [wire-mvc route-builder-contract](https://github.com/swift-wire/wire-mvc/blob/main/openspec/specs/route-builder-contract/spec.md)
- [wire-open-api controller-collation](https://github.com/swift-wire/wire-open-api/blob/main/openspec/specs/controller-collation/spec.md)
- [wire-configuration config-property](https://github.com/swift-wire/wire-configuration/blob/main/openspec/specs/config-property/spec.md)
