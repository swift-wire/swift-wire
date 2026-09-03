# Noncopyable and nonescapable bindings — design note

> **Status:** design space, captured August 2026. **[#341](https://github.com/tachyonics/swift-wire/issues/341) is the source of truth for M8's
> status and carries the build plan**; this note is the *why* it reads from — the worked case, the two
> motivating shapes, and the verified compiler behaviours. The M8.0 spikes ran and cleared the gate;
> nothing after them is built. The point of this note is to
> record what the two features would buy, what the framework would have to emit, and which
> questions gate the work. **Every compiler claim below was verified by compiling to full SIL
> (`swiftc -c -o /dev/null`), not `-typecheck`** — `-typecheck` is unsound for exactly these
> questions, since the move-only checker is a SIL pass and region isolation runs later still.
> Toolchain: Apple Swift 6.3.3 release, `-swift-version 6`, plus
> `-enable-experimental-feature Lifetimes` where noted — except the Phase 0 spikes, which needed
> the 6.4 snapshot. Extended later in August with the worked case, the lifetime-root requirement,
> the `@Provides func` decision, and **the Phase 0 spike results, which cleared the
> region-isolation gate** — see *Spike results* before reading the rest as speculative.

## The two features answer different questions

wire-mvc's [`StreamingResponseTier.md`](https://github.com/tachyonics/wire-mvc/blob/main/Documentation/Notes/StreamingResponseTier.md)
already records the distinction, and it is the thing to hold onto:

- **`~Copyable` is about ownership** — how many owners a value may have.
- **`~Escapable` is about lifetime** — how long a value may live, relative to something else.

They are orthogonal and neither substitutes for the other. `~Copyable` prevents a value being
*shared*; `~Escapable` prevents it *outliving* its source. A `~Copyable` binding can still be
moved somewhere that outlives the scope that made it — moving is precisely what move-only
permits. That is why the two motivating cases below want different features, and why supporting
one does not deliver the other.

## Case 1 — `~Escapable`: resources that must not escape their seed

The motivating shape is a **transaction**. A request-scoped transaction handle is valid until
the request ends and the connection returns to the pool; using it afterwards is a
use-after-return, and it is silent.

Wire already enforces the *graph-level* version of this: the scope-storage rule rejects a
`@Singleton` injecting a `@Scoped`. What it cannot see is the *body-level* version — a handler
moving the transaction into a detached `Task`, or capturing it in an escaping closure. That is
ordinary Swift inside a user's method, not a graph edge, and no amount of discovery will reach
it.

`~Escapable` closes exactly that gap. **Verified** — a nonescapable value with a lifetime
dependency survives suspension, which was the gate this whole direction rested on:

```swift
struct Ctx: ~Escapable {
    private let v: Int
    @_lifetime(borrow o)
    init(_ o: borrowing Owner) { self.v = o.value }
    var value: Int { v }
}

func handler(_ o: borrowing Owner) async -> Int {
    let ctx = Ctx(o)
    let extra = await fetch()      // survives the suspension
    return ctx.value + extra
}
```

And the escape is rejected, with a diagnostic that names the thing the lifetime is bound to:

```
error: lifetime-dependent variable 'ctx' escapes its scope
 note: it depends on the lifetime of argument 'o'
     Task { _ = ctx.value }
```

That is the bug class, caught at compile time, phrased in the user's vocabulary rather than the
framework's. **The framing worth keeping: `~Escapable` extends an invariant Wire already
enforces structurally at graph level into the one region Wire structurally cannot see.**

Note what this does *not* require: none of the concurrency analysis in *Case 2* below. A scoped
binding's lifetime is the seed's by construction — the seed **is** the scope, so it is in scope
at every consumer.

## Case 2 — `~Copyable`: large structures that must not be implicitly copied

The motivating shape is a **large backend data structure** — a decoded payload, an index, a
buffer — where the cost to avoid is the implicit copy, not a correctness violation.

[SE-0527](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0527-rigidarray-uniquearray.md)
is the relevant precedent and it changes the received wisdom about what `~Copyable` is *for*.
`RigidArray` and `UniqueArray` are noncopyable for **performance predictability** rather than
correctness: the proposal's argument is that copy-on-write and dynamic resizing create
"unpredictable complexity spikes," and noncopyability prevents the accidental sharing that
triggers reallocation. Their explicit copy is a concrete method, not a protocol requirement:

```swift
extension [Rigid|Unique]Array where Element: Copyable {
  public func clone() -> Self
  public func clone(capacity: Int) -> Self
}
```

So `~Copyable` in Swift is no longer only the linear/correctness tier — it now also covers
"duplication is meaningful but I refuse to have it happen implicitly." A Wire binding holding
one of these wants to be *moved* into its consumer, never copied.

### The constraint that shapes this in a server

In a server the opportunity is narrower than it first looks, and the reason is concurrency
rather than ownership. **Overlapping requests are separate concurrency domains**, so an
app-scoped binding reached by request-scoped consumers is borrowed concurrently by definition.
Such a binding must be `Copyable`. This is forced, not preferred — boxing solves storage but not
concurrent borrowing, and a noncopyable value inside a box can never be *handed* to a request
scope, only borrowed, which puts a borrow across suspensions in a different domain per request.

So `~Copyable` and scope line up:

| Population | Copyability |
|---|---|
| App-scoped, reached by scoped consumers | **must be `Copyable`** |
| App-scoped, consumed only by other app-scoped bindings at bootstrap | may be `~Copyable` |
| Scoped — constructed at scope entry, confined to one domain, consumed at exit | may be `~Copyable` |

**Verified** — a noncopyable scope struct holding a noncopyable controller survives multiple
suspension points in Swift 6 mode, so the scoped population is viable at the language level.

## The worked case — both features on one chain

The motivating shape in full: a request-scoped provider fetches a large payload, a second wraps
it in a model, and a scoped controller injects the model.

```swift
@Scoped(HttpRequest.self)
@Provides(Backend.data)
func getData(singletonClient: SingletonClient) async throws -> UniqueArray<UInt8> { … }

@Scoped(HttpRequest.self)
@Provides
func backendDataModel(
    @Bind(Backend.data) data: consuming sending UniqueArray<UInt8>,
    request: borrowing HTTPRequest
) -> OwningDataModel { … }

@Scoped(HttpRequest.self)
@Controller
struct Controller: ~Copyable, ~Escapable {
    @Inject var dataModel: OwningDataModel
}
```

Two goals, mapping onto the two features — but not quite the way the shorthand suggests:

- **"Don't implicitly copy the payload or the model."** `~Copyable`, delivered outright, no
  lifetime machinery involved.
- **"Ensure its memory is deallocated."** Already guaranteed by ownership — a `~Copyable` value
  owning a `UniqueArray` is deallocated when it goes out of scope. What `~Escapable` adds is
  deallocation **on time**: it stops the model being moved into a `Task` that outlives the
  request, so per-request memory stays bounded by request lifetime. Worth stating as *"freed by
  end of request"* rather than *"freed"*, because the second is not the part that needs a
  feature.

Incidental syntax finding, **verified**: `sending` is not an ownership specifier and must follow
one on a noncopyable parameter — `consuming sending UniqueArray<UInt8>`. Bare `sending Buf`
gives *"parameter of noncopyable type 'Buf' must specify ownership"*, and the reversed order
gives *"'sending' must be placed after specifier 'consuming'"*.

### `~Escapable` needs a root, and owning your data is not one

The `request:` parameter above is load-bearing, and the reason generalises. `UniqueArray` is
`~Copyable` but **Escapable** — SE-0527 makes those types noncopyable, not nonescapable. So
`getData` returns an owned escapable value, `backendDataModel` consumes it, and
`OwningDataModel` owns its data outright. Without the seed, nothing in the chain borrows
anything.

**Verified** — a `~Escapable` type whose init takes only owned values has no lifetime to depend
on:

```
error: cannot borrow the lifetime of 'data', which has consuming ownership on an initializer
    init(data: consuming Buf) { self.buf = data }
```

`~Escapable` expresses *bounded by something else's lifetime*, and owning a value is precisely
the case where no such bound exists. **So something in the construction chain must borrow the
seed.** With that, it compiles — **verified**:

```swift
struct OwningDataModel: ~Copyable, ~Escapable {
    let buf: Buf
    @_lifetime(borrow request)
    init(data: consuming Buf, request: borrowing HTTPRequest) { self.buf = data }
}

struct Controller: ~Copyable, ~Escapable {
    let model: OwningDataModel
    @_lifetime(copy m)                                   // inherits the model's bound
    init(m: consuming OwningDataModel) { self.model = m }
}
```

### `copy` is compelled, not chosen

Declaring the controller's dependency on the *seed* rather than on the model reads as more
explicit and does not compile. **Verified:**

```
error: lifetime-dependent variable 'self' escapes its scope
 note: it depends on the lifetime of argument 'm'
```

Storing a `~Escapable` value makes `self` depend on **that value**, not on whatever it was
derived from: the compiler tracks the immediate source and cannot know that the `request` in the
signature is the one `m` borrowed. For a stored `~Escapable` dependency, `copy` is therefore the
only correct annotation — which is good news for inference, since Wire cannot get it wrong.

Both together *is* accepted — `@_lifetime(copy m, borrow request)` compiles, **verified**. It is
structurally redundant here (`m` is already bound to `request`, so `copy m` transitively bounds
the controller to it), but it states the seed at every level instead of making a reader walk the
chain. That redundancy costs nothing in generated code; see the emission form below.

## The structural rule

The graph struct holds a reference to every binding, so a `~Copyable` binding cannot be both
graph-held and consumer-held. The rule that falls out:

> **A `~Copyable` binding lives as a local in the frame that owns its lifetime** — the bootstrap
> for app-scoped, the scope-entry closure for scoped. Never a graph stored property.

The same rule at two levels, and it is already the shape M5.4 uses: `requestContext` is
`consuming Builder.RequestContext`, `~Copyable & ~Escapable`, reachable only inside the register
closure and never stored (see the archived
[M5.4 plan](../Archive/M5_4_PLAN.md)). A `~Copyable` controller constructed in that same closure
is the identical pattern one step up.

It also means the support boundary falls on a split the framework already makes:
`_WireRouteContributor_<C>` stores `_wireSubject: C` for `@Singleton` controllers — which must
stay `Copyable` regardless — while M5.4 constructs `@Scoped` controllers per request inside the
thunk, where noncopyable is fine. No new axis is needed.

## The cases, and what the framework does with each

1. **Multiple consuming consumers → error.** Linearity permits one. The diagnostic belongs in
   the plugin, naming both consumers.
2. **One consuming consumer → the binding is exposed to that consumer; the graph does not hold
   it.** The main case, and it generalises: at bootstrap for app-scoped bindings, at scope entry
   for scoped ones.
3. **N borrowing consumers plus at most one consuming consumer → order the borrows first.** More
   common than case 5 below, and satisfiable without any policy surface. Error when no order
   works. This is the one genuinely transplantable piece of pavex's model.
4. **No consumers → the graph would have to hold it,** making `_WireGraph` noncopyable. The blast
   radius is larger than it looks: [`TeardownDesign.md`](TeardownDesign.md) holds
   `let graph: any Teardownable`, and `apply` takes `some WireMVCComposable` — a move-only graph
   breaks the existential immediately. Two options, neither free:
   - **Reject.** Preferred. A `~Copyable` binding with no consumer has little reason to exist,
     and if the motive is "it must be released exactly once," the better answer is making
     teardown a *consuming* consumer, which folds this into case 2. `teardown()` is currently
     `func teardown() async -> [any Error]`, non-consuming and reached by member access, so that
     is a real design change rather than a tweak.
   - **Box it.** **Verified** — a final class can hold a `~Copyable` stored property while the
     reference stays `Copyable`, so the graph is unaffected:
     ```swift
     struct Buf: ~Copyable { var x: Int }
     final class Box { var buf: Buf; init(_ b: consuming Buf) { self.buf = b } }
     struct Graph { let box: Box }        // stays Copyable
     ```
     Costs one allocation and a retain at boot, which barely dents the SE-0527 motive (the point
     was avoiding per-mutation CoW checks, not one startup allocation). **Unverified:** whether
     concurrent borrows through the box are workable under exclusivity — see *Open questions*.
5. **Multiple consuming consumers plus a framework `Clonable` conformance → deliberately
   rejected.** Not because the case is rare, but because it is already served: N consumers each
   wanting their own instance is a generic `@Provides func` specialised per consumer — construct
   N, do not clone one. Cloning a singleton to reach the same place requires a conformance,
   requires the framework to decide when, and hides the count from the user. See
   *Deliberately excluded* below.

## Concurrency is the constraint on `~Copyable`, and depth is not

The limit on `~Copyable` is **not** how deeply scopes nest. It is whether a scope fans out into
multiple concurrently-live children. Stated per *edge* rather than per scope:

> A binding may be `~Copyable` unless it is reached by a consumer in a **concurrently-entered
> descendant scope**.

Consequences:

- A `~Copyable` app-scoped binding consumed by another app-scoped binding at bootstrap is fine.
  "App-scoped must be `Copyable`" is too broad — it is forced only for bindings that scoped
  consumers reach.
- A **sequential** sub-scope below the request (transaction, unit-of-work) adds no new problem,
  and is where `~Copyable` is *most* valuable — a handle consumed exactly once at commit.
- A **fan-out** scope inserted between singleton and request (session, tenant, connection)
  simply inherits the singleton constraint.

So arbitrary nesting adds diagnostic difficulty — the message must name the path from binding to
the boundary-crossing consumer — not a new correctness axis.

**And the compiler already enforces it**, which means Wire needs no structural limit on nesting.
**Verified** — a borrowed noncopyable cannot be fanned out to concurrent children:

```
error: 'r' cannot be captured by an escaping closure since it is a borrowed parameter
  async let a = use(r)      note: closure capturing 'r' here
```

Noncopyability *is* the limit. What Wire could add is a better diagnostic than the raw ownership
error, raised at the graph edge that crosses the boundary rather than at the capture site.

One thing is currently unmodelled: **"this scope is entered concurrently" is implicit**, and
invisible because there is exactly one non-singleton scope kind, so nothing needs to distinguish
it. It becomes observable the moment a second kind exists. That is one bit on the scope
declaration, and the seed is where it belongs — the adapter publishing an HTTP-request seed
knows it is concurrently entered; one publishing a transaction seed knows it is not. Worth
adding when the second scope kind lands, not before. (This is also something pavex's three fixed
lifecycles structurally cannot express — there is nowhere to carry the property.)

## What the framework emits for `~Escapable`

One thing, and it is close to mechanical: Wire generates the initialiser, so Wire emits the
lifetime annotation. Per `StreamingResponseTier.md` the compiler **refuses to infer** between
`borrow` and `copy`, so the annotation cannot be omitted.

It is largely derivable from the `@Inject init`'s ownership modifiers, which Wire already parses:

| Init parameter | Param type escapable? | Emit |
|---|---|---|
| `borrowing seed` | Escapable | `@_lifetime(borrow seed)` |
| `borrowing dep` | `~Escapable` | `@_lifetime(borrow dep)` |
| `consuming dep` | `~Escapable` | `@_lifetime(copy dep)` — **compelled**, see above |
| `consuming param` | Escapable | **nothing** — the result is just Escapable |
| plain `manager: Manager` | Escapable | not mentioned |

**Verified** — all three annotated shapes compile, including naming only the seed among several
parameters, which is the expected constructor form:

```swift
@_lifetime(borrow request)
init(request: borrowing HTTPRequest, manager: Manager) { … }
```

So `borrowing` → always `borrow`, from syntax alone. `consuming` is the only ambiguous case, and
only because distinguishing `copy` from *no annotation* needs the parameter type's escapability,
which is a type fact rather than a syntactic one. Wire knows it for bindings **it generated**;
it may not for an external seed.

**Posture: infer from the modifier by default, and require an explicit annotation only where
inference is genuinely blocked** — a `consuming` parameter whose type Wire has not parsed. Wire
can detect when it does not know. If the generated scope entry *borrows* the seed to construct
the scope's bindings, every binding sees `borrowing` and the whole thing is derivable; at most
one binding can consume the seed.

The failure mode is benign: a wrong inference fails to compile rather than misbehaving. That is
the same posture as the `_check<T>` compiler assertions emitted as a backstop against
reference-to-declaration matching brittleness (see
[BuilderKeyDesign.md](BuilderKeyDesign.md)) — infer aggressively, let the compiler catch the
miss.

### Emission form

Wire has the seed in hand at every scoped binding, so generated initialisers should emit the
compelled dependency *and* the seed:

```swift
@_lifetime(copy dataModel, borrow request)
```

The first component is required; the second is redundant in a rooted chain but makes each
generated initialiser state the seed rather than deferring to the chain. A human writing this by
hand would skip the second — generated code has no reason to.

### Where Wire can root the chain, and where it cannot

Wire only emits annotations into code it generates, which splits the surface:

- **Wire-generated initialisers** — a `@Scoped` struct binding, the scope storage struct. Wire
  can thread a synthetic `borrowing` seed parameter in purely as the lifetime anchor, even where
  the user's type does not otherwise mention the request.
- **A `@Provides func` returning a user-written `~Escapable` type** — Wire cannot. Both the
  function and the returned type's initialiser belong to the user. Wire's only move is to
  diagnose.

**Decision (August 2026): the user takes the seed explicitly.** A `~Escapable` binding produced
by a `@Provides func` must accept the seed as a `borrowing` parameter, exactly as
`backendDataModel` does in the worked case above. Wire's job is to detect a `~Escapable` scoped
binding whose construction chain never borrows the seed, and say so:

> `OwningDataModel` is `~Escapable`, but nothing in its construction borrows the seed
> `HttpRequest` — add a `request: borrowing HttpRequest` parameter.

The deferred alternative is `@Provides` / `@Bind` growing a way for Wire to supply the seed
implicitly. Rejected for now on two grounds: it hides the one relationship the feature exists to
make visible, and the explicit parameter is what makes the user's own `@_lifetime` annotation
writable in the first place — an implicitly-supplied seed has no name to reference.

## Costs

- **Virality, but bounded.** Both features are viral in the way the opaque chain is. The
  difference worth recording: **this virality stops at the scope boundary**, because nothing
  outside the scope can hold the value anyway. The opaque chain propagates through the whole
  graph — that is the trade the README calls its honest headline. These two do not compose the
  way that pairing would suggest.
- **An experimental-feature floor.** `Lifetimes` is experimental and `@_lifetime` is underscored
  (bare `@lifetime` parses but warns). Wire emitting it into user-visible code means every
  consuming package needs `.enableExperimentalFeature("Lifetimes")`, and the spelling changes
  when it stabilises. Acceptable for an opt-in feature; disqualifying if it touched the default
  scope model.
- **Generic-parameter suppression.** Any lifted `_WireGraph<T0…>` parameter or scope-storage
  parameter that could bind a noncopyable or nonescapable type needs suppression, following the
  discipline in wire-mvc's `TestingArchitecture.md` — declare `~Copyable`/`~Escapable` to
  *relax* the constraint on conformers, never to require it.
- **No noncopyable tuples.** **Verified:** `(T, T)` with noncopyable `T` gives *"tuple with
  noncopyable element type 'T' is not supported."* A codegen constraint if generated code ever
  needs to return more than one noncopyable value from a function.

## Backwards compatibility

Both features are per-binding opt-ins, and that has to be an implementation **invariant** rather
than an intention. The mechanism is **conditional emission**: the discovery metadata tells Wire
whether any binding in the graph is noncopyable or nonescapable, and when none is, it emits what
it emits today — no suppression on lifted parameters, no `@_lifetime`, no changed storage model.

Worth pinning with a test rather than a principle:

> A graph containing no `~Copyable` or `~Escapable` bindings produces **byte-identical**
> generated output before and after this work.

A golden-file test over the existing `Fixtures/` is the cheapest guard against the feature
leaking into builds that never asked for it.

Three places it could leak anyway:

- **Generic-parameter suppression — safe, but only if conditional.** Adding `~Copyable` to a
  lifted `_WireGraph<T0…>` parameter *relaxes* the constraint, so existing copyable types still
  satisfy it; it is source-compatible for conformers, per wire-mvc's `TestingArchitecture.md`
  discipline. What it does change is what Wire's *own* emitted code may assume about `T0`. So
  emit suppression only on parameters that actually bind a noncopyable type — unconditional
  suppression would be a silent widening with no user benefit.
- **`Teardownable` — the genuine risk, and it lands in the storage-model work.**
  [`TeardownDesign.md`](TeardownDesign.md) declares
  `public protocol Teardownable { func teardown() async -> [any Error] }`. If resolving
  noncopyable teardown (case 4 above) means changing that requirement, it breaks every conformer
  whether or not they use the feature — the one place the opt-in claim actually fails. **Treat
  "must not change `Teardownable`'s existing requirement" as a constraint on that design
  decision rather than something to discover during it.** Add a separate path instead.
- **The experimental flag reaching Wire's public surface.** If the `Wire` module's own public API
  declares `~Escapable` anywhere — a scope-storage protocol gaining suppression, say — consuming
  packages inherit `.enableExperimentalFeature("Lifetimes")` whether they use the feature or
  not. Keep it out of the public protocol surface, or gate it behind a **package trait**, which
  is already the mechanism in this workspace (`HummingbirdExample` and `VaporExample` enable
  wire-mvc's `ServerTransport` trait in their manifests). A trait also puts the opt-in in the
  manifest rather than leaving it implicit in which types a user happens to declare.

What does **not** leak: every diagnostic in *The cases* above is conditioned on a binding being
noncopyable, so none can fire on code that compiles today; and the toolchain floor does not move
for existing users, provided the new forms are emitted conditionally.

## Deliberately excluded

- **A cloning policy** (`clone_if_necessary`-style). Rejected for case 5's reason above, and
  because there is no vocabulary to build it on: Swift has no stdlib `Clone`. SE-0527's Future
  Directions names a potential `Clonable` protocol, driven by nesting
  (`UniqueArray<UniqueArray<Int>>` fails today because `clone()` requires `Element: Copyable`),
  but even if it lands it will not reach Rust's universality — CoW means most Swift types never
  need it, so conformance stays sparse. **The open question worth watching:** whether `Clonable`
  gets a blanket conformance for `Copyable` types. If it does, it is Rust's `Clone` and a
  framework could call it on any binding; if not, it covers only the performance tier.
- **A structural limit on scope nesting.** Unnecessary — the compiler enforces the fan-out
  constraint directly.
- **Making either feature the default.** Both are per-binding opt-ins. An escapable, copyable
  scoped binding must keep working exactly as today — see *Backwards compatibility* above for
  the invariant that enforces this and the three ways it could be broken.

## Spike results (Phase 0)

Run August 2026 against a faithful mock of the real registration signature from wire-mvc
`Sources/WireMVC/Routing.swift:10-34` — `@escaping @Sendable`, `consuming RequestContext`,
`consuming sending Reader`/`Sender`, `async throws`. Toolchain: **the 6.4 snapshot**
(`swiftly run +6.4.x-snapshot-2026-08-01 swiftc -c`), for the reason in *Toolchain* below.

**All three passed. The region-isolation question that gated this direction is answered.**

1. **Region isolation — clears.** A `~Copyable, ~Escapable` model, rooted on a borrow of the
   `consuming` seed, constructed inside the real `@escaping @Sendable` closure and held across
   suspensions both before and after its construction. Compiles clean, no warnings.
2. **The synthetic anchor works and warns about nothing.**
   `init(data: consuming Buf, ctx: borrowing C)` where `ctx` appears *only* in
   `@_lifetime(borrow ctx)` and never in the body is accepted silently. Wire can thread a seed
   parameter into generated initialisers purely as the lifetime anchor.
3. **The guarantee holds where it matters.** Escaping the model into a `Task` *inside* the
   closure is rejected:
   ```
   error: lifetime-dependent value escapes its scope
    note: it depends on the lifetime of variable 'ctx'
   ```
4. **The full worked chain compiles** — both providers, the controller with the recommended
   `@_lifetime(copy m, borrow ctx)` emission form, and a generated `_WireScope` holding it, all
   inside the closure and alive across a suspension.

### Four findings that change the plan

**The seed is already `~Escapable`.** `HTTPServerCapability.RequestContext` is declared
`~Copyable, ~Escapable` (swift-http-api-proposal,
`Sources/HTTPAPIs/Server/HTTPServerCapability+RequestContext.swift:64`). The chain therefore
roots on the seed naturally — the seed carries its own bound from the server and a scoped binding
borrowing it inherits that. Nothing has to invent a root, which makes the *user takes the seed
explicitly* decision cheaper than it looked: the parameter the user adds is a borrow of a value
that is already lifetime-bound.

**`HTTPServerRouteBuilder.RequestContext` needs `SendableMetatype` — and this is a wire-mvc
prerequisite, not swift-wire codegen.** The real protocol carries `SendableMetatype` on `Reader`
and `ResponseSender` but **not** on `RequestContext` (`Routing.swift:11-15`), and upstream's
`HTTPServerCapability.RequestContext` is a bare `~Copyable, ~Escapable` protocol that does not
imply it. Against that faithful constraint set, any use of a type generic over the seed inside the
register closure warns:

```
warning: capture of non-Sendable type 'B.RequestContext.Type' in an isolated closure [#SendableMetatypes]
```

**Verified not a rebinding artefact** — removing the `let ctx = ctx` line simply moves the warning
to `Model(data: data, ctx: ctx)`. Every scoped binding generic over the seed would trigger it, so
every generated route in a graph using this feature would warn. Adding `SendableMetatype` to the
associated type compiles clean.

So the fix is a **one-line change in wire-mvc**, aligning `RequestContext` with the two associated
types that already carry it. Note it is a *requirement addition on a public protocol*: a conformer
whose `RequestContext` metatype is not sendable would break. Cheap, but it belongs to wire-mvc and
should land before the storage-model work.

**A keyed noncopyable binding needs `BindingKey`/`Bind` suppression, and then hits the SILGen
crash.** The worked case above uses `@Bind(Backend.data) data: consuming UniqueArray<UInt8>` — a
property-wrapped noncopyable *parameter*, which is exactly the combination ROADMAP's
*Known blockers (1.0)* documents. Three stages, all verified on the 6.4 snapshot:

1. **As declared today it fails at the constraint level, before any bug.**
   `public struct BindingKey<Value>` and `public struct Bind<Value>` (`Sources/Wire/BindingKey.swift:31`,
   `Sources/Wire/Bind.swift:22`) have no suppression, so `Buf: ~Copyable` gives
   *"type 'Buf' does not conform to protocol 'Copyable'"* and *"generic struct 'Bind' requires
   that 'Buf' conform to 'Copyable'"*. Both need `~Copyable` on `Value`, and `Bind` must itself
   become `~Copyable` to store one.
2. **With suppression added, the direct use crashes SILGen** —
   [swiftlang/swift#81624](https://github.com/swiftlang/swift/issues/81624), reproduced on
   `6.4-dev` snapshot 2026-08-01: *"While silgen emitFunction … for 'direct(data:)'"*. Confirms
   the ROADMAP's finding that the bug is standing rather than a regression, and that it applies
   to parameters.
3. **The documented `_x.wrappedValue` workaround holds** for the `~Copyable` case and compiles
   clean. ROADMAP's bug 2 ([#91473](https://github.com/swiftlang/swift/issues/91473)) needs
   `~Escapable` **and** a generic parameter, and `UniqueArray<UInt8>` is `~Copyable` but escapable
   and concrete — so keyed noncopyable bindings stay reachable.

The burden falls on **user code**, not Wire's codegen: `@Bind` is transparent at runtime and the
generated bootstrap passes positionally (`Sources/Wire/Bind.swift:1-8`), so it is the user's
provider body that mentions the parameter and crashes. That makes a **plugin diagnostic
worthwhile** — the failure is otherwise a compiler crash with no actionable message, and the
plugin can see the noncopyable-plus-`@Bind` combination before the compiler reaches SILGen.

**Toolchain.** `~Copyable` on an *associated type* is rejected by Swift 6.3.3 (*"cannot suppress
'Copyable' requirement of an associated type"*) and accepted by the 6.4 snapshot. Generic
*parameters* are fine on 6.3.3 — every other spike in this note compiled there. So emission that
stays in generic-parameter territory keeps swift-wire's current floor; only a generated
**protocol** with a noncopyable associated type would move it. Worth knowing before the
scope-storage surface is designed.

## Open questions

1. **Diagnostic quality at depth.** The verified diagnostics are excellent one hop from the
   source. Unknown what they read like when the dependency runs several hops through generated
   code the user did not write.
2. **Concurrent borrows through a class box** (case 4). Exclusivity permits concurrent reads but
   the interaction with per-request domains is untested.
3. **Teardown as a consuming consumer.** The cleanest resolution of case 4, but it changes
   `Teardownable`'s shape and the `any Teardownable` facade. Worth costing before choosing
   "reject" permanently.

## Prior art

Rust has had the precise tool for Case 1 since day one — `&'req` lifetimes express
seed-boundedness directly — and **no Rust DI crate reaches for it**: shaku, lockjaw, and teloc
all use `Arc`. pavex goes furthest, doing genuine borrow reasoning in its generator (reorder
constructors to avoid a clone, clone where permitted, error at code-generation time), and still
declines to push lifetimes into user types; its guarantee covers the constructor call graph, not
handler bodies. So Case 1's guarantee is genuinely unbuilt in any framework — an ecosystem with
a mature borrow checker and a decade of experience concluded that lifetime-parameterising the DI
graph does not pay.

That is the honest caution. What argues the other way here: the diagnostics are better than that
history suggests, the feature is opt-in per binding, and the blast radius is one scope rather
than the graph. See [OpaqueTypesInContext.md](OpaqueTypesInContext.md) for the fuller comparison.

## References

- wire-mvc's [`StreamingResponseTier.md`](https://github.com/tachyonics/wire-mvc/blob/main/Documentation/Notes/StreamingResponseTier.md)
  — the verified `~Escapable` findings this note builds on: moving does not extend a lifetime,
  the container inherits the bound, `@_lifetime` vs `@lifetime`, and the `Lifetimes` flag name.
- [`LinearSenderErrorModel.md`](LinearSenderErrorModel.md) — the linear (correctness-motivated)
  `~Copyable` population, where duplication is forbidden by design.
- [`TeardownDesign.md`](TeardownDesign.md) — `Teardownable` and the `any Teardownable` facade
  that a noncopyable graph would break.
- [M5.4 plan](../Archive/M5_4_PLAN.md) — the register closure and the `consuming`,
  `~Copyable & ~Escapable` `requestContext` this note generalises from.
- [`ScopeAndKeyModelEvolution.md`](ScopeAndKeyModelEvolution.md) — where a per-seed
  "concurrently entered" bit would live.
- [SE-0527 — RigidArray and UniqueArray](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0527-rigidarray-uniquearray.md)
  — `~Copyable` for performance rather than correctness, and the `Clonable` future direction.
