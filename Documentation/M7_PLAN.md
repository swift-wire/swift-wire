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
- **A transitive dead-code diagnostic.** `DeadBindingDiagnostics.swift:14` recorded the check as
  "First-order only: a binding consumed solely by another dead binding is not yet detected (no fixed-point
  pass)." Reachability *is* that fixed point, so the limitation is discharged by construction rather than
  by a separate feature — **done in M7b.4**, and it survives only inside a seed scope, which is built
  unpruned until M7d retires the whole-scope façade.

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

### M7b.2 — prune dependency-module bindings only — **done**

The low-risk first cut, and it captures essentially the whole win. Restrict the node set to reachable
bindings **whose `originModule` is external**; keep every home-module binding regardless. This is the
500-binding case, and it cannot regress an app that reaches a binding through `graph.x`, because home
bindings are all still emitted.

**Gate: met.** Both halves are in `CompositionHarness`, and both were probed to confirm they can fail.
The library ships an unreached `public @Singleton` whose `init` traps, so the consumer reaching its last
line *is* the assertion that the binding was pruned — with pruning disabled the harness aborts on that
`fatalError`. Beside it, the consumer declares a graph conformance over a library-declared key that the
library contributes to: with the conformance root removed the harness builds, runs, and fails the
contributor assertion, which is the silent empty-accessor failure made loud. The byte-identical invariant
holds — `GoldenHarness` is unchanged, as expected, since `WireTestLibrary` is a same-package sibling and
the in-repo corpus therefore has no external bindings at all.

The testing-variant cross-cut is closed rather than tested: variants now derive from the production
graph's retained set (`productionRetains`), narrowed to the external half so the filter cannot drop the
generic templates a variant needs. It has no fixture because one cannot exist yet — it needs a package
with both testing variants and an external Wire-aware dependency, which no harness has; M7b.3 makes it
reachable from the in-repo corpus.

**Measured**, on the ROADMAP's 500-binding case with the consumer injecting exactly one binding: 1,525
lines, 501 stored properties and 501 eager constructions become **28 lines, 2 and 2**.

### M7b.3 — prune home-module bindings

The behaviour change with a migration cost: an app that reaches a binding only through `graph.x`, with no
`allowUnused`, loses it. Do not ship this silently — the pruned-binding set is exactly the information the
developer needs, and Wire already has the visibility gate to decide when to speak.

**Gate: met.** `prunedBindingDiagnostics` reports each pruned home-module binding — at **every**
visibility, not under the dead-binding gate the plan assumed — with the `allowUnused` fix-it and the
property name the developer would have read (`graph.deploymentTarget`), and names a pruned `@Teardown`
binding specifically. The gate does not transfer because it answers a question about *consumption* while
pruning asks about *construction*: a public declaration may have consumers Wire cannot see, but a public
binding is constructed by this graph alone, and the graph is `internal` to its module. The argument for
reusing it — that a library target's own graph would warn on all its public bindings — is false in Wire's
pattern: a Wire-aware library applies no build plugin and is re-parsed by its consumer. It supersedes the
dead-binding warning for anything it reports — the two state one fact and this one says more — which is
part of M7b.4 arriving early for a UX reason, since shipping both would double every message.

**The golden did not need re-recording: it is byte-identical.** That is the finding, not a shortcut. The
migration cost seven annotations (six weak-cycle example bindings and a library service the tests read off
the graph, plus one in the `@GraphInputs` harness), and after them the corpus emits exactly what it emitted
before. The change does not shrink a well-formed app's graph; it makes the app declare which bindings leave
through a door Wire cannot see. Each of the seven was found by the diagnostic first — in the `@GraphInputs`
harness it named the binding, the fix and `graph.deploymentTarget` before the compile error appeared.

The gates live in `CompositionHarness`, beside M7b.2's pair, and cover the message as well as the
behaviour: the consumer declares an unreached home binding whose `init` traps, so the run reaching its last
line asserts the prune, and the script greps the build for the diagnostic naming that binding *and*
carrying its fix-it — a trap alone would still pass if the diagnostic quietly stopped firing. They live
there rather than in `Tests/IntegrationTests` precisely because the warning fires at every visibility now:
a deliberately-unreached fixture inside the corpus would warn on every build, where in the harness the
warning is half the assertion. README's reachability section is written, and `VisibilityModel.md` records
where its own table stops applying.

