# Graph conformance

## Purpose

`WireGraphConformanceV1` is the declaration by which an adapter, or an app, has the generated graph
conform to a protocol it owns, with each protocol member witnessed by the product of a multibinding
key. This spec covers how WireGen recognises the declaration, what it emits, which graphs carry the
conformance, the fallback for a member whose key has no aggregate, and the role a conformance plays
in reachability, retention, liveness diagnostics and generated imports.

Rationale: [WireHummingbirdDesign](../../../Documentation/Notes/WireHummingbirdDesign.md).
Documentation: [WritingAnAdapter](../../../Sources/Wire/Wire.docc/WritingAnAdapter.md), [WhatGetsBuilt](../../../Sources/Wire/Wire.docc/WhatGetsBuilt.md).

## Requirements

### Requirement: A conformance is a binding initialised with a bare `WireGraphConformanceV1` call
WireGen SHALL recognise a graph conformance as a single-binding `let` or `var` (the binding
specifier is not checked) whose initialiser is a call spelled with the bare type name
`WireGraphConformanceV1(...)`, at module scope or as a `static` member of a type, and SHALL NOT
recognise an instance property, a module-qualified call such as `Wire.WireGraphConformanceV1(...)`,
an implicit-member initialiser such as `let c: WireGraphConformanceV1 = .init(...)`, or a
declaration whose initialiser calls anything else.

#### Scenario: a static member of an enum
- **WHEN** an enum declares `static let conformance = WireGraphConformanceV1(conformsTo: (any HummingbirdComposable).self, members: [.init("routes", from: HummingbirdKeys.routes), .init("middleware", from: HummingbirdKeys.middleware)])`
- **THEN** discovery yields one conformance with protocol name `HummingbirdComposable`, members `routes` mapped to `HummingbirdKeys.routes` and `middleware` mapped to `HummingbirdKeys.middleware`, stamped with the declaring module

#### Scenario: a module-scope declaration
- **WHEN** a file declares `let c = WireGraphConformanceV1(conformsTo: HummingbirdComposable.self, members: [])` at module scope
- **THEN** discovery yields one conformance with protocol name `HummingbirdComposable` and no members

#### Scenario: an unrelated static declaration
- **WHEN** an enum declares `static let primary = BindingKey<Database>()` and `static let count = 3`
- **THEN** discovery yields no conformance

#### Scenario: a module-qualified call
- **WHEN** an enum declares `static let conformance = Wire.WireGraphConformanceV1(conformsTo: HummingbirdComposable.self, members: [])`
- **THEN** discovery yields no conformance and WireGen emits no `extension _WireGraph: HummingbirdComposable`

Pinned by: `Tests/WireGenCoreTests/GraphConformanceDiscoveryTests.swift` (`capturesProtocolAndMemberMappings`, `plainProtocolMetatypeAlsoWorks`, `nonConformanceDeclarationsIgnored`). The instance-property exclusion, the acceptance of `var`, and the rejection of module-qualified and implicit-member initialisers are pinned by nothing yet.

### Requirement: The protocol and the keys are read as text
WireGen SHALL read the protocol name from the `conformsTo:` metatype expression, accepting both
`P.self` and `(any P).self` as `P`, and SHALL read each `members:` element's unlabelled string
literal as the member name and the canonical text of its `from:` argument as the key reference.
Nothing in the declaration SHALL be executed; the runtime `WireGraphConformanceV1.Member` SHALL
retain only the member name.

#### Scenario: an existential metatype
- **WHEN** the declaration is written `conformsTo: (any HummingbirdComposable).self`
- **THEN** the discovered protocol name is `HummingbirdComposable`

#### Scenario: a member's key reference
- **WHEN** a member is written `.init("routes", from: HummingbirdKeys.routes)`
- **THEN** the discovered member has name `routes` and key reference `HummingbirdKeys.routes`, whether or not `HummingbirdKeys` exists in the parsed sources

Pinned by: `Tests/WireGenCoreTests/GraphConformanceDiscoveryTests.swift` (`capturesProtocolAndMemberMappings`, `plainProtocolMetatypeAlsoWorks`). The runtime carrier's discarding of the key is pinned by nothing yet.

### Requirement: Each conformance is emitted as an extension mapping members to aggregate properties
For each discovered conformance WireGen SHALL emit `extension _WireGraph: <Protocol> { … }` and,
for each member whose key has an aggregate binding in the graph, one
`var <member>: <aggregate product type> { self.<aggregate property> }` inside it.

#### Scenario: a collected key with one contributor
- **WHEN** `App.routes` is a `CollectedKey<any RouteContributor>` with a contributor and a conformance maps `routes` to `App.routes`
- **THEN** the generated file contains `extension _WireGraph: HummingbirdComposable {` and a line beginning `var routes: [any RouteContributor] { self.`

#### Scenario: consumed generically through the protocol
- **WHEN** a test declares `func labels<Graph: GraphComposable>(of graph: Graph)` and passes `try await Wire.bootstrap()` to it
- **THEN** the call compiles and `graph.things` yields the two contributors to `ThingKeys.things`

Pinned by: `Tests/WireGenCoreTests/GraphConformanceEmissionTests.swift` (`emitsExtensionMappingMemberToAggregateProperty`), `Tests/IntegrationTests/GraphConformanceTests.swift` (`generatedGraphConformsAndIsConsumedGenerically`), `GoldenHarness/Golden/_WireGraph.swift.golden`.

### Requirement: No conformance means no extension
WireGen SHALL emit no `extension _WireGraph:` line when the parsed sources declare no
`WireGraphConformanceV1`.

#### Scenario: a graph with bindings but no conformance
- **WHEN** the topological order holds a `@Singleton App` and no conformance is discovered
- **THEN** the generated file contains no `extension _WireGraph:`

