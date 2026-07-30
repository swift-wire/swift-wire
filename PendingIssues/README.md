# Pending Issues — variant app graph / mock-consuming factories

Outstanding gaps and unverified cases surfaced while building the variant-app-graph testing story
(M6a, `Documentation/Archive/ScopableRouteContributorsPlan.md`). Each was a scoping decision made during
Phase 1/A/B; this directory records them so none stays silently deferred. Resolved ones have moved to
[../CompletedIssues/](../CompletedIssues/README.md). States:

- 🔴 **Known broken** — reproduced or provably unhandled in the current code.
- 🟡 **Unverified** — a code path exists but no test exercises it; may work, may not.
- ⚪ **Coverage gap** — functionally validated elsewhere, but missing its own direct test.
- 🟡 also covers **deferred by decision** — scoped out deliberately and rejected with a diagnostic (#11).

| # | Title | Repo(s) | State |
|---|-------|---------|-------|
| [02](02-global-tier-mock-consuming-fold.md) | Global-tier mock-consuming middleware fold doesn't thread doubles | wire-mvc | 🔴 |
| [03](03-keyed-slot-mock-consuming-factory.md) | Keyed-slot mock-consuming factory untested | swift-wire + wire-mvc | 🟡 |
| [04](04-seed-scoped-mock-consuming-factory.md) | Seed-scoped controller + mock-consuming factory fold untested | wire-mvc (+swift-wire) | 🟡 |
| [05](05-one-hop-mock-detection.md) | Mock-consumption detection is one-hop only | swift-wire + wire-mvc | 🔴 |
| [06](06-factory-only-mock-and-multiple-factories.md) | Subject-unreached mock / multiple factories per proxy | swift-wire | 🟡 |
| [07](07-box-role-variant-factory-coverage.md) | Box-role variant factory absent from swift-wire's own tests | swift-wire | ⚪ |
| [11](11-multiple-testing-keys.md) | One TestingKey per target; several need the doubles model reworked | wire-mvc (+swift-wire) | 🟡 |

These are all **latent** — real, but none is on a shipped example's path (Phase C didn't force them). **#02**
is the one known-broken *functional* gap (a global `@Middleware` that injects a mocked slot never threads
doubles); **#05** is a known one-hop-detection limitation; the rest are untested corners (#03, #04, #06) or a
coverage gap (#07). **#11** is different in kind: a deliberate scope decision, rejected at build time rather
than left latent. Resolved items (#01, #08, #09, #10) are in
[../CompletedIssues/](../CompletedIssues/README.md).
