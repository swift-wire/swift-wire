# Roadmap

Library milestones are tied to what task-cluster needs next, not to a fixed calendar. task-cluster today is a small CRUD service over Hummingbird and the OpenAPI generator with a DynamoDB-backed repository; planned growth includes a real task executor, metrics, tracing, auth, and scheduled or background work. Each milestone below lands when task-cluster's evolution makes it the next thing to solve.

M0 through M6 are complete. The historical implementation plans are archived at
[Documentation/Archive/M1_PLAN.md](Documentation/Archive/M1_PLAN.md),
[Documentation/Archive/M2_PLAN.md](Documentation/Archive/M2_PLAN.md), and
[Documentation/Archive/M5_PLAN.md](Documentation/Archive/M5_PLAN.md) (with the
M5.4 request-scope and M5.5 composition-root detail in
[Documentation/Archive/M5_4_PLAN.md](Documentation/Archive/M5_4_PLAN.md) and
[Documentation/Archive/M5_5_PLAN.md](Documentation/Archive/M5_5_PLAN.md)); M3's
design lives in [WireOpenAPIDesign.md](Documentation/Notes/WireOpenAPIDesign.md).
**M6 (surface completeness) closed at M6d.** All four sub-milestones shipped — M6a (testing) and M6b
(request-logger seam) in order, then M6d (advanced OpenAPI integration) out of order, then M6c
(`@ConfigProperty`) — and M5.6's doc debt, the last M5 thread, is discharged with it. Two loose ends are
**not** work M6 is holding open: task-cluster's migration off M3's adapter is sequenced by task-cluster,
and upstreaming the generator access change waits on upstream review. What M6 did not close is enumerated
in [RemainingSurfaceWork.md](Documentation/Notes/RemainingSurfaceWork.md), which is now the **named
successor track** rather than an M6e — see that note's *Open decision*, and *After M6* below. The detail
sections after the milestones (pre-1.0 polish, deferred features, the WireConfiguration preview) expand on
what lands when.

## Milestones

- **M0: validation spikes — complete (macOS 6.3 + Linux 6.3.1).** Four PoCs confirmed M1's design assumptions, with three derived adjustments folded in:
  - Spike 1 (cross-target source reading): PASS-with-fallback. Reading works for same-package and external-package dependencies; library discovery falls back to a `_WireExports.swift` marker file because SPM plugin-usage inspection isn't exposed.
  - Spike 2 (type-level macro walking method-level annotations): PASS. M5's `WireMVC` design is mechanically viable.
  - Spike 3 (annotation argument extraction): PASS. SwiftSyntax preserves type-expression structure verbatim, including nested- and multi-argument generics. M1 must normalise interior whitespace before binding lookup so `Router<X, Y>` and `Router<X,Y>` resolve to the same binding.
  - Spike 4 (swift-syntax pinning): PASS. `from: "601.0.0"` resolves to swift-syntax 601.0.1 identically on both platforms. Bumps to 602.x are deliberate per-Swift-release maintenance events.
