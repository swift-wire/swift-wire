# 18 — A typed terminal can drain the response-header registry twice

**Repo(s):** wire-mvc
**State:** 🟡 Unverified — the path exists and the compiler proves the two drains are not exclusive, but no
test exercises it and the window is narrow
**Blocks:** nothing. `drain(into:)` — the raw-route path — is already `consuming` and cannot hit this.
**Surfaced by:** trying to make `drain()` `consuming` while closing out the registry's ownership question,
which is what `#148` was argued for. The compiler refused, and the refusal is the report.

## What it is

`ResponseHeaderRegistry.drain()` is `borrowing`, so nothing stops it being called twice. A typed terminal
calls it in **both** branches of its `do`/`catch` — once building the successful outcome, and once in the
mapped-error path that `#148`'s sibling `#155` added. Making it `consuming` fails to compile against
generated code, pointing at both:

```
'wireMVCResponseHeaderDrain' consumed more than once
   54 | headerFields: WireMVCResponseHeaders.resolved(middleware: try await wireMVCResponseHeaderDrain.drain())
      |                                                                     `- note: consumed here
   60 |     middleware: (try? await wireMVCResponseHeaderDrain.drain()) ?? []
      |                             `- note: consumed again here
```

Argument evaluation reaches the success drain **last**, so a handler that throws never got there — that is
the ordinary path and it drains once. The window is a **deferred** contribution:

1. Middleware registers two contributions with `onSend`.
2. The terminal drains. The first closure runs. The second throws.
3. The drain throws, so the `catch` maps the error — and drains again from the start.
4. The first closure **runs a second time**, then the second throws again, `try?` swallows it, and `?? []`
   drops every contribution.

So the observable defect is **a deferred contribution's side effects happening twice**, not duplicated
header fields: the second drain's result is discarded wholesale, which is `#155`'s documented answer for a
contribution that fails to compute. `onSend`'s closure is deliberately non-`@Sendable` so a middleware can
capture per-request state in it, which is the capability that makes running it twice a real hazard rather
than a theoretical one.

Only the typed do/catch shape was traced. Whether any other emission can throw *after* its drain was not
checked.

## Why it is filed rather than fixed

Every way of closing it trades something, so it is a design decision about **when contributions are
computed** rather than a keyword:

- **Drain once before the `do`.** Runs `onSend` ahead of the handler, which is precisely what deferral
  exists to avoid — a deferred contribution reading state the handler set would see the wrong thing.
- **Drain once after the `do`/`catch`.** Loses the documented behaviour that a throw from `onSend` maps
  through `@ErrorResponse` like any other route error, because the mapping has already happened.
- **Make the local an `Optional` and take it.** The `catch` drains only if the `do` did not, which
  preserves both behaviours and makes a second drain impossible. Enforced at runtime by the `nil` rather
  than by the compiler, and it needs a `take()` on an `Optional` of a noncopyable, which the standard
  library does not provide. Not designed.

## Why it is worth keeping on the list

`#148` was argued on the grounds that ownership turns "drained exactly once" from a convention into a
compiler-checked property. It delivered exclusive **ownership** of the registry; it did not deliver
exactly-once **draining**, and this is the gap between the two. Half has since closed —
`drain(into:)` is `consuming`, so every raw route is checked — and this is the remainder.

The dual mistake is already on the record: `#155` fixed a path that *never* drained, found seven commits
after the redesign and from an examples spike rather than from review. This is its twin.
