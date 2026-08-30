<p align="center">
  <a href="https://github.com/tachyonics/swift-wire/actions/workflows/swift.yml">
    <img src="https://github.com/tachyonics/swift-wire/actions/workflows/swift.yml/badge.svg" alt="Build">
  </a>
  <a href="https://swiftpackageindex.com/tachyonics/swift-wire">
    <img src="https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Ftachyonics%2Fswift-wire%2Fbadge%3Ftype%3Dswift-versions" alt="Swift versions">
  </a>
  <a href="https://codecov.io/gh/tachyonics/swift-wire">
    <img src="https://codecov.io/gh/tachyonics/swift-wire/graph/badge.svg" alt="Code coverage">
  </a>
  <a href="https://swiftpackageindex.com/tachyonics/swift-wire">
    <img src="https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Ftachyonics%2Fswift-wire%2Fbadge%3Ftype%3Dplatforms" alt="Platforms">
  </a>
  <a href="https://www.apache.org/licenses/LICENSE-2.0">
    <img src="https://img.shields.io/badge/License-Apache_2.0-blue.svg" alt="License: Apache 2.0">
  </a>
</p>

# swift-wire

> Compile-time-validated dependency injection for server-side Swift on Linux.

**Status:** pre-alpha. Nothing is built yet. The library is being designed and developed alongside `task-cluster`, a server-side Swift demonstration application, and a corresponding blog series. This README is the current design spec; expect it to iterate as task-cluster grows.

---

## What swift-wire is

swift-wire is a compile-time-validated dependency injection library, being built alongside `task-cluster` — a demonstration application that grows in complexity over time — and an accompanying blog series. The library lands new capabilities as task-cluster needs them: request-scoped observability when the HTTP layer gains tracing, lifecycle hooks when there's a DB pool to shut down cleanly, multi-module composition when task-cluster's library targets start shipping their own bindings.

The architectural commitment is an *adapter-annotation contract* — a published, versioned macro-based extension mechanism that lets third-party packages contribute framework integrations (Hummingbird, the OpenAPI generator, queue consumers, schedulers) by publishing their own annotations rather than being baked into the core. The DI core does the wiring; the contract is what turns that core into a platform other packages build against rather than a closed system that knows only its own concepts. The application domain is server-side Swift on Linux: scopes are seed-typed (`@Singleton` for process lifetime; `@Scoped(seed: X.self)` for any sibling lifetime keyed by the seed type, with adapter packages publishing convenience macros for common seeds like HTTP requests and job messages), the build plugin runs against the SPM toolchain on Linux as a first-class target, and the macro surface is shaped by Swift 6's concurrency model.

The design language is openly Java-DI shaped — `@Inject`, `@Provides`, scope macros, adapter annotations. The audience whose intuitions transfer cleanly is anyone working in annotation-based, container-driven backend DI: Spring and Dagger on the JVM, NestJS on Node.js, ASP.NET Core's built-in DI, or teams that want their Swift service to feel architecturally like the other server services they operate. The cross-section that targets Swift-server is small today; the project is partly a bet on Swift's continued growth with developers coming from a non-iOS background.

That Java-DI shape is the on-ramp; the differentiation comes from features designed around Swift's type system specifically. Two anchors. **Opaque binding identities** (`@Provides -> some P`, `@Singleton(as: P.self)`) preserve concrete type identity through the graph at compile time, so an abstract dependency resolves without dynamic dispatch — no existential boxing, no witness-table indirection. No DI framework I can find preserves an *abstraction's* identity this way: JVM/.NET/Node containers all resolve abstract dependencies through an interface reference. The nearest miss is Rust's pavex, whose generated wiring has no dynamic dispatch anywhere — but it has no binding identity to preserve, keying constructors on their concrete return type instead, so it sidesteps the problem rather than solving it. Rust is also the honest check on how much credit this deserves: `impl Trait` and generic bounds make the zero-cost form the *idiomatic* one there, so its compile-time containers reach static resolution without an identity model at all. Swift's idiomatic abstraction is `any P`, which is why arriving at the same place here takes machinery. That costs them very little *relative to the concrete alternative* — the object is heap-allocated and reached through a pointer either way, and the call was already dynamically dispatched, so abstracting buys a slightly worse dispatch path (`invokeinterface`, virtual stub dispatch) and some lost devirtualisation, not a change in how the value is represented. Swift's `any P` is a different kind of cost: it boxes, heap-allocates anything that doesn't fit inline, and forecloses specialisation across the boundary — a delta with no JVM equivalent. That is why eliminating it is worth machinery that would buy nothing on the JVM, and Swift is one of the few languages with a construct (`some P`) that can express the elimination. The trade is real and runs the other way too: those containers bind *open* generics (`IRepo<>` → `Repo<>`, resolved for every `T`) where Wire's opaque chain is viral, and each hop must be restructured as a generic type. That virality has no analogue among DI frameworks, but it is ordinary as a *language* pattern — Rust propagates `T: Repository` bounds through intervening types the same way, at ecosystem scale, and reaches for `Box<dyn Trait>` at the hop where the chain stops being worth it. Wire ships the same valve: `some P` satisfies `any P` promotion, so the chain can be cut where it gets painful. See [`OpaqueTypesInContext.md`](Documentation/Notes/OpaqueTypesInContext.md) for the full comparison. **`BuilderKey<B>`** folds multibinding contributors through a user-defined `@resultBuilder` type, letting consumers express composition semantics no other DI framework offers because `@resultBuilder` machinery doesn't exist outside Swift. swift-wire isn't "Dagger ported to Swift"; it's an exploration of what a DI framework looks like when designed *for* Swift's type system rather than just what can be achieved in other languages. Both features have detailed design notes (`Documentation/Notes/BuilderKeyDesign.md`, `Documentation/Notes/OpaqueTypesSupport.md`); opaque identities shipped in M1, `BuilderKey`'s parameterized-opaque fold is deferred to M2, and they're the architectural anchors that justify the project beyond a Java-DI port.

If you came here looking for a polished library to adopt, this isn't that yet. swift-dependencies is the fastest path to DI ergonomics today; SafeDI is the closest existing compile-time-safe option (iOS-shaped). swift-wire's reason for existing is the gap none of those fill — a compile-time graph extensible by third-party adapters, applied to server-side Swift on Linux, with task-cluster as the live test case.

---

## The diff that justifies the project

Below is `task-cluster`, an existing Hummingbird + OpenAPI-generator service in this workspace, rewritten with swift-wire. Compare against `secondary/task-cluster/` to see today's manual wiring.

### Today (manual wiring)

`Sources/TaskCluster/TaskCluster.swift`:

```swift
@main
struct TaskCluster {
    static func main() async throws {
        let config = ConfigReader(provider: EnvironmentVariablesProvider())
        let port = config.int(forKey: "HTTP_PORT", default: 8080)

        let logger = Logger(label: "TaskCluster")
        let table = InMemoryDynamoDBCompositePrimaryKeyTable()
        let repository = DynamoDBTaskRepository(table: table)
        let configuration = ApplicationConfiguration(address: .hostname("0.0.0.0", port: port))

        let application = try buildApplication(
            repository: repository,
            configuration: configuration,
            logger: logger
        )
        try await application.run()
    }
}
```

`Sources/TaskClusterApp/Application+build.swift`:

```swift
package func buildApplication<Repository: TaskRepository>(
    repository: Repository,
    configuration: ApplicationConfiguration,
    logger: Logger
) throws -> some ApplicationProtocol {
    let router = Router(context: BasicRequestContext.self)
    router.addMiddleware { LogRequestsMiddleware(.info) }
    router.get("/health") { _, _ in HTTPResponse.Status.ok }

    let controller = TaskController(repository: repository)
    try controller.registerHandlers(on: router)

    return Application(router: router, configuration: configuration, logger: logger)
}
```

`Sources/TaskClusterApp/TaskController.swift`:

```swift
package struct TaskController<Repository: TaskRepository>: APIProtocol {
    var repository: Repository
    // ... 4 OpenAPI handler methods
}
```

This is fine at this size. It doesn't stay fine. Add a JWT verifier, an S3 client, a metrics emitter, and a request-scoped tenant context — each depending on two or three of the others — and `TaskCluster.swift` plus `buildApplication` becomes hand-threaded wiring soup.

### With swift-wire

`Sources/TaskClusterDynamoDBModel/DynamoDBTaskRepository.swift`:

```swift
@Singleton
package struct DynamoDBTaskRepository<Table: DynamoDBCompositePrimaryKeyTable & Sendable>: TaskRepository {
    @Inject var table: Table
    // unchanged: methods use self.table directly
}
```

`Sources/TaskClusterApp/TaskController.swift`:

```swift
@Scoped(seed: HTTPRequest.self)                     // request-scoped: one per HTTP request
@OpenAPIController                                  // adapter annotation from WireOpenAPI
package struct TaskController<Repository: TaskRepository>: APIProtocol {
    @Inject var repository: Repository              // singleton — fine to inject from request scope
    @Inject var requestLogger: RequestLogger        // same scope — direct injection, no wrapper
    // unchanged: 4 handler methods, now call requestLogger.logger to emit
}
```

`Sources/TaskClusterApp/RequestLogger.swift` (new — but task-cluster *should* have this):

```swift
@Scoped(seed: HTTPRequest.self)
struct RequestLogger {
    @Inject var baseLogger: Logger
    @Inject var request: HTTPRequest         // the seed itself, injectable like any scoped value

    var logger: Logger {
        var l = baseLogger
        l[metadataKey: "path"] = "\(request.path ?? "")"
        return l
    }
}
```

The HTTP request scope is seeded on `HTTPRequest` — the request *is* the seed, so there is no adapter-published wrapper type to learn. Two `@Scoped(seed: HTTPRequest.self)` types share a request scope: both are constructed fresh per request, both can inject the seed and any other request-scoped value directly, and singletons (the repository, base logger) inject through unchanged.

`Sources/TaskCluster/Bootstrap.swift`:

