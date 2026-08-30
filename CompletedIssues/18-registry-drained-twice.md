# 18 — A typed terminal can drain the response-header registry twice

**Repo(s):** wire-mvc
**State:** ✅ **Fixed in wire-mvc** — was 🟡 Unverified
**Surfaced by:** trying to make `drain()` `consuming` while closing out the registry's ownership question,
which is what `#148` was argued for. The compiler refused, and the refusal is the report.

## Resolution

**The terminals own the registry and drain it once.** `wireMVCBufferedTerminal` and the three
`wireMVCStreamingTerminal` overloads take `responseHeaders: consuming ResponseHeaderRegistry`, run
`building`, drain, and resolve the result onto whichever branch ran (`Sources/WireMVC/ResponseTerminals.swift`).
`drain()` is `consuming`. The three constraints hold at once: the drain is after the handler, so deferral
still works; before anything reaches the wire, so a throw from a contribution still maps through
`@ErrorResponse`; and on every path, so a mapped `401` still carries the `WWW-Authenticate` `#155` restored.

**The option list below was incomplete, and the streaming tier is why.** The write-up traced only the
buffered `do`/`catch`, where all three listed options are about *where* generated code puts the drain. On
the streaming tier the two drains sit in the `building` and `errorMapping` closures, and a noncopyable value
captured by a closure cannot be consumed **at all** — not twice, once:

```
error: noncopyable 'wireMVCResponseHeaderDrain' cannot be consumed when captured by an escaping
       closure or borrowed by a non-Escapable type
```

So no rearrangement of the drain sites reaches a `consuming drain()` there. Any fix had to take the registry
out of generated code entirely, which is what the terminals do — the move the **response sender** had
already made in the same function, for the same reason (`'responseSender' consumed more than once`). The
registry was the second linear value in that terminal and had not been given the same treatment.

Two corrections to the record below. Option 3 ("the standard library does not provide" a `take()` on an
`Optional` of a noncopyable) is a five-line extension and compiles — its real cost is that enforcement is
the `nil` rather than the compiler, which is the property `#148` was argued on. And "whether any other
emission can throw *after* its drain was not checked" resolved as: the streaming emission has the same two
drains, in the shape that cannot be fixed by rearrangement.

**Verified.** The regression test is not vacuous: run against a reverted `borrowing drain()` and the old
two-drain sequence, the deferred contribution's side effect runs twice. Generated code got *smaller* — the
buffered tier stopped writing its own `do`/`catch`, and the two terminal emitters merged, since they had
differed only in the shape that `do`/`catch` forced.

---

The original report follows.

**Blocks:** nothing. `drain(into:)` — the raw-route path — is already `consuming` and cannot hit this.

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
