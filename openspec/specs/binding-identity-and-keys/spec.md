# Binding identity and keys

## Purpose

How WireGen decides which producer satisfies a dependency. A binding's identity, and a
dependency's, is the canonical text of the type expression as written plus an optional key text.
WireGen reads syntax only, so it resolves no conformances and unwraps no typealiases. Each
dependency has exactly one matching producer, or the graph fails with a duplicate-binding or a
missing-binding error. `BindingKey<T>` keys a binding, and `_WireKeyChecks.swift` makes the compiler
check the key of each keyed provider and keyed init-time dependency against its site's type. How a generic `@Provides func` is specialised per
instantiation is specified in [providers](../providers/spec.md); when a specialisation and another
producer both match, the duplicate is reported here.

Rationale: [OptionalMatchingAndCycles](../../../Documentation/Notes/OptionalMatchingAndCycles.md), [OpaqueTypesSupport](../../../Documentation/Notes/OpaqueTypesSupport.md).
Documentation: [ResolutionAndKeys](../../../Sources/Wire/Wire.docc/ResolutionAndKeys.md).

## Requirements

### Requirement: An identity is the written type text with whitespace stripped
WireGen SHALL identify a binding and a dependency by the text of the type expression as written,
with every whitespace character removed. Generated code SHALL keep the type as written.

#### Scenario: spacing inside generic arguments
- **WHEN** a producer binds `Router<X, Y>` and a consumer injects `Router<X,Y>`
- **THEN** the consumer resolves to the producer

#### Scenario: a function type
- **WHEN** `(Int) -> String` is canonicalised
- **THEN** the identity text is `(Int)->String`

Pinned by: `Tests/WireGenCoreTests/BindingIdentityTests.swift` (`stripsWhitespaceInGenericArguments`, `leavesAFunctionTypeIntact`), `Tests/WireGenCoreTests/GraphTests.swift` (`bindingsOfSameTypeWithDifferentWhitespaceAreDuplicates`, `consumerWithDifferentWhitespaceResolvesToProvider`, `internalAndOuterWhitespaceAreAllStripped`), `Tests/WireGenCoreTests/CodeEmissionTests.swift` (`multipleGenericParametersUseAndSeparator`).

### Requirement: Top-level composition members are sorted
WireGen SHALL sort the members of a protocol composition that are separated by `&` at bracket depth
zero, keeping a leading `some` or `any` in front. A composition nested in generic arguments,
brackets or parentheses SHALL be left in written order.

#### Scenario: two spellings of one composition
- **WHEN** `DBTable & Sendable` and `Sendable & DBTable` are canonicalised
- **THEN** both are `DBTable&Sendable`, and `some Sendable & DBTable` is `someDBTable&Sendable`

#### Scenario: a nested composition
- **WHEN** `Box<B & A>` is canonicalised
- **THEN** the identity text is `Box<B&A>`

Pinned by: `Tests/WireGenCoreTests/BindingIdentityTests.swift` (`sortsCompositionMembers`, `keepsTheOpaqueQualifierLeading`, `doesNotSortANestedComposition`, `doesNotSortAParenthesisedComposition`, `bridgesAReorderedConstraintToTheSameIdentity`).

### Requirement: A leading `some` or `any` is part of the identity
WireGen SHALL treat a leading `some` or `any` followed by whitespace as the identity's qualifier,
distinct from the unqualified type of the same name. A type name that merely begins with those
letters SHALL NOT be read as qualified.

#### Scenario: a type named like a qualifier
- **WHEN** `anything & Zed` is canonicalised
- **THEN** the identity text is `Zed&anything`, not `anyZed&thing`

Pinned by: `Tests/WireGenCoreTests/BindingIdentityTests.swift` (`doesNotMistakeATypeNameForAQualifier`, `keepsTheOpaqueQualifierLeading`).

### Requirement: No conformance is resolved
WireGen SHALL NOT match a dependency to a producer of a different identity because one conforms to
or inherits from the other. A producer of a concrete type SHALL NOT satisfy an `any P` or `some P`
dependency, and SHALL NOT collide with a producer of `any P`.

#### Scenario: a conforming concrete producer
- **WHEN** a producer binds `Logger` and a consumer injects `any Logger`
- **THEN** the consumer's dependency is a missing binding