```swift
import Wire
import WireMVC
import WireOpenAPI

@Provides let logger = Logger(label: "TaskCluster")
@Provides let table = InMemoryDynamoDBCompositePrimaryKeyTable()

@Singleton                                          // it is a graph binding like any other
@WireMVCBootstrap                                   // …and the program entry point is generated from it
struct AppBootstrap {
    @Inject let config: ServerConfig

    func createServer() throws -> NIOHTTPServer {
        NIOHTTPServer(logger: Logger(label: "TaskCluster"), configuration: try .init(
            bindTarget: .hostAndPort(host: config.host, port: config.port),
            supportedHTTPVersions: [.http1_1],
            transportSecurity: .plaintext
        ))
    }

    func createRouteBuilder<Server: HTTPServer>(for server: borrowing Server) -> some ... {
        TrieRouteBuilder(for: server)
    }
}
```

There is no `main.swift` and no hand-written `@main`: `swift run TaskCluster` bootstraps the graph, constructs `AppBootstrap`, registers every collated controller onto its route builder, and serves. `TaskController` and `DynamoDBTaskRepository` are picked up automatically (sibling targets in the same `Package.swift`), and `WireOpenAPI`'s `@OpenAPIController` support is composed because `WireOpenAPI` is a dependency of this target — depending on a Wire-aware library activates it, no call needed. The full shape, including what the generated entry point actually emits, is in [The entry point](#the-entry-point) below.

What you actually get from this:

- **Generics are preserved.** `TaskController<Repository>` stays generic. `DynamoDBTaskRepository<Table>` stays generic. The build plugin specializes both at the resolution site — when there's exactly one binding for `DynamoDBCompositePrimaryKeyTable & Sendable` (the in-memory one), it picks `Table = InMemoryDynamoDBCompositePrimaryKeyTable`, and `TaskController` is constructed as `TaskController<DynamoDBTaskRepository<InMemoryDynamoDBCompositePrimaryKeyTable>>`. No existential boxing introduced by the library.
- **The graph is validated at build time.** Forget to bind a `DynamoDBCompositePrimaryKeyTable` and Swift won't compile. Inject a `@Scoped(seed: X.self)` value as a stored property on a `@Singleton` and the build plugin refuses with a fix-it (make the consumer `@Scoped(seed: X.self)` too, or compose via a scope-appropriate wrapper).
- **`@OpenAPIController` is the architectural feature, not a one-off helper.** It's an *adapter annotation* — a macro published by `WireOpenAPI` declaring one **capability**, which is all Wire acts on: collate this binding's generated proxy into a key the adapter owns. The same mechanism carries WireMVC's `@Controller` and `@Middleware`, WireHummingbird's `@HummingbirdController`, and WireConfiguration's `@ConfigProperty`, and is open to any third party — see *Adapter annotations* below. The Wire core knows nothing about OpenAPI.
- **Tests select an alternative `@Container` at the entry point** instead of re-instantiating types with different generic arguments by hand. The chosen container is the whole graph for that test run.

If that diff doesn't look like a meaningful improvement to you, the project doesn't have a reason to exist and you should close this README.

---

## Concepts

### Scope annotations

Two built-in scope macros:

| Macro                          | Lifetime                                                | Typical contents                                     |
|--------------------------------|---------------------------------------------------------|------------------------------------------------------|
| `@Singleton`                   | process                                                 | DB pools, HTTP clients, config, metrics, base logger |
| `@Scoped(seed: SeedType.self)` | one instance per externally provided `SeedType` value   | request-derived state, per-job tenant context        |

`@Scoped` is *seed-typed*: every non-singleton scope is identified by the concrete type whose runtime instance opens it. An HTTP request scope is `@Scoped(seed: HTTPRequest.self)` — the request itself is the seed, so there is no wrapper type; a job scope would be `@Scoped(seed: SQSMessage.self)`. The seed type is the only contract — anyone (the Wire user, an adapter package, a third party) can publish a seed type and the types scoped to it will compose naturally. Multiple seed types coexist; a single graph might host request-scoped, job-scoped, and WebSocket-session-scoped bindings simultaneously.

Singletons outlive everything. Scoped instances see singletons (and the seed value itself) but not each other across scope boundaries. Asking for a scoped type from a singleton — or from a scope keyed by a different seed — is a compile error pointing at the injection site; the fix is either widening the seed or scoping the consumer the same way.

Hierarchical seeded scopes (`@Scoped(seed:, within:)`) are a deferred decision: the data model reserves the slot, but no scope is hierarchical in 0.x. A real adopter case forces the design.

### `@Inject` and how the macro generates an init

`@Inject` marks an injection point on a stored property. The scope macro on the enclosing type generates an `init` that takes one parameter per injection point, in declaration order. The build plugin emits the actual call site: `TaskController(repository: ..., requestLogger: ...)`. You don't write the init.

The macro reads the property type as written. `var repository: Repository` keeps `TaskController` generic over `Repository`. `var repository: any TaskRepository` makes it an existential. The library is neutral — pick the one whose performance characteristics you want.

`@Inject` also recognises two post-construct forms that *don't* feed the synthesised init — `@Inject weak var` for weak storage and `@Inject func` for method-delivered dependencies. Those are covered in [Post-construction injection](#post-construction-injection) below; the constructor flow above is the default for everything else.

### Post-construction injection

Not every dependency fits the constructor flow. Two cases come up enough that Wire ships first-class support: **cycle-breaking** (two types mutually reference each other) and **delivery to custom storage** (a Mutex-wrapped weak ref, an actor-isolated mutator, an instrumentation hook). Both use `@Inject` on an attachment site other than a normal property; both are delivered after the consumer's `init` has run.

**`@Inject weak var x: T?`** is the compact spelling. Swift's `weak` modifier means the property is mutable storage that can't live in an init parameter, so Wire excludes it from the synthesised init and wires it post-construct instead. The graph treats the edge as cycle-breaking — topological sort doesn't see it as a constructor-time dependency.

```swift
@Singleton final class Coordinator {
    @Inject init(view: View) { /* ... */ }
}

@Singleton final class View {
    @Inject weak var coordinator: Coordinator?
}
```

Topo sort: `View` first (no strong deps), `Coordinator` second (takes `View`). Generated bootstrap: `view.coordinator = coordinator` after both exist. The runtime relationship is what Swift's `weak` keyword already means — non-owning, zeroing on dealloc. Wire just respects the language semantics.

**`@Inject func receive(_ x: T)`** is the general form. The user writes a method; the parameter list declares the deps; the build plugin calls the method with resolved arguments after construction. What the method *does* internally — Mutex-wrapped storage, actor messaging, instrumentation, anything — is the user's choice. Wire stays out of the storage decision.

```swift
@Singleton final class ConfigBoard: Sendable {
    private let storage = Mutex<ConfigData?>(nil)

    @Inject
    func apply(config: ConfigData) {
        storage.withLock { $0 = config }
    }
}
```

For consumers that need a custom `@Inject init` *and* post-construct deps, the two coexist: `@Inject weak var` and `@Inject func` are exempt from the "init OR properties, never both" rule because their delivery doesn't compete with the init's parameter list.

**Actor consumers.** `@Inject func` on an `actor` is the canonical "checked-Sendable + post-init wiring" pattern — actors are inherently `Sendable`, so the consumer slots into a `Sendable` `_WireGraph` without `@unchecked` workarounds. The build plugin emits `await consumer.method(args)` at the call site (the `await` pays for the isolation crossing, whether or not the method is itself declared `async`). `@Inject weak var` on actors works the same way at the use site; under the hood the build plugin synthesises a setter extension method (`_wireSet<Property>`) because direct property assignment from outside actor isolation isn't legal Swift.

Member-injection parameters still participate in graph validation: missing-binding diagnostics fire if a target isn't bound, and explicit-key disambiguation works the same way it does for constructor-injected deps. The only difference is cycle detection — member-injection edges are deferred, so a cycle that closes through one is legal (the canonical cycle-breaking case), while cycles entirely through constructor edges remain errors.

`@Inject mutating func` on a struct is rejected with a build-time error pointing at the func declaration: struct value-copy semantics mean consumers that received the struct via init would see the pre-mutation state, while only the graph-stored value would reflect the mutation — a silent divergence Wire refuses to emit. Three fix-it suggestions point at the alternatives: convert to a class, drop `mutating` and manage shared state through an internal reference (Mutex-wrapped, etc.), or deliver the dep via `@Inject init` instead.

### Crossing scopes

The common case for "a singleton needs request-scoped state" collapses if you scope the consumer to the seed instead. A `TaskController` that wants per-request logging is naturally `@Scoped(seed: HTTPRequest.self)`, not a singleton with a deferred-resolution wrapper. A scoped controller becomes an app-scoped contributor whose generated registration enters the scope per request, constructing only its own transitive request-scoped subgraph — so the controller goes in the request scope, the singleton stays in the process scope, and the boundary is never crossed at injection time.

When a singleton genuinely needs to *defer* construction of something within its own scope (an expensive resource not always exercised, a first-use-init pattern), the user writes a `@Provides` that returns `Lazy<T>`. `Lazy<T>` is a regular public Swift type Wire ships; consumers `@Inject` it as `Lazy<T>` and call `.get()` to materialise. There's no framework-magic recognition — the binding's type *is* `Lazy<T>`, and the user controls the factory closure:

```swift
@Provides
static func makePool(config: Config) -> Lazy<DatabasePool> {
    Lazy { DatabasePool(config: config) }
}

@Singleton
struct RequestHandler {
    @Inject var pool: Lazy<DatabasePool>
}
```

Bootstrap allocates the wrapper (cheap); the underlying `DatabasePool` materialises on first `pool.get()`, cached thereafter. For mutual-reference cycles where one side should genuinely not extend the other's lifetime, see the [post-construction injection](#post-construction-injection) section above — `@Inject weak var` is the cycle-break primitive, not `Lazy<T>` (whose edge participates in cycle detection like any other dep).

