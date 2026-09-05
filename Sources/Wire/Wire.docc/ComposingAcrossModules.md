# Composing across modules

A library ships bindings; depending on it composes them. What that activates, what it costs, and
what the plugin checks across the boundary.

## Overview

A Wire-aware library declares `@Singleton`s, `@Provides` and `@Contributes` exactly as an
application does. Nothing else is asked of it — no registration file, no opt-in marker, no
module initialiser. A library is Wire-aware because it depends on the `Wire` product, which any
target declaring a binding must do in order to `import Wire`.

You **activate** such a library by depending on it. The dependency is the activation.

```swift
// In the library — depending on `Wire` is what makes it composable.
@Singleton
public struct SQSClient {
    @Inject public init(url: URL) async throws { … }
}

// In your Package.swift.
.target(
    name: "MyApp",
    dependencies: [.product(name: "WireSQS", package: "wire-sqs")],
    plugins: [.plugin(name: "WireBuildPlugin", package: "swift-wire")]
)

// In your source — no activation directive.
@Singleton
struct WorkerService {
    @Inject var sqs: SQSClient
}
```

## Why the manifest rather than a call

Activation is a compile-time fact. The plugin has to know the activated set before it generates
anything, so that it can validate the whole graph and collate multibindings at build time — it
emits exactly one graph per target, so there is one activation set per target rather than a
per-call choice. The manifest is where that fact already lives, name-checked by SPM.

Both halves are visible in manifests: yours says which libraries you pulled in, and each
library's own dependency on `Wire` is what makes it composable at all. Nothing hidden or
transitive activates.

## Direct dependencies only

The rule is uniform: **you activate the Wire-aware libraries your target directly depends on.**

- **Same-package siblings and external packages are identical.** A direct dependency is a direct
  dependency, whether it is a sibling `.target` or a `.product` from another package.
- **Transitive dependencies are not activated.** To compose a transitive library's bindings, add
  it to your own `dependencies` — which you would have to do anyway to `import` it. So
  "transitive activation is explicit" falls out for free, and your manifest stays a complete
  statement of what is composed.

The plugin still detects the *missing* case: if an activated library references a binding
declared in a package you do not depend on, that is a missing-binding diagnostic naming the
library, with a fix-it pointing at the dependency to add.

## Activation is all-or-nothing

An activated library contributes every one of its bindings: singletons available for injection,
providers available, contributions joining their collections. A library is a unit, and depending
on it takes all of it.

The alternative — partial activation — has a silent failure mode worth avoiding: taking a
library's singleton while its contribution partner stays invisible, with the type system happily
blessing a graph that is missing behaviour the library was designed to provide as a coherent
whole.

Note that "every binding" is not "every binding built". Only what your roots reach is emitted —
see <doc:WhatGetsBuilt>.

## Validation across the boundary

Within the activated set, validation is exactly what it is in one module. Every injection point
must be satisfied somewhere across the union of activated libraries and your own bindings. If a
library's binding needs a `URL` and you have not bound one, the diagnostic names the library and
the missing binding. If two activated libraries both bind `Cache`, you disambiguate with a key,
the same as within a module.

A binding referenced across a module boundary must be `public`, or `package` within a package.
The in-module floor stays `internal`.

## Substituting a library's binding

Two mechanisms, at different scales. Depend on a different library — a mock package instead of
the real one — and the production bindings are simply absent from that graph. Or keep the real
library and supersede one of its bindings with [`@Replaces`](doc:Replaces()), which is exactly
the cross-module case that attribute exists for: a same-module duplicate is a plain conflict,
so `@Replaces` requires the binding it replaces to live elsewhere.

Depending on both a library and its mock is a duplicate-binding error, which is the intended
outcome — pick one, or disambiguate with keys.