Pinned by: `Tests/WireGenCoreTests/BindingIdentityTests.swift` (`aConcreteProducerNeverSatisfiesAnExistential`), `Tests/WireGenCoreTests/GraphTests.swift` (`aConcreteBindingIsNotADuplicateOfTheExistential`). The `some P` dependency case is pinned by nothing yet.

### Requirement: Typealiases are not unwrapped
WireGen SHALL resolve a dependency written as a typealias name by that name only. When the
dependency is missing and a module-scope, non-generic typealias of that name has an underlying type
that is bound under the same key, the missing-binding error SHALL carry the note "'<Alias>' is a
typealias of '<Underlying>' which is bound; typealiases aren't unwrapped at resolution, so inject
'<Underlying>' directly or add a separate binding for '<Alias>'" at the typealias. A dependency
written as an optional of the alias (`UserID?`) gets no such note, which is tracked as a defect in
https://github.com/swift-wire/swift-wire/issues/424.

#### Scenario: an alias of a bound type
- **WHEN** `typealias UserID = UUID` is declared, `@Provides let uuid: UUID = UUID()` is bound, and `Service` declares `@Inject var userID: UserID`
- **THEN** the output contains "error: no binding produces 'UserID'" and "note: 'UserID' is a typealias of 'UUID'"

Pinned by: `Tests/WireGenCoreTests/GraphTests.swift` (`missingBindingForTypealiasAttachesHintWhenUnderlyingIsBound`, `missingBindingWithTypealiasButUnboundUnderlyingHasNoHint`), `Tests/WireGenCoreTests/DiagnosticGalleryTests.swift` (`missingBindingForTypealiasRendersNoteAtUnderlyingType`), `Tests/WireGenCoreTests/DiscoveryTests.swift` (`moduleScopeTypealiasIsCaptured`, `nestedTypealiasIsNotCaptured`, `genericTypealiasIsNotCaptured`). The optional-alias case is pinned by nothing yet.

### Requirement: Two producers of one identity are a duplicate-binding error
When two or more bindings in one partition have the same identity, and none of them is an
honoured `@Replaces` binding (which supersedes the others, see
[multi-module-composition](../multi-module-composition/spec.md)), WireGen SHALL report
"type '<T>' has multiple bindings; the dependency graph is ambiguous" at the first and
"also bound here" notes at each other, naming the key as `'<T>' keyed '<Key>'` for a keyed slot.
When the bindings come from different modules, the error line and each "also bound here" note
SHALL end with ` (module '<Module>')`.

#### Scenario: two singletons
- **WHEN** `Logger.swift` declares `@Singleton struct Logger` at line 2 and again at line 6
- **THEN** the output contains "Logger.swift:2:8: error: type 'Logger' has multiple bindings; the dependency graph is ambiguous" and "Logger.swift:6:8: note: also bound here"

#### Scenario: two libraries
- **WHEN** module `LibA` and module `LibB` each declare `@Provides let …: Cache = Cache()`
- **THEN** the duplicate error names `module 'LibA'` and `module 'LibB'`

Pinned by: `Tests/WireGenCoreTests/DiagnosticGalleryTests.swift` (`twoSingletonsForSameTypeFlagWithNoteOnSecond`, `singletonAndProviderForSameTypeIsAlsoAmbiguous`, `keyedDuplicateBindingNamesTheKeyAndOmitsFixItNote`), `Tests/WireGenCoreTests/GraphTests.swift` (`twoSingletonsForSameTypeAreFlaggedAsDuplicate`, `singletonAndProviderForSameTypeAreFlaggedAsDuplicate`, `sameTypeWithSameKeyIsDuplicate`), `Tests/WireGenCoreTests/CrossLibraryValidationTests.swift` (`crossLibraryAmbiguityNamesConflictingModules`, `sameModuleDuplicateKeepsOriginalWording`), `Tests/WireGenCoreTests/ReplacesTests.swift` (`providesReplacesSupersedesConcreteSingleton`, `replacesSupersedesSameKeyBindingFromAnotherModule`, `plainDuplicateStillErrorsWithoutReplaces`).

