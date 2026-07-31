# 12 — A typed route's declared failures aren't typed

**Repo(s):** wire-mvc
**State:** 🟡 Unverified — a design decision deferred, not a defect
**Blocks:** nothing. A test asserting a declared failure works today; it just compares a raw status code.
**Surfaced by:** the typed per-controller client
(wire-mvc `Documentation/Notes/ControllerScopedTesting.md`, "Non-2xx responses").

## What it is

A typed client method returns the route's decoded response and throws `WireMVCRouteError` for any non-2xx.
That error carries the status, the raw body and the request line — enough to assert on, and it reads well:

```swift
let error = try await #require(throws: WireMVCRouteError.self) { try await hello.tenant() }
#expect(error.status == .badRequest)
```

But it is **one type for every route**, so a route's *declared* failures are untyped. `@ErrorResponse` tiers
say which errors a route maps and to what status — the codegen already reads them to fold the mapping into the
witness — yet none of that reaches the client. A test asserting a declared failure compares a status code, so
retiering a route (`.badRequest` → `.conflict`) breaks the test at runtime, exactly the class of drift the
typed client exists to move to compile time.

## The shape it would take

A generated per-route error type whose cases name the route's `@ErrorResponse` tiers, thrown in place of the
bare `WireMVCRouteError`, with the untyped error kept for everything a route does not declare (a middleware
short-circuit, a harness 500, a transport failure). The note's sketch:

> throw a generated per-route error carrying status + body, with the `@ErrorResponse` tiers naming the
> expected cases — and keep the raw client reachable for everything else.

## Why it is deferred rather than done

The typed client's value is concentrated in the happy path — the derived path, the decoded response — and that
shipped. The failure path already names the route in its message (`"GET /me answered 401 Unauthorized"`), so a
failing assertion is legible without it. Weigh the generated-surface cost against how often a test asserts a
*declared* failure specifically, rather than a middleware or harness status the tiers do not describe.

## State / evidence

- `Sources/WireMVCTesting/TypedRouteClient.swift` — `WireMVCRouteError` is `(status, body, route)`, route-agnostic.
- `Sources/WireMVCCodegen/ControllerClientGeneration.swift` — the client renderer does not read error tiers at
  all; `RouteCodegen`'s `errorMappings` (global + controller + route) is where they are known.
- Assertions that would change shape: `globalErrorTierMapsToBadRequest` (wire-mvc fixtures and
  wire-mvc-examples), `meWithoutSessionShortCircuitsBeforeSessionOp` (examples).
