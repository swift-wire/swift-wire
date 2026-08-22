# Schema validation from the document — runtime assertions (M6d.7 design note)

> **Status:** design, not yet implemented; **all five open questions closed empirically** against the
> pinned generator fork (see *Closed by building the fixture*), and one pre-existing bug found in the
> process. Extends
> [WireOpenAPIAdvanced.md](WireOpenAPIAdvanced.md) (M6d) and rests on the `@ErrorResponse` model in
> [RouteErrorHandling.md](RouteErrorHandling.md). Lands in `wire-open-api`.
>
> **Not to be confused with M6d.5, "spec-read validation."** That milestone validated *the author's
> code against the document* at build time — an `@Path` on something the spec puts in query. This one
> validates *the request against the document* at run time. Same word, opposite direction. If the two
> keep colliding in conversation, M6d.5 should be renamed to "spec-read diagnostics."

## The model in one paragraph

swift-openapi-generator translates a schema's **structure** — types, optionality, `enum`, `required` —
and drops every **assertion**: `minLength`, `pattern`, `minimum`, `multipleOf`, `minItems`,
`uniqueItems`. A document declaring `minLength: 3` compiles to `String`, and nothing in the served
stack enforces it. This note closes that by emitting, per spec, a validator keyed on the document's
*named* schemas, and calling it as the first statement inside the forwarder's existing `do` — the one
place a typed `Input` exists. A failure throws `WireOpenAPIRequestValidationError`, which is an
ordinary handler-thrown error and therefore already matchable by `@ErrorResponse`, already checked
against the document by `diagnoseErrorMappings`, and already serialised as one of the operation's own
response cases. **The capability is an emitted validator plus one emitted call. The error routing is
entirely machinery that exists.**

Request and response validation are **two capabilities that share an emitter, not one capability
pointed in two directions** — see *Two failures, two blames, two types*. A malformed request is the
caller's fault and answers 4xx; a malformed response is the service's fault and answers 5xx. Conflating
them is not a stylistic error but a mechanical one: a single error type makes a controller-scope
`@ErrorResponse` answer a service bug with a client-error status.

## Why the forwarder is the only site — the typed value forces it

The instinct is to validate the request before dispatch, at the route terminal. That is structurally
impossible, and the reason is the same shape as the argument that put `@ErrorResponse` at the terminal
in WireMVC: the site is decided by what is *in hand* there.

At the terminal there are bytes and path parameters. The document's assertions are about decoded
values — `minItems` on an array, `pattern` on a string that the deserializer has yet to produce. The
only place a typed `Operations.X.Input` exists is inside the forwarder, after the generator's
deserializer ran and before the controller's method is called. That is also, not coincidentally, where
`ConformerEmission.errorCatches` already emits the `@ErrorResponse` clauses. So the emission is:

```swift
func getTask(_ input: Operations.GetTask.Input) async throws -> Operations.GetTask.Output {
    do {
        try _WireOpenAPIValidation_TaskAPI.getTask(input)          // the whole addition
        let result = try await wireOpenAPISubject.getTask(id: input.path.id)
        return .ok(.init(body: .json(result)))
    } catch is TaskNotFound {
        return .notFound(.init())
    } catch let wireOpenAPIError as WireOpenAPIRequestValidationError {   // generated today, unchanged
        return .unprocessableContent(.init(body: .json(
            try wireOpenAPIErrorBody(wireOpenAPIError, { e in .init(errors: e.failures.map(\.path)) })
        )))
    }
}
```

Three consequences follow from the site, and each is a decision rather than an accident:

- **Forwarder-scoped, never terminal-scoped.** `ErrorMapping.isTerminalScoped` stays exactly as it is.
  The distinction it already draws is the right one: a validation failure *is* an outcome of this
  operation, so it earns a response the document describes; a `DecodingError` is not, because the
  request never became this operation's `Input`.
- **Middleware runs outside it.** An auth or rate-limit component sees an unvalidated request, as it
  sees an undecoded one. Unchanged from every other ordering here.
- **Request scope is entered before validation, and paid for.** Scope entry lives in the route
  terminal (M5.4.3), so a rejected request still constructs and tears down the operation's scope.
  There is no way around it — the `Input` the validator reads does not exist until after scope entry.
  Stated here rather than discovered later.

## The unmapped default is already correct — and its status comes from wire-mvc

