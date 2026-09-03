# Multi-module composition

> **Status:** **shipped.** M1_PLAN iteration 7 implemented multi-module
> composition across sittings 7a–7g, all of which landed: single-`BindingKey`
> tracking (7a), origin-module metadata per binding (7b), same-package
> cross-target source reading (7c), direct-dependency activation (7d),
> cross-library validation + origin-module-aware ambiguity (7e), and the
> cross-module visibility threshold + cross-module key references (7f).
> SE-0491 `::` naming is **deferred** out of 7f (see "Naming" below for
> why). Remaining: the two-package integration gate (7g), which also
> exercises 7d's external `.product` path and 7e's missing-transitive-
> activation hint end-to-end. This note records the design — the
> **activation model**, cross-module **naming** (deferred), and cross-module
> **visibility** — so those coupled decisions aren't relitigated.

## What composition is

A dependency graph that spans **several modules**: module `A` and module
`B` each declare `@Singleton`/`@Provides`/`@Inject`, and a higher-level
graph composes them — `B` consuming `A`'s bindings, an app module
composing both. (Dagger does this with component dependencies /
subcomponents; Needle with its component hierarchy.) Wire's `@Container`
is *within*-module grouping, not this.

Composition changes one fundamental thing: **the generated bootstrap
references types from modules other than its own, and is consumed across
module boundaries.** That breaks two assumptions the single-module model
bakes in — naming and visibility.

## Activation is the dependency (a compile-time decision)

Activation is **compile-time**, not runtime. Wire's thesis is the static
graph: the plugin emits exactly one `_WireGraph` per target, so there is
one activation set per target — *not* a per-bootstrap-call choice — and
the plugin must know it before codegen to validate the whole graph and
collate multibindings. There is no runtime composition of separately
built module-graphs; the merged graph is flat, and "runtime is just
stored properties" holds across module boundaries.

**The surface is the manifest dependency list.** A library is Wire-aware
because it depends on the `Wire` product — nothing is required of it beyond
what declaring a binding already requires — and a consumer activates it by
**depending on it** in the target's `dependencies`. (Until M7b.5 the library
half was a hand-declared `_WireExports.swift` marker; see below.) The plugin reads the
target's *direct* dependencies, keeps the Wire-aware ones, and composes
them. No call-site `.activating(X.self)` directive (that was rejected: it
can't be a per-bootstrap decision, and SPM build-tool plugins can't take
custom per-target config anyway — the dependency list is the one
plugin-readable, SPM-name-checked manifest signal). One uniform rule:
**you activate the Wire-aware libraries your target directly depends on.**
Same-package and external are identical; transitive deps are *not*
auto-activated (you add them to your own `dependencies`, which you need to
`import` them anyway), so "transitive activation is explicit" falls out
for free.

**Depend = activate** collapses the importable-vs-activated distinction
for Wire-aware libraries. That's acceptable because it isn't the bad kind
of magic: the activated set is your direct, manifest-declared deps ∩
libraries that depend on `Wire` (both halves visible in manifests and
deliberate, nothing transitive), and every conflict is *loud* — a library shadowing your
binding is a duplicate/ambiguity compile error, a missing dep is a
compile error. The only quiet behavior change is a library `@Contributes`
growing a collection you consume, which is the intended cross-module
multibinding feature and is visible in the `_WireGraph.json` dump. A way
to depend-without-activate (types-only) is a deferred refinement.

Guidance for that case: a multibinding key is a *global extension point*,
so injecting a key you don't own means any activated package may
contribute to it (the collection grows with your dependency set). If you
need a known, complete contributor set, declare the key in a target you
control — most strongly the leaf app target, which nothing depends on, so
only your own code can reach it. (Order-sensitive collections also need
`withOrder:`; cross-module element order is otherwise unspecified — see
the `withOrder:` cross-module note below.)

### The marker is detection-only — and can't be auto-generated (retired in M7b.5)

