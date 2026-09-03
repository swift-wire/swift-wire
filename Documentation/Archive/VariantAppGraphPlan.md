# Variant app graph — `@BindType` as a true complete-replacement (plan)

> ✅ **COMPLETE** — shipped as part of milestone **M6a (testing)**: the variant app graph drops the mocked
> eager `@Singleton(as:)` bindings (Docker-free mocked suites) and handles the generic seed-scoped subject.
> Retained as implementation history; the "for review before building" framing and open items below are
> historical. See [../ROADMAP.md](../../ROADMAP.md) and [known gaps](../Notes/KnownGaps.md).

> **Status:** design record + phased plan for making a `TestingKey` variant a **divergent app graph**,
> so `@BindType` alone stops an eager `@Singleton` from constructing under the mock (the wire-mvc-examples
> CouchDB overlay leak), and so a **generic seed-scoped subject** is handled end-to-end. For review before
> building. Builds on #223 (`@Replaces` + `@BindType` composition) and the H2.2a variant-proxy facades.
> Same discipline as [M6a_TestingPlan.md](M6a_TestingPlan.md): each phase runs end-to-end with a gate.
>
> Design records this refines: [Notes/TestingModel.md](../Notes/TestingModel.md) (line 79 — *"the test
> target regenerates its own graph … the production graph is untouched"*) and
> [Notes/WireMVCTesting.md](../Notes/WireMVCTesting.md).

## Grounding — how the variant reuses `_WireGraph` today (post-#223), and what it can't fix

A `TestingKey` variant today emits **only** per-seed artifacts and reuses the production app graph:

- `buildTestingVariants` (`WireGen/TestingVariants.swift`) derives from #223's `@Replaces`-resolved set and
  emits, per key: the `_<Key>Doubles` struct, the doubles-threaded **seed scopes** (`SeedScopeEmission[]`,
  built by `orchestrateVariantScope` with **`parentGraphType: "_WireGraph"`**), and the **contributor-proxy
  facades** (`bootstrap<Variant>_<Subject>Contributor(wireGraph: _WireGraph<…>)`).
- There is exactly **one** app bootstrap — `Wire.bootstrap()` / `_wireBootstrap()`. The variant seed and
  proxy facades take the **production** `_WireGraph`. A test path must call `Wire.bootstrap()` to obtain it.

A `@BindType`'d binding lives in that production graph. For an opaque `@Singleton(as: T)` it is a stored
field `someT: T0`, a construction `let someT = RealT()` in `_wireBootstrap`, and it contributes an **opaque
axis** `T<index>` to `_WireGraph`'s generic parameters (`appendStruct`:
`opaqueBindings = order.filter { $0.boundType.hasPrefix("some ") }`, each → `T<i>: <constraint>`).

**Two problems this reuse cannot solve:**

