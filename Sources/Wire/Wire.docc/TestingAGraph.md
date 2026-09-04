# Testing a graph

Four ways to substitute a binding under test, and how to choose between them.

## Overview

A test wants a different graph from production, and the interesting question is *how* different.
Wire offers four answers at increasing granularity, and picking the right one is mostly a
question of whether the test needs to hold a handle on the double.

| | Swaps | Test holds the double? | Reach |
|---|---|---|---|
| ``Container()`` | the whole graph | n/a | one bootstrap |
| ``Replaces()`` | one binding, by type | no — Wire constructs it | whole test target |
| `@BindType` | one slot, to a named mock type | **yes** — you pass the instance | per `TestingKey`, per scope entry |
| Depending on a mock package | every binding the package declares | no | the test target's manifest |

The test-graph vocabulary — `TestingKey` and `@BindType` — lives in a separate `WireTesting`
product rather than in `Wire`. That is deliberate: a production target that does not link it
cannot spell `TestingKey()` at all, so the mistake fails at the declaration instead of much
later, inside codegen.

```swift
.testTarget(
    name: "MyAppTests",
    dependencies: [
        "MyApp",
        .product(name: "WireTesting", package: "swift-wire"),
    ],
    plugins: [.plugin(name: "WireBuildPlugin", package: "swift-wire")]
)
```

The test target applies the plugin and composes **its own** graph from the app target's
bindings. Every substitution below lives in that graph; the production graph is untouched.

## A whole graph: `@Container`

Selecting a container swaps everything at once, and it is the bluntest of the four. See
<doc:ProvidingValues>.

## A stateless fake: `@Replaces`

When the double is a hand-written type you can annotate, and the test does not need a handle on
it, ``Replaces()`` is the least machinery:

```swift
@Singleton(as: TodoRepository.self)
@Replaces
struct FakeTodoRepository: TodoRepository { … }
```

Wire constructs it, so there is nothing to configure or inspect afterwards. That is the whole
trade: it is the right tool for a stateless fake across a test target, and the wrong one for a
mock you want to `verify`. It also cannot take a *generated* mock, whose type you have no
source to annotate.

## An inspectable mock: `TestingKey` and `@BindType`

When the test needs to construct the double, configure it, and assert against it afterwards,
declare a **test-graph variant**:

```swift
import WireTesting

enum MyTests {
    @BindType(BackendRepository.self, MockBackendRepository.self)
    static let testSetup = TestingKey()
}
```

`@BindType` names the slot first and the concrete mock type second, mirroring `@Provides` and
`@Replaces` — `@BindType(Repo.self, Mock.self)` for the unkeyed slot,
`@BindType(Repo.primary, Mock.self)` for a keyed one. Stack several on one key to substitute
several slots in one variant.

The important difference from `@Replaces` is that `@BindType` **references** the mock type
rather than annotating it, so a generated mock fits with no wrapper. Wire specialises the
variant graph to that concrete type — the same opaque lift it already performs for the real
binding, just pointed elsewhere.

One key is one variant. Two suites wanting different substitutions declare two keys.

## The instance rides the seed

The type substitution is compile-time; the *instance* is not. A `@BindType`ed binding resolves
to a double supplied at scope entry, threaded alongside the seed through the same channel — so
there is no new value-source concept, just an extra thing the scope is entered with.

The plugin generates a doubles struct per variant, and a bootstrap and scope facade named after
the key:

```swift
let graph = try await Wire.bootstrapMyTests_testSetup()

let mock = MockBackendRepository()
let doubles = _MyTests_testSetupDoubles(backendRepository: mock)

let scope = try await Wire.bootstrapMyTests_testSetup_RequestSeedScope(
    seed: RequestSeed(id: "req-1"),
    wireGraph: graph,
    doubles: doubles
)
```

An adapter's test harness normally supplies the doubles for you — wire-mvc correlates them per
HTTP request — so hand-building them, as above, is what you do when there is no harness.

A `@BindType`ed slot reached with **no** double supplied is an error rather than a fallback to
the production binding. The slot is a hole the test is required to fill, and silently filling it
with the real implementation is the failure mode that makes a passing test meaningless.

## The cascade, and why it is inherent

A singleton captures its dependencies once, at bootstrap. So a per-scope-entry double can only
reach one by rebuilding it per entry — which means everything on the path from the mocked
binding up to the scope root has to be lifted into the scope.

This cannot be dodged if you want completeness. A consumer that reads a dependency *in its
`init`* is built once, with no scope active, and would never see the double otherwise:

```swift
@TestScopable
@Singleton
final class AccountController {
    let tag: String

    @Inject init(repository: any AccountRepository) {
        self.tag = repository.tag("init")     // the read a per-call proxy would miss
    }
}
```

Each app-scoped hop on that path carries `@TestScopable` on its own declaration. The mark is an
explicit acknowledgement, because making a singleton per-request can break one that relies on
being a singleton — a cache, a pool, anything holding cross-scope state. It attaches to the type
rather than to a key because "is this safe to rebuild?" is a property of the definition, not of
one test's substitutions. A generic type marks cleanly here, where a key-side metatype could not
spell it.

You are not left to guess where it goes. The plugin knows the scope roots, computes the path,
and errors on each unmarked hop naming exactly what to add:

```
error: BackendRepository is bound per-scope-entry under test, but reaches the
       scope root through singleton 'TodoController'. Add @TestScopable to
       'TodoController' to allow it to be lifted into the scope under test.
```

`@TestScopable` lives in `Wire` rather than `WireTesting`, because it marks a *production* type
and is therefore written in production sources. It has effect only under a variant, so a
production build never activates it.

## What the variant graph actually contains

Lifted bindings are dropped from the variant's app graph — they are reconstructed per scope
entry instead — so their eager initialisers do not run at bootstrap. That is observable, and
worth asserting when you want proof the substitution took:

```swift
let bindings = graph.introspect().bindings.map(\.type)
#expect(!bindings.contains("AccountController"))
```

See <doc:IntrospectingTheGraph>.

## Choosing

Ask whether the test needs to *hold* the double. If it does — to configure it, or to assert on
what it received — that is `@BindType`, and the cascade comes with it. If it does not, a
`@Replaces` fake is less machinery and stays out of the scope system entirely. If nearly every
binding differs, a separate container or a mock package is the honest answer rather than a long
list of substitutions.
