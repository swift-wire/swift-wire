# Completed Issues — variant app graph / mock-consuming factories

Resolved counterparts to [../PendingIssues/](../PendingIssues/README.md) — gaps surfaced while building the
variant-app-graph testing story (M6a) that have since been **fixed or worked around**. Kept for the record;
the individual write-ups are point-in-time (their internal "pending merge" notes predate the merges), and
everything here is now merged/resolved. All four were forced by Phase C (the wire-mvc-examples mocked-suite
un-gate) and proven by that suite going green Docker-free.

| # | Title | Repo(s) | Resolution |
|---|-------|---------|-----------|
| [01](01-generic-mock-consuming-factory.md) | Generic-axis mock-consuming factory not concretized | swift-wire + wire-mvc | Fixed — swift-wire concretizes the mocked generic axis (#235); wire-mvc's fold detection matches the dep's *constraint*, not its spelled type (#47). |
| [08](08-generic-seed-scoped-subject-harness.md) | Generic seed-scoped subject — doubles field ordering | wire-mvc | Fixed — the doubles construction is sorted to match WireGen's alphabetical struct order (the old `@TaskLocal` symptom was already gone post-M6a). |
| [09](09-raw-route-variant-witness.md) | Raw route ignores the variant subject expression | wire-mvc | Fixed — `rawRouteBlock` dispatches on `subjectExpression` + the scope-entry prologue, like the typed path. |
| [10](10-bindtype-cannot-name-macro-generated-mock.md) | `@BindType` can't name a macro-generated mock directly | Swift compiler (example workaround) | Worked around — `@BindType` names a plain `typealias` onto the `@Smock`-generated mock, since a macro can't name another macro's output as its argument. |

See [../PendingIssues/](../PendingIssues/README.md) for what's still outstanding.
