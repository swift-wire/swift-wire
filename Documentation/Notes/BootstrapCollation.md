# Bootstrap collation — design note (M5)

> **Status:** captured during M4.2; **partly superseded by what shipped.** A design space
> for the **Tier-2 composition-root macro**, framed here around a Hummingbird-specific
> `@WireHummingbird` bootstrap. That framing was retired: M5.5 shipped the proposal-native
> **`@WireMVCBootstrap`** (a `@Singleton` root whose plugin generates `@main`) instead — a
> `@WireHummingbird`/`@WireVapor` macro fights the grain in those ecosystems. The *problem
> statement* below (contributions must be applied, nothing enforces it) and the
> apply-collation mechanism remain accurate; the `@WireHummingbird` bootstrap sketch is
> historical. See [ROADMAP.md](../../ROADMAP.md) M5.5 and the archived
> [M5.5 plan](../Archive/M5_5_PLAN.md).

## The problem

Each framework adapter collates contributions into its own keys and ships an `apply`
facade the app calls at bootstrap to wire them onto the runtime:

- `WireHummingbird.apply(graph, to: router)` — mounts `@HummingbirdController` routes and
  returns `@HummingbirdService` services.
- `WireOpenAPI.apply(graph, to: transport)` — registers `@OpenAPIController` handlers.
- (M5) `WireMVC.apply(graph, to: transport)` — the declarative-routing equivalent.

**Nothing enforces that the app calls every adapter whose keys have contributions.** Add a
`@HummingbirdController` to an app that only calls `WireOpenAPI.apply`, and the route
collates into `HummingbirdKeys.routes` and simply never mounts — no error, silent
breakage. task-cluster exhibits this today (it calls `WireOpenAPI.apply` +
`mountIntrospection`, not `WireHummingbird.apply`; it's only safe because it has no
Hummingbird contributions).

Teardown is **not** an instance of this problem — it's a *graph* concern (`Teardownable`,
universal), applied by a single standalone `teardownService`, so there's no "which
adapter" ambiguity. This note is about the *adapter* apply steps.

## Why documentation isn't enough

The obvious fallback — "document that every adapter's `apply` must be called" — breaks on
the Tier-2 composition-root macro. A Hummingbird-specific `@WireHummingbird` bootstrap
macro codifies `bootstrap → router → apply → Application → run`, but it can't know it
should *also* call `WireOpenAPI.apply` / `WireMVC.apply` — those are cross-runtime
adapters it has no compile-time knowledge of. So the macro must **collate** apply steps,
not hard-code its own.

## Mechanism — collated apply steps

Same discipline as the existing adapter contracts (`WireGraphConformanceV1`,
`WireAdapterAnnotationV1`, `WireGraphConformanceV1`): an adapter *declares* its apply step,
and the plugin discovers it by re-parsing sources.

```swift
// WireOpenAPI declares:
public let wireOpenAPIApplyStep = WireApplyStepV1(
    entry: "WireOpenAPI.apply",              // called as entry(graph, to: <target>)
    targetConformsTo: (any ServerTransport).self
)
// WireHummingbird declares one targeting (any RouterMethods<…>) / its composable.
```

The Tier-2 composition-root macro (which knows the runtime and builds the target — a
Hummingbird `Router`) emits `<step.entry>(graph, to: router)` for **every** discovered
step. It never names WireOpenAPI or WireMVC; WireMVC declaring a step is all it takes for
the macro to call it. This is the collation pattern the adapters already use, lifted to
the bootstrap.

### The cross-runtime conformance is a *feature* here

The router conforms to `ServerTransport` only if a transport bridge (`OpenAPIHummingbird`)
is imported. So a generated `WireOpenAPI.apply(graph, to: router)` in an app that depends
on WireOpenAPI but hasn't imported a bridge is a **compile error** — which converts
today's *silent runtime* under-wiring into a *loud build-time* one. That's the
improvement. And because the plugin knows the step's `targetConformsTo`, it can emit a
targeted diagnostic — "WireOpenAPI applies to `some ServerTransport`; your router isn't
one — add `import OpenAPIHummingbird`" — rather than a raw conformance error.

Teardown folds in as one more collated step (unconditional, since every graph is
`Teardownable`), so the Tier-2 bootstrap ends with the graph teardown wired without the
app doing anything.

## Prior art — the same constraint, three escape hatches

