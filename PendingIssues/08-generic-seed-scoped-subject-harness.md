# 08 — Generic seed-scoped subject under the keyed harness

**Repo(s):** wire-mvc (keyed-harness codegen) + swift-wire (variant proxy for a generic seed-scoped subject)
**State:** 🟡 Unverified (documented as broken pre-M6a; the keyed harness has since been rewritten)
**Blocks:** mock-testing a generic `@Scoped(seed:)` controller over the mocked slots — the wire-mvc-examples
`MeController<Repository, Manager>` (`/me`).
**Surfaced by:** the wire-mvc-examples mocked suite's old "LIMITATION 2" note. **Phase C forces this.**

## What it is

`MeController<Repository: TodoRepository, Manager: SessionManager>` is `@Scoped(seed: HTTPRequest.self)` and
generic over **both** mocked slots (the opaque-injection lift). The mocked suite's old comment
(`SwiftHttpServerExampleMockedTests/MockedBinds.swift`) records that the keyed-harness codegen emitted invalid
Swift for it:

> the generated variant-proxy `@TaskLocal` names `_…_WireRouteContributor_MeController` without its `<...>`
> arguments, and the `_…Doubles(…)` fields are ordered wrong (`sessionManager` before `todoRepository`). The
> harness's subjects are assumed non-generic.

The M6a keyed-harness rewrite **dropped `@TaskLocal`** (variant proxies are now hand-registered by the keyed
`.wiremvc(_:)` factory, not parked in a task-local), so the specific `@TaskLocal`-naming symptom almost
certainly no longer applies. But a **generic seed-scoped subject** under the *current* keyed harness is
unverified — the doubles-field ordering and the variant-proxy generic-argument spelling both need checking
against today's codegen.

## Use case blocked

`GET /me` in the wire-mvc-examples mocked suite — the only seed-scoped route, generic over both mocked
backends.

## State / evidence

- Old symptom recorded in `SwiftHttpServerExample/Tests/SwiftHttpServerExampleMockedTests/MockedBinds.swift`
  ("LIMITATION 2").
- Codegen has since changed substantially (M6a keyed harness, generic-subject support in swift-wire's variant
  proxies — e.g. `GenAppController<Backend>`). Whether generic *seed-scoped* subjects are fully handled is
  untested in the current wire-mvc example (`MeController` has no analog in `WireMVCBootstrapExample`).

## Repro

Point the wire-mvc-examples mocked suite at pushed `wire-mvc` main + `swift-wire` main, `@BindType` the two
slots, and build — inspect the generated variant proxy and doubles struct for `MeController`. Or add a generic
`@Scoped(seed:)` controller over a `@BindType`'d slot to `WireMVCBootstrapExample` and drive it through the
keyed suite.

## Fix sketch

Re-verify against current codegen first (the old symptom may be gone). If a generic seed-scoped subject still
misgenerates: fix the variant-proxy generic-argument spelling and the doubles-field ordering in the keyed
harness / variant-proxy emission, mirroring the generic app-scoped (`GenAppController<Backend>`) handling that
already works.
