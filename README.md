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

🚧 🚧 🚧 Status: experimental. Expect a lot of rough edges and public API to change without warning. Don't put it anywhere near production until further notice. 🚧 🚧 🚧

swift-wire is a compile-time dependency injection library for Swift. It has a design language aimed to be familiar to those coming from a Java DI ecosystem such as Spring or Dagger.

```swift
@Provides let db = AdministratorDb()

@Singleton
public struct AdministratorGrant: AccessPolicy {
    @Inject let db: AdministratorDb
}
```

## Installation

Add the package, depend on the `Wire` library, and apply the build plugin to every target that declares bindings. The plugin is what reads the annotations — without it they do nothing.

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/tachyonics/swift-wire.git", branch: "main"),
],
targets: [
    .executableTarget(
        name: "MyApp",
        dependencies: [.product(name: "Wire", package: "swift-wire")],
        plugins: [.plugin(name: "WireBuildPlugin", package: "swift-wire")]
    ),
]
```

swift-wire requires Swift 6.3 and supports Linux and macOS. macOS needs 15 or later; Linux is unaffected.

Bootstrapping the generated graph is one line, and the graph's roots are properties on it.

```swift
@Singleton(allowUnused: true)          // read off the graph rather than injected — so, a root
public struct AdministratorGrant: AccessPolicy { ... }

let graph = try await Wire.bootstrap()
graph.administratorGrant.check(...)
```

Anything else the graph constructs is a local inside the bootstrap rather than a property — it is
handed to whatever injects it and never stored. A binding you intend to read off the graph
yourself is a root, and says so with `allowUnused: true`.

## How it works

At its core, swift-wire is a SwiftPM build plugin that scans your code to detect annotations and uses these to determine the graph of dependencies your application needs. The entry point this codegen creates is a struct that concretely names the types of your bindings, along with a helper to initialise an instance of that struct.

One of swift-wire's aims is to generate code that is as efficient/performant as the best-in-class code that you could manually write so, for example, the library doesn't existentially box bindings into a giant map/dictionary.

By using a SwiftPM build plugin, swift-wire parses source files prior to the compilation process and therefore has no knowledge of type hierarchy. The identity of each binding and injection point is therefore the literal expression written in code. By default that identity is the written type: the two bindings above are `AdministratorDb` and `AdministratorGrant`, and the injection point `let db: AdministratorDb` matches the first of them by that text. `AdministratorGrant` cannot be automatically resolved through `AccessPolicy` (or any protocol that `AccessPolicy` inherits).

For situations where a binding identity of the type is insufficient (such as having multiple bindings of the same type), a `BindingKey` can be used.

```swift
package enum Backend {
    package static let client = BindingKey<ConfiguredHTTPClient>()
}

@Provides(Backend.client)
package func provideBackendClient(...) -> ConfiguredHTTPClient {
    ...
}

@Singleton
public struct TodoRepository {
    @Inject(Backend.client) let client: ConfiguredHTTPClient
}
```

## Designed for Swift

swift-wire is designed to provide the convenience of a dependency injection framework while taking advantage of the features of the Swift language. One of its headline features in this area is its understanding of opaque types. A binding can be declared with an opaque identity and then promoted to the generic parameter of another binding.

```swift
@Provides
package func provideHTTPClient() -> some HTTPClient {
    ...
}

@Singleton
public struct TodoRepository<Client: HTTPClient> {
    @Inject let client: Client
}
```

The generated graph struct will be generic itself with respect to HTTPClient, with its instantiation helper creating a concrete instance based on whatever type the compiler knows `provideHTTPClient()` returns.

## Scopes

`@Singleton` bindings live for the lifetime of the process. Everything else is declared with `@Scoped(seed:)`, where the seed is the type whose runtime value opens the scope — an HTTP request, a queue message, a tenant. The seed itself is injectable, like any other binding in that scope.

```swift
@Scoped(seed: HTTPRequest.self)
struct RequestLogger {
    @Inject var request: HTTPRequest   // the seed
    @Inject var logger: Logger         // a singleton, injected across the boundary
}
```

Scoped bindings see singletons; singletons don't see scoped bindings, and asking for one is a build-time error at the injection site rather than a runtime failure. Entering a scope per request or per message is the job of the adapter that owns the seed — [wire-mvc](https://github.com/tachyonics/wire-mvc) does this for HTTP requests.

## Extending swift-wire

swift-wire is also designed to be extensible and provides a number of extension points that allow third-party libraries to extend the core library. One such example of this is [wire-configuration](https://github.com/tachyonics/wire-configuration). This library takes advantage of an extension point that allows re-writing an injection point.

```swift
@Provides(CouchDB.client)
package func provideCouchDBClient(
    @ConfigProperty(forKey: "couchdb.host", default: "localhost") host: String,
    @ConfigProperty(forKey: "couchdb.port", default: 5984) port: Int,
    @ConfigProperty(forKey: "couchdb.user", default: "admin") user: String,
    // `isSecret` redacts the value in logging and debugging output.
    @ConfigProperty(forKey: "couchdb.password", default: "password", isSecret: true) password: String
) -> ConfiguredHTTPClient {
    return ConfiguredHTTPClient(
        client: .shared,
        baseURL: "http://\(host):\(port)",
        authorization: "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
    )
}
```

Another library that takes extensive advantage of the library's extension points is [wire-mvc](https://github.com/tachyonics/wire-mvc), a declarative web framework.

## Documentation and status

The API reference and articles live in the DocC catalog and build with
`swift package generate-documentation --target Wire`. Design notes for individual subsystems are
in [`Documentation/Notes`](Documentation/Notes); changes that are designed but not yet built are
in [`Proposals`](Proposals).

Work is tracked as [issues](https://github.com/tachyonics/swift-wire/issues), which are the
source of truth for what is built, what is known-broken, and what is deliberately deferred.

---

## Why "wire"?

It's what the library does, it's short, it's available on the package index, and it has prior art (Google's `wire` is the Go ecosystem's compile-time DI library — the design lineage is honest about itself).
