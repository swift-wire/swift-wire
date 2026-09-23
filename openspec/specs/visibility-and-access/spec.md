# Visibility and access

## Purpose

WireGen reads each binding's source-level access modifier and checks it against what the generated
bootstrap, which lives in a separate file and possibly a separate module, can reference. A name the
bootstrap references must be at least `internal` in its own module, at least `package` when a sibling
module composes it, and `public` when a module in another package composes it. The same access level
also gates the dead-binding warning, which stays silent where Wire cannot see every consumer.

Rationale: [VisibilityModel](../../../Documentation/Notes/VisibilityModel.md), [MultiModuleComposition](../../../Documentation/Notes/MultiModuleComposition.md).
Documentation: [ComposingAcrossModules](../../../Sources/Wire/Wire.docc/ComposingAcrossModules.md).

## Requirements

### Requirement: Access is read from the declaration's own modifiers
WireGen SHALL read a declaration's access from its own modifier list, treating a declaration with no
access modifier as `internal`. `internal`, `package`, `public` and `open` SHALL count as visible to the
generated bootstrap; `fileprivate` and `private` SHALL NOT. A member of a `public extension` with no
modifier of its own therefore reads as `internal`
([swift-wire#342](https://github.com/swift-wire/swift-wire/issues/342)).

#### Scenario: an unmodified singleton
- **WHEN** a source declares `@Singleton struct Visible {}`
- **THEN** discovery reports no error

#### Scenario: an unmodified provider in a public enum
- **WHEN** a source declares `public enum Config { @Provides static let baseURL: URL = URL(string: "...")! }`
- **THEN** discovery reports no error

Pinned by: `Tests/WireGenCoreTests/DiscoveryTests.swift` (`internalSingletonDoesNotEmitDeclarationTooPrivateError`, `providesInPublicEnclosingEnumDoesNotEmitError`).

### Requirement: A `@Singleton` or `@Scoped` type must be at least `internal`
WireGen SHALL report an error "<surface> '<name>' is '<keyword>' but must be at least 'internal' —
Wire's generated bootstrap lives in a separate file and can't reference fileprivate/private
declarations. Change to 'internal', 'package', or 'public'." at the name of a `@Singleton` or
`@Scoped(seed:)` type declared `private` or `fileprivate`, where the surface is `@Singleton type` or
`@Scoped type`.

#### Scenario: a private singleton
- **WHEN** `Hidden.swift` declares `@Singleton private struct Hidden {}`
- **THEN** the rendered output contains `Hidden.swift:2:16: error:` and `@Singleton type 'Hidden' is 'private'` and ends the message with `Change to 'internal', 'package', or 'public'`

#### Scenario: a private scoped type
- **WHEN** a source declares `@Scoped(seed: SessionSeed.self) private struct Hidden {}`
- **THEN** discovery reports one error containing `@Scoped type 'Hidden'`

Pinned by: `Tests/WireGenCoreTests/DiscoveryTests.swift` (`privateSingletonEmitsDeclarationTooPrivateError`, `fileprivateSingletonEmitsDeclarationTooPrivateError`, `privateScopedEmitsDeclarationTooPrivateError`), `Tests/WireGenCoreTests/DiagnosticGalleryTests.swift` (`privateSingletonRendersAsErrorWithFixIts`).

### Requirement: A `@Provides` declaration must be at least `internal`
WireGen SHALL report the same error at a `@Provides` property or function declared `private` or
`fileprivate`, with the surface `@Provides declaration` for a property and `@Provides function` for a
function.

#### Scenario: a private provided property
- **WHEN** `Logger.swift` declares `@Provides private let logger: Logger = Logger()`
- **THEN** the rendered output contains `Logger.swift:1:23: error:` and `@Provides declaration 'logger' is 'private'`

#### Scenario: a fileprivate provider function
- **WHEN** a source declares `@Provides fileprivate func makeLogger() -> Logger { Logger() }`
- **THEN** discovery reports one error containing `@Provides function 'makeLogger'` and `'fileprivate'`

Pinned by: `Tests/WireGenCoreTests/DiscoveryTests.swift` (`privateProvidesLetEmitsDeclarationTooPrivateError`, `fileprivateProvidesFuncEmitsDeclarationTooPrivateError`), `Tests/WireGenCoreTests/DiagnosticGalleryTests.swift` (`privateProvidesLetRendersAsError`).

### Requirement: An enclosing scope caps a binding's effective access
WireGen SHALL fold a `@Provides`, `@Singleton` or `@Scoped` declaration's own access with every
enclosing type's access, taking the most restrictive. When the declaration's own modifier is visible
but the effective access is not, the error SHALL read "<surface> '<name>' is effectively '<keyword>'
because its enclosing scope '<scope>' is '<keyword>' — Wire's generated bootstrap lives in a separate
file and can't reference fileprivate/private declarations. Raise '<scope>' to 'internal', 'package',
or 'public'.", naming the most restrictive enclosing scope.

#### Scenario: a provider in a private namespace enum
- **WHEN** `Config.swift` declares `private enum Config { @Provides static let baseURL: URL = URL(string: "...")! }`
- **THEN** the rendered output contains `Config.swift:2:26: error:`, `@Provides declaration 'baseURL' is effectively 'private'`, `enclosing scope 'Config' is 'private'` and `Raise 'Config' to 'internal', 'package', or 'public'`

#### Scenario: a singleton nested in a private type
- **WHEN** a source declares `private struct Outer { @Singleton struct Inner {} }`
- **THEN** discovery reports one error containing `@Singleton type 'Inner'` and `enclosing scope 'Outer' is 'private'`

#### Scenario: the outer scope is the limiter
- **WHEN** a `@Provides static let` sits in `public enum Inner` nested in `private enum Outer`
- **THEN** the one error names `enclosing scope 'Outer' is 'private'`

Pinned by: `Tests/WireGenCoreTests/DiscoveryTests.swift` (`providesInPrivateEnclosingEnumEmitsDeclarationTooPrivateError`, `providesFuncInFileprivateEnclosingEnumEmitsDeclarationTooPrivateError`, `singletonNestedInPrivateTypeEmitsDeclarationTooPrivateError`, `providesInNestedEnumsBlamesMostRestrictiveEnclosingScope`), `Tests/WireGenCoreTests/DiagnosticGalleryTests.swift` (`providesInPrivateEnclosingEnumRendersAsError`).

### Requirement: A too-private own modifier is reported ahead of its enclosing scope
When the declaration's own modifier is itself `private` or `fileprivate`, WireGen SHALL report the
own-modifier form of the error, whatever the enclosing scopes are.

#### Scenario: both the binding and its enum are private
- **WHEN** a `@Provides private static let` sits inside a `private enum`
- **THEN** the error uses the "is 'private' but must be at least 'internal'" form rather than naming the enum

Pinned by: `Tests/WireGenCoreTests/DiscoveryTests.swift` (`ownPrivateModifierWinsOverEnclosingScopeInDiagnostic`).

### Requirement: Member-injection and teardown access errors are specified with their features
The access floor for `@Inject init`, `@Inject weak var` (including its setter) and `@Inject func`, with
the note explaining why a constructor-injected `@Inject private var` is accepted while these are not,
SHALL be as specified in [injection-points](../injection-points/spec.md). The floor for a member
`@Teardown` method SHALL be as specified in [teardown](../teardown/spec.md).

#### Scenario: a private weak var carries the asymmetry note
- **WHEN** a `@Singleton` class declares `@Inject private weak var coordinator: Coordinator?`
- **THEN** the rendered output contains `@Inject weak var 'coordinator' is 'private'` followed by a `note:` containing `can be 'private' because the macro generates the init` and `post-construct delivery patterns`

Pinned by: `Tests/WireGenCoreTests/DiagnosticGalleryTests.swift` (`privateInjectWeakVarRendersWithAsymmetryNote`, `privateInjectFuncRendersWithAsymmetryNote`).

### Requirement: The dead-binding warning covers only what reachability did not judge
WireGen SHALL run the dead-binding check only over bindings no pruned graph's reachability decided,
retained or pruned; in practice these are the bindings of seed-scope partitions. A binding a pruned
graph judged SHALL be reported, if at all, by the pruned-binding warning of
[reachability-and-retention](../reachability-and-retention/spec.md).

#### Scenario: a pruned home binding is reported once
- **WHEN** an unconsumed `internal` binding sits in the default graph, which reachability prunes
- **THEN** the pruned-binding warning reports it and the dead-binding pass does not

Pinned by: `Tests/WireGenCoreTests/PrunedBindingDiagnosticsTests.swift` (`reachabilitySupersedesTheDeadBindingWarning`).

### Requirement: An unconsumed `internal` or `package` binding warns
Within the bindings it judges, WireGen SHALL warn "'<Type>' is declared but nothing in the build
consumes it. Inject it somewhere, raise it to 'public' if it's consumed outside this <target|package>,
or mark it 'allowUnused: true' to silence." for each `internal` or `package` binding that no
initialiser dependency and no member-injection parameter in its container consumes. The word is
`package` for a `package` binding and `target` otherwise, and a keyed slot is rendered `'<Type>' (key
<Key>)`.

#### Scenario: an orphan internal singleton
- **WHEN** a container holds an `internal` `@Singleton` `Orphan` that nothing injects
- **THEN** one warning at `Orphan.swift` contains `'Orphan' is declared but nothing in the build consumes it` and `allowUnused: true`

#### Scenario: an optional consumer keeps the producer live
- **WHEN** a consumer injects `Foo?` and a binding produces `Foo`
- **THEN** the `Foo` producer does not warn

Pinned by: `Tests/WireGenCoreTests/DeadBindingDiagnosticsTests.swift` (`unusedInternalSingletonWarnsWithExplanatoryMessage`, `unusedPackageSingletonWarns`, `unusedProviderWarns`, `optionalConsumerKeepsProducerLive`, `unconsumedKeyedBindingNamesTheKeyedSlot`).

### Requirement: An unconsumed `public` or `open` binding is silent
WireGen SHALL NOT raise the dead-binding warning for a `public` or `open` binding.

#### Scenario: an orphan public singleton
- **WHEN** a container holds a `public` `@Singleton` that nothing injects
- **THEN** no warning is reported

Pinned by: `Tests/WireGenCoreTests/DeadBindingDiagnosticsTests.swift` (`unusedPublicSingletonIsSilent`, `unusedOpenSingletonIsSilent`).

### Requirement: `allowUnused: true` silences the dead-binding warning
WireGen SHALL NOT raise the dead-binding warning for a binding written with `allowUnused: true`.

#### Scenario: an orphan marked allowUnused
- **WHEN** an unconsumed `internal` singleton is declared `@Singleton(allowUnused: true)`
- **THEN** no warning is reported

Pinned by: `Tests/WireGenCoreTests/DeadBindingDiagnosticsTests.swift` (`allowUnusedSilencesTheWarning`).

### Requirement: Liveness is judged per container across its scopes
WireGen SHALL judge dead-binding liveness per container, counting consumers from every scope of that
container, and SHALL NOT count a consumer in another container.

#### Scenario: a singleton consumed only inside a seed scope
- **WHEN** an app singleton is injected only by a `@Scoped(seed:)` binding of the same container
- **THEN** the singleton does not warn

#### Scenario: a consumer in a different container
- **WHEN** the only consumer of a binding is in another `@Container`
- **THEN** the binding warns

Pinned by: `Tests/WireGenCoreTests/DeadBindingDiagnosticsTests.swift` (`singletonConsumedOnlyByScopeIsLive`, `crossContainerConsumptionDoesNotKeepBindingLive`).

### Requirement: Contributors, generic bindings and scope-entry subjects are not reported dead
WireGen SHALL NOT raise the dead-binding warning for a binding that contributes to a multibinding, a
binding with generic parameters, or a binding a bridging proxy's scope-entry thunk constructs as its
subject or yields.

#### Scenario: a scoped subject behind a proxy
- **WHEN** a `.singleton` proxy's scope-entry thunk constructs a `@Scoped(seed:)` subject nothing else injects
- **THEN** the subject does not warn

#### Scenario: a scoped type with no proxy
- **WHEN** a `@Scoped(seed:)` type is consumed by nothing and no proxy constructs it
- **THEN** it warns

Pinned by: `Tests/WireGenCoreTests/DeadBindingDiagnosticsTests.swift` (`contributorIsLiveViaItsAggregate`, `concreteProducerConsumedViaSpecialisationIsLive`, `scopedSubjectIsLiveThroughItsProxysScopeEntryThunk`, `aYieldedBindingIsLiveThroughTheSameThunk`, `aScopedTypeNoProxyConstructsStillWarns`).

### Requirement: A binding composed from a sibling module must be at least `package`
WireGen SHALL report an error "'<Type>' is 'internal' but is composed into module '<Consumer>' from
sibling module '<Origin>' — cross-module references need at least 'package'. Make it 'package' or
'public'." for each `internal` binding whose origin module differs from the consumer module and is
not an external-package module. Bindings originating in the consumer module SHALL keep the `internal`
floor, and synthesised aggregates SHALL NOT be checked.

#### Scenario: an internal binding from a sibling target
- **WHEN** module `App` composes an `internal` singleton from sibling module `SiblingLib`
- **THEN** the error contains `at least 'package'` and `sibling module 'SiblingLib'`

#### Scenario: a package binding from a sibling target
- **WHEN** module `App` composes a `package` singleton from `SiblingLib`
- **THEN** no error is reported

Pinned by: `Tests/WireGenCoreTests/CrossModuleVisibilityTests.swift` (`ownModuleInternalIsFine`, `samePackageForeignInternalNeedsPackage`, `samePackageForeignPackageIsFine`, `samePackageForeignPublicIsFine`).

### Requirement: A binding composed from an external package must be `public`
WireGen SHALL report an error "'<Type>' is '<keyword>' but is composed into module '<Consumer>' from
external-package module '<Origin>' — '<keyword>' isn't visible across packages. Make it 'public'." for
each `internal` or `package` binding whose origin module was passed as an `--external-module`.

#### Scenario: a package binding from another package
- **WHEN** module `App` composes a `package` singleton from external module `ExtLib`
- **THEN** the error contains `across packages`

#### Scenario: an internal binding from another package
- **WHEN** module `App` composes an `internal` singleton from external module `ExtLib`
- **THEN** the error contains `external-package module 'ExtLib'` and `Make it 'public'`

Pinned by: `Tests/WireGenCoreTests/CrossModuleVisibilityTests.swift` (`externalForeignInternalNeedsPublic`, `externalForeignPackageNeedsPublic`, `externalForeignPublicIsFine`).

## Related specifications

- [injection-points](../injection-points/spec.md)
- [teardown](../teardown/spec.md)
- [reachability-and-retention](../reachability-and-retention/spec.md)
- [multi-module-composition](../multi-module-composition/spec.md)
- [build-plugin-and-wiregen-cli](../build-plugin-and-wiregen-cli/spec.md)
