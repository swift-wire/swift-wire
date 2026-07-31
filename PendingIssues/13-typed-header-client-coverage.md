# 13 — A typed client method with a declared `@Header` has no fixture

**Repo(s):** wire-mvc
**State:** ⚪ Coverage gap — the behaviour is exercised by a codegen unit test, not by a running route
**Blocks:** nothing.
**Surfaced by:** adding `headers:` to typed client methods (wire-mvc #63).

## What it is

Two things about a typed method's headers are only pinned at the *codegen* level, by string comparison in
`ControllerClientGenerationTests`:

1. a declared `@Header` binding becomes a method parameter and is sent on the wire, and
2. the caller's extra `headers:` merge **under** it, so a declared binding wins on a name collision.

Neither is exercised by a route that actually serves. No fixture controller in wire-mvc pairs a `@Header`
binding with a generated client: `UsersController` has one (`@Header("x-trace") trace: String?`) but lives in
`WireMVCExample`, a **program** consumer, which gets no client — the client is emitted for test consumers only.

So the codegen could emit a well-formed call that sends the wrong thing — the wrong header name, the merge
inverted so an extra silently overrides a declared binding — and every test would still pass.

## Use case at risk

A route binding `@Header`, driven through its typed method, with a caller also passing unrelated extra
headers. That is not exotic: the extras exist for headers a *middleware or scoped binding* consumes (auth
token, tenant id, trace id), which is precisely the situation where a route also binds one of its own.

## Repro / fix sketch

Give a fixture controller in `WireMVCBootstrapExample` a route with both a required and an optional `@Header`
binding, echoing them in its response. Then assert, over a running route:

- the declared bindings arrive (required and optional-present, and the optional contributes nothing when nil);
- an extra header the route does not declare arrives alongside them;
- an extra whose name collides with a declared binding loses to the binding.

The optional case is worth including specifically: it renders as a separate `.merging(…)` in the chain
(`headerArgument` in `ControllerClientGeneration.swift`), so it is a distinct code path from the required one.
