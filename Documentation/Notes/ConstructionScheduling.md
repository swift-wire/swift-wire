# Construction scheduling — design note (M7c)

> **Status:** the implementation design for M7c, dynamic construction scheduling. **M7c.1 — narrow
> retention — M7c.2 — the state struct, sequential — and M7c.3 — the task group — shipped 2026-09**; their
> outcomes are recorded under their gates in *§ Suggested sequencing*, with the pre-existing bugs and the
> toolchain findings each surfaced. **M7c.4 was rewritten before it started and then shipped** — § *The
> scheduled region* settles how much of one graph the group spans, and the answer took that step from five
> emitter translations to one change of scope: fifteen graphs schedule where two did, on 44 cells across
> the whole corpus. M7c.5 onward keep their trigger. It
> **supersedes the
> `AtomicState<T>`-cell sketch** in [EffectAwareResolution.md](EffectAwareResolution.md) *§ Strict
> per-level vs dynamic ready-as-deps-resolve*; that note stays as the conceptual framing (the levels
> model, the prior-art map, the semantic questions), this one carries the shape the emitter should
> actually produce and why the cell form was dropped. **The trigger is unchanged** — M7c still lands
> when construction latency is worth optimising, or earlier if an adopter forces init-failure partial
> teardown. Nothing here argues for scheduling it. Every Swift-level claim below was verified against
> the repository's toolchain floor (6.3.3) with a compiling fixture, not reasoned from the language
> reference; the error texts quoted are real. **Verifying against the floor alone turned out not to be
> enough**: § "What `sending` can and cannot promise" records where the 6.4 snapshot `.swift-version` also
> pins disagrees, why it is right to, and what that supersedes in this note's own sketch.

## Why the cell sketch was dropped

`AtomicState<T>` was a `final class` holding a `Mutex<State>`, shared across the closures and Tasks that
read it (it has since been retired — see the references). Its generic parameter is constrained `Value: Sendable`, and
that constraint is the problem: it applies to **every scheduled binding**, whether or not that binding
ever crosses a task boundary.

Two consequences, and they compound:

- **Non-Sendable bindings.** Today's bootstrap body is plain `let` locals in one frame, so nothing
  crosses an isolation boundary and no binding needs `Sendable`. A graph binding a `final class Counter
  { var n = 0 }` compiles clean under `-strict-concurrency=complete`. Put that binding in a cell and it
  is `type 'Counter' does not conform to the 'Sendable' protocol`. A wholesale swap therefore rejects
  graphs that compile today.
- **Noncopyable bindings (M8).** A generic parameter is implicitly `Copyable`, so a `~Copyable` binding
  cannot enter a cell at all — and M8.2's model is that such a binding is *not stored* anyway
  ([M8_PLAN.md](../M8_PLAN.md), *the storage model*). [M8_PLAN.md](../M8_PLAN.md) § *Risks / interleaves*
  already anticipates this and asks, at minimum, that noncopyable bindings take the sequential path.

Neither partition ever closes — non-Sendable types stay legal, and M8 is *adding* noncopyable bindings —
so the cell design commits the emitter to two shapes coexisting in one function body, permanently, with
values crossing between them. The interaction surface (builder folds, scope-entry thunks, existential
aliases, member injections, each having to work in both and across the seam) is where the cost would
actually land, and it is the reason to prefer the alternative below.

## The mechanism — one `~Copyable` state struct, owned by the parent

All per-binding state lives in a single `~Copyable` struct in the bootstrap frame, mutated only by the
task draining the group. Child tasks do not schedule; they return a marker, and the parent applies it and
fires the dependents.

```swift
enum State<Value: ~Copyable>: ~Copyable {
    case unmarked, pending, resolved(Value), consumed

    borrowing func isUnmarked() -> Bool { switch self { case .unmarked: return true; default: return false } }
    borrowing func isResolved() -> Bool { switch self { case .resolved: return true; default: return false } }

    mutating func asPending() -> Bool {
        guard isUnmarked() else { return false }
        self = .pending
        return true
    }
    mutating func asResolved(_ value: consuming Value) { self = .resolved(value) }

    /// `sending` is what would let a *non-Sendable* payload leave for a child task.
    /// **It cannot be spelled here** — see § "What `sending` can and cannot promise".
    /// `.consumed` records that the cell surrendered *its* reference, which is only
    /// the same thing as *the only* reference when `Value` is noncopyable.
    mutating func take() -> Value {
        switch consume self {
        case .resolved(let v): self = .consumed; return v
        default: fatalError("unreachable")
        }
    }
}

extension State where Value: Copyable {
    /// Borrowing read for a copyable payload. `guard case .resolved(let x) = cell`
    /// consumes the *enclosing* ~Copyable struct; this does not.
    borrowing func value() -> Value? {
        switch self { case .resolved(let v): return v; default: return nil }
    }
}
```

The generated per-graph struct then carries one cell per binding, one `addX` per binding, and one
`update` over the child-result marker:

```swift
enum GraphTaskResult: Sendable { case pool(DatabasePool), cache(Cache) }   // Sendable AND Copyable

struct BuildingGraph: ~Copyable {
    var poolState: State<DatabasePool> = .unmarked
    var cacheState: State<Cache> = .unmarked
    var dataState: State<Data> = .unmarked

    mutating func addPool(_ g: inout ThrowingTaskGroup<GraphTaskResult, any Error>) {
        guard poolState.asPending() else { return }
        g.addTask { .pool(try await makePool()) }
    }
    mutating func addData(_ g: inout ThrowingTaskGroup<GraphTaskResult, any Error>) {
        // Dep check BEFORE the pending transition, so a dependent that is not yet
        // ready leaves itself schedulable by whichever dep resolves last.
        guard let pool = poolState.value(), let cache = cacheState.value() else { return }
        guard dataState.asPending() else { return }
        dataState.asResolved(Data(pool: pool, cache: cache))   // sync: inline on the parent
    }
    mutating func update(_ r: GraphTaskResult, _ g: inout ThrowingTaskGroup<GraphTaskResult, any Error>) {
        switch r {
        case .pool(let p): poolState.asResolved(p); addData(&g)
        case .cache(let c): cacheState.asResolved(c); addData(&g)
        }
    }
    consuming func finalise() -> _WireGraph { … }   // one `take()` per stored binding
}

try await withThrowingTaskGroup(of: GraphTaskResult.self) { group in
    var building = BuildingGraph()
    building.addPool(&group)
    building.addCache(&group)
    for try await result in group { building.update(result, &group) }
    return building.finalise()
}
```

