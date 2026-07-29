# `@Scopable` for app-scoped route contributors — seedless per-request reconstruction (plan)

> ✅ **COMPLETE** — shipped as part of milestone **M6a (testing)** as `@TestScopable`: seedless per-request
> reconstruction for app-scoped route contributors, including the generic subject and the generic
> mock-consuming middleware factory (`create(doubles:)`), proven end-to-end by the wire-mvc-examples un-gate
> (#32). Retained as implementation history; the "for review before building" framing and any "NEXT" notes
> below are historical. See [../ROADMAP.md](../../ROADMAP.md) and [../PendingIssues](../../PendingIssues/README.md).

> **Status:** design record for extending `@Scopable`'s reach from *singletons on a path to a seed-scoped
> subject* to *app-scoped route contributors that are their own request entry point*. Builds on the variant
> app graph (VariantAppGraphPlan.md) and the M6a keyed harness. For review before building.

## The gap (why the cascade can't reach it)

`@Scopable(X)`'s purpose is: **rebuild app-`@Singleton` X per-request under test so it sees the per-request
mock.** The cascade (`cascadeLift`, `TestingGraph.swift`) does this only for singletons *on a path to a
seed-scoped subject's root*:

```swift
let liftedIdentities = seedReachableApp.intersection(mockReaching)
```

`mockReaching` (reverse-reachable from the mock) already finds every consumer — including an app-scoped
`@Singleton @Controller` like `TodosController`. But the intersection with `seedReachableApp` drops anything
not reachable from a seed scope, and a route contributor is *its own* entry point, depended on by no
seed-scoped subject — so it has no parent scope to be lifted *into*, and falls out. Structurally, in
`ContributorProxySynthesis`, a `_wireEnterScope` reconstruction thunk is synthesized only when
`subject.scopeKey != nil` (i.e. `@Scoped(seed:)`); an app-scoped subject gets a plain proxy holding a *built*
subject. So today an app-scoped mock-consumer produces **orphan codegen** (the variant graph drops the mock
but keeps the controller referencing it) instead of the guided `@Scopable` error.

## The identification algorithm (roots, not seed partitions)

Don't drive off seed partitions. Drive off the **route-contributor roots** — the bindings that are per-request
entry points (`contributesProxy` capability, proxy scope `singleton`; equivalently, a contributor proxy):

1. Reverse-walk the graph from each `@BindType` mock up through its consumers to the **contributor-proxy
   roots** that transitively consume it. App singletons *between* the mock and a root are intermediate hops.
2. Root subject is a **seeded root** (`@Scoped(seed:)`, `subject.scopeKey != nil`) → existing bridge path,
   reconstruct with the known seed.
3. Root subject is a **singleton** (`scopeKey == nil`) → **new seedless path**, reconstruct with no seed.

Intermediate hops are lifted into whichever root's reconstruction reaches them (`@Scopable`'d, else the
guided error — unchanged). `@Scopable` now marks both an intermediate hop (existing) *and* a singleton root
(new) as opted into per-request rebuild. This makes the **trigger** a mock-consuming contributor root — seeded
or singleton — so a pure app-scoped mock-consumer (no seed-scoped controller anywhere) triggers a variant by
construction, and the old `seedReachableApp.intersection(mockReaching)` gate (which discarded non-seed roots)
is replaced by "the roots are the contributor proxies."

## The design — seedless reconstruction

An app-scoped `@Controller` **cannot** consume the request (it's `@Singleton`; the request isn't available at
its `init`), so its per-request reconstruction needs *only the doubles*. Under a `@BindType` variant, an
`@Scopable`'d app-scoped route contributor gets a variant proxy whose thunk is **seedless**:

```
_wireEnterScope(doubles) -> (subject, teardown)
```

vs. the seed-scoped `_wireEnterScope(seed, doubles)`. The thunk rebuilds the subject + its mock-consuming
route-contributor deps (e.g. a middleware `@Factory` that also injects the mocked slot) with `doubles.<field>`,
borrowing every non-mock binding from the variant graph. "Created on demand when the test needs it" — the
binding is a `@Singleton` in production (built once, real backend); only under the keyed suite is it rebuilt
per request with the mock.

### Scope of `@Scopable(X)` — two cases, one annotation

- **Lift-into-scope** (existing): X is a singleton *between* the mock and a `@Scoped(seed:)` subject → lifted
  into that subject's request scope, rebuilt at scope entry.
- **Seedless reconstruct** (new): X is an app-scoped *route contributor* (its own request entry) → rebuilt
  per-request via a seedless variant proxy.

The framework picks the case from whether X carries a contributor proxy (a route entry) vs. is a plain
on-path singleton. A plain app singleton consumed only by a seedless-reconstructed contributor is rebuilt
inside that reconstruction (part of its group); one consumed by nothing served is dropped.

## What changes

### swift-wire
- **Cascade** (`cascadeLift`): surface app-scoped route-contributor subjects in `mockReaching` as
  *seedless-reconstruction* candidates, independent of `seedReachableApp`. `@Scopable`'d → reconstruct;
  unmarked → the existing guided `unmarkedCascadeHopDiagnostic` (`Add @Scopable(X.self)`), not orphan codegen.
