# Introspection

## Purpose

Every generated app, container and testing-variant graph describes its own wiring through an
`introspect()` method returning a `WiringModel`. The model is baked into the generated file as
literals at codegen, holds descriptions rather than values, and is `Codable` so an adapter can
serialise it. The `Introspectable` protocol lets a facade accept a graph without naming its internal
type. The model is available only at run time; there is no build-time dump of it
([swift-wire#344](https://github.com/swift-wire/swift-wire/issues/344)).

Documentation: [IntrospectingTheGraph](../../../Sources/Wire/Wire.docc/IntrospectingTheGraph.md).

## Requirements

### Requirement: The model types are public, `Sendable` and `Codable`
The `Wire` module SHALL declare `WiringModel` with `bindings: [BindingInfo]`; `BindingInfo` with
`type: String`, `key: String?`, `kind: BindingKind`, `scope: String?`, `dependencies: [DependencyEdge]`
and `location: SourceLocation`; `SourceLocation` with `module`, `file` and `line: Int`;
`DependencyEdge` with `type: String` and `key: String?`; and the `String`-backed enum `BindingKind`
with the cases `singleton`, `scoped`, `provider` and `aggregate`. Each SHALL be public and conform to
`Sendable` and `Codable`, with a public memberwise initialiser on every struct.

#### Scenario: a JSON round trip
- **WHEN** a test encodes `try await Wire.bootstrap().introspect()` with `JSONEncoder` and decodes it as `WiringModel`
- **THEN** the decoded model has as many bindings as the original

Pinned by: `Tests/IntegrationTests/IntrospectionTests.swift` (`introspectIsCodable`).

### Requirement: `Introspectable` declares `introspect()`
The `Wire` module SHALL declare `public protocol Introspectable` with the single requirement
`func introspect() -> WiringModel`.

#### Scenario: a generic consumer
- **WHEN** a function takes `some Introspectable` and is passed the bootstrapped graph
- **THEN** it compiles and reads a non-zero binding count

Pinned by: `Tests/IntegrationTests/IntrospectionTests.swift` (`generatedGraphConformsToIntrospectable`).

### Requirement: Every graph struct conforms to `Introspectable`
WireGen SHALL declare each app graph, container graph and testing-variant graph struct as
`internal struct <Name>: Introspectable, Teardownable`, or as
`internal struct <Name><T0: P0, …>: Introspectable, Teardownable` when the graph lifts its opaque
`some P` bindings to generic parameters, and emit `func introspect() -> WiringModel` in it. Seed-scope
structs SHALL carry neither.

#### Scenario: the default and a variant graph
- **WHEN** WireGen generates the integration target's graph
- **THEN** `_WireGraph` and the variant graphs such as `_AppScopedFixture_bindMockWireGraph` are declared `<T0: AggregateSearchBackend, …>: Introspectable, Teardownable`, the container graph is declared `internal struct _ParallelSchedulerContainerWireGraph: Introspectable, Teardownable`, and each has `func introspect() -> WiringModel`

Pinned by: `GoldenHarness/Golden/_WireGraph.swift.golden`, `.github/workflows/swift.yml` (`GoldenHarness`).

### Requirement: One `BindingInfo` per constructed binding, in construction order
`introspect()` SHALL return a `WiringModel` whose `bindings` hold one `BindingInfo(...)` literal per
binding in the graph's topological order, and `WiringModel(bindings: [])` for an empty graph. The
bindings SHALL be those the graph constructs, whether or not the graph stores them, and SHALL NOT
include bindings reachability pruned. The exclusion of pruned bindings is pinned by nothing yet.

#### Scenario: a leaf behind a root
- **WHEN** a graph holds an unrooted `Leaf` and a rooted `Consumer` that depends on it
- **THEN** `introspect()` contains `BindingInfo(type: "Leaf"` and `BindingInfo(type: "Consumer"`, although only `consumer` is stored

#### Scenario: construction order
- **WHEN** `Coordinator` depends on `View`
- **THEN** the `View` literal precedes the `Coordinator` literal

Pinned by: `Tests/WireGenCoreTests/RetentionTests.swift` (`introspectionStillDescribesEveryBinding`, `aReachedButUnrootedBindingIsConstructedAndNotStored`), `Tests/WireGenCoreTests/CodeEmissionTests.swift` (`propertyAssignmentMemberInjectionEmitsAsDirectAssignmentAfterConstruction`).

### Requirement: `type` and `key` are the binding's identity text
Each `BindingInfo` SHALL carry the binding's bound type as written for its identity in `type` (for
example `some AggregateSearchBackend` or `[any Sendable]`), and its key's written text in `key`, or
`nil` when unkeyed. An aggregate's `key` SHALL be its multibinding key reference.

#### Scenario: an aggregate
- **WHEN** the integration graph synthesises the aggregate for `WireTestAggregateKeys.controllers`
- **THEN** its literal is `BindingInfo(type: "[any Sendable]", key: "WireTestAggregateKeys.controllers", kind: .aggregate, …)`

Pinned by: `GoldenHarness/Golden/_WireGraph.swift.golden`.

### Requirement: `kind` follows the binding case, with `scope: nil`
WireGen SHALL emit `kind: .singleton` for a scope-bound binding (a `@Singleton` type, or a
plugin-synthesised contributor or factory struct), `kind: .provider` for a provider binding (a
`@Provides` binding, or a `@GraphInputs` property), and `kind: .aggregate` for a synthesised
aggregate, each with `scope: nil`. No generated `introspect()` SHALL contain `kind: .scoped` or a
non-nil `scope`, since the introspected app, container and variant graphs hold no seeded binding.
That a `@GraphInputs` property surfaces as `kind: .provider` is pinned by nothing yet.

#### Scenario: the fixture's root
- **WHEN** the integration graph is introspected
- **THEN** `IntrospectionRoot` has `kind == .singleton` and `scope == nil`, and the model contains both `.provider` and `.aggregate` bindings

#### Scenario: a synthesised contributor
- **WHEN** the integration graph synthesises the aggregate contributor `_WireAggregateContributor_beta`
- **THEN** its literal is `BindingInfo(type: "_WireAggregateContributor_beta", key: nil, kind: .singleton, scope: nil, …)`

Pinned by: `Tests/IntegrationTests/IntrospectionTests.swift` (`introspectSurfacesKindsScopesAndEdges`), `GoldenHarness/Golden/_WireGraph.swift.golden`.

### Requirement: `dependencies` lists initialiser edges, or an aggregate's contributors
Each `BindingInfo` SHALL list, as `DependencyEdge(type:key:)`, the binding's initialiser or provider
dependencies with their keys, and for an aggregate the contributors collated into it. Member-injection
parameters SHALL NOT appear.

#### Scenario: a root and its leaf
- **WHEN** `IntrospectionRoot` injects `IntrospectionLeaf` through its `@Inject init`
- **THEN** the root's `dependencies` contain an edge of type `IntrospectionLeaf` and the leaf's are empty

#### Scenario: a post-construction injection
- **WHEN** `View` receives `Coordinator` through `@Inject weak var` and `Coordinator` injects `View` in its initialiser
- **THEN** `View`'s literal has `dependencies: []` and `Coordinator`'s has `[DependencyEdge(type: "View", key: nil)]`

Pinned by: `Tests/IntegrationTests/IntrospectionTests.swift` (`introspectSurfacesKindsScopesAndEdges`), `Tests/WireGenCoreTests/CodeEmissionTests.swift` (`propertyAssignmentMemberInjectionEmitsAsDirectAssignmentAfterConstruction`).

### Requirement: `location` names the origin module, file and line
Each `BindingInfo` SHALL carry `SourceLocation(module:file:line:)` with the binding's origin module and
its declaration's path and line as passed to WireGen. A synthesised aggregate's location SHALL be its
multibinding key's declaration.

#### Scenario: the fixture's root
- **WHEN** the integration graph is introspected
- **THEN** `IntrospectionRoot`'s `location.module` is non-empty, `location.file` ends with `IntrospectionExample.swift` and `location.line` is positive

#### Scenario: an aggregate from a library key
- **WHEN** the aggregate for `WireTestAggregateKeys.controllers` is introspected
- **THEN** its location is `SourceLocation(module: "WireTestLibrary", file: "Sources/WireTestLibrary/RouteControllerAdapter.swift", line: 84)`

Pinned by: `Tests/IntegrationTests/IntrospectionTests.swift` (`introspectSurfacesKindsScopesAndEdges`), `GoldenHarness/Golden/_WireGraph.swift.golden`.

### Requirement: The model holds descriptions only
`introspect()` SHALL build its model from string and integer literals alone, reading no property of
the graph, so the model carries no binding value and offers no path back into the graph.

#### Scenario: an introspected leaf that is not stored
- **WHEN** a graph constructs `Leaf` without storing it
- **THEN** `introspect()` still describes `Leaf` while the struct has no `leaf` stored property

Pinned by: `Tests/WireGenCoreTests/RetentionTests.swift` (`introspectionStillDescribesEveryBinding`, `aReachedButUnrootedBindingIsConstructedAndNotStored`), `Tests/WireGenCoreTests/CodeEmissionTests.swift` (`propertyAssignmentMemberInjectionEmitsAsDirectAssignmentAfterConstruction`).

## Related specifications

- [reachability-and-retention](../reachability-and-retention/spec.md)
- [multi-module-composition](../multi-module-composition/spec.md)
- [build-plugin-and-wiregen-cli](../build-plugin-and-wiregen-cli/spec.md)
- [testing-variants](../testing-variants/spec.md)
