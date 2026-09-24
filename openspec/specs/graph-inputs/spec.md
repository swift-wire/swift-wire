# Graph inputs

## Purpose

`@GraphInputs` marks the one struct whose values the caller builds before the graph exists and
passes to `Wire.bootstrap(inputs:)`: configuration read from the environment, CLI arguments, an
externally owned client. Each stored property becomes an app-scope binding of its own type, keyed
when the property carries `@Provides(key)`, so consumers inject an input the ordinary way. This spec
states which declaration WireGen honours, which properties become inputs, the bindings and bootstrap
parameter it generates, and the diagnostics for declarations it cannot honour. The shape of the
generated bootstrap is specified in
[build-plugin-and-wiregen-cli](../build-plugin-and-wiregen-cli/spec.md).

Documentation: [AddingWireToAPackage](../../../Sources/Wire/Wire.docc/AddingWireToAPackage.md), [WhatGetsBuilt](../../../Sources/Wire/Wire.docc/WhatGetsBuilt.md).

## Requirements

### Requirement: The `@GraphInputs` macro is a marker
`@GraphInputs()` SHALL be an attached peer macro implemented by `GraphInputsMacro` whose expansion
returns no peers and emits no diagnostics.

#### Scenario: an inputs struct
- **WHEN** `@GraphInputs struct AppInputs: Sendable { let configuration: RuntimeConfiguration }` is compiled
- **THEN** the struct gains no member and keeps its compiler-synthesised memberwise initialiser

Pinned by: `GraphInputsHarness/Consumer/Sources/GraphInputsHarnessConsumer/main.swift` (built and run by the `GraphInputsHarness` job in `.github/workflows/swift.yml`). The empty expansion is pinned by nothing yet.

### Requirement: WireGen reads `@GraphInputs` from a struct declaration
WireGen SHALL record a `DiscoveredGraphInputs` for each `struct` carrying `@GraphInputs`, named by
the struct's name, and SHALL record none for a struct without the attribute.

#### Scenario: an unannotated struct
- **WHEN** `struct AppInputs { let x: Int }` is discovered
- **THEN** no graph inputs are recorded

Pinned by: `Tests/WireGenCoreTests/GraphInputsDiscoveryTests.swift` (`anUnannotatedStructIsNotInputs`, `storedPropertiesBecomeInputsAndComputedOnesDoNot`).

### Requirement: Stored properties with a written type are the inputs
WireGen SHALL take as inputs, in declaration order, the struct's stored properties that have an
explicit type annotation, whether `let` or `var` and whether or not they carry an initial value or
`willSet`/`didSet` observers. A property with a getter SHALL NOT be an input, and a property with no
type annotation SHALL be skipped.

#### Scenario: stored, observed and computed properties
- **WHEN** `@GraphInputs struct AppInputs` declares `let configuration: RuntimeConfiguration`, `var mutableToo: Int`, `var described: String { "x" }` and `var observed: Bool = false { didSet {} }`
- **THEN** the inputs are `configuration`, `mutableToo` and `observed`, of types `RuntimeConfiguration`, `Int` and `Bool`

Pinned by: `Tests/WireGenCoreTests/GraphInputsDiscoveryTests.swift` (`storedPropertiesBecomeInputsAndComputedOnesDoNot`). The skipped untyped property is pinned by nothing yet.

### Requirement: Only a single identifier with its own type annotation is read
WireGen SHALL read each pattern binding of a declaration separately and SHALL take it as an input
only when its pattern is a single identifier carrying its own type annotation, with no diagnostic for
a binding it skips. This is tracked as a defect in https://github.com/swift-wire/swift-wire/issues/404.

#### Scenario: a shared trailing annotation
- **WHEN** `@GraphInputs struct AppInputs` declares `let region, stage: String`
- **THEN** the only input is `stage`, and no diagnostic names `region`

#### Scenario: a tuple pattern
- **WHEN** `@GraphInputs struct AppInputs` declares `let configuration: RuntimeConfiguration` and `let (host, port): (String, Int)`
- **THEN** the only input is `configuration`

Pinned by: nothing yet.

