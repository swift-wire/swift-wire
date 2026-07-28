# 02 — Global-tier mock-consuming middleware fold doesn't thread doubles

**Repo(s):** wire-mvc
**State:** 🔴 Known broken (provably unhandled — separate code path from the Phase B fix)
**Blocks:** a mock-consuming **global** `@Middleware` (on a `@WireMVCBootstrap` root) under a keyed test suite.
**Surfaced by:** the Phase B audit. **Phase C does not force this** (the examples' global tier — `AccessLog` —
is non-mock).

## What it is

Phase B taught the **route/controller** fold (`RouteBlockGenerator.middlewareConstructions`) to emit
`create(doubles: wireMVCDoubles, …)` for a mock-consuming factory and to hoist the doubles correlation above
the fold. The **global** middleware fold on the `@WireMVCBootstrap` root is a different code path
(`middlewareFactoryConstructions` in `Sources/WireMVCCodegen/BootstrapGeneration.swift`) and was not changed —
it still emits box-role-only:

```swift
self.\(factoryPropertyName(forKey: expression)).create(\(boxRole).RequestContext.self, \(boxRole).Reader.self, \(boxRole).ResponseSender.self)
```

So a global `@Middleware(key)` whose factory `@Inject`s a `@BindType`'d slot would, under a keyed variant,
either fail to compile (swift-wire emits a variant factory whose `create` demands `doubles:`) or resolve the
wrong binding.

## Use case blocked

A `@WireMVCBootstrap`-level global middleware that consumes a mocked dependency, exercised under
`@Suite(.wiremvc(key))`.

## State / evidence

- `Sources/WireMVCCodegen/BootstrapGeneration.swift` ~line 284 — `middlewareFactoryConstructions` emits the
  box-role-only `create`.
- Confirmed by inspection during the Phase B audit; no doubles threading on the global path.

## Open design question

The global tier wraps **every** request, including the router's `@NotFound` fallback. Threading per-request
doubles there means correlating the doubles at the global entry (before any route match). It is not obvious a
mock-consuming *global* middleware is a meaningful use case — the alternative is to **diagnose** it (reject a
mock-consuming factory in the global position) rather than support it. Decide support-vs-diagnose before
implementing.

## Fix sketch

If supporting: apply the same one-hop mock-consumption classification (issue 05) + doubles-thread + hoist to
the global fold, correlating `wireMVCDoubles` at the global middleware entry. If diagnosing: emit a
`WireMVCDiagnostic` when a global `@Middleware(key)`'s factory injects a `@BindType`'d slot for any discovered
`TestingKey`.
