# Scopes and lifetimes

The three lifetime macros, what a seed is, and what it costs to cross a scope boundary.

## Overview

Wire's lifetime model is **flat with siblings**, not a tree. There is one app-scoped partition
that lives for the process, and any number of *seeded* scopes beside it — one per request, job,
tenant or session — that open and close on their own schedule. Scopes do not nest, and a scope
is not a container you register things in: it is a partition of the same graph, identified by
a type.

Choosing a lifetime is the decision that shows up in the generated code, in what a test has to
supply, and in which injections the plugin will refuse. It is worth getting right early.

## App lifetime: `@Singleton`

[`@Singleton`](doc:Singleton(allowUnused:)) is process lifetime — constructed once during
`bootstrap()` and shared by everything that injects it. Database pools, HTTP clients,
configuration, the base logger.

```swift
@Singleton
struct ConnectionPool {
    @Inject var config: PoolConfig
}
```

## Scope lifetime: `@Scoped(seed:)`

[`@Scoped`](doc:Scoped(seed:allowUnused:)) gives a binding the lifetime of a scope, and the
scope is identified by its **seed** — the type whose runtime value opens it. Two bindings share
a scope if and only if they name the same seed type.

```swift
@Scoped(seed: HTTPRequest.self)
struct RequestLogger {
    @Inject var request: HTTPRequest   // the seed itself
    @Inject var logger: Logger         // a singleton
}
```

The seed is bound in its own scope, so it is injectable like anything else — there is no
wrapper type to learn, and no framework-owned context object. A job scope is
`@Scoped(seed: SQSMessage.self)` and works identically. Several seed types coexist in one
graph; a service can have request-scoped, job-scoped and session-scoped bindings at once.

The plugin emits one scope facade per seed type — `Wire.bootstrapHTTPRequestScope(seed:wireGraph:)`
for the example above — taking the seed value and the app graph the scope borrows its singletons
from. Normally the adapter owning the seed drives that entry, once per request or message, and
nothing in your own code touches it. A program with no adapter can call the facade itself.

### Declaring a scope's providers in one place

Applied to a caseless enum, `@Scoped(seed:)` defines a **scope block**: every
[`@Provides`](doc:Provides(allowUnused:)) inside it is routed into that seed's scope without
repeating the seed on each one. It is the scope-axis sibling of
[`@Container`](doc:Container()).

```swift
@Scoped(seed: RequestSeed.self)
enum RequestProviders {
    @Provides static func makeContext(seed: RequestSeed) -> Context { … }
    @Provides static let tag: Tag = Tag()
}
```

On an enum the macro synthesises nothing — it is a marker the plugin reads. A `@Singleton`
self-producer cannot live in a scope block, since its lifetime is the process rather than the
scope, and the plugin says so.

## No lifetime at all: `@Factory`

[`@Factory`](doc:Factory(_:)) is the third lifetime macro and the one that names no scope. It
marks a generic type as a *template*, identified by a ``FactoryKey``, whose generic parameters
are supplied per use site rather than resolved from the graph.

Two objects are involved and they have different lifetimes, which is the part worth spelling
out:

- The **factory** the plugin synthesises is an app-lifetime graph binding, constructed once.
- The **template** — the type you wrote the attribute on — is constructed per `create` call,
  and is not a binding at all.

The consequence bites in practice: a template's `@Inject` members are resolved once, where the
*factory* is constructed, not per call. So a `@Scoped(seed:)` binding cannot be one of them —
not because the template is in the wrong scope, but because it has none. For the same reason
`@Factory` is mutually exclusive with `@Singleton` and `@Scoped(seed:)`: a declaration has one
lifetime, and Wire refuses the combination rather than emitting two colliding initialisers.

## Crossing a boundary

A scoped binding sees singletons. A singleton does not see scoped bindings, and asking for one
is a build error at the injection site rather than a runtime surprise.

The fix is usually to move the consumer rather than to reach across. A controller that wants
per-request logging is naturally request-scoped itself; making it a singleton that somehow
resolves request state is the shape the error is steering you away from.

## Deferring construction inside a scope

When a binding genuinely should not be built at bootstrap — an expensive resource that is not
always exercised — inject ``Lazy`` instead of the value:

```swift
@Singleton
struct Application {
    @Inject var pool: Lazy<DatabasePool>

    func handle() async throws {
        let db = try await pool.get()
    }
}
```

`get()` is `async throws` whatever `T`'s initialiser looks like, so your call site does not
change when `T`'s init colour does. Exactly one factory invocation happens however many callers
race the first `get()`, and a factory that throws caches its failure rather than retrying.

`Lazy` is **intra-scope only**: the deferred value resolves against the consumer's own scope,
never a sibling's. It is a deferral primitive, not a way around the boundary above — and it is
not the cycle-breaker either, since its edge participates in cycle detection like any other.
For that, see the weak form in <doc:InjectionPoints>.