### Requirement: An unkeyed duplicate carries a key fix-it note
For an unkeyed duplicate, WireGen SHALL add the note "to disambiguate, declare named keys (e.g.
`static let primary = BindingKey<<T>>()`) and tag each binding/consumer with
`@Provides(<T>.primary)` / `@Inject(<T>.primary)`" at the first binding. A keyed duplicate SHALL
carry no such note. `<T>` is the canonical identity text, so for a `some` or `any` type the note
suggests `BindingKey<anyLogger>()`, which is not valid Swift; this is tracked as a defect in
https://github.com/swift-wire/swift-wire/issues/423.

#### Scenario: two unkeyed databases
- **WHEN** two unkeyed providers bind `Database`
- **THEN** the report contains `BindingKey<Database>()`, `@Provides(Database.primary)` and `@Inject(Database.primary)`

Pinned by: `Tests/WireGenCoreTests/GraphTests.swift` (`renderUnkeyedDuplicateAppendsFixItNote`, `renderDuplicateKeyedBindingsNamesTheKey`, `someAndAnyProducersForOneProtocolAreDuplicates`), `Tests/WireGenCoreTests/DiagnosticGalleryTests.swift` (`unkeyedDuplicateBindingShowsFixItNote`, `keyedDuplicateBindingNamesTheKeyAndOmitsFixItNote`).

### Requirement: Duplicates stop validation before resolution
When any duplicate binding is found, WireGen SHALL fail the graph with the duplicates alone and
SHALL NOT report missing bindings or cycles for it.

#### Scenario: a duplicate and a missing dependency
- **WHEN** two bindings produce `Logger` and `App` depends on an unbound `Missing`
- **THEN** one duplicate is reported and no missing binding or cycle

Pinned by: `Tests/WireGenCoreTests/GraphTests.swift` (`duplicateBindingsShortCircuitOtherValidation`).

### Requirement: A dependency with no producer is a missing-binding error
When no producer's identity satisfies a dependency, WireGen SHALL report "no binding produces
'<T>'", or "no binding produces '<T>' keyed '<Key>'" for a keyed dependency, anchored at the
dependency's own source location.

#### Scenario: an unbound injected property
- **WHEN** `Greeter.swift` is the whole graph and holds `@Singleton` on line 1, `struct Greeter {` on line 2 and `    @Inject var logger: Logger` on line 3
- **THEN** the output contains "Greeter.swift:3:17: error: no binding produces 'Logger'"

#### Scenario: an unbound key
- **WHEN** a consumer declares `@Inject(Database.primary) var db: Database` and nothing binds that slot
- **THEN** the output contains "error: no binding produces 'Database' keyed 'Database.primary'"

Pinned by: `Tests/WireGenCoreTests/DiagnosticGalleryTests.swift` (`missingBindingForPrimitiveTypeAnchorsAtInjectSite`, `missingBindingPointsAtEachUnsatisfiedDependencySeparately`, `keyedMissingBindingIncludesKeyInMessage`), `Tests/WireGenCoreTests/GraphTests.swift` (`dependencyOnUndiscoveredTypeRecordedAsMissing`, `multipleMissingBindingsAllRecorded`, `renderMissingBindingForKeyedSlotIncludesKey`).

### Requirement: Keyed and unkeyed identities never match each other
WireGen SHALL match an unkeyed dependency only to an unkeyed producer and a keyed dependency only to
a producer with the same key text. Two producers of one type with different keys, or one keyed and
one unkeyed, SHALL coexist.

#### Scenario: a keyed consumer beside an unkeyed binding
- **WHEN** `appName: AppName` is bound unkeyed, `@Provides(AppName.alternate)` binds another `AppName`, and a consumer declares `@Inject(AppName.alternate) var alternate: AppName`
- **THEN** the consumer receives the `AppName.alternate` value and the graph exposes both `appName` and `appNameKeyedAppNameAlternate`

#### Scenario: a keyed dependency with only an unkeyed producer
- **WHEN** a consumer asks for `Database` keyed `Database.primary` and only an unkeyed `Database` is bound
- **THEN** the dependency is a missing binding

Pinned by: `Tests/WireGenCoreTests/GraphTests.swift` (`sameTypeWithDifferentKeysCoexist`, `keyedAndUnkeyedSameTypeCoexist`, `keyedDependencyResolvesToKeyedBinding`, `keyedDependencyDoesNotMatchUnkeyedBinding`, `unkeyedDependencyDoesNotMatchKeyedBinding`), `Tests/IntegrationTests/BootstrapTests.swift` (`keyedConsumerInjectsTheMatchingKeyedProvider`, `keyedInitParameterInjectsTheMatchingKeyedProvider`).

