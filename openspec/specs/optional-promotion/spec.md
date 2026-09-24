# Optional promotion

## Purpose

How WireGen matches a dependency to a producer across optionality. A binding identity records
whether its type ends in one optional marker (`?` or `!`); the matcher lets a `T` producer satisfy a
`T?` or `T!` dependency, never the reverse, and never satisfies an optional dependency with an
absent producer. The missing-binding diagnostics explain both refusals, and a `T` and a `T?`
producer under one key are rejected as a generated-name collision.

Rationale: [OptionalMatchingAndCycles](../../../Documentation/Notes/OptionalMatchingAndCycles.md).
Documentation: [InjectionPoints](../../../Sources/Wire/Wire.docc/InjectionPoints.md).

## Requirements

### Requirement: An identity strips at most one trailing optional marker
`optionalityStripped` SHALL remove one trailing `?` or `!` from a canonical type and report it as
`isOptional == true`, and SHALL leave every other type unchanged with `isOptional == false`. A
binding's and a dependency's `BindingIdentity` SHALL be built from that split, so `T?` and `T!`
share one identity whose `displayType` is `T?`. The test is on the last character only, so a
function type whose result is optional (`() -> Foo?`) is read as optional and a parenthesised
optional keeps its parentheses in the base, which is tracked as a defect in
https://github.com/swift-wire/swift-wire/issues/426.

#### Scenario: the three spellings
- **WHEN** `optionalityStripped` is applied to `Foo`, `Foo?` and `Foo!`
- **THEN** each yields base `Foo`, with `isOptional` false, true and true

#### Scenario: an optional generic argument
- **WHEN** `optionalityStripped` is applied to `Box<Bar?>`
- **THEN** it yields base `Box<Bar?>` with `isOptional == false`

#### Scenario: a doubly optional type
- **WHEN** `optionalityStripped` is applied to `Foo??`
- **THEN** it yields base `Foo?` with `isOptional == true`

#### Scenario: a function type with an optional result
- **WHEN** `optionalityStripped` is applied to `()->Foo?`
- **THEN** it yields base `()->Foo` with `isOptional == true`

Pinned by: `Tests/WireGenCoreTests/GraphTests.swift` (`optionalityStrippedSplitsTopLevelOptional`). The doubly optional and function type scenarios are pinned by nothing yet. The shared `T?` and `T!` identity and its `T?` `displayType` are pinned by nothing yet.

### Requirement: A `T` producer satisfies a `T?` or `T!` dependency
When no producer has the dependency's exact optional identity, `matchProducer` SHALL resolve a
`T?` or `T!` dependency to a `T` producer under the same key. This SHALL apply to init-time
dependencies and to member-injection parameters alike.

#### Scenario: a `weak var` of `T?`
- **WHEN** `View` holds a weak member injection of `Coordinator?` and `Coordinator` is a singleton
- **THEN** the graph validates

#### Scenario: a `weak var` of `T!`
- **WHEN** `View` holds a weak member injection of `Coordinator!` and `Coordinator` is a singleton
- **THEN** the graph validates

#### Scenario: end to end
- **WHEN** `Dashboard` declares `@Inject package weak let telemetry: Telemetry?` against a `@Singleton` `Telemetry`
- **THEN** `graph.dashboard.telemetry === graph.telemetry`

Pinned by: `Tests/WireGenCoreTests/GraphTests.swift` (`weakOptionalDepPromotesToNonOptionalProducer`, `weakIUODepPromotesToNonOptionalProducer`), `Tests/IntegrationTests/BootstrapTests.swift` (`weakLetInjectionDeliversNonOwningReferenceAtInit`, `iuoWeakVarBreaksSingletonCycle`).

### Requirement: A promoted dependency's edge points at the producer it resolved to
When an init-time `T?` dependency resolves to a `T` producer, the graph edge SHALL point at the
`T` producer's identity, so the producer is ordered before its consumer.

#### Scenario: a cycle closed through a promoted dependency
- **WHEN** `A` depends at init on `b: B?`, `B` depends at init on `a: A`, and both are singletons
- **THEN** the graph reports one cycle

Pinned by: `Tests/WireGenCoreTests/GraphTests.swift` (`weakLetInitDependencyParticipatesInCycleDetection`).

### Requirement: An exact optional producer is matched before promotion
`matchProducer` SHALL try the dependency's own identity first, so a `T?` dependency resolves to a
`T?` producer when one exists under the same key. In a graph build a `T` and a `T?` producer under
one key are rejected as an identifier collision before matching, so this precedence over promotion
is observable only in a direct `matchProducer` call.

