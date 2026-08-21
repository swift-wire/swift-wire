# 15 — A cancelled request is reported as a 500

**Repo(s):** wire-mvc
**State:** 🟡 Known, low-severity — the response is inert (the client that would read it has gone); the cost
is that logs and metrics cannot tell "client hung up" from "this route is broken"
**Blocks:** nothing.
**Surfaced by:** fixing the cancellation gap in the `WireMVCServerTransport` bridge, which this is the
residue of.

## What it is

When a request is cancelled before the handler has sent a response head, the bridge's register closure
returns `500 Internal Server Error` — the same outcome as a handler that ran to completion without ever
responding, which is a genuine bug in a route.

The path: `ResponseChannel.awaitStart()` is `for await start in startStream`, and `AsyncStream` iteration is
cancellation-aware, so on cancellation it ends and `awaitStart()` falls through to its
`.finishedWithoutResponse` default. That case maps to a 500. Measured as consistent, not racy — five runs,
`500 Internal Server Error` every time — because the stream observes cancellation before the now-cancelled
handler can report back through the channel.

## Why it is not the same bug as the one just fixed

The **handler** is cancelled correctly. `Task {}` inherits task-locals and priority but not cancellation, so
the bridge now wraps the `awaitStart()` await in `withTaskCancellationHandler` and cancels the handler task
explicitly; before that a client disconnecting mid-handler left it running to completion for a response
nobody would read. That is fixed and pinned by
`cancellingTheRequestCancelsTheHandlerBeforeAnyResponse`.

What remains is only how the *outcome* is reported.

## Use case at risk

Operational, not functional. An app whose clients disconnect routinely — long polls, aborted uploads,
impatient browsers — logs a stream of 500s that look like route failures. Any alert or SLO built on 5xx rate
counts client behaviour as server errors, and the genuine
`finishedWithoutResponse` case (a route with a code path that returns without responding) is hidden among
them rather than standing out.

## Fix sketch

Distinguish the two before mapping to a response. `awaitStart()` can report cancellation separately — either
by checking `Task.isCancelled` once the stream ends, or by having the cancellation handler record that it
fired — and the closure can then `throw CancellationError()` rather than synthesise a 500. Throwing is also
what structured-concurrency convention expects of a cancelled operation, and it lets the host framework
treat it as a cancellation rather than as a response.

Small, and independently testable: the existing test already cancels mid-flight and would only need to
assert the outcome alongside the handler's cancellation.

## Not to be confused with

The framework-pulled response body losing task-local context
(`AmbientContextTests.taskLocalContextIsLostWhenTheFrameworkPullsTheBody` in the Hummingbird and Vapor
examples). That is a separate, measured boundary of the same bridge era, pinned as behaviour rather than
filed here, because it is inherent to the response body being an `AsyncSequence` the framework drives and it
does not affect WireMVC's own streaming path.
