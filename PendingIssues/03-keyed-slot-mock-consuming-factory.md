# 03 — Keyed-slot mock-consuming factory is untested

**Repo(s):** swift-wire (detection/emission) + wire-mvc (discovery/fold)
**State:** 🟡 Unverified (code paths exist on both sides; no test drives them)
**Blocks:** mock-testing a controller whose lifted `@Middleware` `@Factory` injects a **keyed** binding that a
keyed `@BindType(Key.slot, Mock.self)` mocks.
**Surfaced by:** the Phase B audit. Phase C does not force this (the examples mock by-type slots).

## What it is

A factory can inject a keyed binding: `@Inject(PrefsKeys.primary) var prefs: any PrefsBackend`, mocked via
`@BindType(PrefsKeys.primary, MockPrefsBackend.self)`. Both repos have code for the keyed form:

- swift-wire: `mockedDoublesField` has a `slotKey` branch (`substitution.slotKey == dependency.keyIdentifier`).
- wire-mvc: `factoryTemplateInjectFields` reads the `@Inject(key)` argument and derives the keyed doubles-field
  name via `wireGenIdentifierName(forType:key:)`.

But no test exercises a **factory** (as opposed to a controller) injecting a keyed slot, so the two repos'
field-name derivations are not confirmed to agree for this shape.

## Use case blocked

A lifted middleware factory that depends on a keyed binding, mock-tested under a keyed `@BindType`.

## State / evidence

- swift-wire: `Sources/WireGen/TestingVariantSeedlessRoots.swift` — `mockedDoublesField`, `slotKey` branch.
- wire-mvc: `Sources/WireMVCCodegen/RouteContributorGeneration.swift` — `FactoryInjectFinder.injectKeyArgument`
  + `wireGenIdentifierName(forType:key:)`.
- Existing keyed coverage is a controller inject (`PrefsController` `@Inject(PrefsKeys.primary)`), not a factory.

## Repro

Add a `@Factory` that `@Inject(SomeKey)`s a keyed slot, reference it via `@Middleware(factoryKey)` on a keyed
subject, and mock the keyed slot with `@BindType(SomeKey, Mock.self)`.

## Fix sketch

Likely already works; needs a test to confirm the keyed doubles-field name derived by wire-mvc matches the one
swift-wire emits. If they disagree, reconcile `wireGenIdentifierName(forType:key:)` (wire-mvc) with
`identifierName(forType:key:)` (swift-wire) for the factory case.
