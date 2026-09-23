# Build plugin and WireGen command line

## Purpose

`WireBuildPlugin` is the SwiftPM build-tool plugin a graph consumer applies, and `WireGen` is the
executable it runs over the consumer's sources and those of its activated dependencies. This spec
covers the plugin's build command and activation rule, the `WireGen` argument grammar, its failure
and reporting behaviour, the shape of the two generated files, the determinism the golden gate
enforces, and the `WireGen` product an adapter's own plugin can invoke.

Rationale: [MultiModuleComposition](../../../Documentation/Notes/MultiModuleComposition.md).
Documentation: [AddingWireToAPackage](../../../Sources/Wire/Wire.docc/AddingWireToAPackage.md), [WhatGetsBuilt](../../../Sources/Wire/Wire.docc/WhatGetsBuilt.md), [README](../../../README.md).

## Requirements

### Requirement: The plugin emits one build command per source target
For a source-module target with at least one `.swift` file, `WireBuildPlugin` SHALL return a single
`.buildCommand` named `WireGen <target>` whose executable is the `WireGen` tool, whose input files
are the target's `.swift` sources plus every activated dependency's `.swift` sources, and whose
output files are `_WireGraph.swift` and `_WireKeyChecks.swift` in the plugin work directory. A
target with no source module or no `.swift` files SHALL get no command.

#### Scenario: a consumer target with sources
- **WHEN** the plugin runs on `IntegrationTests`, which depends on the Wire-aware sibling `WireTestLibrary`
- **THEN** one command runs `WireGen` over both modules' sources and SwiftPM compiles the emitted `_WireGraph.swift` and `_WireKeyChecks.swift` into the target

Pinned by: `BuildAndTestLinux` and `BuildAndTestMacOS` jobs in `.github/workflows/swift.yml` (the `IntegrationTests` target only builds if both outputs are produced and compile).

### Requirement: Activation is a direct manifest dependency on a target that depends on `Wire`
The plugin SHALL activate a dependency module when it is a direct `.target` or `.product`
dependency of the consumer and that module's own dependencies name `Wire`, by target or by product
name (`dependsOnWire`). Transitive dependencies SHALL NOT be activated, whatever they depend on.

#### Scenario: a same-package Wire-aware sibling
- **WHEN** `IntegrationTests` depends on `WireTestLibrary`, which depends on `Wire` and declares `public @Singleton LibraryService`
- **THEN** `try await Wire.bootstrap()` in `IntegrationTests` exposes `graph.libraryService`

#### Scenario: a transitively depended Wire-aware package
- **WHEN** the composition harness consumer depends on `WireHarnessLibrary`, which depends on `WireHarnessTransitive`, and both the consumer and the transitive package declare `@Singleton HarnessSharedService`
- **THEN** the consumer builds without a duplicate-binding error and `graph.harnessSharedService.origin` is `"consumer"`

Pinned by: `Tests/IntegrationTests/CrossModuleCompositionTests.swift` (`samePackageLibraryBindingIsComposedAndConstructed`), `CompositionHarness/Consumer/Sources/WireHarnessConsumer/main.swift` via the `CompositionHarness` job in `.github/workflows/swift.yml`.

### Requirement: Modules are passed as `--module` or `--external-module` groups
The plugin SHALL pass the consumer first as `--module <name> <files…>`, then each activated
same-package `.target` dependency as `--module <name> <files…>` and each activated external
`.product` dependency as `--external-module <name> <files…>`, deduplicated by module name.

#### Scenario: a same-package dependency
- **WHEN** `WireTestLibrary` is a `.target` dependency and declares a `package`-visible `@Singleton PackageVisibleService`
- **THEN** it is passed as `--module WireTestLibrary` and the `package` binding composes into `IntegrationTests`

#### Scenario: an external package dependency
- **WHEN** `WireHarnessLibrary` is a `.product` dependency of the harness consumer
- **THEN** it is passed as `--external-module WireHarnessLibrary` and its `public` bindings compose across the package boundary

Pinned by: `Tests/IntegrationTests/CrossModuleCompositionTests.swift` (`samePackagePackageVisibleBindingIsComposed`), `CompositionHarness/run-harness.sh` via the `CompositionHarness` job in `.github/workflows/swift.yml`.

### Requirement: `--testing-variants` is passed for test targets only
The plugin SHALL add `--testing-variants` to the `WireGen` arguments when the target's
`sourceModule.kind` is `.test`, and SHALL NOT add it for any other kind.

#### Scenario: a test target declaring a `TestingKey`
- **WHEN** `IntegrationTests` declares `WireDoublesFixture.bindMockRepo = TestingKey()` with a `@BindType`
- **THEN** the build succeeds and `Wire.bootstrapWireDoublesFixture_bindMockRepo()` exists

