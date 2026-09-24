# Multi-module composition

## Purpose

A target that applies the build plugin composes its own bindings with those of every Wire-aware
module it directly depends on into one generated graph. WireGen re-parses each activated module's
sources, stamps every binding with the module it came from, validates the union as one graph, and
emits the imports the generated file needs to reach the composed types. `@Replaces` lets the
consuming module supersede one binding composed from a dependency.

Rationale: [MultiModuleComposition](../../../Documentation/Notes/MultiModuleComposition.md).
Documentation: [ComposingAcrossModules](../../../Sources/Wire/Wire.docc/ComposingAcrossModules.md), [ProvidingValues](../../../Sources/Wire/Wire.docc/ProvidingValues.md).

## Requirements

### Requirement: A direct dependency on a Wire-aware module activates it
The build plugin SHALL activate the modules the consumer directly depends on that themselves depend
on `Wire`, and pass each to WireGen as a module group, as specified in
[build-plugin-and-wiregen-cli](../build-plugin-and-wiregen-cli/spec.md). An activated module's
bindings SHALL enter the consumer's parse set and be validated with it, and those reachable from the
consumer's roots, as specified in [reachability-and-retention](../reachability-and-retention/spec.md),
SHALL be emitted into the generated graph and constructed by its bootstrap.

#### Scenario: a same-package library singleton
- **WHEN** `IntegrationTests` depends on the sibling target `WireTestLibrary`, which declares `public` `@Singleton(allowUnused: true) LibraryService`, a root because `WireTestLibrary` is a same-package module
- **THEN** `try await Wire.bootstrap()` returns a graph whose `libraryService.name` is `"library"`

#### Scenario: a package-visible library singleton
- **WHEN** `WireTestLibrary` declares a `package` `@Singleton(allowUnused: true) PackageVisibleService`
- **THEN** the bootstrapped graph's `packageVisibleService.label` is `"package-visible"`

#### Scenario: an external-package library
- **WHEN** the composition harness consumer depends on the `WireHarnessLibrary` product and injects its unkeyed and keyed `ExternalService`
- **THEN** the consumer bootstraps and both resolve to a service named `"external"`

#### Scenario: an unreached library singleton
- **WHEN** `WireHarnessLibrary` declares `public` `@Singleton UnreachedExternalService`, whose `init` traps, and nothing in the consumer reaches it
- **THEN** the consumer's generated graph does not construct it and the consumer bootstraps

Pinned by: `Tests/IntegrationTests/CrossModuleCompositionTests.swift` (`samePackageLibraryBindingIsComposedAndConstructed`, `samePackagePackageVisibleBindingIsComposed`), `.github/workflows/swift.yml` (`CompositionHarness`).

### Requirement: Every discovered declaration carries its origin module
WireGen SHALL stamp each discovered `@Singleton`, `@Scoped`, `@Provides`, `BindingKey` and multibinding
key with the name of the module group it was parsed under, as `originModule`. The same source parsed
under two module names SHALL carry two different origins.

#### Scenario: one source, two modules
- **WHEN** the same `@Singleton` source is discovered under module `Consumer` and under module `Library`
- **THEN** the first binding's `originModule` is `"Consumer"` and the second's is `"Library"`

Pinned by: `Tests/WireGenCoreTests/OriginModuleDiscoveryTests.swift` (`singletonCarriesOriginModule`, `providerCarriesOriginModule`, `scopedBindingCarriesOriginModule`, `bindingKeyCarriesOriginModule`, `multibindingKeyCarriesOriginModule`, `distinctModulesStampDistinctly`, `bindingAccessorReflectsConstructionModule`).

### Requirement: The generated file imports each foreign origin module
WireGen SHALL add `import <Module>` to the generated file for every distinct origin module, other than
the consumer's, of a composed binding, a graph conformance, or a synthesised factory's produced type.
The lines SHALL be deduplicated and sorted.

#### Scenario: bindings from two libraries
- **WHEN** the composed bindings come from `Consumer`, `Beta`, `Alpha` and `Alpha`
- **THEN** the foreign imports are `import Alpha` then `import Beta`

#### Scenario: only local bindings
- **WHEN** every composed binding originates in the consumer
- **THEN** no foreign import is added

Pinned by: `Tests/WireGenCoreTests/OriginModuleDiscoveryTests.swift` (`foreignImportsEmitsSortedDedupedImportsExcludingConsumer`, `foreignImportsIsEmptyWhenAllBindingsAreConsumerLocal`). The graph-conformance and synthesised-factory sources are pinned by nothing yet.

