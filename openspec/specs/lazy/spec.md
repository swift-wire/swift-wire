# Lazy values

## Purpose

`Lazy` is a public type in the `Wire` module that defers a value's construction to its first `get()`.
It is an ordinary Swift type as far as WireGen is concerned: a graph holds a `Lazy<T>` only when user
code produces one, typically with `@Provides … -> Lazy<T>`, and consumers inject `Lazy<T>` by that type.
The factory runs at most once however many callers race the first `get()`, and a failure is cached.

Rationale: [LazyTypeSupport](../../../Documentation/Notes/LazyTypeSupport.md).
Documentation: [ScopesAndLifetimes](../../../Sources/Wire/Wire.docc/ScopesAndLifetimes.md), [ConcurrencyAndIsolation](../../../Sources/Wire/Wire.docc/ConcurrencyAndIsolation.md).

## Requirements

### Requirement: `Lazy` is a public generic struct over a factory
The `Wire` module SHALL export `public struct Lazy<Value: Sendable>: Sendable` with the public
initialiser `init(_ factory: @escaping @Sendable () async throws -> Value)` and the public method
`func get() async throws -> Value`.

#### Scenario: a synchronous factory under the async contract
- **WHEN** `let lazy = Lazy<Int> { 7 }` and `try await lazy.get()` is called
- **THEN** the result is `7`

Pinned by: `Tests/WireTests/LazyTests.swift` (`syncFactoryWorksUnderAsyncContract`), `Tests/IntegrationTests/LazyResourceExample.swift`, `Tests/IntegrationTests/BootstrapTests.swift` (`userWrittenLazyProviderInvokesFactoryOnFirstGet`).

### Requirement: The factory does not run before the first `get()`
Constructing a `Lazy` SHALL NOT invoke its factory; the first `get()` SHALL invoke it.

#### Scenario: construction then first use
- **WHEN** a `Lazy<Int>` whose factory increments a counter and returns `42` is constructed
- **THEN** the counter is `0` until `get()` is called, `get()` returns `42`, and the counter is then `1`

Pinned by: `Tests/WireTests/LazyTests.swift` (`factoryNotCalledUntilGet`).

### Requirement: The factory runs at most once
Every `get()` after the first, and every `get()` racing the first, SHALL return the value from the
single factory invocation without invoking the factory again.

#### Scenario: sequential calls
- **WHEN** `get()` is called three times on a `Lazy<String>` whose factory returns `"computed"`
- **THEN** each call returns `"computed"` and the factory ran once

#### Scenario: concurrent first callers
- **WHEN** 100 child tasks call `get()` on one `Lazy<Int>` whose factory yields before returning `99`
- **THEN** all 100 results are `99` and the factory ran once

Pinned by: `Tests/WireTests/LazyTests.swift` (`factoryCalledOnceAcrossSequentialGets`, `factoryCalledOnceAcrossConcurrentFirstCallers`).

### Requirement: A factory failure is cached
If the factory throws, that `get()` SHALL rethrow the error, and every later or concurrent `get()`
SHALL rethrow the same failure without invoking the factory again.

#### Scenario: repeated calls after a failure
- **WHEN** the factory throws `TestError.boom` and `get()` is called five times
- **THEN** every call throws a `TestError` and the factory ran once

#### Scenario: concurrent callers of a failing factory
- **WHEN** 50 child tasks call `get()` on a `Lazy<Int>` whose factory yields and then throws
- **THEN** every task catches a `TestError` and the factory ran once

Pinned by: `Tests/WireTests/LazyTests.swift` (`factoryFailureRethrowsOnFirstGet`, `factoryFailureCachedOnSubsequentGets`, `factoryFailureCachedAcrossConcurrentCallers`).

### Requirement: Copies of a `Lazy` share one cached value
A copy of a `Lazy` SHALL share its coordination state with the original, so the factory runs once
across both.

#### Scenario: get on the original, then on the copy
- **WHEN** `let copy = lazy` and `get()` is called on `lazy` and then on `copy`
- **THEN** both return `13` and the factory ran once

Pinned by: `Tests/WireTests/LazyTests.swift` (`copiedLazySharesCachedValue`).

### Requirement: WireGen treats `Lazy<T>` as an ordinary bound type
WireGen SHALL NOT recognise `Lazy`. A `Lazy<T>` binding SHALL exist only when a declaration produces
one, and a consumer's `Lazy<T>` dependency SHALL resolve to that binding by its type, with no edge to a
`T` binding.

#### Scenario: a user-written lazy provider
- **WHEN** `@Provides func makeLazyResource(callCount: LazyResourceCallCount) -> Lazy<LazyResource>` is declared and `LazyResourceConsumer` declares `@Inject var resource: Lazy<LazyResource>`
- **THEN** the bootstrap emits `let lazyOfLazyResource = makeLazyResource(callCount: lazyResourceCallCount)` and `let lazyResourceConsumer = LazyResourceConsumer(resource: lazyOfLazyResource)`, and introspection records the consumer's dependency as `DependencyEdge(type: "Lazy<LazyResource>", key: nil)`

Pinned by: `GoldenHarness/Golden/_WireGraph.swift.golden`.

### Requirement: Bootstrapping a graph that holds a `Lazy` does not run its factory
Bootstrap SHALL construct the `Lazy<T>` binding without calling `get()`; the factory SHALL run on the
consumer's first `get()` and its value SHALL be shared by later calls.

#### Scenario: after bootstrap
- **WHEN** `Wire.bootstrap()` returns
- **THEN** `await graph.lazyResourceCallCount.value == 0`

#### Scenario: first and later use
- **WHEN** `graph.lazyResourceConsumer.materialise()` is called three times
- **THEN** the three results are the same instance with `value == "materialised"` and the call count is `1`

Pinned by: `Tests/IntegrationTests/BootstrapTests.swift` (`userWrittenLazyProviderDoesNotInvokeFactoryAtBootstrap`, `userWrittenLazyProviderInvokesFactoryOnFirstGet`, `userWrittenLazyProviderCachesAcrossMultipleGets`).

### Requirement: A `Lazy` dependency does not break a construction cycle
A dependency on `Lazy<T>` SHALL be a construction edge like any other, included in topological
ordering and cycle detection. The only dependencies left out of those edges are member-injection
parameters (`@Inject weak var` and `@Inject func`) and scope-entry thunks, and a `Lazy<T>` dependency is
neither.

#### Scenario: a lazy provider that needs its own consumer
- **WHEN** `A` injects `Lazy<B>` and the `@Provides` producing `Lazy<B>` takes `A` as a parameter
- **THEN** WireGen reports a dependency cycle through `A` and the `Lazy<B>` binding

Pinned by: nothing yet.

## Related specifications

- [concurrency-posture](../concurrency-posture/spec.md)
- [binding-lifetimes](../binding-lifetimes/spec.md)
- [injection-points](../injection-points/spec.md)
- [dependency-cycles](../dependency-cycles/spec.md)
- [reachability-and-retention](../reachability-and-retention/spec.md)
- [construction-scheduling](../construction-scheduling/spec.md)
- [providers](../providers/spec.md)