Pinned by: `Tests/IntegrationTests/BindTypeDoublesTests.swift` (`suppliedMockInstanceFlowsThroughScopeEntry`), `GoldenHarness/run-golden-harness.sh`. The production-target half is pinned by nothing yet.

### Requirement: Very large input sets raise a plugin warning
When the consumer's sources plus activated dependencies' sources exceed 5000 files, the plugin SHALL
emit `Diagnostics.warning` with the text
`WireBuildPlugin: <count> Swift sources (target + Wire-aware dependencies), approaching argv limits. If WireGen exec fails with E2BIG, file an issue.`
and SHALL still emit the build command.

#### Scenario: 5001 input files
- **WHEN** the input file list has 5001 entries
- **THEN** the warning is emitted with `5001` as the count and the command is returned unchanged

Pinned by: nothing yet.

### Requirement: The `WireGen` argument grammar
`WireGen` SHALL take, in order, the graph output path, the key-checks output path, then one or more
groups each introduced by `--module <name>` or `--external-module <name>` and followed by that
module's source paths; `--testing-variants` SHALL be accepted anywhere in the argument list and removed before group parsing.
The first group SHALL be the consumer module. With fewer than three arguments, no group, or a group
flag without a name, `WireGen` SHALL write
`error: WireGen requires two output paths (graph + key checks) and at least one --module group.`
followed by
`usage: WireGen <graph-output-path> <key-checks-output-path> [--testing-variants] --module <name> <source-files...> [--module <name> <source-files...>]`
to stderr and exit with status 1.

#### Scenario: the golden invocation
- **WHEN** `WireGen` is run as `WireGen <graph> <keychecks> --testing-variants --module IntegrationTests Tests/IntegrationTests/*.swift --module WireTestLibrary Sources/WireTestLibrary/*.swift`
- **THEN** `IntegrationTests` is the consumer, `WireTestLibrary` is a same-package dependency, and variants are enabled

#### Scenario: no module group
- **WHEN** `WireGen` is run with only two output paths
- **THEN** the usage lines above are written to stderr and the exit status is 1

Pinned by: `GoldenHarness/run-golden-harness.sh`. The usage path is pinned by nothing yet.

### Requirement: Diagnostics are written to stderr in compiler form
`WireGen` SHALL render every diagnostic as `<file>:<line>:<col>: error: <message>` or
`<file>:<line>:<col>: warning: <message>`, each note as `<file>:<line>:<col>: note: <message>`,
and SHALL write them to stderr before any graph-validation block. A graph that fails validation
SHALL be reported under a line `in graph '<name>':` where `<name>` is `default`, the container
name, or `scope '<Seed>'`.

#### Scenario: every diagnostic line carries a position
- **WHEN** a source set produces missing-binding, cycle and duplicate-binding errors
- **THEN** every rendered line begins with a `file:line:col:` prefix

#### Scenario: a pruning warning reaches the build log
- **WHEN** the harness consumer declares an unreached `@Singleton UnreachedHomeBinding`
- **THEN** `swift build` output contains `'UnreachedHomeBinding' is declared but nothing reachable` and `mark it 'allowUnused: true'`

Pinned by: `Tests/WireGenCoreTests/DiagnosticGalleryTests.swift` (`everyDiagnosticLineCarriesFileLineColPrefix`), `CompositionHarness/run-harness.sh` via the `CompositionHarness` job in `.github/workflows/swift.yml`.

### Requirement: Any error-severity diagnostic fails the run before anything is written
`WireGen` SHALL exit with status 1 when any diagnostic has `.error` severity, when any graph has
validation errors, or when a testing variant fails, and SHALL write neither output file in that
case. Each output file, when written, SHALL be written atomically and followed by `wrote <path>` on
stdout.

#### Scenario: an unresolvable dependency in a reached binding
- **WHEN** a retained binding depends on a type nothing produces
- **THEN** the error is printed, the exit status is 1, and no `_WireGraph.swift` or `_WireKeyChecks.swift` is written

Pinned by: nothing yet.

### Requirement: Discovery and topological orders are reported on stdout
`WireGen` SHALL print the per-file discovery report, then each graph's order under `default graph:`,
`container '<name>':` and `scope '<Seed>':` headings, each rendered as
`topological order (<n> binding(s)):` followed by numbered entries, or `  (graph is empty)`.

#### Scenario: an empty default graph
- **WHEN** no bindings are discovered
- **THEN** the order renders as `topological order (0 binding(s)):` and `  (graph is empty)`

#### Scenario: a three-binding graph
- **WHEN** three bindings resolve in order
- **THEN** the order renders as `topological order (3 binding(s)):` with entries `1.`, `2.` and `3.`

