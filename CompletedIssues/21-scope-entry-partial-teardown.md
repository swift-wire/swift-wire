# 21 — A scope entry that throws partway leaks the scope bindings it had already built

**Repo(s):** swift-wire
**State:** ✅ Fixed (2026-09) — `ScopeEntryEmission` and `SeedlessReconstructionEmission` accumulate the
scope's `@Teardown` actions and unwind them on a throw, gated by
`Tests/IntegrationTests/ScopePartialTeardownExample.swift` in both construction shapes
**Was:** 🟡 Latent when filed — and **wrong by the time it was read again**. M7c.6's own
`AsyncScopeEntryExample` added a scope entry that both constructs with `try` and carries a `@Teardown`
binding, which made the gap reachable in the corpus: 1 of 20 per-request thunks, where the survey behind
this entry had measured 0 of 19. It should have moved to 🔴 before it was fixed.
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

## How it was fixed

As predicted, and with the two things the entry called out both mattering. The accumulator is declared
**inside** the thunk — per request, since two entries into one scope share nothing — and the walk is over
what that entry actually constructed, which the pruned set already encodes.

The scheduled case needed the hook M7c.6 left open. A scope binding built inside the group is constructed
in a method of the thunk's building struct, where the accumulator is out of scope, so
`schedulerBootstrapOpeningLines`' `tornInGroup` — passed as `[]` by the scope path until now, harmlessly,
because there was no unwind path to feed — became the group's real torn set, and the drain's own `catch`
recovers such a binding from its cell before rethrowing. `ScopePartialTeardownExample`'s second scope puts
its `@Teardown` binding in the group region precisely to exercise that.

One thing the plan got wrong: the accumulator's *declaration* was first gated on the same condition as the
`do`/`catch`, but the happy path folds the same list, so a scope with teardown and no throwing
construction emitted a fold over an undeclared variable. The declaration follows "has teardown"; only the
`do`/`catch` follows "can throw".

Verified discriminating rather than assumed: with the accumulation forced off, all three gate tests fail.
