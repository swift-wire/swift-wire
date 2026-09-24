# Containers

## Purpose

A `@Container` groups bindings under a named type into a graph of their own, built beside the
default graph and selected whole at the entry point: a container's bindings are the graph for that
run, with no overlay of the module's other bindings. This spec states how WireGen assigns bindings
to a container, merges every `@Container` declaration of one name, keeps each container's graph
separate from the default graph and from other containers, gives a container its own seed scopes,
and diagnoses the combinations that do not do what they look like. The generated graph struct and
entry-point names are specified in
[scope-entry-and-generated-names](../scope-entry-and-generated-names/spec.md), and a `@Provides` in
a plain `extension` of a container, which falls through to the default graph with a warning, in
[providers](../providers/spec.md).

Documentation: [ProvidingValues](../../../Sources/Wire/Wire.docc/ProvidingValues.md), [HowWireCompares](../../../Sources/Wire/Wire.docc/HowWireCompares.md).

## Requirements

### Requirement: The `@Container` macro is an argumentless marker
`@Container()` SHALL be an attached peer macro implemented by `ContainerMacro` that takes no
arguments and whose expansion returns no peers and emits no diagnostics, on an `enum`, `struct`,
`class`, `actor` or `extension`.

#### Scenario: an extension
- **WHEN** `@Container extension TestContainer { @Provides static let extra: Extra = Extra() }` is expanded
- **THEN** the expanded source is the extension with the attribute removed and nothing added

#### Scenario: an actor
- **WHEN** `@Container actor RuntimeConfig` is expanded
- **THEN** the expanded source is the actor with the attribute removed and nothing added

Pinned by: `Tests/WireMacrosImplTests/ContainerMacroTests.swift` (`test_containerOnEmptyEnum_producesNoPeers`, `test_containerOnEnumWithStaticProperty_producesNoPeers`, `test_containerOnEnumWithStaticFunc_producesNoPeers`, `test_containerOnEnumWithNestedType_producesNoPeers`, `test_containerOnExtension_producesNoPeers`, `test_containerOnStruct_producesNoPeers`, `test_containerOnClass_producesNoPeers`, `test_containerOnActor_producesNoPeers`).

### Requirement: Bindings declared inside a container belong to it
WireGen SHALL record every `@Provides`, `@Singleton` and `@Scoped(seed:)` binding declared inside a
`@Container` declaration, including inside a nested type that carries no `@Container` itself, in a
partition whose `container` is the container's name. The binding's access path and qualified type
name SHALL carry the enclosing type names.

#### Scenario: a static provider
- **WHEN** `@Container enum TestContainer { @Provides static let logger: Logger = Logger() }` is discovered
- **THEN** the default partition is empty and `TestContainer`'s holds a provider with access path `TestContainer.logger`

#### Scenario: a nested singleton
- **WHEN** `@Singleton struct MockService` is declared inside `@Container enum TestContainer`
- **THEN** it is recorded in `TestContainer`'s partition with `qualifiedTypeName` `TestContainer.MockService`

#### Scenario: a helper type inside a container
- **WHEN** `struct Helper { @Provides static let value: Value = Value() }` is nested in `@Container enum TestContainer`
- **THEN** it is recorded in `TestContainer`'s partition with access path `TestContainer.Helper.value`

Pinned by: `Tests/WireGenCoreTests/DiscoveryTests.swift` (`providesInsideContainerRoutedToContainerBucket`, `nestedSingletonInsideContainerRoutedToContainerBucket`, `providesInsideHelperTypeNestedInContainerStillRoutesToContainer`, `containerOnStructRoutesBindingsToContainer`, `containerOnClassRoutesBindingsToContainer`, `containerOnActorRoutesBindingsToContainer`).

### Requirement: A type without `@Container` does not open a container
A `@Provides` declared as a `static` member of a type that neither carries `@Container` nor is
nested in one SHALL be recorded in the default graph.

#### Scenario: a configuration namespace
- **WHEN** `enum Config { @Provides static let baseURL: URL = URL(string: "...")! }` is discovered
- **THEN** it is a default-graph binding and no container partition exists

Pinned by: `Tests/WireGenCoreTests/DiscoveryTests.swift` (`bindingsInNonContainerEnclosingTypeStayInDefaultGraph`).

### Requirement: Every `@Container` declaration of one name merges into one container
WireGen SHALL key a container by the declared or extended type's name, so that a primary
`@Container` declaration and every `@Container extension` of the same name, in any file of the
module, contribute to one container and one graph. A `@Container extension` SHALL contribute even
when no primary declaration carries `@Container`.

