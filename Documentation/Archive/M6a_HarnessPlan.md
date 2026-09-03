# M6a — WireMVC testing harness: implementation plan

> ✅ **COMPLETE** — shipped as part of milestone **M6a (testing)**. Retained as implementation history; the
> in-progress notes below (status lines, "NEXT", the "one remaining follow-up" for factory-carrying proxies —
> since shipped with the mock-consuming-factory work — and the open decisions, all since settled) are
> historical. See [../ROADMAP.md](../../ROADMAP.md) for the milestone summary, [known gaps](../Notes/KnownGaps.md)
> for latent edge cases, and `wire-mvc/Documentation/TestingArchitecture.md` for the planned follow-up redesign.

> **Status:** the **wire-mvc** side of the M6a testing milestone — the HTTP harness that drives the
> swift-wire testing primitives ([Notes/TestingModel.md](../Notes/TestingModel.md): `@BindType` /
> `@Scopable` / `TestingKey`, **shipped** as Phase 1 + 2) over a real server. Design record:
> [Notes/WireMVCTesting.md](../Notes/WireMVCTesting.md). **Unbuilt.** Iterative, same phase/gate discipline
> as the swift-wire plan. This plan's code lives in **wire-mvc**; it (and `WireMVCTesting.md`) will move
> to that repo when built — kept here for now so the cross-links to the primitives resolve.

## Grounding — what a variant gives the harness

A test consumer declaring a `TestingKey` regenerates (spike-27) into a variant that emits: the doubles-threaded seed scope, a `_<Key>Doubles` struct, and a scope-entry
```swift
func _wireBootstrap<Variant>_<Seed>Scope(seed:, wireGraph:, doubles: _<Key>Doubles) async throws -> (…)
```
The runtime fixtures (`BindTypeDoublesTests`, `ScopableCascadeTests`) already **drive this entry by hand**, constructing a `_<Key>Doubles` and asserting the supplied instance flows through. The harness's whole job is to **supply that `doubles` at scope entry, per request, from an HTTP-correlated store** — turning the hand-driven fixture into `@Suite(.wiremvc(key)) { … withBindValues(repo:) { … } }`.

## The three pieces

1. **Runtime (`WireMVCTesting` library):** the correlation-keyed doubles **store**, `withBindValues`, `TestClient`, and the `@Suite(.wiremvc(key))` suite trait.
2. **Codegen (wire-mvc build plugin):** in a **test target** that depends on `WireMVCTesting` and selects a `TestingKey`, the generated request dispatch reads the correlation header → the store → builds `_<Key>Doubles` → calls the variant scope-entry with it. **Test-target-only** — production dispatch is unchanged (the `@main`/gate discipline from deliverable 2, Part B).
3. **Example:** a `@WireMVCBootstrap` app + a `TestingKey` test proving the full flow over HTTP — a request-scoped mock, a singleton mock (via the `@Scopable` cascade), and a *generated* mock.

## Phase H1 — the doubles supply channel (runtime)

The store holds the **concrete** `_<Key>Doubles` — no boxing. `withBindValues` and the dispatch are generated together for the key, so they share that type through the store's type parameter.