### Requirement: A key is identified by its written text
WireGen SHALL record a key reference (`@Provides(<key>)`, `@Inject(<key>)`, or `@Bind(<key>)` on an
`@Inject init` or `@Provides func` parameter) as the trimmed source text of the expression and
compare keys by that text. A `@Bind(<key>)` on an `@Inject func` parameter is not read, so that
parameter is recorded as unkeyed, which is tracked as a defect in
https://github.com/swift-wire/swift-wire/issues/367.

#### Scenario: a member-access key
- **WHEN** `@Provides(Database.primary) let db: Database = Database()` is discovered
- **THEN** the provider's key is `Database.primary`

Pinned by: `Tests/WireGenCoreTests/DiscoveryTests.swift` (`providesWithMemberAccessKeyExtractsCanonicalText`, `injectPropertyWithKeyExtractsCanonicalText`, `injectInitParameterWithBindKeyExtractsCanonicalText`, `bareIdentifierKeyExtractsAsIs`). The `@Inject func` parameter case is pinned by nothing yet.

### Requirement: `BindingKey<T>` is a stateless phantom type
`BindingKey<Value>` SHALL be a public `Sendable` struct with a single `public init()` and no stored
state.

#### Scenario: a key declaration
- **WHEN** `extension Database { static let primary = BindingKey<Database>() }` is compiled
- **THEN** it declares a key whose only content is its type parameter `Database`

Pinned by: nothing yet.

### Requirement: A referenced key must be declared
WireGen SHALL record as a declared key each module-scope or `static` single-binding `let` or `var`
whose type annotation is `BindingKey…` or whose initialiser calls `BindingKey(…)` or
`BindingKey<T>(…)`, under the reference of its enclosing type names and its name joined by `.`.
Each `@Provides`, `@Inject` or `@Bind` key reference that names neither a declared `BindingKey` nor
a multibinding key in the parse set SHALL be the error "key '<K>' is referenced but never declared —
declare a 'static let <K> = BindingKey<T>()' (or a CollectedKey/MappedKey/BuilderKey for a
multibinding) in the parse set, or fix the reference."

#### Scenario: a key on an extension
- **WHEN** `extension Database { static let primary = BindingKey<Database>() }` is discovered
- **THEN** the declared key reference is `Database.primary` with type argument `Database`

#### Scenario: an undeclared key
- **WHEN** a consumer references `Database.primary` and no such key is declared
- **THEN** WireGen reports an error containing "'Database.primary' is referenced but never declared"

Pinned by: `Tests/WireGenCoreTests/BindingKeyDiscoveryTests.swift` (`bindingKeyOnExtensionCapturesReferenceAndType`, `bindingKeyFromExplicitAnnotation`, `moduleScopeBindingKeyHasUnqualifiedReference`, `bindingKeyWithoutGenericsRecordsNilType`, `nonKeyDeclarationsAreIgnored`, `undeclaredKeyOnConsumerIsAnError`, `undeclaredKeyOnProviderIsAnError`, `declaredSingleKeyDoesNotError`, `multibindingKeyReferenceDoesNotError`, `endToEndUndeclaredKeyErrors`, `endToEndDeclaredKeyPasses`), `Tests/WireGenCoreTests/CrossLibraryValidationTests.swift` (`crossLibraryKeyReferenceResolves`).

### Requirement: Key checks skip `some` and `any` sites
`_WireKeyChecks.swift` SHALL emit a `_check(<key>, <Type>.self)` call, wrapped in
`#sourceLocation` for the site, for each keyed provider and each keyed init-time dependency whose
key is not a multibinding key (`CollectedKey`, `MappedKey`, `BuilderKey`) or a generated
injection-rewrite key and whose written type does not begin with `some ` or `any `, so a key whose
`BindingKey<T>` disagrees with the site's type fails to compile at the user's line. Sites whose type
begins with `some ` or `any ` SHALL get no check. A keyed member injection (`@Inject(<key>) weak
var`) gets no check, noted in https://github.com/swift-wire/swift-wire/issues/425. An optional
site's check names the optional type (`_check(K.primary, Database?.self)`), which fails to compile
even for a matching key; this is tracked as a defect in
https://github.com/swift-wire/swift-wire/issues/421.