#### Scenario: a primary declaration and an annotated extension
- **WHEN** `@Container enum TestContainer` provides `logger` and `@Container extension TestContainer` provides `extra`
- **THEN** `TestContainer`'s partition holds `TestContainer.logger` and `TestContainer.extra` and the default partition is empty

#### Scenario: across files
- **WHEN** `TestContainer.swift` declares `@Container enum TestContainer` with `banner` and `MockBannerService`, and `TestContainer+Extra.swift` declares `@Container extension TestContainer` with `testMode`
- **THEN** `Wire.bootstrapTestContainer()` returns a graph whose `testMode.value` is `"integration-test"` and whose `banner.text` is `"test container"`

#### Scenario: an extension alone
- **WHEN** only `@Container extension SomeType { @Provides static let value: Value = Value() }` is declared
- **THEN** `SomeType`'s partition holds that provider

Pinned by: `Tests/WireGenCoreTests/DiscoveryTests.swift` (`providesInContainerAnnotatedExtensionMergesIntoContainer`, `containerAnnotatedExtensionWithoutPrimaryDeclarationStillContributes`, `containerAnnotatedExtensionProvidesIsNotACandidate`), `Tests/IntegrationTests/TestContainer.swift`, `Tests/IntegrationTests/TestContainer+Extra.swift`, `Tests/IntegrationTests/BootstrapTests.swift` (`testContainerProducesWiredGraphFromOwnBindings`), `GoldenHarness/Golden/_WireGraph.swift.golden`.

### Requirement: A container's graph is built from its own bindings only
WireGen SHALL build each container's graph from that container's singleton partition alone, and
SHALL NOT include module-scope bindings or another container's bindings in it. The default graph
SHALL likewise include no container's bindings. The container's graph is entered through
`Wire.bootstrap<Name>()` and the default graph through `Wire.bootstrap()`, so selecting one is
selecting its whole binding set.

#### Scenario: the same type bound in both
- **WHEN** the default graph builds `Banner` through `makeBanner(appName:buildNumber:)` and `TestContainer` provides a fixed `Banner`
- **THEN** `Wire.bootstrap()` yields `banner.text == "IntegrationTests #42"` and `Wire.bootstrapTestContainer()` yields `banner.text == "test container"`

#### Scenario: the emitted container graph
- **WHEN** the integration module declares module-scope bindings and `TestContainer`
- **THEN** `_TestContainerWireGraph` stores exactly `banner`, `mockBannerService` and `testMode`

#### Scenario: two containers
- **WHEN** `ProdContainer` and `TestContainer` each provide a `Logger`
- **THEN** each partition holds one binding and the default partition is empty

Pinned by: `Tests/IntegrationTests/BootstrapTests.swift` (`testContainerProducesWiredGraphFromOwnBindings`, `defaultGraphAndTestContainerAreIndependent`), `Tests/WireGenCoreTests/DiscoveryTests.swift` (`mixedContainerAndModuleScopeBindingsArePartitioned`, `multipleContainersProduceIndependentBuckets`), `GoldenHarness/Golden/_WireGraph.swift.golden`.

### Requirement: Reaching into a container from outside is a missing binding with a note
When a binding outside a container depends on a type bound only inside one, WireGen SHALL report
`error: no binding produces '<Type>'`, a note `'<Type>' is bound in @Container <Name> scope, not
<consumer scope>` at the binding, and the note "container graphs are atomic; '<consumer>' can't
reach bindings declared inside a different container — move the binding or activate the right
graph". When several containers bind the type, it SHALL add one `is also bound in` note per further
container, in container-name order, and the note "'<consumer>' can't reach any of the listed scopes;
consolidate the binding into a single reachable scope or extract the cross-scope concern into a
wrapper".

#### Scenario: a singleton storing a container's type
- **WHEN** `@Singleton struct Foo` injects `TestContainer.Logger`, a `@Singleton` nested in `@Container enum TestContainer`
- **THEN** the output contains `note: 'TestContainer.Logger' is bound in @Container TestContainer scope, not @Singleton` and `container graphs are atomic`

#### Scenario: two containers bind it
- **WHEN** `Alpha` and `Beta` both provide `Logger` and `@Singleton struct Foo` injects `Logger`
- **THEN** the output contains `note: 'Logger' is bound in @Container Alpha scope, not @Singleton`, then `note: 'Logger' is also bound in @Container Beta scope`, and `consolidate the binding into a single reachable scope`