`Lazy<T>` and `@Inject weak var` aren't mutually exclusive — `@Inject weak var pool: Lazy<DatabasePool>?` is a legal injection point. The graph identity is `Lazy<DatabasePool>` (same as for any other `@Inject weak var`), and the producer side stays a regular `@Provides -> Lazy<DatabasePool>`. The weak slot points at the wrapper (held strongly by the graph), not at the materialised inner value (held by the wrapper's factory closure once `.get()` runs and by anything that retains the result). The framework doesn't special-case the composition — `Lazy<T>` is just a type and `weak` is just a language modifier, so combining them is the same code path as either alone. Useful when a deferred binding's factory closure captures the consumer back and you want the consumer's view of it to be non-owning; less common than the basic shapes but available when needed.

A general `Provider<T>` for cross-scope on-demand resolution is deferred; if a real case surfaces that neither seeded scopes, `Lazy<T>`, nor the post-construction injection forms handle, the design lands then.

### Adapter annotations (the extension mechanism)

The Wire core defines exactly: scope macros (`@Singleton`, `@Scoped`), `@Inject`, `@Bind`, `@Provides`, `@Container`, `@GraphInputs`, `@Contributes`, `@Factory`, `@Teardown`, `@Replaces`, `@TestScopable`, `Lazy<T>`, and the key types (`BindingKey<T>`, `CollectedKey<T>`, `MappedKey<K, V>`, `BuilderKey<B>`, `FactoryKey`). Everything else — every framework integration — is an *adapter annotation*: a macro published by an adapter package that the build plugin recognizes and acts on.

**An adapter annotation does not emit registration code.** It declares a **capability** — one edge Wire adds to the graph around the declaration the attribute sits on. Wire performs the edge; the adapter's own macro performs the framework work, in its own expansion, where Wire never looks. That split is the whole contract, and it is why adding `WireMVC` requires no change to Wire core: the core learns that a binding gained a contribution or a dependency, never that the thing is a route.

An adapter publishes one declaration per annotation:

```swift
public let wireMVCControllerAlias = WireAdapterAnnotationV1(
    annotation: "Controller",                       // the attribute spelling, without `@`
    capability: .contributesProxy(
        to: WireMVCKeys.routeContributors,          // a key the adapter owns
        proxyTypePrefix: "_WireRouteContributor_",
        proxyScope: .singleton
    )
)
```

Wire reads this **syntactically**, exactly as it reads a `BindingKey` declaration — the plugin parses the source and never runs it, so the key argument is captured as written text, not as a runtime value. Nothing registers itself, and there is no initializer to order.

#### The capability axis

Every capability is domain-free. Each names *what edge* the annotation synthesises, never what the value means.

| Capability | The edge | Shipped users |
|---|---|---|
| `.contributes(to: key)` | **Output.** The binding flows into `key`'s aggregate — the annotation aliases `@Contributes(to: key)`. | `@HummingbirdController`, `@HummingbirdService`, `@BackgroundService` |
| `.contributesProxy(to:…)` | **Output, one generated proxy per subject.** The proxy — not the binding — collates, so the annotated type stays an ordinary, footgun-free value. At `proxyScope` the proxy either *holds* the subject or *bridges* into its narrower scope. | `@Controller` |
| `.contributesAggregateProxy(to:…, groupedByAttribute:)` | **Output, one proxy over many subjects**, partitioned by a use-site argument. For a framework demanding a single conformer where the user has several types. | `@OpenAPIController` (grouped by `spec:`) |
| `.liftsPeersToProxy(…)` | A proxy synthesised and addressable, contributing to **no** key — the adapter's codegen emits onto it. | `@WireMVCBootstrap` |
| `.injectsFromGraph` | **Input.** `@X(argument)` makes the binding depend on a graph value named by the argument, dispatching on its kind: a `FactoryKey` injects a synthesised factory, a `BindingKey<T>` a keyed binding, `T.self` a binding by type. | `@Middleware`, `@RequestBinding`, `@Coding` |
| `.mapsFactoryRoles(roles:)` | Supplies the ordered role names for a `@Factory` template's assisted generic parameters. Wire reads them as opaque identifiers. | `@MiddlewareFactory` |
| `.rewritesInjection(provider:selector:)` | The annotated *injection point* stops resolving by its own type and resolves instead to a binding Wire synthesises, which reads the value out of a provider the graph supplies. | `@ConfigProperty` |

`.rewritesInjection` is the clearest illustration of how little Wire is told. For a site of type `T` annotated `@X(a, b)` it emits `try X<T>.wireValue(from: <provider>, a, b)` — copying the annotation's argument list **verbatim**. It never learns what a key is, which method reads it, or that a "default" or a "secret" is a thing. Adding a type is adding an overload in the adapter, not a case in Wire.

#### Where the attribute attaches

Independently of the capability, an annotation attaches in one of three places — all supported, and the contract had to support all three from day one because retrofitting the third would break every adapter written against the first two:

- **Type-level.** `@OpenAPIController` on a type conforming to a generated `APIProtocol`.
- **Type-level with member recognition.** `@Controller` on the type, with `@Get` / `@Post` / `@Path` / `@JSONResponse` on its members and parameters. Wire's scan never matches the member annotations — they are the adapter's private vocabulary — so the DI core stays ignorant of routing while the adapter's plugin walks the same source.
- **Member- or parameter-level.** `@Middleware` on a property, `@ConfigProperty` on an `@Inject` property or an `@Inject init` parameter. (`@Path` on a handler parameter is *not* an example: it declares no capability, so Wire never sees it at all — it belongs to the private vocabulary above.)

A `WireMVC` controller — the canonical type-level-with-member-recognition case — looks like this:

```swift
@Singleton
@Controller("/todos")
@Middleware(ControllerMiddleware.logRequests)
@ErrorResponse(TodoNotFound.self, .notFound)
public struct TodosController<Repository: TodoRepository>: Sendable {
    @Inject var repository: Repository

    @Get("/{id}")
    @JSONResponse
    public func get(@Path id: String) async throws -> Todo {
        guard let todo = try await repository.find(id: id) else { throw TodoNotFound() }
        return todo
    }

    @Post
    @JSONResponse(status: .created)
    public func create(@JSONBody input: CreateTodo) async throws -> Todo {
        try await repository.create(input)
    }
}
```

Wire sees one thing here: `@Controller` contributes a generated proxy into `WireMVCKeys.routeContributors`, and `@Middleware` gives that proxy a dependency on a factory. Everything else — the verbs, the paths, the parameter decoding, the response encoding, the error mapping — is WireMVC's build plugin reading its own annotations. The same controller can be written spec-first against an OpenAPI document instead; since M6d both kinds of route contribute to the *same* key, so an app mixes them per controller and expresses middleware, error mapping and request scope identically across both.

The annotations adapter packages publish today. Only some of them declare a capability — the rest are each adapter's private vocabulary, invisible to Wire, which is the point of the split above:

- `@Controller`, `@Get`/`@Post`/`@Patch`/`@Delete`/`@Put`, `@Path`/`@Query`/`@Header`/`@JSONBody`, `@JSONResponse`, `@Middleware`, `@ErrorResponse`, `@RawRoute`, `@WireMVCBootstrap` — **WireMVC**, declarative cross-runtime routing.
- `@OpenAPIController`, `@Operation` — **WireOpenAPI**, the spec-first path onto the same routing model.
- `@HummingbirdController`, `@HummingbirdService` — **WireHummingbird**, collating natively-written Hummingbird controllers and `Service`s.
- `@ConfigProperty(forKey:default:)` — **WireConfiguration**, over swift-configuration.

Anyone can write one, and the reason to believe that is that the last three capabilities in the table were each added by an adapter's need without Wire learning that adapter's domain — middleware, request bindings, configuration. A third-party `@Secret`, `@FeatureFlag` or `@Clock` is `.rewritesInjection` with a different provider — no swift-wire change, no table to extend.

#### How the contract works

Three pieces:

**1. The adapter declares its annotation, owns its key, and ships a facade.** The key is an ordinary multibinding key (`WireMVCKeys.routeContributors = CollectedKey<any RouteContributor>`); the facade consumes the key's product and applies it to a framework object — a router, a transport — that stays *outside* the graph.

**2. The consumer activates the adapter by depending on it.** The build plugin re-parses the sources of each Wire-aware library the target directly depends on, and finds the `WireAdapterAnnotationV1` declarations there. Discovery is *name-agnostic*: the module defining the annotation is usually not the module using it. (Re-parsing is the M1 mechanism; M7a replaces it with per-library manifests when it becomes a build-time cost. Nothing about the contract changes with it.)

**3. The plugin synthesises the declared edge and everything else is ordinary machinery.** A `.contributes` annotation becomes a synthetic `@Contributes(to: key)` that flows through the same multibinding fan-in a hand-written one uses. An `.injectsFromGraph` annotation appends a dependency the adapter's macro accepts through a generated init. **There is no bespoke emission and no adapter-specific phase.**

The separation is strong: **adapters own their semantics, Wire core owns the graph.** Validation is structural — an unbound dependency is a compile error pointing at the adapter annotation that asked for it, and a key with no contributors yields an empty aggregate rather than a missing member.

Type expressions extracted from annotation arguments are normalised — interior whitespace collapsed — before binding lookup, so `Router<X, Y>` and `Router<X,Y>` resolve to the same binding regardless of how the source was formatted (M0 finding from Spike 3).

#### Collation, not registration

This is the decision the contract turns on, and it replaced an earlier design worth naming because the earlier one is the obvious one.

The first model made an adapter a **post-construction sink**: the annotation's macro generated a `_wireRegister(instance:router:)` member and Wire called it after the graph was built, to register the instance *into* a graph-bound collaborator. It worked, and it cost: the router had to be a binding, which meant a consumer of the *mutated* router had to be ordered after registration, which meant a phase taxonomy, which meant a contract that had to version its phases. It also needed a bespoke dead-binding exemption, since a registered subject that nothing injected looked unused.

Collation inverts it. The framework object leaves the graph; the annotation aliases `@Contributes`; the contributor flows through machinery that already existed. Nothing in the graph consumes a mutated collaborator, so there is no ordering problem, no phase, and no exemption — the contribution *is* the consumption edge. `_wireRegister`, `AdapterResolution`, the phase taxonomy and the register-signature field all retired with it in M2.3.