### Requirement: A `static` stored property is taken as an input
WireGen SHALL NOT read a property's declaration modifiers, so a `static` stored property with a type
annotation SHALL become an input whose access path `_wireInputs.<name>` does not compile in the
generated file. This is tracked as a defect in https://github.com/swift-wire/swift-wire/issues/402.

#### Scenario: a static constant on the inputs struct
- **WHEN** `@GraphInputs struct AppInputs` declares `let configuration: RuntimeConfiguration` and `static let fallback: Int = 0`
- **THEN** the inputs are `configuration` and `fallback`, and the provider for `fallback` reads `_wireInputs.fallback`

Pinned by: nothing yet.

### Requirement: `@Provides(key)` keys an input
An input property carrying `@Provides` with a positional first argument SHALL be keyed by that
argument's text. An input with no `@Provides`, a bare `@Provides`, or only a labelled argument
SHALL be unkeyed.

#### Scenario: two inputs of one type
- **WHEN** `AppInputs` declares `@Provides(InputKeys.region) let region: String`, `@Provides(InputKeys.stage) let stage: String` and `let unkeyed: String`
- **THEN** their keys are `InputKeys.region`, `InputKeys.stage` and none

#### Scenario: a keyed input reaches a consumer
- **WHEN** `DeploymentTarget` takes `@Bind(InputKeys.region) region: String` and `@Bind(InputKeys.stage) stage: String`
- **THEN** it receives `"ap-southeast-2"` and `"prod"` from the inputs passed to `Wire.bootstrap(inputs:)`

Pinned by: `Tests/WireGenCoreTests/GraphInputsDiscoveryTests.swift` (`providesKeysAnInputSoSameTypedInputsCoexist`), `GraphInputsHarness/Consumer/Sources/GraphInputsHarnessConsumer/main.swift` (run by the `GraphInputsHarness` job in `.github/workflows/swift.yml`).

### Requirement: Each input becomes an app-scope provider reading the bootstrap parameter
WireGen SHALL add, before every other binding pass, one property-form provider per input to the
default graph's singleton partition, with the property's type as its bound type, the input's key,
access path `_wireInputs.<name>`, no dependencies and `allowUnused: true`, so every input is a
reachability root.

#### Scenario: two inputs
- **WHEN** `AppInputs` declares `let configuration: RuntimeConfiguration` and `@Provides(InputKeys.region) let region: String`
- **THEN** the providers' access paths are `_wireInputs.configuration` and `_wireInputs.region`, their keys none and `InputKeys.region`, and both are `allowUnused`

#### Scenario: one input, two consumers
- **WHEN** `DeploymentTarget` and `EndpointProbe` both inject `RuntimeConfiguration`
- **THEN** both read `"https://example.test"` from the one value passed in

Pinned by: `Tests/WireGenCoreTests/GraphInputsDiscoveryTests.swift` (`eachInputBecomesAProviderReadingTheBootstrapParameter`), `GraphInputsHarness/Consumer/Sources/GraphInputsHarnessConsumer/main.swift` (run by the `GraphInputsHarness` job in `.github/workflows/swift.yml`).

### Requirement: The default bootstrap takes the inputs value
When an inputs declaration is honoured, the default graph's facade and private bootstrap SHALL
declare the parameter `inputs _wireInputs: <InputsType>`, and each testing-variant app graph's
bootstrap SHALL declare the same parameter. A `@Container` graph's bootstrap SHALL NOT, and its
graph SHALL contain no input binding.

#### Scenario: bootstrapping with inputs
- **WHEN** the harness calls `try await Wire.bootstrap(inputs: AppInputs(configuration: RuntimeConfiguration(endpoint: "https://example.test"), region: "ap-southeast-2", stage: "prod"))`
- **THEN** `graph.deploymentTarget.summary` is `"https://example.test|ap-southeast-2|prod"`

#### Scenario: a container beside inputs
- **WHEN** a module declaring `@GraphInputs` also declares `@Container enum TestContainer`
- **THEN** `Wire.bootstrapTestContainer()` takes no parameter

Pinned by: `GraphInputsHarness/run-graph-inputs-harness.sh` (the `GraphInputsHarness` job in `.github/workflows/swift.yml`). The container and testing-variant signatures are pinned by nothing yet.