#### Scenario: an explicit optional provider
- **WHEN** `App` depends on `logger: Logger?` and `Config.logger` is provided as `Logger?`
- **THEN** the graph validates with order `Logger?`, `App`

Pinned by: `Tests/WireGenCoreTests/GraphTests.swift` (`optionalDepMatchesExplicitOptionalProducerExactly`). The precedence of the exact `T?` producer over a `T` producer is pinned by nothing yet.

### Requirement: A `T?` producer never satisfies a `T` dependency
`matchProducer` SHALL NOT resolve a non-optional dependency to an optional producer. When only the
optional form is bound, the missing binding SHALL carry
`OptionalMismatchHint.optionalProducerCannotSatisfyNonOptional`, rendered after the
`no binding produces '<T>'` error as `note: a '<T>?' producer exists but can't satisfy non-optional
'<T>' (a '<T>?' may be nil) — change the consumer to '<T>?', or have the producer return '<T>'`.

#### Scenario: an optional provider and a non-optional consumer
- **WHEN** `@Provides let logger: Logger? = nil` is declared and `@Singleton struct App` declares `@Inject var logger: Logger`
- **THEN** the output contains `error: no binding produces 'Logger'` and `note: a 'Logger?' producer exists but can't satisfy non-optional 'Logger'`

Pinned by: `Tests/WireGenCoreTests/GraphTests.swift` (`nonOptionalDepIsNotSatisfiedByOptionalProducer`), `Tests/WireGenCoreTests/DiagnosticGalleryTests.swift` (`missingBindingForNonOptionalWithOptionalProducerRendersAsymmetryNote`).

### Requirement: An optional dependency with no producer is a missing binding
When neither `T?` nor `T` is bound under the dependency's key, a `T?` dependency SHALL be reported
as a missing binding carrying `OptionalMismatchHint.optionalNeedsExplicitProducer`, rendered as
`note: Wire never injects nil for an absent binding; an optional dependency still needs an explicit
producer (return '<T>', or '<T>?' if it may be nil)`. WireGen SHALL NOT inject `nil` in its place.

#### Scenario: nothing produces the type
- **WHEN** `@Singleton struct App` declares `@Inject var logger: Logger?` and nothing binds `Logger` or `Logger?`
- **THEN** the output contains `error: no binding produces 'Logger?'` and `note: Wire never injects nil for an absent binding`

Pinned by: `Tests/WireGenCoreTests/GraphTests.swift` (`optionalDepWithNoProducerStillNeedsExplicitProducer`), `Tests/WireGenCoreTests/DiagnosticGalleryTests.swift` (`missingOptionalBindingRendersNeedsExplicitProducerNote`).

### Requirement: `T` and `T?` under one key collide on the generated accessor name
Because a binding's generated accessor name drops the `?`, a `T` producer and a `T?` producer under
the same key SHALL be rejected by the identifier-collision check before dependency resolution,
whether or not anything consumes them, rendered as `error: generated accessor name '<name>'
collides across multiple bindings` with `note: also generates '<name>'` at the other binding.

#### Scenario: both forms provided
- **WHEN** `@Provides let plainLogger: Logger = Logger()` and `@Provides let optionalLogger: Logger? = nil` are declared
- **THEN** the output contains `error: generated accessor name 'logger' collides across multiple bindings` and `note: also generates 'logger'`

Pinned by: `Tests/WireGenCoreTests/GraphTests.swift` (`optionalAndNonOptionalProducersCollideOnGeneratedName`), `Tests/WireGenCoreTests/DiagnosticGalleryTests.swift` (`identifierCollisionNamesTheConflictingAccessor`).

### Requirement: Optional and existential promotion compose
`matchProducer` SHALL try, in order, the dependency's own identity, its non-optional form, and,
for an `any P` dependency, the `some P` form and the non-optional `some P` form, so an `any P?`
dependency resolves to a `some P` producer.

#### Scenario: an optional existential consumer
- **WHEN** `matchProducer` resolves `any Logger?` against a producer set holding only `some Logger`
- **THEN** it returns `.resolved` with the `some Logger` identity

Pinned by: `Tests/WireGenCoreTests/BindingIdentityTests.swift` (`optionalAndExistentialPromotionsCompose`).

## Related specifications

- [binding-identity-and-keys](../binding-identity-and-keys/spec.md)
- [injection-points](../injection-points/spec.md)
- [dependency-cycles](../dependency-cycles/spec.md)