### M7b.4 — fold the dead-code diagnostic onto reachability — **done**

Replace the first-order consumption check with "unreachable from any root", discharging
`DeadBindingDiagnostics.swift:14`. Keep the package-local subtlety the ROADMAP records: a package-local
contributor folded into a `public` aggregate that is never consumed is genuinely dead and warrants the
warning, while the aggregate itself stays silent.

Most of the *behaviour* arrived with M7b.3, whose diagnostic already reported a transitively-dead binding
and the package-local contributor — both verified against the real WireGen before this step began. What
M7b.4 does is make the fold **structural rather than accidental**, and prove it. `deadBindingDiagnostics`
now excludes every identity reachability *decided* — retained and pruned alike, not just the pruned — so a
binding a pruned graph kept is live because a root reaches it, and one it dropped is reported in terms that
say more. Judged bindings still count as *consumers*, which is what keeps an app singleton used only from
inside a seed scope alive.

**The visibility gate is deliberately not kept**, contrary to this plan's line: M7b.3 settled that
visibility gates diagnostics about *consumption* while pruning asks about *construction*, so the merged
diagnostic reports at every visibility. See `VisibilityModel.md`.

**What is left of the limitation, stated rather than pretended away:** seed scopes are built with
`ReachabilityPolicy.none`, because the whole-scope façade still constructs every binding in a scope, so
within one the check is still first-order. Their per-root pruning happens at emission (M5.4.6), and the
graph-level fixed point arrives with **M7d**, when the façade goes.

**Gate: met.** The existing dead-binding tests pass unchanged (738 tests green, none of that suite
touched), plus the two cases that only a fixed point catches: a binding consumed solely by another dead
binding, and a `package` contributor folded into an unconsumed `public` aggregate — with the aggregate
itself staying silent.

### M7b.5 — retire `_WireExports.swift` — **done**

Only now, with a bound in place. Detection flips from the marker file to "this direct dependency's target
depends on the `Wire` product" (`WireBuildPlugin.swift:99`). The predicate cannot under-fire — a target
declaring bindings must `import Wire`, which requires that direct product dependency — and over-firing is
harmless: a scanned library with no bindings contributes none, and anything unreachable is now pruned.

**Gate: met.** Every `_WireExports.swift` in the repository is deleted — the composition, adapter and
injection-rewrite harness libraries, and `WireTestLibrary` — and all five harnesses plus the full suite
pass. Detection is `dependsOnWire`, which matches the `Wire` **product** for an external package and the
`Wire` **target** inside swift-wire's own package, since a same-package sibling depends on it by name.

`CompositionHarness` grew a third package, `TransitiveLibrary`, and it carries both halves of the
transitive case as *passing* assertions rather than an absence:

- **A transitive Wire-aware package is not activated.** It declares a binding whose simple name collides
  with one the consumer declares, so activation would be a duplicate-binding error; the consumer reads its
  own binding's `origin` at runtime to close the other half.
- **A library binding whose dependency lives in a package the consumer never depended on is a
  non-event.** `WireHarnessLibrary` gains a binding needing `DeepConfig`, two packages away and outside
  the consumer's parse set. Reachability strips it before the missing-binding check, which is exactly the
  coupling that made retirement wait for M7b.

All three were probed: with `dependsOnWire` stubbed to `false` composition breaks; with the transitive
package depended on directly the build fails with `'HarnessSharedService' has multiple bindings`; with
pruning disabled it fails with `no binding produces 'DeepConfig'` — the failure the note predicted in
prose, now observed.

**M7d is folded in, on a better criterion than "delete it and rewrite the tests".** The façade is dead
code exactly when a bridging proxy enters the scope, because the generated witness calls the proxy's
`_wireEnterScope` thunk instead — so it is now emitted only for a scope **no proxy enters**, which is the
dead-code criterion stated rather than approximated. The ROADMAP's prerequisite (a thunk-based
construction harness for `BootstrapTests`) turns out not to be needed: swift-wire's own seed-scope tests
use scopes with no proxies, so they keep their façades and are untouched. **219 lines and 13 façades**
leave the integration corpus; the golden is re-recorded at 6,417 lines.

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
