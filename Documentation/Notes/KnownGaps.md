# Known gaps

Outstanding gaps, unverified cases and deliberate deferrals across `swift-wire` and `wire-mvc`, recorded
so none stays silently deferred. This note is the **index**; each entry is a GitHub issue, and the issue
is where the write-up lives.

These were tracked as `PendingIssues/` and `CompletedIssues/` directories in this repository until
2026-09, when they moved to issues in the repository that owns each gap. A gap that spans both repos is
filed in both, with the halves linked to each other.

## State, as labels

The directories' state taxonomy is now carried by labels on the issues themselves:

| Label | Means |
|---|---|
| `known-broken` | Reproduced or provably unhandled in the current code. |
| `unverified` | A code path exists but no test exercises it; may work, may not. |
| `coverage-gap` | Functionally validated elsewhere, but missing its own direct test. |
| `deferred` | Scoped out deliberately — and, where it is expressible, rejected with a diagnostic rather than left latent. |
| `upstream` | The resolution is partly somebody else's; the issue carries the upstream ask. |
| `cross-cutting` | Spans both repos; a linked issue tracks the other half. |

Live lists: [swift-wire](https://github.com/tachyonics/swift-wire/issues) ·
[wire-mvc](https://github.com/tachyonics/wire-mvc/issues).

## Open

| Issue | Title | Repo(s) |
|---|---|---|
| [tachyonics/wire-mvc#165](https://github.com/tachyonics/wire-mvc/issues/165) | Global-tier mock-consuming middleware fold doesn't thread doubles | wire-mvc |
| [#329](https://github.com/tachyonics/swift-wire/issues/329) · [tachyonics/wire-mvc#166](https://github.com/tachyonics/wire-mvc/issues/166) | Keyed-slot mock-consuming factory is untested | both |
| [#331](https://github.com/tachyonics/swift-wire/issues/331) · [tachyonics/wire-mvc#167](https://github.com/tachyonics/wire-mvc/issues/167) | Mock-consumption detection is one-hop only | both |
| [#332](https://github.com/tachyonics/swift-wire/issues/332) | Subject-unreached mock / multiple factories per proxy | swift-wire |
| [#333](https://github.com/tachyonics/swift-wire/issues/333) | Box-role variant factory absent from swift-wire's own tests | swift-wire |
| [#336](https://github.com/tachyonics/swift-wire/issues/336) · [tachyonics/wire-mvc#170](https://github.com/tachyonics/wire-mvc/issues/170) | One `TestingKey` per target; several would need the doubles model reworked | both |
| [tachyonics/wire-mvc#171](https://github.com/tachyonics/wire-mvc/issues/171) | A typed route's declared `@ErrorResponse` failures aren't typed | wire-mvc |
| [tachyonics/wire-mvc#172](https://github.com/tachyonics/wire-mvc/issues/172) | Typed client `@Header` binding + merge has no running fixture | wire-mvc |
| [tachyonics/wire-mvc#173](https://github.com/tachyonics/wire-mvc/issues/173) | Typed-tier duplex routes, paused on an upstream bug | wire-mvc |
| [tachyonics/wire-mvc#174](https://github.com/tachyonics/wire-mvc/issues/174) | A cancelled request is reported as a 500 | wire-mvc |
| [tachyonics/wire-mvc#175](https://github.com/tachyonics/wire-mvc/issues/175) | The handler's path-parameter shape is a pre-1.0 public decision | wire-mvc |
| [tachyonics/wire-mvc#177](https://github.com/tachyonics/wire-mvc/issues/177) | App-scope teardown under `@WireMVCBootstrap` has no shutdown trigger | wire-mvc |
| [#338](https://github.com/tachyonics/swift-wire/issues/338) | Manifest-based discovery works; a consumer cannot tell which dependencies emit one | swift-wire |

### How to read the open list

These are all **latent** — real, but none is on a shipped example's path.
[tachyonics/wire-mvc#165](https://github.com/tachyonics/wire-mvc/issues/165) is the known-broken functional
gap in the *testing* surface (a global `@Middleware` that injects a mocked slot never threads doubles);
[#331](https://github.com/tachyonics/swift-wire/issues/331) is a known one-hop-detection limitation; the
rest are untested corners ([#329](https://github.com/tachyonics/swift-wire/issues/329),
[#332](https://github.com/tachyonics/swift-wire/issues/332)) or a coverage gap
([#333](https://github.com/tachyonics/swift-wire/issues/333)).

[#336](https://github.com/tachyonics/swift-wire/issues/336) is different in kind: a deliberate scope
decision, rejected at build time rather than left latent.
[tachyonics/wire-mvc#171](https://github.com/tachyonics/wire-mvc/issues/171) and
[#172](https://github.com/tachyonics/wire-mvc/issues/172) come from the per-controller testing surface
rather than the variant graph — #171 a deferred design call on the typed client's failure path, #172 a gap
where codegen output is asserted as text but never served.
[#173](https://github.com/tachyonics/wire-mvc/issues/173) is different again: a designed,
ownership-verified route shape held back for surface consistency until
[swiftlang/swift#91473](https://github.com/swiftlang/swift/issues/91473) is fixed, with `@RawRoute` serving
the case meanwhile. [#174](https://github.com/tachyonics/wire-mvc/issues/174) is the residue of a fix rather
than an untested corner: the `ServerTransport` bridge's handler now cancels with its request, and what is
left is that the cancelled request is *reported* as a 500 — an operational cost rather than a functional
one.

[#175](https://github.com/tachyonics/wire-mvc/issues/175) is the only entry held by a *date* rather than a
severity: nothing is broken, but the type the router hands a handler its path parameters in sits in two
public protocols, so changing it is cheap before 1.0 and expensive after — the same trade
[tachyonics/wire-mvc#148](https://github.com/tachyonics/wire-mvc/pull/148) spent on the response-header
registry.

[#177](https://github.com/tachyonics/wire-mvc/issues/177) is the known-broken gap in the *shipped runtime*
path rather than the testing one, and the first whose resolution is partly somebody else's: the app-scope
teardown walk never runs under the generated `@WireMVCBootstrap` `@main`, because nothing on that path stops
the server — and it cannot be stopped the way Hummingbird's is while the proposal's `~Copyable` handler
keeps the server out of the `ServiceGroup`. It carries the upstream asks (a public graceful-shutdown trigger
in swift-service-lifecycle, or a `Service`-shaped server entry point in the proposal) alongside the interim
in-repo fix.

[#338](https://github.com/tachyonics/swift-wire/issues/338) is unlike every other entry: nothing is missing
or untested, and the mechanism it records *works* — a consumer's build command can read a dependency's
plugin output, given a declared `inputFiles` edge, under both build backends. It is listed because the
deferral would otherwise be invisible and the spike would be re-run: manifest-based discovery is held not by
feasibility but by a predicate SPM cannot supply (which dependencies emit a manifest) against a win measured
at ~50 ms, and it carries the upstream asks that would make the route supported rather than derived.

## Resolved

Kept for the record. The write-ups are point-in-time; everything here is merged.

| Issue | Title | Resolution |
|---|---|---|
| [#328](https://github.com/tachyonics/swift-wire/issues/328) · [tachyonics/wire-mvc#164](https://github.com/tachyonics/wire-mvc/issues/164) | Generic-axis mock-consuming factory not concretized | swift-wire concretizes the mocked generic axis ([#235](https://github.com/tachyonics/swift-wire/pull/235)); wire-mvc's fold detection matches the dep's *constraint*, not its spelled type ([tachyonics/wire-mvc#47](https://github.com/tachyonics/wire-mvc/pull/47)). |
| [#330](https://github.com/tachyonics/swift-wire/issues/330) | Seed-scoped controller + mock-consuming factory didn't compile | The variant factory transform now runs for seed-scoped contributor proxies too, dropping the production factory and sourcing its mocked deps from `create(doubles:)`. |
| [#334](https://github.com/tachyonics/swift-wire/issues/334) · [tachyonics/wire-mvc#168](https://github.com/tachyonics/wire-mvc/issues/168) | Generic seed-scoped subject — doubles field ordering | The doubles construction is sorted to match WireGen's alphabetical struct order. |
| [tachyonics/wire-mvc#169](https://github.com/tachyonics/wire-mvc/issues/169) | Raw route ignores the variant subject expression | `rawRouteBlock` dispatches on `subjectExpression` + the scope-entry prologue, like the typed path. |
| [#335](https://github.com/tachyonics/swift-wire/issues/335) | `@BindType` can't name a macro-generated mock directly | Worked around — `@BindType` names a plain `typealias` onto the `@Smock`-generated mock, since a macro can't name another macro's output as its argument. |
| [#337](https://github.com/tachyonics/swift-wire/issues/337) | The cross-scope fix-it names a synthesised factory the user cannot annotate | `@Factory` is diagnosed as a lifetime macro, and the cross-scope note names the *template* and offers only moves that can be written. No source migration. |
| [tachyonics/wire-mvc#176](https://github.com/tachyonics/wire-mvc/issues/176) | A typed terminal can drain the response-header registry twice | The buffered and streaming terminals take the registry `consuming` and drain it once between the handler and the wire. |
| [#339](https://github.com/tachyonics/swift-wire/issues/339) | A scope entry that throws partway leaks the scope bindings it had already built | The scope-entry and seedless-reconstruction thunks accumulate their `@Teardown` actions as each binding is built and unwind them in reverse before rethrowing. |

### Two of these are worth remembering

[#337](https://github.com/tachyonics/swift-wire/issues/337) is the one *diagnostic* bug this list has held,
and the only one fixed by making Wire say something true rather than by changing what it does.
[tachyonics/wire-mvc#176](https://github.com/tachyonics/wire-mvc/issues/176) is its pair: a diagnostic that
*reported* a real defect rather than being one. Trying to write `consuming` on `drain()` was refused, and the
refusal was the bug report — the gap between the exclusive ownership
[tachyonics/wire-mvc#148](https://github.com/tachyonics/wire-mvc/pull/148) delivered and the exactly-once
draining it was argued on.

[#339](https://github.com/tachyonics/swift-wire/issues/339) is different again: it was filed as latent by a
survey done for another question, and had stopped being latent by the time it was implemented — the fixture
that closed it was itself what made the gap reachable. That is worth remembering as a way these entries go
stale.