### Requirement: Only files that declare something contribute their imports
WireGen SHALL carry a parsed file's own `import` declarations into the generated file only when the
file declares a binding, a graph conformance or a multibinding key.

#### Scenario: a helper file with no bindings
- **WHEN** an activated module's file imports `Yams` and declares no binding, conformance or key
- **THEN** the generated file does not import `Yams` on its account

Pinned by: nothing yet.

### Requirement: Imports are normalised to one internal import per module
Among their unconditional imports, the generated `_WireGraph.swift` and `_WireKeyChecks.swift` SHALL
carry one import per module and import-kind specifier, with no access-level modifier and no
`@_exported` attribute, keeping the union of every other attribute the module was imported with. A
captured import-only `#if` block SHALL be kept whole beside them and not merged with them, so a module
imported both plainly and inside such a block appears in both. The lines SHALL be sorted, and only
identical lines deduplicated.

#### Scenario: one module at several access levels
- **WHEN** the collected imports are `import Wire`, `public import Wire`, `package import Wire` and `private import Wire`
- **THEN** the normalised result is `import Wire`

#### Scenario: a re-export from a dependency
- **WHEN** a collected import is `@_exported public import HTTPAPIs`
- **THEN** the normalised result is `import HTTPAPIs`

#### Scenario: attributes across spellings
- **WHEN** the collected imports are `@_spi(Generated) public import OpenAPIRuntime`, `@preconcurrency import OpenAPIRuntime` and `import OpenAPIRuntime`
- **THEN** the normalised result is `@_spi(Generated) @preconcurrency import OpenAPIRuntime`

#### Scenario: a kind specifier
- **WHEN** the collected imports are `public import struct Foundation.Data` and `import Foundation`
- **THEN** both `import Foundation` and `import struct Foundation.Data` are kept

Pinned by: `Tests/WireGenCoreTests/ImportNormalizationTests.swift` (`collapsesAccessLevels`, `dropsAccessModifier`, `dropsExported`, `unionsAttributes`, `keepsKindSpecifier`, `sortsAndDeduplicates`, `emittersNormalize`).

### Requirement: A `#if canImport(FoundationEssentials)` block is kept and normalised inside
WireGen SHALL emit a captured `#if canImport(FoundationEssentials)` import block whole, with each
import inside it rewritten to the canonical form.

#### Scenario: a platform-selection block
- **WHEN** the collected block is `#if canImport(FoundationEssentials)` / `@_exported public import FoundationEssentials` / `#else` / `package import Foundation` / `#endif`
- **THEN** the emitted block is `#if canImport(FoundationEssentials)` / `import FoundationEssentials` / `#else` / `import Foundation` / `#endif`

Pinned by: `Tests/WireGenCoreTests/ImportNormalizationTests.swift` (`normalizesInsideIfConfig`).

### Requirement: Composed modules are validated as one graph
WireGen SHALL resolve dependencies, keys and missing bindings over the union of every activated
module's bindings, so a dependency in one module is satisfied by a producer in another and a key
declared in one module resolves a keyed site in another. WireGen SHALL report a missing binding only
for a consumer that reachability retains; an unreachable binding whose dependency no activated module
produces is pruned before the missing-binding check and reported by nothing.

#### Scenario: a logger from a library
- **WHEN** module `App` injects `Logger` and module `Lib` provides it
- **THEN** validation reports nothing

#### Scenario: a dependency no module provides
- **WHEN** module `App` injects `Missing` into a binding that reachability retains, and no activated module produces `Missing`
- **THEN** the rendered output contains `no binding produces`

#### Scenario: an unreachable binding with an unresolvable dependency
- **WHEN** library `WireHarnessLibrary` declares `@Singleton LibraryBindingNeedingDeep`, which injects `DeepConfig` from a package the consumer never depends on, and nothing in the consumer reaches it
- **THEN** no missing-binding error is reported and the consumer builds

Pinned by: `Tests/WireGenCoreTests/CrossLibraryValidationTests.swift` (`crossLibraryDependencyResolvesAcrossModules`, `crossLibraryMissingBindingFires`, `crossLibraryKeyReferenceResolves`), `Tests/WireGenCoreTests/ReachabilityTests.swift` (`missingBindingInPrunedSubgraphIsNotAnError`, `missingBindingInRetainedSubgraphStillFails`), `.github/workflows/swift.yml` (`CompositionHarness`).