What this buys over the cells:

- **No synchronisation.** Only the parent mutates, so there is no `Mutex`, no `@unchecked Sendable`, and
  no CAS. `asPending()` survives purely as an idempotency guard — several dependents can trigger the same
  `addX` — not as a concurrency primitive.
- **`Sendable` attaches to the task boundary, not to the binding.** A non-Sendable binding lives in a
  cell, is read as a dependency and constructed inline, across `await` points, under
  `-strict-concurrency=complete`. It simply never enters a task.
- **Noncopyable bindings need no separate emitter.** `State<Value: ~Copyable>` holds them, `take()` moves
  them into a consuming consumer. Same structure; they are just never scheduled into a task.
- **The unwrap problem concentrates.** Today every binding is a `let` with a static guarantee; under
  cells the return needs N unwraps. Here it is one `consuming finalise()` and a single `fatalError` inside
  `take()`.

Verified: one `BuildingGraph` carrying a Sendable async binding, a non-Sendable class binding, a
`~Copyable` binding and a non-Sendable consumer compiles (full SIL, not `-typecheck`) and runs, with a
20 ms and a 120 ms binding built concurrently and their dependent firing the moment both land, clean
under `-enforce-exclusivity=checked`.

### Spellings that are load-bearing

Three noncopyable rough edges. **All three pass `-typecheck` and fail at `-c`** — which is a test-design
constraint for the milestone: rendering goldens and diffing text would not catch any of them, so the
gates below must compile the generated output.

| Written naively | What 6.3.3 says | Use instead |
|---|---|---|
| `guard case .unmarked = self` in a `mutating`/`borrowing` method | `'self' is borrowed and cannot be consumed` | `switch self` inside a `borrowing func` |
| `case .unmarked, .pending, .consumed:` | multi-pattern case labels over a noncopyable value are `not implemented` | `default:` |
| `guard case .resolved(let x) = someCell` on a cell of a `~Copyable` struct | `missing reinitialization of inout parameter 'self' after consume` | `value()` / `take()` / `isResolved()` |

That third one consumes the *enclosing* struct, not just the cell, and does so even when the payload is
copyable. So the emitter has exactly three read forms: `isResolved()` for readiness, `value()` for a
copyable dependency, `take()` for a move.

### What `sending` can and cannot promise

The sketch above put `sending` on `take()`, arguing that the `.consumed` transition proves the cell "has
provably surrendered its only reference". **That argument is wrong for a copyable payload, and the newer
toolchain is right to reject it.** Established by probe against both toolchains this package pins — 6.3.3
(the CI floor) and the 6.4 snapshot `.swift-version` names:

| `take()` declared on | 6.3.3 | 6.4 |
|---|---|---|
| a **concrete** noncopyable payload (`enum TokenCell { case resolved(Token) }`) | accepted | **accepted** |
| a **concrete** copyable payload (`case resolved(Counter)`, a class) | accepted | **rejected** |
| the **generic** `<Value: ~Copyable>` cell above | accepted | **rejected** |

The mechanism is that `~Copyable` on a generic parameter is a **suppression, not a requirement**. It
removes the implicit `Copyable` constraint, which *widens* the admissible set rather than narrowing it —
`AnyCell<Counter>` and `AnyCell<Int>` are legal instantiations, verified. Swift cannot express "this
parameter must be noncopyable".

That decides everything else. A `sending` result is a contract the body must prove, and the only way a
value enters a cell is `asResolved(_ value: consuming Value)`:

- **noncopyable payload** — `consuming` transfers *the* reference; the language forbids a second existing,
  so the value `consume self` pulls back out is provably unaliased and the contract holds;
- **copyable payload** — `consuming` transfers *a* reference. For a class that is a retain, and the caller
  may keep its own and go on using it, so the extracted value may be aliased from the caller's region.

A generic body is checked once for every instantiation, so it must hold in the worst case — hence the
third row. 6.3.3 accepts even the second row, where there is no instantiation freedom at all and the
promise is plainly false; it was simply not running the check. **6.4 is correctly stricter, and precisely
so** — it accepts exactly the case that can be proven.

**This is an acknowledged language gap rather than a toolchain quirk**, which is worth knowing before
anyone files it. Asked about consuming a noncopyable property and returning it `sending`, John McCall's
answer on the forums is exactly this situation ([thread][disc-thread]): *"You cannot currently declare
that a property has to hold a disconnected value — we'd like to be able to express that, but it's not in
the language yet."* A cell is a property holding a value, and it cannot say the value is disconnected, so
`take()` cannot promise it. The recommended workaround is `nonisolated(unsafe)`, applied narrowly where
the disconnectedness really is maintained — which is what § *A boxed payload, not a second cell* below is.

[disc-thread]: https://forums.swift.org/t/swift-6-consume-optional-noncopyable-property-and-transfer-sending-it-out/72414

Two consequences, neither of which changes what M7c should build:

- **The cell ships without `sending`.** It costs M7c.2 nothing, which has no task boundary to cross.
- **`sending` is unavailable to any generic cell, ever, under today's language.** When M8 makes
  noncopyable bindings real, a cell that carries `sending` has to be **monomorphised** — a concrete
  `_WireState_<Binding>` emitted per noncopyable binding — because only concreteness pins the payload.

### What this permits at the task boundary (M7c.3)

