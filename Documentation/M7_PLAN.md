# M7 build plan — reachability pruning, and retiring the marker

> **Status:** M7 started 2026-08. **M7b is the pass this plan covers**; M7a is deferred out of the
> milestone with its mechanism proven and its blocker recorded
> ([PendingIssues/20](../PendingIssues/20-manifest-discovery-plugin-output-visibility.md)), and M7c/M7d/M7e
> keep their existing triggers. The design record is
> [Notes/MultiModuleComposition.md](Notes/MultiModuleComposition.md) — it carries the activation model, the
> retirement plan, and the reasoning this plan implements. This file carries the *how*.

Same discipline as the other milestone plans: each sub-step runs end-to-end and has a validation gate;
highest-risk seam first. Grounded in the 2026-08 M7 spike and in the shipped pipeline cited below.

## The headline

A dependency should cost only what the consumer reaches. Today the merged graph is
**construct-everything**: measured on a 500-binding library where the consumer injects exactly *one*
binding, the generated graph carried 500 stored properties, **500 eager constructions** and 1,522 lines.
M7b computes the bindings reachable from the home package's roots and strips the rest before codegen.

Two things ride on it that are not performance:

- **Retiring `_WireExports.swift`.** The marker's detection job has a replacement the consumer can read —
  a direct dependency that depends on the `Wire` product, **verified readable** by the spike. What the
  marker also does is *bound* what composes, and only reachability can take that over. Retirement is
  therefore M7b's, not M7a's (the ROADMAP filed the surface trim as M7a-adjacent; that anchor moved).
- **A transitive dead-code diagnostic.** `DeadBindingDiagnostics.swift:14` records the current check as
  "First-order only: a binding consumed solely by another dead binding is not yet detected (no fixed-point
  pass)." Reachability *is* that fixed point, so the limitation is discharged by construction rather than
  by a separate feature.

## What M7b embeds into (shipped — stable seams, do not change)

- **`buildDependencyGraph`** (`Sources/WireGenCore/Graph.swift:450`) — the whole pipeline: fan-in of
  multibinding aggregates, partitioning, `@Replaces`, duplicate detection, generic specialisation, then
  `resolveDependencies` (`:528`) producing `dependencyEdges` + `missingBindings`, then `topologicalSort`
  (`:533`). **Pruning is a new stage between `resolveDependencies` and `topologicalSort`** — it needs
  resolved edges to walk, and everything after it consumes the reduced node set unchanged.
- **`originModule` per binding** (`Sources/WireGenCore/OriginModule.swift:12`) and the home/external split
  the plugin already passes (`--module` vs `--external-module`,
  `Plugins/WireBuildPlugin/WireBuildPlugin.swift:104`). Reachability's home-package rule reads these; no
  new discovery metadata is required.
- **`allowUnused`** on `@Singleton` / `@Scoped` / `@Provides` (`Sources/Wire/Macros.swift:16`, `:68`,
  `:198`) and on the multibinding keys (`Sources/Wire/MultibindingKeys.swift:32`). Today it is purely a
  diagnostic silencer. M7b gives it a second, *semantic* meaning — see the sub-decision below.
- **The dead-binding visibility gate** (`Sources/WireGenCore/DeadBindingDiagnostics.swift`) —
  `internal`/`package` warn, `public`/`open` stay silent. M7b reuses this gate rather than inventing a
  second liveness policy.
- **The composition harness** (`CompositionHarness/`) — the only place the external-`.product` path is
  exercised, since a fixture package depending on swift-wire cannot live under `swift test`.

## The central decision — prune before diagnosing, not after

Everything else follows from this, and it is also the enabling change for the marker.

Once the marker stops bounding composition, *every* direct Wire-dependency's bindings enter the parse set,
including bindings the consumer cannot satisfy — a library binding whose own dependency lives in a package
the consumer never depended on. Today that is a hard `missingBindings` error. It must become a non-event,
which it does exactly when unreachable bindings are stripped **before** the missing-binding check rather
than after. So the ordering inside `buildDependencyGraph` is the design, not an implementation detail:

> Resolve edges → compute reachability from roots → **restrict the node set** → report `missingBindings`,
> cycles and dead-code warnings over the reachable set only.

A cycle among unreachable bindings likewise stops failing the build. That is correct — the consumer never
constructs them — and it should be stated in the note rather than discovered.

The safety net is the same shape M8 uses, and it should be written before any pruning code:

> A graph in which every binding is already reachable from a root produces **byte-identical** generated
> output before and after M7b.

`GoldenHarness/` is the guard — the real `WireGen` over the `Tests/IntegrationTests` corpus (containers,
seed scopes, contributor proxies, graph conformances, teardown, member injection, opaque lifts, testing
variants) plus its Wire-aware sibling, diffed against a committed recording, with a CI job of its own. It is
what makes this invisible to single-module apps, which is the claim the ROADMAP makes for the whole
milestone.