#### Reading the graph without naming it

A facade needs the collated products but must not name the generated `_WireGraph` type, which is internal to the consumer. So an adapter declares a conformance instead:

```swift
public let conformance = WireGraphConformanceV1(
    conformsTo: (any HummingbirdComposable).self,
    members: [.init("routes", from: HummingbirdKeys.routes)]
)
```

Wire emits `extension _WireGraph: HummingbirdComposable { … }`, mapping each member to its key's aggregate, and infers the protocol's associated types from the witnesses. The facade then takes `some HummingbirdComposable`. Wire still knows nothing about what the protocol means. Every generated graph also conforms to a core `Introspectable`, so an introspection endpoint takes `some Introspectable` for the same reason.

#### Contract versioning

The contract is **versioned by type name**: a shape change ships `WireAdapterAnnotationV2` (or `WireGraphConformanceV2`) and the build plugin recognizes each version by its type, so adapters written against V1 keep working with no shim to maintain. Adding a *capability* is not a version bump at all — the enum grows a case, and an adapter that does not use it is unaffected.

Where a case's own shape might need to grow, the payload is a struct rather than an enum for the same reason: `WireProviderSelector` is a struct with a static factory, so a second selector form can be added later without breaking an exhaustive `switch` in an adapter that inspects one.

#### Public API vs. SPI

The contract distinguishes two stability tiers:

- **Public API** (stable; a breaking change requires a major version of Wire): `WireAdapterAnnotationV1` and `WireAdapterCapability`, `WireGraphConformanceV1`, the key types (`BindingKey`, `CollectedKey`, `MappedKey`, `BuilderKey`, `FactoryKey`), the `Introspectable` protocol and introspection types (`WiringModel`, `BindingInfo`, `DependencyEdge`, `BindingKind`), the `@Teardown` annotation, the `_WireExports.swift` activation marker, and the build-time graph JSON format.
- **SPI** (adapter authors only; can evolve within a major version): the names and internal shape of generated proxies, the generated bootstrap structure, build-plugin internals, and the scope-entry types an adapter's codegen reads.

Adapter authors building against public API are insulated from Wire's internal evolution.

### The entry point

You don't write `@main`. A composition root carrying `@WireMVCBootstrap` is a graph binding like any other, and WireMVC's build plugin generates the program entry point from it.

```swift
@Singleton
@WireMVCBootstrap
@Middleware(GlobalMiddleware.cors)              // global: every route and the fallback alike
struct AppBootstrap {
    @Inject let config: ServerConfig

    /// Optional pre-step. Runs *before* the graph exists; its return value is the graph's inputs
    /// (or `Void`, to run it for its effects alone).
    static func prepare() throws -> AppInputs {
        let config = ConfigReader(providers: [EnvironmentVariablesProvider()])
        LoggingSystem.bootstrap { StreamLogHandler.standardOutput(label: $0) }
        return AppInputs(config: config)
    }

    func createServer() throws -> NIOHTTPServer { ... }
    func createRouteBuilder<Server: HTTPServer>(for server: borrowing Server) -> some ... { ... }

    /// Optional: mount `introspect()` as JSON. Returning `nil` skips it.
    func mountIntrospectionAt() -> String? { "/wiring" }

    /// Optional: the app's own fallback. Without one the plugin synthesises a plain 404.
    @NotFound @RawRoute
    func noRoute<Sender: HTTPResponseSender & ~Copyable>(
        request: HTTPRequest, responseSender: consuming sending Sender
    ) async throws where Sender.Writer: ~Copyable { ... }
}
```

The two `create…` factories are the only required members, and they are what makes this a *composition root* rather than a config struct: the concrete server and route builder are the app's choice, so they are written by the app and constructed with the graph's own dependencies. `createServer()` returns the concrete server type rather than `some HTTPServer` — the proposal's `Reader` and `ResponseSender` are `~Copyable`, which a bare opaque return cannot express.

**What the generated entry point does**, in order — worth reading once, because everything below is a consequence of it:

1. Calls `prepare()` if present, and passes its result to `Wire.bootstrap(inputs:)`.
2. Reads the composition root off the graph, and asks it for the server and the route builder.
3. `WireMVC.apply(graph, to: &builder)` — registers every collated route contributor and returns the graph's collated `ServiceLifecycle` services.
4. Mounts introspection if `mountIntrospectionAt()` returned a path.
5. Registers the `@NotFound` fallback (or a synthesised 404) and a `405` handler, *before* finalizing — so both are real routes inside the router, which is what lets the global middleware and error tiers fold into them.
6. `finalize()`s the builder into an immutable router, wraps it once in the global `@Middleware` layer, and serves it alongside the services.

Step 5 is the one worth pausing on. A fallback is the response nobody declares, and therefore the easiest place to lose the header fields a global middleware contributed; registering it as a route rather than as a special case is what stops that being a per-app mistake.

#### The pre-graph step

`prepare()` exists for the work that has to happen before any binding is constructed, and it is the only place that work can go. Two things need it:

- **`LoggingSystem.bootstrap`.** It traps on a second call, and the unbound default logger is captured at first access — so bootstrapping *after* the graph is built leaves every binding constructed so far holding a logger that ignores the configuration.
- **Building the `ConfigReader`** the graph shares, which is then handed in as a graph input.

Being pre-graph, `prepare()` can inject nothing. That is the trade for running first, and it is why it reads the environment directly there and nowhere else. Its return type is a `@GraphInputs` struct — values supplied to the graph rather than produced by it:

```swift
@GraphInputs
struct AppInputs: Sendable {
    let config: ConfigReader
}
```

Inputs are the *consumer's* to supply: a library cannot decide what its consumers must pass in, which is why `@GraphInputs` is declared in the app rather than by an adapter.

#### The explicit form

`@WireMVCBootstrap` generates the entry point for a WireMVC app. An app that isn't one — a Tier-1 Hummingbird app that writes its own routes, or a non-HTTP program — bootstraps the graph itself and mounts it through the adapter's facade:

```swift
let graph = try await Wire.bootstrap()
let services = WireHummingbird.apply(graph, to: router)
```