### Requirement: A cross-module duplicate names each module
When the bindings of one duplicate identity come from more than one origin module, WireGen SHALL
suffix the error and each "also bound here" note with ` (module '<Module>')`. A duplicate within one
module SHALL keep the unsuffixed wording.

#### Scenario: two libraries bind one type
- **WHEN** module `LibA` declares `@Provides let a: Cache = Cache()` and module `LibB` declares `@Provides let b: Cache = Cache()`
- **THEN** the rendered output contains `has multiple bindings`, `module 'LibA'` and `module 'LibB'`

#### Scenario: a duplicate inside one module
- **WHEN** both `Cache` bindings come from one module
- **THEN** the rendered output contains `has multiple bindings` and no `module '`

Pinned by: `Tests/WireGenCoreTests/CrossLibraryValidationTests.swift` (`crossLibraryAmbiguityNamesConflictingModules`, `sameModuleDuplicateKeepsOriginalWording`).

### Requirement: `withOrder:` ranks are unique across modules
WireGen SHALL check `withOrder:` uniqueness per key over the contributions of every activated module
merged into one partition, as specified in [multibindings](../multibindings/spec.md), so two modules
contributing the same rank to one key is an error.

#### Scenario: two libraries claim rank 1
- **WHEN** module `LibA` and module `LibB` each contribute to `App.services` with `withOrder: 1`
- **THEN** the later contribution is reported with `duplicate withOrder: 1 on 'App.services' — contributor ranks must be unique.`

Pinned by: nothing yet.

### Requirement: `@Wire::X` selects Wire's macros only
When discovering bindings, dependencies, contributions and teardowns, WireGen SHALL recognise a Wire
macro attribute written with an SE-0491 module selector naming `Wire` (`@Wire::Singleton`,
`@Wire::Inject`, `@Wire::Contributes`, and so on, whitespace around `::` ignored) exactly as the bare
name, and SHALL NOT recognise the same name qualified with any other module. The injection-rewrite
candidate scan is the exception: it skips only the bare `Bind`, `Inject`, `Provides` and `Teardown`, so
on `@Wire::Inject @FromSettings(...) var level: String` it records `Wire::Inject` as the candidate and
no adapter rewrite happens, which is tracked as a defect in
https://github.com/swift-wire/swift-wire/issues/413.

#### Scenario: qualified Wire macros
- **WHEN** a source declares `@Wire::Singleton final class View { @Wire::Inject var logger: Logger }`
- **THEN** discovery records the singleton `View` with one `Logger` dependency

#### Scenario: another module's macro
- **WHEN** a source declares `@OtherDI::Singleton final class View {}`
- **THEN** discovery records no singleton

Pinned by: `Tests/WireGenCoreTests/DiscoveryTests.swift` (`moduleQualifiedWireMacrosRecognized`, `otherModuleQualifiedMacroNotRecognizedAsWire`), `Tests/WireGenCoreTests/ContributionDiscoveryTests.swift` (`moduleQualifiedContributesSelectorIsRecognised`). The injection-rewrite exception is pinned by nothing yet.

### Requirement: `@Replaces` is a marker that generates nothing
The `@Replaces` macro SHALL be an argumentless peer macro whose expansion is empty.

#### Scenario: expanding the marker
- **WHEN** `@Replaces` is attached to `@Provides func fakeClient() -> Client`
- **THEN** the macro expansion adds no declaration

Pinned by: nothing yet.

### Requirement: Discovery records `@Replaces` on its co-located binding
WireGen SHALL record `@Replaces` on a co-located `@Singleton`, `@Scoped` or `@Provides` binding as that
binding replacing its slot (`isReplacer`).

#### Scenario: a singleton replacement
- **WHEN** a source declares `@Singleton(as: Repo.self) @Replaces struct FakeRepo: Repo`
- **THEN** discovery records one singleton whose `isReplacer` is true

#### Scenario: a keyed provider replacement
- **WHEN** a source declares `@Provides(Client.primary) @Replaces func fakeClient() -> Client`
- **THEN** discovery records one provider whose `isReplacer` is true and whose `keyIdentifier` is `Client.primary`

Pinned by: `Tests/WireGenCoreTests/DiscoveryTests.swift` (`singletonReplacesMarkerCaptured`, `providesReplacesMarkerCaptured`, `providesKeyedReplacesMarkerCaptured`). The `@Scoped` form is pinned by nothing yet.

### Requirement: A home-module `@Replaces` supersedes the other bindings of its slot
When a binding in the consumer module carries `@Replaces`, WireGen SHALL drop every other binding of
that binding's identity before duplicate detection. A keyed replacer SHALL supersede only its keyed
slot, and an unkeyed one only the unkeyed slot.