## Sub-steps

### M7b.0 — the root model (design gate, no code) — **done**

The hard part, and the reason this is milestone-sized rather than an afternoon. The plugin sees `@Inject`
edges but not external `graph.x` accesses, so the root set has to be declared.

**Settled 2026-08 in [Notes/MultiModuleComposition.md](Notes/MultiModuleComposition.md) §
"Reachability roots (M7b.0)"**, with the `allowUnused` divergence recorded in
[Notes/VisibilityModel.md](Notes/VisibilityModel.md). **Two roots** on the app/container graph —
aggregates a **graph conformance** names, and `allowUnused` in the home package (on a binding or on a
multibinding key); `@GraphInputs` properties are already the second of those, since `graphInputBindings`
folds each into a home provider carrying `allowUnused: true`. Per seed scope, the roots are the subject and
yields its thunk names (M5.4.6's existing rule). Contributors, contributor proxies, borrowed singletons and
synthesised factories are *reached*, not rooted, and the note says why each one that looks like a root
isn't.

Two candidates were settled **against** this plan's opening enumeration, both because they confuse a
diagnostic question with a construction one:

- **`@Teardown` does not root a binding.** Teardown is a property of a constructed binding, not a reason to
  construct one — a resource nothing reaches is never made, so there is nothing to shut down. Rooting on
  the annotation would also pin every dependency's `@Teardown` binding into every consumer's graph, which
  is construct-everything by annotation. A binding whose construction is the point uses `allowUnused:`.
- **A `public` key does not root its aggregate.** The "non-prunable exception" argues from *contributors*,
  but pruning turns on *consumers*, and nothing outside the graph can read an aggregate's product
  (`_WireGraph` is `internal`). Visibility gates diagnostics; consumption gates construction. The
  ROADMAP's own wording — the aggregate stays *silent* — is the diagnostic claim, and it stands.

Three things the enumeration above missed, each of which changes a later sub-step:

- **A graph conformance is a root — and, with `@Teardown` and public keys gone, one of only two.** It is
  the one whose omission is silent. A
  `WireGraphConformanceV1` member reads its multibinding aggregate off the topological order, and a member
  whose key has no aggregate falls back to an *empty accessor* by design (`GraphConformanceEmission.swift`).
  Prune that aggregate and a WireMVC/Hummingbird app compiles, boots, and serves zero routes. A build-based
  gate cannot catch it — M7b.2 needs a behavioural one.
- **The walk's edge set ≠ the sort's edge set.** `dependencyEdges` deliberately omits member-injection
  parameters (so cycles through them stay legal, `Graph.swift:747`) and scope-entry thunks (identity is a
  function type matching no producer). Both consume bindings that are genuinely constructed, so the walk
  covers `dependencyEdges` ∪ member-injection edges ∪ thunk-constructed identities while the sort keeps
  walking `dependencyEdges` alone. `DeadBindingDiagnostics` already unions exactly these
  (`consumedIdentities`, `scopeEntryConstructedIdentities`) — reuse them rather than re-deriving.
- **Testing variants are derived from the *unpruned* set** (`TestingVariants.swift:106`) and borrow the
  production `_WireGraph`'s properties, so a pruned-but-borrowed singleton emits `_wireGraph.<pruned>` and
  fails to compile in generated test code. Settle with M7b.2/M7b.3; the cheap resolution is to derive
  variants from the pruned production node set.

The walk itself is not new code: `reachable(from:over:)` (`TestingGraph.swift:254`) already traverses this
map shape for the seedless-reconstruction cone.

**Gate: met** — the note names the complete root set and its rationale, and says what a *library's*
`allowUnused` means (ignored for reachability; a library binding is live iff reached from a home root).

### M7b.1 — compute reachability, change nothing — **walk landed; guard outstanding**

Add the walk over `dependencyEdges` from the M7b.0 root set, return it alongside the existing outcome, and
**do not** restrict anything yet. Assert the byte-identical invariant.

Landed: `Sources/WireGenCore/Reachability.swift` (the root set as `reachabilityRoots`, the widened
adjacency as `reachabilityEdges`, traversal reusing `reachable(from:over:)`), computed inside
`buildDependencyGraph` between `resolveDependencies` and `topologicalSort` and surfaced as
`GraphResult.reachable`. `ReachabilityRootPolicy` says *which* roots a build wants: `.appGraph` for the
default/container graphs, `.none` — the default — for a seed scope or testing variant, whose construction
set is bounded elsewhere. Nothing reads the result, so output is byte-identical by construction.
`Tests/WireGenCoreTests/ReachabilityTests.swift` covers the walk and every root rule.

The guard the plan named had nothing to run over — **there is no `Fixtures/` directory in this repo**, and
both this plan and M8_PLAN assumed one. It is now `GoldenHarness/`: 6,636 lines of recorded `_WireGraph`
plus its key checks, `--update` to re-record, and a CI job beside the other harnesses. Verified to catch
drift and to survive the `swift-format --recursive` job (the recording carries a `.swift.golden`
extension, so no tool reformats it).

**Gate:** `GoldenHarness` is untouched and green; unit tests over the walk cover diamond deps, cycles among
unreachable nodes, a generic binding reached only after specialisation (the case
`DeadBindingDiagnostics.swift` already had to special-case), a binding consumed *only* by member injection,
and a bridge proxy's subject and yields reached only through its scope-entry thunk — the last two being the
edges M7b.0 found the sort does not carry.

### M7b.2 — prune dependency-module bindings only

The low-risk first cut, and it captures essentially the whole win. Restrict the node set to reachable
bindings **whose `originModule` is external**; keep every home-module binding regardless. This is the
500-binding case, and it cannot regress an app that reaches a binding through `graph.x`, because home
bindings are all still emitted.

**Gate:** a consumer against a library with an unreached binding emits neither the property nor the
construction; `CompositionHarness` still passes; the byte-identical invariant still holds for graphs with no
external bindings. Plus the two M7b.0 cross-cuts: a **behavioural** test that an adapter-conformance-fed
graph still serves its routes (the empty-accessor fallback makes this failure silent, so a build gate does
not cover it), and a testing-variant fixture whose borrowed singleton is unreachable from a production
root.

### M7b.3 — prune home-module bindings

The behaviour change with a migration cost: an app that reaches a binding only through `graph.x`, with no
`allowUnused`, loses it. Do not ship this silently — the pruned-binding set is exactly the information the
developer needs, and Wire already has the visibility gate to decide when to speak.

**Gate:** a diagnostic (not silence) for a home-module binding pruned under the same visibility rule the
dead-binding warning uses, with the `allowUnused` fix-it — and it should name a pruned `@Teardown` binding
specifically, since that is where the developer's intent ("this exists to be shut down") is least visible in
the code and most surprising to lose; `GoldenHarness`'s recording re-recorded, with the
diff read binding-by-binding (it is the migration, and the only place the behaviour change is legible);
README's reachability section written.

### M7b.4 — fold the dead-code diagnostic onto reachability

Replace the first-order consumption check with "unreachable from any root", discharging
`DeadBindingDiagnostics.swift:14`. Keep the visibility gate and keep the package-local subtlety the ROADMAP
records: a package-local contributor folded into a `public` aggregate that is never consumed is genuinely
dead and warrants the warning, while the aggregate itself stays silent.

**Gate:** the existing dead-binding tests pass unchanged where they should, plus a new case that only a
fixed point catches (a binding consumed solely by another dead binding).

### M7b.5 — retire `_WireExports.swift`

Only now, with a bound in place. Detection flips from the marker file to "this direct dependency's target
depends on the `Wire` product" (`WireBuildPlugin.swift:99`). The predicate cannot under-fire — a target
declaring bindings must `import Wire`, which requires that direct product dependency — and over-firing is
harmless: a scanned library with no bindings contributes none, and anything unreachable is now pruned.

**Gate:** `CompositionHarness/Library` builds and composes with its `_WireExports.swift` **deleted**; a
three-package fixture covers the transitive case; the marker's removal is swept from the README, the note,
and `WireBuildPlugin`'s doc comment. Fold in **M7d** here (the seed-scope façade trim) — the ROADMAP filed
it against this surface trim, and this is where the trim lands.

## Key sub-decisions

**`allowUnused` acquires a second meaning.** Today it silences a warning; after M7b it also pins a binding
and its transitive subgraph into the emitted graph. Those coincide for the intended case (a binding pulled
out through `graph.x`), but they diverge for a binding marked `allowUnused` merely to quiet the build —
which now keeps code alive. The alternatives are a distinct spelling (`@Singleton(root: true)`) or reading
`allowUnused` as a root only in the home package. **Recommendation: reuse `allowUnused`, home-package-only**
— it is what the ROADMAP already promises, and a second annotation for a nearly identical concept is worse
than an overloaded one. Record the divergence in `VisibilityModel.md`.

**Pruning is not visible in the surface, but it is visible in the dump.** The deferred `_WireGraph.json`
build-time dump is the natural place to show what was pruned and why (which root reached what). That pairs
the pre-1.0 polish item with the milestone that gives it something to say.

**Request-scope reachability is already shipped.** M5.4.6's per-root scope entry constructs a per-root
*subset*, not the whole scope — the same concept one layer down. M7b should reuse its vocabulary rather than
invent a parallel one, and the two should be described together in the note.