The constraint that actually binds M7c.3 is narrower than "non-Sendable cannot be transferred", and it is
about *where* the transfer is written rather than about the cell. Probed on 6.4:

- a value taken from a cell **and sent from the same scope** transfers fine, non-Sendable and copyable
  included — region isolation can see it is disconnected;
- the same value sent from inside `mutating func addX(_ g: inout ThrowingTaskGroup…)` — **the shape this
  note proposes** — is rejected, because `self` is `inout` and so everything taken out of it belongs to
  the *caller's* region. Breaking that link across a function boundary is exactly what `sending` on
  `take()` would do, and cannot.

So with the cell as it ships, and until M8, a binding is schedulable into a child task iff its type is
`Sendable`. The plan survives; what does not survive is the claim that the cell buys non-Sendable
transferability.

**Three routes, chosen before M7c.3 started rather than inside it. M7c.3 took route 1**, and the reasoning
is recorded under its gate in *§ Suggested sequencing* — the short of it is that route 3 buys back a case
no graph in the corpus has, and the *product* direction it cannot reach is the one that actually binds.

1. **Accept it.** Keep `addX` a method, schedule only `Sendable` bindings into tasks, and construct
   everything else inline on the parent — the fallback this note already describes. Costs nothing and
   builds nothing.
2. **Inline the scheduling into the group body.** A value taken from a cell and sent from the *same*
   scope transfers fine, non-Sendable included, because region isolation can see it is disconnected.
   Buys the non-Sendable case back and gives up the state struct's method structure, which is most of
   what makes the emission flat and mechanical.
3. **Box the payload** — below. Keeps the method structure *and* buys the non-Sendable dependency case,
   with no change to the cell at all. Re-verified compiling and running on both toolchains when M7c.3 was
   built, so it is a change M7c.4 or an adopter can make without re-establishing anything; what it needs
   first is a graph that wants it.

### A boxed payload, not a second cell

The route the forum answer points at, and the one SE-0538 `Disconnected<Value>` standardises — **accepted
and under implementation** (`swiftlang/swift#89597`), and already vendored in wire-mvc as
`WireDisconnected` for M5.5.

The shape to reach for is *not* a second kind of cell. It is the cell above, unchanged, with the payload
wrapped:

```swift
var _wireState_logger: _WireBindingState<WireDisconnected<Logger>> = .unmarked

mutating func _wireAdd_service(_ g: inout ThrowingTaskGroup<GraphTaskResult, any Error>) {
    guard _wireState_logger.isResolved() else { return }
    guard _wireState_service.asPending() else { return }
    let boxed = _wireState_logger.take()   // plain WireDisconnected — no `sending` needed
    let logger = boxed.take()              // sending Logger — the box's own contract
    g.addTask { .service(try await makeService(logger: logger)) }
}
```

`Logger` is a non-Sendable class moved out of a cell, from inside a `mutating` method holding the group
`inout` — the shape § *What this permits at the task boundary* shows being rejected. Verified to compile
on **both** toolchains, and to run. The control, the same graph with the payload unwrapped, is rejected.

The cell never promises `sending` and needs no change, because it does not have to: the box's `sending`
result is a contract verified in *the box's* body against its `nonisolated(unsafe)` storage, and that
verification does not care where the box came from. The cell stays honest and the box does the single
unsafe thing, once.

**Composition is not merely tidier here — it is what makes the invariant checkable.** A bespoke
`sending`-capable cell would rest on "this type must never offer a borrowing read", which is a promise its
author keeps; adding a `value()` to such a type compiles. Wrapping makes the payload noncopyable, so the
cell's existing `extension … where Value: Copyable` takes the read away by construction:

```
error: referencing instance method 'value()' on '_WireBindingState'
       requires that 'WireDisconnected<Logger>' conform to 'Copyable'
```

Box a binding and it *cannot* be copy-read. That is the property the whole design depends on, and it stops
being something the emitter has to be careful about. The boxing site is where disconnectedness is proven,
and it is checked there: `WireDisconnected(makeLogger())` type-checks because the value is fresh, and a
value that had been read out of another cell would be refused by `init(_ value: consuming sending Value)`.

What it buys stays narrow, and worth stating exactly: **a non-Sendable, single-consumer *dependency*
moving into a child task whose *product* is `Sendable`.** The return direction is untouched —
`ChildTaskResult: Sendable` still applies — so a non-Sendable async binding still constructs inline on the
parent. And a boxed binding has exactly one consumer by construction, which is now the type system's rule
rather than the emitter's. So the decision this route asks for, whenever it is taken, is per binding and
about the *payload*: box the ones whose single consumer is built in a child task. Consumer count Wire computes from its edges; "is this consumer
built in a child task" is the scheduler's call, so the two are decided together.

**This is consistent with *§ the upstream ask*'s rejection of a Sendable box, not a reversal of it.** What
was rejected there is a *copyable* box whose soundness "would rest on 'the generated scheduler takes
exactly once and never aliases', an invariant asserted by codegen". `WireDisconnected` is `~Copyable` and
linear with no copy-out, so the invariant is carried by the type — the ground its own doc already stands
on. SE-0538 argues it identically, and **refuses a borrow accessor for exactly the reason the ordinary
cell cannot promise `sending`**: "any such accessor is unsound given the unconditional `Sendable`
conformance". The residual cost is that `nonisolated(unsafe)` stops the compiler checking *inside the
box*, which is why the box stays the vendored, audited, already-shipping one rather than something codegen
invents.

## Init-failure partial teardown

The half deferred from M4 ([TeardownDesign.md](TeardownDesign.md) *§ Init-failure partial teardown*) falls
out of this structure rather than needing its own design. The `do`/`catch` goes **inside** the group body,
where `building` is still live; the walk is the static reverse topological order filtered to cells that
reached `.resolved`, reusing `teardownCallLines` with cell reads in place of locals. The concrete-type
capture that makes `@Teardown` work on an `@Singleton(as:)` binding is unaffected. Verified compiling.

