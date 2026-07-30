# 04 — Seed-scoped controller + mock-consuming factory didn't compile

**Repo(s):** swift-wire (variant app graph emission)
**State:** ✅ **Fixed (pending merge)** — was 🔴 Known broken
**Blocks:** mock-testing a `@Scoped(seed:)` controller whose lifted `@Middleware` `@Factory` injects the mocked
slot.
**Surfaced by:** the Phase B audit; reproduced and fixed 2026-07-31 while scoping per-controller doubles
(wire-mvc `Documentation/Notes/ControllerScopedTesting.md`). Not forced by Phase C — no shipped example carried
this shape until the fixture below was added.

## What it was

A `@Scoped(seed:)` controller carrying a **mock-consuming** `@Middleware` `@Factory` emitted a variant
`_WireGraph.swift` that did not compile:

```
_WireGraph.swift:516:94: error: cannot find 'anyNoteBackend' in scope
516 | let _WireFactory_ScopedAuditKeys_factory = _WireFactory_ScopedAuditKeys_factory(backend: anyNoteBackend)
```

The *production* factory survived into the variant app graph and was constructed against the `@BindType`'d
binding the variant had dropped. The seedless path in the same generated file did the right thing — emitting a
variant factory constructed with no `backend`, sourcing the mock per request — so the two paths diverged.

The controller's **own** mocked dependency was always handled correctly (the scope-entry thunk emitted
`AuditedController(backend: anyNoteBackend)` off the doubles). Only the factory's was not.

> **The original entry was wrong on four counts** and is corrected here for the record: it attributed the gap to
> wire-mvc's fold/hoist, asserted swift-wire emits the same variant factory regardless of subject scope, marked
> it 🟡 unverified, and expected it to work via the existing hoist. The break was upstream in swift-wire, and
> wire-mvc's hoist never ran because there was no `create(doubles:)` in the fold to trigger it.

## Root cause

`variantFactoryTransforms` had exactly one caller, inside the seedless reconstruction path. Root selection
required the subject to be an app `@Singleton` *and* `@TestScopable`, so a `@Scoped(seed:)` controller never
qualified and never got the transform. With no transform, the factory's identity never joined the `dropped`
set, and its production construction survived into `appGraphOrder`.

## The fix

- `WireGen/TestingVariantContributorProxies.swift` — `seedScopedFactoryTransforms` runs the same transform for
  seed-scoped contributor proxies, and `variantContributorProxy` re-types a mock-consuming factory field to its
  variant type instead of carrying it through unchanged.
- `WireGenCore/ContributorProxyFacadeEmission.swift` — `renderContributorProxyFacade` gains
  `factoryConstructions`, so a dropped factory's local is built in the facade rather than read off `_wireGraph`.
  This is the one line that already differed in the seedless facade.
- `WireGen/TestingVariants.swift` — folds the results in: dropped production-factory identities join `dropped`,
  the variant factory declarations join the emission, and their doubles fields join the struct.

The transforms are computed **before** the variant app graph, because each drops a binding and the graph is
built from what survives — while the facades that consume them need the graph reference that dropping produces.
Computation is split from emission to break that cycle.

Their doubles fields are added to the variant-wide struct because a factory can consume a slot no controller
injects directly, and the field must exist for `create(doubles:)` to read it. The repro doesn't exercise that
case (`ScopedAudit` and `AuditedController` share `NoteBackend`).

**wire-mvc needed no change.** `foldThreadsDoubles` keys off `create(doubles:)` appearing in the fold, which is
scope-agnostic, so the existing hoist picked the seed-scoped case up untouched — which also settles the original
entry's open question about the hoisted doubles composing with the terminal's `self._wireEnterScope(request,
wireMVCDoubles)`.

## Validation

- swift-wire's own suite: 721 tests green, no regressions.
- wire-mvc fixtures against this change: all three targets green, including the new
  `seedScopedRouteWithMockConsumingMiddlewareServesMock`, which asserts
  `mock.recordedNotes == ["scoped-audit", "audited:x"]` — the one supplied instance recorded the middleware's
  call and then the handler's, so both reached the same double.

Validated with wire-mvc's `Fixtures` package pointed at a local swift-wire (`swift package edit`), since the
change was unpushed; re-confirm against pushed main on merge.

## Fixture added (wire-mvc)

`Fixtures/Sources/WireMVCBootstrapExample/ScopedAudit.swift` — a mock-consuming middleware factory under
`ScopedAuditKeys.factory`, recording `scoped-audit`. `AuditedController` (`/audited`, `@Scoped(seed:)`,
`@Middleware(ScopedAuditKeys.factory)`) in `NotesController.swift`, plus the test above in `BindTests.swift`.
Together with `SummaryController` (seedless + mock-consuming) and `LoggedController` (seed-scoped + non-mock),
the three factory/scope combinations are now covered.