Reading the runtime rather than assuming it: `UniversalServer.handle` wraps a handler throw in
`ServerError`, and `ServerError.init` lifts `httpStatus`/`httpHeaderFields`/`httpBody` from
`underlyingError as? (any HTTPResponseConvertible)`, falling back to 500. `WireOpenAPIRoutes.invoke`
already consults `error as? any HTTPResponseConvertible` in its terminal `catch`.

So conforming the validation errors to `HTTPResponseConvertible` means an app that writes no
`@ErrorResponse` at all gets a correct status with a problem body — not a 500, and not the dropped
connection an unmapped throw would otherwise cause. `@ErrorResponse` then **upgrades** that to a
response the document describes, serialised by the generator like any success.

**The status is not invented here.** `WireMVCBindingError.status` already answers a *request* that
failed to bind, and it splits by location: 422 `unprocessableContent` for a malformed body, 400
`badRequest` for a missing or mismatched path/query/header value, 415 for a contradictory
`Content-Type`. A schema violation is the same kind of failure one step later — the body parsed and is
unacceptable, which is what 422 means — so it takes the same split:

| where the violation is | status | matches |
|---|---|---|
| request body | **422** | `WireMVCBindingError.malformedBody` |
| path / query / header parameter | **400** | `WireMVCBindingError.pathParameterTypeMismatch` et al. |
| a response body | **500** | see below — the service broke its own document |

A flat 400 for everything was the first draft and is worse than it looks: it would make a `@Get` route
and an OpenAPI operation in the same app answer the same category of failure with different statuses.
That is the exact inconsistency M6d.6 closed for dates and JSON options, and it is closed here the same
way — by deferring to the shared tier rather than by picking a number.

Under collect-all a single error can carry failures in both the body and a parameter, so the status is
derived from the failure set: **any parameter failure wins, and the answer is 400.** A request whose
path is wrong is malformed before its body's semantics are worth discussing.

One ordering footnote: `rejectionResponse` (the terminal-scoped mappings) is consulted *before* the
`HTTPResponseConvertible` tier, so a `Swift.Error` catch-all intercepts an otherwise-unmapped
validation error. That is what a catch-all means, and it matches wire-mvc's rule that the catch-all
sits after the built-in mapping but before the rethrow.

## What is emitted — per named schema, not inlined per operation

One `enum` per spec, holding one `static func` per **constrained component schema** and one entry
point per operation:

```swift
enum _WireOpenAPIValidation_TaskAPI {
    static let _p0 = try! Regex("^[a-z][a-z0-9-]*$")     // compiled once, at file scope;
                                                         // WireOpenAPIGen parsed it at build time

    static func schema_Task(
        _ v: Components.Schemas.Task, at path: WireOpenAPIPath, into failures: inout [Failure]
    ) { … }

    static func getTask(_ input: Operations.GetTask.Input) throws { … }
}
```

Keying on the document's **names** rather than inlining at each use buys three things:

- **recursion terminates.** A self-referential `Node` becomes a call, not an infinite inline
  expansion.
- **code size is linear in the document**, not in operations × schema depth.
- a `$ref` reached from twenty operations emits once.

This requires reading schemas **un-dereferenced** — `document.underlyingDocument.components.schemas`
and the operations' unresolved `Either` — so that a `$ref` is still visible *as a name*. The
`locallyDereferenced()` document that `DocumentLoading` already produces stays exactly as it is for
everything else; this is an additional read of the same loaded value, not a change to loading.

Optionality is free. A property the document does not mark `required` was emitted by the generator as
an `Optional`, so the validator is an `if let` and absence is never a constraint failure —
`required` already handled that, structurally, before this note existed.

## Three decisions

### 1. Always on, with an opt-out

Validation is emitted whenever the document declares a constraint the operation can reach. It is not
requested by an annotation.

The document is already the sole authority in this adapter for a parameter's location, for which
status a handler constructs, and for whether a response carries a body — a handler that disagrees is
an error, not a preference. Making assertions the one thing the document declares that the author must
separately ask for would be inconsistent with all three. And "the spec says `minLength: 3` and the
server never checks" is precisely the silent drop that M6d.5 refused when it replaced the dictionary
walk.