One ordering detail: `withThrowingTaskGroup`'s own `catch` does `cancelAll()` then
`awaitAllRemainingTasks()`, but that runs *after* a `catch` written inside the body. If a teardown action
would close something a sibling task is still using, the generated code must do its own `cancelAll()` and
drain first rather than relying on the enclosing machinery.

## The scheduled region — how much of one graph the group spans

> **Settled 2026-09, before M7c.4, and it changes what M7c.4 is.** M7c.3's trigger decides *whether* a
> graph is scheduled. It says nothing about *how much of it* is, and the answer it inherited — all of it —
> is what made M7c.4 look like five emitter rewrites. It is not.

M7c.3 argued that a group only pays where two async bindings can overlap, and narrowed the trigger on
exactly that ground. The same argument runs one level down and was never applied there: inside a
scheduled graph, a binding that cannot overlap with anything gains nothing from a cell either. The
corpus says how much that costs. Surveyed over all twenty graphs, with the scheduled region taken as the
async bindings plus everything transitively downstream of them:

| graphs | bindings | async | region | frontier |
|---|---|---|---|---|
| `_WireGraph` and 11 `*Fixture_bind*` variants | 109–122 | 3 | **4** | **0** |
| `SchedulerContainer`, `ParallelScheduler` | 4–8 | 2 | 3 | 1 |
| 4 container graphs | 3–4 | 0 | 0 | — |

**Four bindings out of a hundred and ten.** The async bindings in the corpus are near-leaves, and the
*frontier* — prefix bindings a scheduled binding reads across the seam — is **zero**: nothing crosses at
all. The survey seeds from *every* async binding rather than from Overlap alone and does not trim the
serial suffix, so four is an upper bound on the group region under the rules below, not an estimate of
it. Against a machinery cost measured on the two scheduled graphs at ≈46 lines fixed per graph plus ≈6.75
per scheduled binding, converting whole graphs costs those twelve about **790 lines each**; converting the
region costs about **73**. That is the whole of the ~9,000-line objection to M7c.4, and it is an artefact
of the scope, not of the design.

### Three regions, from the dependency order

The split is prefix / group / suffix, and both boundaries are computed from the DAG — there is no timing
model in it. Let **Overlap** be the async bindings that have at least one *independent* async partner,
which is the set `hasIndependentAsyncPair` already walks for the trigger.

- **Prefix** — every binding with no Overlap ancestor that is not itself in Overlap. Downward-closed (an
  ancestor of a prefix binding is a prefix binding), so it is a valid topological head and stays today's
  linear `let` chain. **It may contain async bindings**: a source everything else waits on is serial by
  definition, and putting it in a group would buy a child task the parent immediately blocks on.
- **Suffix** — every binding that transitively depends on *all* of Overlap. Upward-closed, and strictly
  serial: nothing is still outstanding by the time one of these can start. Also today's linear chain, run
  after the drain.
- **Group** — the rest. Overlap, plus the descendants that can begin while some other branch is still in
  flight, which is exactly the population the cascade exists for.

The three partition the graph, and because the prefix is downward-closed and the suffix upward-closed the
emitted body stays one shape: **chain → group → take each cell into a local → chain**. After the drain
every value is a local again, which is the same ground the linear chain has always stood on.

**One group, not several.** The middle can in principle contain a serial choke point with parallel phases
either side, and splitting there would shrink the cell count further. It is not worth it: a choke costs a
single group nothing (the group simply has one task in flight at that moment), while a second group costs
another frame, another marker enum, and cells that have to survive across both regardless.

### What this does to M7c.4

The constructs M7c.4 owns were surveyed the same way — how many instances fall *inside* the region rather
than anywhere in the graph:

| construct | in region / in graph, per large graph |
|---|---|
| builder aggregates | 0 / 3 |
| scope-entry thunks | 0 / 9 (default graph only) |
| existential promotions | 0 / 2 |
| member injections | 0 / 5 |
| `@Teardown` | 0 / 4 |
| opaque (`some P`) lifts | 0 / 6–7 |

**Every one of them is zero on this corpus.** So the exclusion predicate does not need five new emitters
to unblock these twelve graphs; it needs one change of scope — from "this construct appears in the graph"
to "this construct appears in the *group region*" — after which all twelve qualify with no new emission at
all.

That is a claim about *what the corpus is asking for*, and nothing more. It is not a claim that a
construct cannot land in the region: an aggregate whose contributors are async is downstream of them by
definition, and any of the six can be reached from an async binding by an edge someone adds tomorrow. So
the translations are not cancelled; they become **demand-driven**, and the question that matters is what
each one costs *when* it is demanded. Probed rather than argued, since two of the six turn out to be much
cheaper than the plan assumed and one much dearer:

| construct in the region | what it needs | status |
|---|---|---|
| **collected / mapped aggregate** | nothing — it is a single expression, and `asResolved` takes it | **already works**; the clause only ever excluded `.builder` |
| **builder aggregate** | the `@resultBuilder` local function nests *inside* `addX`, over the locals the guard already bound, then `asResolved(_wireFoldX())` | **verified compiling and running on both toolchains**; ~10 lines of emitter |
| **`@Teardown`** | nothing — the closure is built at the end of the bootstrap over each binding's local, and after the seam every binding is a local | clause is probably deletable outright, not merely region-scoped |
| **member injection** | nothing, for the same reason, and it *cannot* be region-scoped anyway (below) | same |
| **existential promotion** | the shared `any P` alias needs a definition site: either its own cell or an inline coercion at each consumer | a real translation, unprobed |
| **scope-entry thunk** | an *escaping* closure whose captures must be taken out of cells before it is formed — and whose capture set is `.scopeCapture` dependencies, which `constructionDependencyLocals` excludes, so the readiness guard does not cover them | the hard one |
| **opaque (`some P`) lift** | the lifted generic parameter mirrored onto the building struct and inferred through both it and the bootstrap | the other hard one |