#### Scenario: a test fake over an app binding
- **WHEN** module `Lib` binds `RealRepo` and module `App`, the consumer, binds `FakeRepo` with `@Replaces`, both as `Repo`
- **THEN** the graph builds with no warning and its order holds only `FakeRepo`

#### Scenario: an unkeyed replacer and a keyed slot
- **WHEN** module `Lib` binds `RealRepo` and `@Provides(Repo.primary) realPrimary`, and module `App` binds `FakeRepo` with a bare `@Replaces`, all as `Repo`
- **THEN** the graph holds `FakeRepo` and the keyed `Repo.primary` provider, and not `RealRepo`

Pinned by: `Tests/WireGenCoreTests/ReplacesTests.swift` (`homeModuleReplacesIsHonoured`, `keyedReplaceSupersedesSameKeyedBinding`, `unkeyedReplacesDoesNotCrossIntoKeyedSlot`). That a keyed replacer leaves an unkeyed binding of the same type in place is pinned by nothing yet.

### Requirement: `@Replaces` outside the consumer module has no effect
WireGen SHALL honour `@Replaces` only on bindings whose origin is the consumer module. For a
`@Replaces` in another module of the same package it SHALL warn "@Replaces on '<Type>' in module
'<Module>' has no effect — only the composition root's own module ('<Home>') may override a binding";
for one in an external-package module it SHALL say nothing. Either way the binding SHALL remain an
ordinary binding.

#### Scenario: a sibling module's replacement
- **WHEN** module `HelperLib` of the consumer's package carries `@Replaces` over a binding also produced elsewhere, and the consumer is `App`
- **THEN** one warning containing `has no effect`, `HelperLib` and `App` is reported, and the duplicate is an error

#### Scenario: an external module's replacement
- **WHEN** the `@Replaces` binding originates in an external-package module
- **THEN** no warning is reported and the duplicate is an error

Pinned by: `Tests/WireGenCoreTests/ReplacesTests.swift` (`homePackageReplacesIgnoredWithWarning`, `externalModuleReplacesIgnoredSilently`, `plainDuplicateStillErrorsWithoutReplaces`).

### Requirement: A `@Replaces` must have something to replace
WireGen SHALL report "@Replaces has nothing to supersede — no other binding produces '<slot>'. Remove
the @Replaces, or bind the type it should override." for an honoured `@Replaces` binding that is the
only binding of its identity.

#### Scenario: a stale override
- **WHEN** a `@Replaces` binding is the only producer of its slot
- **THEN** validation fails with the error containing `nothing to supersede`

Pinned by: `Tests/WireGenCoreTests/ReplacesTests.swift` (`replacesWithNothingToSupersedeDiagnosed`).

### Requirement: At most one `@Replaces` per slot
WireGen SHALL report "'<slot>' has more than one @Replaces binding; at most one binding may supersede a
given key" when two honoured `@Replaces` bindings share an identity, with a note "also replaces
'<slot>' here" at each further one.

#### Scenario: two replacers
- **WHEN** two `@Replaces` bindings in the consumer module produce the same slot
- **THEN** validation fails with the error containing `more than one @Replaces` and one related binding

Pinned by: `Tests/WireGenCoreTests/ReplacesTests.swift` (`twoReplacersForOneKeyDiagnosed`).

### Requirement: `@Replaces` cannot supersede a binding of its own module
WireGen SHALL report "@Replaces can't supersede a binding in the same module ('<Module>') — it
overrides a binding composed from a dependency. Two same-module bindings for one key are a duplicate:
remove one, or disambiguate with named keys." when a binding the replacer would drop shares its origin
module, with a note "also bound here (module '<Module>')" at each such binding.

#### Scenario: replacing a sibling in one module
- **WHEN** a `@Replaces` binding and the binding it would supersede both originate in `AppServer`
- **THEN** validation fails with the error containing `same module`

Pinned by: `Tests/WireGenCoreTests/ReplacesTests.swift` (`replacingSameModuleBindingDiagnosed`).

## Related specifications

- [build-plugin-and-wiregen-cli](../build-plugin-and-wiregen-cli/spec.md)
- [visibility-and-access](../visibility-and-access/spec.md)
- [reachability-and-retention](../reachability-and-retention/spec.md)
- [graph-conformance](../graph-conformance/spec.md)
- [multibindings](../multibindings/spec.md)
- [testing-variants](../testing-variants/spec.md)