Pinned by: `Tests/WireGenCoreTests/GraphTests.swift` (`renderTopologicalOrderEmptyShowsEmptyNotice`, `renderTopologicalOrderNumbersEachEntry`), `Tests/WireGenCoreTests/DiscoveryTests.swift` (`discoveryReportHeaderAndCountWithEmptyInput`, `discoveryReportSkipsFilesWithNoBindings`).

### Requirement: The generated graph is a struct, a private bootstrap and a `Wire` facade
`_WireGraph.swift` SHALL begin `// Generated by WireGen — do not edit.`, then the imports folded to
one per module with access-level modifiers and `@_exported` dropped and attributes unioned, sorted
and deduplicated, then any synthesised module-scope types, then
`internal struct _WireGraph<T0: P0, …>: Introspectable, Teardownable` with one stored `let` per
retained binding named from its bound type, then
`private func _wireBootstrap() async throws -> _WireGraph<some P0, …>` constructing every binding
in topological order, and finally one `internal enum Wire` whose
`static func bootstrap() async throws -> …` calls `try await _wireBootstrap()`. The generic clause
SHALL be present only when the graph lifts opaque (`some P`) bindings.

#### Scenario: an empty graph
- **WHEN** no bindings are discovered
- **THEN** the file declares `internal struct _WireGraph: Introspectable, Teardownable {`, `private func _wireBootstrap() async throws -> _WireGraph {` returning `_WireGraph()`, and `internal enum Wire {` with `bootstrap()`

#### Scenario: one retained singleton with no dependencies
- **WHEN** a retained `@Singleton A` is the only binding
- **THEN** `_WireGraph` has `let a: A`, `_wireBootstrap()` constructs `let a = A()` and returns `_WireGraph(a: a)`

#### Scenario: imports are normalised
- **WHEN** input files import one module at several access levels, with `@testable` on one of them, and another module twice
- **THEN** the generated file carries each module once, sorted, with its access-level modifier dropped and its attributes kept

Pinned by: `Tests/WireGenCoreTests/CodeEmissionTests.swift` (`emptyGraphProducesBareBootstrap`, `singleNoDependencySingleton`, `importsAreEmittedSortedAndDeduplicated`, `importsArePreservedVerbatimWithModifiers`), `Tests/WireGenCoreTests/ImportNormalizationTests.swift` (`collapsesAccessLevels`, `dropsAccessModifier`, `unionsAttributes`, `sortsAndDeduplicates`, `emittersNormalize`), `GoldenHarness/Golden/_WireGraph.swift.golden`.

### Requirement: Named graphs share the default graph's shape
Each `@Container` and each testing-variant app graph SHALL be emitted as
`internal struct _<Name>WireGraph`, `private func _wireBootstrap<Name>()` and
`Wire.bootstrap<Name>()`, in sorted name order after the default graph, with every entry point
collected onto the single trailing `enum Wire`.

#### Scenario: one container
- **WHEN** the module declares `@Container Test` and no default-graph bindings
- **THEN** the file declares both `_WireGraph` with `bootstrap()` and `_TestWireGraph` with `bootstrapTest()`

#### Scenario: several containers
- **WHEN** the module declares containers `Beta` and `Alpha`
- **THEN** `_AlphaWireGraph` is emitted before `_BetaWireGraph`

Pinned by: `Tests/WireGenCoreTests/CodeEmissionTests.swift` (`singleContainerEmitsItsOwnStructAlongsideEmptyDefault`, `defaultAndContainerBothEmitSideBySide`, `multipleContainersAreEmittedInSortedOrder`), `GoldenHarness/Golden/_WireGraph.swift.golden`.

### Requirement: `@GraphInputs` adds an `inputs:` parameter to the default and testing-variant bootstraps
When the consumer module declares a `@GraphInputs` type, `Wire.bootstrap`, `_wireBootstrap` and each
testing-variant bootstrap SHALL take `inputs: <Type>`; a `@Container` graph's bootstrap SHALL NOT.

#### Scenario: a module with graph inputs
- **WHEN** the graph-inputs harness consumer declares `@GraphInputs struct AppInputs` with a `configuration` property and two `@Provides(key)` properties
- **THEN** `try await Wire.bootstrap(inputs: …)` constructs the graph and the values reach their consumers by type and by key

Pinned by: `GraphInputsHarness/run-graph-inputs-harness.sh` via the `GraphInputsHarness` job in `.github/workflows/swift.yml`.

### Requirement: A constructed but unstored binding becomes an unavailable stub
For each binding the graph constructs but does not store, `_WireGraph.swift` SHALL emit, on one
line in place of the stored property,
`@available(*, unavailable, message: "'<property>' is constructed by the graph but not a direct property of it. To read it as 'graph.<property>', mark its binding at <file>:<line> 'allowUnused: true'.") internal var <property>: <Type> { fatalError() }`.

