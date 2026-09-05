# How Wire compares

Where Wire sits among Swift's DI libraries, what it deliberately does not do, and when one of
the others is the better answer.

## Overview

Wire's distinguishing claim is not "compile-time DI" — several Swift libraries offer that. It is
a compile-time graph that **third-party packages can extend**, applied to server-side Swift.
Everything below is downstream of that.

## The technical axes

| Library | Compile-time graph | Linux support | Macros | Scoping | Forces existentials? |
|---|---|---|---|---|---|
| swift-wire | Yes | Yes | Yes | Seeded scopes, type-checked | No |
| SafeDI | Yes | Untested | Yes | Hierarchical, not framework-aware | No |
| Needle | Yes | Builds; codegen tool not packaged for Linux | No (codegen) | Hierarchical | No |
| swift-dependencies | No (runtime) | Yes | No | Task-locals, not statically scoped | n/a |
| Swinject | No (runtime) | Yes | No | Manual | n/a |

The table understates the structural gap, though. None of these publishes a macro-based
extension contract for third-party framework integrations. Needle has internal pluginised
components but no public extension surface. SafeDI is a closed system: it knows its own concepts
and nothing else, so a new framework integration means changing SafeDI. swift-dependencies and
Swinject work at the value-resolution layer, with no build-time graph for a package to
contribute to. Retrofitting an equivalent into any of them would be a redesign rather than a
feature — which is the argument for Wire existing, and the thing to weigh it on.

## The mental-model question

swift-dependencies is the closest comparison along a different axis, and the honest split is by
how a team already thinks:

- **iOS or SwiftUI, TCA-shaped.** Dependencies looked up at the point of use. swift-dependencies
  fits that model and is the faster path to working DI.
- **Spring or Dagger-shaped.** A build-time graph validated as a whole, with dependencies wired
  at construction. That is Wire.

Both are legitimate. Pick per service, not per organisation, and do not mix them in one.

## Different layer, not just a different library

Wire is often compared against things that are not its competitors. Web frameworks own the
runtime — request handling, the network, the service group. Capability-abstraction libraries
define what an individual dependency looks like, so a database or HTTP client is substitutable.
Wire validates and composes the *graph* of those dependencies at build time.

The three compose: an application uses a web framework as its runtime, depends on capability
abstractions for its building blocks, and uses Wire to wire them together.

## Deliberate non-goals

Not a roadmap — these are decisions, and knowing them is part of deciding whether Wire fits.

- **No service-locator escape hatch.** There is no global resolve-from-anywhere entry point. If
  a component needs to resolve, it is passed what it needs explicitly. This is why introspection
  returns descriptions rather than values.
- **No runtime registration.** The graph is fixed at build time.
- **No container hierarchy.** Containers are flat. Parent/child models bring override semantics,
  scope interaction and profile inheritance with them, and none of that has earned its keep for
  server cases: multi-tenancy is a scope problem, profile selection picks one of several flat
  containers at startup, and plugins compose at the package level.
- **No fine-grained override across containers.** Selecting a [`@Container`](doc:Container())
  swaps the whole graph rather than overlaying the default. Substituting one binding is what
  [`@Replaces`](doc:Replaces()) is for.
- **No transitive or hidden activation.** Only the Wire-aware libraries your target directly
  depends on are composed — never a dependency of a dependency, and never a bare `import`. The
  surprise this rules out is classpath autoconfiguration, where a transitively-dragged package
  starts contributing behaviour; here the activated set is your manifest, and a conflict it
  introduces is a compile error rather than a silent behaviour change.
- **No compatibility layer with swift-dependencies.** Different models; pick one per service.
- **No SwiftUI integration.**

## When to use something else

Worth being blunt about, and the fuller version is on the ``Wire`` landing page. A deep, nested
dependency tree with contextual state at many levels is SafeDI's model rather than this one.
Genuinely heterogeneous lifetimes that resist scope categorisation are better served by runtime
resolution. If dependency overlay for tests and previews is the dominant concern and the graph
is small, a library designed for overlay is less machinery.

Wire earns its cost when the graph is large enough that a missing binding at runtime is a real
risk, and when compile-time validation and Linux support both matter.