#### Scenario: an existential keyed provider
- **WHEN** a provider keyed `Logger.fancy` binds `any Logger`
- **THEN** no `_wireTypeCheck_` function is emitted for it

#### Scenario: the integration fixtures
- **WHEN** WireGen runs over `Tests/IntegrationTests`
- **THEN** `_WireKeyChecks.swift` contains `_check(AppName.alternate, AppName.self)` under `#sourceLocation(file: "Tests/IntegrationTests/KeyedExample.swift", line: 21)`

Pinned by: `Tests/WireGenCoreTests/CodeEmissionTests.swift` (`anyProtocolBindingsAreSkipped`, `someProtocolBindingsAreSkipped`, `differentKeysProduceSeparateFunctions`, `differentTypesProduceSeparateFunctions`), `GoldenHarness/Golden/_WireKeyChecks.swift.golden`. The multibinding-key, rewrite-key, member-injection and optional-site cases are pinned by nothing yet.

### Requirement: An instantiation with two candidate producers is a duplicate
When a dependency's instantiation is bound both by a concrete binding the user declared and by a
matching generic template, or by two or more matching generic templates, WireGen SHALL report a
duplicate binding for that identity. A template with a different key SHALL NOT be a candidate.

#### Scenario: concrete and generic
- **WHEN** `@Provides let repo: Repository<DynamoDBTable> = Repository()` and `@Provides func makeRepository<T>() -> Repository<T>` are both declared and `App` injects `Repository<DynamoDBTable>`
- **THEN** one duplicate binding for `Repository<DynamoDBTable>` lists both producers

Pinned by: `Tests/WireGenCoreTests/GraphTests.swift` (`concreteAndGenericForSameInstantiationIsAmbiguous`, `concreteAndGenericWithDifferentKeysCoexist`, `multipleGenericCandidatesProduceAmbiguityError`), `Tests/WireGenCoreTests/DiagnosticGalleryTests.swift` (`multipleGenericCandidatesEmitDuplicateBindingError`).

### Requirement: A dependency matching no template is missing
A dependency naming a generic instantiation that no concrete binding produces and for which no
template of matching base name, argument count and key exists, or naming the template's base type
without arguments, SHALL be a missing binding.

#### Scenario: the bare base name
- **WHEN** `makeRepository<Model>() -> Repository<Model>` is declared and `App` injects `Repository`
- **THEN** the dependency is a missing binding

Pinned by: `Tests/WireGenCoreTests/GraphTests.swift` (`dependencyOnGenericNameIsMissingNotResolvedToGeneric`, `noMatchingGenericProducesMissingBindingForInstantiation`).

### Requirement: Two bindings with one accessor name are an error
When two bindings of distinct identities derive the same generated accessor name, WireGen SHALL
report "generated accessor name '<name>' collides across multiple bindings" at the first and
"also generates '<name>'" notes at the others.

#### Scenario: an optional and a non-optional logger
- **WHEN** `@Provides let plainLogger: Logger = Logger()` and `@Provides let optionalLogger: Logger? = nil` are declared
- **THEN** the output contains "error: generated accessor name 'logger' collides across multiple bindings" and "note: also generates 'logger'"

Pinned by: `Tests/WireGenCoreTests/GraphTests.swift` (`bindingsWithCollidingAccessorNamesAreReported`, `renderIdentifierCollisionNamesTheGeneratedAccessor`), `Tests/WireGenCoreTests/DiagnosticGalleryTests.swift` (`identifierCollisionNamesTheConflictingAccessor`).

## Related specifications

- [binding-lifetimes](../binding-lifetimes/spec.md)
- [opaque-type-identity](../opaque-type-identity/spec.md)
- [optional-promotion](../optional-promotion/spec.md)
- [injection-points](../injection-points/spec.md)
- [dependency-cycles](../dependency-cycles/spec.md)
- [multibindings](../multibindings/spec.md)
- [scope-entry-and-generated-names](../scope-entry-and-generated-names/spec.md)
- [build-plugin-and-wiregen-cli](../build-plugin-and-wiregen-cli/spec.md)
- [providers](../providers/spec.md)
- [multi-module-composition](../multi-module-composition/spec.md)
