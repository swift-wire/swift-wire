# Pending Issues

Outstanding gaps, unverified cases and deliberate deferrals, recorded so none stays silently deferred.
Most of the list came from building the variant-app-graph testing story (M6a,
`Documentation/Archive/ScopableRouteContributorsPlan.md`), where each was a scoping decision taken during
Phase 1/A/B; #12–#15 came from later work and are noted below. #16 came from Phase 3's `auth-abac` item
and has since been fixed. #17 and #18 both came from Phase 5's allocation work — #17 is the first entry
here held by a *deadline* rather than by severity, #18 by a compiler diagnostic. Resolved ones have
moved to
[../CompletedIssues/](../CompletedIssues/README.md). States:

- 🔴 **Known broken** — reproduced or provably unhandled in the current code.
- 🟡 **Unverified** — a code path exists but no test exercises it; may work, may not.
- ⚪ **Coverage gap** — functionally validated elsewhere, but missing its own direct test.
- 🟡 also covers **deferred by decision** — scoped out deliberately and rejected with a diagnostic (#11).

| # | Title | Repo(s) | State |
|---|-------|---------|-------|
| [02](02-global-tier-mock-consuming-fold.md) | Global-tier mock-consuming middleware fold doesn't thread doubles | wire-mvc | 🔴 |
| [03](03-keyed-slot-mock-consuming-factory.md) | Keyed-slot mock-consuming factory untested | swift-wire + wire-mvc | 🟡 |
| [05](05-one-hop-mock-detection.md) | Mock-consumption detection is one-hop only | swift-wire + wire-mvc | 🔴 |
| [06](06-factory-only-mock-and-multiple-factories.md) | Subject-unreached mock / multiple factories per proxy | swift-wire | 🟡 |
| [07](07-box-role-variant-factory-coverage.md) | Box-role variant factory absent from swift-wire's own tests | swift-wire | ⚪ |
| [11](11-multiple-testing-keys.md) | One TestingKey per target; several need the doubles model reworked | wire-mvc (+swift-wire) | 🟡 |
| [12](12-typed-route-error-tiers.md) | A typed route's declared `@ErrorResponse` failures aren't typed | wire-mvc | 🟡 |
| [13](13-typed-header-client-coverage.md) | Typed client `@Header` binding + merge has no running fixture | wire-mvc | ⚪ |
| [14](14-typed-tier-duplex-routes.md) | Typed-tier duplex routes, paused on an upstream bug | wire-mvc | 🟡 |
| [15](15-cancelled-request-reports-500.md) | A cancelled request is reported as a 500 | wire-mvc | 🟡 |
| [17](17-path-parameter-shape.md) | The handler's path-parameter shape is a pre-1.0 public decision | wire-mvc | 🟡 |
| [18](18-registry-drained-twice.md) | A typed terminal can drain the response-header registry twice | wire-mvc | 🟡 |

These are all **latent** — real, but none is on a shipped example's path (Phase C didn't force them). **#02**
is the one known-broken *functional* gap (a global `@Middleware` that injects a mocked slot never threads
doubles); **#05** is a known one-hop-detection limitation; the rest are untested corners (#03, #06) or a
coverage gap (#07). **#11** is different in kind: a deliberate scope decision, rejected at build time rather
than left latent. **#12** and **#13** come from the per-controller testing surface rather than the variant
graph: #12 is a deferred design call on the typed client's failure path, #13 a gap where codegen output is
asserted as text but never served. **#14** is different again — a designed, ownership-verified route shape
held back for surface consistency until an upstream compiler bug is fixed, with `@RawRoute` serving the
case meanwhile. **#15** is the residue of a fix rather than an untested corner: the `ServerTransport`
bridge's handler now cancels with its request, and what is left is that the cancelled request is *reported*
as a 500, which is an operational cost rather than a functional one. **#17** is the only entry here with a
*date* rather than a severity: nothing is broken, but the type the router hands a handler its path
parameters in sits in two public protocols, so changing it is cheap before 1.0 and expensive after — the
same trade #148 spent on the response-header registry, and the last one Phase 5 is holding. **#18** is
what #148 argued for and did not finish: ownership of the registry became compiler-checked, draining it
exactly once did not, and a typed terminal drains in both branches of its `do`/`catch`. The raw-route half
has since closed. Resolved items (#01, #04, #08, #09, #10, #16) are in
[../CompletedIssues/](../CompletedIssues/README.md) — #16 was the one *diagnostic* bug
this list has held, and the only one fixed by making Wire say something true rather than by changing what
it does.