- **`TestBindStore<Doubles: Sendable>`** — a framework generic, `Mutex`-guarded `[CorrelationID: Doubles]`, instantiated per key as a generated static (`_<Key>Doubles` is `Sendable`). `withBindValues` (generated; its parameters typed from the key's `@BindType` slots) builds the concrete `_<Key>Doubles` and stores it; the dispatch reads it back concretely and passes it straight to the scope-entry — no per-slot erasure, no downcast.
- **`withBindValues(...) { body }`** — mint a `CorrelationID`, build the `_<Key>Doubles` from the passed instances and store it under the id, set a **task-local** carrying the id, run `body`, and remove the entry on exit (`defer` — survives throws/cancellation; a crashed process drops the whole store).
- **`TestClient`** — reads the task-local id and stamps `X-WireMVC-Test-Binds: <id>` on every request; typed surface `get`/`post(json:)` → `.status`/`.json(T)`, reusing deliverable 1's client.
- **Gate:** unit tests — store round-trip; `withBindValues` sets the task-local + clears on exit (incl. throw); `TestClient` stamps the header only inside the closure; parallel `withBindValues` closures get distinct ids → isolated store slots.

## Phase H2 — the suite trait + the doubles-threaded dispatch

### H2.1 — the suite trait *(built)*
`@Suite(.wiremvc())` — a swift-testing `SuiteTrait`/`TestScoping` (mirroring swift-local-containers' `containerTrait`) that, once at suite entry, builds + serves the wired app on an ephemeral port and exposes `TestClient.current`; cancels at suite exit. The opaque `~Copyable` handler stays inlined in a generated `.wiremvc()` factory closure the trait holds; `WireMVCTesting.serveForSuite` is the internal mechanism. Keyless form serves the default/replaced graph. **This is the one public server API** — the old per-test `withTestServer` is gone.

### H2.2 — thread the doubles (Route B: swift-wire proxy entry first)

**The blocker (found by the seam map).** swift-wire's Phase 1/2 variant emits only a seed-scope *facade* (`Wire.bootstrap<Variant>_<Seed>Scope(seed:wireGraph:doubles:)` → a scope struct). But wire-mvc's dispatch reaches request scope only through the M5.4 **contributor proxy's** `self._wireEnterScope(request)` → `(subject, teardown)` with per-route pruning. They don't meet. **Route A** (wire-mvc calls the facade directly) loses teardown + pruning and hard-codes swift-wire naming — rejected. **Route B** (decided): fix swift-wire so the variant drives a doubles-threaded proxy entry.

#### H2.2a — swift-wire: doubles-threaded contributor-proxy entry *(built)*
The same-proxy overload proved impossible (`_wireEnterScope` is a *stored closure field*, not a method; a variant proxy collides with the production proxy's type name in one module; the doubles thunk needs `wireGraph:` to capture borrows). So `buildTestingVariants` emits a **distinct, variant-name-disambiguated proxy** `_<Variant>_<ProductionProxy>` (its `_wireEnterScope` field re-typed to take the key's doubles) plus a facade `Wire.bootstrap<Variant>_<Subject>Contributor(wireGraph:)` that builds it against the reused production `_WireGraph` — reusing the production tuple+pruning thunk emission, the `ScopeEntryEmission` `doubles:` branch, and the Phase-2 `@Scopable` cascade. The seed-only production path is untouched.

**Consumer contract (what H2.2b binds to):**
```swift
let variantProxy = Wire.bootstrap<Variant>_<Subject>Contributor(wireGraph: graph)  // non-async/throws
let (subject, teardown) = try await variantProxy._wireEnterScope(request, doublesValue)  // positional, no label
```
`Variant` = key reference `.`→`_`; the variant proxy type is `_<Variant>_<ProductionProxyType>`. Gate: an emission unit test + a runtime IntegrationTests fixture (via a no-op `@RouteController` test-support marker in `WireTestLibrary`) proving init-time mock read + teardown runs + sibling pruning, all through one shared mock instance.

A spike over generic + borrowing subjects then reclassified the limitations:
- *Generic subjects* — **work.** The facade return type erases the opaque axes while the thunk concretizes at construction (`doubles.<field>` is the concrete mock), so `HelloController<G: Greeter>` under `@BindType` resolves — covered by fixtures (full + partial concretization).
- *Borrowed app singletons* — the spike surfaced (and this milestone **fixed**) a capture bug: the facade inlined `_wireGraph.<prop>` borrows *inside* the `@Sendable` thunk, capturing the non-`Sendable` graph. Any subject borrowing an app `@Singleton` (idiomatic controllers) broke. Fixed by binding those borrows as `Sendable` locals *outside* the thunk (via `reachableBorrows`), mirroring the production bootstrap. Covered by a borrow-regression fixture.

**One remaining follow-up (not blocking; avoidable in the H2.2b example):**
- *Factory-carrying proxies* — a subject with its own `@Middleware(key)`/factory-injected deps yields `_wireFactory_<key>` proxy fields the facade doesn't yet resolve. Wire the facade to borrow/construct factories from `wireGraph` when the examples need it (global front-layer middleware doesn't trigger it).

#### H2.2b — wire-mvc: the keyed dispatch
After swift-wire re-pin: `TestingKey` discovery in `WireMVCCodegen`; a `.wiremvc(key)` factory + a per-key `static let _<Key>DoublesStore = TestBindStore<_<Key>Doubles>()` + the generated typed `withBindValues(...)`; and the dispatch branch in `RouteCodegen.scopeEntryProloguePrefix` that reads `X-WireMVC-Test-Binds` → `correlationID(fromHeaderValue:)` → `store.value(for:)` → `self._wireEnterScope(request, doubles:)`. Emit only when `WireMVCTesting` is a dependency + a `TestingKey` is present; production dispatch unchanged.

### H2.3 — missing double → explicit 500 *(decided)*
Under `.wiremvc(key)`, a request reaching the doubles-threaded entry with no double in the store for its id → an explicit **500**, not a silent fall-back to the real binding (which would false-green a test that forgot `withBindValues`). A mock-nothing integration test uses the keyless `.wiremvc()` instead. Part of H2.2b's dispatch branch.

- **Gate (end-to-end, H2.2b):** a `@WireMVCBootstrap` app + a `TestingKey`; a `@Suite(.wiremvc(key))` suite; `withBindValues(repo: mock)` + a real `GET` observes the mock's behaviour over HTTP; a request *without* `withBindValues` for a reached slot → 500; parallel tests with different mocks don't cross (distinct ids).

## Phase H3 — the example

A `@WireMVCBootstrap` app (the `wire-mvc-examples` `SwiftHttpServerExample`, or a focused in-repo one) + a `TestingKey` test suite demonstrating end-to-end: a **request-scoped** mock; a **singleton** mock reached via the `@Scopable` cascade (with the guided-diagnostic experience shown); and a **generated** mock (smockable-style) proving the "can't annotate the concrete type" path. Alongside an *integration* suite that mocks nothing (real backend, the value-config port from deliverable 1) — showing the two coexist.

## Open decisions / risks

1. **Store typing — decided: concrete, not boxed.** A framework generic `TestBindStore<Doubles: Sendable>` instantiated per key holds `_<Key>Doubles` directly; `withBindValues` and the dispatch are generated together so they share the type. No `any Sendable` / downcast — the generated `_<Key>Doubles` is exactly what's stored and read back.
2. **Selecting + building the variant.** The suite trait must bootstrap the *variant* graph, not the default. The test target regenerates the variant; the trait needs the variant's bootstrap entry — decide whether the plugin emits a named per-key test entry the trait calls, or the trait is generated per key.
3. **The request-scope dispatch seam.** Confirm where in the generated route dispatch the `(seed:, wireGraph:, doubles:)` call is made (the request-scoped-controller witness) and that threading the store lookup there is a localized, test-target-only change.
4. **Coexistence.** `@Replaces` (compile-time, deliverable 2) and value-config (the server port) both still apply under the suite trait; `withBindValues` is the runtime-instance path on top.
5. **Non-`@WireMVCBootstrap` / adapter servers.** The bridge-proxy doubles threading (Hummingbird/Vapor via `WireMVCServerTransport`) is out of the first cut — proposal-native `NIOHTTPServer` first.
