# 06 — Subject-unreached mock / multiple factories per proxy

**Repo(s):** swift-wire
**State:** 🟡 Unverified (two related edge cases in the seedless reconstruction)
**Blocks:** (a) a lifted factory that mocks something the controller itself doesn't use; (b) more than one
mock-consuming factory on one proxy.
**Surfaced by:** the Phase B audit. Phase C does not force this.

## What it is

Two untested corners of `buildSeedlessReconstruction` / `variantFactoryTransforms`:

**(a) Factory-only mock.** The subject reconstruction drops `reconstructionSet = subjectCone ∩ mockReaching`
from the variant graph. A mock consumed **only** by a lifted factory — not reached by the subject — is not in
`subjectCone`, so it is not in `reconstructionSet` and not dropped. The factory's doubles field *is* added to
the reconstruction (`doublesFields: substituted.doublesFields + factoryTransforms.flatMap { $0.doublesFields }`),
so the `_<Key>Doubles` struct will carry it — but whether the mock *binding* is correctly dropped/doubles-sourced
in the variant graph (given it's outside the subject's cone) is unverified.

**(b) Multiple mock-consuming factories on one proxy.** `variantFactoryTransforms` returns a list and the
caller merges all their declarations, doubles fields, and drop identities — but no fixture has more than one
mock-consuming factory on a single contributor proxy.

## Use case blocked

(a) A controller whose lifted middleware mocks a backend the controller's own routes never touch. (b) A
controller carrying two mock-consuming middlewares.

## State / evidence

- `Sources/WireGen/TestingVariantSeedlessRoots.swift` — `buildSeedlessReconstruction` (drop set derivation),
  `variantFactoryTransforms` (list handling).
- Current fixture: one mock-consuming factory whose mock is *also* reached by the subject (shared field).

## Repro

(a) A factory injecting a mocked slot the subject doesn't inject. (b) Two `@Middleware(key)`s on one
`@TestScopable` controller, both mock-consuming.

## Fix sketch

(a) Include factory-consumed mock identities in the variant-graph drop set (union the factories' mock bindings
into `droppedIdentities`), not just the subject cone. (b) Likely already correct via the list; add a fixture to
confirm no field-name / drop-identity collisions.