Pinned by: `Tests/WireGenCoreTests/GraphConformanceEmissionTests.swift` (`noConformancesEmitNoExtension`).

### Requirement: A member whose key has no aggregate falls back to an empty accessor
When a member's key has no aggregate in the graph, WireGen SHALL emit
`var <member>: [<Element>] { [] }` for a `CollectedKey<Element>` and
`var <member>: [<Key>: <Value>] { [:] }` for a `MappedKey<Key, Value>`, and SHALL omit the member
for a `BuilderKey` or a key it cannot find, without a diagnostic, so the incomplete conformance
fails at compile time unless the protocol supplies a default implementation for that member.

#### Scenario: two collected keys with no contributors
- **WHEN** a conformance maps `routes` to `App.routes` and `services` to `App.services`, both declared `CollectedKey`s with no contributors
- **THEN** the extension contains `var routes: [any RouteContributor] { [] }` and `var services: [any Service] { [] }`

#### Scenario: the empty accessor is consumed at runtime
- **WHEN** `EmptyKeys.things` is a `CollectedKey<any RouteThing<RequestCtx>>` nothing contributes to and a conformance maps `emptyThings` to it
- **THEN** `graph.emptyThings.count` is `0` for `try await Wire.bootstrap()`

Pinned by: `Tests/WireGenCoreTests/GraphConformanceEmissionTests.swift` (`memberWithNoContributorsMapsToEmptyCollection`), `Tests/IntegrationTests/GraphConformanceTests.swift` (`generatedGraphConformsWithEmptyCollectionWhenNoContributors`). The `BuilderKey` and unknown-key omission is pinned by nothing yet.

### Requirement: Conformances are emitted on the default graph and its testing variants only
WireGen SHALL emit every conformance on `_WireGraph` and again on each testing-variant app graph
`_<Variant>WireGraph`, and SHALL NOT emit one on a `@Container` graph.

#### Scenario: a variant app graph
- **WHEN** a `TestingKey` `AppScopedFixture.bindMock` emits a variant app graph and the module declares a conformance to `GraphComposable`
- **THEN** the generated file contains both `extension _WireGraph: GraphComposable {` and `extension _AppScopedFixture_bindMockWireGraph: GraphComposable {`

#### Scenario: a container graph
- **WHEN** the module declares `@Container TestContainer` alongside the same conformance
- **THEN** the generated file contains no `extension _TestContainerWireGraph:`

Pinned by: `GoldenHarness/Golden/_WireGraph.swift.golden`.

### Requirement: An aggregate a conformance names is a reachability root
On the default graph, WireGen SHALL treat every aggregate whose key a conformance member names as a
declared root, so the aggregate and its contributors are retained whether or not anything injects
them. The conformances SHALL NOT be passed as roots when pruning a `@Container` graph.

#### Scenario: a library contributor with no injector
- **WHEN** a library binding `LibraryRoute` contributes to `App.routes`, nothing injects the aggregate, and a conformance maps `routes` to `App.routes`
- **THEN** `LibraryRoute` is reachable and an unrelated library binding is pruned

#### Scenario: an external contributor across a package boundary
- **WHEN** the composition harness consumer declares a conformance mapping `contributors` to the library's `HarnessRouteKeys.contributors`
- **THEN** `(graph as any HarnessComposable).contributors.map(\.label)` is `["external-route"]`

Pinned by: `Tests/WireGenCoreTests/ReachabilityTests.swift` (`conformanceNamedAggregateIsARoot`), `CompositionHarness/Consumer/Sources/WireHarnessConsumer/main.swift` via the `CompositionHarness` job in `.github/workflows/swift.yml`. The `@Container` exclusion is pinned by nothing yet.

### Requirement: An aggregate a conformance names is stored on the graph
The generated graph SHALL keep a stored property for an aggregate a conformance names, since the
emitted member reads it off `self`.

#### Scenario: a collected aggregate with one contributor
- **WHEN** `ServiceKey.services` aggregates `Alpha` and a conformance maps `services` to it
- **THEN** the graph declares `let anyServiceKeyedServiceKeyServices: [any Service]` and `extension _WireGraph: Composable {`

Pinned by: `Tests/WireGenCoreTests/RetentionTests.swift` (`anAggregateAGraphConformanceNamesIsStored`).

### Requirement: A key consumed only by a conformance is live
The multibinding liveness diagnostics SHALL treat a key a conformance member names as consumed, so
an `internal` key with contributors and no `@Inject` consumer raises no dead-key warning.

#### Scenario: an internal key read only through the protocol
- **WHEN** `App.services` is an internal `CollectedKey<any Service>` with a `@Contributes(to: App.services)` singleton and a conformance maps `services` to it
- **THEN** no liveness diagnostic is emitted

Pinned by: `Tests/WireGenCoreTests/MultibindingValidationTests.swift` (`keyConsumedByGraphConformanceIsSilent`).

### Requirement: A conformance is an import source
WireGen SHALL propagate the `import` declarations of any file that declares a conformance into the
generated files, and SHALL add `import <Module>` for each conformance whose origin module is not
the consumer module.

#### Scenario: a conformance declared in a dependency module
- **WHEN** a conformance is discovered in a `--module Adapter` group while the consumer is `App`
- **THEN** the generated `_WireGraph.swift` contains `import Adapter`

Pinned by: nothing yet.

## Related specifications

- [multibindings](../multibindings/spec.md)
- [reachability-and-retention](../reachability-and-retention/spec.md)
- [multi-module-composition](../multi-module-composition/spec.md)
- [adapter-annotations](../adapter-annotations/spec.md)
- [testing-variants](../testing-variants/spec.md)
- [build-plugin-and-wiregen-cli](../build-plugin-and-wiregen-cli/spec.md)
