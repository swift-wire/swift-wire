# Module-scoped bindings — design proposal

> **Status:** proposed, November 2026. Nothing here is built and no tracking issue is filed yet. The
> spec deltas will land with the first implementation step, as `openspec/README.md` requires. This
> proposal extends the shipped design in
> [`MultiModuleComposition.md`](../Documentation/Notes/MultiModuleComposition.md) and changes two of
> its rules: which access level a library binding needs, and where a library's generated code lives.
> Three spikes ran on Swift 6.4.1, under both the `swiftbuild` and `native` build systems, and on
> Xcode 27.0. Claims they measured say so; the rest is argued.

## What this is for

Today every binding in a composed graph is an application global. The root target's plugin re-parses
each Wire-aware library it depends on, and all generated code lands in the root. Two rules follow
from that:

- **A library binding must be `public`,** or `package` from a sibling target, even when nothing
  outside the library uses it. The root's generated code constructs it, so the root must be able to
  name it. A library's private wiring therefore becomes public API.
- **Nothing generated can live beside the code it serves.** An adapter that wants to emit a type into
  a library, next to the controllers that use it, can't. The plugin runs only for the root.
  wire-open-api hit this directly: its `SuccessStatus` enum has to be hand-written next to the
  controller, because a generated one would land in the app, where a library's controllers can't see
  it.

NestJS draws the line elsewhere. A module declares providers, imports and exports, and an importer
reaches only what is exported. This proposal gets the same encapsulation without moving resolution
out of the root. The Swift access level of a binding or key is its visibility. Each library generates
its own code. The root still resolves, validates, prunes and schedules the whole graph, as it does
today.

## The visibility model

**Access levels are the boundary.** There is no `@Exported` marker or module declaration type. A
binding or key is visible outside its module exactly when Swift says it is. The compiler enforces
the boundary, so it can't drift from what Wire believes.

