# Introspecting the graph

Every generated graph can describe its own wiring, without reflection and without a runtime
container to ask.

## Overview

Wire is compile-time DI, so the wiring is fully known at codegen. ``Introspectable`` is how a
graph hands it back: the plugin emits `introspect()` on every graph struct and conforms it, so a
facade can accept `some Introspectable` without naming the concrete, internal graph type.

```swift
let model = graph.introspect()
for binding in model.bindings {
    print(binding.type, binding.location.file, binding.location.line)
}
```

## The model

``WiringModel`` holds every binding in construction (topological) order. Each ``BindingInfo``
carries:

- `type` — the bound type as graph identity: `Logger`, `some TodoRepository`, `[any Service]`.
- `key` — the binding key, if keyed; `nil` otherwise.
- `kind` — a ``BindingKind``: `singleton`, `scoped`, `provider` or `aggregate`.
- `scope` — the seed type it lives under, or `nil` for app scope.
- `dependencies` — the ``DependencyEdge`` values it consumes, or for an aggregate, the
  contributors collated into it.
- `location` — a ``SourceLocation`` naming the origin module, file and line. For a synthesised
  aggregate, that is where its key is declared.

The model is `Codable`, so an adapter can serialise it — an HTTP introspection endpoint is the
obvious consumer, and is exactly why the protocol exists rather than the graph exposing its
concrete type.

## What it costs

Nothing until you call it. `introspect()` builds the model on demand, so there is no runtime
memory cost in a process that never asks. The construction code itself lives in the binary and
is small for typical graphs.

## What it is not for

- **Not runtime resolution.** The model returns *descriptions*, not values. There is no lookup
  from it back into the graph, which is what keeps the service-locator pattern out.
- **Not mutation.** Bindings are fixed at compile time; introspection observes.
- **Not a validity check.** Do not introspect to see whether a binding exists before using it —
  if it did not, the build would have failed. Reaching for that is a sign the code wants
  <doc:ResolutionAndKeys> instead.
