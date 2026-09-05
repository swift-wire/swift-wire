# Providing values

[`@Provides`](doc:Provides(allowUnused:)) for what the graph cannot build itself,
[`@Container`](doc:Container()) for grouping a graph, and [`@Replaces`](doc:Replaces()) for
substituting one binding in it.

## Overview

A `@Singleton` or `@Scoped(seed:)` type is already a binding — the plugin constructs it and
nothing else is needed. `@Provides` is for the rest: framework primitives you did not write,
values produced by external systems, and concrete instances that pin a generic constraint.

## `@Provides`

It attaches to a property or a function, whichever fits. A property contributes a value with no
dependencies; a function's parameters *are* its dependencies:

```swift
@Provides let logger = Logger(label: "MyApp")

@Provides
func repository(client: HTTPClient) -> TodoRepository {
    TodoRepository(client: client)
}
```

Declarations live at module scope, or as `static` members of an enclosing type. The plugin
aggregates every one in the target into a single graph, and for most applications that is the
whole composition story.

A binding that starts as a plain value and later needs computation gains parameters and a body;
the attribute does not change. There is no migration between annotations as a graph grows.

Pass a ``BindingKey`` to declare a keyed binding when the same type is bound more than once —
see <doc:ResolutionAndKeys>.

## `@Container`

[`@Container`](doc:Container()) groups bindings under a named type, and generates a bootstrap
of its own so the whole graph can be selected at the entry point:

```swift
@Container
enum TestContainer {
    @Provides static let logger = Logger(label: "test")
    @Provides static let repository: any TodoRepository = MockTodoRepository()
}

let graph = try await Wire.bootstrapTestContainer()
```

Selection is **atomic**: a container's bindings *are* the graph for that run. Module-scope
`@Provides` and module-scope `@Singleton`s do not leak in, which keeps the swap total rather
than an overlay with override semantics to reason about.

Containers are flat — no parents, no children. Every `@Container` declaration targeting the
same type name merges into one logical container, including `@Container extension Foo`, so a
container can be assembled across files. A plain `extension Foo` without the attribute does not
contribute; its bindings fall through to the default graph.

## `@Replaces`

Where a container swaps an entire graph, [`@Replaces`](doc:Replaces()) swaps one binding inside
one. Attach it alongside a producer macro; the slot it supersedes is the one that producer
already declares, so it takes no argument:

```swift
@Singleton(as: Repo.self)
@Replaces
struct FakeRepo: Repo { … }
```

A keyed producer supersedes its keyed slot for free, and neither crosses into the other's:
`@Provides(Repo.primary) @Replaces` targets the keyed slot, `@Provides @Replaces` the unkeyed
one.

When another binding also produces that slot — typically one composed in from a dependency
module — the `@Replaces` binding wins and the other is dropped, instead of raising the
duplicate-binding error two ordinary bindings would. At most one `@Replaces` may target a slot
per graph, and the binding it replaces must live in a **different module**: two same-module
bindings for one slot are a plain duplicate, and you resolve that directly rather than
overriding it.

The motivating case is a test target that composes an application's real bindings and
substitutes a fake for one of them.
