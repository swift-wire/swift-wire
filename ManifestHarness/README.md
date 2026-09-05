# Manifest harness (plugin-output gate)

Pins the mechanism manifest-based discovery would be built on: **a consumer's build command reading a
dependency's build-tool-plugin output.** The design note had recorded this as
impossible; a 2026-08 spike narrowed that to *impossible at plan time*, and
showed it works at command-execution time given a declared `inputFiles` edge.
That finding is what defers the manifest route rather than kills it, so it is worth a gate —
see [#338](https://github.com/swift-wire/swift-wire/issues/338).

```
ManifestHarness/
├── Library/    — a package whose target applies a manifest-emitting build plugin.
│                 ManifestGen scans the library's own sources and writes
│                 wire-manifest.json + a generated _WireExports.swift marker
├── Consumer/   — depends on Library, applies its own build plugin. That plugin
│                 derives the library's plugin-output path, declares it in
│                 inputFiles, and hands it to ConsumerGen, which bakes what it
│                 read into the built product
└── run-manifest-harness.sh — runs the gate
```

## What makes it a gate rather than a demo

Two undocumented behaviours are being pinned, and neither is API:

1. **The layout.** Nothing in `PluginContext` exposes another target's work
   directory, so the consumer reconstructs
   `<build>/plugins/outputs/<package-id>/<target>/<destination>/<PluginName>/`
   from its own path by string surgery. If SPM moves it, the read fails.
2. **The ordering.** Declaring that derived path in `inputFiles` is what makes
   llbuild schedule the producing command first.

The script runs two phases because **only the second is deterministic**, which
the first attempt at this harness got wrong:

- **Step 1 — clean build.** Proves the derived path resolves: a wrong path
  reads nothing and traps. The producer sleeps before writing, so an unordered
  consumer is *likely* to fail here — but scheduling can still let it win the
  race, and it was observed doing so. This phase alone would pass with the edge
  removed.
- **Step 2 — change the library, rebuild.** The manifest is derived from the
  library's sources, so adding a type changes its contents, and nothing but the
  declared edge would re-run the consumer's codegen. A stale manifest fails.
  Verified: deleting the `inputFiles` edge passes phase 1 and fails phase 2.

Step 3 repeats step 1 under the Swift Build backend, which keeps both the
layout and the ordering. It is opt-in (`MANIFEST_HARNESS_SWIFTBUILD=1`) because
a failure there is a different finding from a failure above.

## What it deliberately does not test

**Whether a consumer can know which dependencies emit a manifest.** It cannot —
a dependency package's plugin target does not appear in its `targets` at all, so
this harness's consumer hardcodes the one dependency it knows about, and the
producing plugin's name with it. That gap is the reason the manifest route is deferred, and it
is recorded in #338 rather than gated here, because there is nothing
to pin: an input nothing produces is a hard build failure, and no predicate
available at plan time answers the question exactly.

Neither package depends on swift-wire. The claim under test is a toolchain
capability, not Wire behaviour, so the gate should fail only when the toolchain
changes. That also keeps it free of the circular-dependency constraint the other
harnesses here work around.

## Running

```
./ManifestHarness/run-manifest-harness.sh
```

The root `swift-wire` package does not reference this directory, so
`swift build` / `swift test` ignore it entirely.