#### Scenario: a reached leaf nothing declares a root
- **WHEN** `Leaf` is injected by an `allowUnused` consumer and nothing else roots it
- **THEN** the struct carries the `@available(*, unavailable, message:` stub for `leaf` naming its declaration's file and line, and the memberwise init omits it

Pinned by: `Tests/WireGenCoreTests/RetentionTests.swift` (`aDroppedPropertyLeavesAnUnavailableStubNamingItsFix`, `theStubIsLineForLineWhatTheStoredPropertyWas`), `GoldenHarness/Golden/_WireGraph.swift.golden`.

### Requirement: `_WireKeyChecks.swift` unifies each keyed site with its key
`_WireKeyChecks.swift` SHALL begin with the `// Generated by WireGen — do not edit.` header and the
normalised imports, and SHALL contain one `private func _wireTypeCheck_<n>()` per distinct
`(key expression, declared type)` pair, each declaring
`func _check<T>(_: BindingKey<T>, _: T.Type) {}` and, per source site,
`#sourceLocation(file: "<file>", line: <line>)`, `_check(<key>, <Type>.self)` and
`#sourceLocation()`. Multibinding keys and injection-rewrite keys SHALL be excluded, and the file
SHALL be emitted with the header alone when there are no keyed sites.

#### Scenario: no keyed bindings
- **WHEN** the input holds only unkeyed bindings
- **THEN** the file contains the header and no `_wireTypeCheck_` function

#### Scenario: a keyed provider
- **WHEN** `@Provides(Database.primary)` binds `Database` at `App.swift:5`
- **THEN** the file contains `private func _wireTypeCheck_1()`, `#sourceLocation(file: "App.swift", line: 5)` and `_check(Database.primary, Database.self)`

#### Scenario: one pair at three sites
- **WHEN** a keyed provider and two keyed consumers all use `(Database.primary, Database)`
- **THEN** one function carries three `_check` calls, each under its own `#sourceLocation`

Pinned by: `Tests/WireGenCoreTests/CodeEmissionTests.swift` (`keyChecksEmptyInputProducesHeaderOnlyFile`, `keyChecksUnkeyedBindingsProduceNoFunctions`, `keyedProviderProducesCheckFunction`, `keyedDependencyProducesCheckFunction`, `sameKeyAndTypeAtMultipleSitesDedupesToOneFunction`), `GoldenHarness/Golden/_WireKeyChecks.swift.golden`.

### Requirement: Generated output is deterministic and path-relative
For the same input files in the same order, `WireGen` SHALL produce byte-identical output. Source
paths SHALL be echoed exactly as passed into `#sourceLocation` directives and stub messages, so a
run over repository-relative paths contains no machine-specific path. The golden harness SHALL
compare both outputs against `GoldenHarness/Golden/*.golden`, fail on any drift or on any occurrence
of the checkout's absolute path, and re-record with `--update`.

#### Scenario: the corpus is unchanged
- **WHEN** `bash GoldenHarness/run-golden-harness.sh` runs over `Tests/IntegrationTests` and `Sources/WireTestLibrary`
- **THEN** both generated files are byte-identical to the recorded goldens and the gate passes

#### Scenario: re-recording
- **WHEN** `bash GoldenHarness/run-golden-harness.sh --update` runs
- **THEN** `_WireGraph.swift.golden` and `_WireKeyChecks.swift.golden` are overwritten with the current output

Pinned by: `GoldenHarness/run-golden-harness.sh`, `GoldenHarness/Golden/_WireGraph.swift.golden`, `GoldenHarness/Golden/_WireKeyChecks.swift.golden`, `GoldenHarness` job in `.github/workflows/swift.yml`.

### Requirement: `WireGen` is an executable product other plugins can invoke
The package SHALL export `WireGen` as `.executable(name: "WireGen")`, and `WireBuildPlugin` SHALL
obtain it through `context.tool(named: "WireGen")`. `WireGen` SHALL behave identically when an
adapter package's own build-tool plugin obtains it the same way and passes the same argument
grammar.

#### Scenario: an adapter's plugin
- **WHEN** a plugin in another package calls `context.tool(named: "WireGen")` and passes the same `<graph> <keychecks> [--testing-variants] --module … --external-module …` arguments
- **THEN** `WireGen` emits `_WireGraph.swift` and `_WireKeyChecks.swift` exactly as it does for `WireBuildPlugin`

Pinned by: nothing yet in this repository.

## Related specifications

- [multi-module-composition](../multi-module-composition/spec.md)
- [reachability-and-retention](../reachability-and-retention/spec.md)
- [binding-identity-and-keys](../binding-identity-and-keys/spec.md)
- [scope-entry-and-generated-names](../scope-entry-and-generated-names/spec.md)
- [graph-conformance](../graph-conformance/spec.md)
- [testing-variants](../testing-variants/spec.md)
- [introspection](../introspection/spec.md)
- [teardown](../teardown/spec.md)
