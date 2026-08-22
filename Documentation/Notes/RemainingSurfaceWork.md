# Remaining surface work — the proposed sequence

> **Status:** planning note, nothing here is built. It assembles into one order the surface work that is
> currently spread across five documents in three repositories, and proposes a sequence with the reasoning
> for it. It introduces no new work — every item already exists somewhere; this note is about *order*, and
> about the fact that most of these items are not tracked by the milestone whose job they are.
>
> **Two items were removed on first assembly**, both from the parity note's streaming track, because
> `PendingIssues/14` records them already measured: the Hummingbird/Vapor duplex question (answered, spikes
> 31–32) and the lending tier's ownership question (answered, spike-33). What looked like a three-item track
> gated on an experiment is one item gated on an upstream compiler fix. Sequencing across repositories is
> exactly where this kind of staleness accumulates, which is the case for keeping one ordered list.

## Why this exists

M6 is defined in [`ROADMAP.md`](../../ROADMAP.md) as *"features that make idiomatic apps expressible and
unblock the last examples."* Read against its own sub-milestones, M6 is one-and-a-half items from done:
M6a/M6b complete, M6c built, M6d built with task-cluster unmigrated.

Read against the documents that actually enumerate the last examples, it is not close. The roadmap contains
no reference to
[`HummingbirdExamplesParity.md`](https://github.com/tachyonics/wire-mvc-examples/blob/main/Documentation/Notes/HummingbirdExamplesParity.md),
which holds the gap list M6 exists to close; and
[`WireMVCRouter.md`](https://github.com/tachyonics/wire-mvc/blob/main/Documentation/Notes/WireMVCRouter.md)'s
six-item backlog — which includes behaviour a 1.0 router is expected to have — appears in neither M6 nor M7.

So "what remains in M6" currently has two defensible answers that differ by an order of magnitude. This note
takes the larger one and sequences it. Whether these become an M6e or an explicitly post-M6 track is a
tracking decision recorded as open at the end; the sequence holds either way.

## Sources

| Source | What it contributes |
|---|---|
| [`ROADMAP.md`](../../ROADMAP.md) M6d | task-cluster migration; upstreaming the generator access change |
| [`HummingbirdExamplesParity.md`](https://github.com/tachyonics/wire-mvc-examples/blob/main/Documentation/Notes/HummingbirdExamplesParity.md) | the parity track (5 items) and the streaming track (3), with their internal ordering already argued |
| [`StreamingResponseTier.md`](https://github.com/tachyonics/wire-mvc/blob/main/Documentation/Notes/StreamingResponseTier.md) | the tier shipped; migrating SSE and multipart off `@RawRoute` is "the larger part of the payoff" and still to come |
| [`WireMVCRouter.md`](https://github.com/tachyonics/wire-mvc/blob/main/Documentation/Notes/WireMVCRouter.md) | the six-item router backlog |
| [`PendingIssues/14`](../../PendingIssues/14-typed-tier-duplex-routes.md) | the duplex story: what spikes 31–33 already measured, and the upstream bug the typed tier waits on |
| [wire-mvc-performance](https://github.com/tachyonics/wire-mvc-performance) | measured per-request cost and allocations — where Phase 5 comes from |

Where an ordering below differs from its source, the difference is called out and argued. Where it does not,
the source's reasoning stands and is summarised rather than repeated.

## The sequence

### Phase 0 — one question left, and one already answered

The parity note poses two. One is genuinely open and cheap; the other has been measured since that note was
written, and is kept here only so it is not re-run.

1. **Does tracing context cross the WireMVC boundary?** The bridge dispatches into an unstructured
   `Task {}`, which *inherits* task-locals (unlike `Task.detached`), so an `open-telemetry`-style host
   middleware's `ServiceContext` — itself a task-local — *ought* to reach a handler. It is exactly the kind
   of thing that silently doesn't. The answer prices the native-adapter trade described under
   *The `ServerTransport` ceiling* below. Hours, not days.

   **Bridge half: done.** Two tests in `WireMVCServerTransportTests` pin it — one-shot, and into a *streamed*
   body, where the value is read after the register closure returned and the host's `withValue` scope has
   exited. Both pass; a plain `@TaskLocal` stands in for `ServiceContext` so no dependency is taken to prove
   a mechanism they share. The value is what a swap to `Task.detached` for some unrelated reason would break
   silently, with no test and no compiler complaint.

   **Host half: done, and the answer has an edge.** Three tests per runtime in `HummingbirdExample` and
   `VaporExample` set a task-local in real host middleware and read it through a route registered on the
   `ServerTransport` conformance, over a real server. Hummingbird and Vapor behave identically:

   | Where the value is read | Context |
   |---|---|
   | In the handler, one-shot response | **present** |
   | In a response body the *framework* pulls after the closure returned | **absent** |
   | In a response body produced by a `Task` created inside the closure | **present** |

   The middle row was a surprise and is the reason this was worth measuring rather than assuming. The
   frameworks consume an `AsyncSequence` response body outside the task that had the value bound, so a
   handler that reads ambient context *while generating bytes lazily* sees nothing — the response is still
   correct, only the trace is missing, which is the silent-failure shape.

   **It does not affect WireMVC**, and the third row is why: the bridge produces bytes from an unstructured
   `Task` created inside the register closure, which copies the task-locals; the framework's later pull only
   moves already-built values. So tracing context reaches WireMVC handlers on both runtimes, streaming
   included. The boundary is real for anyone writing a *raw* `ServerTransport` handler, and is pinned as
   such rather than filed as a defect — it is inherent to the body being a framework-driven sequence.

   **Net for the native-adapter trade:** tracing is not a reason to drop `ServerTransport`. It crosses
   intact on the path WireMVC uses.

   **A defect fell out of this, now fixed.** Asking what the bridge's unstructured `Task {}` inherits
   surfaced what it does *not*: cancellation. A client disconnecting before the handler sent a response
   head left the handler running to completion — the lifetime tie to the returned body only exists once
   there is a body. Fixed with `withTaskCancellationHandler` and pinned by a test that cancels mid-flight;
   the residue (the cancelled request is *reported* as a 500, indistinguishable from a broken route) is
   [`PendingIssues/15`](../../PendingIssues/15-cancelled-request-reports-500.md).

   That question also settled one this note had left implicit: **the unstructured task is not a choice to
   revisit.** `ServerTransport.register` returns `(HTTPResponse, HTTPBody?)` and the framework consumes the
   body after the closure returns, so the producer must outlive the closure — no task group inside it can
   work, a discarding one included, since those await their children at scope exit. A `ServiceLifecycle`
   group one level out would be structured but does not subsume the per-request fix.

   **A per-framework adapter is a different matter, and an earlier version of this note got it wrong.** It
   said Hummingbird and Vapor are natively head-then-body (`respond → Response`, body lent a writer only
   afterwards) so a native adapter would not remove the task either. That holds only for a **dynamic**
   status. Where the status is *declared* — every typed tier — a native adapter can return
   `Response(status: declared, body: .closure { writer in try await handler(writer) })` and run the handler
   inside the lent writer: no task, no `ResponseChannel` rendezvous, no `HandlerTaskHandle`, and no second
   set of currency types. Since that covers most routes rather than an edge case, concurrency structure
   *is* among the arguments for a native path, alongside the `ServerTransport` ceiling. What is missing is
   measurement, not argument — see
   [CatchAllMountingProbe.md](https://github.com/tachyonics/wire-mvc/blob/main/Documentation/Notes/CatchAllMountingProbe.md).

2. ~~**The `response-body-processing` echo as a `@RawRoute`.**~~ **Already answered — do not re-run.**
   The parity note lists the full-duplex case as unverified on Hummingbird and Vapor, and that is now stale.
   [`PendingIssues/14`](../../PendingIssues/14-typed-tier-duplex-routes.md) records it measured: **spike-31**
   established that the transport interleaves on both Hummingbird and Vapor, and **spike-32** drove
   `@RawRoute` duplex end to end on the proposal-native server *and* through `WireMVCServerTransport` on
   Hummingbird, with a raw-socket ping-pong client that cannot pass if either direction buffers.

   So the frameworks tolerate it, the escape hatch the diagnostic points at is real rather than theoretical,
   and nothing downstream is waiting on this answer. An echo example would now be worth writing for parity
   value alone — it belongs in Phase 3, not ahead of anything.

### Phase 1 — migrate the streaming routes onto the producer tier

wire-mvc's own outstanding item, and `StreamingResponseTier.md` calls it "the larger part of the payoff" of
a tier that has already shipped. Until `@RawRoute` shrinks to the routes that genuinely need the whole
sender, you cannot tell which routes are there for which reason.

**Independent of Phase 4, and of the duplex question generally.** Both routes are `@Get`s that read no body,
so neither can reach the `bodyStreamOnStreamingResponse` diagnostic. `PendingIssues/14` is explicit that an
earlier analysis coupling the two was wrong; this note does not repeat it.

**`/todos/stream` first, `/export` second.** `/export` streams through `MultiPartSender<S>`, a middleware
that transforms the *sender*, while the producer tier's writer comes from the framework's own `send`. It is
not obvious the two compose, and that migration may surface a real constraint rather than being mechanical.
Ordering it second means a failure there does not also cost the tier its first client.

### Phase 2 — router correctness

The six items from `WireMVCRouter.md`, which are independent of the example tracks and can proceed in
parallel with them. All are additive and testable through `RouteTrie`/`FrozenRouteTrie` before anything
above the router sees them.

The source lists these "roughly by value." **This note proposes one change to that order:** raise
**percent-decoding** to second. It is the only item on the list that produces a *silently wrong value* — a
handler receives `a%20b` where the client sent `a b` — rather than a wrong status code or an absent
capability. Everything else on the list fails visibly or fails to exist.

| | Item | Why here |
|---|---|---|
| 1 | **405 vs 404** — distinguish "path matched, not this method" (`405` + `Allow`) from "no path matched" (`404`); `resolve` reports a node's available methods on a path hit | The most visible gap against what a 1.0 router is expected to do, and the one an HTTP-conformance test suite fails on first |
| 2 | **Percent-decoding** of path parameters | *Raised from 6th.* The only silent-wrong-value item — a handler cannot tell it received undecoded input |
| 3 | **Duplicate-route diagnostics** — two registrations for the same method+template | Today a precondition guards only index/handler drift; a real duplicate is accepted silently. Cheap, and a build-time error beats a runtime surprise |
| 4 | **Trailing-slash policy** — a deliberate strict/redirect/lenient choice | Replaces incidental "empty segments omitted" behaviour with a stated one. Behavioural, so it wants deciding before adopters depend on the accident |
| 5 | **Full precedence** — parameter beats catch-all, order-independent among ambiguous routes | Partly blocked on catch-all existing; the order-independence half is separable and worth doing alone |
| 6 | **Catch-all / wildcard params** (`{path*}`) | Last, deliberately — see below |

**Catch-all is last on purpose, and it is not the blocker it looks like.** Nothing in the 28
hummingbird-examples registers one (a grep for `**` across all their route tables returns nothing), and the
two examples usually attributed to it — `s3-file-provider` and `proxy-server` — are middleware with at most
one real route. Arbitrarily deep *fixed-arity* templates already work; what is missing is a variable-arity
remainder.

Portability makes it worse than a missing feature. `ServerTransport` carries OpenAPI's `{name}` template
convention, and a wildcard fails **silently and differently** per adapter: swift-openapi-vapor maps anything
that isn't `{name}` to a literal segment, while swift-openapi-hummingbird hands it to `RouterPath`, where
`{path*}` parses as a single-segment capture *named* `path*`. Any catch-all example would work on
`SwiftHttpServerExample` and be quietly broken on the other two. Building it means deciding what it means
across three adapters, not just adding a trie edge.

### Phase 3 — parity examples

In the parity note's own order, which this note does not change. Each is an example rather than framework
work, so they are individually droppable and individually schedulable.

1. **File serving / s3-file-provider** — a global `@Middleware` that answers the request itself over the
   `@NotFound` fallback: the box's `.responded` state plus the front layer wrapping every route including
   the fallback. Nothing in the repo exercises that seam end-to-end. Native-path only — on the
   `ServerTransport` runtimes the host's own file middleware does this, which is the honest story for a
   framework that collates rather than owns the router.
2. **jobs** — a queue as a graph-hosted `ServiceLifecycle` service plus a route that enqueues. Nothing
   currently shows work outliving the request.
3. **auth-abac / auth-permissions** — policy objects as bindings, composed by route-scope middleware. The
   existing API-key gate is a toy next to this.
4. **upload** — an unbounded body streamed to disk. Was blocked on the request-body-streaming bridge, now
   ordinary. Overlaps the streaming track: a large streamed upload answered with a streamed response is the
   echo's shape.

### Phase 4 — the typed duplex tier

**Not a spike, and not conditional on Phase 0.** The parity note proposes spiking a lending tier with
ownership as the open question. That framing is superseded: spikes 31–33 have already run, the ownership
question came back **yes**, and the design compiles with real bindings — including negative checks (a second
`send` gives `'responseSender' consumed more than once`; reusing the stream likewise). See
[`PendingIssues/14`](../../PendingIssues/14-typed-tier-duplex-routes.md).

What remains is not a question but an **upstream blocker**:
[swiftlang/swift#91473](https://github.com/swiftlang/swift/issues/91473). The response must be `~Escapable`
because it owns the writer, and a property wrapper on an `~Escapable` *generic* parameter is unusable — all
three ingredients required, verified by removing them one at a time. A conformance-on-the-parameter-type
workaround compiles, and was rejected on purpose: it would make the response the one binding in the
framework recognised structurally rather than declared, sitting in a parameter list next to `@MultipartStream`,
which *is* declared. Shipping a second binding idiom for one route shape, then removing it, costs more than
waiting.

**So this phase is scheduled by an event, not by us.** It lands with `@RequestBinding(.bodyStream)`, which
waits on the same bug under the roadmap's *Known blockers (1.0)*, so the surface stays one idiom. Sooner
only if an adopter has a real duplex route `@RawRoute` cannot serve — a capability argument rather than a
consistency one, and it should be recorded as such rather than treated as this item arriving early.

**Two pieces of it are not blocked and should not wait:**

- ~~**The sequential case**~~ — **shipped**, wire-mvc #113. A `.readerBody` binding on a
  *streaming-response* route: reduce the body without buffering, then stream. It went in as the third
  terminal overload, `lendingBodyFrom:`, handing the reader to `building` as a consuming closure parameter —
  moved in rather than captured, which is why the recorded obstacle ("a closure only borrows it") never
  applied. The bind lands inside the same `do` whose `catch` maps, so a malformed or oversized body still
  becomes a status through `@ErrorResponse` instead of escaping as a truncated response.
  `readerBodyOnStreamingResponse` is now `bodyStreamOnStreamingResponse`, refusing only the duplex shape it
  was always about.
- **The lent-binding validation step.** Duplex is the first shape where the handler runs *after* the head, so
  `MultipartParts.init`'s deferred content-type check would truncate a response instead of mapping to 415.
  Fixing that changes a **public binding protocol**, which is cheaper before 1.0 than after — so it wants
  doing on 1.0's schedule, not on #91473's, even though the feature it serves is paused.

### Phase 5 — allocation reduction in the native request path

Not a correctness item and not urgent: the whole native path is ~0.9 µs at p50 and ~1.2 µs at p99, against
a `ServerTransport` bridge that costs 16–47 µs. It is here because the measurements exist, the causes are
identified, and two of the fixes are small enough that leaving them undone is a choice rather than a
backlog.

Measured in [wire-mvc-performance](https://github.com/tachyonics/wire-mvc-performance) with a `malloc`
interposer, bisected in process so the numbers are the router's rather than a socket's. **Nine allocations
and 756 bytes per request.** For contrast, Hummingbird's router adds *none* — so these are choices in this
implementation, not the cost of routing.

**This is a native-path project.** On a bridged runtime the host's router matches the path and parameters
arrive as `metadata.pathParameters`, so `FrozenRouteTrie.resolve` never runs and groups #1 and #2 — the two
clearest wins below — do not exist there. What does carry over is the registry, allocated per request at
`WireMVCServerTransport.swift:342` whether or not anything contributes. So Phase 5 is 3–5 allocations off a
9-allocation request natively, and one off a 47- or 106-allocation one through the bridge.

| # | what | count | addressable | what it would take | recommended |
|---|---|---|---|---|---|
| 1 | `split` array growth in `FrozenRouteTrie.resolve` | 2 | **yes** | walk segments lazily instead of materialising `[Substring]` | **yes** |
| 2 | parameter collection + `Dictionary(zip(…))` | 2 | **yes** | inline buffer for the 0–2 case; name lookup against the route's own `parameterNames` | **yes, with #1** |
| 3 | response body + write path | 4 | partly | the bytes are the work; some copies may be avoidable | not yet — measure first |
| 4 | `ResponseHeaderRegistry` instance | 1 | **yes** | make it a `~Copyable` struct, or allocate it lazily | **yes** — see below |

**#1 is the clearest, and the diagnosis is exact.** `resolve` does
`requestPath.split(separator: "/", omittingEmptySubsequences: true)` and then walks the result forward
once. The cost is not one allocation but *`Array` growth*: measured at 2 allocations for a two-segment path
and 4 for a five-segment one, which is the doubling sequence (capacity 1, 2, 4, 8), not one per segment.
So a deeper path costs more, for a container nothing needs to index or keep. Iterating segments lazily
takes this to zero and gets *better* the deeper the route.

**#2 follows the same shape.** Values are collected positionally into an array, then built into a
`[String: Substring]` via `Dictionary(zip(route.parameterNames, values))`. Most routes bind nought to two
parameters. An inline buffer would carry them without heap, and the handler's by-name lookup could resolve
against `parameterNames` directly. Note this cost arrived *with* a correctness fix — per-route parameter
naming, which removed a registration-order dependency — so the inline version recovers what that cost.

**#3 is the one to leave alone for now.** Four allocations to build and write a response body is the least
suspicious group: producing bytes and handing them to a sender is the work itself. Attributing them
individually needs an allocation *list*, not a counter, which means Instruments.

#### The registry, and the inline-buffer version

`ResponseHeaderRegistry` is a `final class` the courier instantiates per request whether or not anything
contributes. Three options, in increasing order of both cost and payoff:

1. **Allocate lazily** — the registry exists only once something registers. Removes the one allocation in
   the common case, is contained within one type, and changes no API. The cheap 80%.
2. **`~Copyable` struct with a heap container.** Removes the same allocation and, more importantly, makes
   ownership match the box's — see the design argument below. Contributions still allocate their payloads.
3. **`~Copyable` struct with an inline buffer.** `InlineArray<N, Registration>` (SE-0453, stdlib, verified
   available on the pinned toolchain — four `Int`s occupy 32 bytes with no heap at all) plus a
   `UniqueArray` overflow for the rare deep case. This is the only option that reaches **zero allocations
   while contributing**, not merely when empty. Two payloads still allocate and cannot be helped by the
   container: `.values` holds an `Array` (flattening the store would fix it) and `.deferred` captures an
   escaping closure (inherent). `N` is a tuning parameter — four covers a CORS, a cache and a security
   header with room spare.

**The reason to do 2 or 3 is not the allocation.** `RequestResponseMiddlewareBox` is `~Copyable` precisely
so ownership is explicit and "consumed exactly once" is checked rather than trusted — and it carries inside
it a shared mutable reference that escapes all of those guarantees. Today the registry is aliased three
ways at once (the context, the box, and `ResponseHeaderApplyingSender`), and a write through one handle
must be visible through another. Under ownership, "drained exactly once" becomes a compiler-checked
property rather than a convention — and it is a convention that has already been violated once, which is
why the 405 needed a synthesised handler and why raw routes need the applying-sender wrapper at all.

The data flow permits it: contributions only ever travel downward, registered on the way in and drained
deeper, because a middleware cannot mutate after `next` returns. What blocks it is plumbing — two
independent read sites (`requestContext.responseHeaders` and `wireMVCFinalBox.responseHeaders`, both
emitted by codegen) that must agree, plus the sender wrapper holding its own handle.

**Sequencing.** #1 and #2 are internal to `WireMVCRouter` and can be done any time — and being
native-path-only, they are worth exactly as much as the native path is. The registry's option 1
likewise. Options 2 and 3 change a public shape — `box.responseHeaders` becomes a borrow or a consume, and
every middleware that contributes changes with it, including user-written ones — so if they are right they
are right **now**: a public-shape change is cheap pre-1.0 and expensive after, the same argument
`PendingIssues/14` makes about the lent-binding validation step.

**Caveat on the analysis.** The four groups are measured; the identity of every individual allocation
within groups 2 and 3 is inferred from the code rather than observed. Confirming those needs an allocation
list. And the ownership redesign should re-walk each contribution site — particularly `respondingWith` on
the gate path and the keyed-harness variant paths, which this analysis did not trace.

## Response framing

**Done.** Every one-shot response WireMVC writes now states a `Content-Length`, through one rule —
`HTTPResponse.stateLengthIfAbsent(_:)`, which RFC 9110 §8.6 makes skip `1xx` and `204`, and which skips
`304` because that carries the length the `200` *would* have had. Three sites use it: `WireMVCOutcome.send`
for typed routes, the courier's writer for raw ones, and the synthesised `404`/`405`, which write their own
heads rather than going through an outcome.

Before it, every WireMVC response on every runtime went out `Transfer-Encoding: chunked`, because nothing
downstream infers a length — not the router, not the `ServerTransport` bridge, not `NIOHTTPServer`, whose
only `Content-Length` is the one it writes for an aborted request. What that cost, measured with both sides
of every comparison framed alike:

- **On a bare server, with no framework at all**: a p99 tail of +11.8 µs on Hummingbird, +14.3 µs on Vapor,
  +18.9 µs on the proposal server. Not allocation — 0.1 allocations and 488 bytes — so it is writes and
  parsing, which is why allocation counting would never have found it.
- **Through the bridge, which amplifies it**: Hummingbird's cost rises from +16.3 to +23.3 µs at p50 and
  Vapor's from +47.7 to +67.5, while the plain routes barely move.
- **WireMVC's own path: unchanged either way**, ~2 µs. That is the point. WireMVC never had a tail; it
  omitted the header that avoided one, and was then compared against things that had it.

The whole class was invisible for as long as framing was something a harness set once and never varied, and
three careful attempts to find it by bisecting layers all refuted correctly and learned nothing — because
nothing was in a layer. A one-minute dump of response headers found it.

### What remains

- **An upstream report.** `HTTPResponseSender` declares `sendAndFinish(_:buffer:trailer:)` as a requirement
  *and* supplies a same-signature extension with `trailer` defaulted. A two-argument call — the spelling
  nearly every raw route uses — cannot match the requirement, so it binds to the extension, which calls
  `self.send` instead of dispatching through the witness. Any conformer's override is silently bypassed,
  which contradicts the proposal's own advice that conformers are encouraged to override it. Working around
  it is why the courier defers its head at all; the fix belongs upstream.
- **A trade-off to revisit.** Deferring means a raw route that *streams* sees its head flushed on the first
  `write` rather than on `send`. Typed routes and transformed-sender routes (SSE, multipart) are
  unaffected, so the exposure is hand-written raw streaming routes with an untransformed sender — a client
  there sees headers at the first chunk rather than immediately. Narrow, but it is a timing change, and if
  upstream fixes the shadowing the deferral can be dropped entirely.
- **Routes registered directly on a builder** — bypassing codegen, as a benchmark or a test harness might —
  do not get the courier's sender and so state no length. Not an app-authoring path, but worth knowing
  before concluding from one that raw routes are still chunked.

## Independent of the sequence

Two M6d items that do not belong to either track and should not gate them:

- **task-cluster migration.** The forcing case still runs M3's adapter. Sequenced by task-cluster's own
  needs, not by this list.
- **Upstreaming the generator access change.** Not fully in our control: it depends on upstream review.
  The roadmap currently reads *"wants upstreaming, or at least pinning to a revision"* — the pin is
  **already done** (`wire-open-api/Fixtures/Package.swift`, revision `9e655e0`, with the reasoning that a
  branch reference on a fork nobody else watches is exactly the kind that moves quietly). Only upstreaming
  remains, and the roadmap wants correcting on that point.

## Deferred, with reasons

Recorded so they are not re-proposed:

- **auth-jwt** — bearer-token scope construction beside the existing cookie one. Small delta, cheap, worth
  doing when convenient rather than scheduling.
- **auth-cognito, auth-otp, auth-srp, webauthn, graphql-server, todos-auth-fluent, todos-lambda** —
  protocol and backend variety, low framework signal.
- **proxy-server** — needs connection metadata, absent from `ServerRequestMetadata` *and* from
  `NIOHTTPServer.RequestContext`. The proposal has a designed extension point (capability protocols on
  `RequestContext`, with `ConnectionInfo` as the worked example), so this is an upstream gap with a known
  shape rather than a dead end.
- **websocket-echo, websocket-chat** — protocol upgrade, native adapter only. If one is written, name it
  against the existing `wire-hummingbird` (a Wire-DI-tier adapter where controllers hand-write Hummingbird
  routing) — a WireMVC-tier adapter would be a third, confusable product.
- **http2** — `Application` TLS configuration, not a WireMVC concern.

Also deferred by decision within M6d, and unchanged here: `@OpenAPIConfiguration` (nothing to act on until
non-JSON bodies are supported at the terminal), the decomposition-transformer registry (it belongs in
wire-mvc first), and non-JSON bodies themselves.

## The `ServerTransport` ceiling, for reference

Worth stating once so it is not rediscovered per item. `ServerRequestMetadata` is a struct whose entire
contents are `pathParameters: [String: Substring]`. Unreachable through it: connection metadata (remote
address), protocol upgrade (websockets), the host's request context, and non-`{name}` path syntax.

`WireOpenAPI` does **not** use `ServerTransport` — an operation is a `RouteContributor` witness via direct
dispatch — so the protocol's only job in this stack is as a borrowed universal router-registration interface
for Hummingbird, Vapor and Lambda. Dropping to a native adapter would cost portability, not any OpenAPI
capability. That is the trade Phase 0.1's answer prices.

## Open decision

**Where this lives in the roadmap.** The sequence above is independent of the answer, but the current state
is not tenable: M6 cannot tell you it is incomplete, because the documents enumerating its remaining work
are not linked from it. Two options:

- **M6e**, linking this note from the M6 header — accurate to M6's stated purpose ("unblock the last
  examples"), at the cost of a milestone that grows after being nearly closed.
- **An explicitly post-M6 track**, with M6 closed at M6d and this note named as the successor — a cleaner
  milestone boundary, at the cost of M6 having not quite met its own definition.

Either is fine. Leaving it unstated is not, which is what this note exists to fix.
