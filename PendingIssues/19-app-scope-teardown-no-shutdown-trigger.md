# 19 — App-scope teardown under `@WireMVCBootstrap` has no shutdown trigger

**Repo(s):** wire-mvc (+ upstream: swift-service-lifecycle, swift-http-api-proposal)
**State:** 🔴 Known broken — provably unhandled: the walk exists, nothing calls it, and nothing on this path
would ever reach the call
**Blocks:** nothing. The explicit form (`Wire.bootstrap()` + facade) has orderly shutdown today, and no
shipped example depends on the generated `@main` having it.
**Surfaced by:** writing the README's *The entry point* section — stating what the generated `@main` does and
finding teardown was not among it — then reading `WireMVC.serve` against Hummingbird's
`ApplicationProtocol.run()` to see what the Tier-1 path has that this one doesn't.

## What it is

The ROADMAP's *Pre-1.0 polish* entry records this as a missing **call**: M4's teardown walk exists, every
graph conforms to `Teardownable`, "so there is nothing to build on the swift-wire side". That is true of
swift-wire. It understates wire-mvc, where there are two gaps and the second is the work.

**Gap 1 — the call.** `WireMVC.serve` (`wire-mvc/Sources/WireMVC/Bootstrap.swift:17`) never receives the
graph, so it cannot run `teardown()`. The generated `@main` has `graph` in scope at the call site
(`wire-mvc/Sources/WireMVCCodegen/BootstrapGeneration.swift:134`) and simply doesn't pass it. Small.

**Gap 2 — there is no shutdown trigger.** Even with the call in place it is unreachable, because nothing
makes `server.serve` return:

- `WireMVC.runServices` builds `ServiceGroup(services:logger:)`, whose `gracefulShutdownSignals` default is
  `[]`. There is no signal handling anywhere in wire-mvc's `Sources/`.
- SIGINT/SIGTERM therefore kills the process outright. CI's boot-probe step
  (`wire-mvc/.github/workflows/build.yml:87`) does exactly this — `kill "$pid"`, never checking that
  anything shut down.
- Outer cancellation of a `ServiceGroup` is a **hard cancel**, not a graceful shutdown. So the obvious
  transplant — a `gracefulShutdown()`-based teardown service prepended to the collated services — would not
  fire even once added.

## Why the Tier-1 shape does not transplant

The design this would copy (`Documentation/Notes/TeardownDesign.md:82`) prepends a `GraphTeardownService` to
the `[any Service]` array, relying on ServiceLifecycle's reverse-order shutdown to run it last. That works
under Hummingbird because **the server is itself a service**, so one `ServiceGroup` owns everything:

- `public actor Server<ChildChannel: ServerChildChannel>: Service`
  (`hummingbird/Sources/HummingbirdCore/Server/Server.swift:22`).
- `let services: [any Service] = self.services + [dateCache, serverService]`
  (`hummingbird/Sources/Hummingbird/Application.swift:152`) — the server is appended *last*, so reverse-order
  shutdown stops it *first* and the app's own services outlive it.
- `runService(gracefulShutdownSignals: [.sigterm, .sigint] = …)` (`Application.swift:161`) — the trigger is
  built in at the top level.
- `Server.run()` wraps its accept loop in `withGracefulShutdownHandler { … } onGracefulShutdown: { … }`
  (`Server.swift:112-130`), quiescing in-flight requests rather than cutting them.

Trigger, ordering and drain all fall out of **group membership**. WireMVC cannot have it: the proposal's
finalized handler is opaque and `~Copyable`, so it cannot be captured into an escaping `@Sendable` closure,
so it cannot be stored in a `Service`, so it cannot enter the group. That is why `WireMVC.serve` keeps
`server.serve(handler:)` in the task-group **body** (`Bootstrap.swift:31-35`, and the doc comment above it
says so) — and a body cannot be cancelled from inside, since `group.cancelAll()` reaches children only.
Serving therefore cannot be stopped in-process at all today.

This is **not** a deficiency of the proposal server. `NIOHTTPServer` already `import ServiceLifecycle`
(`swift-http-server/Sources/NIOHTTPServer/NIOHTTPServer.swift:29`) and its `serve` registers both handlers —
`withTaskCancellationHandler { withGracefulShutdownHandler { … } onGracefulShutdown: … } onCancel: …`
(`NIOHTTPServer.swift:168-176`). It would drain correctly *if it ran inside a group's child task*. The
missing piece is a way for a caller who cannot make the handler `Sendable` to participate.

## Use case at risk

An app whose graph carries a `@Teardown` `AWSClient` or `DatabasePool`. Under the explicit form it shuts
down in order; under the generated `@main` — the entry point the README now leads with, and the one a new
app writes — SIGTERM kills the process with no drain and no flush. Same annotations, same graph, different
behaviour depending on which entry point was chosen, with nothing at build time saying so. That silence is
the argument for fixing it rather than only documenting it.