Pinned by: `Tests/WireGenCoreTests/CrossScopeDiagnosticsTests.swift` (`singletonStoringContainerBindingRendersCrossScopeNote`, `sameTypeBoundInMultipleContainersListsAllAsNotes`).

### Requirement: Containers are flat
The `@Container` macro SHALL take no argument naming another container, and WireGen SHALL give a
`@Container` declaration nested in another container a container of its own, named by its simple
name, whose graph includes none of the outer container's bindings and is included in none of its.

#### Scenario: a container nested in a container
- **WHEN** `@Container enum Inner` is declared inside `@Container enum Outer`
- **THEN** bindings inside `Inner` are recorded under container `Inner`, and `Outer`'s graph does not hold them

Pinned by: nothing yet.

### Requirement: A container has its own seed scopes
A `@Scoped(seed:)` binding inside a container SHALL belong to that container's seed scope, which is
distinct from the default graph's scope for the same seed and from every other container's, and
which borrows only that container's singletons, as specified in
[seeded-scopes](../seeded-scopes/spec.md).

#### Scenario: one key, two partitions of one container
- **WHEN** `WidgetContainer` has a singleton and a `WidgetSeed`-scoped binding both contributing to `WidgetContainer.widgets`
- **THEN** `Wire.bootstrapWidgetContainer()` yields `["singleton"]` and `Wire.bootstrapWidgetContainer_WidgetSeedScope(seed: WidgetSeed(theme: "dark"), widgetContainerWireGraph:)` yields `["scoped:dark"]`

#### Scenario: a container scope entered over its graph
- **WHEN** `TestContainer.JobRunner` is `@Scoped(seed: TestJobSeed.self)`
- **THEN** it is entered through `Wire.bootstrapTestContainer_TestJobSeedScope(seed:testContainerWireGraph:)`, which takes `_TestContainerWireGraph`

Pinned by: `Tests/WireGenCoreTests/DiscoveryTests.swift` (`scopedInsideContainerRoutesToContainerAndSeedPartition`), `Tests/IntegrationTests/ContainerSeedScopeMultibindingExample.swift`, `Tests/IntegrationTests/BootstrapTests.swift` (`containerPartitionsPickTheirOwnContributions`, `containerScopeBootstrapBorrowsFromContainerWireGraph`, `containerMultibindingAggregatesContainerContributors`, `moduleScopeKeyContributedPerContainer`), `Tests/IntegrationTests/ContainerMultibindingExample.swift`, `Tests/IntegrationTests/ProductionTestContainerMultibindingExample.swift`.

### Requirement: `@Container` on a lifetime-annotated type warns
WireGen SHALL warn at the type's name when one declaration carries both `@Container` and
`@Singleton` or `@Scoped`: "'<Type>' carries both @Container and @<Macro> — the two roles end up in
separate graphs. Split into two declarations: a @<Macro> type for the binding, and a separate
@Container type for the grouping."

#### Scenario: a container that is also a singleton
- **WHEN** `Mixed.swift` declares `@Container @Singleton struct Mixed {}` starting on line 1
- **THEN** the rendered output contains `Mixed.swift:3:8: warning: 'Mixed' carries both @Container and @Singleton` and the split advice

#### Scenario: a container that is also scoped
- **WHEN** `@Container @Scoped(seed: RequestSeed.self) struct Mixed {}` is discovered
- **THEN** exactly one warning is reported, containing `'Mixed' carries both @Container and @Scoped`

Pinned by: `Tests/WireGenCoreTests/DiscoveryTests.swift` (`containerCombinedWithSingletonEmitsWarning`, `containerWithScopedWarningFires`, `plainTypeDeclWithoutContainerEmitsNoWarning`), `Tests/WireGenCoreTests/DiagnosticGalleryTests.swift` (`containerWithScopeRendersAsDiagnostic`).

## Related specifications

- [scope-entry-and-generated-names](../scope-entry-and-generated-names/spec.md)
- [seeded-scopes](../seeded-scopes/spec.md)
- [binding-lifetimes](../binding-lifetimes/spec.md)
- [multibindings](../multibindings/spec.md)
- [graph-inputs](../graph-inputs/spec.md)
- [graph-conformance](../graph-conformance/spec.md)
- [reachability-and-retention](../reachability-and-retention/spec.md)
- [multi-module-composition](../multi-module-composition/spec.md)
- [build-plugin-and-wiregen-cli](../build-plugin-and-wiregen-cli/spec.md)
- [testing-variants](../testing-variants/spec.md)
- [providers](../providers/spec.md)
