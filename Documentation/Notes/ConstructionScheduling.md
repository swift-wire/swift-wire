# Construction scheduling — design note (M7c)

> **Status:** the implementation design for M7c, dynamic construction scheduling. It **supersedes the
> `AtomicState<T>`-cell sketch** in [EffectAwareResolution.md](EffectAwareResolution.md) *§ Strict
> per-level vs dynamic ready-as-deps-resolve*; that note stays as the conceptual framing (the levels
> model, the prior-art map, the semantic questions), this one carries the shape the emitter should
> actually produce and why the cell form was dropped. **The trigger is unchanged** — M7c still lands
> when construction latency is worth optimising, or earlier if an adopter forces init-failure partial
> teardown. Nothing here argues for scheduling it. Every Swift-level claim below was verified against
> the repository's toolchain floor (6.3.3) with a compiling fixture, not reasoned from the language
> reference; the error texts quoted are real.

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

    /// `sending` is what lets a *non-Sendable* payload leave for a child task; the
    /// `.consumed` transition is the proof obligation behind it — the struct has
    /// provably surrendered its only reference.
    mutating func take() -> sending Value {
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

## Step 1 — narrow what the graph retains

The scheduler's one real constraint is that a value which is **retained** while a child task uses it must
be `Sendable`. Retention, not asynchrony, is the lever — and `_WireGraph` retains everything today, one
stored property per binding. Narrowing that is worth doing on its own and makes the rest cheaper.

**The target set is M7b's root model,** which the repository already commits to: an aggregate a graph
conformance names, and `allowUnused: true` in the home package (with `@GraphInputs` properties already
the second of those). A binding that is neither is, by M7b's own rule, only reachable *through* another
binding — so storing it is redundant.

Three additions to that set, which the roots model does not cover:

- **`@Teardown` bindings.** `bootstrapTeardownClosureLines` (`Sources/WireGenCore/TeardownEmission.swift`)
  captures each binding's concrete local — that *is* retention, and a consumed binding cannot be torn
  down. Worth stating loudly because the ROADMAP settled that `@Teardown` does **not** root a binding for
  *reachability*; retention is a different question with the opposite answer, and the shared word will
  invite confusion.
- **Facade borrows.** Seed-scope façades, factory proxies and contributor-proxy facades read
  `_wireGraph.<property>` — 12 sites in the current golden. M7d already removed this wherever a bridging
  proxy enters the scope (those thunks capture locals directly); this is the residue.
- **Multi-consumer bindings**, which need frame retention even when they need no graph storage. Dropping
  the stored property removes *one* retainer; a binding with three consumers still has three.

`introspect()` costs nothing — it is baked string literals at codegen with no property reads
(`Sources/WireGenCore/IntrospectionEmission.swift`).

**Compatibility.** M7b already made "a binding you read from user code must be `allowUnused: true`" the
contract, with a diagnostic and a fix-it, so most of the migration is done. The residual break is a
binding that is *reachable via a consumer* **and** read by user code: it survived pruning without the
annotation and would lose its stored property here. Same annotation, same fix-it shape, but it needs its
own diagnostic rather than riding M7b's.

**Why it pays.** Retention is what makes a value un-transferable, so removing a retainer converts a
single-consumer binding into one that can be moved into its consumer — including into a child task, even
when non-Sendable. The correlation runs the right way: many-consumer bindings (logger, config, pool) are
the ones that are `Sendable` anyway because they are built for concurrent use, while non-Sendable
bindings tend to be narrow helpers with one consumer.

## The constraint model

Classifying these correctly is the point of the note — it decides what to design around permanently and
what not to build workarounds for.

**Intrinsic — no change to any library lifts these.**

- A dependency that is **retained** (2+ consumers, or stored, or captured by the teardown closure) and is
  used inside a concurrently-running construction must be `Sendable`. This is a real race: the parent
  constructing a sync dependent from a non-Sendable object while a child task mutates it. Region
  isolation says so from two independent directions — the `sending`-parameter route gives *"task-isolated
  'counter' is passed as a 'sending' parameter; Uses in callee may race with later task-isolated uses"*,
  and two `async let`s over one non-Sendable local give *"access can happen concurrently"*. Drop to one
  consumer and both compile.
- A noncopyable binding has exactly one consumer, so it can never be a shared dependency in a parallel
  fan-out. Already M8's rule.

**`ThrowingTaskGroup`'s signature — would lift with stdlib adoption, no semantics behind them.**

- `ChildTaskResult: Sendable`, declared on the struct (SDK interface, the `ThrowingTaskGroup`
  declaration), inherited by `addTask`'s operation return and by `next()`. `async let` produces a
  non-Sendable result under `-strict-concurrency=complete` today, so the *language* already handles
  "child constructs a fresh value, transfers it to the parent". Note that `addTask`'s `operation:` is
  already `sending` — the inbound direction has been modernised for region isolation and the outbound
  one has not.
- `GroupResult: Copyable` — an implicit constraint with no `where` clause behind it. Also routable
  today: return the copyable values and build the noncopyable chain in the enclosing frame.

**Unimplemented, with intent clear.**

- Noncopyable `async let` results: `async let t = makeToken(); return await t` gives *"copy of noncopyable
  typed value. This is a compiler bug. Please file a bug"*.
- Consuming captures into escaping closures — there is no `[consume x]` capture list, and the diagnostic
  when you try is a region-isolation message about the parent retaining access, not a rule against
  capturing noncopyable values.
- `sending` does not compose with noncopyable ownership: `sending Token` gives *"parameter of noncopyable
  type 'Token' must specify ownership"*.

### The decision Wire cannot compute

`WireGenCore` is a SwiftSyntax pipeline; `Sendable` is usually derived rather than written, so Wire cannot
answer "is this binding Sendable?" at codegen time.

The way out is to decide scheduling on something Wire *does* know. **Put only async bindings in child
tasks** — parallelism only pays where there is a suspension, and effect flags are already captured
(`Sources/WireGenCore/EffectSpecifiers.swift`). The `Sendable` requirement then lands on exactly two sets,
both computable from the graph and both small enough to document by name: async bindings' products, and
the *retained* dependencies of async bindings. After step 1 the second set is "dependencies of async
bindings with 2+ consumers, or that carry `@Teardown`, or that a facade borrows."

A binding in neither set needs no annotation and no user action. For a non-Sendable async binding — the
one case with no route — the fallback is a bare `await` inline on the parent inside the group body
(`addX` becomes `async throws`): that binding loses parallelism, already-scheduled siblings keep running,
and only the scheduling of newly-ready work stalls.

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

## What it costs

Cascade decisions run on the parent's drain loop instead of firing inside the child that resolved the
dependency. The hop is free — the parent is suspended on the iterator anyway — but sync bindings now
construct on the parent, so two *expensive sync* bindings downstream of two different async bindings run
serially rather than concurrently in their child tasks. Wire has no cost model to know when that matters,
and the trade buys non-Sendable and noncopyable support, so it is the right one.

Generated volume goes up: a cell, an `addX` and an `update` arm per binding, against one `let` today. It
is flat and mechanical, and it is the same shape for all four binding categories.

## Suggested sequencing

Same discipline as the other milestone plans — each sub-step runs end to end and has a gate; highest-risk
seam first. **Every gate compiles the generated output**, per the `-typecheck`-is-not-enough finding above.

- **M7c.1 — narrow retention.** `_WireGraph` stores the root set plus `@Teardown` bindings plus facade
  borrows; everything else becomes a bootstrap local only. No scheduler yet, so the construction body
  stays the linear chain. **Gate:** the integration corpus builds unchanged apart from the properties that
  disappear, with a diagnostic naming each dropped property and the `allowUnused: true` fix-it; goldens
  re-recorded once, deliberately.
- **M7c.2 — the state struct, sequential.** Emit `State`/`BuildingGraph`/`addX`/`finalise` and drive it
  with *no* task group: the cascade runs entirely inline, which is the wholly-sync degenerate case. This
  isolates every noncopyable spelling and the three read forms before any concurrency is involved.
  **Gate:** a fixture graph over all four binding categories constructs correctly; `GoldenHarness/` output
  is byte-identical for graphs with no async binding, because those keep the linear chain.
- **M7c.3 — the group.** Async bindings move into `group.addTask`, the parent drains and cascades.
  **Gate:** a fixture with a fast and a slow independent async binding plus a dependent of the fast one
  shows the dependent starting before the slow one finishes; `-enforce-exclusivity=checked` clean.
- **M7c.4 — the interacting constructs.** Builder folds, scope-entry thunks, existential-promotion
  aliases, member injections and weak-cycle post-construct, translated into the `addX` form. **Gate:** the
  integration corpus, which already exercises all five.
- **M7c.5 — init-failure partial teardown.** The `do`/`catch`, the resolved-set walk, the explicit
  `cancelAll()`-and-drain. **Gate:** a fixture with a throwing init downstream of a constructed
  `@Teardown` binding asserts the earlier action fired — the fixture [TeardownDesign.md](TeardownDesign.md)
  asks for.
- **M7c.6 — scope paths.** Decide, explicitly, which of `SeedScopeStructEmission.swift:134`,
  `ScopeEntryEmission.swift:128`, `SeedlessReconstructionEmission.swift:136` and
  `ContributorProxyFacadeEmission.swift:62` get the scheduler. Per-request scope entry is where async data
  resolution actually shows up, so "app bootstrap only" is a defensible first cut but not obviously right.

The per-graph rule — scheduler if the graph contains an async binding, today's linear chain otherwise —
is what protects the 6,417-line golden and what keeps this from being a per-binding predicate Wire cannot
compute.

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
  idea but the wrong shape: it is `~Copyable`, and `ChildTaskResult` must be `Copyable`. A copyable box —
  a final class, `@unchecked Sendable`, nil-ing out on take — works mechanically, but its soundness would
  rest on "the generated scheduler takes exactly once and never aliases", an invariant asserted by
  codegen. That is strictly weaker than the argument the project already made for itself:
  `WireDisconnected`'s own doc grounds safety in `init(_:)`/`take()` being the only ways in and out, with
  linearity enforcing it. Lowering that bar inside generated code, for a performance milestone, is a bad
  trade. Recorded so it is not re-proposed.

The noncopyable restrictions are a separate, larger ask (noncopyable task results, consuming captures in
escaping closures, `sending` composing with ownership modifiers). They are unimplemented rather than
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
- `Sources/Wire/AtomicState.swift` — **deleted with this design.** The cell primitive had no production
  caller: `Lazy<T>` mirrors its lifecycle in a separate `LazyBox` (whose cases carry payloads the shared
  primitive had no room for) rather than using it, and this note removes the only other prospective one,
  so it went out along with its tests. `Package.swift`'s macOS 15 floor still stands on `Mutex`, now via
  `LazyBox`.