- **An `internal` binding** may be consumed only inside its module. That rule is new. Today an
  internal library binding is a build error the moment it is composed (`visibility-and-access`, "A
  binding composed from a sibling module must be at least `package`"). Under this proposal it is
  legal, and the root constructs it through the library's generated maker (see *Tier 1*).
- **A `public` binding** may be consumed anywhere, as today.
- **A `package` binding** may be consumed by sibling targets, as today.

**Keys follow the same rule, in two cases:**

1. **A key at `package` access or below is closed.** Nothing outside its module can name it, so
   `@Contributes(to:)` from outside doesn't compile. The module's own build sees every possible
   contributor, so it can collate the key and run every check `Multibindings.md` describes: ordering,
   duplicate map keys, empty and unused keys. The checks fire in the library's own build, not only in
   a consumer's. "I need a known, complete contributor set" becomes a declared property of the key.
   Today it is only advice about which target to declare the key in.
2. **A `public` key is open and collates at the root,** over the union of contributors across the
   composed modules, as today. **A non-public binding can't contribute to a public key.** The
   diagnostic: "`MetricsEmitter` contributes to the public key `App.services` but is `internal`; make
   it `public`, or contribute to a key at `package` access or below."

The second half of case 2 is a policy choice, not a mechanical limit. Tier 1's makers could build an
internal contributor and hand it to the root behind a public protocol. The rule holds anyway: a
contribution to an open extension point is part of the module's public behaviour, and its access
level should say so.

### `package` keys and the package layer

"Closed" is exact for `internal`, not for `package`. A `package` key declared in target `A` can take
contributions from sibling target `B`. `B` imports `A`, so `A` is built before `B`'s contributions
exist, and `A` can't collate the key. Something in the package that depends on every contributor has
to.

This case is rare. A library opts into package-level wiring deliberately. It is configured explicitly
rather than inferred from the target layout:

- **Applying `WirePackageLayerPlugin` to one target makes it the package's layer.** That target
  collates the package's `package` keys and resolves `package` bindings across its targets. To the
  root it looks like one more module. Applying a plugin in the manifest is the configuration, because
  SwiftPM build plugins take no arguments. This matches how `ComposingAcrossModules.md` treats
  activation: a compile-time fact whose home is the manifest.
- **The layer checks itself.** It must depend on every target that contributes to a `package` key or
  consumes a `package` binding across targets. One layer is allowed per package. Package-level wiring
  across targets with no layer is a diagnostic naming both fixes: apply the plugin, or make the key
  `internal`.
- **Without a layer, a `package` key behaves as `internal`,** collated in its declaring target from
  that target's contributors. That's the default, and most packages never leave it.
- **The consumer side has one rule.** If an app activates `A` but not the layer, the package-scope
  graph is never composed. The root can see this, because `A`'s descriptor names its layer: "`A`'s
  package bindings are composed by `StoreLayer`; depend on the `Store` product, which vends it."
  By convention the package's library product vends the layer.
- **When the app is in the package,** it already depends on everything and acts as the layer, with
  no plugin needed.

**Measured limit:** a plugin sees its whole package (`context.package.targets`) only when that package
is the root. In a dependency build, `targets` is pruned to what the products reach. So the layer's
self-check runs in the author's own build and CI, not in a consumer's. That's sufficient: a target no
product reaches is never built for a consumer, so its contributions don't exist there.

## Getting the library's surface to the root

The root has to know each library's bindings, keys and contributions. There are three ways to get
them there. The spikes settled the choice.

1. **Read the library's plugin output.** Ruled out by measurement. No PackagePlugin API exposes
   another target's outputs: `pluginGeneratedSources` and `pluginGeneratedResources` were empty for
   every target, including one with outputs on disk. The path has to be guessed from the output
   layout, and ordering behaved differently between the two build systems. Only "declared input plus
   a target dependency" ordered correctly under both. This is the M7a predicate problem from
   [#338](https://github.com/swift-wire/swift-wire/issues/338) again: SwiftPM can't tell a plugin
   whether a dependency applied a plugin at all.
2. **Re-derive from source.** Chosen. The root runs the same discovery over the library's sources that
   the library's own plugin ran, which is what happens today. The spike confirmed a plugin can read the
   sources of direct, transitive and other-package dependencies, plus non-Swift files. That includes
   resources, undeclared files, and an `exclude:`d `openapi.yaml` read by path. A 500-file dependency
   re-parses in about 50 ms (#338).
3. **A committed manifest,** written by a command plugin and checked by the library's build like a
   golden file. Held in reserve for libraries shipped without sources. Otherwise it adds a step to the
   development loop and puts generated state under version control.

**The hash witness catches drift.** If the library's plugin and the root's re-derivation disagree, the
build should fail at one clear point, not through scattered "no member" errors. The library emits a
witness named after a hash of the surface it generated:

```swift
@_spi(WireGenerated) public enum _WireModule_OrdersAPI {
    public static let surface_3fa9c1: Void = ()
}
```

The root's generated code references `_WireModule_OrdersAPI.surface_3fa9c1`, using the hash it
derived. A mismatch fails with "type '_WireModule_OrdersAPI' has no member 'surface_3fa9c1'". The
message is ugly, but the case is rare. SwiftPM resolves one swift-wire version per graph, so both
plugins come from the same package.

## Tier 1: generate in each module, resolve at the root (proposed)

Each Wire-aware library runs a plugin that emits:

- a **maker** for each binding the root can't name;
- a **handle** type for each such binding's value;
- the **surface witness**;
- whatever adapters need generated beside their code (wire-open-api's conformers and `SuccessStatus`,
  below).

The root's plugin works as today. It discovers across the closure, validates, prunes, schedules
construction and emits teardown. Where it would construct an internal library binding directly, it
calls the maker instead.

**`@_spi` keeps the makers off the public API.** This was measured in a spike:

```swift
// In library A. The author's binding stays internal:
struct Cache { let size: Int }

// Emitted by A's plugin:
@_spi(WireGenerated) public struct _WireHandle_Cache: Sendable { let value: Cache }
@_spi(WireGenerated) public enum _WireModule_A {
    public static func makeCache(size: Int) -> _WireHandle_Cache { .init(value: Cache(size: size)) }
}
```

- The root's generated file does `@_spi(WireGenerated) import A`, calls the maker, and works.
- A plain `import A` gives "cannot find '_WireModule_A' in scope".
- Built with library evolution, `A.swiftinterface` contains no mention of the makers, and
  `A.private.swiftinterface` contains them.

The makers stay out of the library's public interface, its documentation and autocomplete.
swift-openapi-generator uses the same mechanism for its own generated surface
(`@_spi(Generated)`). Across sibling targets, `package` access does the same job with no SPI.

**What it costs:**

- **A hidden ABI surface.** The symbols are in the binary even though the interface hides them.
  `@_spi` is underscored: widely used, including by swift-openapi-generator, but not formally
  supported.
- **Unused makers.** A library compiles makers for bindings a given root then prunes away. The cost
  is compile time only: reachability still decides what is constructed.
- **Libraries now apply a plugin.** Today a Wire-aware library applies none. Under tier 1 a library
  needs the plugin only when the root would otherwise have to name something it can't. The root knows
  that from the library's source: a non-public binding, or an adapter type to generate. A library
  whose bindings are all public keeps working unchanged. If the plugin is missing, the root's
  reference to `_WireModule_A` doesn't compile. The error is loud and local, but generic. As in #338,
  the root can't detect the missing plugin at plan time.
- **Size:** about 1.5–2.5k lines, estimated by reading the generator. Resolution, scheduling and
  validation stay as they are. The new work is in discovery (visibility), emission (makers, handles,
  witness) and the plugin split.

**What it keeps:** every diagnostic Wire has today, with module names added. Reachability pruning,
`@Replaces`, testing variants, seed scopes and construction scheduling are all unchanged, because the
root still sees one whole graph.

**Libraries get earlier feedback.** A library's own build now checks its closed keys and every check
it can complete without the root. It can't treat an unbound injection point as an error, because the
root may supply it. That stays a consumer-side diagnostic, as today. *Open questions* covers declaring
module inputs explicitly.

## Tier 2: resolve each module (the alternative)

Each module resolves its own graph and the root composes resolved modules, as NestJS does. A
prototype was built and run in debug and release. It shows that the mechanics work:

- **Interleaved construction across the boundary.** The module builds its first stage, the root
  builds what that stage exports to it, and then the module builds its second stage. A shared
  singleton is constructed once.
- **Teardown in correct reverse order,** including concurrent appends. Every stage gets one shared
  teardown list, and no extra protocol is needed.
- **Stages derived without knowing the consumer.** A module groups bindings by the inputs each needs.
  It is argued, not tested, that this never invents a false cycle. A single opaque `init(inputs:)` per
  module **does** produce a false cycle, so stages are required.
- **Cross-module cycle reports that don't leak private names:**

  ```
  error: dependency cycle crosses the boundary of module(s) ["A"]:
      App.AppSettings -> needs 'Clock', exported by A stage s1
        -> inside A: export 'Clock' depends through 1 private binding(s) [A#5b07] on requirement 'any Settings'
        -> 'any Settings' is supplied by App.AppSettings
  ```

- **A small descriptor:** `{module, stages: [{id, requires, after, exports, contributes?, async?,
  via?}]}`.

What stays hard are design questions, not mechanics:

- **Silent inputs.** A library's unbound injection point becomes an input to its graph, so a typo or
  a forgotten binding stops failing the library's own build. The fix is declaring inputs explicitly,
  and `@GraphInputs` is the natural place. That adds ceremony to every library.
- **Pruning regresses.** Today's reachability takes a 500-binding library from 501 constructions to 2
  (`MultiModuleComposition.md`). A stage constructs everything in it.
- **Generics.** The root can't ask a module for a specialisation of an internal generic binding the
  module never emitted.
- **`@Replaces`** of a binding a module consumes internally forces extra stage boundaries.
- **Seed scopes and testing variants** each need their own stages.
- **Parallelism.** An app binding can wait on an unrelated slow binding in the same stage. The
  prototype measured 315 ms against an ideal of about 210 ms. A futures-based shape recovers it, at
  213 ms, but turns a missed cycle into a deadlock at run time.
- **Size:** about 3–5k lines, estimated, plus the design work above.

### What tier 2 would need: a resolve-first view

Most of tier 2's costs have one cause. A module is generated without knowing its consumers, which in
SwiftPM it can't. A library's plugin sees only its own package once that package is a dependency. One
build of a library serves every root in the package, including test targets. No build plugin can write
into a dependency's checkout.

A step outside the build gets around this. A command plugin (`swift package wire-resolve`) resolves
the whole program, writes a view under the root, and each library's plugin generates from its slice of
the view. That gives each module its reachable set, its requested specialisations and replacements,
and stage splits shaped by its real consumers: four of the costs above. A spike measured how it
behaves:

- **Finding the view works** by walking up from the plugin's `pluginWorkDirectoryURL` to the first
  `.wire/`. That held for a git checkout, a `path:` dependency, both `swift package edit` modes,
  `--package-path`, and SourceKit-LSP's index build. Walking up from `package.directoryURL` is wrong:
  it fails for path dependencies, and silently picked up a dependency's own `.wire/`. An environment
  variable reaches plugins on both build systems as an override. Plugins see the whole shell
  environment.
- **The view as a declared input** regenerates and recompiles the library when it changes, and the
  next build is a no-op. A missing view is a generic "Build input file cannot be found".
- **The command plugin** runs with `--allow-writing-to-package-directory` and sees all the root's
  targets, tests and executables included.
- **A stale view fails the build** only when the check is a build command with the sources as inputs.
  A plan-time `Diagnostics.error` works under `swiftbuild` only. `native` doesn't re-run plugins on a
  source edit, so a stale view passed silently there.
- **Xcode with DerivedData in its default location** finds no view, and the build **succeeds without
  one**. This was inferred from a run with DerivedData moved outside the project, not tested directly.
  The environment-variable override fixes `xcodebuild` from a shell, but not GUI builds. A
  `--scratch-path` outside the root fails the same quiet way.
- **SourceKit-LSP runs the plugins,** but a stale or missing view shows up only in its log, never as
  an editor diagnostic.

Each target can check only its own freshness, which avoids a closure walk Xcode can't do. Hashing a
target's binding surface rather than its raw source limits re-resolves to edits that change bindings.
Even so, the inner loop permanently becomes edit, build fails with "run wire-resolve", resolve, build.
Today it is edit, build. Under tier 1 the view buys only the skipped unused makers, so it isn't
proposed there.

## Recommendation

**Build tier 1 with `@_spi`.** It delivers the encapsulation and the generated-beside-the-code
behaviour this proposal is for. It keeps every existing guarantee and diagnostic. It needs no step
outside the build, and it works wherever today's model works. Its costs are a hidden generated ABI
surface and some compile time spent on unused makers.

Keep tier 2 on record with the costs measured above. It is worth revisiting only if strict per-module
encapsulation or separately built module graphs become goals in their own right. If it is revisited,
the resolve-first view is how to remove its gaps, and the inner-loop cost comes with it.

## Consequences for wire-open-api

This section belongs to wire-open-api to decide. It is recorded here because the swift-wire design
determines what is possible.

**Generating `SuccessStatus` doesn't wait for any of the above.** A second plugin beside
swift-openapi-generator's, on a library target, was measured to work. It emitted:

```swift
extension Operations.CreateOrder {
    enum SuccessStatus: Sendable, Hashable {
        case ok(Operations.CreateOrder.Output.Ok.Headers)
        case created(Operations.CreateOrder.Output.Created.Headers)
    }
}
```

It compiled with the generator's `accessModifier` set to `public` and to `package`, and was used from
a controller in the library and from an app. The order in `plugins:` made no difference. When one
plugin read the other's output as a declared input, ordering followed that input, not array position.

**The one trap is `package`.** The generated code then does `package import OpenAPIRuntime`, so a
plain `import OpenAPIRuntime` written by hand in the same module fails with an ambiguous implicit
access level. It must be written `package import`.

This would replace the author-declared enum from
[wire-open-api#99](https://github.com/swift-wire/wire-open-api/pull/99), and the plugin check that it
matches the document, with a generated one. It needs no swift-wire change. It hasn't been filed as an issue yet.

**Under tier 1, a document can span modules with partial conformers.** wire-open-api's
`controller-collation` spec already supports one document's controllers across modules: one
`APIProtocol` conformer, in the app. That conformer has two jobs. It lets the compiler check that the
operation set adds up. It is also what swift-openapi-generator's generated server is generic over,
so whatever serves an operation needs *some* complete conformer.

Under tier 1, each module emits its own:

- **A partial conformer,** with real forwarders for the operations its controllers implement and
  stubs for the rest (`throw WireOpenAPIOperationNotMounted("listOrders")`).
- **A contributor that mounts only its own operations,** through a generated server over that
  conformer. Operations are mounted one at a time already, so a stub is never reachable: no route
  leads to it.

The root's plugin has every module's surface and the document. It checks that each operation is
implemented exactly once across the composed modules, that document-level settings agree, and that
no route is duplicated. The diagnostics improve on "Type does not conform to protocol
'APIProtocol'": "`listOrders` in `OrdersAPI`'s document is implemented by no module this app
composes", or "…by both `OrdersAPI` and `Admin`", naming the controllers.

What this gives:

- **Controllers, forwarders, the conformer and `SuccessStatus` all stay `internal`.** Only the
  contributor is public, because it contributes to the public `WireMVCKeys.routeContributors`.
- **A module can be served and tested without the app.**
- **Each module's per-request conformer holds only its own controllers' request-scoped subjects.**
- **Completeness becomes a policy rather than a type-system fact,** so a partly implemented document
  could later be allowed deliberately.

What it costs:

- **Completeness is only as strong as the root's check.** A bug in the check shows as a missing route,
  not a crash, because stubs are unreachable by construction.
- **One generated server per document and module, not per document.** Document-level settings must
  agree across modules, which the root checks.
- **Contributor proxy names gain a module component.**
- **The duplicate-`operationId` rule moves** from a check inside one group to the root's cross-module
  check.

## Open questions

- **Declared module inputs.** Tier 1 leaves an unbound injection point in a library as a
  consumer-side error, as today. An opt-in declaration through `@GraphInputs` would let a library
  check itself fully. Tier 1 doesn't need it; tier 2 can't do without it.
- **`@Replaces` reach.** Under the access-level model it replaces only what it can name. That means
  public bindings, or internal ones from a test target that uses `@testable import`. Whether a
  `@testable` replacement of an internal library binding is supported should be decided explicitly.
- **Generic makers.** A maker for an internal generic binding, `makeBox<T>() -> _WireHandle_Box<T>`,
  is expected to work, since the handle only wraps the internal type. It wasn't spiked.
- **Teardown through handles.** A maker for an internal `@Teardown` binding has to hand the root a
  teardown action alongside the handle. The shape is unsettled.
- **Ordering across packages.** `withOrder:` ranks on a public key are still one global namespace.
  Two independently written libraries can collide, and neither author can fix it. That's true today;
  closed keys only make it rarer.
- **Seed scopes across modules.** Can a `@Scoped(seed:)` scope declared in one module be entered from
  a route in another? With root resolution the mechanics are unchanged, so the open part is whether a
  scope seed's access level governs it.
- **Xcode project targets.** In the spikes, `XcodeTarget.dependencies` came back empty for a real
  target-to-target dependency. Today's plugin finds libraries through `target.dependencies`, so this
  probably already fails in an Xcode project. That's inferred, not tested. The proposal assumes
  SwiftPM targets, and Xcode-project support should be stated, not implied. Inside Xcode, a dependency
  package's plugin also reported `origin == .root`.

## Prior art

- **NestJS modules** declare `providers`, `imports` and `exports`, and resolve per module. This
  proposal takes their visibility model, using Swift access levels in place of `exports`. It doesn't
  take their resolution model; tier 2 is what taking it would cost.
- **Dagger** generates a factory beside each `@Inject` class, in the class's own package, and the root
  component calls those factories. That is tier 1's shape: code generated where the binding is
  visible, resolution in one place.
- **lockjaw** reached across Rust's crate privacy to the same end, and its author calls that
  unsupportable (`MultiModuleComposition.md`, *Visibility*). `@_spi` is the language's own mechanism
  for a hidden surface, and the generated code uses it only through an explicit `@_spi` import.
