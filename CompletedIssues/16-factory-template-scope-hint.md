# 16 — The cross-scope fix-it names a synthesised factory the user cannot annotate

**Repo(s):** swift-wire
**State:** ✅ **Fixed, 2026-08-27** — `@Factory` is named as a lifetime and diagnosed as one, and the
cross-scope note now offers only moves that can be written. See *Resolution* at the end.
**Blocks:** nothing. The underlying restriction (a factory template's deps resolve once, at the wider
scope) is real and is not what this issue asks to change.
**Surfaced by:** wire-mvc-examples' `auth-abac` item, where a route-scope middleware wanted the
request-scoped identity binding its controller already had.

## What it is

A `@Factory` template that `@Inject`s a `@Scoped` binding is rejected, correctly:

    error: no binding produces 'Caller'
    note: 'Caller' is bound in @Scoped(seed: HTTPRequest.self) scope, not @Singleton
    note: scope '_WireFactory_ControllerMiddleware_screenAccess' to @Scoped(seed: HTTPRequest.self) too,
          or extract the scope-bound concern into a wrapper bound at the wider scope

Both halves of the fix-it are wrong here, and the first is wrong twice over.

**`_WireFactory_ControllerMiddleware_screenAccess` is not a type the user wrote.** It is the concrete
factory the plugin synthesises per consumed `FactoryKey`. There is no declaration to put `@Scoped` on, so
the instruction has no spelling even before its semantics are considered.

**And the type the user did write cannot take it either.** Annotating the *template* — `@Scoped(seed:)`
alongside `@Factory(key)` — fails two ways in sequence:

    error: invalid redeclaration of 'init(engine:directory:caller:)'   // in expansion of macro 'Factory'

because `ScopedMacro` and `FactoryMacro` both synthesise an `init` from the `@Inject` members. Supplying
the `init` by hand (which both macros defer to) gets past that and reveals that the plugin never read the
scope macro at all:

    error: no binding produces 'HTTPRequest'
    error: no binding produces 'Caller'
    note: scope '_WireFactory_ControllerMiddleware_screenAccess' to @Scoped(seed: HTTPRequest.self) too, …
    error: '@Singleton ScreenAccess' can't be a single instance: generic parameters 'Ctx', 'Reader',
           'Sender' are unconstrained or unbound, so the type would vary per use.

The seed is not recognised (`no binding produces 'HTTPRequest'`), the same fix-it is repeated, and the
template is described as `@Singleton` — so a reader who follows the advice ends up further from a working
graph than they started, holding three errors instead of one.

The second half of the fix-it — *"extract the scope-bound concern into a wrapper bound at the wider
scope"* — is sound generic advice and vacuous here: the scope-bound concern **is** the request, and a
wrapper at the wider scope has no request to hold.

## Where it comes from

`WireGenCore/CrossScopeHints.swift:190-196`. The branch fires on `consumerPartition.scope == nil` with the
binding scoped in the same container family, which is the ordinary singleton-wants-scoped case and the
advice is right for it. Nothing in that branch distinguishes a consumer the user declared from a
synthesised factory, and factory templates are the one consumer kind for which "scope it too" is not an
available move.

## Fix sketch

