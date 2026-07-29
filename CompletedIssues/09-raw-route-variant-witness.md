# 09 — Raw route ignores the variant subject expression

**Repo(s):** wire-mvc
**State:** ✅ **Fixed (pending merge)** — was 🔴 Known broken
**Blocks:** a `@RawRoute` on any variant witness — a `@Scoped(seed:)` or seedless `@TestScopable` controller
under a keyed suite.
**Surfaced by:** Phase C (`ExportController<Repository>`'s `@RawRoute` streaming `/export`). **Phase C forced
this.**

## What it is

`rawRouteBlock` hard-coded the terminal as `try await self.<subjectAccessor>.<method>(…)` and passed **no**
scope-entry prologue to `emitRegister`. So on a variant witness it:
1. dispatched on `self._wireSubject` — which a **seedless** variant proxy doesn't have (it holds
   `_wireEnterScope`, not `_wireSubject`) → *"value of type '…_WireRouteContributor_ExportController<Repository>'
   has no member '_wireSubject'"*; and
2. never entered request scope (no `_wireEnterScope(doubles)`), so even a seed-scoped variant raw route would
   have dispatched on the wrong instance.

The typed-route path (`routeBlock`) already used `subjectExpression` (→ `wireMVCController` for a variant
witness) and emitted the scope-entry prologue + doubles preamble/hoist; the raw path simply predated that.

## Resolution

`rawRouteBlock` now mirrors the typed path: it dispatches on `subjectExpression`, prepends the scope-entry
prologue (`_wireEnterScope`) and, for a variant witness, the doubles preamble (hoisted above the fold when the
fold threads doubles). A production app-`@Singleton` raw route stays `self._wireSubject`, byte-for-byte
unchanged.

Validated by `rawRouteOnVariantWitnessEntersSeedlessScope` — the variant witness dispatches on
`wireMVCController.stream(…)` after `_wireEnterScope(wireMVCDoubles)`; the production witness keeps
`self._wireSubject.stream(…)`.