- **M1: core graph — complete.** Macros (`@Singleton`, `@Scoped`, `@Inject`, `@Container`, `@Provides`, `@Contributes`, `@Teardown`), runtime types (`Lazy<T>`, `BindingKey<T>`, `CollectedKey<T>`, `MappedKey<K, V>`, `BuilderKey<B>`), build plugin, graph validation (including cross-scope storage checks), the adapter-annotation contract v1, opaque-type support (`@Singleton(as:)` plus lift-the-minimum — see [OpaqueTypesSupport.md](Documentation/Notes/OpaqueTypesSupport.md)), multi-module composition (activation = depending on a Wire-aware library; full cross-target validation by re-parsing dependency sources at build time and merging into one graph; the manifest optimization is deferred to M7a, and reachability pruning shipped in M7b), Linux CI. task-cluster's manual wiring switched to Wire-driven construction; framework integration stays manual at this point. The `_WireGraph.json` dump moved to pre-1.0 polish (below). No public 0.x tag yet.
- **M2: `WireHummingbird` adapter — complete.** The first framework adapter: native **app-scoped** Hummingbird controllers auto-wired onto a `Router` that stays *outside* the graph, on the principle of **collation, not registration**. Two framework-agnostic capabilities landed in Wire Core — the graph-conformance emission (`extension _WireGraph: <Protocol>`, so Wire wires an adapter-declared protocol knowing nothing about HTTP) and the **contribution-alias** adapter contract (an annotation aliases `@Contributes(to: key)`, retiring the iteration-8 `_wireRegister` side-effect). On top, the external `wire-hummingbird` repo (depending on pushed swift-wire main) ships: context-free route collation via `@HummingbirdController` (a `@Contributes` alias that also generates the mount witness); service-lifecycle collation via `@HummingbirdService` → `[any Service]` (the first real `CollectedKey` consumer); and a framework-agnostic `introspect()` wiring model (bindings, kinds, scopes, dependency edges, source locations) with a mountable JSON endpoint. **Middleware is out of scope** — a context-typed value with no clean collation shape, so the app owns it via `router.addMiddleware`; the callable-vs-value boundary (routes/controllers are callables whose context defers to the call site; middleware and typed values aren't) is what decides what collates. The Tier-2 composition-root macro anticipated here was **retired** — M5.5 shipped the proposal-native `@WireMVCBootstrap` instead (see M5 above), on the principle that a `@WireHummingbird`/`@WireVapor` macro fights the grain in those frameworks' own ecosystems. See the archived [M2 plan](Documentation/Archive/M2_PLAN.md) and [WireHummingbirdDesign.md](Documentation/Notes/WireHummingbirdDesign.md).
- **M3: `WireOpenAPI` adapter — complete.** The **cross-runtime** adapter and the headline differentiator. It **re-homes M2's collation model** from `some RouterMethods<Context>` onto `some ServerTransport`: `@OpenAPIController` (a `@Contributes` alias, mirroring `@HummingbirdController` — optional path → `registerHandlers`'s `serverURL`) makes an `APIProtocol` conformer a `TransportContributor` whose generated witness calls `registerHandlers`; `WireOpenAPI.apply` registers the collated handlers onto a user-provided `ServerTransport` that stays *outside* the graph. Because the target is `ServerTransport` (and the external `wire-open-api` package depends only on `OpenAPIRuntime`, no HTTP framework), the same wired controller mounts on Hummingbird, Vapor, or Lambda unchanged. **Handlers-only** — unlike Hummingbird, OpenAPI is not a runtime, so services/lifecycle stay with WireHummingbird. task-cluster demonstrates **the two adapters coexisting on one graph**: WireOpenAPI registers the collated handlers on the router's `ServerTransport`, and WireHummingbird's introspection endpoint serves the graph's wiring model over the same router (`/wiring`), verified live. Two Wire Core capabilities landed to make that clean: a graph conformance now emits for an **activated adapter with zero contributors** (empty-collection accessors, with conformances and multibinding keys treated as import sources like bindings), and every generated graph conforms to a public **`Introspectable`** protocol, so a facade takes `some Introspectable`/`mountIntrospection(graph:)` without naming the internal concrete graph. The `ServerTransport` collation surface (`TransportContributor` / `TransportKeys.handlers` / `TransportComposable` / `apply`) is the durable primitive M5's `@Controller` folds into — a re-home, not a parallel surface. task-cluster's `TaskController.registerHandlers(on: router)` moved into the adapter system, validated live against pushed swift-wire main. **M3.4 (an explicit second-transport demo) was skipped** — the cross-runtime property is structural (the target is `ServerTransport`), not something a demo makes truer. `@OpenAPIConfiguration` and middleware are deferred (middleware to align with M5's `swift-http-api-proposal` `Middleware`). See [WireOpenAPIDesign.md](Documentation/Notes/WireOpenAPIDesign.md).
- **M4: lifecycle orchestration — complete.** The forcing case: task-cluster moved onto a real (Soto) DynamoDB client vs the in-memory one, needing orderly shutdown. The `@Teardown` annotation existed from M1 (recognised and recorded, but inert); M4 emits the **app-scope** teardown walk — `teardown()` on the generated graph, calling each `@Teardown` action in reverse dependency order, run at shutdown via WireHummingbird's `teardownService` (a `ServiceLifecycle` service prepended so it shuts down last, after the server stops). Teardown-action failures are collected and logged so one doesn't stop the rest. **Request-/job-scope teardown** needs request scope and is **M5**. **Init-failure partial teardown** — tearing down already-constructed bindings in reverse before a bootstrap rethrow — is deferred to **M7c**: its implementation is fixed by the construction scheduler that pass settles (a linear prefix today vs. the resolved cells of the dynamic scheduler's state struct), so it lands there once rather than being rewritten; until then a bootstrap init-failure leaves constructed resources for process exit to reclaim. The forcing case moved task-cluster onto the Soto AWS stack (`AWSClient` `@Provides @Teardown`), validated against a real table via a LocalStack integration test. See [TeardownDesign.md](Documentation/Notes/TeardownDesign.md).
- **M5: `WireMVC` adapter — complete.** The first type-level-with-member-recognition adapter (spike-2 proved the macro mechanics): `@Controller`/`@Get`/`@Path`/`@JSONResponse`/`@JSONBody`/`@RawRoute` **fold into a Wire collation surface** (`WireMVCKeys.routeContributors`, mirroring M3's `ServerTransport` collation *shape* with WireMVC's own key) — so cross-runtime comes for free and WireMVC is essentially a spec-free, annotation-driven analogue of the OpenAPI generator's registration codegen. **Proposal-native:** the witness registers on `RoutableHTTPServerBuilder` (over `swift-http-api-proposal`'s `HTTPServer`), not `some ServerTransport` — deploying against macOS 26 makes `anyAppleOS 26.0` unconditional, so the plan's *tracked successor* became the core; `some ServerTransport` is retained as the opt-in `WireMVCServerTransport` adapter (Hummingbird/Vapor), so the core doesn't depend on OpenAPIRuntime. The settled design is the authoritative record in [WireMVCDesign.md](Documentation/Notes/WireMVCDesign.md) (raw-handler + middleware detail in [WireMVCMiddleware.md](Documentation/Notes/WireMVCMiddleware.md)); the implementation history is the archived [M5 plan](Documentation/Archive/M5_PLAN.md). What shipped:
  - **M5.0–M5.3 — typed routing, middleware, raw handlers.** Because WireMVC owns the route-registration codegen, controller- and route-scoped `@Middleware` are nested wrappers around the generated handler closure — no runtime router type, composition is closure nesting. **Type-transforming middleware falls out as a compile error, not a declared feature:** the codegen threads each middleware's output type into the next stage's input, terminating at the handler's expected input, so an auth middleware producing a principal a handler requires either type-checks or fails at the generated seam — modeled on the ecosystem-standard `Middleware<Input, NextInput>` shape (forward transform, handler as terminal stage, mismatch enforced by `@MiddlewareBuilder`/`ChainedMiddleware`). The `@RawRoute` escape hatch takes the proposal's raw primitives (`consuming sending Reader`/`ResponseSender`) verbatim, skipping decode/encode — streaming/SSE/proxying live here (spike-14 proves SSE both natively and via the `ServerTransport` adapter); **WebSocket stays escape-to-framework** (an upgrade isn't request→response).
  - **M5.4 — request-scoped controllers.** A `@Scoped(seed:)` controller becomes an app-scoped proxy contributor whose *generated* registration embeds per-request scope entry (weak back-ref to the app graph + an injected scope-entry thunk), reusing the shared "adapter replaces the binding" primitive. Each is a **per-request reachability root** — its scope-entry constructs only its own transitive request-scoped subgraph (the M7b reachability concept at the request-construction layer, structural here, not deferrable). Sub-milestones: M5.4E `@ErrorResponse` (error→status tiers), M5.4R `@RawRoute(.role)`, M5.4.5 request-scope teardown, M5.4.6 per-root reachability. Detail in the archived [M5.4 plan](Documentation/Archive/M5_4_PLAN.md).
  - **M5.5 — `@WireMVCBootstrap` composition root.** The WireMVC-native Tier-2 macro: a `@Singleton` composition-root struct whose plugin generates the program entry point (`@main`) — no hand-written `main.swift`. It folds in the `@NotFound` fallback, `@ErrorResponse` global tiers, an optional `introspect()` mount (`mountIntrospectionAt()`, basic or route-scope-guarded), and **global `@Middleware`** as a front layer: a single `GlobalMiddlewareHandler` wraps the finalized router once in the `@main` — O(1) in route count, plain routes untouched, the miss endpoint covered for free (the wrapper sits above the router's 404). It rides swift-wire's `.liftsPeersToProxy` capability (a keyless `.contributesProxy` variant that reattributes the root's `@Middleware` factories onto a synthesized proxy). **Deliberately proposal-native, not a `@WireHummingbird`/`@WireVapor` macro** — a composition-root macro fights the grain in those frameworks' own ecosystems. Detail in the archived [M5.5 plan](Documentation/Archive/M5_5_PLAN.md).
  - **M5.6 — `WireMVCAbstraction.md` rewrite (doc debt) — complete.** The last M5 thread, taken in the M6-era doc pass as scheduled. The note is rewritten against what shipped and the `_wireRegister` model is gone from the WireMVC design surface, with the incidental mentions swept from `ScopeAndKeyModelEvolution.md`, `OpaqueTypesSupport.md` and `VisibilityModel.md` (marked as period-accurate rather than rewritten — they are records of iteration-8 thinking about other subjects). **One thing was done differently from the scope written here:** the Tier-1/Tier-2 progressive-adoption content did *not* fold into [WireMVCDesign.md](Documentation/Notes/WireMVCDesign.md). Folding it in would have put an adoption narrative inside a surface decision record; the two are different subjects with different readers, and the design note is already dense. So [WireMVCAbstraction.md](Documentation/Notes/WireMVCAbstraction.md) survives as the **companion** note — how an existing framework app moves onto Wire in steps, and where each step stops — with the design record authoritative over any surface question. What the rewrite also settled is that the exploration's *tiers* were right and its *mechanism* was not, which is the reason it was worth rewriting rather than deleting.
- **M6: surface completeness / DX — complete.** The pre-1.0 *surface* work — features that make idiomatic apps expressible and unblock the last examples, ahead of M7's invisible perf passes. The principle was *complete the surface before optimizing it*, and it was ordered so foundational, example-unblocking work led. **The examples this milestone existed to unblock were enumerated outside it**, in [RemainingSurfaceWork.md](Documentation/Notes/RemainingSurfaceWork.md) — which sequenced the parity and streaming tracks together with wire-mvc's router backlog, and is where the milestone's definition was actually tested. **All three of those tracks have closed** (the router backlog entirely, the streaming migration entirely, the parity examples), which is what lets M6 close on its own terms rather than by declaration: the larger reading of "unblock the last examples" was the one worked from, and it finished. What is left of that note is one upstream-blocked tier and one allocation group, neither of which is surface work — so the note becomes the successor track and M6 does not grow an M6e to hold them — see *After M6* below. What shipped:
  - **M6a — testing — complete.** Make a `@WireMVCBootstrap` app testable end-to-end. It shipped the original three deliverables — the `@Suite(.wiremvc())` suite-trait seam (build-without-serve; the harness owns serving/port/cancellation, no override machinery); **`@Replaces`** (a test target as its own Wire consumer superseding a sibling module's binding for the same key, retiring the duplicate-binding error); and a **`WireMVCTesting`** typed client + `SwiftHttpServerExample` migration with a real-backend integration suite — validated by spikes **26** (seam factors trivially) and **27** (a test target composes an executable dependency's bindings, `_WireExports.swift` marker + `package` cross-module access, no library restructure). It then **grew into the full keyed variant-graph testing story**: `@BindType` doubles supply (`withBindValues`, `TestClient`, per-key `TestBindStore`, missing-double → explicit 500); a **variant app graph** per `TestingKey` that drops the mocked eager `@Singleton(as:)` bindings, so a mocked suite is Docker-free without touching production; **seedless per-request reconstruction** (`@TestScopable`) for app-scoped route contributors, with the guided-`@TestScopable` diagnostic; the **generic** subject (opaque-lift concretized to the mock) and **generic mock-consuming middleware factory** (`create(doubles:)`) cases; and raw-route + multi-slot keyed variants. Proven end-to-end by the wire-mvc-examples `SwiftHttpServerExample` un-gate (#32): a Docker-free mocked routing suite (smockable `verify` over `/me`/`/todos`/`/export`) alongside the real-backend integration suite. Implementation history: [M6a testing-primitives plan](Documentation/Archive/M6a_TestingPlan.md) (swift-wire), [M6a harness plan](Documentation/Archive/M6a_HarnessPlan.md) (wire-mvc), [VariantAppGraphPlan.md](Documentation/Archive/VariantAppGraphPlan.md), [ScopableRouteContributorsPlan.md](Documentation/Archive/ScopableRouteContributorsPlan.md). Latent edge cases (a global mock-consuming middleware; keyed-slot / transitive / factory-only-mock corners) are tracked in [PendingIssues/](PendingIssues/README.md), non-blocking. A **follow-up redesign** — decouple `WireMVCTesting` from a concrete server + a three-mode (`.inProcess` / `.server(_:)` / `.swiftHttpServer`) harness — is designed in `wire-mvc/Documentation/TestingArchitecture.md` (not part of M6a; not started).
  - **M6b — request-logger seam — complete.** A per-request logger as a first-class convenience on top of the already-shipped request-scope injection. It stayed true to "not a new primitive" — the logger is an ordinary `@Scoped(seed: HTTPRequest.self)` binding, so nothing in the witness or the context needed to carry it — but it was **larger than the "small" it was scoped as**: two interchangeable logging targets, a pre-graph hook, and four swift-wire changes. What shipped:
    - **`WireMVCLogging` (the default target).** Three bindings: the app logger under the *keyed* `WireMVCApplication.logger`, the per-request correlation id under `WireMVCRequest.id` (`X-Request-Id` first, then a W3C `traceparent` trace-id, then a fresh UUID — an inbound id is kept so a request holds one identity across services), and the request logger. **Which binding a plain `@Inject var logger: Logger` resolves to is the whole design:** the request-scoped one is *unkeyed*, so the easy thing to write inside a request is the correct thing and reaching for the process-wide logger is what costs a key. Outside a request scope the same spelling is a missing-binding error naming the scope it is bound in. Scope shadowing would have been the other way there and is **deliberately not built** — binding identity excludes scope, and the app singleton is borrowed into *every* scope, so it is the one binding that meets every scope's logger and therefore the one that has to take the key. **Not a coin flip between two scopes:** sibling seeded scopes never borrow from each other, so a second scope declares its own unkeyed `Logger` and a job-scoped `@Inject var logger: Logger` resolves to *that* one — measured, not assumed. Every seeded scope gets the bare spelling for free; only the app logger pays, and the rule scales to as many scopes as an app has without touching swift-wire's scope semantics. Metadata is **open**: `WireMVCLogMetadata.stringEntries` is a `MappedKey<String, String>` folded into the logger, so a distributed-tracing integration adds trace/span ids by `@Contributes` rather than by editing WireMVC or replacing the logger wholesale — and being *value*-typed rather than `Logger.MetadataValue`-typed makes a field one declaration (the injectable binding *is* the log field). Every binding is `@Replaces`-able, so a custom id scheme or handler needs no configuration surface of its own.
    - **`WireMVCTaskLocalLogging` (the second target, and the reason the split exists).** Hummingbird wraps its responder chain in `withLogger(…)`, so a request already *has* a logger with an id on it and the default target mints a second — WireMVC's lines and the framework's own lines then correlate to different ids. This target *adopts* swift-log's task-local (`Logger.current`) instead, which is the only way to share one, and survives the `WireMVCServerTransport` bridge's unstructured `Task {}` including the streaming case where the handler outlives the register closure (spike-30). That `Task {}` inherits task-locals and priority but **not cancellation** — a distinction the logging story depends on the first half of and which cost the bridge the second: a client disconnecting before the handler sent a head left it running to completion, since the lifetime tie to the returned body (`HandlerTaskHandle`) only exists once there *is* a body. Now cancelled explicitly via `withTaskCancellationHandler`, and pinned. The unstructured task itself stays: `ServerTransport.register` returns `(HTTPResponse, HTTPBody?)` and the framework consumes that body after the closure returns, so the producer must outlive the closure — no task group inside it can work, a discarding one included, since those await their children at scope exit; and Hummingbird and Vapor are natively the same head-then-body shape, so a per-framework bridge would not remove it either. See [PendingIssues/15](PendingIssues/15-cancelled-request-reports-500.md) for what remains (the cancelled request is *reported* as a 500). The two targets are deliberately interchangeable — same three bindings, same keys, same derived id, differing in exactly one expression (the request logger's base) — so an app switches by changing one import; the genuinely shared pieces live in the core as `WireMVCRequest.correlationID(from:)` and `WireMVCLogMetadata.applying(_:to:)`. Depending on both is a build error. **Not the default:** Vapor and the native proposal server bind no task-local, so on those runtimes it silently reads swift-log's empty-label process default. Gated by `WireMVCTaskLocalExample`, whose fixture binds *different* loggers at bootstrap and at serve so that seeing the serve marker proves the request logger re-reads rather than snapshotting.
    - **`@WireMVCBootstrap.prepare()` — a pre-graph step.** `LoggingSystem.bootstrap` must run before the first log call and traps on a second, and its metrics/tracing counterparts behave the same way; every existing Bootstrap hook (`createServer`, `createRouteBuilder`) is an *instance* method, so by construction it runs after `Wire.bootstrap` built the graph. `prepare()` is static and runs first — returning a value makes it the graph's `@GraphInputs`, returning `Void` is the side-effect-only form. Being pre-graph it can inject nothing; that is the trade for running first. The generated *test* entry routes through `WireMVCTesting.preparedOnce`, which memoises the `Task` under a mutex (not a has-run flag, which would race under parallel suites), so a multi-suite bundle doesn't trap on a second `LoggingSystem.bootstrap`.
    - **Four swift-wire changes fell out of it.** **`@GraphInputs`** (#266) gives the root graph the door a seeded scope already had — each stored property of the annotated struct becomes an app-scope binding and `Wire.bootstrap(inputs:)` is how the values arrive, emitted as ordinary property-form providers (so resolution, keying, `@Bind`, dead-binding analysis and emission needed no special case), `allowUnused` and necessarily leaves. A **`@Bind` parameter can now name a multibinding key** (#263) — the forcing case being the request logger folding a `MappedKey` inside a `@Provides`, which previously had no parameter spelling and forced restructuring the consumer. And two **dead-binding-warning** fixes surfaced by wire-mvc's fixtures: a scope-bound subject is now counted as consumed by its proxy's scope-entry thunk (#264 — every `@Scoped(seed:) @Controller` warned as dead), and synthesised contributor proxies are `allowUnused` outright (#265 — M5.5's global-middleware proxy warned in every `@WireMVCBootstrap` app, anchored at the user's Bootstrap).
  - **M6c — `@ConfigProperty` / WireConfiguration — built.** The swift-configuration adapter, in a new [`wire-configuration`](https://github.com/tachyonics/wire-configuration) package. `@ConfigProperty(forKey:default:)` at all three sites — `@Inject` property, `@Inject init` parameter, `@Provides func` parameter — makes the *value* the binding rather than the reader: a consumer depends on `Int`/`String` instead of on a collaborator it has to call, the key is visible in the signature, and a test substitutes a value rather than a configured reader. (Note the justification this milestone was scheduled under — *every example hand-rolls config* — was already spent by M6b, which put one shared `ConfigReader` behind a `@GraphInputs` value in all three runtimes. The narrower win above is what it was built for.)
    - **The domain logic lives in the adapter, not in Wire — and that is the whole design.** The capability `.rewritesInjection` had been reserved since iteration 8, naming `@ConfigProperty` in its doc comment and carrying no payload; it gained exactly one, `provider:`. Wire emits `try <Annotation><Value>.wireValue(from: <provider>, <the annotation's arguments, verbatim>)`, copying the argument list without reading it — so it never learns what a value means, which method reads it, or that a "default" or a "secret" is a thing. The call is **static**, which keeps the annotation's two roles apart: its initialisers carry the value the compiler passes at a use site, and resolution is a static method given a provider, so Wire builds no instance to resolve. Which `ConfigReader` method each type uses is chosen by *constrained overloads* (`where Value == Int`) — ordinary Swift overload resolution, so an unsupported type fails at the user's own annotation rather than inside generated code, and adding a type is adding overloads. **There is no protocol to conform to.** An earlier cut had one, but it ended up requiring only an associated `Provider` type — a second source for something `provider:` already states, which generated code would then have had to agree with; everything else in the contract has a signature determined by the annotation's own arguments, which no protocol can express. `provider:` is the one thing Wire cannot derive: it matches dependencies by canonical type text.
    - **What that buys beyond configuration.** A third-party `@Secret`, `@FeatureFlag` or `@Clock` conforms its wrapper and declares `.rewritesInjection(provider:)` — no swift-wire change, no table to extend. The pass is generic; the earlier plan (a Configuration-aware pass with a hard-coded type→method table in swift-wire) was **abandoned during the build** as strictly worse: more code in the core, a worse diagnostic, and no extensibility.
    - **Dedup is by (annotation, arguments, type)**, so the same annotation written at three sites is one binding read once, while a different key — or the same key at another type — is distinct. The synthesised producer is keyed by a generated identifier, so it can neither capture nor be captured by an ordinary binding of the same type; those generated keys are exempted from both the missing-key diagnostic and `_WireKeyChecks`, since neither has a user declaration to check against.
    - **Gate:** `InjectionRewriteHarness/`, an adapter + consumer pair, separate for the same reason `AdapterHarness` is — a fixture adapter depends on swift-wire, so a package inside its tests would cycle. Its adapter is **synthetic** (`@FromSettings` over a dictionary), not WireConfiguration: swift-wire must not depend on one of its own adapters, and a fixture with nothing to do with configuration is better evidence that the pass learned nothing domain-specific. It exercises all three sites, dedup, the no-default form, and that an unannotated binding of the same type is untouched. CI runs it, as it does the other three.
    - **The provider selector — built, by label rather than by position.** `@ConfigProperty(reader: ConfigKeys.overrides, forKey:…)` names which `ConfigReader` a site reads from, for a graph binding more than one. An adapter opts in with `.rewritesInjection(provider:selector: .labelled("reader"))`; Wire lifts that argument out and keys the synthesised producer's dependency on the provider with it, which is the single place it stops copying the argument list verbatim. Omitted, the provider resolves by type as before. The design below specified a *leading unlabelled* argument, matching the `@Bind(K)` idiom — that cannot work in general: an annotation whose own first argument is unlabelled (`@Secret("DB_PASSWORD")`) is indistinguishable from one leading with a selector, and Wire sees only the use site, never the wrapper's signature, so it cannot verify that an adapter has no other unlabelled arguments. A label is unambiguous whatever else the annotation takes, and each adapter picks one that reads in its own domain. `WireProviderSelector` is a struct with a static factory, not an enum, so a leading-unlabelled form can be added later without breaking an exhaustive `switch`; `selector:` is defaulted, so `WireAdapterAnnotationV1` did not need a V2. Two consequences worth stating: the selector stays in the **dedup identity** (two sites with identical arguments reading different providers are different bindings — collapsing them would silently give both one value), and the synthesised provider dependency is now anchored at a **real site** rather than `<synthetic>:0:0`, so an undeclared selector key reports against source the user wrote.
    - **Validated in wire-mvc-examples.** All three runtimes' backend providers now declare what they need rather than taking a reader and calling it — CouchDB and the server bind address on the proposal runtime, Valkey on Hummingbird, MongoDB on Vapor, with the CouchDB password carrying `isSecret:`. The env-var contract is unchanged, and the `@GraphInputs` reader stays, since that is what the synthesised producers resolve against. Two things surfaced there: a test target needs the adapter as its *own* dependency (depend-to-activate does not inherit through the app it re-composes, and without it an annotated site quietly falls back to resolving by type — the error names the parameter, not the missing dependency); and a **swift-wire bug**, where the seedless reconstruction thunk a keyed variant graph builds picked its subject positionally (`topologicalOrder.last`) and so returned a config string where a controller belonged, once these rewrites put new bindings in the app scope. Fixed to read the subject from the thunk's own return type.
  - **M6d — advanced OpenAPI integration — built.** WireMVC's request-scope + typed-param/response DX brought onto OpenAPI operations. The objective was **one routing model, not two**: an app expresses middleware, error mapping, request scope, encoding and its composition root the same way whether a route came from an OpenAPI document or from `@Get`. What that selected is operations becoming **WireMVC routes** — `@OpenAPIController` contributes to `WireMVCKeys.routeContributors` and `TransportKeys.handlers` retires as a collated key, so there is one collation surface rather than two. Shipped across M6d.0–M6d.6: **direct dispatch** on a per-request copy of a `UniversalServer` (adopted on measurement, replacing the designed task-local, and needing a generator access widening carried on a fork); many controllers per spec and many specs per app (per-spec namespaces resolve the identically-spelled generated types); the **typed shim** (`@Operation`, parameter binding through WireMVC's own property wrappers, responses selected from the document) with two pieces of generator naming **transcribed** and held by goldens the real generator produces; **spec-read validation** via OpenAPIKit, fully dereferenced — reading the document as a dictionary silently dropped `$ref` parameters; and `@ErrorResponse` across both sites. Coding landed in **wire-mvc** rather than here (`WireMVCCoding` + `@Coding`), because a `@Get` route returning a `Date` asks the same question and was answering it differently — closing a live inconsistency between the two kinds of route. Deferred by decision: `@OpenAPIConfiguration` (what remains of it has nothing to act on until non-JSON bodies are supported at the terminal), the decomposition-transformer registry (it belongs in wire-mvc first), and non-JSON bodies themselves. **Outstanding, and neither holds M6 open:** task-cluster is not yet migrated, so the forcing case still runs M3's adapter — sequenced by task-cluster's own needs rather than by this milestone. And the generator fork wants **upstreaming**; the *pin* this entry used to offer as the alternative is already done (`wire-open-api/Fixtures/Package.swift`, revision `9e655e0` — a branch reference on a fork nobody else watches is exactly the kind that moves quietly), so what remains depends on upstream review and is not fully in our control. Decision record: [WireOpenAPIAdvanced.md](Documentation/Notes/WireOpenAPIAdvanced.md).
- **M7: performance optimizations — M7b, M7c.1–M7c.5 and M7d complete; M7a, M7c.6 and M7e trigger-based.** A cluster of perf passes, each landing when its cost is felt — the multi-module discovery/pruning optimizations (M7a/M7b; multi-module composition itself ships in M1) plus construction scheduling (M7c). All keep the surface contract unchanged and are invisible to users. **Ordering, decided at the start (2026-08): M7b leads, and M7a is deferred out of the milestone.** The two were spiked against each other and the cost model separated them cleanly. On the same 500-file dependency where a consumer injects exactly *one* binding, the re-parse M7a removes costs **~50 ms**, while the graph M7b prunes carries 500 stored properties, **500 eager constructions** and 1,522 lines of generated code. M7b also carries a structural debt M7a does not: it is the prerequisite for retiring the `_WireExports.swift` marker, whose replacement signal ("a direct dependency that depends on the `Wire` product") the same spike verified readable. M7a's feasibility question is answered rather than dropped — the mechanism works; the deferral is on cost and on a predicate SPM cannot supply, recorded with its upstream asks in [PendingIssues/20](PendingIssues/20-manifest-discovery-plugin-output-visibility.md). **M7b shipped 2026-08/09** across five sub-steps, taking M7d with it; what is left of the milestone waits on external triggers rather than on each other. The build plan for the milestone is [Documentation/M7_PLAN.md](Documentation/M7_PLAN.md).
  - **M7a — manifest-based discovery. Deferred at the top of M7, with the mechanism proven — see [PendingIssues/20](PendingIssues/20-manifest-discovery-plugin-output-visibility.md).** Each library's build plugin emits a per-library compile-time manifest of its bindings; the consumer reads manifests instead of re-parsing source. A 2026-08 spike settled the feasibility question the design note had left open: a consumer's build *command* **can** read a dependency's plugin output, given the derived path declared in `inputFiles` — verified under both build backends, with correct incremental propagation. What holds it is not the mechanism but a **predicate**: the edge is declared at plan time, an input nothing produces is a hard build failure, and SPM exposes no signal for whether a dependency applies a plugin. So the trigger is no longer "when re-parsing gets slow" (it is ~0.1 ms/file, and the `ARG_MAX` warning bites first) but **when SPM can answer the predicate**, or when a dependency graph makes the derived-path route worth its undocumented-layout cost. `_WireExports.swift` does *not* become the manifest — it is retired independently, with M7b.
  - **M7b — reachability pruning. Complete.** The plugin computes the bindings reachable from the graph's roots and strips the rest before codegen, so a dependency costs only what the consumer reaches. Measured on the case this entry used to predict — a 500-binding library where the consumer injects exactly one binding — **1,525 generated lines, 501 stored properties and 501 eager constructions became 28, 2 and 2.** `Lazy<T>` is no longer the workaround for an expensive library binding; not reaching it is enough.
    **Roots are declared, because Wire reads syntax and never use**: the generated graph is `internal` and `graph.userService` is an expression no discovery pass sees. There are two — an aggregate a graph conformance names, and `allowUnused: true` in the home package (on a binding or a multibinding key); `@GraphInputs` properties are already the second of those. Two candidates were settled *against*: `@Teardown` does not root a binding (teardown is what happens to a binding you built, not a reason to build one — and rooting on it would pin every dependency's `@Teardown` binding into every consumer), and a `public` key does not root its aggregate (visibility gates diagnostics about *consumption*; nothing outside the graph can read an aggregate's product). See [MultiModuleComposition.md](Documentation/Notes/MultiModuleComposition.md) § "Reachability roots (M7b.0)".
    Pruning the home module is the one behaviour change, so it ships with a diagnostic rather than in silence — naming the binding, the `allowUnused` fix-it, and the property the developer would have read. On this repository the whole migration was seven annotations, after which generated output was byte-identical.
    The promised **dead-code diagnostic** arrived with it, and more than promised: reachability *is* the fixed point the first-order check never had, so a binding consumed solely by another dead binding is now caught, along with the package-local contributor folded into a `public` aggregate nothing consumes — while the aggregate itself stays silent. The limitation survives only inside a seed scope, which is built unpruned until the whole-scope façade goes.
    It also discharged the structural debt: **`_WireExports.swift` is retired** (M7b.5), detection replaced by "this dependency's target depends on the `Wire` product". That coupling is now a fixture rather than an argument — with pruning disabled, a consumer whose dependency has a binding needing a type from a package it never depended on fails with `no binding produces 'DeepConfig'`, which is exactly why retirement had to wait for reachability. wire-mvc, wire-open-api, wire-configuration, wire-mvc-examples and wire-mvc-performance moved with it.
  - **M7c — dynamic construction scheduling.** Lands when construction latency (a deep async dependency chain built strictly level-by-level) is worth optimising. Replaces the strict sequential/per-level bootstrap with the dynamic *ready-as-deps-resolve* form — a single `TaskGroup`, each binding firing the instant its own deps resolve (maximum parallelism; sync bindings still construct inline). The scheduling model is [EffectAwareResolution.md](Documentation/Notes/EffectAwareResolution.md); the **emission design is [ConstructionScheduling.md](Documentation/Notes/ConstructionScheduling.md)**, which supersedes that note's per-binding `AtomicState<T>` cells with one `~Copyable` state struct owned by the draining parent (the `AtomicState` type itself is **retired** — it never acquired a caller) — the cell's `Value: Sendable` constraint applies to every scheduled binding and would have forced two permanent emitter shapes, and a `~Copyable` binding cannot enter a cell at all. It also carries an early step that stands on its own, and **that step shipped as M7c.1 (2026-09)**: narrowing what `_WireGraph` **retains** to M7b's root set — plus `@Teardown` bindings, opaque lifts and what generated code reads off the graph — which is what makes a non-Sendable binding transferable into a child task. 569 stored properties left the integration corpus (the default graph: 123 → 79) at no cost in generated lines. A binding the graph builds but does not store keeps an `@available(*, unavailable)` stub, so an app reading it through `graph.x` gets the property name, the `allowUnused: true` fix and the declaration's location **at its own read site** rather than a build warning that would never quiesce. **M7c.2 followed (2026-09)**: the construction state struct — a `~Copyable` cell per binding, an `add` per binding that fires when its dependencies resolve, and a cascade from each resolution into its dependents — driven with *no* task group, so the whole cascade runs inline. It applies per graph, to a graph with an async binding and none of the constructs M7c.4 owns; every pre-existing graph in the corpus stays byte-identical, and a new `@Container` fixture is what takes the path. The cell itself is library code (`Wire._WireBindingState`). Two findings came with it: no corpus graph was async-and-clean, so the staging as written had an empty population; and `take() -> sending Value` compiles on the 6.3.3 floor but is *correctly* rejected on the 6.4 snapshot this package also pins, because `~Copyable` on a generic parameter suppresses the `Copyable` requirement rather than replacing it — so the cell must type-check for copyable payloads, where `.consumed` proves nothing about aliasing. That costs M7c.2 nothing (it has no task boundary) but bounds M7c.3 to Sendable bindings until M8. **M7c.3 followed (2026-09)**: the async bindings move into a `ThrowingTaskGroup`, the parent drains it and applies each child's result to its cell, and the cascade fires from there — so a dependent of a fast async binding is constructed while a slow, independent one is still suspended, which is the whole of what the group buys and what a new `@Container` fixture asserts. Three things it settled. **The trigger narrowed** from "the graph has an async binding" to "two of its async bindings have no dependency path between them": one async binding in a group is one child task the parent immediately blocks on, and a chain is sequential however it is scheduled, so both keep the linear chain — which also retires M7c.2's sequential state struct, whose population is now empty. **The `Sendable` bound above became a user-visible edge, and is asserted rather than decided**: `ChildTaskResult` is `Sendable` *and* `Copyable`, and `addTask`'s closure is `sending`, so a scheduled binding's product and every dependency its closure captures must be `Sendable` — which Wire cannot compute, because it reads syntax and never sees a conformance. Each scheduled graph therefore emits a never-called `_wireSendableChecks…` function of `#sourceLocation`-wrapped assertions — the instrument `_WireKeyChecks.swift` already uses — so a non-Sendable *dependency*, whose native failure is `sending closure risks causing data races` inside a closure the user never wrote, is reported **at the binding's own declaration** and nothing else is. A non-Sendable *product* keeps the marker enum's own error, which already names the binding's property name, the type and, in a note, the user's declaration; that one is measured to be the better of the two available diagnostics rather than assumed. Non-Sendable bindings that never enter a task are untouched, and the corpus's own non-Sendable class binding still rides through a scheduled graph. **Route 3 of the note's three (boxing a non-Sendable dependency into the child task through the vendored `WireDisconnected`) was weighed and not taken**: it is verified to compile on both toolchains and stays available, but no graph in the corpus wants it, and the direction that actually binds — a non-Sendable *product* — is one no box can reach while `ChildTaskResult` is `Copyable`. **M7c.4 was then rewritten before it started, on a survey rather than on argument.** M7c.3 bounded volume *between* graphs — only a graph whose async bindings can overlap is scheduled — and the same argument applied *within* a graph had never been made: a scheduled graph put every binding in a cell. Measured across the corpus, the region that can actually overlap (the async bindings plus what they unblock) is **four bindings out of a hundred and ten**, and nothing at all crosses the seam into it. So a graph splits into a serial prefix, the group, and a serial suffix, both serial regions staying today's linear chain — which cuts the machinery those twelve graphs would carry from ~790 lines each to ~73, and, more to the point, **empties M7c.4 for this corpus**: every instance of all six excluded constructs sits in the prefix, so narrowing the predicate from "appears in the graph" to "appears in the group region" admits every graph with no new emission. The translations are not cancelled by that, only made demand-driven — a construct reaches the region as soon as an async binding reaches it — so each was costed for when it is demanded. Two are cheaper than the plan assumed: a **collected/mapped aggregate already works** (only the `.builder` flavour was ever excluded, so an aggregate with async contributors is fine today), and a builder fold's `@resultBuilder` local function nests inside its own `add` method, verified compiling and running on both toolchains. Two need nothing at all, because `@Teardown`'s closure and the member-injection block both run after the seam where every binding is a local again — and member injection *cannot* be region-scoped in any case, since its parameters are deliberately not graph edges. The two that stay expensive, scope-entry thunks and opaque lifts, are the two already called the highest-risk seams. The cost the region change does carry is that the exclusion becomes **shape-sensitive**: an added edge can silently move a graph on or off the scheduler, which is legible only in the `_WireGraph.json` dump below. **M7c.4 then shipped on that plan (2026-09)**: `ConstructionRegions` computes the split, the two serial regions reuse the linear chain emitter, and the seam takes each cell back into a local so the suffix, the member-injection block, the teardown closure and the memberwise init all stand on locals and need no translation at all. **Fifteen graphs schedule where two did** — every graph with an independent async pair, the four wholly-sync containers byte-identical — on **44 cells across the whole corpus**, thirteen graphs at three and one at two; the golden grew by ~58 lines per newly-scheduled graph rather than ~790. Two findings: a frontier value named inside `addTask`'s escaping closure captures mutating `self`, which the design's own probe missed because its consumer was sync (fixed by copying to a local first), and the seam retired `GraphStoragePatch.builderLocal`, since the memberwise init now names a plain local whichever shape the body took. The rest of M7c keeps its trigger. **M7c.5 then discharged init-failure partial teardown (2026-09)**, the half deferred from M4. That deferral's reasoning — the already-constructed set is whatever the construction shape makes it — held, and pointed one step further than it expected: after M7c.4 the set is three things at once, a linear prefix of locals, a set of resolved cells and a linear suffix of locals, which no single inspection reaches. So it is **accumulated** instead: each `@Teardown` binding appends its action where it is built, a `do` wraps the body, and the `catch` walks the list in reverse and rethrows the original error. The same list folds into the graph's happy-path `_wireTeardown`, so the teardown call lines exist once rather than twice. Two consequences worth recording: a *scheduled* binding cannot append at its construction site (that happens inside a method of the building struct), so the drain gets a `catch` that recovers such an action from its cell — the one place the constructed set really is inspected; and the explicit `cancelAll()`-and-drain the design called for turns out to be unnecessary rather than forgotten, because putting the `catch` outside the group means `withThrowingTaskGroup` has already cancelled and awaited every child by the time it runs. The wrapper is conditional on the graph having both a `@Teardown` binding and a construction that can throw, since a `do` that cannot throw is an unreachable-`catch` warning in generated code. (Happy-path teardown walks the *static* topological order in reverse, so it's independent of the scheduler and already ships in M4.)
  - **M7d — retire the whole-scope seed-scope façade in consumers. Done, with M7b.5.** A `@Scoped(seed:)` app emits `Wire.bootstrap<S>Scope` + the `_<S>WireScope` struct + `_wireBootstrap<S>Scope`, but the generated witness never calls them — it uses the per-request `_wireEnterScope` thunk (which since M5.4.6 constructs a per-root *subset*, not the whole scope). So in a consumer the façade is emitted-but-`internal` dead code: a struct + two functions per seed scope. It's retained today because it's swift-wire's *own* testable seed-scope constructor — `Tests/IntegrationTests/BootstrapTests.swift` validates shared-singletons / per-seed-identity / construction-ordering through it, and `SeedScopeEmissionTests` golden-tests its emission. That prerequisite turned out to be unnecessary: the façade is dead code exactly when a bridging proxy enters the scope, so it is emitted only for a scope no proxy enters — swift-wire's own seed-scope tests use scopes without proxies and were untouched. 219 lines and 13 façades left the integration corpus. It landed with the `_WireExports`/surface trim rather than as a standalone change — that trim was filed here as M7a-adjacent, but with M7a deferred out of the milestone and marker retirement now coupled to reachability, its anchor is **M7b**. Invisible to users (the façade is `internal` and uncalled). Surfaced by the M5.4.6 per-root work.
  - **M7e — retire the vendored `WireDisconnected` for the stdlib `Disconnected`, when SE-0538 ships.** M5.5 Phase 5 shipped the global-`@Middleware` **front layer**: a single `GlobalMiddlewareHandler` wrapper in the generated `@main` folds the global tier around `router.handle` once — O(1) in route count, plain routes untouched, the miss endpoint covered for free (the wrapper sits above the router's 404). Its one obstacle was that the linear-sender box launders `sending` off its reader/sender on extraction, so the wrapper's terminal (`consuming`) couldn't call `router.handle` (`consuming sending`). WireMVC cleared that **now** by vendoring `WireDisconnected` — the stable-feature subset of [SE-0538 `Disconnected<Value>`](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0538-disconnected.md) (`nonisolated(unsafe)` storage; `init(_ value: consuming sending Value)` / `consuming func take() -> sending Value`) — held inside the box's `.pending` case so `withPendingContents` re-yields the reader/sender `sending`. So SE-0538 is no longer a *prerequisite*; it's a **cleanup**: when it lands in a usable toolchain (**accepted**, impl `swiftlang/swift#89597`), swap the ~20-line vendored `WireDisconnected` for the stdlib type. `WireDisconnected` stands on stable features regardless of the proposal's fate (accepted, renamed, or rejected), so this is optional polish, not a blocker. User-invisible (the type is `internal`). Detail: [M5_5_PLAN.md § Deferred](Documentation/Archive/M5_5_PLAN.md).
- **Post-1.0:** custom scopes, container composition / fine-grained overrides, `WireVapor` if a Vapor variant of task-cluster materialises, anything else that came out of real use.

The ordering assumes task-cluster's roughly-expected trajectory; it'll shift if the trajectory does.

## After M6 — the successor track

M6 closed at M6d rather than growing an **M6e**, and this section is the other half of that decision:
naming what carries the residue, so it is not left unstated the way it was while M6 was open.

**The successor is [RemainingSurfaceWork.md](Documentation/Notes/RemainingSurfaceWork.md)**, the note
that already sequenced M6's real work across four repositories. The case for M6e was that M6's stated
purpose — *unblock the last examples* — is what the remaining items serve. The case against, and the one
taken, is that the items no longer serve it: the parity, streaming and router tracks all closed, so what
is left is an upstream-blocked tier and an allocation group, neither of which is surface work and neither
of which any example is waiting on. A milestone that grows after meeting its definition is a worse record
than one that closes and hands over.

What the track holds, none of it blocking:

- **The typed duplex tier** — a route that reads its request body incrementally *and* writes its response
  incrementally. Designed and ownership-verified; blocked on
  [swiftlang/swift#91473](https://github.com/swiftlang/swift/issues/91473), the same bug under *Known
  blockers* below, so the two land together and the surface stays one idiom. Scheduled by that event
  rather than by us. `@RawRoute` serves the case meanwhile, measured end to end on both transports.
  [PendingIssues/14](PendingIssues/14-typed-tier-duplex-routes.md).
  - **Its lent-binding validation step — shipped**, and deliberately ahead of the feature it serves.
    A `.bodyStream` stream type now conforms to WireMVC's `LentBodyStream` and the generated terminal
    calls `validateRequest()` on the constructed value, one statement after building it and still inside
    the mapped region. Nothing observable changed on today's tiers — a buffered response runs its handler
    before the head, so a check deferred to the handler mapped just as well — which is exactly why it was
    worth doing now: it changes a **public** binding protocol, every lent stream anyone writes conforms to
    it, and that is a mechanical sweep before 1.0 and a break after. The duplex shape is where the
    deferred check would have truncated a response that had already claimed a status instead of mapping
    to 415. It also aligned the two request-streaming tiers, since `.readerBody` already checked up front.
- **The router path's remaining allocation group** — path-parameter values, collected positionally and
  then built into a `[String: Substring]`. The internal half (an inline buffer for the values during the
  walk) needs no decision and can land whenever. The public half is
  [PendingIssues/17](PendingIssues/17-path-parameter-shape.md): `[String: Substring]` is written into
  `HTTPServerRouteBuilder.register`'s handler shape and into `RequestBound.bind`, so replacing it is
  cheap before 1.0 and expensive after — a deadline rather than a performance item. Nothing is broken;
  the whole native path is ~0.9 µs against a bridge costing 16–47.
- **Upstreaming the generator access change** — see M6d above. The fork is pinned; only upstreaming is
  left, and it depends on review.
- **task-cluster's migration** off M3's adapter — sequenced by task-cluster.

**M7's reachability pass has since shipped**; what remains of it (M7a, M7c, M7e) waits on triggers rather than on any of these.

## Pre-1.0 polish (M6/M7 → 1.0)

Output and developer-experience items lifted out of iteration 9. None are
correctness or milestone blockers, and doing them late is deliberate:

- **`_WireGraph.json` build-time dump.** An inspectable JSON of the wired graph
  alongside `_WireGraph.swift`. Deferred because the schema wants the fuller
  model (adapter registrations, opaque identities, containers/scopes) that lands
  through M2–M7; it also pairs with M7's manifest/metadata emission, and the
  runtime `Resolver.introspect()` counterpart is already M2. M7b gave it
  something more to say: which bindings were pruned, and which root reached
  what. M7c adds the construction plan — which region of the graph the scheduler
  spans, and for a graph it declined, which construct in that region declined it.
  That last one is the only place the scheduler's decision is legible at all: it
  is a silent no-op by design, and once the exclusion is scoped to the region it
  turns on graph shape rather than on a declaration.
- **Diagnostic-quality sweep.** Re-read every error the suite fires, fix the
  worst wording, tighten fix-it text. Best done against a *stable* error surface
  — M2–M7 add new paths (adapters, `some P<…>`, manifest generation), so a sweep
  now would be partly re-done. Diagnostics stay maintained incrementally
  meanwhile (iteration 3's standard, re-checked each iteration).
- **Extension member-default access (edge case).** A binding or multibinding key
  declared as a *defaulted* member of a `public extension` — `public extension Foo {
  static let x }`, no per-member modifier — reads as `internal`, so an unconsumed key
  can falsely warn "no consumer". The explicit-member idiom (`extension Foo { public
  static let x }`) and no-modifier extensions are handled; the remaining fix is to
  inherit a defaulted member's access from the extension's explicit modifier. Benign —
  over-warns only in that rarer idiom.
- **Missing-transitive-activation hint** (deferred from 7e/7g). When a
  cross-module `@Inject` is unsatisfied and the type is declared in a
  *non-activated* transitive Wire-aware dependency, name that library and suggest
  depending on it. The base "no binding produces X" error already fires
  cross-module, so this is fix-it polish; it also needs a three-package fixture
  under `CompositionHarness/`. Slot in with a broader cross-module DX pass.
- ~~**The README's adapter-contract section is stale**~~ — **done.** Surfaced by M5.6, which swept
  `_wireRegister` out of the design notes and found the README still teaching it as the live public
  contract. The section is rewritten around the **capability axis**: an adapter annotation declares one
  edge Wire adds to the graph, with a table of the seven capabilities against the adapters that use each,
  the three attachment forms restated as attachment rather than contract, the real shipped annotation
  list, the graph-conformance surface, and a corrected public-API/SPI split. *Collation, not registration*
  is now a named subsection rather than an omission — the retired sink model is described as history,
  because the design it replaced is the one a reader would otherwise reach for. Incidental mentions fixed
  in the multi-module, concurrency, risks and roadmap sections, and `@RoutedBy` replaced with
  `@OpenAPIController` in the headline example. The `@JobHandler` / `@ScheduledTask` / `@WebSocketRoute`
  adapters, which were never built, are gone rather than restated as plans.
- ~~**The README's entry-point story**~~ — **done, leading with `@WireMVCBootstrap`.** The headline example
  bootstrapped with `Wire.hummingbird()…run()` seeded on `HBRequestSeed`, neither of which was ever built.
  It now shows the composition root and says there is no `main.swift`, with a new *The entry point* section
  carrying the six steps the generated `@main` actually emits, the `prepare()` pre-step and why it must be
  pre-graph (swift-log captures its handler at first access), `@GraphInputs`, the explicit
  `Wire.bootstrap()` + facade form for a Tier-1 or non-HTTP app, and container selection. `HBRequestSeed`
  swept to `HTTPRequest` throughout — the request *is* the seed, so the wrapper type the README invented
  never needed to exist. Leading with the generated entry point was the positioning call: it is what a new
  app writes, and the explicit form reads as the general case underneath it rather than as a fallback.

- **App-scope teardown does not run under `@WireMVCBootstrap`.** Surfaced while writing the README's
  entry-point section, by trying to state what the generated `@main` does and finding this is not among
  it. M4's teardown walk exists and every graph conforms to `Teardownable`, so there is nothing to build
  on the swift-wire side; what is missing is the *call* — and, it turns out, anything that would reach it.
  The Tier-1 path has one — WireHummingbird's `teardownService`, a `ServiceLifecycle` service prepended so
  it shuts down last — but transplanting it to `WireMVC.serve` was the first guess and does **not** work:
  it relies on the server being a group member (Hummingbird's is; the proposal's `~Copyable` handler
  cannot be), and nothing on the generated path traps a signal or otherwise stops `serve` at all, so there
  is no shutdown to hang the walk off. Written up, with the two upstream asks that would remove the need
  for bespoke machinery, in
  [PendingIssues/19](PendingIssues/19-app-scope-teardown-no-shutdown-trigger.md). **Request-scope teardown
  is unaffected** and does run, emitted per route; this is only the app scope. Not a blocker — an app that needs
  deterministic shutdown today uses the explicit form — but it is a silent gap rather than a documented
  one, which is the argument for fixing it rather than only writing it down. Lands in **wire-mvc**.

## Known blockers (1.0)

Unlike *Pre-1.0 polish* above, these are correctness or API-shape issues that must be resolved — or
consciously accepted — before a 1.0 tag.

### Property wrappers on non-copyable parameters (upstream)

**Status:** two upstream bugs plus one evolution gap; workaround shipped. **Blocks:** the final shape of
WireMVC's lent request-body stream binding (`@RequestBinding(.bodyStream)`).

**1. SILGen crash — [swiftlang/swift#81624](https://github.com/swiftlang/swift/issues/81624), open since
May 2025.** Referencing a property-wrapped non-copyable value crashes the compiler. Reported there for a
local variable; it applies to function parameters too, and still reproduces on 6.3.3 (release) and 6.4-dev
2026-08-01, so it is standing rather than a regression. The trigger is *any* mention of the value — a
`consuming` call, a `borrowing` call, or simply passing it on. An empty body compiles, which is why the
shape looks workable until something uses it. That issue documents a workaround — access the backing store,
`_x.wrappedValue` — and it does work, including for parameters.

**2. The workaround fails for `~Escapable` generic parameters —
[swiftlang/swift#91473](https://github.com/swiftlang/swift/issues/91473).** Adding `~Escapable` replaces the
crash with `copy of noncopyable typed value. This is a compiler bug. Please file a bug with a small example
of the bug`, for a move-out, a `consume`, and a `consuming` method call alike. Three ingredients are each
required, verified by removing them one at a time: the property wrapper, `~Escapable`, and a **generic**
parameter — the concrete-type version compiles. Together the two issues make a property-wrapped non-copyable
parameter unusable precisely when the wrapper is being used to guarantee that a borrowed resource cannot
outlive its scope, which is the one combination worth having it for.

**3. `inout` is not a workaround, and is not a bug.** SE-0293 (property wrappers on function and closure
parameters) defers property wrappers on `inout` parameters explicitly — "better tackled by another
proposal, due to its implementation complexity" — and gives the reason not to want it: "the ability to
mutate a wrapped parameter
would likely confuse users into thinking that the mutations they make are observable by the caller; that's
not the case." Nothing to file; it needs a proposal, and the confusion argument is a good reason not to
pursue one for this.

**The accepted weakening.** The binding wants a parameter that is `~Copyable, ~Escapable`, making "a handler
cannot keep the stream past the request" a compile error. Bug 2 makes that unreachable, so the parameter is
`~Copyable` only and the stream is consumed through `withParts { cursor in … }`. The guarantee survives
where it matters: the *cursor* — the thing that can read the socket — is a closure parameter rather than a
property-wrapped one, so it is `~Copyable, ~Escapable` and provably cannot be stashed. What is lost is the
outer one: a handler could move the stream into a class instead of calling `withParts`. That yields a spent
reader rather than a dangling one (the stream owns its reader directly — no heap box), and it cannot happen
by accident, since consuming it through `withParts` is the only path the API offers.

**Why this blocks 1.0:** the weakening is in a *public API shape*. When bug 2 is fixed the parameter gains
`~Escapable` and the documented gap disappears; shipping 1.0 first would fix the weaker guarantee in place.

**One neighbouring public-shape change did not wait, and shipped.** A lent stream now conforms to
`LentBodyStream` and is validated by the terminal immediately after construction — see *After M6* above.
It is listed here because the two are easy to conflate: both are public API shapes in the same binding,
and only *this* one is waiting on a compiler fix. The validation step was waiting on nothing, so holding
it against #91473 would have meant breaking every lent stream after 1.0 for the sake of landing two
changes together.

## Deferred features

Features the README describes but M1 deliberately didn't commit to. Each is
documented as a design space to build **when a concrete adopter use case forces
it**, not on a fixed schedule — the *decision point* in each names the trigger.
Opaque-type support (once listed here) landed in iterations 9–10; the remaining
candidates:

### Shaping the graph: config vs `@Container` vs `@Replaces` (three tools, three intents)

Three of the deferred features below (`@ConfigProperty`/config, `@Container(includes:)`,
`@Replaces`) all "make the graph different," which invites treating them as
alternatives — especially when reaching for a **testing** story. They aren't
alternatives; they sit at three points on a granularity axis and answer three
different questions, and every mature DI system ships all three (Spring
`@Profile` + `@MockBean` + `@ConfigurationProperties`; Dagger `@Module`/`@Component`
+ Hilt `@BindValue` + config):

| Tool | Granularity | Intent | Prior-art twin |
|---|---|---|---|
| **config / `@ConfigProperty`** | a *value* | 12-factor: same graph, different inputs (port, URL, pool size) | Spring `@ConfigurationProperties` / `@DynamicPropertySource` |
| **`@Container` / `@Container(includes:)`** | a *coherent, named set of bindings* | select one of several **structural** variants wholesale | Spring `@Profile` / Dagger `@Module`+`@Component` |
| **`@Replaces`** | a *single binding* | surgically swap one thing in an otherwise-intact graph | Spring `@MockBean` / Hilt `@BindValue` |

Consequences for how these get built and sequenced:

1. **Testing draws on two of them at different resolutions, and neither is "the
   testing feature."** A **value** override (an ephemeral test port, a container's
   mapped DB port) is config's job — no graph surgery (this is what the examples'
   integration tests already do via env). A **surgical** override (swap one real
   dependency for a fake, so a unit test needs no Docker) is `@Replaces`'s job. A
   coarse **whole-"test-environment"** swap (an all-in-memory stack selected
   wholesale) is a `@Container` use, à la `@ActiveProfiles("test")`. So the
   build-without-serve seam (M6a) needs *none* of this machinery — the port is a
   value; config handles it.

2. **`@Container`'s enduring home is environments and modularity, not testing.**
   Its non-test justifications: environments that differ *structurally* (dev binds
   an in-memory repo + fake mailer; prod binds real DynamoDB + SES — a coherent set
   of implementations, not values); reusable binding fragments composed into a graph
   (`@Container(includes:)` = Dagger `@Module`); and multiple entry points in one
   package each selecting a graph. **Caveat — its territory is narrower than classic
   Spring suggests:** in a config-driven (12-factor) app, config absorbs the *value*
   variation and `@Replaces` absorbs the *surgical-test* variation, leaving `@Container`
   composition only the residue — "swap a coherent set of *implementations* as a named
   unit." Real, but narrow. If no such structural-variation use case appears (the
   examples' three runtimes are separate *packages*, not containers in one package;
   task-cluster is a single deploy), container composition legitimately stays a
   documented design space indefinitely. **So don't build `@Container(includes:)` for
   testing reasons** — its trigger is a structural-environment or modularity case.

3. **The bootstrap↔container plumbing has standing regardless.** A `@WireMVCBootstrap`'s
   generated `@main` bootstraps the default graph (`Wire.bootstrap()`); associating a
   bootstrap with a chosen container ("which environment does this app boot") and
   letting an entry point run it against a selected container is a real gap — but it's
   justified by *production environment selection*, not testing, and it's the seam any
   `@Container`-based path (test or prod) would need.

Each has its own forcing case (below): config/`@ConfigProperty` is **M6c**; **`@Replaces`
shipped in M6a** (its surgical-test trigger arrived — the `SwiftHttpServerExample`
fake-dependency test); `@Container(includes:)` stays deferred behind a structural-variation
trigger that hasn't appeared. So M6a builds `@Replaces`, while the coarse container band
stays a documented design space.

### `Resolver` protocol

The README describes a public `Resolver` protocol surfacing in three places: `Provider<T>` lazily resolving into a request scope, runtime `introspect()` for ops/admin endpoints, and explicit escape-hatch resolution. None of these have a concrete iteration-1 use case, and the adapter-contract redesign (direct-injection `_wireRegister` parameters) removed adapters as a fourth user.

The protocol is therefore deferred. Iteration 1's bootstrap is a concrete struct with one stored property per binding, accessed directly. Decisions to make later:

- **Iteration 4** decides whether `Provider<T>` needs a `Resolver` protocol or works with a `@Sendable () async throws -> T` closure.
- **M2** decides whether `introspect()` lives on the bootstrap struct directly or on a public `Resolver` protocol.

If neither iteration ends up needing the protocol, it never lands. If one does, the resulting design is shaped by that real use case rather than M1-time speculation. The README's references to `Resolver` describe the *eventual* design and don't need to change at this point — they describe a target that will either be reached or revised once the use case clarifies.

### Library-binding override (`@Replaces`)

> **Shipped as part of M6a (testing) — complete.** The trigger arrived (the `SwiftHttpServerExample` fake-dependency test), and `@Replaces` shipped: the *surgical single-binding* band of [three tools, three intents](#shaping-the-graph-config-vs-container-vs-replaces-three-tools-three-intents) — the DI-idiomatic **test-double** primitive (Hilt `@BindValue`). Per spike-27, a consumer's binding **supersedes a sibling module's binding for the same key** (previously a duplicate-binding diagnostic); a `@Provides @Replaces(X.self)` in the consumer, as sketched below. Under a keyed suite it composes with `@BindType`'s per-request doubles (see M6a).

The README's "What's not in scope" section excludes fine-grained binding override across containers — when you select a `@Container`, it's the whole graph for that run, not an overlay on the default. That stance still holds, but a narrower form of override has surfaced as a concrete future use case worth capturing now: replacing a single library-provided `@Singleton` with a consumer-provided `@Provides`.

The shape we'd consider when the use case becomes concrete:

```swift
import WireSQS

@Provides
@Replaces(WireSQS.SQSClient.self)
static func customSQSClient(config: CustomConfig) -> WireSQS.SQSClient {
    SQSClient(specialConstructor: config)
}
```

Build plugin behaviour:
- Removes the library's `@Singleton SQSClient` binding from the graph.
- Substitutes the consumer's `@Provides` as the binding for that type.
- Validates: replacement type matches replaced type; consumer's target only (libraries can't replace each other's bindings); at most one `@Replaces` per replaced type per graph.

Reasons to defer until a real use case appears:

1. The all-or-nothing activation rule is the simplest committable model. `@Replaces` introduces the first crack; once we have one override mechanism, requests for others (override a `@Contributes` collection element, override an adapter annotation's effect) become harder to refuse without a principle to point at.
2. Step B's "two bindings for the same type, both activated" diagnostic already gives users a path: disambiguate with a key. Less ergonomic than `@Replaces` but functional. Whether that pain is real has to be measured by external adopters hitting it, not anticipated.
3. The exact validation rules — particularly around transitive consumers of the library binding inside the library itself — need shaping by a real example, not a hypothetical one.

Decision point: when a concrete adopter (likely the user themselves, integrating a library binding they need to swap) hits the disambiguate-with-keys workaround and finds it insufficient, that's the demand signal to build `@Replaces`. Until then, document the design space here and move on.

### Cross-file `@Container` composition (`ContainerKey`)

Iteration 2b commits to single-declaration containers — every `@Provides`/`@Singleton` belonging to a logical container lives inside that one `@Container enum { ... }` body. `extension TestContainer { @Provides ... }` is silently ignored.

The leading candidate for relaxing this when it bites in real use: an explicit-key mechanism that mirrors iteration 5's `CollectedKey<T>` / `MappedKey<K, V>` / `BuilderKey<B>` pattern.

The shape we'd consider:

```swift
struct ContainerKey: Sendable, Hashable {
    let identifier: String
}

extension ContainerKey {
    static let logging = ContainerKey(identifier: "logging")
}

@Container(key: ContainerKey.logging)
enum CoreLogging {
    @Provides static let logger = Logger(...)
}

@Container(key: ContainerKey.logging)
enum HTTPLogging {
    @Provides static let httpLogger = HTTPLogger(...)
}

// Selection at entry point uses the key, not a contributing type:
let graph = try await _LoggingWireGraph.bootstrap()
```

Build plugin behaviour:
- All `@Container`-annotated types referencing the same key contribute their bindings into one logical container, named after the key's accessor (`ContainerKey.logging` → `_LoggingWireGraph`).
- Within-key duplicate bindings (same type from two contributors) are an error, same rules as iteration 1's duplicate-binding check.
- Cross-module key sharing extends naturally once iteration 7's plugin walks dependency targets — a library publishes a `ContainerKey` and consumer-target `@Container`s reference it.

Why deferred:
1. The single-declaration model is the simplest committable shape. Whether the inability to spread containers across files is actually painful needs to be measured by adoption, not anticipated.
2. Auto-magical extension-based merging (a plain `extension TestContainer { @Provides ... }` joining the container without any annotation) was rejected outright — it would load `extension` syntax with DI semantics that surprise readers who don't know to look for them. 2b's `@Container extension` opt-in covers the same-name cross-file story without that magic; ContainerKey is specifically about cross-*type* contribution.
3. The exact validation rules around cross-module key sharing want shaping by a real adopter scenario rather than a hypothetical.

Decision point: when an adopter hits the same-name limit (wanting multiple unrelated types — not just multiple declarations of the same enum — to contribute to one logical container), that's the signal to build `ContainerKey`. Until then, document the design space here and move on.

### Container composition / hierarchies (`@Container(includes:)`)

> The *coherent-set-of-bindings* band of [three tools, three intents](#shaping-the-graph-config-vs-container-vs-replaces-three-tools-three-intents) — for **structural** environment variation and modularity, **not** testing (config eats value-variation, `@Replaces` eats surgical-test). Trigger: an app that swaps a coherent set of *implementations* as a named unit in one package. Narrow; may never land if all environment differences are config values.

A separate axis from `ContainerKey`: composition lets one container *build from* others by including their bindings, instead of multiple types *contributing to* a single container. The motivating use case is environment-specific configuration — a shared `BaseConfig` plus per-environment overlays:

```swift
@Container
enum BaseConfig {
    @Provides static let logFormat: LogFormat = .json
    @Provides static let appName: String = "MyApp"
}

@Container(includes: [BaseConfig.self])
enum DevContainer {
    @Provides static let baseURL: URL = URL(string: "https://api.dev.example.com")!
    @Provides static let dbName: String = "dev_db"
}

@Container(includes: [BaseConfig.self])
enum ProdContainer {
    @Provides static let baseURL: URL = URL(string: "https://api.example.com")!
    @Provides static let dbName: String = "prod_db"
}

// Selecting DevContainer at the entry point materialises a graph
// containing both DevContainer's bindings and BaseConfig's.
```

Without composition, `BaseConfig`'s bindings would have to be repeated inside every environment container.

Design rules to lock in (so future work doesn't accidentally exclude them):

1. **Composition is additive across all `@Container` declarations of the same logical container.** Just like bindings, `includes:` clauses accumulate. A primary `@Container(includes: [Base.self]) enum DevContainer` plus a `@Container(includes: [Logging.self]) extension DevContainer` mean DevContainer's composition is `{Base, Logging}`. No conflict between annotations is possible because composition is set-valued.

2. **No overriding** — duplicate-binding rules apply within the resolved (post-composition) graph. If `BaseConfig` and `DevContainer` both `@Provides Logger`, that's a duplicate-binding error at validation time. Users design their bindings so each binding has exactly one home in the composed graph.

3. **Relaxed validation: validate the resolved graph, not per-fragment.** A container can have unsatisfied dependencies in isolation (e.g., `BaseConfig` provides `func appLogger(level: LogLevel) -> Logger` but no `LogLevel` binding) as long as the composer fills them. Validation runs on the union of own bindings + transitive `includes:`. A container that's selected (or transitively included by something selected) and ends up with missing bindings is a build error pointing at the entry-point selection.

4. **Fragment opt-out for non-selectable containers.** A container that only makes sense composed (a "fragment" like `BaseConfig` whose standalone graph has open dependencies) needs a way to opt out of bootstrap-struct codegen. Cleanest shape: a parameter on `@Container` — `@Container(selectable: false)` — keeping fragments-are-containers under one annotation. Alternative: a separate `@PartialContainer` / `@ContainerFragment` peer annotation. Either works; the bikeshed is for the actual composition iteration.

What 2b's design preserves so this lands cleanly later:

- `containerBindings: [String: [DiscoveredBinding]]` partitions bindings by container name. Composition adds a *separate* structure (`containerComposition: [String: Set<String>]`) without touching the partition.
- Per-container graph construction in sitting 2 takes a `[DiscoveredBinding]` for each container. With composition, that vector becomes the union of own bindings plus transitive `includes:` resolution; the graph algorithm doesn't need to know.
- Codegen emits one `_<Name>WireGraph` per selectable container. Composition doesn't change the per-container output shape, only the binding set fed in.

Decision point: when an adopter hits the "I'm repeating bindings across containers" pattern (most likely the environment-config case described above), that's the signal to build composition. Until then, document the design space here and move on.

### Nested seeded-scope hierarchies (`@Scoped(within:)`)

Iteration 4a commits to a two-layer scope structure: `@Singleton` is the one always-active scope; everything else is a sibling seeded scope identified by its seed type. Two seeded scopes can't see each other's bindings — they're isolated by design. The common cases the iteration 4 audience cares about (request handling, job consumption, scheduled tasks) fit this shape: a request scope and a job scope coexist as siblings, both pulling from `@Singleton`, never reaching across.

The case worth capturing for future work: scope-within-scope composition. A session scope around a request scope — the session is established at login, lasts across many requests, and a request handler wants access to session-scoped values without re-seeding them per request. Or a per-tenant scope around a per-request scope — tenant identity comes from a token verified once, then descendants inside the request handler need it.

Today's workaround is a composite seed struct: `struct RequestSeed { let request: HTTPRequest; let session: SessionData; let tenant: TenantID }`. The framework adapter assembles the composite at request-scope entry by reading from whichever upstream context holds each piece. Works for shallow composition; gets awkward when the session/tenant values have lifetimes meaningfully longer than the request and you'd rather express the lifetime in the type system.

The shape we'd consider when the use case becomes concrete:

```swift
@Scoped(seed: SessionData.self)
struct SessionLogger {
    @Inject var seed: SessionData
    @Inject var baseLogger: Logger
}

@Scoped(seed: HTTPRequest.self, within: SessionData.self)
struct RequestLogger {
    @Inject var session: SessionData       // from outer scope
    @Inject var request: HTTPRequest       // from this scope's seed
    @Inject var sessionLogger: SessionLogger   // also from outer scope
}

// Entry point: nest via the outer scope's handle.
try await wire.withScope(seeded: session) { sessionScope in
    try await sessionScope.withSubScope(seeded: request) { requestScope in
        // RequestLogger resolves here, with session + request both visible.
    }
}
```

Design rules to lock in:

1. **`@Scoped(within:)` declares the parent statically.** The build plugin verifies that every entry point reaching a `@Scoped(within: A.self)` binding does so from inside an `A` scope. A subscope can only be entered through its declared parent's handle; entering it from singleton scope (or from an unrelated sibling) is a compile-time error.

2. **Validation generalises naturally.** A `@Scoped(seed: B.self, within: A.self)` type can `@Inject` from: `@Singleton` bindings, the A scope's bindings (including A's seed), and the B scope's bindings (including B's seed). It cannot reach sibling scopes of A.

3. **No task-local context propagation is required.** The sub-scope's handle is passed explicitly via the closure parameter (`sessionScope.withSubScope { ... }`), which carries the captured outer-scope state directly. The build plugin generates the `withSubScope` method on the outer scope's resolver type, with the inner scope's binding set + the captured outer bindings. This avoids the ambient-context fragility that `Provider<T>` already mitigates with a different mechanism.

4. **Cross-scope storage rules generalise.** A `@Scoped(seed: A.self)` value still can't be stored directly by a `@Singleton` — same diagnostic with the same `Provider<...>` fix-it. Storing a `@Scoped(within: A.self)` value inside a non-`A` scope is the obvious extension of the rule and gets the same diagnostic shape.

5. **Sibling-scope rule unchanged.** Two `@Scoped(seed: B.self, within: A.self)` and `@Scoped(seed: C.self, within: A.self)` types share an A scope but are independent within it. They can each be entered from inside A but not from inside each other.

Reasons to defer:

1. The two-layer model covers the dominant iteration 4 cases without complicating either the macro contract or the build plugin's graph routing. The cost of deferring is a small ergonomic tax on the session-around-request case (a composite seed struct), not a fundamental capability gap.
2. The static-analysis story — verifying every entry point to a sub-scope goes through its parent — is the substantive work. Designing it against a real use case (rather than a hypothetical session pattern) avoids over-engineering the graph-validation pass.
3. The closure-captured-state vs. task-local-propagation choice should be made when there's a concrete API to weigh against — the current `withSubScope { }` sketch is plausible but not the only option.

Decision point: when an adopter has a real session-scoped value (or tenant-scoped value, etc.) that they want to express as scope nesting rather than as a composite seed, that's the signal to design `@Scoped(within:)`. Until then, document the shape here and let the composite-seed workaround serve.

### Cross-scope reads from outer scope (`Provider<T>`)

The original iteration 4 plan included `Provider<T>` as the scope-crossing primitive for a `@Singleton` reading a `@Scoped`-bound value lazily. Working through the design surfaced that most cross-scope-reading cases collapse under "scope the consumer correctly":

- A controller wanting a request-scoped logger → make the controller `@Scoped(seed: HTTPRequest.self)` (or whatever seed the adapter publishes); the logger injects naturally.
- A long-lived service wanting per-request tracing → wrap with a `@Scoped(seed: ...)` decorator that composes the singleton service with the request-scoped trace; consumers inject the wrapper.
- A controller-shaped type that needs request-scoped values → use `@Scoped`-ing on the controller itself. (Written when this was expected of the Tier-1 adapters; it is **WireMVC** that does it, since M5.4 — an app-scoped proxy contributor whose generated registration embeds per-request scope entry. `wire-hummingbird` collates app-scoped controllers only, there is no `WireVapor`, and a Hummingbird-shaped controller reaches per-request data through Hummingbird's own context. See [WireMVCAbstraction.md](Documentation/Notes/WireMVCAbstraction.md), *Where the tiers stop*.)

The residual cases that genuinely need cross-scope ambient reads — singleton-shaped service reaching down into a request scope it didn't establish — are architecturally inverted and uncommon enough that designing the primitive speculatively risks shipping the wrong shape. Particularly around the captured-scope vs dynamic-lookup decision, the ergonomics of "this call can fail at runtime if no scope is active," and the error-message specificity (naming the expected seed type concretely).

Iteration 4b ships `Lazy<T>` for the deferred-construction motivation (which is often conflated with `Provider<T>` in JVM-DI usage) — that's a separate primitive (just a regular Swift type Wire happens to define) that doesn't have the cross-scope-crossing concerns.

The shape we'd consider when the use case becomes concrete:

```swift
public struct Provider<T: Sendable>: Sendable {
    public func callAsFunction() async throws -> T  // throws if no active scope
}
```

Design notes if `Provider<T>` is reopened:

1. **Throws explicitly.** `callAsFunction()` is `async throws`. Two failure modes: no active scope (`WireScopeError.noActiveScope(seedType: "HTTPRequest")`) and any `async throws` propagated from `T`'s init. The first error names the expected seed type concretely.
2. **Visible code-smell beacon.** Searching for `Provider<...>` in `@Inject` lists shows every place a long-lived type reaches across scope boundaries — useful in code review without needing additional tooling.
3. **Captured-scope vs dynamic-lookup** is the open design question for the API shape; resolve against a real adopter's pattern.
4. **Distinct from `Lazy<T>`.** Lazy is a regular Swift type the user opts into per binding for deferred-and-cached construction (no framework recognition); Provider would be a framework-recognised cross-scope per-call primitive. They serve different needs and ship as separate types if both ever land.

Decision point: when an external adopter has a concrete cross-scope-read pattern that genuinely resists the wrapper-at-appropriate-scope solution, that's the signal to design `Provider<T>` against their pattern. The error-message specificity bar from iteration 3 applies at runtime: the runtime error names the seed and suggests the wrapper-pattern alternative before naming Provider as the resort.

## WireConfiguration (scheduled as M6c)

> **Status: built** — see the M6c entry in Milestones above for what shipped and what did not. The design below is the record it was built from; three things diverged, all noted in that entry: the type→method dispatch moved into the adapter's constrained overloads rather than a table in swift-wire; the annotation shipped as `@ConfigProperty` rather than `@Configuration`; and the provider selector is identified by **argument label**, not by leading position as *Disambiguating the underlying ConfigReader* specifies. The milestone-ordering speculation in this section is historical — it predates M2–M5 and its "suggested reorder" did not happen (WireHummingbird shipped as M2, WireOpenAPI as M3). The **design** below (desugaring model, recognized sites, key-based dedup, `ConfigReader`-method dispatch, validation) is current and is what M6c builds, with two sections revised after M6b: *Disambiguating the underlying ConfigReader* replaces a composed-annotation design that turned out not to compile, and *Validation* now leads with the graph-input idiom `@GraphInputs` made available. References to "iteration 3/8" are M1-internal iteration numbers.

The README names `WireHummingbird` as M2 — the first framework adapter, the integration target task-cluster is built around. Working through the M1 design surface (specifically iteration 8's adapter-annotation contract) surfaced a smaller adapter that's a better first real-world test: **WireConfiguration**, a swift-configuration adapter exposing `@ConfigProperty(forKey:default:)`. This section captures the design so the eventual milestone-ordering decision has the work to point at.

### Why ahead of WireHummingbird

1. **Smaller adapter surface, simpler first contract validation.** Hummingbird is the canonical "framework adapter" — type-level + member-level annotations (`@Controller`, `@Get`, `@Post`, `@RoutedBy`) with deeper integration patterns. swift-configuration is comparatively narrow (read a value, pass it through). Validating M1's iteration-8 adapter contract on a smaller surface first surfaces issues before they're tangled up with framework complexity. Same "highest-risk integration first" philosophy the M1 plan applies at the iteration level, applied at the milestone level.
2. **Universal applicability.** Configuration is a fundamental need in any real app; configuration wiring through DI is high-leverage. WireHummingbird benefits HTTP apps; WireConfiguration benefits everything.
3. **Concrete migration target in task-cluster.** The current `let port = config.int(forKey: "HTTP_PORT", default: 8080)` line in `TaskCluster.swift` becomes `@ConfigProperty(forKey: "HTTP_PORT", default: 8080) port: Int` at the @Inject site. Another step on the incremental task-cluster migration path the M1 plan calls out.

### Desugaring model

`@ConfigProperty` is **sugar over the existing graph machinery** — not a new adapter-contract form. The build plugin sees the annotation and synthesizes a binding equivalent to:

```swift
static func _wire_<configKey>(config: ConfigReader) -> <Type> {
    config.<typedMethod>(forKey: "<configKey>", default: <default>)
}
```

The original consumer parameter/property resolves to that synthesized binding via the graph's normal mechanics. **No new adapter form, no contract extension.** The README's three adapter forms (type-level, type-level-with-members, member-level) stay intact — `@ConfigProperty` is purely a build-plugin source transformation that produces existing graph constructs.

### Recognized sites

`@ConfigProperty` is recognized at three sites, all desugaring identically. The property form takes `var`
**or `let`**: the annotation ships as two declarations sharing one name — a property wrapper, the only
mechanism that can attach to a *parameter*, and a peer macro, the only one that can attach to a `let`
*property* (`property wrapper can only be applied to a 'var'`). Swift resolves each use site to whichever
applies, and Wire reads the attribute syntactically before expansion, so the two are indistinguishable to
it and deduplicate to the same binding:

```swift
// 1. @Inject property site (most common — Controller-style consumers)
@Singleton
struct TaskController {
    @Inject @ConfigProperty(forKey: "REQUEST_TIMEOUT", default: 30) var timeout: Int
    @Inject var repository: any TaskRepository
}

// 2. @Inject init parameter site
@Singleton
struct TaskController {
    @Inject
    init(
        @ConfigProperty(forKey: "REQUEST_TIMEOUT", default: 30) timeout: Int,
        repository: any TaskRepository
    ) { ... }
}

// 3. @Provides func parameter site (multi-field config aggregation)
@Provides
static func appConfig(
    @ConfigProperty(forKey: "HTTP_PORT", default: 8080) port: Int,
    @ConfigProperty(forKey: "HTTP_HOST", default: "0.0.0.0") host: String
) -> ApplicationConfiguration {
    .init(address: .hostname(host, port: port))
}
```

A standalone `@Provides @ConfigProperty static let httpPort: Int` form was considered but **deliberately not supported** — Swift's `let`-must-be-initialised rule plus the absence of a "synthesise initializer expression for a stored let" macro role means there's no clean way to ship that syntax without sentinel-value workarounds. The three @Inject/@Provides parameter sites cover the realistic consumer patterns; the standalone form is mostly redundant once those work. Worth revisiting if Swift's macro system grows the capability later.

### Synthesized-binding identity (key-based dedup)

Two `@ConfigProperty` annotations of the same parameter type with the *same* config key resolve to the *same* synthesized binding (natural deduplication). Two with *different* config keys resolve to *different* synthesized bindings — keyed by the config key string (e.g., `BindingKey<Int>(identifier: "HTTP_PORT")` and `BindingKey<Int>(identifier: "TIMEOUT")` are distinct).

This integrates cleanly with iteration 3's explicit-key disambiguation work — `@ConfigProperty` essentially uses iteration 3's machinery internally, just with auto-derived keys instead of user-written ones.

### Disambiguating the underlying ConfigReader

**The name.** This shipped as `@ConfigProperty`, not the `@Configuration` written throughout this section —
because `@Configuration` collides with the module it adapts. swift-configuration's library product is named
`Configuration`, so any file importing it to name `ConfigReader` (the composition root of every app, at
least) cannot use the annotation: `error: cannot use module 'Configuration' as a type`. The alternative was
splitting such files so none both imports the module and annotates a parameter — ceremony imposed on every
consumer. `@ConfigProperty` is [MicroProfile Config's](https://download.eclipse.org/microprofile/microprofile-config-2.0/microprofile-config-spec-2.0.html)
name for the same thing in the same shape (a qualifier beside the inject marker, naming a key and a
default), and that spec splits the same three ways this one does. The other widely-known spellings do not
survive Swift: Spring's and Micronaut's `@Value` is the generic parameter name in the wrapper itself, and
Micronaut's `@Property` collides with the language's vocabulary; `@ConfigValue` and `@ConfigKey` are types
swift-configuration already declares. The argument labels stay `forKey:`/`default:` rather than
MicroProfile's `name:`/`defaultValue:`, matching swift-configuration's own reader methods.

**The reader selector is an argument of `@ConfigProperty`\'s own.** *(Built by **label** — `reader:` —
not by leading position as written below; see the M6c entry for why position cannot work in general. The
rest of this section stands.)* Two spellings:

```swift
@Provides
static func appConfig(
    // Implicit — reads as `@ConfigProperty(ConfigReader.self, …)`: the unkeyed reader, resolved by type.
    @ConfigProperty(forKey: "HTTP_PORT", default: 8080) port: Int,
    // Explicit — names which reader binding to resolve, for an app that binds more than one.
    // (Built as `reader: ConfigKeys.testReader`.)
    @ConfigProperty(ConfigKeys.testReader, forKey: "TIMEOUT", default: 30) timeout: Int
) -> ApplicationConfiguration { ... }
```

A single defaulted parameter on each `init` rather than the two overloads this design assumed — `reader: BindingKey<ConfigReader>? = nil` admits both spellings from one initialiser, so the selector costs no overloads at all (18 initialisers and 7 macro declarations were touched, none added). No common parameter type is needed to admit both — which sidesteps the metatype-vs-key-reference mixing wrinkle [`ScopeAndKeyModelEvolution.md`](Documentation/Notes/ScopeAndKeyModelEvolution.md) lists as open. The metatype form is **not** writable syntax: it is exactly redundant with the bare form, and exists here only to explain what bare means. The selector is typed `BindingKey<ConfigReader>`, so naming a key of the wrong type fails at the annotation.

**This replaces an earlier design that cannot compile.** It had `@ConfigProperty` take no selector — on the grounds that doing so would special-case it when iteration 3 was already shipping general explicit-key disambiguation — and composed the general annotation instead: `@Inject(ConfigReader.testKey) @ConfigProperty(forKey:default:) port: Int`. That is wrong twice over. `@Inject` is a peer macro and cannot attach to a parameter at all, which is why `@Bind` exists. And `@Bind` cannot express it either: **property-wrapper composition rewrites the outer wrapper\'s generic parameter to the inner wrapper\'s type**, so `@Bind(ConfigReader.testKey) @ConfigProperty(…) port: Int` asks for a `BindingKey<Configuration<Int>>` and is rejected —

```
error: cannot convert value of type 'BindingKey<ConfigReader>'
       to expected argument type 'BindingKey<Configuration<Int>>'
```

— measured, not reasoned about. There was no general mechanism at parameter sites to defer to; the old rationale assumed one.

**The generalisable rule, worth stating once:** when an annotation selects a dependency of a *different type* than the site it is attached to, the selector belongs to that annotation — a composed `@Bind` structurally cannot express it, since its `Value` is pinned to the site\'s own wrapped type. Any future annotation with a hidden collaborator (a decoder, a clock, a transport) meets the same wall. It also lands where the adapter-dependency family rule in `ScopeAndKeyModelEvolution.md` already points — *spell the key bare where the type is available at the site; bundle it where it isn\'t*. The parameter\'s own type is at the site; the reader\'s is not.

### Type → ConfigReader-method dispatch

`@ConfigProperty` calls the typed method matching the annotated parameter's type — `Int` → `config.int(forKey:default:)`, `String` → `config.string(…)`. The mapping is hard-coded; swift-configuration's surface is small and closed enough that this is the right shape, not a stopgap. Read off the shipped reader rather than guessed, the sync surface is `bool`, `int`, `double`, `string`, `bytes` **and their array forms** (`intArray`, `stringArray`, `boolArray`, `doubleArray`, `byteChunkArray`) — so arrays come free on day one rather than as a later extension. `Codable`-conforming structured config stays a later hook.

Three properties of that surface the earlier sketch did not account for, each a small decision to settle when M6c starts:

- **Required vs defaulted.** Every method has a `requiredInt`/`requiredString`/… counterpart that throws when the key is absent. `@ConfigProperty(forKey:)` with no `default:` should map to those, giving a missing required value a clean startup failure instead of a silent fallback. The synthesized binding is then `throws`, which the graph already supports.
- **Secrets.** Every method takes `isSecret:`, which governs redaction in logging and debugging. Redaction is a property of the *value*, and the annotation is the only place that knows — so `@ConfigProperty(forKey:default:isSecret:)` is where it belongs. Worth shipping with the first cut given M6b just made per-request logging idiomatic.
- **Sync vs async.** There is a parallel `fetchInt`/`fetchString`/… family that is `async`, for providers doing I/O. Wire supports async providers, so either desugaring is expressible. Start sync-only; the async form is additive.

### Validation

Synthesized binding's `ConfigReader` dep resolves against the active graph like any other dep. Missing `ConfigReader` binding → ordinary missing-binding diagnostic at the synthesized site, with a fix-it naming both idioms: **pass one in as a graph input** (`@GraphInputs struct AppInputs { let config: ConfigReader }`, supplied by `Wire.bootstrap(inputs:)` — or by `@WireMVCBootstrap`'s `prepare()` pre-step, which is where an app reads configuration and bootstraps its logging *before* the graph exists), or bind one in-graph with `@Provides let configReader = ConfigReader(...)` at module scope. The input form is the one to lead with: reading configuration is pre-graph work in any app that also bootstraps swift-log, since swift-log captures its default handler at first access. See M6b.

### Suggested milestone reorder

- **M2 — WireConfiguration**: smaller surface, validates the iteration-8 adapter contract on a focused adapter, gives task-cluster's port/timeout wiring an obvious migration target.
- **M3 — WireHummingbird**: framework adapter with type-level + member-level annotations. Bigger integration; lands once the contract has been shaken out by M2.
- WireSQS, WireOpenAPI, etc. shift one slot accordingly.

The README still names WireHummingbird as M2; that's editing work for after M1 ships, not now. This section captures the case so the decision is informed.

## The opaque `BuilderKey` fold (superseded — no scheduled consumer)

The parameterized-opaque `BuilderKey` (`some P<A,B,C>` lifting + the
`.opaque(P<…>.self)` middleware fold) was originally slated for **M2 / WireHummingbird**,
where its anticipated consumer (`router.addMiddleware`) would get a bootstrap-driven
form. That consumer never materialised: M2 shipped with middleware left a framework
concern, M5.3 (spike-15) found the opaque `Middleware` fold **isn't expressible and
isn't needed**, and M5.5's global-middleware front layer uses the concrete
`.liftsPeersToProxy` proxy instead. So this fold now has **no scheduled consumer** —
treat it as unbuilt and likely permanently unneeded, not pending. The design and the
deferred *conformance-derived aliasing* thread remain documented in
[OpaqueTypesSupport.md](Documentation/Notes/OpaqueTypesSupport.md) for reference.