The pressure valve is a **marker at controller and route scope**, `@SkipValidation`, following
`@Middleware`/`@ErrorResponse`'s two-scope shape. It has to be its own marker rather than a parameter
on `@Operation`, because it must be available to `@RawOperation` too — a raw operation still receives
`Input`, so validation applies to it uniformly, and its author still needs the escape.

**Zero cost when the document is unconstrained.** A document declaring no assertions emits no
validator and no call, so every existing consumer is byte-identical. This is load-bearing under
always-on, not merely a nicety.

### 2. An unrepresentable constraint is a build error

Following `diagnoseMappingForm`'s precedent — *"this adapter cannot construct that content type; use
`@RawOperation`"* — a constraint the emitter cannot express fails the build, naming the keyword, the
schema and the operation that reaches it.

The confirmed case is `minProperties`/`maxProperties`: the generator emits nothing for them (verified
against a probe document, below), and a generated struct has no runtime property count to read. There
is nothing to check and nothing to check it with, so the build refuses rather than promising something
false.

**`additionalProperties: false` is *not* one of these — an earlier draft of this note had it exactly
backwards.** The generator enforces it, in a custom `init(from:)`:

```swift
try decoder.ensureNoAdditionalProperties(knownKeys: ["a"])
```

So it is already checked, and the validator must emit nothing for it. But *where* it is checked
matters, and creates the one genuine seam in this design — see *The decode-time seam*.

The message ends in the two real options: remove the keyword from the document, or take the operation
`@RawOperation`. With decision 1, `@SkipValidation` is a third, and suppresses these diagnostics for
what it covers.

### 3. All failures collected, not the first

Each schema validator takes `into failures: inout [Failure]`; only the operation entry point throws,
once, at the end. The emission cost over fail-fast is an accumulator parameter; the DX difference is
that a client fixes every bad field in one round-trip instead of one per round-trip.

```swift
public struct WireOpenAPIRequestValidationError: Error, HTTPResponseConvertible {
    public struct Failure: Sendable {
        public let path: String        // "body.items[3].name"
        public let keyword: String     // "minLength"
        public let expected: String
        public let actual: String?
        public let location: Location  // .body / .path / .query / .header
    }
    public let operationID: String
    public let failures: [Failure]
    public let truncated: Bool
    /// 400 if any failure is in a parameter, 422 otherwise.
    public var httpStatus: HTTPResponse.Status { … }
}
```

**Two error types across the adapter, but only one per operation.** `@ErrorResponse` matches by type,
so a per-operation type would mean writing the same mapping once per operation; one type per *blame*
makes the ergonomic form — a single controller-scope
`@ErrorResponse(WireOpenAPIRequestValidationError.self, .unprocessableContent, { … })` — the natural
thing to write. Why exactly two, and not one, is the next section.

**Collect-all needs a cap.** A ten-thousand-element array failing a `pattern` produces ten thousand
failures and a response body larger than the request. The walk stops at a fixed count and sets
`truncated`. This is a cost that exists *only* because of decision 3, and is the kind of thing that
otherwise shows up as an outage.

## Two failures, two blames, two types

A request that violates the document and a response that violates it are opposite events. The caller
malformed the request; the service malformed the response. They differ in blame, in status class, in
who can fix them, and in whether the author should be allowed to dress them up.

**One error type would be a bug, not an inelegance.** The `@ErrorResponse` clauses are emitted in the
same forwarder `do` that response validation would throw from, and they match by type. So with a
single `WireOpenAPIValidationError`, this —

```swift
@ErrorResponse(WireOpenAPIValidationError.self, .badRequest, { e in Problem(errors: e.failures) })
```

— written once at controller scope for its obvious purpose, would *also* catch every response
validation failure and answer a service bug with a 400, telling the caller they malformed a request
that was fine and hiding the broken contract behind a client-error status. Nothing in the type system
or the existing diagnostics would object. The split is therefore forced by the emission site:

| | request | response |
|---|---|---|
| type | `WireOpenAPIRequestValidationError` | `WireOpenAPIResponseValidationError` |
| default status | 422 / 400, per location | **500** |
| blame | the caller | the service |
| `@ErrorResponse` | overridable, to any documented 4xx | overridable for the *body*, not the class |