So your example — an aggregate with async contributors — is the case most likely to arise in real code and
it is the *cheapest* of the set, not a counterexample. The two that stay expensive, scope-entry thunks and
opaque lifts, are the two M7c.3's plan already called the highest-risk seams.

Member injection is worth stating separately, because it constrains the split rather than being
constrained by it. **It is a post-construction block by design and cannot be region-scoped.** Its
parameters are deliberately *not* graph edges (`Graph.swift`: "post-init delivery, so excluded from graph
edges. Cycle through these is legal") — which is the whole point of `@Inject weak var`. So an injection
can read across regions in either direction and must stay after everything is constructed, which is where
it already is. Plainly: the prefix is downward-closed *under construction edges*, and injection edges are
not construction edges.

### The cost of the region change, which is not zero

Narrowing the predicate to the region makes the exclusion **shape-sensitive**. Today "this graph has a
builder fold" is a property of code someone wrote, and is stable. After the change it becomes "an async
binding happens to reach a builder fold", which an added edge can flip either way, silently — the graph
simply keeps the linear chain and nobody is told why. The silence itself is not new (an excluded graph is
silently unscheduled today), but what determines it moves from a declaration to a topology, and topology
is the thing a developer changes without meaning to.

No diagnostic is proposed: a "this graph could have been scheduled" note is exactly the never-quiescing
build warning M7c.1 already rejected once. The place this belongs is the **`_WireGraph.json` build-time
dump** in the ROADMAP's *Pre-1.0 polish*, which already exists to answer "what did Wire decide about my
graph" and which M7b already gave the pruned set to say. It is recorded here so the connection is made
when that lands rather than rediscovered.

## What it costs

Cascade decisions run on the parent's drain loop instead of firing inside the child that resolved the
dependency. The hop is free — the parent is suspended on the iterator anyway — but sync bindings now
construct on the parent, so two *expensive sync* bindings downstream of two different async bindings run
serially rather than concurrently in their child tasks. Wire has no cost model to know when that matters,
and the trade buys non-Sendable and noncopyable support, so it is the right one.

Generated volume goes up: a cell, an `addX` and an `update` arm per *scheduled* binding, against one `let`
today, plus a marker case and a `Sendable` assertion for each binding that crosses the task boundary. It is
flat and mechanical, and it is the same shape for all four binding categories. Two things bound it, and
they are the same argument applied at two scales — § *The scheduled region* carries both. Between graphs:
only a graph with two async bindings that can overlap is scheduled at all, which on the integration corpus
is two `@Container`s. Within a graph: only the region that can overlap is scheduled, which on the corpus'
large graphs is four bindings out of a hundred and ten.

## Suggested sequencing

Same discipline as the other milestone plans — each sub-step runs end to end and has a gate; highest-risk
seam first. **Every gate compiles the generated output**, per the `-typecheck`-is-not-enough finding above.

- **M7c.1 — narrow retention.** `_WireGraph` stores the root set plus `@Teardown` bindings plus facade
  borrows; everything else becomes a bootstrap local only. No scheduler yet, so the construction body
  stays the linear chain. **Gate:** the integration corpus builds unchanged apart from the properties that
  disappear, with a diagnostic naming each dropped property and the `allowUnused: true` fix-it; goldens
  re-recorded once, deliberately.

  **Gate: met, with the diagnostic's *form* settled against this plan's wording.** `Sources/WireGenCore/Retention.swift`
  carries the retained set — `declaredRoots` reused verbatim, plus `@Teardown`, plus opaque lifts, plus
  what generated code reads off the graph — and `resolveStoragePatches` decides each graph's stored-property
  block and memberwise init once the whole file exists. **569 stored properties leave the corpus**; the
  default graph goes from 123 to 79, and the golden is re-recorded at the same 6,417 lines.

  Four things the plan did not anticipate, each of which changed the implementation:

  - **A build warning per dropped property was the wrong instrument.** M7b.3's pruned set is *empty* once
    an app is migrated, so its warning quiesces; here, dropping the property is the normal case for every
    non-root binding, so the same shape would leave a well-formed app carrying one warning per binding
    forever. The information moved to an `@available(*, unavailable, message:)` computed stub, which puts
    it where it is actionable — the compiler reports it **at the user's own `graph.x` read site**, with the
    property name, the annotation and the declaration's `file:line` — and says nothing at all to an app
    that does not read the property. It stores nothing, is absent from the memberwise init and from
    `Sendable` derivation, and is emitted on one line, so the narrowing costs no generated volume.
  - **The retained set is scanned from the emitted text, not re-derived.** Four emitters read properties
    off a graph and each prunes its own read set differently; re-deriving the union would be four copies
    of existing logic kept in step by hand. Scanning is correct by construction, and the asymmetry makes
    it safe rather than merely convenient — **over-retention costs one stored field, under-retention is a
    compile error in generated code**, and a textual scan cannot under-fire. The `<local>.` half must be
    global: a variant's facade takes `wireGraph _wireGraph: _BorrowFixture_bindMockWireGraph`, so the name
    comes from the parent graph while the type is the variant's.
  - **Opaque (`some P`) bindings stay stored, deliberately.** They lift a generic parameter onto the
    struct, so the graph's *type* names them — dropping one is a change to the graph's type identity, which
    every `wireGraph:` parameter and bootstrap return type spells, not a change to what it retains.
  - **Two pre-existing bugs surfaced, both of which made `allowUnused:` silently inert.**
    `specialiseBinding` (`Graph.swift`) rebuilt a specialised provider without carrying `allowUnused`
    across, so a generic `@Provides(allowUnused: true)` template's specialisation — which is the binding
    the app actually holds — was neither a reachability root under M7b nor a stored property here. And
    `AggregateProxySynthesis` never set the `allowUnused: true` that `ContributorProxySynthesis` sets for
    an explicit reason (a synthesised proxy is anchored at its *subject's* location, so any diagnostic
    about it names a type the user did not write and cannot annotate); the divergence was invisible until
    the retention diagnostic started printing a fix-it no user could act on. Both fixed, both with the
    reasoning recorded at the site.

  The corpus migration is 13 annotations — smaller than feared, because M7b.3 had already annotated
  everything read through `graph.x` that was *also* unreachable. The residue is exactly what this note
  predicted: a binding reachable via a consumer **and** read by user code.
- **M7c.2 — the state struct, sequential.** Emit `State`/`BuildingGraph`/`addX`/`finalise` and drive it
  with *no* task group: the cascade runs entirely inline, which is the wholly-sync degenerate case. This
  isolates every noncopyable spelling and the three read forms before any concurrency is involved.
  **Gate:** a fixture graph over all four binding categories constructs correctly; `GoldenHarness/` output
  is byte-identical for graphs with no async binding, because those keep the linear chain.

  **Gate: met, and exceeded on the byte-identical half — *every* pre-existing graph is unchanged, not only
  the sync ones.** `Sources/WireGenCore/ConstructionSchedulingEmission.swift` carries the per-graph
  trigger, the building struct and the driver, over `Wire._WireBindingState`; the golden grows by 97 lines
  with **zero deletions**. The full suite compiles and runs on both the 6.3.3 floor and the 6.4 snapshot,
  which is the gate that matters here: every spelling this shape avoids passes `-typecheck`.

  Three findings, the first of which changed the plan:

  - **The staged population is empty.** This sequencing assumes M7c.2 converts async graphs while M7c.4
    later adds the interacting constructs — but slicing every bootstrap body in the golden shows all 13
    async-containing graphs *also* carry builder folds, member injections and existential aliases, and
    **no graph is async-and-clean**. So the trigger is `async AND none of the constructs M7c.4 owns`
    (builder folds, scope-entry thunks, existential promotions, member injections, `@Teardown`, opaque
    lifts), and the corpus gained `SchedulerContainerExample.swift` — a `@Container`, because the trigger
    is per graph — so a real, compiled graph takes the new path instead of the step proving nothing.
    Every exclusion is one clause of one predicate, so M7c.4 relaxes it by deleting clauses.
  - **The cells carry a `_wire` prefix**, not this note's bare `poolState`. The `add` methods reference
    module-scope declarations by bare name, and Swift checks the enclosing type's members before module
    scope — the same shadow that put `_wireBootstrap` at module scope rather than on `_WireGraph`. A cell
    named `appNameState` would still collide with a user binding whose property name is `appNameState`; a
    `_wire`-prefixed one cannot.
  - **`finalise()` is not emitted.** The memberwise init takes from the cells inline
    (`_WireGraph(pool: building._wireState_pool.take(), …)`). *What* is stored is M7c.1's deferred
    decision, resolved only once the whole file exists, so a `finalise()` body would have needed a third
    patch point to stay in step with it.
- **M7c.3 — the group.** Async bindings move into `group.addTask`, the parent drains and cascades.
  **Gate:** a fixture with a fast and a slow independent async binding plus a dependent of the fast one
  shows the dependent starting before the slow one finishes; `-enforce-exclusivity=checked` clean.

  **Gate: met.** `Tests/IntegrationTests/ParallelSchedulerExample.swift` is a `@Container` whose
  `FastDependent` is constructed while `makeSlowSignal` is still suspended, and the emission around it is
  a `_XWireTaskResult` marker enum, an `addX(_ _wireGroup: inout ThrowingTaskGroup<…>) throws` per binding
  and a `_wireUpdate` over the marker. Only the two scheduled graphs moved; the rest of the golden is
  byte-identical. **`GroupResult` is not `Sendable`-constrained**, so the graph the closure returns can
  hold a non-Sendable binding — verified, and it is what lets `SchedulerContainer` keep its
  `SchedulerCounter` while its two async bindings run in child tasks.

  Four things this step settled, three of them departures from the plan above:

  - **The trigger narrowed to graphs a group can win on: two async bindings with no dependency path
    between them.** M7c.2's predicate was "contains an async binding", which was right while the cascade
    ran inline and wrong the moment it costs a group: one async binding in a group is one child task the
    parent immediately blocks on, and a *chain* of async bindings is sequential however it is scheduled.
    Both would take the `Sendable` requirement below and gain nothing. The consequence is that M7c.2's
    sequential state struct no longer has a population — a graph either schedules or keeps the linear
    chain — which is the right end for a staging step, and it took `EffectAwareEmission`'s async fixtures
    back to the `let` form they had before M7c.2.
  - **The `Sendable` requirement is asserted, not decided.** `ChildTaskResult` is `Sendable` *and*
    `Copyable` on 6.4 (re-verified: a `~Copyable` result is "requires that 'Linear' conform to
    'Copyable'"), and `addTask`'s closure is `sending`, so a scheduled binding's product and every
    dependency its closure captures must be `Sendable`. Wire reads syntax and has no conformance
    information at all — implicit derivation, an extension and an external type are each invisible — so it
    cannot restrict the trigger to bindings it knows are safe without making the feature inert. What it
    can do is put the resulting error where the fix goes: each graph emits a `_wireSendableChecks…`
    function, never called, holding one `_check<T: Sendable>(_: T.Type)` per binding that crosses the
    boundary, each wrapped in `#sourceLocation` — the instrument `_WireKeyChecks.swift` already uses to
    attribute a keyed binding's type mismatch to the user's own line. The check is emitted in the graph
    file rather than in `_WireKeyChecks.swift` because the requirement is a property of *this graph's
    construction plan*, and that file is rendered from a flat binding list with no notion of one. This is
    the one user-visible edge of the milestone, and it is bounded by the trigger: a graph with a
    non-Sendable async binding qualifies only if it also has a second, independent async binding.

    **Which of the two failures the assertion actually improves is worth stating, because it is only one
    of them.** For a non-Sendable *dependency* it is the whole diagnostic: the build reports
    `ParallelSchedulerExample.swift:38:5: error: type 'ConstructionClock' does not conform to the
    'Sendable' protocol` at the binding, and nothing else — the `sending closure risks causing data races`
    that would otherwise name a closure the user never wrote is never reached. For a non-Sendable
    *product* the assertion is suppressed: the marker enum's own conformance fails at module level, which
    aborts before function bodies are type-checked, so what is reported is `associated value 'fastSignal'
    of 'Sendable'-conforming enum '…WireTaskResult' has non-Sendable type 'FastSignal'` — in the generated
    file, but carrying the binding's property name, the type, **and a note anchored at the user's own type
    declaration**. Leaving the enum's conformance to derivation instead does let the assertion through,
    and was measured: it buys the located error at the cost of three `type '…WireTaskResult' does not
    conform to 'Sendable'` errors against generated code that name nothing. Declared is the better trade,
    and the enum stays declared.
  - **`while let … = try await next()`, not `for try await … in group`.** The sketch above iterates the
    group while the body passes it `inout` to schedule from a cascade, which is an overlapping access.
    The `next()` form is what compiles, and it is also the shape that makes the cascade's scheduling
    obviously legal.
  - **`-typecheck` misses concurrency diagnostics too, not only the noncopyable spellings.** Region
    isolation runs as a SIL pass, so `swiftc -swift-version 6 -strict-concurrency=complete -typecheck`
    accepts an actor call that `-c` rejects with `sending 'c' risks causing data races` — the same file,
    the same flags. Every probe for this step was therefore run as a SwiftPM package matching the
    repository's own settings rather than as a bare `swiftc` invocation, and the first round of probes
    that was not had to be thrown away. This generalises *§ Spellings that are load-bearing*: for
    anything in this milestone, the compile has to reach SIL.
- **M7c.4 — the scheduled region, and the exclusions that survive it.** *Rewritten 2026-09 against the
  survey in § The scheduled region; what it used to say is kept below, because the reason it was wrong is
  the reason this step is small.*

  Split each scheduled graph into prefix / group / suffix, emit the two serial regions as today's linear
  chain, and narrow the exclusion predicate from "this construct appears in the graph" to "this construct
  appears in the group region". **Gate:** the integration corpus — all twelve large graphs take the
  scheduled form, and the golden grows by the machinery for four bindings each rather than for a hundred
  and ten.

  **Gate: met, and the regions came out smaller than the survey's upper bound.** `ConstructionRegions.swift`
  computes the split; `chainConstructionLines` emits a region as the linear chain and is called twice, once
  for the prefix and once for the suffix. **Fifteen graphs are now scheduled where two were** — every graph
  in the corpus with an independent async pair, the four wholly-sync containers untouched and byte-identical
  — and the whole corpus carries **44 cells**, thirteen graphs at three and one at two. The golden grows
  6,646 → 7,398, about 58 lines per newly-scheduled graph against the ~790 a whole-graph conversion would
  have cost. The survey predicted four per graph and said so as an upper bound; the suffix trim is the
  difference.

  Three things this step settled:

  - **A bug the design missed, and the first probe missed with it.** A frontier value is a stored property
    on the building struct, and *naming one inside `addTask`'s escaping closure captures `self`* — which is
    `inout` in a mutating method: `escaping closure captures mutating 'self' parameter`. The seam probe had
    only a *sync* consumer reading the frontier value, so it never formed the closure. The fix is one line
    per crossing dependency — `let config = self.config` after the guards — and the closure captures the
    local. Region isolation is unaffected for a `Sendable` payload, and a non-Sendable one is what
    `_wireSendableChecks` already asserts against, at the binding's own line.
  - **The seam retired `GraphStoragePatch.builderLocal`.** M7c.2 added it so the memberwise init could take
    each stored binding out of its cell; now the seam does that first, so the init names a plain local in
    both shapes and the field had no second value left to hold.
  - **Two clauses deleted rather than narrowed, and the corpus exercises both.** Every large graph carries
    four `@Teardown` bindings and five member injections, all in the prefix — but the clauses are gone
    outright rather than region-scoped, because both name post-construction blocks that run after the seam.
    `aTeardownBindingNoLongerBlocksScheduling` puts a `@Teardown` binding *in the group* and asserts the
    closure still closes over its local.

  It used to read: *"builder folds, scope-entry thunks, existential-promotion aliases, member injections
  and weak-cycle post-construct, translated into the `addX` form. Gate: the integration corpus, which
  already exercises all five."* Two things were wrong with it. Its gate was **empty for four steps out of
  five** — every large graph is blocked by five clauses at once, so deleting one admits nothing and the
  fifth flips eleven graphs in one commit; the same empty-population trap M7c.2 hit. And the five
  translations are not what the corpus is asking for: **every instance of all six constructs sits in the
  prefix**, so the region change admits all twelve with no new emission. The translations stay written
  down as what a graph would have to look like to need them, and get written when one does — each behind
  its own fixture, since the corpus gate will still be empty for them.
- **M7c.5 — init-failure partial teardown.** The `do`/`catch`, the resolved-set walk, the explicit
  `cancelAll()`-and-drain. **Gate:** a fixture with a throwing init downstream of a constructed
  `@Teardown` binding asserts the earlier action fired — the fixture [TeardownDesign.md](TeardownDesign.md)
  asks for.
- **M7c.6 — scope paths.** Decide, explicitly, which of `SeedScopeStructEmission.swift:134`,
  `ScopeEntryEmission.swift:128`, `SeedlessReconstructionEmission.swift:136` and
  `ContributorProxyFacadeEmission.swift:62` get the scheduler. Per-request scope entry is where async data
  resolution actually shows up, so "app bootstrap only" is a defensible first cut but not obviously right.

The per-graph rule — scheduler if two of the graph's async bindings can be in flight at once, today's
linear chain otherwise — is what protects the golden and what keeps this from being a per-binding
predicate Wire cannot compute.

## The upstream ask, and what it would give

One ask, well-formed and small: **`sending` results for task groups**, relaxing `ChildTaskResult:
Sendable`. `async let` already produces non-Sendable results, so region isolation handles the transfer;
the constraint is on the frozen struct declaration and nothing in the body depends on it.

What it would buy: an **async binding of a non-Sendable type** could be constructed in a child task rather
than inline on the parent. That is the whole of it — a narrow case, and already an odd one (a type not
designed for concurrency, constructed by suspending work).

What it would **not** buy is the constraint that actually binds a DI graph: a retained, shared
non-Sendable dependency stays impossible, because that is a race. Sharing is what a DI graph is *for*, so
waiting on the stdlib buys less than it appears to, and step 1 buys more.

Two routes exist without waiting, and both are worse:

- **`async let`** supports non-Sendable results today but cannot express the cascade — an `async let`'s
  right-hand side cannot reference another (*"capturing 'async let' variables is not supported"*), so it
  degrades to the strict per-level form [EffectAwareResolution.md](EffectAwareResolution.md) treats as the
  degenerate case. It buys non-Sendable support by giving up the scheduling model.
- **A Sendable box.** wire-mvc's `WireDisconnected` (the SE-0538 subset vendored for M5.5) is the right
  idea but the wrong shape **for this direction**: it is `~Copyable`, and `ChildTaskResult` must be
  `Copyable`. For the *inbound* direction it is exactly the right shape — see § *A boxed payload, not a
  second cell*, where the same type carries a non-Sendable dependency into a child task as a cell's
  payload. SE-0538 is now
  accepted and under implementation, so the vendored subset has a swap path. A copyable box —
  a final class, `@unchecked Sendable`, nil-ing out on take — works mechanically, but its soundness would
  rest on "the generated scheduler takes exactly once and never aliases", an invariant asserted by
  codegen. That is strictly weaker than the argument the project already made for itself:
  `WireDisconnected`'s own doc grounds safety in `init(_:)`/`take()` being the only ways in and out, with
  linearity enforcing it. Lowering that bar inside generated code, for a performance milestone, is a bad
  trade. Recorded so it is not re-proposed.

A second ask fell out of M7c.2, and unlike the first it is **already answered, in the negative**: a way to
*require* a generic parameter to be noncopyable. `~Copyable` only suppresses the implicit `Copyable`
requirement, so a cell generic over it is type-checked for copyable instantiations too and can never
promise `sending` — even though the noncopyable case it exists for could. Today the only way to pin the
payload is to monomorphise, so a cell carrying `sending` for M8's noncopyable bindings would have to be
emitted concretely per binding; the requirement would collapse all of those back into one generic cell.

It is not worth pitching, because SE-0427 *§ Alternatives Considered* weighed exactly this and set it
aside: formalising `T: ~Copyable` as the **logical negation** of a conformance, where *"it is not apparent
how this leads to a sound and usable model and we have not explored this further."* Recorded so the next
reader does not mistake it for an unexplored opening — and because § *A boxed payload, not a second cell*
gets the same result without it, by pinning disconnectedness in the payload's type instead of copyability
in the generic signature.

The noncopyable restrictions are a separate, larger ask (noncopyable task results, consuming captures in
escaping closures, `sending` composing with ownership modifiers on parameters). They are unimplemented rather than
forbidden, and they sit in the same actively-moving area as M8's own toolchain-floor bet, so the right
posture is to let M8 own that timeline.

## Trigger, unchanged

Nothing here changes when M7c should happen. The corpus has 39 `await`ed construction lines out of 3,169
across all graphs, and three in the default graph — construction latency is not being felt. The forcing
case remains a deep async dependency chain worth optimising, or an adopter hitting a throwing init that
coexists with a constructed `@Teardown` binding, which pulls M7c.5 forward on its own.

If that second trigger arrives alone, the coupling argument for deferring partial teardown is weaker than
the ROADMAP's wording suggests: the `do`/`catch`-plus-reverse-walk structure is the same under either
scheduler, and only the "what resolved" predicate changes. Writing it against the linear chain and
accepting the rewrite is a reasonable call at that point.

## References

- [EffectAwareResolution.md](EffectAwareResolution.md) — the levels model, the prior-art map, and the open
  semantic questions (error precedence, cancellation policy, user opt-out) this note does not settle.
- [TeardownDesign.md](TeardownDesign.md) *§ Init-failure partial teardown* — the deferral this discharges.
- [M8_PLAN.md](../M8_PLAN.md) *§ Risks / interleaves* — the noncopyable interleave, and *§ the storage
  model* for the frame-local model step 1 converges with.
- [M7_PLAN.md](../M7_PLAN.md) — the milestone's build plan; M7b's shipped reachability is what makes the
  root set the right retention target.
- `Sources/WireGenCore/CodeEmission.swift` — `appendStruct`'s construction body, the loop this replaces.
- `Sources/Wire/BindingState.swift` — **the cell, shipped with M7c.2.** Library code rather than emitted:
  generated code already names Wire's public types, and a type whose failure modes pass `-typecheck` needs
  somewhere it can be tested directly (`Tests/WireTests/BindingStateTests.swift`).
- `Sources/WireGenCore/ConstructionSchedulingEmission.swift` — **M7c.2, shipped.** The per-graph trigger,
  the building struct and the driver; `Tests/WireGenCoreTests/ConstructionSchedulingTests.swift` gates the
  trigger and the cascade, and `Tests/IntegrationTests/SchedulerContainerExample.swift` is the graph that
  actually takes the path.
- `Sources/WireGenCore/Retention.swift` — **M7c.1, shipped.** The retained set, the read scan and the
  deferred stored-property/memberwise-init resolution; `Tests/WireGenCoreTests/RetentionTests.swift` is
  its gate.
- `Sources/Wire/AtomicState.swift` — **deleted with this design.** The cell primitive had no production
  caller: `Lazy<T>` mirrors its lifecycle in a separate `LazyBox` (whose cases carry payloads the shared
  primitive had no room for) rather than using it, and this note removes the only other prospective one,
  so it went out along with its tests. `Package.swift`'s macOS 15 floor still stands on `Mutex`, now via
  `LazyBox`.
