# What gets built

A dependency should cost only what you reach. Reachability is how Wire keeps that true, and
`allowUnused:` is how you tell it about a root it cannot see.

## Overview

Wire computes the bindings reachable from your graph's **roots** and emits only those.
Depending on a five-hundred-binding library and injecting one of them costs you one: no stored
property, no eager construction and no generated line for the other four hundred and
ninety-nine.

That only works if Wire knows what the roots are, and there is a specific reason it cannot
always work them out.

## Why roots have to be declared

The plugin reads syntax, never use, and the graph it generates is `internal` to your module. So
it can see that `WorkerService` injects `SQSClient`, because that is an annotation. It cannot
see `graph.reportBuilder` in your `main.swift`, because that is an expression.

Two ways to declare a root:

```swift
// 1. `allowUnused:` — "I am a root, keep me."
@Singleton(allowUnused: true)
struct ReportBuilder { … }

let graph = try await Wire.bootstrap()
graph.reportBuilder.run()          // the read Wire cannot see

// 2. A graph conformance — an adapter's protocol member is a root for the key it names.
//    Your routes and services reach their framework this way, so nothing extra is needed.
```

[`@GraphInputs`](doc:GraphInputs()) properties are roots automatically: a value the caller
supplied is live by definition. Everything else is *reached* rather than declared — a
contributor through its collection, a request-scoped controller through its proxy, a resource
through whatever injects it.

## When Wire prunes something you wanted

It tells you, with the fix in the message:

```
warning: 'ReportBuilder' is declared but nothing reachable from this graph's roots constructs
it, so it was not emitted. Inject it somewhere, or mark it 'allowUnused: true' if you read it
from the graph directly (as 'graph.reportBuilder').
```

That warning fires at **every** visibility, unlike the dead-binding warning, which stays quiet
for `public`. The two are about different things. A public *declaration* may have consumers Wire
cannot see; a public *binding* is constructed by exactly one thing — this graph — and the graph
is `internal`, so nothing downstream can be the reason it went missing. A pruned `public`
binding is as surprising as a pruned `internal` one, and silence would only trade a warning for
a "has no member" error at the use site.

## The one shape that needs care

A target that both bootstraps a graph *and* exports bindings for a downstream Wire target to
compose. Its public bindings are legitimately absent from its own graph, and `allowUnused: true`
quiets the warning by keeping them in it — slightly wasteful, not wrong.

A library that is only *consumed* never meets this: it does not apply the build plugin, so it
has no graph of its own, and its consumer re-parses its sources.

## Constructed is not the same as stored

Reachability decides what is *built*. A second, narrower question decides what the graph
**stores**: only its roots, plus whatever generated code reads off it. Everything else is a
local inside the bootstrap — constructed, handed to the bindings that consume it, and never
retained by the graph.

That is why a binding can exist and still not be `graph.something`. Rather than leave you with a
"has no member" error, the plugin emits an unavailable stub carrying the fix:

```
'reportBuilder' is constructed by the graph but not a direct property of it. To read it as
'graph.reportBuilder', mark its binding at Sources/App/ReportBuilder.swift:12 'allowUnused: true'.
```

The stub stores nothing, so saying this costs the graph no retention — it is absent from the
memberwise initialiser and from `Sendable` derivation alike, and an application that never reads
the property never hears about it.

## Two errors get quieter, deliberately

- A **missing dependency** inside a binding nothing reaches is not an error. That is what lets
  you depend on a library whose own dependencies you have not pulled in.
- A **cycle** among bindings nothing reaches is likewise not an error, since nothing constructs
  them.

Reach either one and both fail the build exactly as they always did.

## `allowUnused:` is local

A library's `allowUnused:` is a statement about **its** build, not yours. It silences the
author's own dead-binding warning and does not pin the binding into your graph. A library
binding is live in your graph exactly when one of your roots reaches it — otherwise every
dependency could opt out of the pruning you are paying for.
