# Multibindings

Four key flavours for the bindings that are one-of-many, and one attribute that contributes to
all of them.

## Overview

Some dependencies are naturally a set rather than a single value — the services a lifecycle
runs, a middleware chain, health checks, strategies by name. Wire handles them with keys that
aggregate, and with ``Contributes(to:)-(CollectedKey<Element>)`` on the contributing side.

Contribution is always **explicit**. Adding a type that happens to conform to a protocol never
joins it to a collection; the contributor has to name the key. That rules out the most-cited
surprise in container-based DI, where a new class silently joins every consumer of a marker
protocol, and it means refactoring a conformance cannot quietly change what a collection
contains.

## `CollectedKey` — a list

```swift
extension App {
    static let services = CollectedKey<any Service>()
}

@Singleton @Contributes(to: App.services)
struct AuthService: Service { … }

@Singleton @Contributes(to: App.services)
struct MetricsEmitter: Service { … }

@Singleton
struct Application {
    @Inject(App.services) var services: [any Service]
}
```

A contributor keeps its own binding identity — it is still independently injectable — and
additionally fans into the aggregate. A consumer asking for `[any Service]` *without* a key
gets a literal-list binding instead, if one exists; the two are different lookups and can
coexist.

## `MappedKey` — a dictionary

```swift
extension App {
    static let strategies = MappedKey<String, any Strategy>()
}

@Singleton @Contributes(to: App.strategies, atKey: "fast")
struct FastStrategy: Strategy { … }

@Inject(App.strategies) var strategies: [String: any Strategy]
```

`atKey:` is required on every contribution and typed to the map's `Key`, so a wrong-typed entry
fails to compile. Duplicate keys are a build error rather than a compiler concern, because a
duplicate-key dictionary literal traps at runtime.

## `BuilderKey` — a typed fold

When the aggregation is neither a list nor a map but a *composition* whose type changes with
each addition, declare a ``BuilderKey`` over your own `@resultBuilder`:

```swift
@resultBuilder
enum MiddlewareBuilder {
    static func buildBlock(_ parts: any Middleware...) -> [any Middleware] { Array(parts) }
}

extension App {
    static let middleware = BuilderKey<MiddlewareBuilder>()
}
```

The plugin orders the contributors and emits a fold annotated with your builder attribute; the
compiler then dispatches whichever builder methods you defined. Wire stays out of the builder's
protocol entirely, which is what lets the builder's own `where` clauses act as the constraints
on contributing — a mismatched middleware fails from *your* signature, not from Wire's logic.

## `FactoryKey` — a namespace, not an aggregate

``FactoryKey`` joins the family but is not typed to a produced value, because a ``Factory(_:)``
template's product varies per consumer. It is a pure namespace token whose identity is the text
of its declaring reference. See <doc:ScopesAndLifetimes>.

## Ordering

`withOrder:` ranks contributors on a `CollectedKey` or a `BuilderKey`. The rule is
all-or-nothing: **if any contributor on a key specifies an order, all of them must.** Mixing is
a build error, and so is a duplicate order on one key — both would otherwise leave the
aggregate's sequence dependent on something you cannot see from the declarations.

Relative ordering (`before:` / `after:` naming other types) is deliberately not offered.
Topological ordering over relative constraints brings cycle detection and its diagnostics along
with it, and integer priority avoids the whole class.

## Empty and unused keys

Zero contributors resolves to an empty aggregate rather than a missing member, so a key is
always safe to consume. Each key type takes `allowUnused:` to silence the dead-or-empty warning
when emptiness is genuinely valid:

```swift
static let optionalHooks = CollectedKey<any Hook>(allowUnused: true)
```

## A key is an extension point

If you inject a multibinding key you do not own, any other activated package may also
contribute to it, so the collection can grow when you add a dependency. That is the intended
plugin-registry behaviour. When you need certainty about the complete set of contributors,
declare the key in a target you control — most strongly your leaf application target, which
nothing depends on, so only your own code can reach it. See <doc:ComposingAcrossModules>.
