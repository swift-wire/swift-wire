// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

/// A typed marker identifying a binding in the dependency graph.
///
/// `BindingKey<Value>` is a phantom-typed marker. It carries no runtime
/// state; its job is to let users declare keys at the source level
/// (typically as static members on the bound type) and reference them
/// in `@Inject(...)` / `@Provides(...)` arguments. The build plugin
/// matches keyed bindings to keyed consumers by the *canonical text* of
/// the key expression — e.g. `Database.primary` — so what the user
/// writes IS the key.
///
/// Declare a named key for each binding that shares a slot, as a
/// static member on a type you own:
///
///     extension Database {
///         static let primary = BindingKey<Database>()
///         static let replica = BindingKey<Database>()
///     }
///
/// And tag both the producer and the consumer with it:
///
///     @Provides(Database.primary) let primaryDB: Database = ...
///     @Inject(Database.primary) var db: Database
///
/// For a protocol-typed slot, declare the keys on a named type such as
/// a caseless enum (`enum Repositories { static let primary =
/// BindingKey<any TodoRepository>() }`), not on the protocol: a protocol
/// extension can't hold a stored `static let`.
///
/// The `key` member `@Singleton`/`@Scoped(seed:)` synthesise does not
/// key the binding; those types are always bound unkeyed.
///
/// The generic parameter `Value` documents which type the key is
/// intended for. Swift's type system uses it at the call site to
/// rule out non-`BindingKey` arguments (`@Inject(42)` fails to
/// compile), and the build plugin's emitted type-assertion functions
/// unify it with the consuming binding's type to catch mismatches —
/// `@Inject(Database.primary) var db: Cache` doesn't type-check.
public struct BindingKey<Value>: Sendable {
    public init() {}
}
