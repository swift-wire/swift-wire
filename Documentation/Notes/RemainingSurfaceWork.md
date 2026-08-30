# Remaining surface work — the sequence, and where it stands

> **Status:** live sequencing note, revised 2026-08-26 against all four repositories, with Phase 5's registry
> section re-checked against wire-mvc on 2026-08-30. **Phases 0, 1, 2 and 3 are done; Phase 5 is two thirds
> done, with half of one item still scheduled by 1.0; Phase 4 is blocked upstream.** Each phase carries its own
> status and the PRs that closed it, and where a phase's *argument* was overturned by what shipped, the note
> says so rather than quietly agreeing with the outcome.
>
> It assembled into one order the surface work that was spread across five documents in three repositories,
> and introduced no new work — every item already existed somewhere; the note was about *order*, and about
> the fact that most of these items were not tracked by the milestone whose job they are. That second half
> is now half-fixed: `ROADMAP.md`'s M6 entry links this note, so M6 can at least say where its remaining
> work is enumerated. *Which* milestone it belongs to is still open — see the end.
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

Read against the documents that actually enumerate the last examples, it was not close when this note was
assembled. The roadmap referenced neither
[`HummingbirdExamplesParity.md`](https://github.com/tachyonics/wire-mvc-examples/blob/main/Documentation/Notes/HummingbirdExamplesParity.md),
which holds the gap list M6 exists to close, nor
[`WireMVCRouter.md`](https://github.com/tachyonics/wire-mvc/blob/main/Documentation/Notes/WireMVCRouter.md)'s
six-item backlog — which includes behaviour a 1.0 router is expected to have.

So "what remains in M6" had two defensible answers that differed by an order of magnitude. This note took
the larger one and sequenced it. **All three tracks in that larger answer have since closed** — the router
backlog entirely, the streaming migration entirely, and now the parity examples — which is the answer to
whether the larger reading was the right one to work from. What is left is one blocked tier and an
allocation pass. Whether that becomes an M6e or an explicitly post-M6 track is still open at the end; the
sequence holds either way.

## Sources

| Source | What it contributes |
|---|---|
| [`ROADMAP.md`](../../ROADMAP.md) M6d | task-cluster migration; upstreaming the generator access change |
| [`HummingbirdExamplesParity.md`](https://github.com/tachyonics/wire-mvc-examples/blob/main/Documentation/Notes/HummingbirdExamplesParity.md) | the parity track (5 items) and the streaming track (3), with their internal ordering already argued — **the parity track is now closed**; that note carries the per-item record behind each |
| [`StreamingResponseTier.md`](https://github.com/tachyonics/wire-mvc/blob/main/Documentation/Notes/StreamingResponseTier.md) | the tier shipped, and migrating SSE and multipart off `@RawRoute` — "the larger part of the payoff" — is **now done**, Phase 1 |
| [`WireMVCRouter.md`](https://github.com/tachyonics/wire-mvc/blob/main/Documentation/Notes/WireMVCRouter.md) | the six-item router backlog, **all six shipped**; that note carries the per-item record and the prior-art surveys behind each decision |
| [`PendingIssues/14`](../../PendingIssues/14-typed-tier-duplex-routes.md) | the duplex story: what spikes 31–33 already measured, and the upstream bug the typed tier waits on |
| [wire-mvc-performance](https://github.com/tachyonics/wire-mvc-performance) | measured per-request cost and allocations — where Phase 5 comes from |

Where an ordering below differs from its source, the difference is called out and argued. Where it does not,
the source's reasoning stands and is summarised rather than repeated.

## The sequence

### Phase 0 — one question left, and one already answered — **both closed**

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

### Phase 1 — migrate the streaming routes onto the producer tier — **done**

wire-mvc's own outstanding item, and `StreamingResponseTier.md` called it "the larger part of the payoff" of
a tier that had already shipped. Both routes moved, in the proposed order — `/todos/stream` first
(wire-mvc-examples **#53**), `/export` second (**#54**) — and the reason for that order turned out to be the
right hedge.

**`/todos/stream`** became `@EventStreamResponse` over a `ServerSentEventProducer`: SSE modelled as a codec
through `@ResponseMode(.streaming, codec:)`, the third use of that extension point after `@FormBody` and
`@YAMLResponse`, and the first on the streaming tier. What the route gained is the **mapped region** — the
handler call now sits inside the terminal's `building` closure, so a repository failure becomes a status
instead of an empty `200` with a truncated body. Mapping after the first byte is still impossible, which is
inherent to streaming; the raw version had the same exposure without saying so. Wire format unchanged, so
the existing assertions passed untouched on all three runtimes.

**`/export` surfaced the constraint the ordering was hedging against, and it was real.** `MultiPartSender<S>`
transforms the *sender*; the producer tier calls `send` itself and hands the producer a plain writer, so
`beginParts()` is never reached and the transform goes inert. The two are alternatives, not collaborators.
It resolved by **splitting the concerns rather than trading them**: `/export` is the producer tier,
`/export/raw` keeps the sender transform and `@RawRoute(.responseSender)`, and one shared `multiPartFrame`
means they cannot drift. Comparing the two bodies as an equivalence assertion was tried and is unsound —
`all()` promises no part ordering and `JSONEncoder` no key ordering within a part, both observed varying
between adjacent requests — so each route's framing is asserted separately.

**Independent of Phase 4, and of the duplex question generally**, as recorded: both routes are `@Get`s that
read no body, so neither can reach the `bodyStreamOnStreamingResponse` diagnostic.

So `@RawRoute` has shrunk to the routes that genuinely need the whole sender, which was the point of the
phase. `/export/raw` is the only one left in the examples repo, kept deliberately: it is the sole running
proof of a box-transforming middleware in either repository, since every wire-mvc fixture declares
`NextInput = Input`.

### Phase 2 — router correctness — **done**

All six items from `WireMVCRouter.md` shipped. The source listed them "roughly by value"; this note proposed
one change to that order — raise **percent-decoding** to second, as the only item producing a *silently
wrong value* rather than a wrong status or an absent capability — and that is the order the work took.

| | Item | Shipped as | What it turned out to be |
|---|---|---|---|
| 1 | **405 vs 404** | wire-mvc **#116** | `resolve` returns a three-way `RouteResolution`, but the *head* is written by a synthesised `registerMethodNotAllowed` handler, the sibling of the synthesised `404`. A router-written head carries no global `@Middleware` contributions, since only generated code has a `ResponseHeaderCarrying` context — so the obvious implementation would have dropped every contribution on the one response an app never declares |
| 2 | **Percent-decoding** | **#117** | Parameters only, and *after* the split, so `%2F` binds one parameter containing a slash rather than reintroducing a path boundary. Malformed input stays verbatim (Vapor's `removingPercentEncoding ?? $0`) rather than becoming a 400 the router invented. Hand-rolled, so the router stays free of Foundation on a per-request path |
| 3 | **Duplicate-route diagnostics** | **#119** | `insert` reports `.inserted`/`.duplicate(existing:)`; the builder turns the second into a `preconditionFailure`. Duplicate is a property of the **node**, not the template text — `/users/{id}` and `/users/{name}` are the same node, a collision comparing strings would miss |
| 4 | **Trailing-slash policy** | **#120** | `TrailingSlashPolicy` chosen where an app builds its router. `.lenient` (default) and `.strict` shipped; **`.redirect` deliberately did not** — canonicalising means writing a response head, so it would want a *third* synthesised handler beside the 404's and the 405's. Cheap once something asks; nothing has |
| 5 | **Full precedence** | **#121** + **#123** | Split in half. Order-independence (#121) was hiding a defect, not a missing feature: the parameter edge carried the `{name}`, so with `GET /users/{id}` and `DELETE /users/{userId}` the DELETE handler's value arrived under `"id"`. Names now belong to the route. Parameter-beats-catch-all fell out of #123 |
| 6 | **Catch-all / wildcard params** | **#123** | `{name*}` as the final segment, one-or-more segments, last only. The remainder is bound **undecoded** — the one place this router does not decode, because a remainder spans separators and decoding would turn `%2F` into a real path boundary before whatever resolves it ever sees it |

**This note's catch-all argument was overturned, and that is worth recording rather than quietly agreeing
with the outcome.** It argued catch-all belonged last because nothing in the 28 hummingbird-examples
registers one, and because the portability story was bad. Both facts held; the conclusion did not. #123's
reasoning is that blocking it was wrong regardless: catch-all is a standard capability every neighbour has
— Hummingbird's four wildcard forms, Vapor's `.catchall`, Go's `{path...}`, Express's `*`, Spring's `/**` —
with uses well beyond file serving, and refusing it *natively* bought no portability, since nobody had it
either way. It was also the thing item 5 was waiting on, so deferring it deferred two items rather than one.

The portability cliff was handled rather than avoided. `WireMVCServerTransport` **throws on a catch-all
route at registration** — not at codegen, since a controller in a shared package does not know which runtime
will serve it — so a catch-all controller serves natively only, entered knowingly. The example (#57) lives
in `SwiftHttpServerExample`'s own package rather than in `Controllers`, so the cliff is visible in the
layout instead of at boot. Whether it closes at a small seam is what
[CatchAllMountingProbe.md](https://github.com/tachyonics/wire-mvc/blob/main/Documentation/Notes/CatchAllMountingProbe.md)
measures — now with a native implementation to mount, which is what the probe needed.

**What came out of the phase that this note did not anticipate: a divergence matrix.** Three of the six
items make the native path behave differently from the bridged runtimes, and the difference is now measured
in each runtime's own suite rather than inferred from router source (wire-mvc-examples **#55–#58**):

| | native | Hummingbird | Vapor |
|---|---|---|---|
| wrong method on a real path | `405` + `Allow` | `404` | `404` |
| percent-encoded path parameter | decoded | **not decoded** | decoded |
| catch-all route | serves | refused at registration | refused at registration |

Accepted rather than filed as defects: on a `ServerTransport` runtime WireMVC collates onto the host's
router rather than owning it — the same position file serving sits in — and neither host exposes a hook,
both constructing their not-found responder internally. The two hosts reach the same `404` differently,
which matters if anyone proposes closing the gap: Hummingbird *has* the information and declines to use it,
while Vapor cannot tell the cases apart at all, the method being the first path component of its lookup.

### Phase 3 — parity examples — **done**

In the parity note's own order, which this note does not change. Each is an example rather than framework
work, so they are individually droppable and individually schedulable — and with Phases 1 and 2 closed,
this was where the remaining example-facing work was. All three landed, and each one turned out to be about
something other than its title: the file-serving item was about a middleware answering over the fallback,
the jobs item was about durability rather than about background work, and `auth-abac` overturned the half
of its own sentence that said *route-scope* — twice, since it ended up with no middleware at all.

1. ~~**File serving / s3-file-provider**~~ — **done**, and restated on the way, as this note asked. The
   item was never "file serving": `AssetsController` (#57) already served a tree through `@Get("/{path*}")`,
   which is the shape people expect and a *different* seam — a route runs inside the router, after a match.
   What was unexercised is a global `@Middleware` answering the request itself, from outside the router,
   over the `@NotFound` fallback.

   `SwiftHttpServerExample`'s `StaticFileServing.swift` now does it: a second global `@Middleware` on the
   composition root, with an injected `StaticFileStore` whose lookup is `async` because the example it
   stands in for is S3. It answers `GET`/`HEAD` under `/static/` via the box's `.responded` state, and
   **declines** everything else — which is why the app also gained an authored `@NotFound` carrying a
   `NoRoute` body, so eleven tests in `StaticFileServingTests` can assert *which* of the app's three
   reachable `404`s answered rather than only that one did. Native-path only, as this item said: the
   `ServerTransport` runtimes have no generated `@main` and therefore no global tier at all.

   Two properties the implementation settled, both structural rather than stylistic:

   - **A global file middleware must be prefix-scoped.** The front layer runs before the router and cannot
     ask whether a route would have matched, so an unscoped one shadows every route in the app.
     Hummingbird's `FileMiddleware` runs *after* its router declines; WireMVC's global tier has no such
     position, and the prefix is what stands in for one.
   - **It must answer with `respondingWith`, not raw `responding`**, or every header field an outer
     middleware contributed is discarded — CORS's `Access-Control-Allow-Origin` among them, on exactly the
     responses a browser fetches most.

   **And one finding that looked upstream — fixed in-house instead, and it paid.** A `@RawRoute` could not
   declare its response sender `consuming sending Sender` when the sender was the **untransformed** one:
   every raw route not behind a sender-transforming middleware, and always a `@NotFound`, which folds no
   middleware and so can never be handed a transformed sender. A reader took `sending` even then, through
   a fold; so did a transformed sender (`MultiPartSender<S>`). Only the untransformed sender refused, and
   each case was established by compiling it rather than by reading the codegen.

   **The cause was provenance, not the wrap and not aliasing** — regions permit aliasing within a region.
   The proposal's `HTTPServerRequestHandler.handle` declares `reader` and `responseSender` as `consuming
   sending` but `requestContext` as plain `consuming`, and the `ResponseHeaderRegistry` travels inside the
   context (it must: `handle` takes exactly four values and the context is the only extension point among
   them). So the registry was task-isolated, and `ResponseHeaderApplyingSender` merging it into an
   otherwise-disconnected sender is what closed the region.

   **The minimal fix was one word upstream** — `requestContext: consuming sending RequestContext` — and it
   was never asked for, because the API break was affordable while there are no consumers and the in-house
   route turned out to pay for itself. `ResponseHeaderRegistry` is now a `~Copyable` struct carried in
   `WireDisconnected` inside `WireMVCContext`, the treatment reader and sender already had; linearity is
   the load-bearing half, since `WireDisconnected` over a class compiles and is **unsound** (its
   precondition is that the stored value is never aliased, true of a linear value by construction and
   false of a reference). wire-mvc's
   [`LinearResponseHeaderRegistry.md`](https://github.com/tachyonics/wire-mvc/blob/main/Documentation/Notes/LinearResponseHeaderRegistry.md)
   records the design and the four places the plan turned out to be wrong.

   **It removed six allocations and 1536 bytes per request**, measured on a case where the registry
   genuinely escapes into the courier, reproducible to the allocation across two matched pairs. That was
   the *second* payoff the brief hoped for and could not promise, and it is larger than the one allocation
   predicted — why it is six is not attributed. So the upstream annotation, if it ever lands, is now a
   simplification rather than a rescue.

   The public break landed as expected and was smaller than feared: every middleware's
   `input.responseHeaders.add(…)` became `input.contributing { headers in … } then: { … }`, across
   wire-mvc, wire-open-api, wire-mvc-examples and wire-mvc-performance. The third option — a `Sendable`
   registry with a `Mutex` and `@Sendable` `onSend` closures — was not taken, and the reason still stands:
   it costs a middleware the ability to capture per-request state in a deferred contribution.

   The two smaller wire-mvc items are closed. `notFoundHandlerRegistersAsFallback` spelled its fixture
   with `sending` while asserting only on rendered source, so nothing compiled it — the only place in
   either repo advertising a spelling that could not work. It is true now, and compiled for real by two
   fixtures plus `SwiftHttpServerExample`'s `noRoute`. And two comments — `WireMVCExample`'s raw route and
   `WireMVCOutcome.send(on:)` — blamed the middleware fold for handing the sender out as "a plain
   `consuming` value", where both box destructures declare `consuming sending`; both now say that plain
   `consuming` is simply the permissive spelling.

2. ~~**jobs**~~ — **done**, in the shared `Controllers` package rather than in one runtime, so all three
   serve it. Two bindings, not one: a per-runtime `JobStore` holding the records, and a `JobWorker` that
   owns an in-process handoff, drains it, and *is* what the route talks to — bound
   `@Singleton(as: JobProcessor.self) @BackgroundService`, so the graph constructs one instance and hands
   it both to `JobsController` and to the app's `ServiceGroup`. `POST /jobs` awaits the store write before
   answering `202`, so the record is durable when the response is written.

   **The first cut kept the records in memory, and the write-up of it here was wrong**: it said the durable
   version "changes one line — where `submit` writes". It does not, and what it hid is most of what the
   item was worth. Giving the records a real store added a startup sweep, a double-delivery bug and the
   conditional claim that fixes it, an explicit at-least-once contract, and a rule about which test
   substitution primitive can reach a background service at all.

   - **The sweep exposed a bug that had nothing to do with persistence.** A route is reachable before its
     own service's `run()` has begun — nothing on any runtime orders serving after the `ServiceGroup`
     starts — so a job submitted in that window is handed to the loop by `submit` *and* found by the sweep,
     and it ran twice. Fixed at the claim, by re-reading the record and skipping a terminal one, which the
     serial loop makes sufficient. Pinned by a test that fails without it.
   - **`@BindType` cannot reach a background service.** It sources its instance from a `doubles` value
     threaded into a scope at entry, and an app-scoped service reading its store *before the first request*
     has no scope to be threaded through. So a service's collaborators are `@Replaces` territory — the
     mocked suite supersedes the CouchDB store with an in-memory one and stays Docker-free. This is the
     first `@Replaces` in wire-mvc-examples, and the rule is worth knowing generally.
   - **`@Singleton(as:)` combined with `@Contributes` had no consumer anywhere**, generic or otherwise —
     every contributor in swift-wire's own harnesses is a plain `@Singleton`. It composes correctly: one
     construction, two consumers.
   - **Vapor was discarding the collated services**, and had been since the collation existed, invisible
     while that runtime bound none. Vapor 4 has no ServiceLifecycle integration at all, so the app now
     builds the `ServiceGroup` itself in a `LifecycleHandler` — registered after the teardown handler, and
     implementing the synchronous `didBoot` because `app.testing()` boots through the non-async path.
   - **The drain is why the worker is a `Service` and not a `Task`**, and a failure after acceptance is a
     record rather than a status, since `@ErrorResponse` cannot reach a response already written.

   Three claims are measured rather than argued: substituting `cancelOnGracefulShutdown()` for the drain
   fails the drain test on 37–41 of fifty accepted jobs across three runs (a range, because it is a race);
   substituting `didBootAsync` leaves Vapor's `202` intact with nothing ever running the job; and removing
   the conditional claim makes a job submitted before the sweep run twice.

   The per-item record, including where the three backends stop being interchangeable, is in
   wire-mvc-examples'
   [`HummingbirdExamplesParity.md`](https://github.com/tachyonics/wire-mvc-examples/blob/main/Documentation/Notes/HummingbirdExamplesParity.md),
   item 3.
3. ~~**auth-abac / auth-permissions**~~ — **done**, and the "composed by route-scope middleware" half of
   the item is what it overturned. Seven rules, each an ordinary `@Singleton` contributed to one
   `CollectedKey<any AccessPolicy>`, combined by a `PolicyEngine` that names none of them
   (deny-overrides, then permit-required); `/documents` in the shared `Controllers` package is the
   resource. **No per-runtime binding anywhere** — the policy set, the engine, the request bindings and
   the store are all portable — which makes it the only feature in that repository whose arrival on a runtime costs that
   runtime nothing, where `TodoRepository`, `SessionManager` and `JobStore` each cost a binding.

   **Once policy is a set of bindings, the annotation stops carrying policy.** A route-scope placement
   would say "this route is the one that needs screening", which is a second, hand-maintained encoding of a
   decision the set already makes. The first pass answered that with a single *controller*-scope gate; the
   second removed the gate outright, so no annotation carries policy at all — see *What it became* below.
   That is the real contrast with the API-key gate, and it is not strictness: the toy encodes its rule in
   the placement, so reading the app's policy means grepping for annotations.

   **Three structural findings, all about what a middleware is not told** — and per-route policy could not
   have been expressed by placement anyway, which is the first of them:

   - **A middleware does not know which route it is on.** The box carries the request, the context, the
     reader and the sender; the matched template and the path parameters stay in the generated register
     closure. A genuinely per-route rule needs its own key and its own middleware type.
   - **A middleware cannot reach a request-scoped binding**, for two independent reasons, each established
     by compiling the alternative. A `@Factory` template's `@Inject` deps resolve **once**, into the
     synthesised `_WireFactory_<key>`, which is an app `@Singleton`; and the fold is entered before
     `_wireEnterScope`, which happens inside the fold's own terminal, so there is no scope in existence
     when `create` is called. A gate therefore has to resolve the subject from the request while the
     request-scoped `Caller` resolves it again — two dictionary reads, or two round trips against a real
     identity provider. The shipped example no longer pays this, because it no longer has a gate; it is a
     cost of the optimisation rather than of the design.
   - **There is no channel from a middleware to the handler**, so the first resolution cannot be handed
     forward even in principle: the terminal destructures the box and discards the context. A
     context-transforming middleware, which the box does support, therefore reaches no handler either.

   **A swift-wire diagnostic bug fell out of the first of those, and belonged to this repository** —
   [#16](../../CompletedIssues/16-factory-template-scope-hint.md), **since fixed**. Injecting
   a scoped binding into a factory template reports `no binding produces 'Caller'` with a guided note —
   *"scope `_WireFactory_ControllerMiddleware_screenAccess` to `@Scoped(seed: HTTPRequest.self)` too, or
   extract the scope-bound concern into a wrapper bound at the wider scope"*. The first half cannot be
   written: `@Scoped` and `@Factory` both synthesise an `init`, so together they are an `invalid
   redeclaration`, and with the `init` supplied by hand the plugin ignores the scope macro and diagnoses
   the template as a singleton anyway. The text is the generic scope-mismatch guidance and a factory
   template is the case it does not fit — so it sent a reader at a combination that has no spelling.
   Closed by the step below: the combination is now refused outright as two lifetime macros on one
   declaration, and the note names the *template* and the moves that exist.

   **The double resolution turned out to be a smaller item than it first looked.** Its *cost* is closable
   in the application by caching the lookup, which a deployment with a real identity provider does anyway,
   and the two resolutions cannot diverge because both go through one method — so what a framework change
   buys is only agreement by construction. The obvious fix is also the wrong one: folding inside the scope
   destroys the pre-authorisation property (a gate refusal skips scope construction entirely) and drops
   every contributed header field from the `401`. The answer moved authorisation into the *argument*, via a
   request binding with graph access — a seam that already sits after scope entry. wire-mvc's
   [`ScopeAwareMiddlewareAndBindings.md`](https://github.com/tachyonics/wire-mvc/blob/main/Documentation/Notes/ScopeAwareMiddlewareAndBindings.md)
   carries the designs, the four costs of the obvious reordering, the prior-art survey behind each, and a
   sequence with a forcing case per step — including a decision to keep middleware **app-lifetime
   permanently** rather than build a scoped tier, since the prior art is unanimous on that and the tier's
   only remaining charter is served more cheaply by carrying route identity on the box. **This repository
   owned three steps of it, and all are done (2026-08-27 to 2026-08-28).** The first — naming
   `@Factory` as a lifetime in its own right and diagnosing it as one — needed no source migration,
   since `@Factory(K)` was already written correctly everywhere; what changed is that a scope macro beside
   it is refused as the contradiction it is, and that the cross-scope note says something true. The second
   — a seeded scope yielding more than its subject — took the scope-entry thunk's return from a tuple to a
   named `_WireScopeEntry_<Subject>` struct, and made the extra bindings *inferred* rather than declared: a
   bridged subject's entry hands back every binding in its scope that its method parameters name. A yielded
   binding is a construction root in its own right, since nothing inside the scope depends on something
   whose whole purpose is to leave it. **The struct is a break for the one consumer that exists**: a scope
   entry now returns one value rather than a pair, so wire-mvc's generated terminal changed with it.

   The third was not foreseen, and is the one worth reading. Inference alone was not enough, because the
   attribute a route parameter carries is **not** the binding that resolves it: `@AuthorizedDocument` is a
   property wrapper, and the `@Scoped(seed:)` worker is a second type it names. Only a property wrapper can
   attach to a parameter, and a wrapper's instance holds the value the call site supplies while a graph
   binding's holds what the graph supplied — so no one type can have both initialisers be total, and the
   two-type shape is forced rather than chosen. `WireAdapterAnnotationV1`'s `.injectsFromGraph` capability
   now follows **one hop**: a use-site naming a type that is itself annotated for the graph yields *that*
   type on the scope entry. First-seen wins, and the subject is never yielded to itself.

   The alternative was rejected on sight, and the reason generalises: an explicit `@ScopeYield(Worker.self)`
   on the wrapper would have been ceremony the author cannot motivate — *"it will not be clear to a user
   why `AuthorizedDocument.self` needs to be `@ScopeYield`; it doesn't do anything for them."* An adapter
   annotation that already says which worker does the work is enough for swift-wire to read.

   **So the decision splits in two, and the split is the item.** "Can subject S do action A on resource R"
   turns on the resource, which has not been loaded when the request arrives — so the same set is consulted
   twice by two callers with different attributes in hand, and a rule that needs the resource returns
   `.notApplicable` when there is none. A third question falls out: `GET /documents` neither screens nor
   refuses per document, it *filters*, on the same decision function the item route uses, which is what
   stops a list from disagreeing with a read.

   **Whatever asks first must answer *deny or undecided*, never permit** — the one thing here that would be
   a security bug rather than a missed optimisation. Every resource-reading rule abstains without a
   resource, so such a query is missing an unknown number of the rules that would have denied it, while the
   resource-independent `ReadGrant` permits every read. `screen` returns `AccessDenial?` rather than a
   decision, so the mistake is unwriteable rather than discouraged.

   ### What it became

   **The split is by attributes, not by layers, and that is a correction to what this entry first said.**
   Both questions now run inside the request binding, in the order the attributes arrive: screen from the
   request, load, then decide. The controller-scope gate was deleted and **no status changed on any route**
   — measured on a spike across 21 policy tests and three runtime suites before it was decided. A front
   tier remains a real optimisation, refusing before the request scope is constructed at all and covering
   routes nobody has written yet; it is not a correctness requirement, and it costs the double resolution
   above. wire-mvc's design note carries the withdrawal in full.

   That matters here rather than only downstream, because "the resource is not loaded when the *middleware*
   runs" was the sentence that made a scoped middleware tier look necessary. The resource is not loaded
   when the *request arrives* — which is a fact about attributes, and a binding is on the right side of it.

   Two smaller things the implementation settled. **A refusal names the rule that produced it**, which is
   the observation channel a suite needs: `@ErrorResponse(AccessDenied.self, .forbidden, { $0.denial })`
   encodes the denial, so a test asserts that `ClearanceRule` refused rather than that something did. The
   first pass used a cruder channel — the gate answered with a body and a mapping answered a bare status,
   so a test could tell which *layer* refused by whether bytes came back — which reported plumbing rather
   than policy and evaporated when the layers merged. And **a `@Scoped` controller under a keyed test suite
   needs `withClient(supplying:)` even when it substitutes nothing**: the doubles struct is empty, but an
   uncorrelated request still gets the harness's explicit `500`, and the failure is *partial* — requests
   refused before the terminal never look the doubles up and pass — so it reads as a broken policy tier
   rather than an uncorrelated request. That sits beside the jobs item's
   `@BindType`-cannot-reach-a-background-service rule.

   The exhaustive caller × action × resource matrix is a table in a unit suite rather than a request each,
   for the reason that suite states: an authorisation bug does not throw, it answers `200`, and it answers
   `200` only for the caller nobody drove a request as. The runtime suites assert what only a driven route
   can — that the decision reaches the response, and that the two tiers are two — on all three hosts. The
   per-item record is in wire-mvc-examples'
   [`HummingbirdExamplesParity.md`](https://github.com/tachyonics/wire-mvc-examples/blob/main/Documentation/Notes/HummingbirdExamplesParity.md),
   item 4.
4. ~~**upload**~~ — **covered, and the item wants striking or restating.** `UploadController` (#46/#47)
   already runs both shapes: `POST /upload` binds `@MultipartSummary` on the `.readerBody` tier and
   `POST /upload/stream` binds `@MultipartStream` on the `.bodyStream` tier, neither ever holding the
   upload. That is the unbounded-body-in half of the item, and it landed before this note was assembled —
   listing it as outstanding was a staleness of exactly the kind the note exists to catch.

   What is *not* covered is the sentence after it: a large streamed upload answered with a **streamed
   response**, which is the echo's shape and belongs to Phase 4's blocker, not here.

### Phase 4 — the typed duplex tier — **blocked upstream**

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
- **The lent-binding validation step — still open.** Duplex is the first shape where the handler runs
  *after* the head, so `MultipartParts.init`'s deferred content-type check would truncate a response
  instead of mapping to 415. Fixing that changes a **public binding protocol**, which is cheaper before 1.0
  than after — so it wants doing on 1.0's schedule, not on #91473's, even though the feature it serves is
  paused. Still a spelling rather than a protocol today: `RequestBinding.swift:38` calls the
  `MultipartParts(request:reader:)` init "a spelling, not a protocol", which is exactly the gap.

### Phase 5 — allocation reduction in the native request path — **two thirds done**

**The header path is finished, in eight changes rather than the two this note listed; the registry is gone
entirely; the router path is untouched.** Not a correctness item and not urgent: the whole native path is ~0.9 µs at p50 and ~1.2 µs at
p99, against a `ServerTransport` bridge that costs 16–47 µs. It is here because the measurements exist, the
causes are identified, and the fixes that remain are small enough that leaving them undone is a choice
rather than a backlog.

Measured in [wire-mvc-performance](https://github.com/tachyonics/wire-mvc-performance) with a `malloc`
interposer, bisected in process so the numbers are the router's rather than a socket's. **Twelve
allocations and 920 bytes per request** — re-measured 2026-08-25 against wire-mvc `1437735`, where it was
nine and 756 when this note was assembled, and thirteen before the re-measurement's own finding was fixed. For contrast, Hummingbird's router adds *none* — so these are
choices in this implementation, not the cost of routing.

**That twelve excluded the courier, and a real request was paying eighteen.** These cases drive the router
directly; the courier sits above it and the bisection never priced it, reporting +0.0 for group #4 while
the true cost was 6 (see *#4* below). Since wire-mvc #148 the courier costs nothing, so twelve is now the
whole native figure rather than the visible part of it.

**On time, there is nothing to fix.** Scope-matched — WireMVC's trie served on the bare server with no
courier and no registry, against each framework's own routerless floor — its router is indistinguishable
from Hummingbird's, both at or below what the harness can resolve, with Vapor's the only measurable one at
about +4 µs. So this phase is about allocations, which are real and countable, not about latency, which is
already at parity. Anyone reaching for it as a performance fix is reaching for the wrong thing: the bridge
costs 16–47 µs and everything here is fractions of one.

**The header *mechanism* is the one place that is not quite parity, and it is a tenth of a microsecond.**
Both frameworks driven in process, six runs each: Hummingbird's `RouterMiddleware` costs **+0.29 µs** over
its own plain routed case and WireMVC's registry-plus-applying-sender costs **+0.41**. Hummingbird's figure
is the `HTTPFields` insertion and nothing else — it lands exactly on what inserting one field costs,
measured independently from the other direction — so WireMVC's extra **~0.12 µs** is what the
sender-not-return-slot model costs over mutating a response that already exists.

**That tenth splits, and only part of it is inherent.** About a third is the registry's *size*: making it
`~Copyable` turned an 8-byte class pointer into a 240-byte value, moved about five times per request, and
shrinking it (inline capacity 4 → 1, 240 B → 72 B) takes the mechanism from +0.41 to +0.37. Not taken —
`CORSMiddleware` contributes four fields, so capacity 1 sends it to the overflow array and puts an
allocation back where the inline storage earns its place, and capacity 2 measures no better than 4. The
other two thirds are register-now-apply-later itself: storing a description of the operation, carrying it,
walking the registrations and dispatching on the case to replay it. Registering costs nothing measurable;
a fast path for the common single-`.value` case might take 0.03 … 0.05 of the rest, untested.

**Closed rather than open.** The whole 0.12 is under 0.2% of a real request against a bridge costing
16–47 µs. It is written down so the number has an explanation attached, not as an item.

**Two measurements had to be thrown away to get that, and both failures are the same shape as the
allocation ones.** The socketed rows put the gap at ~1.3 µs, which is inside their own ±1.6 µs spread, and
the WireMVC row was not even scope-matched — it served on the courier server against a bare-server
baseline, charging WireMVC for the courier as well as the mechanism, the same error `proposal-routed`
exists to have stopped making for the router row. Then the in-process Hummingbird driver turned out to be
measuring **executor hops**: `HTTPResponder.respond` is `@Sendable`, the harness enables
`NonisolatedNonsendingByDefault` and Hummingbird does not, so every request hopped to the global executor
and back. Its floor read 15.9 µs against WireMVC's 0.88 and its delta was noise; on the executor the call
actually wants, the floor is 1.02. Both wrong numbers were published before being caught, and both looked
reasonable. At this scale an instrument has to be checked as carefully as a cause.

**Now entirely a native-path project.** On a bridged runtime the host's router matches the path and
parameters arrive as `metadata.pathParameters`, so `FrozenRouteTrie.resolve` never runs and groups #1 and
#2 — the two clearest wins below — do not exist there. The registry used to carry over, allocated per
request at `WireMVCServerTransport.swift:339` whether or not anything contributed; it is a `~Copyable`
struct now and allocates nowhere, on any runtime. What still counts everywhere is header *resolution*,
which runs whichever router matched, and that is finished. So what is left of Phase 5 is **4 allocations
off a native request and nothing at all off a bridged one** — groups #1 and #2, both in the router.

**The count is for a request that contributes no headers**, and **none of the four original groups has
been touched.** A route with a contributed header pays for resolution on top; that was the largest single
item found and is now closed — see *The header path* below, which is measured on its own scale and does not
appear in this total.

**Nine became thirteen, and the re-measurement is the reason this note now carries two more items.** The
four original groups are unchanged to the allocation. What moved is everything after them:

| | allocs/req | |
|---|---|---|
| route, parameter, and building the response — groups #1–#3 | 8.0 | unchanged since first measured |
| **+ stating a `Content-Length`** | **+4.0** | arrived with the framing fix, #125 — new item **#7** |
| ~~+ `WireMVCOutcome`'s `[:]` default~~ | ~~+1.0~~ | a live sibling of the #129 defect — **found and fixed** |
| ~~+ `ResponseHeaderRegistry` (group #4)~~ | ~~+0.0~~ | never visible here; measured at **+6.0** where it escapes, and now **0** — read below |
| | **12.0** | 920 bytes |

Each row is a pair of cases differing in exactly one thing, measured by slope (22,000 against 62,000
requests, so process startup cancels) and reproducible to the allocation across runs.

| # | what | count | addressable | what it would take | status |
|---|---|---|---|---|---|
| 1 | `split` array growth in `FrozenRouteTrie.resolve` | 2 | **yes** | walk segments lazily instead of materialising `[Substring]` | **open** — still `requestPath.split(…)` at `RouteTrie.swift:276` |
| 2 | parameter collection + `Dictionary(zip(…))` | 2 | **yes** | inline buffer for the 0–2 case; name lookup against the route's own `parameterNames` | **open** — do with #1 |
| 3 | response body + write path | 4 | partly | the bytes are the work; some copies may be avoidable | **open, deliberately** — measure first |
| 4 | `ResponseHeaderRegistry` instance | 1 → **6** | **yes** | the `~Copyable` struct, not the lazy allocation | **shipped**, wire-mvc #148 — and it was worth six, not one; see below |
| 5 | `apply`'s array-valued subscript, **per contribution** | 7 → 5 | — | scalar `HTTPFields` API | **shipped**, wire-mvc #128 |
| 6 | `resolved`'s wrapper around `apply` | 2 | — | it was the *defaulted parameter*, not the round-trip | **shipped**, #129 — and the note's guess was wrong; see below |
| 7 | stating a `Content-Length`, **every response, every runtime** | 4 | **no** | nothing left — the one idea was tried and measured identical | **closed as not-addressable**; see below |
| 8 | `WireMVCOutcome.init`'s `headerFields: HTTPFields = [:]` | 1 | — | `HTTPFields()`, exactly as #129 did to `resolved` | **fixed** — all seven defaults, across `Responses.swift` and `StreamingResponses.swift` |

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
naming (wire-mvc #121, Phase 2 item 5), which removed a registration-order dependency — so the inline
version recovers what that cost rather than undoing it.

**#3 is the one to leave alone for now.** Four allocations to build and write a response body is the least
suspicious group: producing bytes and handing them to a sender is the work itself. Attributing them
individually needs an allocation *list*, not a counter, which means Instruments.

#### #7 and #8 — what the re-measurement found

Both are on the **typed** path and both count on **every runtime**, since `WireMVCOutcome` is what sends
whether the host's router matched or ours did. Neither existed as an item before the count was re-taken,
which is the argument for re-taking it rather than carrying a number forward.

**Both were acted on, and only one of them survived contact with the measurement.** #8 is fixed and worth
one allocation on every typed response on every runtime. #7 had one idea, it was implemented, it measured
nothing, and it was reverted — which is the more useful of the two results.

**#7 — framing costs four allocations, and it is not `String(Int)`.** A hand-written handler that writes a
bare `HTTPResponse(status:)` costs 8; the same handler stating a `Content-Length` costs 12. The obvious
suspect is the `String(length)`, and it is innocent: a case building that string *once at registration*
measures identically to one building it per request, because a length like `"1024"` fits Swift's inline
string form and never reaches the allocator. All four are the **field insertion**, and that number is not
WireMVC's to fix — the `+fields-N` ladder puts every response header field at 3–4 allocations, which is
what inserting into `HTTPFields` costs.

**One of the four looked like ours, and it was not.** A handler that builds `var fields = HTTPFields()`,
sets the length and hands it to `HTTPResponse(status:headerFields:)` pays **3**, where `stateLengthIfAbsent`
mutating an already-constructed response pays **4** — so the typed path was changed to state the length
into a local `HTTPFields` before constructing the response. It measured **identical**: 12 either way.

The difference was between the two *cases*, not the two spellings. The hand-written handler builds its
fields fresh; `WireMVCOutcome.send` has to copy `headerFields` off the outcome, and the copy costs exactly
what the later mutation would have. **The allocation moves; it does not go.** Reverted, with the reasoning
left in the source, because it is the kind of idea that gets proposed again — and it is the third
attribution in this phase that was convincing and wrong. That is now the reliable pattern rather than the
exception: at this scale, nothing here should be changed on an argument.

**This is a trade, not a regression, and it should not be argued as one.** Those four allocations bought a
p99 tail of 12–19 µs on every server tested. They are listed because they are countable and had not been
counted, not because they should be given back — the same discipline the rest of this phase asks for.

**#8 was a defect, and it is the one from #129 that got away — now fixed.** `WireMVCOutcome.init`
defaulted `headerFields: HTTPFields = [:]` — a dictionary literal, the exact spelling #129 removed from
`WireMVCResponseHeaders.resolved` after measuring it at one allocation per call. A case passing
`HTTPFields()` explicitly and differing in nothing else measured 13 against 12, which is how it was found.
Every typed route that does not return header fields paid it, which is most of them. All seven remaining
defaults — six in `Responses.swift`, one in `StreamingResponses.swift` — now spell it `HTTPFields()`, and
the pair measures equal, which makes it the regression guard as well as the diagnosis.

That #129 fixed one call site of this and left seven is worth more than the allocation: the fix was applied
where the measurement pointed rather than to the pattern, and nothing looked for the pattern elsewhere. The
sweep this time was a two-token grep. Worth doing after any fix whose cause is a *spelling* rather than a
place — which, in this phase, has been most of them.

#### #4 — the registry, and why this bisection never priced it

**It read zero here for the wrong reason, and the honest number was six.** Group #4 measured +1 when first
taken and +0 afterwards, because in these cases the registry never escapes the handler and the optimiser is
free to promote it. The note said so at the time and said what it would take to measure honestly: a case
where it escapes. `+courier` and `courier-headers` are those cases — the courier is exactly where the
registry escapes into the request context — and against them the class cost **6 allocations and 1536 bytes
per request**, reproducible to the allocation across two matched pairs and two replicates.

It is now zero, for real. `ResponseHeaderRegistry` became a `~Copyable` struct, which was not done for this
phase at all — it was forced by an ownership problem, since a task-isolated registry merged into a response
sender stopped a `@RawRoute` declaring `consuming sending Sender` (Phase 3, item 1 above). The allocation
saving is a side payment, and a larger one than the lazy-allocation idea this table proposed: lazy would
have made the *uncontributed* case free, where linearity makes every case free.

**And it bought no time at all, which is the phase's thesis holding rather than a disappointment.**
Socketed, the header-mechanism row is unchanged within noise — but socketed noise there is ±1.6 µs, which
cannot resolve six allocations either way. The in-process pair can, at ~0.05 µs: `courier-headers` −
`routed-match` measures **+0.41 µs before the change and +0.41 µs after**, p50 identical to the hundredth
across three reps of each binary. Six allocations per request, zero measurable time. Allocations here are
real and countable; latency is already at parity, and anyone reaching for this phase as a *performance*
fix is reaching for the wrong thing.

**Two lessons worth more than the six.** The estimate in this table was 1, from reading the type — a
`final class` is one instance, so one allocation. It was six, and why it is six is *still not attributed*:
an extra async frame does not explain it, since `WireMVCContextHandler` is untouched and the after-figure
is zero. And the bisection reported +0.0 for two revisions while the true cost sat at 6, because the case
it measured was not the case that runs. A number a harness cannot see is not a number that is not there.

#### The header path — finished, in eight changes rather than two

Header resolution was the largest single item found, and this note listed it as two: the array-valued
subscript (#5) and `resolved`'s wrapper (#6). It took eight, because each fix exposed the next one behind
it. All of it counts on **bridged runtimes as well as native**, since header resolution runs whichever
router matched.

The chain, for **one contributed header resolved into `HTTPFields`** — each figure measured in process by
the change that made it:

| | change | | |
|---|---|---|---|
| #128 | `apply` through the **scalar** `HTTPFields` API | 7 → 5 | `fields[values: name] = [value]` built an `Array` to carry one value, and `.setIfAbsent` built one *just to ask `.isEmpty`*, then another to write |
| #132 | non-variadic `add` | `add`: 2 → 1 | `add` was variadic, so `add(.set(name, value))` built an `Array` for the argument and boxed it into a `.values` case. Every caller passes exactly one |
| #135 | `InlineArray<4>` registrations + `drain(into:)` | 5 → 3, `add`: 1 → 0 | the registration array grew on the first `add`; `drain()` built an array for its caller to iterate and discard |

And three that are not on that scale, each at its own call site:

| | change | measured | |
|---|---|---|---|
| #129 | default `returned` to `HTTPFields()`, not `[:]` | 1 allocation per call | a dictionary literal ran `init(dictionaryLiteral:)` at **every typed route**, since only a handler returning response fields in its tuple passes one |
| #130 | apply contributions onto the head the handler wrote | 17 → 3 allocations, 2.75 → 1.96 µs | on the raw-route path `statics` is always empty, so replaying `returned` into an empty `HTTPFields` reproduced what `response.headerFields` already was |
| #138 | applying sender through `drain(into:)` | 6 → 5 | the one call site still doing the round-trip `drain(into:)` was added to remove — and it runs for every raw route |

**Item #6 was real but this note guessed its cause wrong, twice over.** An earlier version said the
subscript was worth 7 → 3; re-measurement after #128 landed put it at 7 → 5, with the other 2 attributed to
`resolved`'s `applying(returned:)` round-trip. That attribution was also wrong. Guarding the round-trip was
tried **twice**, before and after, and changed nothing; the 2 allocations were the **defaulted empty
parameter** — the candidate this note named as the alternative and did not pick. #129 fixed it. #134 later
removed the replay anyway, because with no statics it reproduces `returned` exactly, but that is a
simplification rather than the allocation win it was predicted to be.

The lesson is the one the bisection already carried: at this scale a plausible cause with a delta of the
right size is not evidence. Three attributions in this section were wrong before measurement corrected them,
and each was individually convincing.

**#137 is the largest single win here and was nowhere in this note.** `WireMVCOutcome.send` used the
two-argument `sendAndFinish` spelling, which cannot match the three-parameter protocol requirement — Swift
forbids defaults on requirements — so it bound to the same-signature extension and never dispatched through
the witness. `BridgeResponseSender` fuses head and body into a known-length response *in its witness*, so
**every buffered response took the streaming path**: `deliverStreaming`, the `AsyncChannel` rendezvous and a
`HandlerTaskHandle`, for a body already complete. The bridge's own comment called the fused path "the typed
path"; nothing reached it. Worth **5 allocations per request** through the Hummingbird bridge, whose
`contentLength:` fast path only a known-length body can reach. Vapor is unchanged, which matches
OpenAPIVapor building every body the same way regardless.

It is the same upstream wart as the deferred head under *Response framing*, found from the other end.

The original bisection is still worth keeping, because it contradicted the two obvious guesses:

| step | µs |
|---|---|
| registry allocated but unused | +0.04 |
| `add` + the `async drain()` | +0.13 |
| **`WireMVCResponseHeaders.resolved`** | **+0.21–0.29** |
| building `HTTPField.Name` per request | +0.04 |
| applying sender + deferred head | +0.04 |

The `async drain()` was the suspect going in — an await per response — and it is 0.13 µs. Per-request
`HTTPField.Name` construction, the other candidate, is 0.04. Neither was the answer.

**Behaviour pinned along the way**, because "equivalent spelling" was an assumption worth checking: `.set`
must clear *every* value a name already has, which both spellings do; and `HTTPFields`' scalar setter
special-cases `Cookie` by splitting on `"; "` where assigning `[value]` stored one field containing the
separator. That last is a real divergence, narrow enough to accept — `Cookie` is a request header and
malformed on a response, and `Set-Cookie` is not special-cased. #130's five equivalence tests and #135's
three ordering tests were each run against the *previous* implementation and pass there too, which is what
makes them evidence of equivalence rather than of the new code agreeing with itself.

**What this does not close.** The socketed harness reported this mechanism at ~3 µs and the in-process one
at ~0.5. The in-process figure is the trustworthy one; the difference is the ~2.5 µs of jitter in the
proposal baseline (see the harness README). Anything at single-µs scale has to be measured in process
until that is understood. And none of this is a latency win — #135 says so explicitly, and it is worth
repeating: these are allocation wins and should not be justified as the other thing.

#### The registry — all three options are closed, and none of them by this section's argument

This section proposed three options, priced option 1 as the cheap 80% and argued the ownership case for 2
and 3. **All three are now closed: #135 built the inline buffer, #148 made the registry a linear value, and
option 3 shipped whole.** What is worth keeping is that it shipped for a reason this section never named.

`ResponseHeaderRegistry` is a `~Copyable` struct (`ResponseHeaderRegistry.swift:47`) holding
`InlineArray<4, Registration?>` with an overflow `Array` past four, `add`/`onSend` `mutating` and `drain`
`borrowing`. The courier no longer instantiates a class per request on any runtime — item #4, closed. Only
`onSend`'s escaping closure still allocates a payload, and that is inherent.

**The forcing reason was soundness, and it is none of the three arguments below.** A `@RawRoute` could not
declare `consuming sending Sender` while the registry merged into the sender was task-isolated, and
`WireDisconnected` over a class would have compiled and been *unsound* — Phase 3, item 1 carries that
account. Neither appears in the three options here, which is the entry worth reading twice: the change this
section spent the most words declining to justify was carried by an argument it had not considered, from a
phase it does not mention.

So the re-pricing above is spent rather than open:

1. **Allocate lazily** — dead, not open. There is no per-request allocation left to make lazy, and
   linearity made every case free where lazy would have freed only the uncontributed one.
2. **`~Copyable` struct with a heap container** — dead; superseded by 3.
3. **`~Copyable` struct with an inline buffer** — **shipped**, #135 and #148.

**The plumbing this section called blocking is gone.** The three-way aliasing is not aliasing any more:
`ResponseHeaderApplyingSender` is itself `~Copyable` and owns a `ResponseHeaderRegistry` by value
(`RequestContextCourier.swift:204`), and the two codegen read sites no longer have to agree because codegen
*threads* the registry rather than reading it twice — the raw-route-with-middleware path builds the wrapper
from the registry the box yields as the fifth value of its consuming destructure, rather than from a local
read above the fold. The registry also lives in `pending` only; `responded` carries none and is
`responded(request:)`, which killed a claim the box had carried since the registry was a class — that
holding it in both states let an always-run observer further in still contribute. It never did.

**This registry's deadline is spent.** Option 3 changed the public shape as predicted — every contributing
middleware's `input.responseHeaders.add(…)` became `input.contributing { headers in … } then: { … }` — and
it is now on the far side of that date rather than approaching it. Six allocations and 1536 bytes per
request, and no measurable time at all: see *#4* above for the measurement and Phase 3, item 1 for the
break.

**Sequencing, and a claim this note carried that was wrong.** It said #1 and #2 are "internal to
`WireMVCRouter` and can be done any time". That holds for #1 and for **half** of #2. The `[Substring]` of
parameter values is internal and can take the same `InlineArray` treatment #135 gave the registry. The
`Dictionary` is not: `[String: Substring]` is written into `HTTPServerRouteBuilder.register`'s handler
shape (`Routing.swift:36`), whose own comment says **"WireMVC owns this shape"** — so removing it is not an
upstream ask, but it *is* a public break across every conforming builder including user-written ones, every
codegen emission of `{ request, requestContext, pathParameters, reader, responseSender in }`, and both
adapters. It is therefore the same pre-1.0/post-1.0 trade the registry just spent, and **the registry was
not the last item in Phase 5 scheduled by 1.0** — half of #2 still is.

A constraint on that decision, not previously recorded: on a bridged runtime the parameters arrive as
`metadata.pathParameters`, which the proposal types as `[String: Substring]`. So a positional replacement
either has to be constructible from a dictionary — bridged pays what it pays today — or the shape has to
abstract over both, which is a larger change than the two allocations justify on their own.

The rest is unconstrained: #1 is internal, and #3 stays parked until it can be attributed by an allocation
list rather than a counter. All of it is native-path-only, so it is worth exactly as much as the native
path is.

**Caveat on the analysis.** The four groups are measured; the identity of every individual allocation
within groups 2 and 3 is inferred from the code rather than observed. Confirming those needs an allocation
list.

**The caveat about re-walking the contribution sites paid out, and should stay standing.** It named
`respondingWith` on the gate path and the keyed-harness variants as untraced. The gate path was traced and
was never wrong — `respondingWith` drains on its way out — but the walk found the asymmetry hiding *behind*
it: a served response resolved against the drain and a **mapped** one did not, so every contributed field
survived a `200` and vanished from every `@ErrorResponse` status, which is backwards, since a `403` without
its `Access-Control-Allow-Origin` and a `401` without its `WWW-Authenticate` are the responses that need
them most. Fixed in #155, seven commits after the redesign, found from an examples spike rather than from
the redesign's own review. The keyed-harness variant paths are still untraced.

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

- **The upstream fix — written, not yet upstreamed.** `HTTPResponseSender` declares
  `sendAndFinish(_:buffer:trailer:)` as a requirement *and* supplies a same-signature extension with
  `trailer` defaulted. A two-argument call — the spelling nearly every raw route uses — cannot match the
  requirement (Swift forbids defaults on requirements), so it binds to the extension, which expands to
  `send` + `finish` and never dispatches through the witness. Any conformer's override is silently
  bypassed, contradicting the proposal's own advice that conformers are encouraged to override it.

  The fix is small and exists in a local `swift-http-api-proposal` working tree: drop the default from the
  extension implementing the requirement, and add a **distinct** two-argument overload that forwards to the
  requirement, so the call dispatches through the witness. A `ResponseSenderDispatchTests.swift` goes with
  it. **Neither is committed or submitted**, and wire-mvc pins revision `638af2b`, which is before it — so
  nothing downstream sees it yet. This is now the smallest remaining item in the whole note and the only
  one whose next step is a pull request against someone else's repository.

- **The workaround has been removed, so the exposure changed shape.** wire-mvc #139 dropped the courier's
  deferred head. It worked and cost almost nothing (0.05 µs, no allocations), but it required a `~Copyable`
  state machine with an explicit in-flight placeholder — a throw between consuming the state and
  reinitialising it would leave `self` consumed — to work around an API wart that is being fixed at source.

  So the trade-off this note recorded is **gone**: streaming raw routes get their head flushed at `send`
  again rather than at the first `write`, which is what they always did. What replaces it is narrower and
  more honest — until the upstream fix lands, **a two-argument raw route frames as chunked**. Every call
  site in wire-mvc uses one or three arguments and is unaffected, as is every typed route. A test pins the
  gap and is documented as expected to fail when the fix arrives, at which point it should be inverted.

- **The same wart cost more than framing.** #137 found the other end of it: `WireMVCOutcome.send` used the
  two-argument spelling too, so every buffered response missed `BridgeResponseSender`'s fusing witness and
  took the streaming path. Worth 5 allocations per request through the Hummingbird bridge — see *The header
  path* in Phase 5. One upstream overload-resolution wart, two unrelated-looking symptoms — a chunked
  response, and a buffered body taking the streaming path — found from opposite ends on the same day. That
  is the argument for fixing it upstream rather than working around it a third time.

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

## Mounting on Hummingbird and Vapor: four options, and why there are four

Measured in [wire-mvc-performance](https://github.com/tachyonics/wire-mvc-performance) by building a native
Hummingbird adapter and reading Vapor's own proposal-server adoption. This supersedes the framing of
"native adapters, pending rationale" — the rationale is here, and the answer is not one option.

### The mismatch, and where it lives

The proposal hands a handler **both carriers for its whole lifetime**:
`handle(request:requestContext:reader:responseSender:)`. Nothing is returned; the handler writes. WireMVC
follows that model, which is what lets `@RawRoute` be a literal passthrough of the carrier types.

Hummingbird and Vapor route handlers **return a response**. Their routers are built on that, it is their
public API, and they have no reason to change it.

Adapting between the two is **asymmetric**, and this is the whole of the analysis:

- **Return-based → push-based** composes structurally. The responder returns a *description* — Vapor's
  `Response.Body` is `.stream(BodyStream)`, a callback not yet run — so the adapter gets the head first and
  can drive the body callback into the sender inside its own scope. Vapor's `VaporHTTPServerHandler` does
  exactly this in ~100 lines with no concurrency machinery.
- **Push-based → return-based needs an unstructured task.** The head must exist before the closure returns
  (a `Response` cannot be built without a status) and the body must be written after. WireMVC's handler
  produces both, in that order, as *one continuous execution*. Splitting one execution across a return
  boundary means suspending it on one side and resuming it on the other, and a suspendable resumable async
  execution **is** a task. There is no trick: buffering the body until the handler finishes is structural
  but no longer streaming, and calling the handler twice is not an option.

**The mismatch lives at the router, not the server, and it is permanent.** Vapor has adopted the proposal
server underneath an entirely unchanged `Responder`/`Response` API — the push-based shape is confined to
one adaptation layer, and everything the router knows about is still return-based. Hummingbird has no
proposal work at all (checked: no reference to `swift-http-api-proposal` or `swift-http-server` in any
`Package.swift` on any of its 26 branches). So framework adoption changes the *server* boundary and leaves
the *router* boundary exactly as it is.

### The four options

They are different products, not rankings.

| | what it is | cost | what you give up |
|---|---|---|---|
| 1 | **Mount in their router** — an `HTTPServerRouteBuilder` registering on `Router`/`Application` | +3.6 µs buffered, task for streaming | nothing, once the shape hint exists |
| 2 | **Serve on their server** through the proposal interface | free, structural | their router, their middleware, their ecosystem |
| 3 | **WireMVC's router on top, theirs as a fallback route** | free for WireMVC routes; theirs pay what they already pay | their middleware over WireMVC routes; two routing tables |
| 4 | **A push-based hole in their `RoutesBuilder`** | free, structural, both directions | needs them to agree |

**Option 1 is measured.** A native Hummingbird adapter costs **+3.6 µs and 4 allocations** against a plain
Hummingbird route where `ServerTransport` costs **+16.5 µs and 41** — so 13 µs is the bridge's *shape*
rather than the cost of mounting. Catch-all comes back for free (`{name*}` → Hummingbird's `**`), which was
the capability `ServerTransport.register` could not express. Adding streaming to the prototype pushed it to
+9.6 µs and 18 allocations, because the adapter cannot tell a buffered route from a streaming one at
registration and so spawns the task for both — see the shape hint below.

**Option 3 is the interesting one and was not previously on the table.** Invert the stack: WireMVC's router
on top, the host's whole `Responder` chain mounted as a fallback route. That adapts in the *structural*
direction, so nothing needs a task — WireMVC routes pay nothing at all, and host routes pay exactly what
the host already pays itself. It is also the least code, because Vapor has written the reference
implementation. It reads as a migration path ("a WireMVC app that still hosts Vapor routes") rather than an
integration, which is a positioning question rather than a technical one.

**Option 4 is the best outcome and the biggest ask.** Vapor now holds a `responseSender` at the top of its
stack and discards it after writing one buffered response; the information a hole needs already exists.
What makes it a real request rather than plumbing is **middleware**: their middleware is
`(Request, Responder) -> Response`, it exists to transform a returned response, and a push-based route
never produces one. So the hole admits a class of route their middleware cannot wrap. The argument that
would carry it is that this is not WireMVC-specific — anything built on the proposal's carriers hits it.

### What WireMVC should change

**Add a route-shape hint to `HTTPServerRouteBuilder.register`.** Codegen knows statically whether a route
is buffered (a typed terminal) or streaming (`@EventStreamResponse`, multipart); `register` does not pass
it, so every adapter must assume the worst and pay for streaming machinery on every request. With the hint,
a buffered route registers a task-free closure and only streaming routes pay.

This is worth doing whatever happens with the options above, because **`ServerTransport` pays the same
unstructured task on every buffered request today**. And it is not a workaround for a transition — the
mismatch is permanent, so this is the correct permanent design.

**Nothing else in WireMVC needs to change.** In particular the streaming model should not: it is the
proposal's, and it is what makes `@RawRoute` a passthrough. Handing builders a body *description* instead
would trade that passthrough for adapter convenience, which is the wrong way round.

### One thing this settled in the proposal's favour

Duplex — reading a request while writing a response — is ordinary in the proposal's model, because the
handler holds both carriers at once. In a return-based model it has to be reconstructed inside the response
body callback, after the route function has returned. Vapor's adoption does not support it at all yet: it
eagerly collects the whole request body before building its `Request`. That is a stronger argument for the
typed duplex tier in [`PendingIssues/14`](../../PendingIssues/14-typed-tier-duplex-routes.md) than the
performance work produced.

## The `ServerTransport` ceiling, for reference

Worth stating once so it is not rediscovered per item. `ServerRequestMetadata` is a struct whose entire
contents are `pathParameters: [String: Substring]`. Unreachable through it: connection metadata (remote
address), protocol upgrade (websockets), the host's request context, and non-`{name}` path syntax.

`WireOpenAPI` does **not** use `ServerTransport` — an operation is a `RouteContributor` witness via direct
dispatch — so the protocol's only job in this stack is as a borrowed universal router-registration interface
for Hummingbird, Vapor and Lambda. Dropping to a native adapter would cost portability, not any OpenAPI
capability. That is the trade Phase 0.1's answer prices.

That trade is now measured rather than argued: a native Hummingbird adapter costs +3.6 µs and 4 allocations
where `ServerTransport` costs +16.5 µs and 41. See
[Mounting on Hummingbird and Vapor](#mounting-on-hummingbird-and-vapor-four-options-and-why-there-are-four),
which also answers what the ceiling costs on each of the four routes out of it.

## Open decision

**Where this lives in the roadmap.** Half-answered since this was written: `ROADMAP.md`'s M6 entry now
links this note and names the open question, so M6 can at least say where its remaining work is enumerated.
The other half — which milestone that work *is* — is still unstated, and now matters less than it did,
since the parity track has closed too and only Phase 5 and the upstream-blocked duplex tier are left. Two
options, unchanged:

- **M6e**, naming what is left as a sub-milestone under the link that already exists — accurate to M6's
  stated purpose ("unblock the last examples"), at the cost of a milestone that grows after being nearly
  closed. Cheaper now than when this was written, since what would be added is one track and two loose
  ends rather than three tracks.
- **An explicitly post-M6 track**, with M6 closed at M6d and this note named as the successor — a cleaner
  milestone boundary, at the cost of M6 having not quite met its own definition.

Either is fine. Leaving it unstated is not, which is what this note exists to fix. **What is left to place
is now small enough to describe in a sentence**, which it was not before, and Phase 3 closing shortened it
again: the router path's four allocation groups (Phase 5 — the registry's ownership question closed with
#148 and is no longer among them), the
lent-binding validation step, and one upstream pull request. Everything else is either shipped or waiting on
[swiftlang/swift#91473](https://github.com/swiftlang/swift/issues/91473).