1. **B — the eager-singleton leak.** `@BindType` rewrites only the *seed-scope consumer* to the
   doubles-sourced mock (#223). The `@BindType`'d **base** binding stays in the shared `_wireBootstrap`.
   For a lazy `@Provides -> T` that is harmless. For an eager `@Singleton(as: T)`, `Wire.bootstrap()`
   runs its `init` under the mocked suite (verified with the STEP-0 fixture `EagerSingletonBindTypeExample`:
   `let someEagerWidget = RealEagerWidget()` runs in the sole `_wireBootstrap`). The keyless path is
   shared, so the binding can't just be dropped from `_wireBootstrap` — that would break the real suite.
2. **Bug 2 — the generic seed-scoped subject.** A controller generic over its opaque backend
   (`MeController<Repository, Manager>`, the idiomatic opaque-lift) under a `TestingKey` mis-generates its
   wire-mvc harness (details in *The generic subject* below). Untested and unexercised in wire-mvc today.

Both share a root: the variant is not its own graph. TestingModel.md's stated model is that the *test
target regenerates its own graph* — the `_WireGraph`-reuse is the shortcut that leaks and that never
forces the generic-subject path to be spelled correctly.

## The design — a divergent variant app graph

Emit, per `TestingKey`, a **variant app graph** `_<Variant>WireGraph` + `_wireBootstrap<Variant>()` /
`Wire.bootstrap<Variant>()` that is the production app graph **minus the bindings the variant reconstructs
in its seed scopes**. The variant seed + proxy facades take `_<Variant>WireGraph`. The keyless/default path
keeps `Wire.bootstrap()` + `_WireGraph` unchanged — real singletons intact for integration tests.

A variant app graph is structurally a **container-shaped graph**: containers already emit
`Wire.bootstrap<Container>()` / `_<Container>WireGraph` via `appendStruct(structName:, bootstrapFunction:,
bootstrapMethod:, topologicalOrder:, seedScopes:, …)`, and register `parentGraphBindings["_<Container>
WireGraph"]`. The variant graph reuses that machinery with a filtered topological order.

### What the variant graph drops (the order rule)

```
variantOrder = production defaultOrder
             − the @BindType'd substituted identities            (the mocked leaves)
             − the @Scopable cascade liftedIdentities            (their app consumers, reconstructed per entry)
             − the contributor proxies for variant subjects      (replaced by the variant proxies)
```

aggregated across the key's seed scopes. The dropped `some T` bindings drop their opaque axes too, so the
variant graph's generics are the production axes **minus the dropped ones, re-indexed**.

**No orphans, by construction.** The dropped mocked-leaf's app consumers are exactly the lifted set (also
dropped). Any *remaining* app binding that consumed a dropped binding would be an unmarked-`@Scopable`-hop
— already a Phase-2 build error (`… reaches the scope root through singleton 'X'. Add @Scopable(X.self)`),
so a *valid* variant has none. This is the STEP-0 "no legitimate variant consumer" guarantee, now formal.

### Re-pointing (the coupled change)

- `orchestrateVariantScope`: `parentGraphType` → `"_<Variant>WireGraph"`; the borrow set
  `syntheticSingletonBorrowBindings(from: variantAppSingletons, inWireGraphOfType: "_<Variant>WireGraph")`.
- `renderContributorProxyFacade`: `parentGraphTypeReference` → the variant graph's opaque-erased reference.
- `renderWireGraph`: a new input `variantAppOrders: [String: [DiscoveredBinding]]`; emit each via
  `appendStruct("_<Variant>WireGraph", "_wireBootstrap<Variant>", "bootstrap<Variant>", …)`; add to
  `parentGraphBindings`. `seedScopeLift` then computes the (fewer-axis) opaque-lift from the variant ref
  automatically.

### The contributor-proxy / route-collation interaction (the crux)

