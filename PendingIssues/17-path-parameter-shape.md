# 17 — The handler's path-parameter shape is a pre-1.0 public decision

**Repo(s):** wire-mvc
**State:** 🟡 Deferred by decision — nothing is broken; the shape is the one that shipped, and changing it
is cheap before 1.0 and expensive after
**Blocks:** nothing. It is also the second half of Phase 5's allocation group #2 — the first half needs no
decision and can land whenever.
**Surfaced by:** Phase 5's allocation bisection (group #2, `Documentation/Notes/RemainingSurfaceWork.md`),
then reading the consumers to answer what would replace the dictionary.

## What it is

The router hands a matched route's `{name}` parameters to the handler as **`[String: Substring]`**, built
per request by `FrozenRouteTrie.resolve` as `Dictionary(zip(route.parameterNames, parameterValues))`. That
dictionary is one allocation on every native request that matches a route.

The type is not local to the router. It is written into two public surfaces:

- `HTTPServerRouteBuilder.register`'s handler shape (`Sources/WireMVC/Routing.swift:36`) — every conforming
  builder, including hand-written ones and both adapters.
- `RequestBound.bind(name:request:pathParameters:body:)` (`Sources/WireMVC/RequestBinding.swift:57`) — the
  protocol **every** `@RequestBinding` conforms to, user-written ones included.

Sixteen signature sites in wire-mvc itself, twelve of them the built-in bindings in `RequestBinding.swift`,
plus `RouteContext.pathParameters` as a public stored property.

The `register` comment says WireMVC owns this shape, so this is **not** an upstream ask. It is entirely a
question of when.

## Why it has a date

After 1.0, changing `RequestBound.bind` breaks every binding anyone has written against it, and changing
`register`'s handler shape breaks every builder. Before 1.0 it costs a mechanical sweep. That is the same
trade `#148` spent on the response-header registry, and it is the *last* one Phase 5 is holding — see
`RemainingSurfaceWork.md`, which said otherwise until it was corrected.

The allocation is the smaller half of why it matters. "Should a handler receive a hash table, or a view
onto what the router already matched?" stands as a design question with the allocation set aside.

## Why it cannot simply become positional

Two consumers need lookup **by name at runtime**, so the values alone are not enough:

- `RequestBound.bind` takes a `name` and is implemented by types the framework has never seen.
- `RouteContext` is read by middleware, which does not know the route template statically.

Only codegen knows that `{id}` is parameter 0. So a replacement has to keep by-name lookup and stop
*materialising a hash table* for it — a view over the route's own `parameterNames` and the positional
values, with a subscript. Call sites barely move: `pathParameters[name]` still compiles, and
`RouteContext`'s `subscript(_ name: String) -> String?` keeps its exact signature. What changes is the type
in those sixteen places.

## The constraint that makes it bigger than two allocations

On a bridged runtime the host's router matched, and parameters arrive as `metadata.pathParameters` —
`[String: Substring]`, fixed by the proposal's `ServerRequestMetadata`. So the replacement either carries a
dictionary case (bridged pays exactly what it pays today, one branch per lookup) or the bridge converts and
pays **more** than today. Only the first is acceptable, and it means the type abstracts over two
representations rather than being a straight positional view.

## What would settle it

A measured pair for the allocation half, which does not exist yet — `wire-mvc-performance` is where it
lives. But the measurement does not decide this; the deadline does. If the shape is right it should change
while it is cheap, and if the dictionary is the right public shape then group #2's second allocation is
closed as not-addressable and should be written down as such, the way #7 was.

## Not to be confused with

Group #2's **first** allocation — the `[Substring]` of parameter values collected during the walk. That is
internal to `WireMVCRouter`, takes the same `InlineArray` treatment `#135` gave the registry, needs no
decision and no deadline.