**A new diagnostic, in both directions.** Mapping a response validation error to a 4xx is a build
error: the caller is blameless, so there is no honest 4xx to answer with. Mapping a request validation
error to a 5xx is the same error mirrored — the service is working exactly as documented by refusing a
bad request, and a 500 would invite the caller to retry something that can never succeed. So
`@ErrorResponse` may change the *body and the specific code* within a class, and never the class. This
is the one rule in this note that is purely about honesty rather than about what can be constructed,
and it is cheap to check because both types are the adapter's own.

**The 500 exemption already exists.** `diagnoseErrorMappings` exempts `.internalServerError` from the
must-be-documented rule — *"a document does not promise 500 the way it promises 404 — it is what
happens when the promise cannot be kept"*, which is precisely what a response validation failure is.
So `@ErrorResponse(WireOpenAPIResponseValidationError.self, .internalServerError, { … })` passes
without the document declaring a 500, and no new exemption is needed.

## Two diagnostics that fall out of always-on

Both are consequences of decision 1, and neither exists today.

**`diagnoseControllerErrorMappings` will report a false error.** It requires that every operation a
controller-scope mapping covers declares the mapped status. Under always-on, the natural
controller-scope `@ErrorResponse(WireOpenAPIRequestValidationError.self, .unprocessableContent, …)`
would therefore be rejected against operations that declare no 422 — *including operations with no
constraints at all*, which can never throw it. The check has to learn to skip operations that cannot
throw the mapped error. That is only decidable for the adapter's own two validation types — a narrow,
justified special case, and it must be written as one rather than as a general "maybe it can't throw"
weakening.

**Unrepresentable-constraint diagnostics are keyed on request-reachability, not on the schema.** A
`Components.Schemas.Task` is routinely both a request body and a response body. Response validation is
off by default (below), so failing the build over a constraint reachable only from a response would
fail it for a feature nobody switched on. The diagnostic walks from each operation's *request* surface
and reports what it finds there; switching response validation on widens the walk, and may
legitimately turn a passing build into a failing one.

## Coverage, and where it is easy to be quietly wrong

| keyword | emission | the trap |
|---|---|---|
| `minLength` / `maxLength` | count | JSON Schema counts **code points**; `String.count` counts grapheme clusters. `unicodeScalars.count` is the faithful one. Wrong silently, and only for non-ASCII input. |
| `pattern` | precompiled `Regex`, unanchored find | ✅ dialect gap narrow; pattern compiled at *build* time so a bad one is a diagnostic, not a `try!` |
| `minimum` / `maximum` / `exclusive*` | comparison | ✅ 3.0's bool form and 3.1's numeric form both normalise to `Bound { value, exclusive }` — no version handling needed |
| `multipleOf` | remainder | exact for `type: integer` (OpenAPIKit gives `Int`); epsilon question is `type: number` only |
| `minItems` / `maxItems` | `.count` | — |
| `uniqueItems` | set insertion | ✅ generated types are `Hashable`; the property stays an `Array`, so the check is needed |
| `enum` | nothing | the generator already emits a Swift enum |
| `required` | nothing | the generator already emits non-optional |
| `format` | opt-in only | JSON Schema makes `format` an **annotation**, not an assertion, by default. Enforcing it silently would reject requests a conforming document permits |
| `minProperties` / `maxProperties` | diagnose | ✅ generator emits nothing; no runtime property count to read |
| `additionalProperties: false` | **nothing** | ✅ already enforced by the generator's `init(from:)` — but at decode time; see *The decode-time seam* |

## Response validation — emitted, off by default

The same `schema_Task` function checks what a handler *returns*. Switching it on turns a
contract-violating 200 into a 500, which is honest — the service broke its own document — but is a
runtime behaviour change nobody asked for. Gated off by default and on in debug/test builds, it lets a
fixture assert the contract holds without costing production anything. Cheap, because the functions
are already emitted, and because it reuses the request walk's accumulator and cap.

**Mapped error responses are responses too.** `@ErrorResponse(TaskNotFound.self, .notFound, { e in
Problem(…) })` builds a documented 404 body from an author's closure, which can violate that response's
schema exactly as a success body can — and it is constructed *in a `catch` clause*, outside where an
end-of-`do` check on the success value would run. So the validation call has to be emitted in each
catch clause as well as on the success path. This is the detail most likely to be missed, because the
success path is the one anybody tests.

