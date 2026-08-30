# Completed Issues

Resolved counterparts to [../PendingIssues/](../PendingIssues/README.md) — gaps that have since been
**fixed or worked around**. Kept for the record; the individual write-ups are point-in-time (their internal
"pending merge" notes predate the merges), and everything here is now merged/resolved.

Most came from building the variant-app-graph testing story (M6a). #01, #08, #09 and #10 were forced by
Phase C (the wire-mvc-examples mocked-suite un-gate) and proven by that suite going green Docker-free; #04
was not — it was reproduced and fixed later, from a fixture written for the purpose. **#16 is different in
kind**: a *diagnostic* bug rather than a graph one, surfaced by Phase 3's `auth-abac` item and fixed by
naming `@Factory` as the lifetime it already was. **#18 is the pair to it**, from Phase 5 rather than the
graph: a diagnostic that *reported* a real defect rather than being one. Trying to write `consuming` on
`drain()` was refused, and the refusal was the bug report — the gap between the exclusive ownership #148
delivered and the exactly-once draining it was argued on.

| # | Title | Repo(s) | Resolution |
|---|-------|---------|-----------|
| [01](01-generic-mock-consuming-factory.md) | Generic-axis mock-consuming factory not concretized | swift-wire + wire-mvc | Fixed — swift-wire concretizes the mocked generic axis (#235); wire-mvc's fold detection matches the dep's *constraint*, not its spelled type (#47). |
| [04](04-seed-scoped-mock-consuming-factory.md) | Seed-scoped controller + mock-consuming factory didn't compile | swift-wire | Fixed — the variant factory transform now runs for seed-scoped contributor proxies too, dropping the production factory and sourcing its mocked deps from `create(doubles:)`; wire-mvc's existing hoist needed no change. |
| [08](08-generic-seed-scoped-subject-harness.md) | Generic seed-scoped subject — doubles field ordering | wire-mvc | Fixed — the doubles construction is sorted to match WireGen's alphabetical struct order (the old `@TaskLocal` symptom was already gone post-M6a). |
| [09](09-raw-route-variant-witness.md) | Raw route ignores the variant subject expression | wire-mvc | Fixed — `rawRouteBlock` dispatches on `subjectExpression` + the scope-entry prologue, like the typed path. |
| [10](10-bindtype-cannot-name-macro-generated-mock.md) | `@BindType` can't name a macro-generated mock directly | Swift compiler (example workaround) | Worked around — `@BindType` names a plain `typealias` onto the `@Smock`-generated mock, since a macro can't name another macro's output as its argument. |
| [16](16-factory-template-scope-hint.md) | The cross-scope fix-it names a synthesised factory the user cannot annotate | swift-wire | Fixed — `@Factory` is diagnosed as a lifetime macro (dissolving the `invalid redeclaration of init` and the double discovery behind it), and the cross-scope note names the *template* and offers only moves that can be written. No source migration. |
| [18](18-registry-drained-twice.md) | A typed terminal can drain the response-header registry twice | wire-mvc | Fixed — the buffered and streaming terminals take the registry `consuming` and drain it once between the handler and the wire, so `drain()` is `consuming` and generated code holds no registry to drain twice. |

See [../PendingIssues/](../PendingIssues/README.md) for what's still outstanding.
