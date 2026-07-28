# 04 — Seed-scoped controller + mock-consuming factory fold is untested

**Repo(s):** wire-mvc (fold/hoist) — swift-wire emits the same variant factory regardless of subject scope
**State:** 🟡 Unverified
**Blocks:** mock-testing a `@Scoped(seed:)` controller whose lifted `@Middleware` `@Factory` injects the mocked
slot.
**Surfaced by:** the Phase B audit. **Phase C may force this** — depends on whether the examples' generic
seed-scoped `MeController` (`/me`) carries a mock-consuming middleware (unconfirmed).

## What it is

Phase B's doubles-threaded fold + hoisted preamble were validated only on the **seedless** (app-`@Singleton`
`@TestScopable`) variant witness — `SummaryController` in the wire-mvc example. The one seed-scoped
factory-carrying case tested (`LoggedController` + `AccessLog`) uses a **non-mock** factory, so its fold is
box-role-only and no hoist happens.

A `@Scoped(seed:)` controller carrying a **mock-consuming** factory is unexercised. The seed-scoped variant
witness enters request scope with `self._wireEnterScope(request, wireMVCDoubles)` *inside* the terminal, while
the hoisted preamble binds `wireMVCDoubles` at the register-closure top before the fold. These should compose
(the terminal's seed entry reads the hoisted binding), but the specific interaction — hoisted doubles + seed
entry + doubles-threaded fold — has no test.

## Use case blocked

A per-request (`@Scoped(seed:)`) controller whose lifted middleware injects the mocked backend, mock-tested
over HTTP.

## State / evidence

- `Sources/WireMVCCodegen/RouteCodegen.swift` — `routeBlock` computes `foldThreadsDoubles` and hoists; only
  `scopedSeedType == nil` (seedless) is covered by a test.
- Tested seed-scoped factory case: `LoggedController` + `AccessLog` (non-mock) — no doubles threading.

## Repro

Give a `@Scoped(seed: HTTPRequest.self)` controller a `@Middleware(key)` whose `@Factory` `@Inject`s the mocked
slot; run the keyed suite; `GET` the route and assert the mock records the middleware's call.

## Fix sketch

Expected to work via the existing hoist. Add a fixture (seed-scoped controller + mock-consuming middleware) to
`WireMVCBootstrapExampleBindTests` and confirm the generated fold + hoist compile and serve. If the seed entry
and the hoisted doubles collide (shadowing / ordering), adjust the hoist to bind above both.
