# 14 — Typed-tier duplex routes, paused on an upstream bug

**Repo(s):** wire-mvc (+swift-wire, none)
**State:** 🟡 Deferred by decision — designed, ownership-verified, blocked on
[swiftlang/swift#91473](https://github.com/swiftlang/swift/issues/91473)
**Blocks:** nothing. `@RawRoute` serves the case today, measured end to end on both transports.
**Surfaced by:** the wire-mvc-examples ↔ hummingbird-examples coverage comparison (`proxy-server` has no
counterpart), then spikes 31–33 in `swift-wire-spikes`.

## What it is

A **duplex** route reads its request body incrementally *and* writes its response body incrementally.
`WireMVCDiagnostic.readerBodyOnStreamingResponse` refuses it on the typed tiers and points at `@RawRoute`
for "full control of both directions".

The design that would lift that is settled and compiles: the response becomes a **parameter** rather than a
return value, so the handler holds both halves in one frame — the property that makes `@RawRoute` work —
and nothing has to be stored:

```swift
@Post("/transform")
@StreamedResponse(.ok, contentType: "multipart/mixed")
@ErrorResponse(MultipartBindingError.self, .badRequest)
func transform<Stream: MultipartPartStream & ~Copyable, Writer: CallerAsyncWriter & ~Copyable & ~Escapable>(
    @MultipartStream stream: consuming Stream,
    into response: consuming PartResponse<Writer>
) async throws {
    try await stream.withParts { parts in
        while let part = try await parts.nextPart() {
            try await response.beginPart(name: part.name, filename: part.filename)
            while let chunk = try await parts.nextChunk() { try await response.write(chunk) }
            try await response.endPart()
        }
    }
    try await response.finish()
}
```

## Why it is paused

**The response parameter cannot carry an attribute, and every other binding in WireMVC does.**

The response owns the writer, so it must be `~Escapable` — moving a non-escapable value does not extend its
lifetime, so the container inherits the bound. And #91473 makes property-wrapper + `~Escapable` + *generic*
parameter unusable. Verified on `6.4.x-snapshot-2026-08-01`:

```
error: copy of noncopyable typed value. This is a compiler bug. Please file a bug with a small example
```

The workaround is to bind the response by **conformance on the parameter type** instead, the way
`@RawRoute` infers its reader and sender by constraint. That compiles — but it makes the response the one
binding in the framework that is recognised structurally rather than declared, in a parameter list sitting
next to `@MultipartStream`, which *is* declared. Shipping the asymmetry would mean shipping a second
binding idiom for one route shape, then removing it when the bug is fixed.

This is the same bug the ROADMAP's *Known blockers (1.0)* entry already records for
`@RequestBinding(.bodyStream)`, reached from the response side. That entry accepts a *weakening* of a
guarantee; here it would be a divergence in the **surface**, which is worse — a weakening is invisible until
you look for it, an idiom is what every reader of the route sees.

So: pause, and implement it consistently once #91473 lands. Nothing is lost meanwhile — see below.

## What is already established (compiled, not reasoned)

All in `swift-wire-spikes`, on 6.4-dev unless noted:

- **`@RawRoute` duplex works today**, by both binding forms, on the proposal-native server *and* through
  `WireMVCServerTransport` on Hummingbird — `spike-32`, driven by a raw-socket ping-pong client that
  cannot pass if either direction buffers. So the escape hatch the diagnostic names is real, not
  theoretical.
- **The transport interleaves** on Hummingbird and Vapor — `spike-31`.
- **The response-as-parameter terminal compiles**, carrying the real `MultipartParts` binding across the
  mapped `do`/`catch` in a `~Copyable` outcome, with the sender consumed exactly once outside it —
  `spike-33`, `ParameterResponseProbe.swift` + `RealBindingProbe.swift`. Negative checks included: a second
  `send` gives `'responseSender' consumed more than once`, reusing the stream gives `'stream' consumed more
  than once`.
- **A producer that *holds* the reader does not compile** (`stored property 'reader' of
  'Copyable'-conforming generic struct … has non-Copyable type`), which is why the return-a-value shape
  cannot express duplex and the parameter shape can.

## Decisions taken, so they are not re-litigated

- **Status is static**, declared by annotation and sent before the handler runs. Measured dichotomy: the
  terminal holds the sender (static status, full `@ErrorResponse` up to the first byte) or the handler does
  (dynamic status, no mapping — that is `@RawRoute`). There is no middle; `do { handler(sender) } catch {
  … sender … }` is `'responseSender' consumed more than once`. Costs little: the case that wants a late
  status ("read a field, refuse with 401 while bytes are in flight") is `.bodyStream` + a **buffered**
  response — `/upload/stream` today, untouched by any of this. Only a proxy wants a status it cannot know
  up front, and a proxy forwards opaque bytes rather than using typed bindings.
- **The typed client emits the path shim only**, as for `@RawRoute`. A buffering client would make the one
  property a duplex route has untestable while looking like coverage. A real duplex client belongs with the
  `WireMVCTesting` redesign in wire-mvc's `Documentation/TestingArchitecture.md`, not ahead of it.
- **Lent bindings need a throwing validation step.** Forced by the static head: `MultipartParts.init` is
  non-throwing on purpose, deferring its content-type check to `withParts` because "the failure [stays]
  inside the handler — still before any response head is written". Duplex is the first shape where the
  handler runs *after* the head, so without a validation step a non-multipart `Content-Type` would truncate
  instead of mapping to 415. This is a change to a public binding protocol, so it is cheaper pre-1.0.

## Not blocked by this

Two neighbouring items are independent and can proceed:

- **The sequential case** — a `.readerBody` binding on a streaming-response route (reduce the body without
  buffering, *then* stream). `readerBodyOnStreamingResponse` refuses it under the same message, but it needs
  no response parameter and no upstream fix: one new terminal overload that lends the reader into `building`
  as a *consuming closure parameter*. Compiles (`spike-33`, `LendingTerminal.swift`). The recorded obstacle
  ("a closure only borrows it") is about a *captured* reader and does not apply.
- **The `StreamingResponseTier.md` migration** of `/todos/stream` and `/export` off `@RawRoute`. Both are
  `@Get` routes that read no body, so neither can reach this diagnostic. An earlier analysis coupled the
  two; that was wrong.

## When to un-pause

When #91473 is fixed in a usable toolchain — the same event the ROADMAP's known-blocker entry is waiting on
for `@RequestBinding(.bodyStream)`'s `~Escapable` parameter, so the two land together and the surface stays
one idiom. Sooner only if an adopter has a real duplex route that `@RawRoute` cannot serve, which would be a
different argument (capability, not consistency) and should be recorded as such.

## A related defect, now fixed

`spike-32` measured that `@RawRoute(.reader, .responseSender)` **silently dropped contributed response
headers** while a bare `@RawRoute` kept them: `RawRouteCodegen.rawArgument(forPrimitive:wrapsSender:)`
skipped the `ResponseHeaderApplyingSender` wrap whenever roles were explicit, on a rationale written for
*transformed* sender slots. A duplex handler names `.reader` to get a reader — its sender is ordinary — and
forfeited `@ResponseHeader` and global-middleware contributions as a side effect.

Fixed rather than deferred, because it was a live defect in the path this issue defers *to*. The wrap is now
decided **per slot** on both paths, by the test the inferred path already made: a transformed slot names a
compound type (`MultiPartSender<S>`), an untransformed one is the function's own generic parameter
constrained by `HTTPResponseSender`. Non-breaking — every explicit-role route in the tree was a transformed
one, which is why nothing caught it. Pinned by
`rawRouteExplicitRolesStillWrapAnUntransformedSender` and measured end to end by `spike-32`, which now
reports the header reaching both binding forms on both transports.