- **Seedless reconstruction proxy**: a parallel to the bridge path. The proxy struct carries
  `_wireEnterScope: @Sendable (Doubles) async throws -> (Subject, teardown)`; the facade builds it against the
  variant graph; the thunk (a seedless variant of `scopeEntryThunkLines`) rebuilds the subject + its
  mock-consuming deps from `doubles`, borrowing the rest. `parsedContributorScopeEntryThunkType` /
  `contributorScopeEntryThunkType` gain a seedless form (no seed term).
- **Variant graph drop rule**: already drops mocked ∪ lifted ∪ bridge proxies; extend the lifted set to
  include the seedless-reconstructed app-scoped subjects + their production proxies + their mock-only deps.
  The merged aggregate filter then sheds their route proxies from `routeContributors`.

### The mark — `@TestScopable`, on the type
Scopability moved from a key-side `@Scopable(X.self)` argument to a `@TestScopable` marker on the **type
declaration** (module-global; read by the cascade + seedless reconstruction). Reasons: a key-side metatype
can't spell an unbound generic (`GenericController.self` fails to compile, `X<some P>.self` is illegal), and
scopability is a property of the definition (safe to rebuild, or holds global state?) not of any one key. It
has effect only under a `TestingKey`'s `@BindType` (test-only), so a production build never activates it.

### wire-mvc
- Key app-scoped `@TestScopable` subjects alongside seed-scoped ones (they now carry a variant proxy). The
  variant witness for a seedless subject calls `self._wireEnterScope(doubles)` (no `request`); wire-mvc knows a
  subject is seedless from its scoping (app-`@Singleton` vs `@Scoped(seed:)`).

### wire-mvc-examples
- `TodosController`/`ExportController`/`MeController` get `@TestScopable`. All three routes (`/me`, `/todos`,
  `/export`) become mock-testable; the mocked suite grows `verify`-based tests for `/todos`/`/export`.

## The mock-consuming middleware factory — `create(doubles)`

A lifted middleware `@Factory` that `@Inject`s the mocked slot (the example's `audit`: `@Inject var repository`)
can't hold the mock as a **field** — the factory is built once when the facade runs (server startup), but the
mock arrives **per-request** (header → `TestBindStore`, after the server is up), and interleaved requests carry
different mocks. So the mock must ride the **`create` call**, exactly as the subject's mock rides
`_wireEnterScope(doubles)`. One rule: everything that touches the mock enters through a per-request call taking
the doubles.

- **swift-wire (Phase B) — DONE.** `renderVariantFactoryDeclaration` emits a **variant factory**
  (`_<Variant><FactoryType>`): its mocked `@Inject`s become `create(doubles:)`-sourced parameters, its non-mock
  `@Inject`s stay held fields, and the box-role `create` generics/return/`where` are unchanged (mocking is a
  value axis, not a role axis — a leading `doubles:` parameter is prepended). `variantFactoryTransforms` finds
  the seedless root proxy's mock-consuming lifted `@Factory`s (a dep matching a `@BindType` slot), retypes the
  proxy field to the variant factory, drops the production factory from the variant graph (else it orphans on
  the dropped mock), and the seedless facade **constructs** the variant factory from the non-mock graph deps
  rather than borrowing it. The factory and subject share the one doubles field for a shared mock.
- **wire-mvc (Phase B):** fold the middleware chain **inside the per-request handler** for a variant witness,
  threading the per-request doubles to each variant factory's `create(doubles: …)`. Non-mock factories in the
  same chain still `create()` without doubles (a mixed fold). This is a per-request *fold*, not a per-request
  factory rebuild — cheap.

## Phases (each ends green)
1. **swift-wire seedless proxy + cascade — DONE (merged).** App-`@Singleton @RouteController` consuming a
   `@BindType`'d slot, `@TestScopable`'d → seedless variant proxy; `_wireEnterScope(doubles)` threads the mock;
   borrow + generic (opaque-axis, concretized) cases locked; unmarked → guided error. `@TestScopable` shipped.
2. **A — wire-mvc keyed seedless witness.** Key app-scoped `@TestScopable` subjects; witness calls
   `_wireEnterScope(doubles)` (seedless, no `request`). Gate: a wire-mvc keyed suite over a simple app-scoped
   `@TestScopable` controller (no mock-consuming middleware) serves it with the mock over HTTP.
3. **B — the mock-consuming factory.** swift-wire variant factory (`create(doubles)`) **DONE** — the
   `ScopableRouteContributorExample` fixture's `AppScopedController` carries a mock-consuming `@RouteMiddleware`
   `@Factory`; the test invokes `proxy._wireFactory_<key>.create(doubles:)` and the *same* mock instance records
   both the subject's and the factory's call. **NEXT:** wire-mvc per-request fold. Gate: a wire-mvc fixture with
   a mock-consuming middleware factory serves + `verify`s over HTTP.
4. **C — example un-gate.** `@TestScopable` on the controllers; turn the mocked target on; `/todos`/`/export`/
   `/me` mock tests with `verify`; Docker-free (no real backend `init`).

## Risks / open items
- **Fold timing (Phase B).** Whether wire-mvc's middleware chain is already rebuildable per-request or the fold
  must be lifted into the handler — resolved against the real example, not guessed.
- **Non-contributor app singletons** consuming the mock but not on a seed path and not a route contributor:
  dropped if unused under the variant, else part of a contributor's reconstruction group. Confirm none strand.
