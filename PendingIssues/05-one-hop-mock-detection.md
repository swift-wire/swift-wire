# 05 — Mock-consumption detection is one-hop only

**Repo(s):** swift-wire + wire-mvc (both apply the same one-hop rule)
**State:** 🔴 Known limitation (intentional simplification; consistent across repos but incomplete)
**Blocks:** a lifted `@Middleware` `@Factory` that reaches the mock **transitively** — through a non-mock
dependency that itself reaches the `@BindType`'d slot.
**Surfaced by:** the Phase B audit. Phase C does not force this (the examples' factories inject the mock
directly).

## What it is

A factory is classified as mock-consuming iff one of its **direct** `@Inject` members matches a `@BindType`
slot (swift-wire's `mockedDoublesField` over `factory.dependencies`; wire-mvc's `factoryTemplateInjectFields`
over the template's `@Inject` members). A factory that injects a *non-mock* dependency which transitively
reaches the mock — e.g. a `@Singleton` whose `init` reads the mocked backend — is **not** detected, so its
`create` won't thread doubles and it would see the real binding under a keyed suite.

Both repos deliberately use the same one-hop rule, so they *agree* — but both are incomplete in the same way.

## Use case blocked

A lifted middleware factory that depends on the mock indirectly (via a `@TestScopable`'d singleton or a
request-scoped intermediate), rather than injecting it directly.

## State / evidence

- swift-wire: `variantFactoryTransforms` inspects only `factory.dependencies` (direct), not their cone.
- wire-mvc: `FactoryInjectFinder` records only the template's own `@Inject` members.
- Chosen during Phase B to keep the two repos' detection identical and simple.

## Fix sketch

Extend detection to walk the factory's dependency cone for mock-reachability (mirror the subject
reconstruction's `reachable(from:over:)` walk). Note the deeper interaction: a transitively-reached singleton
must itself be `@TestScopable`'d and reconstructed, and the factory would then need to source *that*
reconstructed instance — larger than a detection tweak. May be acceptable to keep one-hop + **diagnose** the
transitive case (guide the user to inject the mock directly or mark the intermediate).