Both halves follow from naming something that is already true, decided in wire-mvc's
[`ScopeAwareMiddlewareAndBindings.md`](https://github.com/tachyonics/wire-mvc/blob/main/Documentation/Notes/ScopeAwareMiddlewareAndBindings.md):
**`@Factory` is a lifetime in its own right**, and it is not a scope. A template is constructed per
`create` call — per use site — and is not a binding; the synthesised `_WireFactory_<key>` that holds its
`@Inject` members *is* a binding, with app lifetime. So the members resolve once, where the factory is
constructed, and that is the constraint that bites. The template's own lifetime was never the obstacle.

Dagger, which this vocabulary is borrowed from, reaches the same place and says so outright:
**"@AssistedInject types cannot be scoped"** — and its assisted type carries no scope annotation at all.

So `@Factory(K)` stays exactly as it is written today. **No source migration.** What changes is:

1. **A mutual-exclusion diagnostic.** `@Factory` alongside `@Singleton` or `@Scoped(seed:)` is two lifetime
   macros on one type, and should be reported as that. It also **dissolves the `invalid redeclaration of
   init`**, since only one such macro may be present to synthesise the initialiser — the collision stops
   being reachable rather than being worked around.
2. **A factory-aware branch in `fixItSuggestion`** that recognises a synthesised `_WireFactory_<key>`
   consumer and states the true constraint:

       error: no binding produces 'Caller'
       note: 'Caller' is bound in @Scoped(seed: HTTPRequest.self) scope, not @Singleton
       note: 'ScreenAccess' is a @Factory template. Its @Inject members are resolved once, where the
             factory is constructed — app scope — while the template itself is constructed per `create`
             call and has no scope of its own, so a scoped value cannot be one of them. Take it as an
             assisted parameter, or move the concern to where the scope is live: a handler, or a
             RequestBound binding.

3. **Documentation.** `@Factory`'s own doc comment describes the two axes it differs from `@Singleton` on
   but never states the lifetime, which is why a reader reaches for a scope macro in the first place.

## What this issue is not

It is **not** a request for scoped factory templates — Dagger forbids the equivalent outright
(*"@AssistedInject types cannot be scoped"*), and wire-mvc has declined the tier that would have been their
only consumer. The consumer that wanted one — a WireMVC route-scope
middleware needing the request-scoped identity — is blocked by an ordering fact as well as a scoping one:
wire-mvc's generated register closure enters the middleware fold *before* `_wireEnterScope`, which runs
inside the fold's own terminal, so there is no scope in existence when `create` is called. That is
wire-mvc's question to answer, and it is designed out in
[`ScopeAwareMiddlewareAndBindings.md`](https://github.com/tachyonics/wire-mvc/blob/main/Documentation/Notes/ScopeAwareMiddlewareAndBindings.md),
whose sequence assigns **two steps to this repository**: naming `@Factory` as a lifetime and diagnosing it
as one (which dissolves the `invalid redeclaration` above rather than fixing it), and a seeded scope
yielding more than its subject. This issue is only that
swift-wire currently answers the question by naming a fix that does not exist, and it stands whether or not
either step is scheduled.

## Resolution

Fixed as **step 2** of wire-mvc's
[`ScopeAwareMiddlewareAndBindings.md`](https://github.com/tachyonics/wire-mvc/blob/main/Documentation/Notes/ScopeAwareMiddlewareAndBindings.md)
sequence, in three parts and with **no source migration** — `@Factory(K)` is written correctly everywhere
already; what changed is what the compiler says when it is combined, and what the plugin says when a scoped
value is asked of it.

**1 — the mutual exclusion, twice, because it has two symptoms.** `LifetimeMacroExclusion` (WireMacrosImpl)
stops the *second* lifetime macro on a declaration synthesising anything, so `invalid redeclaration of
'init(…)'` is dissolved rather than diagnosed alongside: there is only ever one `init`. The first lifetime
attribute in source order expands normally and every later one reports, which yields exactly one error
pointing at the attribute to delete. `factoryWithScopeDiagnostics` (WireGenCore) refuses the same
combination from source, where it prevents the *other* symptom this issue documents: the declaration being
discovered twice, as a binding whose generic parameters must be bound and as a template whose generic
parameters are assisted by definition — which is where the `'@Singleton ScreenAccess' can't be a single
instance` generic-arity error came from. A refused declaration is recorded as **neither** role, so nothing
downstream reports on top of an error already given.

**2 — the fix-it.** `DiscoveredScopeBoundType` gained `factoryTemplateName`, set only on a synthesised
`_WireFactory_<key>` binding, and `fixItSuggestion` branches on it ahead of every shape branch. It is a
field rather than a `_WireFactory_` prefix test on purpose: the prefix is an emission detail, and a
diagnostic keyed on it would be one rename away from silently falling back to the advice being removed.
The note now reads:

    error: no binding produces 'Caller'
    note: 'Caller' is bound in @Scoped(seed: HTTPRequest.self) scope, not @Singleton
    note: 'ScreenAccess' is a @Factory template, so it has no scope of its own: it is constructed per
          `create` call, and its @Inject members resolve once — where the factory Wire synthesises for
          its key is constructed, in @Singleton. A @Scoped(seed: HTTPRequest.self) binding can't be one
          of them. Produce 'Caller' at @Singleton, or move the scope-bound concern out of the template
          and into a binding that lives in the scope. Annotating 'ScreenAccess' with a scope is not a
          move: @Factory is itself a lifetime, and a declaration has one.

**One correction to the sketch above.** It proposed ending the note with *"Take it as an assisted
parameter, or move the concern to where the scope is live: a handler, or a `RequestBound` binding."* Both
halves were dropped. "Handler" and "`RequestBound`" are WireMVC vocabulary and this diagnostic is emitted
by a domain-free layer that never learns what a middleware is; and an assisted *value* parameter does not
exist in Wire today — it is step 6 of the wire-mvc sequence and explicitly unscheduled. Recommending it
would have repeated the exact fault being fixed: naming a fix with no spelling. The note offers the two
moves that can be written today and says plainly which one cannot.

**3 — documentation.** `@Factory`'s own declaration now has a *Lifetime* section. It was the absence of one
that sent a reader to a scope macro in the first place: the doc described the two axes `@Factory` differs
from `@Singleton` on and never said what lifetime it names. It names the two objects apart — the
synthesised factory is a binding with app lifetime; the template is constructed per `create` call and is
not a binding — and states the constraint that follows, which is that the template's `@Inject` members
resolve at the *factory's* scope, not the template's. The template's own lifetime was never the obstacle.

The underlying restriction is unchanged, and was never what this issue asked to change: a factory
template's dependencies still resolve once, at the wider scope. What is gone is Wire answering that with a
fix that does not exist.
