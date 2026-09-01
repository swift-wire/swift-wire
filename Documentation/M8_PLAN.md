# M8 build plan — noncopyable and nonescapable bindings

> **Status:** not started; M8.0 (spikes) is done and cleared the gate. The design record is
> [Notes/OwnershipAndLifetimeSupport.md](Notes/OwnershipAndLifetimeSupport.md) — it carries the
> *why*, the worked case, the two motivating shapes, and every verified compiler behaviour this
> plan depends on. This file carries the *how*.

Same discipline as the other milestone plans: each sub-step runs end-to-end and has a validation
gate; highest-risk seam first. Grounded in the M8.0 spikes (run August 2026 against the real
registration signature, not a synthetic one) and the shipped shapes cited below — not a predicted
model.

## The headline

A binding may opt into `~Copyable` (so a large backend structure is never implicitly copied) or
`~Escapable` (so a request-bound resource cannot outlive its request), and Wire adjusts what it
emits. The mechanism is **conditional emission**: a graph with no such binding produces
byte-identical output to today. A `~Copyable` binding stops being a `_WireGraph` stored property
and becomes a local in the frame that owns its lifetime — the bootstrap for app-scoped, the
scope-entry closure for scoped. A `~Escapable` binding additionally gets a generated
`@_lifetime(...)` naming the seed it is bound to.

The support boundary falls on a split the framework already makes: `_WireRouteContributor_<C>`
stores `_wireSubject: C` for `@Singleton` controllers, which must stay copyable regardless, while
M5.4 constructs `@Scoped` controllers per request inside the thunk, where noncopyable is fine.

## What M8 embeds into (shipped — stable targets, do not change)

- **The register closure.** `wire-mvc Sources/WireMVC/Routing.swift:10-34` —
  `@escaping @Sendable (HTTPRequest, consuming RequestContext, [String: Substring],
  consuming sending Reader, consuming sending ResponseSender) async throws -> Void`. All three
  associated types carry `~Copyable`; `Reader` and `ResponseSender` also carry
  `SendableMetatype`, **`RequestContext` does not** — see *M8.P* below. This is the frame a
  scoped noncopyable binding lives in.
- **The seed is already nonescapable.** `HTTPServerCapability.RequestContext` is declared
  `~Copyable, ~Escapable` (swift-http-api-proposal,
  `Sources/HTTPAPIs/Server/HTTPServerCapability+RequestContext.swift:64`). The lifetime chain
  roots on it naturally; nothing has to invent a root.
- **The scope-entry thunk.** M5.4's injected thunk constructs the request-scoped subgraph per
  request ([Archive/M5_4_PLAN.md](Archive/M5_4_PLAN.md)). This is where scoped noncopyable
  bindings are constructed and destroyed.
- **`Teardownable`.** `public protocol Teardownable { func teardown() async -> [any Error] }`
  ([Notes/TeardownDesign.md](Notes/TeardownDesign.md)), with the graph held as
  `any Teardownable` and the walk running over the graph struct's **members**. Both facts
  constrain M8.2 — see *Key sub-decisions*.
- **Per-binding discovery metadata.** `originModule` per binding
  ([Notes/MultiModuleComposition.md](Notes/MultiModuleComposition.md), 7b) is the channel M8.1
  extends.

## The central decision — conditional emission

Everything else follows from this. Wire learns copyability/escapability per binding in M8.1, and
**every** later emission change is gated on that metadata being non-empty. The invariant is
testable and should be pinned before any emission work starts:

> A graph containing no `~Copyable` or `~Escapable` bindings produces **byte-identical**
> generated output before and after M8.

`GoldenHarness/` is the guard — the real `WireGen` over the `Tests/IntegrationTests` corpus,
diffed against a committed recording (built for M7b, which leans on the same invariant). This is
not a nicety — it is what makes the feature an opt-in rather than a change everyone absorbs, and
it is cheap only if written first.

## Sub-steps

### M8.0 — spikes — ✅ DONE

Three compiles against a faithful mock of the real `register` signature, on the 6.4 snapshot
(`swiftly run +6.4.x-snapshot-2026-08-01 swiftc -c`). All passed; full results in
[Notes/OwnershipAndLifetimeSupport.md](Notes/OwnershipAndLifetimeSupport.md), *Spike results*.

