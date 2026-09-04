# Resolution and keys

How a dependency finds its binding, why a protocol conformance is not enough, and what to write
when two bindings match.

## Overview

Wire's build plugin reads source **before** the compiler does. It parses syntax, and it has no
type checker behind it — no conformance tables, no inheritance graph, no knowledge that one
type implements another. Everything about resolution follows from that, including the rule
newcomers trip over first.

## Identity is the text you wrote

A binding's identity, and an injection point's, is the canonical text of the type expression as
written.

```swift
@Provides let db = AdministratorDb()

@Singleton
struct AdministratorGrant: AccessPolicy {
    @Inject let db: AdministratorDb        // matches, by that text
}
```

`AdministratorGrant` conforms to `AccessPolicy`, and Wire does not know it. A consumer asking
for `any AccessPolicy` will not resolve to it, and no protocol that `AccessPolicy` inherits
will either. Whitespace inside a type expression is normalised before matching, so
`Router<X, Y>` and `Router<X,Y>` are the same identity — but that is the extent of the
interpretation.

When you *want* an abstract identity, say so on the producing side. ``Singleton(allowUnused:)``
with `as:` sets a type's graph identity to the opaque form, and a ``Provides(allowUnused:)``
function can return `some P` directly:

```swift
@Singleton(as: TodoRepository.self)
struct CouchDBTodoRepository: TodoRepository { … }
```

That is the identity model working for you rather than against you — the concrete type is named
once, at the leaf, and consumers see the abstraction. <doc:ChoosingAnAbstraction> covers what
each of the three spellings costs.

## The three outcomes

1. **One binding matches** — it is injected, and nothing in your code mentions a key.
2. **Several match** — a compile error naming the candidates, which you resolve with a key.
3. **None match** — a compile error at the unsatisfied dependency.

There is no automatic disambiguation: no most-specific-match, no declaration-order tie-break.
Every silent inference rule eventually surprises someone, and the price of ruling them out is
one annotation at the place the ambiguity actually exists.

## Keys

Every ``Singleton(allowUnused:)`` and ``Scoped(seed:allowUnused:)`` generates a
`static let key: BindingKey<Self>`, so the disambiguating key usually already exists and you
only have to name it:

```swift
@Inject(CouchDBTodoRepository.key) var repository: any TodoRepository
```

Auto-generated keys are tied to the producing type, which does not help when two values of the
*same* type are configured differently — a primary and a replica, two clients with different
timeouts. Declare a ``BindingKey`` and reference it on both sides:

```swift
extension Database {
    static let primary = BindingKey<Database>()
    static let replica = BindingKey<Database>()
}

@Provides(Database.primary) static let primaryDB: Database = …
@Provides(Database.replica) static let replicaDB: Database = …

@Singleton
struct UserService {
    @Inject(Database.primary) var db: Database
}
```

`BindingKey` is phantom-typed and carries no runtime state. Its identity in the graph is the
canonical text of the declaring reference — `Database.primary` — which is why the key needs no
name string. Its generic parameter is what rules out mismatches: `@Inject(Database.primary) var
cache: Cache` does not compile.

Keyed and unkeyed do not mix. An unkeyed `@Inject` matches only unkeyed bindings, and a keyed
one only same-key bindings.

On an initialiser parameter, the key rides on ``Bind`` instead — see <doc:InjectionPoints>.

## The cost, stated plainly

Preserved generics mean the only verbosity Wire forces into your code is one key per genuinely
ambiguous injection. In the common case nothing mentions a key at all, and concrete types
appear only where bindings are declared. That is what the strict rule is buying.