Two lines, and the second is the adapter's. The framework object — the router — stays outside the graph and is the app's to construct and to serve, which is the same property [collation](#collation-not-registration) buys everywhere else. Nothing about the graph differs between the two forms; the generated entry point is a convenience over exactly this, not a different mechanism.

#### Selecting a container, and entering from a test

`Wire.bootstrap()` builds the default graph. A named `@Container` gets its own generated bootstrap — `@Container enum TestContainer` yields `Wire.bootstrapTestContainer()` — and calling that one instead is the whole swap for that run. See [`@Provides` (and optionally `@Container`)](#provides-and-optionally-container) below. Container selection is a property of the **explicit** form: the generated `@main` bootstraps the default graph, because a program's entry point has nobody to ask which container to use.

Tests do not need one anyway. For a test consumer the plugin generates a suite-trait factory rather than a `@main`, so a test target re-composes the *same* composition root while the harness owns serving, the port and cancellation — build-without-serve, with no override machinery. Substitution happens through `@Replaces` (a test target's binding supersedes a sibling module's for the same key) or through per-request doubles, rather than by selecting a parallel graph. That is the same app entered differently, which is a property a container swap cannot offer.

#### What the generated entry point does not do

**App-scope `@Teardown` actions do not run on this path.** The generated `@main` serves and exits; it does not call the graph's `teardown()`. Request-scope teardown *does* run — it is emitted per route and fires when the request scope ends — and the Tier-1 path runs app-scope teardown through WireHummingbird's `teardownService`. So an app with a `@Teardown`-annotated `AWSClient` gets orderly shutdown under WireHummingbird and process-exit cleanup under `@WireMVCBootstrap`. Closing that is tracked in [ROADMAP.md](ROADMAP.md) and written up — with what actually blocks it and the upstream asks that would unblock it — in [PendingIssues/19](PendingIssues/19-app-scope-teardown-no-shutdown-trigger.md); until it is, an app that needs deterministic app-scope shutdown should use the explicit form.

### `@Provides` (and optionally `@Container`)

`@Provides` declares a binding for the dependency graph. It attaches to either a property or a function — pick whichever Swift construct fits. A property contributes a value with no dependencies; a function's parameters become its dependencies.

You only declare `@Provides` for things the graph can't construct on its own — framework primitives (a `Logger`, a config object), values produced by external systems, or concrete instances pinning a specific type for a generic constraint. Every `@Singleton` / `@Scoped(...)` type is automatically part of the graph and constructed by the build plugin without an explicit `@Provides`.

In the common case, `@Provides` declarations live at module scope and that's the entire graph:

```swift
@Provides let logger = Logger(label: "TaskCluster")
@Provides let table = InMemoryDynamoDBCompositePrimaryKeyTable()

@Provides
func repository(table: InMemoryDynamoDBCompositePrimaryKeyTable)
    -> DynamoDBTaskRepository<InMemoryDynamoDBCompositePrimaryKeyTable>
{
    DynamoDBTaskRepository(table: table)
}
```

The build plugin aggregates every `@Provides` in the executable target into one graph. Most apps don't need anything more.

`@Container` is opt-in. It groups a set of bindings under a named type — useful in larger codebases for documenting which subsystem owns which bindings, and for swapping graphs at the entry point:

```swift
@Container
enum TestContainer {
    @Provides static let logger = Logger(label: "test")
    @Provides static let repository: any TaskRepository = MockTaskRepository()
    // ... other bindings the test graph needs
}

// Entry point for that graph — one generated bootstrap per container:
let graph = try await Wire.bootstrapTestContainer()
```

When a `@Container` is selected at the entry point, that container's bindings *are* the graph for that run; module-scope `@Provides` aren't merged in. This keeps the swap atomic and avoids inheriting override semantics from day one.

Containers are flat — no parents, no children. Multiple `@Container`s in the same target merge their bindings; a collision between them is a compile error.

A binding that starts as a plain value and later needs computation just gains parameters and a body — the annotation stays. No migration between annotations as the graph evolves.

### Resolution and disambiguation

Bindings are looked up by type first, by key second. The rules:

1. **One binding matches the type** → bound automatically. No key needed at the injection site.
2. **Multiple bindings match** → compile error naming the candidates. The user disambiguates with an explicit key.
3. **No binding matches** → compile error pointing at the unsatisfied dependency.

Every `@Singleton` / `@Scoped(...)` macro auto-generates a `static let key: BindingKey<Self>` on the type. The build plugin uses these keys to identify bindings; users only ever *read* keys, and only when an ambiguity forces them to. In the common case, nothing in the user's code mentions a key.

When an ambiguity does arise — say, a second `TaskRepository` implementation lands in the graph:

```swift
@Singleton
package struct InMemoryTaskRepository: TaskRepository { ... }

// Build plugin error at TaskController:
//   error: ambiguous binding for `Repository` matching `TaskRepository`
//   candidates:
//     - DynamoDBTaskRepository<...>.key   (Sources/.../DynamoDBTaskRepository.swift:9)
//     - InMemoryTaskRepository.key        (Sources/.../InMemoryTaskRepository.swift:3)
//   fix: write `@Inject(DynamoDBTaskRepository.key) var repository: Repository`
```

The fix is mechanical — the diagnostic names the candidates and the user pastes one of the keys at the injection site. The rule extends to ambiguity on a generic type parameter (as with `TaskController<Repository: TaskRepository>`): the key selects which binding specializes the enclosing type.

There is no automatic disambiguation. No "most specific match," no declaration-order tie-breaker. If two bindings could satisfy a request, you write the key. The reason: every silent inference rule eventually surprises someone, and the cost of forcing a key is one annotation at the place the ambiguity actually exists.

#### Named keys for same-type-different-role

Auto-generated keys are tied to the providing type, which doesn't help when you have two values of the same concrete type configured differently — a primary and replica DB, two HTTP clients with different timeouts. Declare a `BindingKey` explicitly and reference it on both sides:

```swift
extension Database {
    static let primary = BindingKey<any Database>("primary")
    static let replica = BindingKey<any Database>("replica")
}

@Provides(Database.primary)
static func primary() -> some Database { ... }

@Provides(Database.replica)
static func replica() -> some Database { ... }

@Singleton
struct UserService {
    @Inject(Database.primary) var db: any Database
}
```

#### The cost of preserved generics, restated

Swift specializes generics; it doesn't erase them. With explicit-key disambiguation, the only verbosity Wire forces into user code is one `@Inject(Foo.key)` per ambiguous injection. In the unambiguous common case nothing in user code mentions a key, and concrete types appear only at the binding declaration. That's the win the strict-on-ambiguity rule is buying.

### Multibindings (`CollectedKey<T>`)

Some bindings are naturally one-of-many rather than one-and-only-one — Hummingbird's `[any Service]` for the application's lifecycle, a list of middleware, a collection of health checks. Wire handles these with a second key flavor:

```swift
public struct CollectedKey<Element>: Sendable { ... }
```

Multibindings are explicit and keyed; there is no anonymous "collect everything that conforms to `T`" sweep. To opt a type into a collection, add `@Contributes(to: SomeCollectedKey)` alongside its scope macro:

```swift
extension Service {
    static let lifecycle = CollectedKey<any Service>("lifecycle")
}

@Singleton @Contributes(to: Service.lifecycle)
struct QueueConsumer: Service { ... }

@Singleton @Contributes(to: Service.lifecycle)
struct MetricsEmitter: Service { ... }

@Singleton
struct ApplicationBuilder {
    @Inject(Service.lifecycle) var services: [any Service]
}
```

`@Contributes(to:)` is to `CollectedKey<T>` what `@Provides(_:)` is to `BindingKey<T>` — the declaration annotation for that key flavor. They're separate annotations specifically so the call site tells you which kind of binding you're looking at without having to look up the key's declaration:

- `@Provides(Database.primary)` — single-binding key; exactly one provider expected, multiple is a compile error.
- `@Contributes(to: Service.lifecycle)` — collection key; multiple contributors expected, the consumer's `[T]`-typed injection point gets all of them.

A consumer asking for `[any Service]` *without* specifying a key gets a literal-list lookup, not the collection. The two cases are different lookup paths and can coexist:

```swift
@Provides let coreServices: [any Service] = [a, b, c]   // literal, single binding

@Inject var services: [any Service]                     // → the literal list
@Inject(Service.lifecycle) var services: [any Service]  // → collected from contributors
```

#### Multiple keys per declaration

A `@Singleton` (or `@Provides` function) can carry more than one `@Contributes(to:)` annotation, or mix `@Provides(Key)` and `@Contributes(to:)`. The same instance is registered under each key, with the type system enforcing that each key's element type matches what's provided:

```swift
@Singleton
@Contributes(to: Service.lifecycle)         // started by Hummingbird
@Contributes(to: Healthcheck.allChecks)     // queried by /health
struct DatabaseHealthService: Service, Healthcheck { ... }
```

A common mixed case is a type that's both a unique singleton and a contributor to one or more collections:

```swift
@Singleton
@Provides(Database.primary)                 // unique — the canonical primary DB
@Contributes(to: Database.allConnections)   // also part of the connection-pool collection
struct PrimaryDatabase: Database { ... }
```

The instance is constructed once (singleton lifetime applies once across all keys); every lookup that resolves any of its keys gets that same instance. For `@Provides` functions with multiple key annotations, the function is invoked at most once per resolution and the result is registered under each key.

#### Ordering contributions

When the order of contributors matters — service startup is the canonical case — add `withOrder:` to the contribution. Lower numbers come first; contributions without `withOrder:` are appended after the ordered ones, in declaration order:

```swift
@Singleton @Contributes(to: Service.lifecycle, withOrder: 10)
struct MetricsEmitter: Service { ... }      // starts first

@Singleton @Contributes(to: Service.lifecycle, withOrder: 20)
struct QueueConsumer: Service { ... }       // starts after metrics

@Singleton @Contributes(to: Service.lifecycle)
struct PrometheusScraper: Service { ... }   // unspecified — appended after ordered contributors
```

Convention: leave integer gaps (10, 20, 30) so future contributors can insert without renumbering. The build plugin sorts ascending by `withOrder`, with declaration order as the tiebreaker for unspecified contributors.

Relative ordering (`before:` / `after:` references to other types) is not in scope. Topological sort over relative-order constraints introduces cycle-detection and diagnostic concerns that integer priority avoids; if a real case turns up that integers can't express, it'll be added then.

#### Map-shaped collections (`MappedKey<K, V>`)

When the collection is keyed by string, enum, or other discriminator — strategies-by-name, routes-by-prefix, formatters-by-content-type — declare a `MappedKey<K, V>` and contribute under per-entry keys with `atKey:`:

```swift
public struct MappedKey<Key: Hashable, Value>: Sendable { ... }

extension Strategy {
    static let byName = MappedKey<String, any Strategy>("byName")
}

@Singleton @Contributes(to: Strategy.byName, atKey: "fast")
struct FastStrategy: Strategy { ... }

@Singleton @Contributes(to: Strategy.byName, atKey: "thorough")
struct ThoroughStrategy: Strategy { ... }

@Singleton
struct StrategyDispatcher {
    @Inject(Strategy.byName) var strategies: [String: any Strategy]
}
```

Two contributors writing `atKey:` with the same key value is a compile error — same strict-on-ambiguity stance as `BindingKey`. The build plugin enforces parameter validity per key flavor: `withOrder:` is only meaningful for `CollectedKey`, `atKey:` is required for `MappedKey`, mixing them on the same contribution is an error.

#### Builder-shaped aggregations (`BuilderKey<B>`)

When the natural aggregation isn't a list or a map but a typed *composition* — type-preserving middleware chains (the pattern explored in the Swift HTTP server proposal), pipeline stages, or any case where each addition transforms the type signature of the result — declare a `BuilderKey<B>` whose type parameter is the builder:

```swift
public struct BuilderKey<Builder>: Sendable where Builder: ~Copyable {
    // Builder is a user-defined @resultBuilder type; its methods
    // determine both the constraints on contributors and the
    // aggregated output type.
}

extension Middleware {
    static let chain = BuilderKey<MiddlewareBuilder>("chain")
}

@Singleton @Contributes(to: Middleware.chain, withOrder: 10)
struct LogRequests: MiddlewareProtocol { ... }

@Singleton @Contributes(to: Middleware.chain, withOrder: 20)
struct Compression: MiddlewareProtocol { ... }

@Singleton
struct ApplicationBuilder {
    @Inject(Middleware.chain) var middleware: some MiddlewareProtocol
    // Concrete type at runtime: _Middleware2<LogRequests, Compression>
}
```

The build plugin orders contributors by `withOrder:`, then emits a fold function annotated with the builder's `@resultBuilder` attribute. The Swift compiler dispatches whichever builder methods the user defined (`buildBlock`, `buildPartialBlock`, `buildFinalResult`, etc.) — Wire stays out of the builder's internal protocol and emits no API-specific code. The result is a fully specialized aggregate — `_Middleware2<LogRequests, Compression>` here — with no existential boxing forced by Wire. The consumer reads it via an opaque type (`some MiddlewareProtocol`) since the concrete aggregation depends on which contributors are activated.

The builder's own where-clauses become DI constraints. If the user's builder requires matching `Input`/`Output`/`Context` across the chain, contributing a middleware with mismatched generic parameters is a compile error from the *builder's* signature, not from Wire's logic. Wire doesn't reinvent the constraint system; it threads contributors through the builder the user already wrote.

#### One annotation, four key flavors

The four key flavors form a clean progression by aggregation strategy:

- `BindingKey<T>` — single value, no aggregation
- `CollectedKey<T>` — flat collection (`[T]`)
- `MappedKey<K, V>` — keyed collection (`[K: V]`)
- `BuilderKey<B>` — result-builder aggregation, fully type-preserving

`@Contributes(to:)` is the universal contribution annotation across all four. The key's type determines what the build plugin does at the aggregation site; from the user's perspective, the contribution site looks identical regardless of key flavor.

#### Why the explicit opt-in matters

Spring's "any `List<T>` is autowired" looks convenient and is the source of the most-cited DI surprise in production: someone adds a new type that happens to conform to a marker protocol and silently joins every collection consumer for that protocol. Wire's contributor-side opt-in makes this impossible — adding `@Singleton struct X: Service` does not put `X` into any collection. To join, the contributor must explicitly write `@Contributes(to: Service.lifecycle)`, which is a deliberate annotation referencing a specific key. Refactoring conformances doesn't silently break collections; the compiler enforces that the contribution element type matches the key.

#### Open for later

- **Empty collections.** Zero contributors resolves to `[]` (or `[:]` for a map), with a build-plugin warning. Silenceable when zero is genuinely valid.
- **Relative ordering.** As noted above, `before:` / `after:` constraints aren't in scope. Defer until integer priority demonstrably can't express a real case.

### Lifecycle and teardown (`@Teardown`)

Async/throwing initialization is handled by the constructor — Swift's `init(...) async throws` covers it directly:

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

The macro propagates `await` and `try` through the resolution chain, which is why the bootstrap is `try await Wire.bootstrap()` (and why the generated entry point's `main()` is `async throws`). There is no `@PostConstruct`-style separate init step — Swift constructors don't need one.

Teardown is the asymmetric case (Swift has no async `deinit`). Rather than a framework-recognised protocol or a wrapper type the framework knows to unwrap, Wire marks teardown **explicitly at the binding's declaration** with `@Teardown`. There is no `Lifecycle` protocol and no `Resource<T>` — nothing for the framework to discover by a conformance probe. The graph already knows construction order; `@Teardown` just annotates which nodes have a teardown action and what it is. Two forms, for the two cases:

**Owned types — mark the teardown method:**

```swift
@Singleton
struct DatabasePool {
    let client: PostgresClient

    @Inject
    init(url: String) async throws {
        self.client = try await PostgresClient.connect(to: url)
    }

    @Teardown
    func teardown() async throws {
        try await client.shutdown()
    }
}
```

The method may be named anything and takes no parameters, but it must be at least `internal` — Wire's generated bootstrap calls it at scope teardown from a separate file, the same post-construct visibility rule as `@Inject func`. Wire reads its effect specifiers (`async`/`throws`) off the declaration, so the generated teardown call gets the right colour.

**Third-party or produced values — attach the action to the `@Provides`:**

```swift
@Provides
@Teardown({ (client: HTTPClient) in try await client.shutdown() })
static func httpClient() -> HTTPClient {
    HTTPClient()
}
```

The producer's return type stays the honest `HTTPClient`, so consumers `@Inject var client: HTTPClient` directly — no wrapper, no unwrap step. The teardown action is either an explicit-typed closure (as above) or a reference to a free or static function (`@Teardown(shutdownClient)`); a sync, non-throwing action is fine — it coerces into the `async throws` teardown contract. (Swift attributes take no trailing-closure sugar, so the closure is parenthesised: `@Teardown({ … })`, not `@Teardown { … }`. The closure parameter needs an explicit type — `$0`-inference doesn't reach across the attribute.)

Why explicit annotation over retroactive `Lifecycle` conformance: a recognised conformance is still framework magic (the container probes `as? Lifecycle` at runtime), it can't distinguish two bindings of the same type with different teardown needs, and it pushes a per-binding decision off the declaration and into the type system. `@Teardown` keeps teardown local, per-binding, and statically known — consistent with Wire treating `Lazy<T>` as just a type and refusing dynamic `Any.Type` lookup.

#### Scope semantics

Each scope has a teardown phase. `@Teardown`-annotated bindings within the scope are torn down in reverse dependency order — dependents before dependencies — so a `TaskRepository` that depends on `DatabasePool` tears down first, letting in-flight queries complete before the pool drains.

- **App-scope teardown** runs at shutdown, plumbed through `WireHummingbird` into swift-service-lifecycle's shutdown sequence. It happens *after* all `Service`s have stopped, so a `DatabasePool` is torn down only after the HTTP server has finished serving the last request. **This is the explicit entry point's path.** A `@WireMVCBootstrap` app does *not* run app-scope teardown today — see the note under [The entry point](#what-the-generated-entry-point-does-not-do).
- **Request-scope teardown** runs at end of request handling, including the cancelled case. A request-scoped `RequestTransaction` that auto-rollbacks on teardown if not committed is the canonical example.
- **Job-scope teardown** runs at end of job, same scope-guard semantics.

If a teardown action throws, the error is collected and logged; teardown continues with the next binding, and `teardown()` returns the collected errors. **Init-failure partial teardown** — if an init throws partway through bootstrap, tearing down the already-initialized teardown-annotated bindings in reverse before the bootstrap rethrows — is **not yet implemented** (see the status note below); a bootstrap init-failure currently leaves them for process exit to reclaim.

> **Status.** M1 shipped the `@Teardown` annotation (recognised and recorded, inert). **M4** emits the **app-scope** teardown walk: `teardown()` on the generated graph calls each action in reverse dependency order, collecting teardown-action failures. Every graph conforms to `Teardownable`, so any facade can drive it; the one that does today is WireHummingbird's `teardownService` (prepended so it shuts down last). **The generated `@WireMVCBootstrap` entry point does not call it** — the walk exists and nothing on that path invokes it, so a WireMVC app's app-scope teardown currently relies on process exit. **Request-/job-scope teardown** needs request scope and is **M5**. **Init-failure partial teardown** is deferred to **M7c** — its implementation is fixed by the construction scheduler that pass settles (a linear prefix today vs. resolved `AtomicState` cells under dynamic scheduling), so it lands there once rather than being rewritten, or earlier if a concrete adopter forces it; until then a bootstrap init-failure relies on process exit for cleanup.

#### Service vs teardown

Two distinct mechanisms for two distinct concerns:

- **`Service`** (from swift-service-lifecycle, contributed via `@Contributes(to: Service.lifecycle)`) — types with a `run()` loop that the service group orchestrates. HTTP server, queue consumer worker, scheduled task runner.
- **`@Teardown`** — a resource cleanup step (no main loop) marked on a `@Singleton`/`@Scoped` type's method or on a `@Provides`-produced value. `DatabasePool`, `HTTPClient`, JWT verifier, anything that's a *resource* rather than a *service*.

A type can have both if it has both responsibilities, but most are one or the other. The build plugin warns at compile time if a `@Singleton` conforms to `Service` but isn't contributed to a service collection (silent "service that's never run" is a common bug).

### Multi-module composition

Wire-aware library packages — `WireSQS`, `WireOpenAPI`, internal company packages shipping shared bindings — declare their `@Singleton`s, `@Provides`, and `@Contributes` like any other module, plus a one-line `_WireExports.swift` marker file that opts them into composition. A consumer **activates** such a library simply by **depending on it** in the consuming target — the dependency *is* the activation:

```swift
// In WireSQS package — opted into composition by shipping `_WireExports.swift`.
@Singleton
public struct SQSClient {
    @Inject public init(url: URL) async throws { ... }

    @Teardown
    public func teardown() async throws { ... }
}

// In task-cluster's Package.swift — depending on a Wire-aware library activates it.
.target(
    name: "TaskCluster",
    dependencies: [.product(name: "WireSQS", package: "wire-sqs")],
    plugins: [.plugin(name: "WireBuildPlugin", package: "swift-wire")]
)

// In task-cluster source — no activation directive; the dependency is the activation.
@Singleton
struct WorkerService: Service {
    @Inject var sqs: SQSClient                    // resolves to WireSQS.SQSClient
}
```

**Why the dependency, not a call-site directive.** Activation is a *compile-time* fact: the build plugin must know the activated set before it generates anything, so it can validate the whole graph and collate multibindings at build time (the plugin emits exactly one `_WireGraph` per target — there is one activation set per target, not a per-bootstrap-call choice). The manifest dependency list is where that fact already lives, name-checked by SPM. Both halves of activation are explicit and visible: your `Package.swift` (which libraries you pulled in) and each library's `_WireExports.swift` (its opt-in to being composable). Nothing transitive or hidden activates — only the libraries you directly named.

Activation is **all-or-nothing per library**: an activated library contributes every one of its bindings — `@Singleton`s available for injection, `@Provides` available, `@Contributes` joining the relevant collections, adapter-annotated types collating into their adapters' keys. A library is a unit; depending on it takes all of it. This prevents the silent failure mode of partial activation — taking a library's `@Singleton` while its `@Contributes` partner is invisible, with the type system blessing a graph that's missing behavior the library was designed to provide as a coherent unit.

#### Same-package, external, and transitive

The rule is uniform: **you activate the Wire-aware libraries your target directly depends on.**

- **Same-package siblings** and **external packages** are treated identically — a direct dependency is a direct dependency, whether declared as a sibling `.target` or a `.product` from `.package(url:)`.
- **Transitive** dependencies (a dependency of a dependency, not in your target's own `dependencies`) are *not* auto-activated. To compose a transitive library's bindings you add it to your own `dependencies` — which you must do anyway to `import` and reference its types. So "transitive activation is explicit" falls out for free: only what you directly depend on is in scope, and your `Package.swift` is always a complete statement of what's activated.

The build plugin still detects *missing* transitive activations at compile time: if an activated `WireOpenAPI` references `Router<BasicRequestContext>` (a binding declared in `WireHummingbird`) and your target doesn't depend on `WireHummingbird`, that's a missing-binding diagnostic naming the library, with a fix-it suggesting you add the `WireHummingbird` dependency.

#### Cross-library validation

Within the activated set, validation is the same as in-target: every `@Inject` must be satisfied somewhere across the union of activated libraries plus the consumer's own bindings. If `WireSQS.SQSClient` needs a `URL` and the consumer hasn't bound one, the diagnostic names the library and the missing binding. If two activated libraries both bind `Cache`, the consumer disambiguates with a key. `@Contributes(to:)` collections union across activated libraries; a `CollectedKey<any Service>` declared anywhere collects contributors from the activated set. A binding referenced across a module boundary must be `public` (or `package` within a package) — the cross-module visibility threshold; the in-module floor stays `internal`.

> **Multibinding keys are global extension points.** If you `@Inject` a multibinding key you *don't* own — one published by a library — any other activated package may also contribute to it, so the collection you receive can grow just by adding a dependency. That's the intended plugin-registry behavior (and the `_WireGraph.json` dump records every contributor with its origin module, so it's auditable). But if you need to be confident about the *complete* set of contributors, **declare the key in a target you control** — most strongly your leaf app target, which nothing depends on, so only your own code can contribute to it. (For order-sensitive collections, also use `withOrder:` — cross-module element order is otherwise unspecified.)

#### How it works mechanically

The build plugin running on the consuming target enumerates its direct dependency targets via the SPM plugin context, then identifies Wire-aware libraries by the presence of a `_WireExports.swift` marker file in their sources — written manually in M1 (a one-line stub), generated by the library's own Wire build plugin in M7a. M0 confirmed that `PackagePlugin` doesn't expose plugin-usage information for dependency targets, so the marker file is the committed discovery mechanism rather than the SPM-context-inspection path that would otherwise be cleaner.

For each activated Wire-aware dependency, the plugin reads the library's source files (M1: re-parse; M7a: a compile-time manifest the library emits) and aggregates `@Singleton`/`@Provides`/`@Contributes` declarations and adapter-annotated types into **one merged graph** for validation and codegen. There is no runtime graph composition — the generated `_WireGraph` is a single flat graph spanning the consumer and its activated libraries, and Wire's "runtime is just stored properties" invariant holds across module boundaries exactly as within one module. Non-activated libraries are skipped entirely.

**Eager construction and the reachability optimization.** In M1 every binding in the merged graph is constructed at bootstrap — including a library binding nothing in the consumer reaches. That's correct but not free: a large library you depend on for a few bindings still constructs all its singletons. **M7b** adds compile-time **reachability pruning** — only bindings reachable from the home package's roots are constructed, the rest stripped before codegen — so depending on a library costs only what you use. Until then, an expensive library binding can opt into deferral with `Lazy<T>`.

#### Test-only substitution

A test target depends on the libraries it needs — typically a mix of production and test variants:

```swift
// In the test target's Package.swift dependencies:
.product(name: "WireMockSQS", package: "wire-mock-sqs"),   // mock instead of WireSQS
.product(name: "WireOpenAPI", package: "wire-openapi"),
```

The production library isn't depended on, so its bindings are absent from the test graph. If a test target depends on both `WireSQS` and `WireMockSQS`, that's a compile error from the strict-on-ambiguity rule (two libraries binding `SQSClient`); depend on only one, or disambiguate with keys.

### Concurrency and isolation

Wire respects Swift 6's isolation model rather than reinventing it. The compiler does the hard work of enforcing isolation correctness; Wire's job is to generate code that passes the checker without getting in the way.

#### The rules

1. **All bindings must be `Sendable`.** Singletons are shared across the process; scoped values cross `await` boundaries during request or job handling. The macro-generated `init(...)` from `@Inject` properties propagates Sendable requirements naturally — try to `@Inject` a non-Sendable type into a `@Singleton` and Swift rejects the generated init at compile time.

2. **Global actor isolation is honored, not reinvented.** Write `@MainActor @Singleton struct UICoordinator` and the macro reads the existing `@MainActor` attribute. Consumers of an isolated singleton from non-isolated contexts use Swift's standard `await` semantics. Wire doesn't introduce a parallel `isolation:` parameter — the language's existing mechanisms already type-check correctly.

3. **The `Resolver` protocol is `Sendable`-aware where it surfaces.** Most adapters never touch a resolver — an adapter declares a capability and Wire wires the edge, so nothing the adapter writes resolves anything (see *How the contract works*). Where the resolver does appear — `Lazy<T>` deferring construction within its own scope, or an explicit escape-hatch resolution — its surface is:

    ```swift
    public protocol Resolver: Sendable {
        func resolve<T: Sendable>(_ type: T.Type) async throws -> T
        func resolve<T: Sendable>(_ key: BindingKey<T>) async throws -> T
        func resolve<T: Sendable>(_ key: CollectedKey<T>) async throws -> [T]
        // ... map-shape and other variants
    }
    ```

   Global-actor types are Sendable (the actor provides isolation), so they pass through these methods naturally. Calling `resolve` from any isolation domain is fine; the await hops happen as needed at the call site.

4. **`Lazy<T>` inherits its Sendability from `T`.** A type injecting `Lazy<DatabasePool>` is Sendable iff `DatabasePool` is. `Lazy` defers construction within the same scope — the held value is constructed on first access using the scope's normal isolation rules, with no cross-scope hop.

#### Diagnostics

The classic Spring-style "inject a request-scoped non-Sendable thing into a singleton" failure becomes a Swift compile error — Wire's structural check (scoped types can't be stored on a wider scope) fires first with a fix-it ("scope `Foo` to `HTTPRequest`, or scope the consumer to the same seed"); the Sendable checker is a second line of defence for cases the structural check can't see (e.g., escape-hatch resolves). Wire emits a custom diagnostic to pre-empt the otherwise-confusing "synthesized init isn't Sendable" message: when a `@Singleton`-annotated type isn't `Sendable`, the build plugin reports "`@Singleton`-annotated types must conform to `Sendable`. Add `: Sendable` to the type or audit its stored properties."

#### What's deliberately deferred

- **Custom isolation domains as scope qualifiers.** "This dependency is on `MyJobActor`" is expressed as `@MyJobActor` on the type. Wire respects that without inventing a parallel `@Scoped(isolation:)` form.
- **Container-level isolation enforcement.** A `@Container(isolation: SomeActor.self)` that constrains every binding within to share an isolation domain is a plausible future direction — useful for single-threaded subsystems where coherent isolation is the architectural intent. Deferred until a concrete use case demonstrates Swift's per-type isolation isn't sufficient. Adding it post-1.0 is non-breaking; existing containers continue to work.
- **`~Copyable` types.** Singletons are shared by definition; non-copyable means single-owner. The semantics conflict; `~Copyable` types don't compose with `@Singleton`. Request- and job-scoped uses *might* work for single-consumer cases but require parallel `Resolver` overloads that haven't been designed. The ergonomic answer for now is to wrap a `~Copyable` resource in a Sendable reference type that manages scoped access internally — the same pattern Swift's standard library uses for `Mutex`. `~Copyable` injection stays out of scope through 0.x; reconsider post-1.0 if a real use case appears.

### Introspection

Wire surfaces the graph in two complementary forms — one at build time, one at runtime — for tooling, documentation, and operational diagnostics.

#### Build-time JSON dump

The build plugin emits a structured dump alongside `_WireGraph.swift` — call it `_WireGraph.json` — describing every binding in the graph, its source location, its dependencies, and the activation list. The format is part of the public API: tools depending on it get stability, with version bumps coordinated alongside the adapter-annotation contract version.

```json
{
  "wireVersion": 1,
  "executable": "TaskCluster",
  "activations": ["TaskClusterApp", "TaskClusterDynamoDBModel", "WireOpenAPI"],
  "bindings": [
    {
      "key": "BindingKey<Logger>",
      "type": "Logger",
      "kind": "provides",
      "scope": "singleton",
      "source": { "library": "TaskCluster", "file": "Sources/.../TaskCluster.swift", "line": 8 },
      "dependencies": []
    },
    {
      "key": "BindingKey<DynamoDBTaskRepository<InMemoryDynamoDBCompositePrimaryKeyTable>>",
      "type": "DynamoDBTaskRepository<InMemoryDynamoDBCompositePrimaryKeyTable>",
      "kind": "singleton",
      "scope": "singleton",
      "source": { "library": "TaskClusterDynamoDBModel", "file": "...", "line": 9 },
      "dependencies": [
        { "key": "BindingKey<InMemoryDynamoDBCompositePrimaryKeyTable>", "site": "@Inject var table" }
      ]
    }
  ],
  "collections": [
    { "key": "CollectedKey<any Service>", "name": "Service.lifecycle",
      "contributors": [{ "type": "WorkerService", "source": {...}, "order": null }] }
  ],
  "adapters": [
    { "annotation": "WireOpenAPI.RoutedBy",
      "type": "TaskController<DynamoDBTaskRepository<...>>",
      "phase": "post-graph",
      "parameters": [...] }
  ]
}
```

The dump enables IDE integrations ("jump to binding declaration"), documentation generators, CI checks ("did the graph change in this PR?"), and ad-hoc debugging ("where is `SQSClient` coming from?"). It costs a few KB of build output and zero runtime overhead.

#### Runtime introspection

The generated graph (returned by `Wire.bootstrap()`) exposes a read-only view of its own wiring, baked in at codegen — Wire is compile-time DI, so the wiring is fully known without runtime reflection:

```swift
extension _WireGraph {
    func introspect() -> WiringModel
}

public struct WiringModel: Sendable, Codable {
    public let bindings: [BindingInfo]   // in construction (topological) order
}

public struct BindingInfo: Sendable, Codable {
    public let type: String              // the bound type (graph identity)
    public let key: String?              // the binding key, if keyed
    public let kind: BindingKind         // singleton / scoped / provider / aggregate
    public let scope: String?            // the scope seed, or nil for app-scoped
    public let dependencies: [DependencyEdge]
    public let location: SourceLocation  // origin module, file, line
}
```

`introspect()` builds nothing until called — no runtime memory cost in production — and the model is `Codable` so adapters can serialise it. Use cases: `/admin/wiring` endpoints (WireHummingbird ships a mountable one), ops dashboards, runtime diagnostic logs. The construction code lives in the binary (small for typical graphs); if that ever matters for a large graph, an opt-out build flag is a future lever.

#### Deliberately not in scope

- **No runtime resolution via introspection.** `introspect().bindings.first(...)` returns descriptions, not values. Use `resolve(...)` for instances. Read-only by design — the service-locator pattern is excluded.
- **No runtime modification.** Bindings are fixed at compile time; introspection observes the graph, doesn't mutate it.
- **Not a substitute for compile-time validation.** Don't introspect to check whether a binding exists before using it — the compiler already guarantees that.

#### Tooling

Wire core ships the data; tooling builds on it. A `wire graph` CLI, IDE plugins, doc generators — these are community-driven and post-1.0. The build-time JSON's stability is the contract that lets such tooling exist independent of Wire core's release cadence.

### What's *not* in scope

- No SwiftUI integration.
- No service-locator escape hatch (`Wire.resolve(Foo.self)` from arbitrary code). If you need it, you pass a resolver explicitly.
- No runtime registration. The graph is fixed at build time.
- No compatibility layer with swift-dependencies. They're different models; pick one per service.
- No custom scopes through 0.x.
- **No container hierarchy.** Containers are flat. Spring's parent/child container model is the source of a lot of complexity (override semantics, scope interaction, profile inheritance) that hasn't earned its keep in concrete server-side cases. Multi-tenant is a request-scope problem; profile selection picks one of several flat containers at startup; plugins compose at the SPM module level. If a real need for hierarchy turns up post-v1 it'll be added with semantics worked out, not inherited as an assumption.
- **No fine-grained binding override across containers.** When you select a `@Container` at the entry point, it's the whole graph for that run, not an overlay on the default. "Selectively swap one binding while keeping the rest" is the next ergonomic ask post-1.0, but introducing override semantics is a big enough commitment that it stays out until there's a concrete use case it's the only answer to.
- **No `~Copyable` injection through 0.x.** All bindings are `Copyable`. Wrap move-only resources in a Sendable reference type that manages scoped access internally.
- **No container-level isolation enforcement.** Swift's per-type isolation handles correctness; container-level policies (`@Container(isolation:)`) are a deliberately deferred direction, addable post-1.0 without breaking existing code.
- **No *transitive* or hidden library activation.** Depending on a Wire-aware library *directly* composes its bindings (the dependency is the activation), but only for the libraries you name in your own target's `dependencies` — never a dependency-of-a-dependency, and never from a bare `import`. So the surprise Wire rules out is Spring's classpath autoconfig (a JAR transitively dragged onto the classpath starts side-effecting beans): here the activated set is exactly your manifest's direct dependencies, visible in one place, and any binding conflict it introduces is a compile error (strict-on-ambiguity), not a silent runtime behavior change. A way to depend-without-activating (use a library's plain types but not its wiring) is a deferred refinement, not an M1 feature.

---

## Comparison

| Library            | Compile-time graph | Linux-first | Macros | Request scope                          | Forces existentials? |
|--------------------|--------------------|-------------|--------|----------------------------------------|----------------------|
| swift-wire         | Yes                | Yes         | Yes    | First-class, type-checked              | No                   |
| SafeDI             | Yes                | Untested    | Yes    | Hierarchical, not framework-aware      | No                   |
| Needle             | Yes                | Builds; codegen tool not packaged for Linux | No (codegen) | Hierarchical | No |
| swift-dependencies | No (runtime)       | Yes         | No     | Task-locals; not statically scoped     | n/a                  |
| Swinject           | No (runtime)       | Yes         | No     | Manual                                 | n/a                  |

The table compares technical axes, but the bigger gap is structural: none of the listed libraries publishes a macro-based extension contract for third-party framework integrations. Needle has internal pluginized components but no public extension surface. SafeDI is a closed system — it knows its own concepts (`Instantiable`, `Forwarded`, `Received`) and nothing else; new framework integrations require changes to SafeDI itself. swift-dependencies and Swinject operate at the value-resolution layer with no build-time graph for packages to contribute to. swift-wire's adapter-annotation contract is the architectural difference, and retrofitting an equivalent into the others would be a redesign rather than an incremental feature.

swift-dependencies is the closest comparison along a different axis. It's the right call for teams whose mental model is iOS or SwiftUI — TCA-style dependency injection where dependencies are looked up at the point of use via `@Dependency`. swift-wire is the right call for teams whose mental model is Spring or Dagger — a build-time graph that's validated as a whole, with dependencies wired at construction. Both are legitimate; pick the one whose mental model fits your team.

Beyond the DI category, swift-wire sits at a different layer from the libraries it gets compared against. Web frameworks (Hummingbird, Vapor) own the runtime — request handling, the network, the service group. Capability-abstraction libraries define what individual dependencies look like — how a database client or HTTP client is shaped for testability and substitution. swift-wire validates and composes the graph of those dependencies at build time. The three layers compose: an app uses a web framework as its runtime, depends on capability abstractions for its building blocks, and uses swift-wire to wire them together.

---

## Roadmap

Milestones are tied to what task-cluster needs next, not a fixed calendar. The full roadmap — milestone-by-milestone (M0–M7 and post-1.0), plus pre-1.0 polish, deferred features, and post-M1 design previews — lives in [ROADMAP.md](ROADMAP.md). M0–M6 are complete; `RemainingSurfaceWork.md` is the named successor track for what M6 did not close, and M7 (performance) is next.

---

## Risks (so I have to look at them)

1. **swift-syntax tax.** Every Swift release breaks something. SafeDI's commit log is full of Xcode N+1 fixes. Signing up to chase swift-syntax for years is the actual cost of this project, not the design work. Mitigations: keep the macro surface small (most logic in the build plugin, which is more stable); pin swift-syntax `from: "601.0.0"` (M0 confirmed this resolves to 601.0.1 identically on Linux + macOS Swift 6.3.x); treat 602.x bumps as deliberate per-Swift-release maintenance events rather than free version drift.
2. **Audience and adoption asymmetry.** "Compile-time DI for Swift" is saturated; "Compile-time DI for server-side Swift on Linux with a JVM-shaped extension contract" is a real gap but a small one — and partly a bet that Swift continues to grow with developers coming from a non-iOS background. In the demonstration framing the primary audience is task-cluster's blog readership, with adoption downstream of that. The asymmetry to be careful about: publishing the library implicitly invites adoption, and adopters expect ongoing maintenance regardless of whether the blog series stays interesting. The "Status: pre-alpha" header should stay loud through 0.x to keep expectations calibrated.
3. **Hummingbird vs. Vapor abstraction.** Hummingbird threads context through generic parameters; Vapor uses storage on `Request`. A single library can either lean into one model and make the other adapter lossy, or use task-locals as the lowest common denominator and sacrifice some compile-time safety for request-scoped values. M2 will commit to one and the README will be updated honestly.
4. **Macro diagnostics.** The single biggest UX failure mode for compile-time DI is bad error messages when the graph is broken. M1 has to nail this. If it doesn't, the project fails on first contact.
5. **Resolution edge cases.** Strict-on-ambiguity reads cleanly on paper. Real graphs surface cases — default-implementation conformances, conditional conformances, generic protocols whose witnesses come from generic specialization — where what counts as "matching" is itself a judgment call. The build plugin has to be conservative ("when in doubt, ambiguous") to keep diagnostics honest, even at the cost of forcing keys in cases where a smarter algorithm could have picked. If users hit ambiguity errors constantly because the conservative rule is too coarse, the ergonomic story collapses regardless of how good the diagnostics are.
6. **Adapter-annotation contract churn.** The contract is the most architecturally consequential decision in the project, and it has to support all three attachment forms (type-level, type-level-with-member-recognition, member-level) from day one — retrofitting the third would break every adapter written against the first two. Mitigation (executed in M0): the first two were prototyped in Spike 2 and passed cleanly. **How this actually went, since it is now testable rather than predicted:** the *attachment forms* held and the *mechanism* did not. M1's design made an adapter a post-construction sink emitting a `_wireRegister` call, and M2.3 replaced the whole path with collation — a full redesign of the thing this risk was about, before any adapter had shipped publicly, which is the only reason it cost nothing. What has held since is the **capability axis** that replaced it. Six capabilities beyond the original have arrived across M5–M6d, each demanded by a real adapter, and each landed as a new enum case rather than a version bump. One correction to that record, because it is the interesting case: the axis has been broken once — `.injectsDependencyOnArgument` and `.injectsFactoryOnArgument` merged into a single `.injectsFromGraph` dispatching on the argument's kind — which did touch the one adapter declaring it. That was cheap because both cases were months old and in-house, and it would not have been otherwise. So the residual risk is not churn in the contract's *shape* but in whether a future adapter needs an edge the axis cannot express, and whether the next such merge arrives after third parties have written against the cases. The versioning answer (`WireAdapterAnnotationV2`, recognized by type name beside V1) exists and has never been exercised.
7. **Features-driven-by-narrative.** The demonstration framing creates a temptation to ship features because they make for a good blog post rather than because task-cluster needs them. Each library addition should be motivated by an actual task-cluster need. `WireMVC` is the canonical test — if no task-cluster endpoint genuinely benefits from inline route declarations, don't ship the adapter just because the contract-design post wants an example. The contract still had to *support* both the spec-first and the annotation-driven shape from day one for the architectural reasons above. (Resolved since: `WireMVC` shipped in M5, and M6d then merged the two — an OpenAPI operation is a WireMVC route contributing to the same key, so it is one routing model rather than a choice.)
8. **Isolation handling untested through 0.x.** task-cluster's planned trajectory exercises `Sendable` extensively but doesn't naturally use global-actor isolation (no `@MainActor` on a server) or actor-isolated job processors (the planned task executor is structured-concurrency-shaped, not actor-shaped). The basic Sendable rule will be validated; the harder isolation corners — global actors, custom-actor scope crossings — won't appear in the example application. If Wire is adopted by code with richer isolation patterns, latent design issues may surface that task-cluster's validation didn't catch. Mitigation: be honest about this gap; treat any external adoption of isolation-heavy code as an early test that may produce design issues to fix.

---

## Why "wire"?

It's what the library does, it's short, it's available on the package index, and it has prior art (Google's `wire` is the Go ecosystem's compile-time DI library — the design lineage is honest about itself).
