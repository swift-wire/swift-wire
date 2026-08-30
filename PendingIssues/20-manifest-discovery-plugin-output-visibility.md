# 20 — M7a's manifest route works; a consumer cannot tell which dependencies emit one

**Repo(s):** swift-wire (+ upstream: swift-package-manager)
**State:** 🟡 Deferred by decision — the mechanism is proven, the cost is known, and the clean form is held
by an upstream API gap
**Blocks:** nothing. M1's re-parse path is correct and costs ~50 ms for a 500-file dependency; M7b does not
depend on this.
**Surfaced by:** starting M7 and spiking M7a directly, rather than inheriting the note's 2026-07 conclusion.

## What changed

`Documentation/Notes/MultiModuleComposition.md` recorded that "there is no plugin-generated export *file* a
consumer can read." That is **true of plan time and false of execution time**, and the distinction is the
whole issue. A 2026-08 spike (two packages: an external library whose target applies a manifest-emitting
build-tool plugin, and a consumer applying its own) probed three routes:

- **A — the dependency's `sourceFiles` lists the generated manifest.** No: `["Service.swift"]`, committed
  sources only. This is the 2026-07 finding, and it stands.
- **B — read the manifest at plan time from a derived path.** No, and never: every build-tool plugin's
  `createBuildCommands` runs before any command executes, so a clean build always reports `exists=false`.
- **C — declare the derived path in `inputFiles` and read it at command-execution time.** **Yes.**

Route C is a real ordering edge, not scheduling luck. With the producer sleeping 5 s and no declared edge
the consumer read `MISSING` — a race. With the path declared as an input, llbuild ordered the consumer's
codegen after the producer and it read the manifest. Verified under **both** build backends (native and
`--build-system swiftbuild`), with identical layout
`.build/plugins/outputs/<package-id>/<target>/<destination>/<PluginName>/`. Incremental propagation is
correct: changing the library's manifest content regenerated the consumer's graph, and a second no-op
rebuild did nothing.

So M7a is **possible**. It is deferred on cost, not on feasibility — and this entry exists so the spike is
not re-run to rediscover that.

## The blocker: the consumer must predict, at plan time, which dependencies emit a manifest

Route C's edge is declared during `createBuildCommands`. Declaring an input that nothing produces is a hard
build failure:

    error: couldn't build _WireDiscovered.swift because of missing inputs: …/wire-manifest.json

And **SPM exposes no signal for plugin application**. In the spike, the dependency package's `targets`
returned only `SpikeLib` and `ManifestGen` — the plugin target `LibManifestPlugin` **does not appear at
all**, so the consumer cannot see that the target applies a plugin, or even that the package contains one.
Grepping the `PackagePlugin` interface confirms nothing on `Target` or `Package` exposes plugin usages.
This is Spike-1's check (4), still unavailable.

Every inferable predicate answers a *different* question — "does this library declare bindings?" — and the
two diverge exactly when an author declares bindings and omits the plugin:

| Predicate | Available? | Where it breaks |
|---|---|---|
| Committed `_WireExports.swift` marker | ✓ (today) | Proves intent, not plugin application; and it is the file the retirement plan deletes. |
| Depends on the `Wire` product | ✓ verified readable | Over-fires: a library depending on Wire only for `Lazy<T>`/`BindingKey` emits no manifest. |
| Read the dependency's `Package.swift` as text | ✓ verified — the plugin sandbox permits the read | Manifests are Swift code; a substring hit does not say *which* target applies the plugin, and conditional or computed target lists defeat it. Fails **unsafe**. |
| Scan the dependency's sources for binding annotations | ✓ | Detects declaration, not emission. |

**The asymmetry bounds the risk.** A false negative falls back to re-parsing that dependency's sources —
today's behaviour, correct, only slower. A false positive is a hard build failure. So any predicate must be
conservative and the re-parse path must be retained: M7a can only add a fast path *beside* source
re-parsing, chosen per dependency, never replace it. Both feed the same `[DiscoveredBinding]` seam the note
already identifies, so this is structurally fine — but "the consumer reads manifests instead of re-parsing"
overstates what is reachable.

