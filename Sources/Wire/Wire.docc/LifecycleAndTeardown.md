# Lifecycle and teardown

Asynchronous construction comes free with Swift's initialisers. Shutdown is the asymmetric
case, and [`@Teardown`](doc:Teardown()) is how a binding declares it.

## Overview

Wire needs nothing special for async or throwing setup — `init(…) async throws` already says it,
and the plugin propagates `await` and `try` through the whole construction chain, which is why
`bootstrap()` is `async throws`. There is no `@PostConstruct`-style second step, because Swift
constructors do not need one.

```swift
@Singleton
struct DatabasePool {
    let client: PostgresClient

    @Inject
    init(url: String) async throws {
        self.client = try await PostgresClient.connect(to: url)
    }
}
```

Teardown is where the symmetry breaks: Swift has no async `deinit`. Rather than a protocol Wire
probes for, or a wrapper type it knows to unwrap, teardown is marked **explicitly at the
binding's declaration**. The graph already knows construction order; the attribute only says
which nodes have an action and what it is.

## The owned-type form

Mark the method on a type you wrote:

```swift
@Singleton
struct DatabasePool {
    @Teardown
    func teardown() async throws {
        try await client.shutdown()
    }
}
```

It may be named anything and takes no parameters, but it must be at least `internal` — the
generated bootstrap calls it from a separate file, the same visibility rule post-construct
injection follows. Its effect specifiers are read off the declaration, so the emitted call gets
the right colour.

## The producer form

For a type you did not write, attach the action to the
[`@Provides`](doc:Provides(allowUnused:)):

```swift
@Provides
@Teardown({ (client: HTTPClient) in try await client.shutdown() })
static func httpClient() -> HTTPClient {
    HTTPClient()
}
```

The produced type stays honest — consumers inject `HTTPClient`, with no wrapper and no unwrap
step. The action is an explicit-typed closure or a reference to a free or static function, and
a synchronous, non-throwing action coerces into the `async throws` contract. Swift attributes
take no trailing-closure sugar, so the closure is parenthesised and its parameter explicitly
typed; `$0` inference does not reach across an attribute.

## Why not a `Lifecycle` protocol

A recognised conformance is still framework magic: the container probes for it, it cannot
distinguish two bindings of the same type with different shutdown needs, and it moves a
per-binding decision off the declaration and into the type system. `@Teardown` keeps the
decision local, per-binding and statically known — the same reasoning that keeps ``Lazy`` an
ordinary type rather than something the framework unwraps.

## What runs, and in what order

Every generated graph conforms to ``Teardownable``, so a facade can drive shutdown through
`some Teardownable` without naming the internal graph type:

```swift
let errors = await graph.teardown()
```

Actions run in **reverse construction order** — dependents before dependencies — so a
repository tears down before the pool it holds, letting in-flight work finish first.

`teardown()` **collects** rather than throws. A failing action does not stop the ones after it,
and the returned errors are yours to log. A graph with no `@Teardown` bindings gets the protocol
default and has nothing to run.

Scope teardown works the same way at the other lifetime: a seeded scope's actions fire when the
scope ends, including when it ends by cancellation. A request-scoped transaction that rolls
back unless committed is the canonical use.

## Teardown is not a reason to build something

Marking a binding `@Teardown` does not make it a root. Teardown is what happens to a binding you
built, not a reason to build one — if nothing reaches a resource it is never constructed, so
there is nothing to shut down. A resource whose *construction* is the point says so with
`allowUnused: true`. See <doc:WhatGetsBuilt>.

## Services are a different concern

A `Service` with a `run()` loop that something orchestrates — an HTTP server, a queue consumer —
is not a teardown case. Contribute it to the relevant collection instead
(<doc:Multibindings>), and keep `@Teardown` for resources: pools, clients, verifiers. A type
with both responsibilities can have both, but most types are one or the other.
