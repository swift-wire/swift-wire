# Injection points

The forms [`@Inject`](doc:Inject()) takes, which of them feed the generated initialiser, and
which are delivered after construction.

## Overview

`@Inject` contributes no code of its own. It is a marker that the enclosing scope macro reads
to synthesise an initialiser, and that the build plugin reads to discover dependencies. Putting
it on a type carrying no lifetime macro is harmless and pointless, and the plugin says so.

Most injection points are constructor parameters. Two forms are not, and they exist for the two
cases the constructor cannot serve: breaking a reference cycle, and delivering a value into
storage you control.

## Constructor injection

Mark stored properties, and the scope macro generates an `init` taking one parameter per
injection point in declaration order:

```swift
@Singleton
struct UserService {
    @Inject var store: any UserStore
    @Inject var logger: Logger
}
```

The type is read exactly as written. `var store: any UserStore` gives you an existential;
`var store: Store` on a generic type keeps the consumer generic. Wire is neutral about which —
see <doc:ChoosingAnAbstraction>.

## Writing the initialiser yourself

When construction does real work — an `async throws` connect, say — mark your own initialiser
instead and let its parameters declare the dependencies:

```swift
@Singleton
struct DatabasePool {
    @Inject
    init(url: String) async throws { … }
}
```

`@Inject` on both an initialiser and a stored property is an error: the two would be competing
declarations of the same thing, so you pick one source of truth.

Keying a parameter needs a different attribute. `@Inject` is a peer macro, and Swift does not
allow a macro attribute on a function parameter, so a parameter carries ``Bind`` instead — a
property wrapper, which *can* attach there, and which is transparent at runtime:

```swift
@Singleton(as: TodoRepository.self)
struct CouchDBTodoRepository: TodoRepository {
    @Inject init(@Bind(CouchDB.httpClient) client: HTTPClient) async throws { … }
}
```

An unkeyed parameter still resolves by type; `@Bind` is only needed to choose among several
bindings of one type. It also takes the multibinding keys, so a `@Provides func` or `@Inject
init` can take an aggregate:

```swift
@Provides
static func router(@Bind(App.routes) routes: [Route]) -> Router { … }
```

## Post-construction delivery

**`@Inject weak var x: T?`** is the cycle-breaker. Swift's `weak` means mutable optional
storage, which cannot be an init parameter, so Wire excludes it from the synthesised init and
assigns it after both objects exist. The graph treats that edge as deferred, so a cycle closing
through it is legal where a cycle through constructor edges is an error.

```swift
@Singleton final class Coordinator {
    @Inject init(view: View) { … }
}

@Singleton final class View {
    @Inject weak var coordinator: Coordinator?
}
```

Topological sort puts `View` first, `Coordinator` second, and the bootstrap assigns
`view.coordinator` afterwards. The runtime relationship is exactly what Swift's `weak` already
means; Wire is respecting the language rather than inventing a lifetime rule.

**`@Inject unowned let x: T`** is the non-optional sibling, and it is *not* a cycle-breaker:
non-optional storage must be initialised in `init`, so it is constructor-injected like any
other property. Use it for a non-owning reference to something the graph is known to keep
alive, when you would rather not write `?` at every use.

**`@Inject func receive(_ x: T)`** is the general form. You write the method, its parameters
declare the dependencies, and the plugin calls it after the consumer is constructed. What the
method does with the value — a `Mutex`-wrapped store, an actor hop, an instrumentation hook —
is yours to decide.

```swift
@Singleton final class ConfigBoard: Sendable {
    private let storage = Mutex<ConfigData?>(nil)

    @Inject
    func apply(config: ConfigData) {
        storage.withLock { $0 = config }
    }
}
```

Both forms coexist with a custom `@Inject init`, because their delivery does not compete with
the initialiser's parameter list.

A post-construct member must be at least `internal`: the generated bootstrap calls it from a
separate file in the same module.

## Actors

`@Inject func` on an `actor` is the natural pairing — actors are `Sendable`, so the consumer
slots into the graph without workarounds, and the plugin emits `await consumer.method(args)`
at the call site to pay for the isolation crossing. `@Inject weak var` on an actor works the
same way from where you sit; underneath, the plugin synthesises a setter extension, because
assigning a property from outside actor isolation is not legal Swift.

## What still gets validated

Member-injected parameters are ordinary graph dependencies: a missing binding is the same
error it would be on a constructor parameter, and keys disambiguate the same way. The only
difference is cycle detection, which treats these edges as deferred.

`@Inject mutating func` on a struct is rejected outright. Value semantics mean a consumer that
received the struct by init would keep the pre-mutation copy while only the graph's value
reflected the change — a silent divergence, so Wire refuses to emit it and points at the
alternatives instead.
