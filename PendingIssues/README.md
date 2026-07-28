# Pending Issues — variant app graph / mock-consuming factories

Known gaps and unverified cases surfaced while building the variant-app-graph testing story
(`Documentation/ScopableRouteContributorsPlan.md`). Each was a scoping decision made during Phase 1/A/B;
this directory records them so none stays silently deferred. States:

- 🔴 **Known broken** — reproduced or provably unhandled in the current code.
- 🟡 **Unverified** — a code path exists but no test exercises it; may work, may not.
- ⚪ **Coverage gap** — functionally validated elsewhere, but missing its own direct test.

| # | Title | Repo(s) | State | Phase C forces |
|---|-------|---------|-------|----------------|
| [01](01-generic-mock-consuming-factory.md) | Generic-axis mock-consuming factory not concretized | swift-wire (+wire-mvc) | ✅ Fixed (pending merge) | **Yes** |
| [02](02-global-tier-mock-consuming-fold.md) | Global-tier mock-consuming middleware fold doesn't thread doubles | wire-mvc | 🔴 | No |
| [03](03-keyed-slot-mock-consuming-factory.md) | Keyed-slot mock-consuming factory untested | swift-wire + wire-mvc | 🟡 | No |
| [04](04-seed-scoped-mock-consuming-factory.md) | Seed-scoped controller + mock-consuming factory fold untested | wire-mvc (+swift-wire) | 🟡 | Maybe |
| [05](05-one-hop-mock-detection.md) | Mock-consumption detection is one-hop only | swift-wire + wire-mvc | 🔴 | No |
| [06](06-factory-only-mock-and-multiple-factories.md) | Subject-unreached mock / multiple factories per proxy | swift-wire | 🟡 | No |
| [07](07-box-role-variant-factory-coverage.md) | Box-role variant factory absent from swift-wire's own tests | swift-wire | ⚪ | No |
| [08](08-generic-seed-scoped-subject-harness.md) | Generic seed-scoped subject under the keyed harness | wire-mvc (+swift-wire) | 🟡 | **Yes** |

**Phase C (wire-mvc-examples mocked suite un-gate) forces #01 and #08**, and possibly #04. The rest are latent —
real, but not on Phase C's path unless the examples grow into them.
