# 21 — A scope entry that throws partway leaks the scope bindings it had already built

**Repo(s):** swift-wire
**State:** 🟡 Latent — provably unhandled, but unreachable in any shipped shape: no construction on this
path can throw yet, so nothing reaches the gap
**Blocks:** nothing today. It becomes live the first time a `@Scoped(seed:)` binding has a throwing init in
a scope that also carries a `@Teardown` binding.
**Surfaced by:** M7c.6's survey of the scope construction paths. The question asked was whether any of them
should take the construction scheduler; the answer was no, and this is what the same survey found instead.

## What it is

M7c.5 gave the **app/container bootstrap** init-failure partial teardown: a `do`/`catch` around the
construction body, an accumulator of `@Teardown` actions appended as each binding is built, and a reverse
walk on the way out. Per-request **scope entry** did not get it, and has the same shape without it.

Measured on the integration corpus: **19 per-request construction thunks — 17 scope entries and 2
seedless reconstructions — all 19 carrying a `_wireScopeTeardown` closure, none of them constructing with
`try`.** So the machinery to tear a scope down exists on every one
of them, and the failure path that would need it cannot currently be reached. Add one throwing `@Inject
init` to a request-scoped binding and the gap is live.

## Why it is worse here than it was at app scope

The deferral reasoning M4 used for the bootstrap — a bootstrap init-failure "almost always ends in process
exit, so the OS reclaims the half-built resources" — **does not transfer**. A scope entry runs per request.
A failing one leaks per request, in a process that keeps serving, which is the shape that actually
accumulates.

## What the fix is

The same accumulator, in the thunk. `teardownAccumulatorLines`, `teardownActionAppendLines`,
`partialTeardownCatchLines` and `accumulatedTeardownClosureLines` are all indent-parameterised already, and
the scope's existing `scopeTeardownClosureLines` is the fold they would replace — so this is the M7c.5
change applied to `ScopeEntryEmission` and `SeedlessReconstructionEmission`, not a new design.

Two things to get right that the bootstrap did not have to:

- The thunk is `@Sendable` and captures borrowed singletons from the enclosing bootstrap frame. The
  accumulator has to be declared **inside** the thunk, not outside it — a per-request list, not a shared
  one.
- Scope entry is pruned per root (M5.4.6), so the walk is over the *reachable* set for that root, exactly
  as `scopeTeardownClosureLines` already does.

## Why it is not fixed now

No forcing case, and no population: the gate would be a fixture built for the mechanism rather than a
graph that wants it, which is the trap M7c.2 recorded and M7c.4 was rewritten to avoid. It lands when an
adopter has a throwing request-scoped init, which is the same trigger M4 set for the bootstrap half and
which took until M7c.5 to fire.