The structural problem here isn't Swift's: contributions are spread across a module graph,
something has to collect them, and no single site knows them all. Rust hits it constantly,
because proc macros are strictly per-item with no channel between invocations — a macro
expanding `@X` on one type cannot know another `@X` exists anywhere. Three answers are in
production there, and the differences map onto choices this note is making.

**An out-of-band compiler (pavex).** A separate binary (`pavexc`) reads rustdoc JSON across the
crate graph, resolves the whole graph, and generates the wiring. Same family as Wire's plugin —
a whole-program collector living outside macro expansion — and the only one of the three that
gets *type* information rather than syntax. It pays by pinning to an unstable format. Wire's
plugin re-parses sources instead, so it stays on a stable toolchain and gets no type
information; see [ChoosingADIFramework.md](ChoosingADIFramework.md), *Macros vs. codegen*.

**A build script plus a user-placed epilogue (lockjaw).** `build_script()` in `build.rs`
collects; `epilogue!()` in `main.rs` validates and emits. Libraries skip the epilogue, binaries
cannot. This is the cautionary one for this note, because it solves collation and still **leaves
a user-side obligation** — the binary must remember to invoke `epilogue!()`. That is the same
shape as the bug this document exists to kill: added a contributor, forgot the call at the root,
silent until something doesn't happen. A design that collates centrally but still asks the app
to declare something hasn't finished the job. The Tier-2 macro emitting *every* discovered step,
rather than the app calling each `apply`, is what closes it here.

**Link-time distributed slices (linkme / inventory).** Contributors self-register into a slice
the linker assembles, or via life-before-main constructors. Zero ceremony and no central
declaration at all — which is exactly why it can't answer either question this note cares about.
There is nowhere to *count* contributions, so the interim reminder below ("graph has N
contributions to this key; ensure `apply` is wired") has no analogue: nothing knows the total
until the program is already running. And ordering is link order, which is not deterministic in
any useful sense — directly relevant to open question 1. Wire can impose a deterministic order
precisely because the plugin holds the whole list at build time.

Worth carrying forward: the interim diagnostic and the ordering guarantee are both
*consequences of collating centrally at build time*, not incidental conveniences. A link-time
design would be less ceremony and would forfeit both.

## Interim: a build-time reminder (could land before M5)

Short of full collation, the plugin already knows each collation key's contribution count.
A build note when a key has contributions — "graph has N `HummingbirdKeys.routes`
contributions; ensure `WireHummingbird.apply` is wired at bootstrap" — surfaces the
requirement without generating any bootstrap. Non-enforcing, cheap, and it would have
caught the "added a controller, forgot `apply`" case. A candidate for M4/pre-1.0 polish if
Tier-2 is far off.

## Open questions for M5

1. **Step ordering.** Does apply order matter across adapters (routes vs handlers on the
   same router)? Likely independent, but the collated steps need a deterministic order.
2. **Target construction.** The Tier-2 macro builds the runtime target (HB `Router`); a
   `WireVapor` Tier-2 would build a Vapor `Application`. The step's `targetConformsTo`
   protocol is the contract; the macro supplies a conforming value.
3. **Manual (Tier-1) apps.** They keep calling `apply` by hand. The interim diagnostic is
   their safety net; full collation is a Tier-2 benefit.

## References

- [AdapterModel.md](AdapterModel.md) — the contribution-alias contract this extends.
- [WireHummingbirdDesign.md](WireHummingbirdDesign.md) — the Tier-2 macro (`bootstrap →
  router → apply → Application → run`) this generalises.
- [WireMVCAbstraction.md](WireMVCAbstraction.md) — the cross-runtime adapters whose apply
  steps must collate.
- [ChoosingADIFramework.md](ChoosingADIFramework.md), *Macros vs. codegen* — the source-parsing
  vs. compiler-artefact trade the pavex comparison above turns on.
- External, for the prior-art section: [pavex](https://docs.rs/pavex) and
  [its design post](https://www.lpalmieri.com/posts/a-taste-of-pavex-rust-web-framework/);
  [lockjaw](https://docs.rs/lockjaw) (`build_script()` + `epilogue!()`, and the
  [caveats](https://azureblaze.github.io/lockjaw/caveats.html) that disown its cross-crate
  mechanism); [linkme](https://docs.rs/linkme) and [inventory](https://docs.rs/inventory) for
  the link-time registration model.