**And the regress terminates by rule, not by luck.** A response validation failure inside a `catch`
clause turns that mapped 404 into a 500 — correct, the service's *error* body broke the contract — but
it must not itself be mappable, or an `@ErrorResponse` on `WireOpenAPIResponseValidationError` whose
own body is invalid would loop. The rule: **a response validation failure is never matched by the
clauses of the `do` it was thrown from.** It propagates to the terminal, where the
`HTTPResponseConvertible` tier answers 500 with no body of the document's. One hop, always.

## Cost

Straight-line comparisons: no reflection, no dictionary walk, no allocation on the passing path beyond
the empty failure array. Regexes are compiled once per process at file scope. The walk is proportional
to what the request already paid to decode. An unconstrained document emits and calls nothing.

## Sequencing

0. ✅ **Done — the recursion fix.** `DocumentLoading` no longer requires a dereferenced document; it
   resolves each reference where it is read. Shipped independently, because a recursive `$ref` failed
   the build for a document the generator handles. It also removes the obstacle slice 3 would have hit:
   reading component schemas without dereferencing them is now the established pattern rather than a
   new exception. One caveat for slice 3 — the one-hop `lookup` used here is fine for parameters,
   responses and request bodies, whose components are concrete; walking *schemas* will need the
   name-keyed, cycle-aware treatment this note describes, and must not reintroduce a full resolve.
1. **Runtime only.** Both error types, their `HTTPResponseConvertible` conformances (including the
   400/422-by-location rule), the `Failure` accumulator and the cap. No codegen. Provable with a
   hand-written `throw` in a fixture controller plus an `@ErrorResponse` mapping — which exercises the
   **entire** error path, both the mapped and the unmapped tier, before a single schema has been read.
   This is the milestone that de-risks the claim this note rests on.
2. **Parameters only**, scalar constraints. Self-contained, no `$ref` walking, no recursion. The
   fixture grows a `minLength` path parameter.
3. **Component schemas.** Per-name validators, `$ref` as a call, arrays, nesting, recursion.
4. **The decision-2 diagnostics**, with the request-reachability walk.
5. **Response validation**, gated off — success path *and* every mapped error body, with the
   one-hop regress rule.

## Closed by building the fixture

All five open questions were settled by running the pinned fork against a probe document exercising
recursion, `allOf`, `uniqueItems`, every numeric keyword and `additionalProperties: false`. Two of the
answers contradicted this note as first written.

- **Generated structs are `Hashable`.** Every schema struct is `Codable, Hashable, Sendable`, and each
  `Operations.X.Input` is `Sendable, Hashable`. So `uniqueItems` is a set insertion, O(n), not an
  O(n²) `Equatable` scan and not a diagnostic. Worth noting that `uniqueItems: true` does **not** make
  the generated property a `Set` — it stays `[Swift.String]` — so the check is genuinely needed.
- **`allOf` members are `value1`, `value2`, positionally.** A `$ref`'d member is the named type
  (`Components.Schemas.Base`); an inline member gets a nested `Value2Payload` struct. The validator
  needs both: a call to the named schema's validator, and an emitted anonymous validator for the
  payload. **And the Swift member path diverges from the JSON path here** — `value1`/`value2` are Swift
  artifacts with no wire counterpart, since the generated `init(from:)` decodes both from the *same*
  decoder. A failure under `meta.value1.kind` must be reported to the caller as `meta.kind`. The
  emitter therefore threads a JSON path, not a Swift key path, and `allOf` is the case that proves the
  two are not the same thing.
- **`locallyDereferenced()` does not survive recursion — that was a live bug, now fixed (slice 0).** It throws
  `ReferenceCycleError`; OpenAPIKit detects the cycle rather than hanging. Confirmed by running
  `WireOpenAPIGen` against a recursive document: it exits 1 with *"has a reference that could not be
  resolved"* — a document swift-openapi-generator itself generates from without complaint, because it
  has a whole `RecursionDetector` and boxes recursive types. **The two tools disagree about the same
  document.** Removing only the recursive property makes the same run exit 0. OpenAPIKit's own error
  names the fix: *"avoid requesting a `locallyDereferenced()` copy… `lookupOnce()` is your best option
  in this case."* ✅ **Shipped ahead of this note**, since it is a bug on its own terms: `DocumentLoading`
  now resolves references one hop at a time at the four places the codegen reads — path item, parameters,
  responses, request body — and never asks for a dereferenced document. Schema `$ref`s are never
  followed, because nothing here reads a schema, so a schema cycle is not merely tolerated but never
  visited. The fixture's `Order` carries a recursive `relatedOrders` so a regression fails the build.
