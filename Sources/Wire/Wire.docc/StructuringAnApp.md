# Structuring an app with Wire

Where Wire sits in a layered or ports-and-adapters design, and what it does not decide for you.

## Overview

Wire is a **composition mechanism**. It validates the dependency graph at build time and emits
the wiring code; it does not dictate architectural style. An application using Wire can be
hexagonal, onion, plainly layered, or transaction-script. The annotations describe *what* goes
in the graph — which layer each type belongs to stays your design decision.

That said, the annotations do line up with ports and adapters cleanly enough to be worth
spelling out, because the mapping tells you which annotation to reach for.

## The ports-and-adapters mapping

Hexagonal architecture separates the application's core logic from its infrastructure. *Ports*
are the protocols the application defines; *adapters* implement them. Application code depends
on ports, never on adapters, and the implementations are plugged in at composition time.

- **Controllers are inbound adapters.** A `@Controller` translates an HTTP request into an
  application-service call. It sits at the edge, depends on protocols or generic parameters the
  application defines, and does its work by calling into the domain.

- **A ``Provides(allowUnused:)`` binding typed as a protocol is an outbound port.** When you write
  `@Provides func database(…) -> any DatabaseClient`, the consumer depends on the port —
  `any DatabaseClient` — not on the concrete implementation the function constructs internally.

- **The concrete type the function returns is the outbound adapter.** It is named in one place,
  the provider, and nothing downstream of it knows what it is.

So the three edges Wire wires are: inbound adapters to application services, application
services to outbound ports, and outbound ports to outbound adapters.

```swift
// Port — what the application depends on.
protocol UserStore: Sendable {
    func user(id: String) async throws -> User?
}

// Outbound adapter, named once, at the provider.
@Provides
func userStore(_ db: Database) -> any UserStore { PostgresUserStore(db) }

// Application service — depends on the port.
@Singleton
struct UserService {
    @Inject var store: any UserStore
}
```

Swapping `PostgresUserStore` for an in-memory implementation is a change to one provider
function. Nothing that consumes `any UserStore` mentions either type.

## The three layers

An application built this way has three kinds of package, and it is worth being clear which
one you are writing at any moment:

**Wire itself** knows nothing about HTTP, databases or any other domain. It knows about
bindings, scopes, keys and graphs. Every domain-specific behaviour reaches it through the
adapter-annotation contract rather than through a special case in the core.

**Adapters** carry the domain knowledge. WireMVC knows what a route is; WireOpenAPI knows what
an operation is; WireConfiguration knows what reading a configuration value means. Each declares
a capability, and Wire copies its arguments without interpreting them — which is why a
third-party adapter needs no change to Wire.

**Your application** depends on the adapters it wants and on Wire, and writes ordinary Swift
with annotations on it. Depending on a Wire-aware library is what activates its bindings; there
is no registration step and no import-triggered side effect.

## Scopes are the lifetime decision

Wire's scope model is flat-with-siblings rather than nested: app-scoped ``Singleton(allowUnused:)`` bindings,
plus a seeded ``Scoped(seed:allowUnused:)`` partition for each request, job or tenant. A request-scoped controller
is constructed fresh per request and torn down at the end of it; an app-scoped one is built once.

Choosing between them is a lifetime question, not an architectural one — and it is the decision
most worth getting right early, because it is the one that shows up in the generated code and in
what a test has to supply.
