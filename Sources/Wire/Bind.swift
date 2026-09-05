// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

/// Name the keyed binding an `@Inject init` parameter should resolve to.
///
/// `@Inject(Key)` keys a *property* (`@Inject(Database.primary) var db: Database`), but `@Inject` is a
/// peer macro and Swift does not allow a macro attribute on a function parameter. When the dependency has
/// to arrive through a custom initialiser — the usual case for a `@Singleton` that does async setup work in
/// `init` — the parameter carries `@Bind(Key)` instead. It is a property wrapper (which *can* attach to a
/// parameter), transparent at runtime: the initialiser sees the plain value, and the generated bootstrap
/// passes it positionally, exactly as for an unkeyed parameter. Only the build plugin reads the key.
///
///     enum CouchDB {
///         static let httpClient = BindingKey<HTTPClient>()
///     }
///
///     @Singleton(as: TodoRepository.self)
///     struct CouchDBTodoRepository: TodoRepository {
///         @Inject init(@Bind(CouchDB.httpClient) client: HTTPClient) async throws { … }
///     }
///
/// An unkeyed parameter still resolves by type; `@Bind` is only needed to pick among several bindings of
/// the same type. `Value` unifies with the parameter's type, so `@Bind(Database.primary) cache: Cache`
/// fails to compile.
///
/// A parameter can also name a **multibinding** key, mirroring `@Inject`'s overloads for the same three
/// key kinds — so a `@Provides func` or `@Inject init` can take an aggregate, not only a single binding:
///
///     @Provides
///     static func router(@Bind(App.routes) routes: [Route]) -> Router { … }
@propertyWrapper
public struct Bind<Value> {
    public var wrappedValue: Value

    public init(wrappedValue: Value, _ key: BindingKey<Value>) {
        self.wrappedValue = wrappedValue
    }

    /// Bind a `CollectedKey` aggregate. `Value` is pinned to `[Element]` — the shape the key fixes — so a
    /// parameter declared with the wrong element type fails here rather than as a missing binding at
    /// codegen time. (`@Inject`'s counterpart can't check this: it is a macro, and multibinding keys are
    /// excluded from the generated `_check` functions.)
    public init<Element>(wrappedValue: Value, _ key: CollectedKey<Element>) where Value == [Element] {
        self.wrappedValue = wrappedValue
    }

    /// Bind a `MappedKey` aggregate. `Value` is pinned to `[Key: Element]`, as above.
    public init<Key: Hashable, Element>(
        wrappedValue: Value,
        _ key: MappedKey<Key, Element>
    ) where Value == [Key: Element] {
        self.wrappedValue = wrappedValue
    }

    /// Bind a `BuilderKey` aggregate. Unconstrained, unlike the two above: a `BuilderKey` lets the producer
    /// define how contributions fold, so the result type is the builder's to decide and there is no fixed
    /// shape to pin `Value` to.
    public init<Builder>(wrappedValue: Value, _ key: BuilderKey<Builder>) {
        self.wrappedValue = wrappedValue
    }
}