- **The regex dialect gap is narrow, and the `try!` should not exist.** Swift `Regex` and
  `NSRegularExpression` both accept all nine representative ECMA-262 patterns probed — lookahead,
  negative lookahead, named groups, `\p{L}`, `\d`, `\w`, `\S` — and Swift `Regex` anchors `^`/`$`
  to the string rather than the line, matching ECMA-262 without the `m` flag. So: use Swift `Regex`,
  accept the residual gap, and **compile every pattern in `WireOpenAPIGen` at emission time**. A
  pattern Swift cannot parse then becomes a build diagnostic naming the schema, instead of a `try!`
  that traps on first request. That is better than either option this note originally offered.
- **`exclusiveMinimum` is fully normalised before the emitter sees it.** OpenAPIKit decodes the 3.1
  numeric form and OpenAPIKit30 the 3.0 boolean form into the same `Bound { value, exclusive }`, and
  `OpenAPIKitCompat` maps it across. One shape; the emitter picks `<` or `<=` and needs no version
  handling. Bonus: `IntegerContext` carries `Int` bounds and an `Int` `multipleOf`, `NumericContext`
  carries `Double` — so integer `multipleOf` is exact arithmetic, and the epsilon question applies
  only to `type: number`.

## The decode-time seam

`additionalProperties: false` is enforced by the generator's `init(from:)`, which runs in the
**deserializer** — before the forwarder, before the `Input` exists. So it throws a `DecodingError`,
which is terminal-scoped by `ErrorMapping.isTerminalScoped`, answered by the runtime's own
`HTTPResponseConvertible` mapping, and matchable only by a terminal-scoped
`@ErrorResponse(DecodingError.self, …)` that cannot construct one of the operation's documented
responses.

A `minLength` violation on the very same schema is forwarder-scoped, answers 422, and *can* be a
documented response. **Two assertions in one schema, answered by two tiers, with two statuses and two
mapping scopes.** Nothing in this design causes that — it is where the generator already draws the
line — but it is the sharpest edge a user will meet, and it must be documented rather than discovered.
Whether the two should be reconciled (by catching the decode rejection and re-throwing it as a request
validation failure, which would cost the deserializer's error detail) is the one question this note
leaves genuinely open.

## What this rests on

- `Input` is fully decoded before the forwarder body runs — the generator's contract.
- `ServerError` lifts its response from `underlyingError as? HTTPResponseConvertible` (verified in
  `swift-openapi-runtime`'s `ServerError.swift` and `UniversalServer.swift`), and
  `WireOpenAPIRoutes.invoke` consults that conformance in its terminal `catch`.
- `diagnoseErrorMappings` / `diagnoseMappingForm` already require a mapped status to be documented and
  the mapping's form to match the response's body-ness. Validation adds no rule to either; it adds an
  error type they already govern.
- `openapi.yaml` is a **source input of the target**, so reading more of it carries no plugin-ordering
  hazard. Reading the generator's emitted `Types.swift` would, and remains forbidden.
- Generated schema structs are `Hashable`, `allOf` members are `value1`/`value2`, and the generator
  enforces `additionalProperties: false` but nothing else — all three verified against the pinned
  fork (`9e655e0`) rather than assumed, and all three are dialect coupling belonging in
  *Coupling inventory*. A generator bump can move any of them.

## Reproducing the findings

The probe is a single document exercising recursion, `allOf` with one `$ref`'d and one inline member,
`uniqueItems`, every numeric keyword, `minProperties` and `additionalProperties: false`. Build the
fixture once, then drive the two binaries it produces directly:

```
cd wire-open-api/Fixtures && swift build
# what the generator does with the constraints (answers 1, 2, and additionalProperties)
.build/out/Products/Debug/swift-openapi-generator generate probe/openapi.yaml     --config probe/openapi-generator-config.yaml --output-directory probe/out
# what this adapter does with recursion (answer 3)
.build/out/Products/Debug/WireOpenAPIGen out.swift --spec probe/openapi.yaml     --spec-config probe/openapi-generator-config.yaml --module Probe probe/Controller.swift
```

The second exits 1 on the recursive document and 0 with only the recursive property removed, which is
the isolation that makes it a bug report rather than an observation.