## The one closure, and why it is not taken

The gap can be closed producer-side, with a trick Wire already uses. A missing `@Factory` plugin is a loud,
local compile error (`cannot find type '_WireFactory_<key>'`) because the macro expansion references a
plugin-generated symbol. Applying that to bindings — expanding to a reference to an anchor symbol only the
contributor plugin emits — makes *declares bindings ⇒ applies plugin ⇒ emits manifest* a compiler-enforced
invariant in the library's own build. The consumer's predicate then collapses to the cheap annotation scan
and false positives stop existing, because a library violating the invariant fails its own compile anyway.

It is not taken because it costs the property the retirement plan is built on: **every** Wire-aware library
would have to apply the contributor plugin, so a pure-`@Singleton` contributor no longer "declares nothing."
It also couples macro expansion to a plugin-generated symbol for every binding rather than only for
`@Factory` templates. That is a surface regression traded for a build-time win measured below at ~50 ms.

## What it would buy, measured

WireGen re-parsing a synthetic 500-file dependency, steady state: **50 ms** (~0.1 ms/file; 0.63 s cold). A
5,000-file dependency would be ~0.5 s — and the plugin already warns about `ARG_MAX` at that size
(`Plugins/WireBuildPlugin/WireBuildPlugin.swift:117`), so argv bites first. Re-parsing is also
embarrassingly parallel today: it reads committed sources and waits for nothing, where route C introduces a
build-graph serialization point.

Against that, route C costs a path derived by string surgery over an undocumented build-directory layout —
which is the lockjaw "abuse undocumented toolchain behavior" hazard this note twice cites as the branch Wire
does not take — plus a resource side effect: the emitted `wire-manifest.json` was copied into
`SpikeLib_SpikeLib.bundle`, so the library grows a resource bundle it did not have.

**The same 500-file measurement is M7b's case, stated positively.** A consumer injecting exactly *one*
binding from that dependency generated 500 stored properties, **500 eager constructions** and 1,522 lines.
That is the cost worth removing, and it is the reason M7b leads.

## The upstream ask

Either removes the need for the derivation and the predicate. The second is preferred.

**1. swift-package-manager — expose plugin usages on `Target`.** Something in the shape of
`target.pluginUsages: [PluginUsage]`, letting a consumer's plugin ask whether a dependency applies a named
plugin. This makes the predicate exact without any producer-side surface change, and it is the smaller ask.

**2. swift-package-manager — first-class plugin-output exports.** A way for a target to declare that a
build-tool plugin's outputs are readable by dependents, with SPM supplying the path and the ordering edge
instead of the consumer deriving both. This is what route C emulates by hand; making it supported removes
the undocumented-layout dependency *and* the missing-input failure mode, and it generalises past Wire —
every codegen tool that wants a per-library sidecar has this problem.

**Why #2 is preferred:** #1 makes the guess exact but leaves Wire deriving `.build/plugins/outputs/…` paths
by string surgery and relying on llbuild's undeclared-but-observed ordering semantics. #2 makes the whole
route supported.

## Not to be confused with

**The `.swiftinterface` third route** the note raised as an open question. That is now **answered: no.**
Synthesizing an interface from `WireHarnessLibrary`'s binary `.swiftmodule` works without library evolution
and carries fully-qualified types (`Wire.BindingKey<WireHarnessLibrary.ExternalService>`), but the macro
attributes are gone — no `@Singleton`, `@Inject` or `@Provides`, only post-expansion API. It cannot supply
binding data, and reading it would serialize the consumer's codegen behind the dependency's full compile,
which is strictly worse than route C.

**Retiring `_WireExports.swift`**, which this does *not* block — see the note's retirement plan and M7b. The
"depends on the `Wire` product" predicate is unusable here but adequate there, because the failure mode
flips: over-firing costs a wasted scan that yields no bindings, not a build failure.
