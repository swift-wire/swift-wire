# Concurrency and isolation

Wire generates code that passes Swift 6's checker rather than layering a concurrency model of
its own on top of it.

## Overview

The compiler already enforces isolation correctness, and it does it better than a DI framework
could from the outside. Wire's job is to emit wiring that type-checks, and to fail early and
legibly where the graph's shape is what makes it fail. There is no parallel `isolation:`
parameter to learn and no framework-owned executor.

## Sendability is derived, not demanded

Wire does not impose a blanket `Sendable` requirement on bindings. The generated graph struct
declares no explicit conformance — Swift auto-derives it when every binding is `Sendable`, and
does not when one is not. You get the feedback at the use site, where the graph actually crosses
an isolation boundary, which is the layer at which the answer means something.

In practice most server graphs are `Sendable` throughout, because singletons are shared across
the process and scoped values cross `await` boundaries during handling. The point is that this
follows from your bindings rather than from a rule Wire wrote down, and a graph deliberately
held in one task does not have to pretend otherwise.

## Global actors are honoured, not reinvented

```swift
@MainActor
@Singleton
struct Coordinator { … }
```

The macro reads the `@MainActor` you already wrote. Consumers in other isolation domains use
`await` the way they would for any isolated type. Wire adds nothing here because Swift's
existing mechanism already type-checks correctly.

For actors specifically, `@Inject func` is the natural fit — the plugin emits
`await consumer.method(args)` to pay for the crossing. See <doc:InjectionPoints>.

## `Lazy` inherits from its value

``Lazy`` is `Sendable` when `T` is. It defers construction *within the same scope*, so the held
value is built under that scope's normal isolation rules with no cross-scope hop. Its
first-call coordination is a `Mutex`-based state machine: exactly one factory invocation
however many callers race, with concurrent callers awaiting the same task.

## The classic failure becomes a build error

"Inject a request-scoped value into a singleton" is the archetypal container bug, and here it
is caught structurally before the concurrency checker ever sees it — a scoped binding cannot be
stored on a wider scope, and the diagnostic points at the injection site with the fix. The
Sendable checker is the second line of defence, for what the structural check cannot see.

## Deliberately deferred

- **Custom isolation domains as scope qualifiers.** "This dependency lives on `MyJobActor`" is
  already expressible as `@MyJobActor` on the type. Wire respects that rather than inventing a
  parallel spelling.
- **Container-level isolation enforcement.** A container that constrains every binding inside it
  to one isolation domain is a plausible direction for single-threaded subsystems, deferred
  until per-type isolation is demonstrably insufficient. Adding it later is not a breaking
  change.
- **`~Copyable` bindings.** Singletons are shared by definition and non-copyable means
  single-owner, so the semantics conflict. Wrap a move-only resource in a `Sendable` reference
  type that manages access internally — the pattern the standard library itself uses for
  `Mutex`. The full design question is written up in the package's proposals.
