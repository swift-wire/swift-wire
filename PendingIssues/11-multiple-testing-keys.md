# 11 — One `TestingKey` per target; several would need the doubles model reworked

**Repo(s):** wire-mvc (+swift-wire)
**State:** 🟡 Deferred by decision — rejected with a diagnostic, not silently ignored
**Blocks:** two `@Suite(.wiremvc(key))` suites in one test target serving *different* variant graphs.
**Surfaced by:** the testing-architecture work (`wire-mvc/Documentation/TestingArchitecture.md`, Phase 4).

## What it is

swift-wire already emits **one variant app graph per `TestingKey`** — `TestingVariants.buildVariants` loops
over `aggregate.testingKeys`. The limit is on wire-mvc's side: it emits a single
`.wiremvc(_ key:, _ mode:)` factory bound to one variant, so a second key has nothing to be served by.

That used to be silent (`discoverTestingKey` returned the first match). It is now an **error** on the second
key's declaration, naming the one that won — a suite passing the second key would otherwise be handed the
first key's mocks, which fails as a mysteriously wrong double rather than as a build error.

## Why it wasn't just implemented

The dispatch half is easy and was prototyped: `TestingKey` now carries its declaration site (`#fileID`/`#line`
captured by `init` defaults, `Hashable` — see `Sources/Wire/TestingKey.swift` and
`Tests/WireTests/TestingKeyTests.swift`), so a generated `switch` can match a key value by reconstructing
`TestingKey(fileID:line:)` for each variant. **That mechanism is in place and tested.**

What stops it is the **doubles model**, which is per-key today:

- WireGen emits one `_<Key>Doubles` struct per key, fields non-optional and **concretely typed**
  (`let noteBackend: MockNoteBackend`), with bindings resolving a slot to `doubles.<field>`. The concrete
  type is load-bearing for the opaque-injection lift, where the controller is generic *over* the mock type.
- wire-mvc emits a matching module-scope `withBindValues(<every slot of that key>:)` per key.

With N keys that is N free functions. They are overloads, so they mostly resolve — but the natural fix for a
second, worse problem makes them ambiguous. That second problem: **every request under a keyed suite must
supply every one of the key's doubles, even for a route that consumes none.** (`/ping` in
`WireMVCBootstrapExample` has no mocked dependency yet still needs `withBindValues(noteBackend:prefs…:)`;
`mockIgnoringRouteWithoutDoublesIs500` asserts that as the decided behaviour.) Making the fields optional
fixes it — and then `withBindValues { … }` with no arguments matches every overload.

So multi-key and the doubles model are one problem, not two.

## Options considered

1. **Union doubles struct, all-optional, one `withBindValues`.** Per-request validation moves into the
   variant scope entry, which fails a route whose doubles are missing. Terse, and the 500 becomes precise
   ("this route needs `noteBackend`"). Costs the compile-time guarantee that you supplied everything, and
   needs key-qualified field names wherever two keys bind the same slot to *different* mock types (the field
   type is concrete, so they cannot share one).
2. **Per-controller bind values** — `with<Controller>BindValues(…)` taking exactly the doubles that
   controller's scope consumes, all required, yielding a controller-scoped client. Keeps compile-time
   completeness *at the granularity testing actually happens*, and drops the over-specification. Needs
   swift-wire to keep its per-subject doubles sets rather than merging them into one variant-wide struct, and
   to emit a per-subject struct from them — the set is transitive (`CartController → CartService →
   AccountRegistry`, whose `init` reads the mock), so it is graph-derived and belongs on this side. wire-mvc
   then needs only the struct's *name*, by the same blind-agreement convention it already uses for doubles
   field names. **This is the preferred direction**, written up with its typed-client half in wire-mvc's
   `Documentation/Notes/ControllerScopedTesting.md`.

Option 2 also weakens the case for multi-key: a common reason to want a second key is a different mock set
per suite, and per-controller bind values already give that without a second variant graph.

## Use case blocked

Two suites in one test target needing genuinely different *graph substitutions* — e.g. the same slot bound to
two different concrete mock types where the consumer is generic over it. Different mock *instances*, or
different mock types behind an existential slot, are already covered by one key: the double is supplied
per-request through `withBindValues`.

Workaround: put the second key in its own test target. Test targets are cheap here — each re-composes the
app's graph through its own `WireMVCBuildPlugin` — and the in-package fixtures already split this way
(`WireMVCBootstrapExampleTests` / `…ReplaceTests` / `…BindTests`).

## State / evidence

- Rejected loudly: `WireMVCDiagnostic.multipleTestingKeys`, raised by
  `discoverTestingKeys(in:)` in `wire-mvc/Sources/WireMVCCodegen/TestingKeyDiscovery.swift`.
- Covered by `aSecondTestingKeyIsRejected` / `noTestingKeyIsNotAnError` in `WireMVCCodegenTests`.
- The identity mechanism the eventual dispatch needs is merged and tested in swift-wire; nothing else of the
  multi-key work was kept.