- **Region isolation clears** — a `~Copyable, ~Escapable` model rooted on a borrow of the
  `consuming` seed, constructed inside the real `@escaping @Sendable` closure, held across
  suspensions before and after construction. Clean, no warnings. This was the gate.
- **The synthetic anchor works silently** — a `borrowing` seed parameter appearing only in
  `@_lifetime(borrow ctx)` and never in the body draws no unused-parameter complaint.
- **The guarantee holds in the real frame** — escaping into a `Task` inside the closure is
  rejected, naming `ctx`.
- **The full worked chain compiles**, including `@_lifetime(copy m, borrow ctx)` and a generated
  `_WireScope`.

Three findings folded into the steps below: the `SendableMetatype` gap on
`HTTPServerRouteBuilder.RequestContext` (**M8.P**, a wire-mvc prerequisite); the
`BindingKey`/`Bind` suppression gap and the SILGen crash behind it (**M8.1**); and `~Copyable` on
an *associated type* needing the 6.4 snapshot while generic *parameters* are fine on 6.3.3
(M8.2's surface choice).

### M8.P — `SendableMetatype` on `RequestContext` — wire-mvc prerequisite

**Lands in wire-mvc, before M8.2.** `HTTPServerRouteBuilder` carries `SendableMetatype` on
`Reader` and `ResponseSender` but not on `RequestContext` (`Routing.swift:11-15`), and upstream's
`HTTPServerCapability.RequestContext` is a bare `~Copyable, ~Escapable` protocol that does not
imply it. Against that constraint set, **any** use of a type generic over the seed inside the
register closure warns:

```
warning: capture of non-Sendable type 'B.RequestContext.Type' in an isolated closure [#SendableMetatypes]
```

Verified in M8.0 not to be a rebinding artefact — removing the rebinding moves the warning to the
next use of the seed's generic type. Every scoped binding generic over the seed would trigger it,
so every generated route in a graph using this feature would warn. Adding the constraint compiles
clean.

One line, aligning `RequestContext` with its two siblings. **But it is a requirement addition on a
public protocol**, so a conformer whose `RequestContext` metatype is not sendable breaks — worth a
scan of known conformers before it lands.

**Gate:** wire-mvc CI green with the constraint added; a fixture constructing a seed-generic type
inside a register closure compiles without warnings.

### M8.1 — copyability/escapability as binding metadata

Discovery records, per binding: is the type `~Copyable`? `~Escapable`? Read syntactically from
the suppressed conformances on the declaration, riding the same per-binding channel as
`originModule`.

The known limit applies: Wire only knows types it parses. `UniqueArray` from the stdlib and
adapter-published types are opaque — the same "matching syntax with no type checker" constraint
[Notes/OpaqueTypesInContext.md](Notes/OpaqueTypesInContext.md) records. So this step also adds
the **seed declaration's escapability bit**, and is the natural moment to add the
**concurrently-entered bit** the diagnostics in M8.3 need. Both live on the seed/adapter
declaration.

**Also lands the keyed-binding surface.** `BindingKey<Value>` (`Sources/Wire/BindingKey.swift:31`)
and `Bind<Value>` (`Sources/Wire/Bind.swift:22`) have no `~Copyable` suppression, so a keyed
noncopyable binding fails at the constraint level before any of the rest matters — verified in
M8.0. Both need suppression on `Value`, and `Bind` must itself become `~Copyable` to store one.
This is a public-type change to `Sources/Wire`, independent of codegen, and it gates the whole
keyed path in the motivating case.

Behind it sits [swiftlang/swift#81624](https://github.com/swiftlang/swift/issues/81624) — with
suppression added, a user's provider body that mentions the wrapped parameter **crashes SILGen**
(reproduced on the 6.4 snapshot). The `_x.wrappedValue` workaround holds for the `~Copyable` case;
ROADMAP's *Known blockers* bug 2 needs `~Escapable` plus a generic parameter and does not apply
here. Because `@Bind` is transparent at runtime and the bootstrap passes positionally, the burden
is on **user code**, not Wire's emission — so M8.3 should carry a plugin diagnostic for the
noncopyable-plus-`@Bind` combination, since the alternative is a compiler crash with no
actionable message.

**Gate:** `_WireGraph.json` reports copyability/escapability per binding for a fixture graph
mixing parsed and external types, with "unknown" distinguishable from "copyable". A keyed
noncopyable binding resolves through `@Bind` with the `_x.wrappedValue` form. No emission changes.
Golden files unchanged.

### M8.2 — the storage model: noncopyable bindings as frame locals

The real codegen work. A `~Copyable` binding is not a `_WireGraph` stored property; it is
constructed as a local in the owning frame and moved into its single consuming consumer. Touches
`_WireGraph` emission, bootstrap construction order, and M5.4's scope-entry thunk.

**Depends on M8.P having landed in wire-mvc** — without it every generated route in a graph using
this feature warns. Also lands the second M8.0 finding: keep the generated surface in
**generic-parameter** territory rather than declaring a protocol with a noncopyable associated
type, which would move swift-wire's toolchain floor from 6.3.3 to the 6.4 snapshot.

**This step owns the teardown decision** — see *Key sub-decisions*. Resolve it before the
emission model is settled, not after.

**Gate:** a fixture graph with one `~Copyable` app-scoped binding and one `~Copyable`
request-scoped binding builds and serves; the noncopyable bindings appear as locals in generated
output, not as stored properties; `_WireGraph` remains copyable; golden files for graphs without
noncopyable bindings are byte-identical.

### M8.3 — consumer-count and concurrency diagnostics

The rules from the design note's *The cases*:

- multiple consuming consumers → error naming both
- N borrowing consumers plus ≤1 consuming → order the borrows first
- no consumers → error (with the teardown alternative recorded, per M8.2's decision)
- a consumer in a **concurrently-entered descendant scope** → error, naming the path
- a noncopyable binding reached through `@Bind` whose provider body mentions the parameter
  directly → **warn, steering to `_x.wrappedValue`** (M8.1). Worth carrying even though the
  underlying bug is upstream: without it the user gets a SILGen crash and no message.

The last rule needs M8.1's concurrency bit. If only one non-singleton scope kind exists when this
lands, **hardcode** "request scope is concurrently entered" with a TODO — do not invent the
general model before a second scope kind forces it.

**Gate:** each rule has a failing fixture with the expected diagnostic text. A graph that
compiles today still compiles.

> **Release boundary.** M8.1–M8.3 are `~Copyable` only: stable toolchain, no experimental
> feature, no annotations emitted, releasable on its own. It delivers the *"don't implicitly copy
> the large payload"* half of the motivating case — the half that does not depend on an
> underscored attribute due to be renamed. Ship here and stop if M8.4's cost looks wrong.

### M8.4 — `~Escapable`: lifetime emission

- Derivation from the `@Inject init`'s ownership modifiers (table in the design note). `borrowing`
  → `borrow` from syntax alone; `consuming` a `~Escapable` parameter → `copy` is **compelled**,
  so Wire cannot get it wrong; the only ambiguity is `copy` vs *no annotation*, which needs the
  parameter type's escapability from M8.1.
- Emit `@_lifetime(copy dep, borrow seed)` in generated initialisers — the compelled component
  plus the self-documenting one.
- Thread the synthetic seed anchor into Wire-generated initialisers (verified in M8.0).
- Diagnose an unrooted chain: a `~Escapable` scoped binding whose construction never borrows the
  seed. **Decision: the user takes the seed explicitly** for `@Provides func` — Wire cannot emit
  into user-written functions, so it diagnoses instead.
- **The manifest problem.** Generated code lives in the *user's* target, so the user's manifest
  needs `.enableExperimentalFeature("Lifetimes")`. A build plugin cannot set that, and the plugin
  does not read manifests. Without it the failure is a confusing error in generated code, so this
  step must decide how the flag's absence is surfaced. Candidate: a **package trait**, the
  mechanism already used for wire-mvc's `ServerTransport` trait.

**Gate:** the worked chain from the design note builds; a `Task` escape in a handler body fails
with the lifetime diagnostic; a `~Escapable` binding with no seed borrow fails with Wire's
diagnostic rather than a raw compiler error.

### M8.5 — validation gate

The worked chain end-to-end in `wire-mvc-examples`, on at least one runtime, serving a real route
that returns a large payload through a `~Copyable, ~Escapable` model.

## Key sub-decisions (pinned)

1. **`Teardownable`'s existing requirement must not change.** This is a constraint on M8.2, not a
   discovery within it. `teardown()` walks the graph struct's members, so a binding that is not a
   member cannot be walked — but altering the public protocol breaks every conformer whether or
   not they use M8. Add a separate path for noncopyable bindings, or exclude them from teardown
   and say so in the diagnostic. Teardown-as-consuming-consumer stays an open question
   ([design note](Notes/OwnershipAndLifetimeSupport.md), *Open questions*), not an M8 deliverable.
2. **The experimental flag must not reach Wire's public surface.** If the `Wire` module's public
   API declares `~Escapable`, consuming packages inherit the flag whether they use the feature or
   not. Package trait, or keep it out of public protocols.
3. **Suppression is emitted conditionally.** Adding `~Copyable` to a lifted `_WireGraph<T0…>`
   parameter is source-compatible for conformers (it relaxes, per wire-mvc's
   `TestingArchitecture.md` discipline), but changes what Wire's own emitted code may assume.
   Emit it only on parameters that actually bind a noncopyable type.
4. **No cloning policy.** N consumers each needing their own instance is a generic `@Provides
   func` specialised per consumer. See the design note, *Deliberately excluded*.
5. **No structural limit on scope nesting.** The compiler enforces the fan-out constraint
   directly; Wire's contribution is a better diagnostic, not a restriction.

## Risks / interleaves

- **M7c dynamic construction scheduling — the sharpest interleave.**
[Notes/EffectAwareResolution.md](Notes/EffectAwareResolution.md)'s scheduler was "a single
  `TaskGroup` plus per-binding `AtomicState<T>` cells", and this risk is **discharged**: a
  noncopyable binding cannot live in such a cell — that is storage, and M8.2's whole model is that
  noncopyable bindings are not stored — which is one of the two reasons M7c's emission design
  dropped the cell form. [Notes/ConstructionScheduling.md](Notes/ConstructionScheduling.md) holds
  per-binding state in a `~Copyable` struct that carries noncopyable bindings directly, so they no
  longer need a separate sequential path. What survives for M8.2 to honour is narrower: a
  noncopyable binding can never cross into a child task in either direction, so it and everything
  downstream of it construct on the parent.
- **M6a variant-graph testing.** `@BindType` doubles are stored per key in a `TestBindStore`. A
  noncopyable binding cannot be stored there, so a noncopyable binding is not mockable by the
  current mechanism. Either diagnose that combination, or scope M8 to bindings that are not
  `@BindType` subjects. Needs a decision in M8.3, not later.
- **M7b reachability pruning.** Reachability decides what is constructed; M8.2 decides where it
  lives. A noncopyable binding with no consumers is both a reachability question and an M8.3
  diagnostic — make sure the two do not fire contradictory errors.
- **Toolchain.** `~Copyable` on associated types needs the 6.4 snapshot. Staying in
  generic-parameter territory keeps swift-wire on 6.3.3; the moment a generated protocol wants a
  noncopyable associated type, the floor moves. M8.2 owns that choice.
- **`@_lifetime` is underscored and will be renamed.** M8.4 ships against a spelling with a known
  expiry. The release boundary after M8.3 exists so this risk is isolated.

## When M8 is "done"

- A `@Scoped(seed:)` binding of a `~Copyable` type is constructed per request, consumed by one
  consumer, and never stored in `_WireGraph`.
- A `~Escapable` scoped binding cannot be moved into a `Task` outliving the request, and the
  failure is a lifetime diagnostic naming the seed.
- Every diagnostic in M8.3 has a failing fixture and expected text.
- **`GoldenHarness`'s recording is byte-identical to pre-M8 output.**
- The worked chain serves on at least one runtime in `wire-mvc-examples`.
