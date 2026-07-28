# 07 — Box-role variant factory absent from swift-wire's own tests

**Repo(s):** swift-wire
**State:** ⚪ Coverage gap (functionally validated end-to-end via wire-mvc; no direct swift-wire test)
**Blocks:** nothing functionally — it works; it just isn't covered by swift-wire's own suite.
**Surfaced by:** flagged in the Phase B handoff (not silent).

## What it is

swift-wire's variant-factory unit fixture (`AppScopedAudit` in
`Tests/IntegrationTests/ScopableRouteContributorExample.swift`) has **no box roles** — its `create` takes no
assisted (Ctx/Reader/Sender) parameters, so `renderVariantFactoryDeclaration`'s box-role passthrough
(`createGenerics`, the `_: Role.Type` metatype params, the concretized return type) is never exercised in
swift-wire's own tests.

The box-role form is validated only **end-to-end through wire-mvc** (`SummaryAudit`, whose generated variant
factory is `create<RequestContext, Reader, ResponseSender>(doubles:, _, _, _) -> SummaryAudit<…>`). If a
swift-wire refactor broke the box-role emission, swift-wire's suite would stay green — the break would only
show in wire-mvc.

## Use case blocked

None. This is a test-coverage gap, not a functional one.

## State / evidence

- `Sources/WireGenCore/FactorySynthesis.swift` — `renderVariantFactoryDeclaration`, the `createGenerics` /
  `createParameters` / `returnType` box-role machinery.
- swift-wire fixture: `AppScopedAudit` has `func run() -> String` (no box roles).
- Validated in wire-mvc: generated `_NoteTestBinds_mockBackend_WireFactory_SummaryAuditKeys_factory.create<…>`.

## Fix sketch

Add a swift-wire fixture with a box-role mock-consuming `@Factory` (`@MiddlewareFactory`-shaped, generic over
box roles) and assert the emitted variant factory's `create<…>(doubles:, _, _, _)` shape directly, so
swift-wire owns coverage for its own emission.
