# Adding Wire to a package

What goes in `Package.swift`, what the build plugin does with it, and how you get from an
annotation to a running graph.

## Overview

Wire is a library and a SwiftPM build plugin.. The library gives you the attributes and key
types to write; the plugin is what *reads* them, validates the graph and emits the wiring.
A target that depends on `Wire` but does not apply the plugin compiles perfectly and produces
no graph at all, which is the one setup mistake worth calling out up front.

## The manifest

```swift
dependencies: [
    .package(url: "https://github.com/swift-wire/swift-wire.git", branch: "main"),
],
targets: [
    .executableTarget(
        name: "MyApp",
        dependencies: [.product(name: "Wire", package: "swift-wire")],
        plugins: [.plugin(name: "WireBuildPlugin", package: "swift-wire")]
    ),
]
```

Every target that *declares* bindings needs the `Wire` dependency, because a binding is written
with attributes you have to `import Wire` to spell. Only the target that *composes* a graph
needs the plugin. A library shipping bindings for someone else to compose takes the dependency
and skips the plugin — its consumer's plugin re-parses its sources. See
<doc:ComposingAcrossModules>.

Wire requires Swift 6.3, and supports Linux and macOS. macOS needs 15 or later.

## Your first graph

Two declarations are enough to have a graph worth bootstrapping:

```swift
import Wire

@Provides let logger = Logger(label: "MyApp")

@Singleton(allowUnused: true)
struct UserService {
    @Inject var logger: Logger
}
```

[`@Provides`](doc:Provides(allowUnused:)) declares a value available to bindings in the graph.
[`@Singleton`](doc:Singleton(allowUnused:)) says `UserService` is a binding with process lifetime,
and [`@Inject`](doc:Inject()) marks the dependency. You do not need to write `UserService`'s initialiser —
the macro synthesises one taking a parameter per injection point, and the plugin emits the call.

`allowUnused: true` is needed here because nothing in the graph injects `UserService` — you are going
to read it off the graph yourself, and that read is an expression Wire cannot see. Without the
mark it would be pruned as unreachable. A binding some other binding injects needs nothing.
<doc:WhatGetsBuilt> has more detail on what bindings actually get constructed.

## Bootstrapping

```swift
let graph = try await Wire.bootstrap()
graph.userService.load()
```

`bootstrap()` is `async throws` regardless of your graph, because any binding's `init` may be
either, and the colour propagates through the whole construction chain.

The graph's **roots** (including bindings marked `allowUnused: true`) are its stored properties, named
after their types. Everything else the graph constructs is a local inside the bootstrap, handed
to whatever consumes it and never stored — so `graph.someInternalDependency` is a compile error
telling you to mark that binding `allowUnused: true` if you really do want to read it.

The generated struct is `internal` to the module that composed it, so it is yours to read and
nothing downstream can see it.

## Values that come from outside

Some values are not the graph's to construct — configuration read from the environment, CLI
arguments, an externally-owned client. Declare them together as
[`@GraphInputs`](doc:GraphInputs()):

```swift
@GraphInputs
struct AppInputs: Sendable {
    let configReader: ConfigReader
}

let graph = try await Wire.bootstrap(inputs: AppInputs(configReader: reader))
```

Each stored property becomes a binding of its own type, injected the ordinary way
(`@Inject var configReader: ConfigReader`). Inputs are leaves by construction: they exist
before the graph does, so they cannot depend on anything in it. Forgetting one is a missing
argument at the `bootstrap(inputs:)` call — a compile error at the line that is wrong, not a
resolution failure at startup.

## Where to go next

- <doc:ScopesAndLifetimes> — when a binding should not live for the whole process.
- <doc:ResolutionAndKeys> — what happens when two bindings could satisfy one injection point.
- <doc:StructuringAnApp> — where Wire sits in a layered design.