## The upstream ask

Either of these removes the need for bespoke machinery in wire-mvc. Both are worth filing; the second is
preferred.

**1. swift-service-lifecycle — a public way to trigger graceful shutdown outside a `ServiceGroup`.**
The shutdown context is task-local, and the only type that can set it is `@_spi(TestKit)`:
`TaskLocals.gracefulShutdownManager` and `GracefulShutdownManager.shutdownGracefully()`
(`Sources/ServiceLifecycle/GracefulShutdown.swift:236`, `:244`, `:301`). A caller can *observe* graceful
shutdown (`withGracefulShutdownHandler`, `gracefulShutdown()`) but cannot *initiate* one, so the only
supported way to obtain the context is to wrap the work in a `Service` — which a `~Copyable` handler cannot
be. The ask: a supported scope-and-trigger API (something in the shape of
`withGracefulShutdownScope { trigger in … }`, or promotion of the existing task-local trigger out of SPI) so
a caller owning a non-`Sendable`, non-copyable serving frame can establish the same context a group would.

**2. swift-http-api-proposal / swift-http-server — a `Service`-conforming server entry point, or a `serve`
that returns a stop handle.** The server already handles cancellation and graceful shutdown internally; what
it lacks is any way to stop it from outside the task running `serve`. The protocol carries an open
`// TODO: We should revisit if this should be Sendable` on `HTTPServer` itself
(`swift-http-api-proposal/Sources/HTTPAPIs/Server/HTTPServer.swift:22-24`), which is adjacent territory —
this is the same question asked from the lifecycle side.

**Why #2 is preferred:** #1 supplies only the trigger, leaving WireMVC to re-implement server-first ordering
by hand and to hold the graceful-shutdown context itself. #2 restores the Hummingbird arrangement — the
server is a group member, ordering and drain come free, and the `teardownService` prepend from
`TeardownDesign.md` transplants unchanged. It is also the ask that benefits every proposal-server adopter
rather than only this one.

## Fix sketch (interim, in wire-mvc, if neither upstream lands first)

**The call.** `WireMVC.serve` gains a `graph: some Teardownable` parameter — `Wire` is already a wire-mvc
dependency, and every generated graph conforms universally (`WireGenCore/CodeEmission.swift:393`) — and runs
`await graph.teardown()` after the task group joins, i.e. once the server *and* the services have stopped.
Three details:

- **Shield it from cancellation.** If serve returned because the enclosing task was cancelled, an async
  `AWSClient.shutdown()` inside the walk fails. Run it in an unstructured `Task` and await that.
- **`do`/`catch`, not `defer`** (which cannot await), so a throwing `serve` or a failing service still tears
  down, exactly once.
- **Prefer the structural post-step to a `GraphTeardownService`.** Putting the graph in a `Service` newly
  requires the *graph* to be `Sendable`, which `CodeEmission.swift:384-388` deliberately leaves to
  auto-derivation; and without group membership the service buys no ordering anyway.

`WireMVCTesting.runSuite` (`Sources/WireMVCTesting/WireMVCTesting.swift:209`) has the same hole and is worth
the same pass — a suite rebuilds the app at every entry, so a `@Teardown` resource leaks per suite. It is
also the cheapest test vehicle: in-process, no signals.

**The trigger.** Trap SIGINT/SIGTERM in `serve` (the `UnixSignals` product, not currently a dependency),
cancel the group, let `NIOHTTPServer`'s `onCancel` close the channels, then tear down. Deterministic
app-scope teardown, but **no request drain** — weaker than what the README currently promises for the Tier-1
path, so it must be documented as the narrower guarantee rather than by restating the Tier-1 wording.
Driving the SPI manager directly buys the drain, at the price of `@_spi(TestKit)` in shipping code; this
issue exists so that trade is made deliberately rather than silently.

**Blast radius.** Codegen: the serve line (`BootstrapGeneration.swift:134`), the suite line (`:221`), doc
comments (`:8`, `:58`, `:118`). Goldens:
`Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift:302`, `:399`, `:658`. Fixture + CI: a
`@Teardown` binding in `Fixtures/Sources/WireMVCBootstrapExample` printing a marker, and a boot-probe step
that `kill -TERM`s, waits for exit and greps for it (`build.yml:87`). Docs: swift-wire's
`README.md:487` (*What the generated entry point does not do*), `:803`, `:809`, and the ROADMAP entry at
`:156`.

## Not to be confused with

**Init-failure partial teardown** (ROADMAP M7c). That is tearing down bindings already constructed when an
init throws *partway through bootstrap* — the graph struct does not exist yet, so it cannot go through
`Teardownable` at all. Different mechanism, different deferral, and its shape is fixed by the construction
scheduler rather than by the entry point.

**Request-scope teardown**, which is unaffected and does run: it is emitted per route and fires at end of
request, probed end to end by the `WireMVCExample` fixture. This issue is only the app scope.