A production contributor proxy's scope-entry thunk **borrows the real binding it wraps** (`Subject(dep:
_wireGraph.someT)`). On the variant graph — `someT` dropped — that borrow references a missing field. So
the variant graph must **not host the production proxies for variant subjects**; the keyed path already
builds **variant proxies** (via `bootstrap<Variant>_<Subject>Contributor`) whose thunks borrow only the
variant graph's surviving bindings. Consequence:

- The variant graph omits the contributor proxies (they are keyless route-contributor artifacts).
- The keyed harness must assemble its router from the **variant proxies**, not from `WireMVC.apply(graph)`'s
  production route-contributor collation.

**O1 — RESOLVED (wire-mvc trace).** Keyed routes register **only** via `WireMVC.apply(graph)` →
`graph.routeContributors`, which holds **production proxy instances**; the route witnesses (paths/methods +
the dispatch closure) live only on the production proxy type (`extension _WireRouteContributor_<Subject>:
RouteContributor`). The H2.2b runtime-branch closure depends on the production proxy both as its enclosing
`self` (the keyless `else`-branch) and as the collated instance. So a production-proxy-less variant graph
**cannot** reuse that model — `apply(variantGraph)` would register nothing for variant subjects (silent
404s). **Resolution:** the keyed path becomes a **separate keyed registration** — the variant proxy
`@Contributes(to: WireMVCKeys.routeContributors)` (today `contributions: []`, `TestingVariantContributorProxies.swift:112`)
so `apply(variantGraph)` collates it, and wire-mvc emits a **keyed `RouteContributor` witness** on the
variant proxy type whose prologue is the keyed-only form (header → `TestBindStore` → `self._wireEnterScope(request, doubles)`,
explicit 500 on miss) — **no** production `else`-branch, **no** `@TaskLocal`. This **retires** H2.2b's
runtime-branch + `@TaskLocal`/box/`.withValue` keyed machinery (and inherently the keyless↔keyed box-leak,
since the two paths now serve separate graphs). Per-request doubles still ride the header + `TestBindStore`.

**The load-bearing collation (the go/no-go).** The production `routeContributors` is fanned-in by
`synthesizeAggregates` from singleton bindings that `@Contributes`; variant proxies are façade-built values,
not fan-in bindings. Two ways to collate them: (a) synthesize a variant singleton partition where the variant
proxies *are* contributing bindings (principled but ≈ rebuilding a variant singleton graph); (b) hand-emit
the `routeContributors` stored property mixing borrowed production-proxy values + variant-façade calls
(smaller, a one-off emitter). **Spike this first** (path b): materialize `_<Variant>WireGraph.swift`, confirm
`routeContributors` lists variant proxies for touched subjects + production proxies for the rest, and that
`Wire.bootstrap<Variant>()` type-checks (needs the variant proxy's `RouteContributor` witness — so the
swift-wire `@Contributes` change and the wire-mvc witness land together). If (b) can't cleanly collate the
non-contributing façade values, (a) is forced and the effort moves medium→large.

## The generic subject (bug 2) — entangled with the variant graph

A generic seed-scoped subject `MeController<Repository, Manager>` under `@BindType(Repository, Mock)`:
`Repository` is mocked (lifted → `doubles.repository`, concrete `Mock`), `Manager` stays an opaque backend
borrowed from the variant graph. The variant subject is `MeController<Mock, some SomeManager>` — a
**partial concretization**. swift-wire's facade side already handles this: `variantContributorProxy` carries
the subject's generics through, and `variantProxyTypeReference` erases to `…<some Mock-constraint, some
SomeManager>` (validated by the H2.2a `GenericProxyContributor` shape-2 gate). Two **wire-mvc** defects
surface — independent of B, but the variant-graph work is the first to exercise them:

- **(a) `@TaskLocal` drops the generic clause.** `KeyedHarnessGeneration` spells the box type
  `_<Variant>_WireRouteContributor_<Subject>` (bare, from `variantProxyTypeName`) while the facade returns
  the opaque-erased generic form `…<some C1, some C2>`. The box is under-applied and cannot hold the value.
  (Internal tell: `controller.selfType` — used for the dispatch tuple — *does* carry `<…>`; the two
  spellings can't both be right.) Fix: the box type must be the facade's return-type spelling.
- **(b) Doubles field order mismatch.** WireGen orders `_<Key>Doubles` fields + memberwise `init`
  **alphabetically** (`accumulation.doublesFields.values.sorted { $0.name < $1.name }`); wire-mvc builds the
  `_<Key>Doubles(...)` call in **`@BindType` source order**. Swift's memberwise init is positional, so a
  divergent order binds the wrong mock or fails to compile. Masked today only because the shipping fixture's
  two fields (`noteBackend`, `prefs…`) are already alphabetical. Fix: one canonical order shared by both —
  simplest is wire-mvc emitting `withBindValues`/the `_<Key>Doubles(...)` call in the **same sorted order**
  WireGen uses (name the ordering in the swift-wire↔wire-mvc contract so it can't drift again).

**Design decision:** fix bug 2 in the same effort. (a) is pure wire-mvc (spell the box type from the
facade's generic return). (b) is a contract nail (shared field order). Both are exercised by the phase-3
gate — the first generic keyed subject in the suite.

## Phased implementation (each phase runs end-to-end with a gate)

### Phase 1 — swift-wire variant app graph + re-point **seed** facades
- Compute `variantOrder` (the drop rule, seed-facade scope: `@BindType`'d + `@Scopable`-lifted identities);
  emit `_<Variant>WireGraph` + `Wire.bootstrap<Variant>()` via `appendStruct`; thread through
  `renderWireGraph` (`variantAppOrders`, `parentGraphBindings`, `seedScopeMap(forParent:)`).
- Re-point `orchestrateVariantScope` (`parentGraphType`, borrows) to the variant graph.
- Migrate the seed-facade gates onto `Wire.bootstrap<Variant>()`: `BindTypeDoubles`, `ScopableCascade`,
  `ReplacesBindTypeCompose` (its **variant** scope only; its default scope keeps `Wire.bootstrap()`, so it
  now threads **both** graphs), plus the STEP-0 `EagerSingletonBindType` fixture.
- **Gate:** eager `@Singleton(as: T)` — variant path (`Wire.bootstrap<Variant>()` + variant seed facade):
  `RealT.init` counter stays **0**, consumer gets the mock; keyless path (`Wire.bootstrap()` + production
  seed facade): counter **1**, consumer gets real. `@Replaces`+`@BindType` (#223) still composes. swift-wire
  `swift test` green; SwiftLint 0.

### Phase 2 — re-point **proxy** facades onto the variant graph — **DONE**
- `renderContributorProxyFacade` takes the variant graph reference; the variant graph omits contributor
  proxies for variant subjects (the drop rule already filtered `bridgeProxyIdentities`; the phase-1
  `contributorFacades.isEmpty` guard was lifted, keeping only the `dropsOpaqueAxis` guard for phase 3). The
  facade already borrows via the `_wireGraph` *parameter instance*, so re-typing that parameter is the whole
  mechanism (`TestingVariants.buildVariant`: compute `appGraphReference` before the facades, pass it as
  `facadeParentReference`).
- Migrated the proxy-facade gates: `BindTypeProxyContributor`, `FactoryProxyContributor`,
  `BorrowingProxyContributor` → build proxies from `Wire.bootstrap<Variant>()`. `GenericProxyContributor`
  stays on `Wire.bootstrap()` — its subject drops an *opaque* axis (`dropsOpaqueAxis` fallback), which is
  phase 3.
- **Gate (met):** each proxy facade builds from the variant graph; `BindTypeProxyContributor` gained a
  leak-freedom test — the `@Scopable`-lifted eager `@Singleton` (`ProxyAccountController`) is dropped, so
  `Wire.bootstrap<Variant>()` runs `RealProxyRepository.init` **0** times vs **1** for keyless; teardown +
  pruning intact (the H2.2a properties). swift-wire `swift test` green (710); SwiftLint 0.

> **O1 scope refinement (found while building phase 2).** The `routeContributors` fan-in **aggregate** is a
> *wire-mvc* concept: swift-wire's own in-repo `@RouteController` adapter uses `.liftsPeersToProxy`, so its
> bridging proxies carry `contributions: []` and there is **no aggregate** in swift-wire's suite to collate.
> So the swift-wire phase-2 work is purely the facade/graph re-pointing above — dropping the (non-contributing)
> production proxies strands nothing. The load-bearing collation (path a/b — mixing borrowed production-proxy
> values with variant-façade calls into `[any RouteContributor]`) only arises once wire-mvc's
> `.contributesProxy(to: WireMVCKeys.routeContributors)` proxies + keyed `RouteContributor` witness are in play
> — it lands with **phase 4** (the wire-mvc keyed registration), not here.

### Phase 3 — the generic subject / opaque-axis drop — **swift-wire DONE**
The `dropsOpaqueAxis` guard is lifted: every variant now emits its app graph, dropping an opaque
(`some P`) mocked binding and **re-indexing** its remaining opaque axes (`appendStruct` +
`openGraphTypeReference` derive axes from the filtered order, so this is automatic).
- **A real swift-wire fix was needed** (the plan's "likely no code change" was wrong): a lifted opaque
  mocked binding is `doubles.<field>`-sourced (a concrete `Mock`) and has **no parent axis to thread as a
  `T0`**, so the seed scope can't spell it `some P` (an illegal stored-property type). Fix in
  `SeedScopeStructEmission.liftedFieldParameters`: map the lifted opaque slot → its concrete mock type in the
  `wireGraphFieldType` spelling map, so both the lifted binding's field and any generic consumer's parameter
  spell concretely (`GenSeedConsumer<MockGenBackend>`, `let someGenBackend: MockGenBackend`). The map is
  threaded via a new `SeedScopeEmission.doublesFields`. The binding keeps its opaque *identity* (resolution
  matches the generic param against `some P` — concretizing the identity breaks it with "no binding produces
  R"); only the *spelling* concretizes. Adds no generic-clause parameter.
- Migrated `GenericProxyContributor` onto `Wire.bootstrap<Variant>()` (shape 1 full concretization
  `Controller<Mock>` + shape 2 partial `Controller<Mock, T0>`); added `GenericSeedFacadeBindType` (a generic
  `@Scoped(seed:)` subject over an opaque `@BindType`'d backend, seed-façade path) to lock the non-proxy
  entry. swift-wire `swift test` green (711); SwiftLint 0.
- **wire-mvc (separate repo, lands with phase 4):** fix (a) — the `@TaskLocal` box type spelled from the
  facade's generic return; (b) — emit the `_<Key>Doubles(...)` call in the canonical (WireGen, sorted-by-name)
  field order. The gate — a wire-mvc keyed suite over a generic controller with a second non-mocked backend
  sorting *before* the mocked one — is a wire-mvc gate.

### Phase 4 — the wire-mvc contract (keyed factory → `Wire.bootstrap<Variant>()`)

**Prerequisite — swift-wire aggregate filter (DONE, the O1 collation that phase 2 mis-scoped).** Building the
variant graph against wire-mvc's *real* `routeContributors` aggregate revealed the go/no-go: the variant graph
drops the scoped-subject proxies, but the inherited aggregate binding still listed them, so its emitted
`[…] as [any RouteContributor]` fold referenced dropped locals (they resolve to the proxy *type* — "cannot
convert `_WireRouteContributor_NotesController.Type` to `any RouteContributor`"). swift-wire's own
`.liftsPeersToProxy` fixtures (`contributions: []`) have no aggregate, so the suite never caught this — the gap
that let phase 2 conclude "no swift-wire change." Fix: `droppingRemovedAggregateContributors` (TestingGraph.swift)
rewrites each surviving `.aggregate` in the variant order to shed contributors whose identity was dropped, so
`routeContributors` keeps only the **non-scoped** controllers (e.g. `HelloController`). The scoped set is
registered by wire-mvc from the variant proxies (path b / hand-assembly — confirmed compiling end-to-end
against wire-mvc). Unit-tested in `TestingGraphTests` (swift-wire has no `.contributesProxy` integration
fixture; wire-mvc is the integration proof).

**Prerequisite 2 — swift-wire variant graph conformance (DONE, found during wire-mvc integration).**
`WireMVC.apply(graph)` requires the graph conform to `WireMVCComposable` (surfacing `routeContributors` +
`services`). swift-wire emitted the adapter-declared graph conformances (`appendGraphConformances`) only on the
default `_WireGraph`, so `apply(variantGraph)` failed to compile. Fix: `appendAllGraphConformances` also emits
`extension _<Variant>WireGraph: <Protocol>` for each variant graph — the aggregate field name is unchanged
(only its dropped contributors are shed), so the member mapping is identical apart from the struct name.

**Remaining (wire-mvc repo — DONE + validated locally, awaiting the prerequisite-2 merge + pin bump):**
- The keyed `.wiremvc(_:)` factory's `let graph = try await Wire.bootstrap()` (from `bootstrapBuildLines`,
  keyed call site only) becomes `Wire.bootstrap<Variant>()`, and `graph` is now `_<Variant>WireGraph`; the
  variant proxy facades take it. Keyless `.wiremvc()` + `@main` keep `Wire.bootstrap()`.
- O1 route registration (path b): hand-assemble the scoped routes from the variant proxies. Emit a keyed
  `RouteContributor` witness on the variant proxy type; register the variant proxies onto the builder; the
  variant graph's `apply` covers only the surviving non-scoped controllers. Retire the production-witness
  `@TaskLocal` variant-proxy branch (the variant graph selects structurally); the per-request doubles channel
  (`TestBindStore` + header) stays.
- bug 2a — `@TaskLocal`/witness box type spelled from the facade's generic return; bug 2b — `_<Key>Doubles(...)`
  call in WireGen's sorted-by-field-name order. Add `variantGraphTypeName`/`variantBootstrapMethodName` to
  wire-mvc's `TestingKeyDiscovery`.
- **Gate:** wire-mvc-examples mocked suite — the eager overlay `@Singleton` (CouchDB-style) `init` does not
  run under `@Suite(.wiremvc(key))`; the real/keyless suite still constructs it. Existing keyed harness
  tests + the example app stay green.

## The swift-wire ↔ wire-mvc contract change

Exact generated names wire-mvc binds to (must match WireGen blind; sources: WireGen
`TestingVariantContributorProxies.swift`/`TestingGraph.swift`, wire-mvc `TestingKeyDiscovery.swift`):

| Artifact | swift-wire emits | wire-mvc derives | Change |
|---|---|---|---|
| Variant app graph | **new** `_<Variant>WireGraph` + `Wire.bootstrap<Variant>()` | keyed factory calls it | **new** |
| Variant proxy facade | `bootstrap<Variant>_<Subject>Contributor(wireGraph:)` | `variantFacadeMethodName` | param type → `_<Variant>WireGraph` |
| Variant proxy type | `_<Variant>_WireRouteContributor_<Subject>` (generic-erased return) | `variantProxyTypeName` | wire-mvc must spell the **generic** return in the `@TaskLocal` (bug 2a) |
| `_<Key>Doubles` | fields/init **sorted by field name** | `_<variantName>Doubles` | wire-mvc emits the `_<Key>Doubles(...)` call in the **same sorted order** (bug 2b) |
| `variantName` mangling | `keyReference` dots→`_` | must match | unchanged |

The doubles-per-request channel (`TestBindStore`, `X-WireMVC-Test-Binds`, `withBindValues`, per-request
`variantProxy._wireEnterScope(request, doubles)`) is **unchanged** — the variant graph is orthogonal to it.

## Blast radius & migration

- **swift-wire source:** `TestingVariants.swift` (compute + thread `variantAppOrders`; extend the drop
  rule), `TestingVariantContributorProxies.swift` (variant graph reference), `renderWireGraph`/`appendStruct`
  wiring (`CodeEmission.swift`), `orchestrateVariantScope` re-point (`TestingVariants.swift`). No change to
  `_wireBootstrap()`/`_WireGraph` (keyless untouched).
- **swift-wire gates (migrate the bootstrap call):** the six variant gates above; `ReplacesBindTypeCompose`
  is the notable one (needs both `Wire.bootstrap()` and `Wire.bootstrap<Variant>()`).
- **wire-mvc:** `BootstrapGeneration.bootstrapBuildLines` (keyed variant of the build line),
  `KeyedHarnessGeneration` (`@TaskLocal` generic type, doubles-call order), and O1's route registration.
  The example app's real suite is unaffected; the mocked suite gains leak-freedom.

## Risks / open items

1. **O1 — route collation on the variant graph.** The central unknown: whether keyed route registration
   moves off `WireMVC.apply(graph)`'s production collation onto the variant proxies. Resolve before phase 2
   lands (it decides whether the variant graph drops proxies and how wire-mvc registers routes).
2. **Generic-axis re-indexing.** Dropping a `some T` axis shifts the remaining `T<i>` indices; the variant
   seed scope's `seedScopeLift` and the proxy facade's return must agree on the re-indexed axes. The H2.2a
   generic spike (shape 2 + the borrow-local fix) covers the facade side, but the *variant graph type* with
   a dropped axis is new — phase 1's generic fixture must exercise it directly.
3. **`@Scopable`-lifted eager singletons.** They are dropped from the variant graph (reconstructed per
   entry), so their `init` also doesn't leak — good — but confirm nothing keyless-only relies on their
   app-scope construction. (It can't: they're only lifted *under a key*.)
4. **Contract drift on `_<Key>Doubles` order.** Bug 2b re-surfaces if either side changes the order
   independently. Pin the ordering (sorted-by-field-name) in the contract table and a cross-repo assertion.
5. **Reopening H2.2a's reuse decision.** This deliberately diverges the variant from `_WireGraph`. It adds a
   per-key app graph to the generated file (size), justified by delivering TestingModel.md's stated model
   and closing both the leak and the generic-subject gap with one mechanism.
</content>
