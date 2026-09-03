# ``Wire``

Compile-time dependency injection for Swift, with no runtime container.

## Overview

Wire reads your annotations at build time, validates the dependency graph, and emits the wiring
as ordinary Swift. There is no resolver to call, no registration step, and nothing to look a
dependency up in at runtime — the generated graph is stored properties, and a missing or
ambiguous binding is a compile error rather than a crash on first request.

```swift
@Singleton
struct UserService {
    @Inject var store: any UserStore
}

@Provides
func userStore(_ db: Database) -> any UserStore { PostgresUserStore(db) }
```

Two features go beyond that baseline, and both are designed around Swift's type system
specifically rather than ported from a JVM container. **Opaque binding identities**
(``Provides(allowUnused:)`` returning `some P`, ``Singleton(allowUnused:)`` with `as:`) let an abstract dependency resolve
without existential boxing or witness-table indirection, preserving concrete type identity
through the graph. **``BuilderKey``** folds multibinding contributors through a user-defined
`@resultBuilder`, which lets a consumer express composition semantics that need machinery no
other language has.

## Is Wire the right fit?

Worth answering before adopting anything. Wire suits a **flat-with-scopes** dependency
structure — app-scoped singletons plus sibling scopes for a request, a job, a tenant — which is
the shape most server applications have. It is built and tested Linux-first.

It is a poor fit, and something else is the better answer, when:

- **The tree is deep and nested** — eight or more levels with contextual state at several of
  them. Compile-time tree position is what you want there, which is SafeDI's model, not this one.
- **Lifetimes are genuinely heterogeneous** and resist clean scope categorisation. A flexible
  runtime-resolution library is often the right call; forcing a build-time graph here pays the
  ceremony cost without gaining proportional safety.
- **Dependency overlay for tests and previews is the dominant concern** and the graph itself is
  small. A library designed for overlay will be less machinery.
- **You are writing an iOS app and your existing patterns are working.** Don't introduce a DI
  framework for its own sake.

The honest summary is that Wire earns its cost when the graph is large enough that a missing
binding at runtime is a real risk, and when you are on a platform where compile-time validation
and Linux support both matter.

## Topics

### Getting started

- <doc:StructuringAnApp>
- <doc:ChoosingAnAbstraction>

### Declaring bindings

- ``Singleton(allowUnused:)``
- ``Provides(allowUnused:)``
- ``Scoped(seed:allowUnused:)``
- ``Factory(_:)``
- ``Inject()``
- ``Bind``

### Composition

- ``Container()``
<!-- The `Contributes` overloads need hash disambiguators rather than the type-signature form
     (`-(CollectedKey<Element>)`), which only the 6.4 DocC understands and the 6.3.3 floor rejects.
     The hashes derive from each symbol's USR, so changing one of these macro signatures changes its
     hash and fails the documentation gate — take the replacement DocC suggests in the error. -->
- ``Contributes(to:)-2dvt9``
- ``Contributes(to:)-3elca``
- ``Contributes(to:atKey:)``
- ``Contributes(to:withOrder:)-5diak``
- ``Contributes(to:withOrder:)-8p702``
- ``Replaces()``
- ``GraphInputs()``

### Multibindings

- ``BindingKey``
- ``CollectedKey``
- ``MappedKey``
- ``BuilderKey``
- ``FactoryKey``

### Lifecycle

- ``Teardown()``
- ``Teardownable``
- ``Lazy``

### Introspection

- ``Introspectable``
- ``WiringModel``
- ``BindingInfo``
- ``BindingKind``
- ``DependencyEdge``
- ``SourceLocation``

### Writing an adapter

- ``WireAdapterCapability``
- ``WireProviderSelector``
- ``WireProxyScope``