> **Status: done.** `_WireExports.swift` is gone. Detection is now "this direct dependency's target
> depends on the `Wire` product", the predicate the retirement plan below argued for, and every marker
> file in the repository has been deleted. The section is kept because the *reasoning* it records — why a
> plugin-generated marker was impossible, and why retirement had to wait for reachability — is what makes
> the current design legible, and because [#338](https://github.com/tachyonics/swift-wire/issues/338) still leans on it for M7a.

`_WireExports.swift` does exactly one thing: signal Wire-awareness so a consumer
re-parses (later: references) a direct dependency. It is **not** a future readable
export interface, and it **can't be plugin-generated** — a consumer's plugin reads a
dependency's committed *sources*, never its plugin *outputs*. Spike-1's check (4)
(inspecting which plugins a dependency applies) is unavailable, and a 2026-07 re-check
confirmed the consequence directly: emitting `_WireExports.swift` from the contributor
plugin instead of hand-declaring it made the dependency **invisible** to the consumer's
`sourceFiles` scan — the build succeeded but the dependency's bindings silently dropped
out of the graph. So there is no plugin-generated export file a consumer can read **at plan
time** — a 2026-08 spike (see [#338](https://github.com/tachyonics/swift-wire/issues/338))
narrowed that: a consumer's *build command* can read one at **execution** time, given a declared
`inputFiles` edge on a derived path. Neither helps the marker, which must be readable while
`createBuildCommands` runs; it does change M7a, below. Composition works by re-parsing committed sources for the data and
referencing the dependency's public symbols **by derivable name** (compiler-linked) —
which is exactly what the `@Factory` factory-lift does (`_WireFactory_<key>` is public
in the template's module; the consumer emits a reference resolved at compile time).

**Retirement plan — executed (M7b.5).** The marker's whole job was replaceable by a signal the consumer
*can* read: **a direct dependency that depends on the `Wire` product** — **verified readable**
(2026-08): a dependency target's own product dependencies are exposed at plan time, and a target
that declares bindings must `import Wire`, which requires that direct dependency, so the predicate
cannot under-fire. In swift-wire's own package `Wire` is a *target* rather than a product dependency, so
`dependsOnWire` matches both kinds by name — a same-package sibling library and an external one are
otherwise identical here, exactly as the activation rule says. Over-firing is harmless here — a scanned library with no bindings yields none —
which is exactly why the same predicate is unusable for M7a, where over-firing is a build failure. That drops the
hand-declared file — a contributor applies `WireContributorPlugin` only when it declares
`@Factory` templates (a missing plugin is a loud, local compile error, `cannot find type
'_WireFactory_<key>'`); a pure-`@Singleton` contributor declares nothing. The catch is
that the marker also *bounded* what composes, so its removal was **coupled to
reachability pruning (M7b)** — the prerequisite, not a nicety: without a bound, every
direct Wire-dependency's bindings are pulled in and eagerly constructed, so an
incidentally-scanned binding with a consumer-unresolvable dep would break; reachability
strips the unreachable before resolution. **That coupling is now measured rather than argued**: the
composition harness carries a library binding whose own dependency lives in a third package the consumer
never depends on, and with pruning disabled the consumer's build fails with `no binding produces
'DeepConfig'` — the exact failure this paragraph predicted. That work's bulk lands with **M5.4
(request-scoped controllers)**. A public-keyed multibinding was recorded here as
the non-prunable exception (a public collection key can gain contributors outside the
analysed graph, so it survives with no local consumer). **M7b.0 settled that the other
way** — nothing outside the graph can read an aggregate's product, so visibility gates
the diagnostic and consumption gates construction; see "Reachability roots (M7b.0)"
below.

## The two optimizations split out of M1 (M7a deferred, M7b shipped)

Both keep the surface contract unchanged. **M7b shipped in 2026-08/09** and is
recorded below and in the roots section that follows; M7a remains deferred on
cost and on a predicate SPM cannot supply:

- **M7a — manifest-based discovery.** M1 re-parses dependency sources at
  the consumer's build; M7a has each library emit a per-library
  compile-time manifest of its bindings, which the consumer reads instead
  of re-parsing. The seam is the discovery-output model
  (`[DiscoveredBinding]` + key lists): M1 produces it by parsing, M7a by
  deserializing a manifest. Everything downstream (merge, graph, codegen,
  diagnostics) is unchanged — `originModule` is already per-binding and
  serializable, so it rides into the manifest exactly as stamped today.
  **Constraint, restated (2026-08).** The 2026-07 reading was that the manifest can't be a
  per-build *plugin output* at all, leaving only a **committed** artifact or **public symbols**
  referenced by name. A spike narrowed that, and the distinction is plan time vs. execution time:
  a consumer's plugin can't *see* a dependency's plugin output while planning, but the build
  command it emits **can read one**, given the derived output path declared in `inputFiles` —
  llbuild then orders the producer first, verified under both build backends with correct
  incremental propagation. So M7a is **possible**; it is deferred on cost, not feasibility.

  What holds it is a **predicate**, not the mechanism: the edge must be declared during
  `createBuildCommands`, an input nothing produces is a hard build failure, and SPM exposes no
  signal for plugin application (a dependency package's plugin target doesn't appear in its
  `targets` at all). Every inferable predicate answers "does this library declare bindings?"
  rather than "does it emit a manifest," and the two diverge exactly when an author declares
  bindings and forgets the plugin. The failure is asymmetric — a false negative falls back to
  re-parsing (correct, slower), a false positive breaks the build — so M7a can only ever add a
  fast path *beside* source re-parsing, per dependency, never replace it.

  The win is also smaller than assumed: re-parsing a 500-file dependency costs **~50 ms** steady
  state, and is embarrassingly parallel, where route C introduces a build-graph serialization
  point plus a path derived by string surgery over an undocumented layout — the lockjaw hazard
  this note twice declines. Full evidence, the closure that would make the predicate exact (and
  the surface it would cost), and the upstream asks are in
  [#338](https://github.com/tachyonics/swift-wire/issues/338).

  **The third route is answered: no (2026-08).** rustdoc-JSON's Swift analogue was the open
  question. `swift-synthesize-interface` does work on a binary `.swiftmodule` without library
  evolution, and carries fully-qualified types the source-parsing route structurally lacks — but
  the macro attributes are gone. An interface synthesized from the harness library shows
  `public static let primary: Wire.BindingKey<…>` and `public init()` with no `@Singleton`,
  `@Inject` or `@Provides` anywhere: post-expansion API only. It cannot supply binding data, and
  reading it would serialize the consumer's codegen behind the dependency's full compile — worse
  than the plugin-output route. `_WireExports.swift` still doesn't "become the manifest"; it's
  retired (detection moves to the Wire-product dependency, verified above).
- **M7b — reachability pruning. Shipped.** M1 eager-constructed *every*
  binding in the merged graph, including a library binding nothing reached, so
  a large dependency cost all its singletons even when the consumer used a few.
  The plugin now computes the bindings reachable from the graph's roots and
  strips the rest before codegen. Measured on a 500-binding library where the
  consumer injects exactly one binding: **1,525 generated lines, 501 stored
  properties and 501 eager constructions became 28, 2 and 2.** `Lazy<T>` is no
  longer the workaround for an expensive library binding — not reaching it is
  enough.

  The hard part was defining roots, because the plugin sees `@Inject` edges but
  not external `graph.x` accesses. **The complete root set is settled below**
  ("Reachability roots (M7b.0)") and comes to two: an aggregate a graph
  conformance names, and `allowUnused: true` in the home package. A library's
  `allowUnused` is ignored for reachability, so a library binding is live iff a
  home root reaches it. This changed the construction model
  (construct-reachable, not construct-all) and added a small annotation cost
  for externally-pulled roots — seven annotations across this repository, after
  which generated output was byte-identical.

## Reachability roots (M7b.0)

Pruning needs a **declared** root set, and the reason is structural: Wire reads syntax, never use. The
generated `_WireGraph` is `internal` and its bindings are read as ordinary expressions — `graph.userService`
— from the home target's own code, which no discovery pass sees. Everything Wire *can* see is either an
edge (`@Inject`, `@Contributes`) or a declaration, so a root has to be something declared. This section
names the complete set with the failure mode for each, settled 2026-08 as M7b.0's gate; the walk is M7b.1
and the restriction on which modules it prunes.

**Roots are per graph, not per module.** Each `buildDependencyGraph` call is one graph — the default app
graph, one per `@Container`, one per seed scope (`orchestrateSeedScope`), one per testing variant — and each
carries its own root set. A seed scope's roots are the subject and the yields its bridging proxy's
scope-entry thunk names, which is exactly what M5.4.6 already prunes with (`reachableBindings(from:in:)`);
the list below is the app/container graph's. Same concept at two layers, and the vocabulary is shared
deliberately rather than reinvented.

### The root set

1. **Aggregates named by a graph conformance member.** A `WireGraphConformanceV1` maps each protocol member
   onto a multibinding key's product (`GraphConformanceEmission.swift`), and that is how an adapter-driven
   app's routes reach its framework — through `extension _WireGraph: HummingbirdComposable`, never through
   an `@Inject`. **This is the one root whose omission is silent**: a member whose key has no aggregate
   falls back to an empty accessor (`var routes: [any RouteContributor] { [] }`) *by design*, so that a
   graph contributing nothing still conforms. Prune the aggregate and the app compiles, boots, and serves
   zero routes. Nothing in a build-based gate catches it, so M7b.2 needs a behavioural test here.
2. **`allowUnused: true` in the home package.** "I'm a root, keep me" — the annotation a developer reaches
   for when a binding leaves through `graph.x`, or when its *construction* is the point. Home-package only
   (see below), and it roots a multibinding **key** the same way: an aggregate the app pulls out through
   `graph.x` says so on the key declaration, which already carries `allowUnused:` for the diagnostic.
3. **`@GraphInputs` properties.** Caller-supplied, so live by definition — the graph did not construct them
   and cannot judge their use. They need no rule of their own, and that is not a special case: they are
   already home-package-only (`resolvedGraphInputs` honours only home declarations) and already spelled as
   roots, because `graphInputBindings` folds each property into a home-module provider carrying
   `allowUnused: true`, for exactly the reason that makes the annotation a root.

Two things that read like roots are deliberately **not** roots, each settled against an earlier reading of
this note:

- **`@Teardown` does not root a binding.** The earlier reading was that a resource registered for orderly
  shutdown is reachable *because* it is torn down. It is the wrong way round: teardown is a property of a
  *constructed* binding, not a reason to construct one. A resource nothing reaches is never made, so there
  is nothing to shut down, and the teardown rides the binding either way — `teardown()` is emitted from
  the same node set as construction. Rooting on the annotation also has a cost the `allowUnused` rule
  exists to avoid: it would pin *every* dependency's `@Teardown` binding into *every* consumer's graph,
  which is construct-everything by annotation. A binding whose construction is itself the point — a
  registration, an exporter, a pool nothing injects — says so with `allowUnused: true`, the one annotation
  that means "I'm a root". `TeardownExample` in the integration corpus already has this shape: its
  consumer is the declared root and the resources it holds are torn down because they were constructed
  for it.
- **A `public` key does not root its aggregate.** The earlier reading (the retirement-plan section above,
  and the "non-prunable exception") was that a public collection key can gain contributors
  outside the analysed graph, so its aggregate survives with no local consumer. That is an argument about
  *contributors*, and pruning turns on *consumers*: contributions flow into an aggregate, they do not read
  it. Nothing outside this graph can read one — `_WireGraph` is `internal` to its module — so there is no
  downstream reader for the permissive tier to protect. **Visibility gates diagnostics; consumption gates
  construction**, and the two questions had been run together. The original wording is already the
  narrower one ("the aggregate stays *silent*"), which is the diagnostic and stays true. A public key
  whose product the app pulls out through `graph.x` roots it with `allowUnused:`, exactly as a binding
  does.

Explicitly **not** roots either, because they are *reached* rather than rooted — worth stating, since each
looks like a root from the outside:

- **Multibinding contributors**, adapter-annotated ones included (`@Controller`, `@RoutedBy`): an adapter
  annotation aliases `@Contributes(to: key)`, so a contributor is reached from its aggregate and lives iff
  the aggregate does. That is the whole reason (3) and (4) carry the weight they do.
- **Contributor proxies**: synthesised beside their subject and contributed to the key in its place, so also
  reached from the aggregate. The subject is reached from the proxy — by an ordinary field edge in the hold
  form, through the scope-entry thunk in the bridge form (see the edge set below).
- **Borrowed app singletons**: `linkingScopeEntryCaptures` gives a bridging proxy one `.scopeCapture`
  dependency per singleton its seed scope genuinely borrows, and those are ordinary resolved edges. A
  singleton used only inside a request scope is therefore reachable from the proxy and needs no root of its
  own — *provided* seed-scope orchestration keeps running ahead of the app graph's build, which it does
  today (`WireGen.swift:245`) and which the pruning stage must not reorder.
- **Synthesised factories** (`_WireFactory_<key>`): registered as ordinary bindings, with an input edge
  appended onto each consuming binding.

### The walk's edge set is not the sort's edge set

`dependencyEdges` is built for the topological sort, and it deliberately omits two things a reachability
walk must include. This is where a wrong prune is most likely to come from, and it is the same trap
`DeadBindingDiagnostics` already hit and worked around:

- **Member injections form no edge.** `@Inject weak var` / `@Inject func` parameters are post-init delivery,
  excluded from the sort precisely so cycles through them stay legal (`Graph.swift:747`) — that is the
  cycle-breaking feature, not an oversight. The value is still constructed and delivered, so a binding
  consumed *only* by member injection is live. `consumedIdentities` already unions both.
- **Scope-entry thunks form no edge.** A `.scopeEntryThunk` dependency's identity is a *function* type that
  matches no producer, so `resolveDependencies` skips it outright. Its subject — and every
  `.yieldsFromScope` binding it hands back — is constructed by the thunk.
  `scopeEntryConstructedIdentities` already derives exactly that set for the dead-binding analysis.

So the walk covers `dependencyEdges` ∪ member-injection edges ∪ thunk-constructed identities, while the sort
keeps walking `dependencyEdges` alone: **two edge sets over one node set, named apart** — widening the
sort's edges instead would turn a legal member-injection cycle into a build failure. The traversal itself is
not new code; `reachable(from:over:)` (`TestingGraph.swift:254`) already walks this map shape for the
seedless-reconstruction cone.

### What a library's `allowUnused` means: nothing

For reachability it is ignored, and a library binding is live iff reached from a home-package root. Its
diagnostic meaning is unchanged in both packages — it still silences the dead-binding warning wherever it is
written. The asymmetry is deliberate: `allowUnused` is the author's statement about their *own* build's
visible consumers, and honouring it as a root downstream would hand every dependency a way to opt out of the
pruning the consumer is paying for — construct-everything, by annotation. The consumer's roots are the
consumer's to declare. `VisibilityModel.md` records the divergence this opens between the annotation's two
meanings.

### Ordering: prune before diagnosing

The reachability stage sits between `resolveDependencies` and `topologicalSort`, and everything downstream
of it — `missingBindings`, cycles, dead-code warnings — is judged over the reduced node set. That ordering
is what lets the marker go: once composition is bounded by reachability rather than by
`_WireExports.swift`, every direct Wire-dependency's bindings enter the parse set, including a library
binding whose own dependency lives in a package the consumer never depended on. Today that is a hard
`missingBindings` error; it becomes a non-event exactly because the binding is stripped before the check.
A cycle among unreachable bindings likewise stops failing the build, which is correct — nothing constructs
them.

### What M7b.2 retains, and why home bindings are roots

The first cut prunes **dependency-module bindings only**: every home-module binding is emitted whether or
not anything reaches it. That is not timidity, it is the `graph.x` problem again — the app may pull any of
its own bindings out through an expression Wire never sees, so its own graph stays whole.

The part that is easy to get wrong: home bindings are not merely *retained*, they are **retention roots**.
Retaining a binding without retaining what it depends on emits a graph that reads properties which were
never declared, so the walk starts from the home set and pulls its dependencies in with it. Retention is
therefore closed under dependencies by construction, and the same reasoning covers the two edges this
graph cannot see for itself:

- **What a seed scope borrows.** A request-scoped binding's use of an app singleton is an edge in the
  *scope's* graph. WireGen already computes the genuinely-used borrow set for `.scopeCapture` ordering
  (`usedBorrows`), and passes it in as a retention root; without it, a dependency-module singleton used
  only inside a request scope is pruned out from under the scope that needs it.
- **What a testing variant borrows.** Variants are derived from the production app graph's retained set,
  so they cannot borrow what production never constructs — see below.

Measured on the motivating case, a 500-binding library where the consumer injects exactly one binding:
**1,525 lines, 501 stored properties and 501 eager constructions become 28 lines, 2 and 2.** That is the
part that carries the win.

**M7b.3 then drops the home half of that union**, and the declared roots carry the whole graph. It is the
milestone's one behaviour change, so it ships with a diagnostic rather than in silence: a pruned
home-module binding is reported, at every visibility, with the `allowUnused` fix-it and the property name
the developer would have read (`graph.reportBuilder`). A pruned `@Teardown` binding says so explicitly —
that intent is the least visible in the code, since a resource nothing reaches is never constructed and so
never torn down.

Reporting at every visibility is a departure from the dead-binding gate, and settled the same way the
public-key question was: visibility gates diagnostics about *consumption*, not about *construction*. A
public declaration may have consumers Wire cannot see; a public binding is still constructed by exactly one
thing, this graph, which is `internal` to its own module. The argument for silence — that a library target
has a graph full of unreached public bindings — is false in Wire's own pattern, where a Wire-aware library
applies no build plugin at all and is re-parsed by its consumer. See
[`VisibilityModel.md`](VisibilityModel.md).

The diagnostic supersedes the dead-binding warning for anything it reports: the two describe one fact and
this one says more. **M7b.4 makes that a fold rather than a suppression** — the first-order pass now stands
aside for every identity reachability *decided*, retained and pruned alike, and judges only what
reachability did not. That discharges the limitation `DeadBindingDiagnostics` recorded from 5α: a binding
consumed solely by another dead binding is unreachable too, so the fixed point comes by construction. It
also gives the subtlety for free — a package-local contributor folded into a `public` aggregate
nothing consumes is pruned and reported, while the aggregate itself stays silent.

The limitation survives in exactly one place: a **seed scope** is built unpruned, because the whole-scope
façade still constructs every binding in it, so within a scope the check is still first-order. Scopes are
pruned per routed root at emission instead (M5.4.6), and their graph-level fixed point arrives with M7d,
when that façade goes.

What the migration actually cost, on this repository: **seven annotations**. Six weak-cycle example
bindings and a library service the tests read straight off the graph, plus one in the `@GraphInputs`
harness. After them the golden recording is **byte-identical** — the corpus emits exactly what it emitted
before, which is the useful shape of this change: it does not shrink a well-formed app's graph, it makes
the app say which bindings leave through a door Wire cannot see.

### One open cross-cut: testing variants

Testing variants are derived from `aggregate.allBindings` — the *unpruned* discovered set — and borrow the
production `_WireGraph`'s properties for every app singleton they do not lift
(`syntheticSingletonBorrowBindings(from: defaultSingletons, inWireGraphOfType: "_WireGraph")`,
`TestingVariants.swift:106`). A binding pruned from the production graph but still borrowed by a variant
would emit `_wireGraph.<pruned>` and fail to compile in generated test code. **Settled in M7b.2 the cheap
way**: variants are derived from the production graph's retained set — a variant cannot need what
production cannot construct. The filter is narrowed to the external half (`productionRetains`), because
the retained set holds *resolved* identities and a blanket membership test would silently drop the generic
templates and pre-specialisation bindings a variant legitimately needs.

## Naming — use SE-0491 module selectors

> **Status: deferred**, tracked as [#355](https://github.com/tachyonics/swift-wire/issues/355). Working it through during iteration 7
> surfaced that `::` is *not* "mechanical once origin-module metadata
> exists." Two bindings both named `Logger` from different modules have the
> **same** textual `BindingIdentity` (`base: "Logger"`), so today they're a
> duplicate/ambiguity (7e names the conflicting modules; resolve with a
> key) — for `A::Logger` and `B::Logger` to *coexist* the identity model
> would have to incorporate the origin module, which also changes the
> duplicate check and consumer-side matching (does bare `@Inject var x:
> Logger` match `A::Logger`?). The residual genuine clash — a binding's
> simple name colliding with a *non-binding* type another activated module
> exports — Wire can't even detect structurally (it sees bindings, not all
> exports), so the only robust fix is *always-qualify every reference*,
> which churns all codegen output and still can't qualify nested generic
> arguments. Meanwhile the common case — non-clashing foreign types —
> already works via 7c's `import <module>`. So `::` gets its own design
> pass (identity model + matching + generics) when an adopter hits the
> clash; until then it's a known limitation (a binding whose simple type
> name collides with another activated module's exported type can produce
> an ambiguous reference in generated code — rename, or disambiguate with a
> key). The design direction below is retained for that pass.

In a single module the generated file lives in that module, so a bare
type reference resolves by Swift's normal rules (own-module types win by
local precedence). Compose `A` and `B` where **both define a `Logger`**,
and the composed graph genuinely references `A.Logger` *and* `B.Logger`
in one generated file — a real cross-module name clash. This is exactly
what [SE-0491 module selectors](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0491-module-selectors.md)
exist to resolve: emit `A::Logger` / `B::Logger` to pin each reference to
its module.

**The load-bearing insight: Wire can qualify correctly without name
resolution — the knowledge is *structural*, not semantic.** Wire ran
discovery on `A`'s sources, so it *knows* `A`'s `@Singleton`/`@Provides`
types are from `A` — not by type-checking, just by "I parsed `A`'s
files." A dependency reference resolves to a producer binding whose
origin module is likewise known. So `A::Logger` / `B::Logger` come
straight from per-module-discovery metadata.

This is why the earlier "Wire can't auto-emit `::` usefully" conclusion
(see [`OptionalMatchingAndCycles.md`](OptionalMatchingAndCycles.md)) was
**specific to single-module**: there, the only real ambiguity is two
*imported* types colliding, whose modules Wire genuinely can't determine
(no name resolution), so auto-qualifying buys nothing. Composition flips
it: the collisions are between modules Wire *discovered itself*, so it
has exactly the information needed.

**Prerequisite (the actual work, when the time comes):** the discovery
model must carry **origin-module metadata per binding**. It doesn't
today — a single module doesn't need it. That metadata is load-bearing;
the `::` emission is mechanical once it exists. (Note also: module
selectors disambiguate, they don't *normalize* — `A::Logger` and
`Logger` may be different types, so they stay distinct graph identities.
Module qualification is therefore a composition concern, not part of the
deferred typealias/collection-sugar normalization.)

**Prior art: lockjaw hit this exact wall.** Rust's lockjaw needs fully
qualified type paths for the same reason Wire does — comparing bindings
discovered across separately-compiled units — and its caveats page lists
"path resolution" first among three mechanisms it describes as "abhorrent
engineering practices that abuse undocumented behaviors of Rust." It had
neither a structural route to the answer nor a language-level spelling for
the emission. Both halves of the position above are the reply:
qualification is knowable structurally because Wire parsed the module
itself, and SE-0491 gives the emission a first-class syntax. Useful as
independent evidence that this problem is real rather than anticipated,
and that the structural route is the one that doesn't end in abusing the
toolchain.

## Visibility — the cross-module threshold

The sibling break, easy to forget. [`VisibilityModel.md`](VisibilityModel.md)'s
rule is "a binding must be at least `internal`," because the generated
bootstrap lives in the **same module** (a separate file). Under
composition a binding consumed by **another** module's composed graph
must be at least `public` (or `package`, within the same package) — the
consuming bootstrap can't reach `internal` declarations across the module
boundary.

So the declaration-too-private threshold becomes **context-dependent**:
`internal` for in-module consumption, `public`/`package` for
cross-module-consumed bindings. Whether a binding is cross-module-
consumed is, again, knowable structurally from the composition graph.

**Prior art: lockjaw took the other branch, and disowns it.** Rust has the
same break — a consuming crate cannot reach another crate's private items
— and lockjaw's answer was to **bypass** Rust's visibility rules, granting
itself access to symbols the language keeps private, precisely so users
wouldn't have to widen anything for cross-crate use. That is the second of
the three practices its own caveats page cites as a reason "you should not
use Lockjaw in any serious project." The threshold above is the honest
branch of the same fork: cross-module-consumed means ≥ `public` /
`package`, with no framework-privileged access path and nothing
undocumented relied upon. Worth keeping to hand, because "why do I have to
make this `public`?" is a predictable adopter objection, and the answer is
that the ergonomic alternative was built, shipped, and withdrawn by its
own author.

## Multibinding key references across modules

Iteration 5β's multibindings reference a key by name — `@Contributes(to:
X)` on a contributor, `@Inject(X)` on a consumer — and 5β validates that
`X` resolves to a discovered key declaration (a `CollectedKey` /
`MappedKey` / `BuilderKey` `static let`). That "must exist" check is
scoped to **the plugin's parse set**, which is one module today.

Composition widens the parse set, not the rule: a contributor in module
`B` may legitimately `@Contributes(to: A.serviceKey)` for a key declared
in `A`, and an app module may aggregate contributors from both. The
missing-key diagnostic stays "no such key *in the parse set*" and
loosens automatically as more packages are parsed — no special-casing.
Two constraints ride along, both already covered above:

- **Visibility** — the key declaration must be reachable from the
  contributing/consuming module (≥ `public`, or `package` within a
  package), the same cross-module threshold as any other binding.
- **Naming** — a key referenced across modules qualifies via SE-0491
  (`A::serviceKey`) from origin-module metadata, like any other
  cross-module reference.
- **`withOrder:` uniqueness** — iteration 5β requires globally-unique
  ranks per key (duplicate `withOrder:` is an error, keeping "ranked" a
  strict total order). That's fine in one module but hard to coordinate
  across independently-authored modules contributing to a shared key.
  **M1 decision (7f): keep the global-uniqueness rule** — a cross-module
  duplicate `withOrder:` is still an error (it already fires on the merged
  set), and cross-module *unordered* collection order is unspecified, so
  an order-sensitive cross-module collection must use `withOrder:`. The
  coordination relief — relax to ties-allowed with a documented tiebreak
  (origin module, then source location, both known structurally) or scope
  rank-uniqueness per contributing module — is deferred until an adopter
  hits it with independently-authored modules sharing a key.

This makes cross-module multibindings the *motivating* case for
composition: aggregating contributions a host module can't see is a
thing DI users reach for (plugin registries, feature-module roundup),
and it falls out of the parse-set framing without new mechanism.

## Single-key (`BindingKey`) tracking rides here too

Today Wire tracks *multibinding* keys (it must — the type lives on the
key) but not single `BindingKey`s (the type lives producer-side, so the
compiler enforces it via generated `_check`s). That asymmetry is fine
single-module, but composition already forces Wire to discover keys
across the parse set — and once it tracks single keys too, they become
**self-describing** (type + identity from one reference), which unlocks
consistent single/multi key diagnostics and a value-level scope-input
key. Tracking single keys is a **behavioural change** (Wire would begin
diagnosing them), so it's deliberately bundled here — landed *before*
library behaviour expectations lock in, and on the same key-discovery
work composition needs anyway. See
[`ScopeAndKeyModelEvolution.md`](../../Proposals/ScopeIdentityAndKeyModel.md).

## Summary

Composition is "the bootstrap now lives in / is consumed by a different
module," and it has a naming half and a visibility half:

| Concern | Single-module (today) | Multi-module (future) |
|---|---|---|
| Cross-type **naming** | bare references; own-module wins | `A::Logger` (SE-0491), qualified from origin-module metadata |
| Binding **visibility** | ≥ `internal` | ≥ `public` / `package` when cross-module-consumed |

Both are driven by the same structural per-module-discovery knowledge;
neither needs a Swift name-resolver. SE-0491 is the right tool for the
naming half — deferred because there's no composition yet, **not**
because it's useless. The toolchain floor it implies (consumers on
Swift 6.3+) is acceptable, since composition would itself be a new
feature.
