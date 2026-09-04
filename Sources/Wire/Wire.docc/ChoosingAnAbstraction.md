# `some P`, `any P`, or concrete

Three ways to type a binding, what each costs, and when the abstraction is not worth having.

## Overview

Every binding you declare makes a choice about how much its consumers know. Wire supports all
three, per binding, and the choice is yours rather than the framework's — but they are not
interchangeable, and the trade is different in Swift than it is in a language where abstracting
is free.

## `some P` — abstraction without the box

A ``Provides(allowUnused:)`` function returning `some P`, or a ``Singleton(allowUnused:)`` declared with `as:`, gives the
consumer an abstract dependency whose **concrete type identity is preserved through the graph**.
The consumer references only the protocol, through a generic constraint; the compiler still
knows what the type is.

```swift
@Provides
func repository(_ db: Database) -> some Repository { PostgresRepository(db) }

@Singleton
struct ReportService<R: Repository> {
    @Inject var repository: R
}
```

No existential boxing, no heap allocation for a value that would not otherwise need one, no
witness-table indirection, and specialisation still crosses the boundary.

This is the option worth understanding, because it is the one that has no equivalent in
reflection-based JVM containers — Spring and Guice resolve an abstract dependency through an
interface reference, and there is nothing to preserve. It needs a compile-time framework and a
language with `some P`.

**Its cost is virality.** The opaque chain propagates: each intervening type has to become
generic over the constraint. That is ordinary as a *language* pattern — Rust propagates
`T: Repository` bounds through intervening types at ecosystem scale — but it is real work, and
it compounds the further the chain runs.

## `any P` — the workhorse

Strict port-and-adapter separation: the consumer depends on the port through an existential and
knows nothing else. This is the standard shape, and the right default when the opaque form's
virality would cost more than the boxing does.

Reach for it when:

- The consumer **cannot or should not be generic** over the port — a heterogeneous collection of
  implementations, or a type where the generic surface would cascade awkwardly through code that
  has no interest in it.
- The type is one you do not control, such as swift-log's `Logger`.
- The chain has simply run long enough. `some P` satisfies `any P` promotion, so you can cut
  the chain at the hop where it stops paying — you are not committed to it all the way down.

The cost is what an existential always costs in Swift: boxing, a heap allocation for anything
that does not fit inline, and no specialisation across the boundary. That is a heavier cost than
the JVM equivalent, where the object was heap-allocated and dynamically dispatched either way —
which is exactly why eliminating it is worth machinery here and would buy nothing there.

## Concrete — no abstraction at all

The consumer knows the implementation type. Strictly this breaks the port-and-adapter separation
for that binding, and it is frequently the right call anyway: when there is one canonical
implementation and no plausible second, the abstraction costs more than it returns.

A `Logger` is the usual example. So is any internal type that exists to be constructed by the
graph and used in one place.

## Choosing

Ask what the abstraction is *for*. If the answer is "so a test can substitute it", note that
Wire substitutes bindings at the graph level — ``Replaces()`` and the `@BindType` testing
primitives work on concrete bindings too — so a protocol introduced only for testability may not
be earning its cost.

If the answer is "because there really are several implementations", the question becomes
whether the consumer can be generic. If it can, `some P` is strictly better than `any P`. If it
cannot, `any P` is doing a job the opaque form cannot.