### Requirement: Only a declaration from the consumer's own package is honoured
WireGen SHALL honour the first `@GraphInputs` declaration whose origin module is not an
`--external-module`, so a declaration in another module of the same package is honoured. A
declaration from an external module SHALL be ignored with the warning "@GraphInputs '<Type>' is
declared by dependency '<Module>' and is ignored — inputs are supplied by the consumer that
bootstraps the graph, so a library cannot declare them. Any binding of its own that consumes one
will not resolve."

#### Scenario: a library's inputs
- **WHEN** `LibraryInputs` is declared in `SomeLibrary` and `SomeLibrary` is an external module
- **THEN** no inputs are honoured and one warning naming `SomeLibrary` is reported

#### Scenario: a same-package module's inputs
- **WHEN** `AppInputs` is declared in a module that is not in the external set
- **THEN** `AppInputs` is honoured and no diagnostic is reported

#### Scenario: a library's and the consumer's
- **WHEN** both the consumer's `AppInputs` and the external `LibraryInputs` are discovered
- **THEN** `AppInputs` is honoured and the only diagnostic is the ignored-dependency warning

Pinned by: `Tests/WireGenCoreTests/GraphInputsDiscoveryTests.swift` (`aDependencysInputsAreIgnoredAndDiagnosed`, `aSamePackageModulesInputsAreUsed`, `aDependencysInputsDoNotCollideWithTheConsumersOwn`).

### Requirement: The generated file does not import the inputs declaration's module
WireGen SHALL name the honoured inputs type bare in the generated file and SHALL add no import for
the module that declares it, so a declaration from another module of the same package compiles only
when a binding-bearing file of the consumer already imports that module. This is tracked as a defect
in https://github.com/swift-wire/swift-wire/issues/405.

#### Scenario: inputs declared in a sibling module
- **WHEN** `AppInputs` is declared in `App`, the consumer is `AppTests` in the same package, and no binding-bearing file of `AppTests` imports `App`
- **THEN** the generated file declares `inputs _wireInputs: AppInputs` with no `import App` line for it

Pinned by: nothing yet.

### Requirement: More than one honoured declaration is an error
When more than one `@GraphInputs` declaration comes from outside the external modules, WireGen SHALL
report an error at each declaration after the first: "multiple @GraphInputs types are declared
('<First>' and '<Other>') — the graph takes one 'inputs:' value, so merge them into a single type."

#### Scenario: two inputs structs
- **WHEN** `@GraphInputs struct AppInputs` and `@GraphInputs struct OtherInputs` are declared in one module
- **THEN** exactly one error is reported, naming both `AppInputs` and `OtherInputs`

Pinned by: `Tests/WireGenCoreTests/GraphInputsDiscoveryTests.swift` (`twoGraphInputsTypesIsAnError`).

### Requirement: A declaration with no inputs warns
WireGen SHALL warn at each `@GraphInputs` declaration from outside the external modules that has no
input properties: "@GraphInputs '<Type>' declares no stored properties, so it contributes no
bindings — give it the values the graph needs from outside, or remove the annotation." A declaration
with at least one input SHALL NOT raise this warning.

#### Scenario: only a computed property
- **WHEN** `@GraphInputs struct AppInputs: Sendable { var described: String { "x" } }` is discovered
- **THEN** exactly one warning is reported

#### Scenario: one stored property
- **WHEN** `@GraphInputs struct AppInputs: Sendable { let a: Int }` is discovered
- **THEN** no diagnostic is reported

Pinned by: `Tests/WireGenCoreTests/GraphInputsDiscoveryTests.swift` (`inputsWithNoStoredPropertiesWarns`, `oneWellFormedDeclarationIsSilent`).

## Related specifications

- [build-plugin-and-wiregen-cli](../build-plugin-and-wiregen-cli/spec.md)
- [binding-lifetimes](../binding-lifetimes/spec.md)
- [binding-identity-and-keys](../binding-identity-and-keys/spec.md)
- [reachability-and-retention](../reachability-and-retention/spec.md)
- [multi-module-composition](../multi-module-composition/spec.md)
- [containers](../containers/spec.md)
- [seeded-scopes](../seeded-scopes/spec.md)
- [testing-variants](../testing-variants/spec.md)
- [providers](../providers/spec.md)
