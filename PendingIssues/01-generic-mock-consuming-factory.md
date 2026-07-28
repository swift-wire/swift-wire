# 01 — Generic-axis mock-consuming factory is not concretized

**Repo(s):** swift-wire (emission + detection); wire-mvc consumes the result
**State:** ✅ **Fixed in swift-wire (pending merge)** — was 🔴 Known broken (deliberately deferred in Phase B)

## Resolution

Fixed in swift-wire. Three changes:
- **Lookup** (`variantFactoryTransforms`): a generic factory's proxy field is typed `_WireFactory_<key><Backend>`,
  but the factory is keyed by its bare name — strip the generic-argument list (`seedlessBareTypeName`) before
  the lookup, else the transform never fires and the production factory (over the dropped opaque axis) orphans.
- **Detection** (`mockedFactoryDependency`): a dep spelled as an injected generic param is bound to the slot
  named by its *constraint* (`Backend: GenAppBackend` → the `GenAppBackend` slot); match the constraint, and
  record the (param, concrete mock type) to concretize.
- **Emission** (`renderVariantFactoryDeclaration`, new `concretizedGenerics`): drop the mocked generic param
  from the struct's generics and spell it as the concrete mock type in the produced (return) type.

Validated by `genericAppScopedRouteContributorConcretizesToTheMock` — the generic `GenAppController<Backend>`
carries a generic mock-consuming `GenAppAudit<Backend>`; the emitted variant factory is
`create(doubles:) -> GenAppAudit<MockGenAppBackend>`, and the one mock instance records both `routed` (subject)
and `audit` (factory). All 697 swift-wire tests green.

---

## Original report
**Blocks:** mock-testing a controller whose lifted `@Middleware` `@Factory` injects the mocked backend
*generically* — the wire-mvc-examples `TodosController<Repository>` + `AuditGate<…, Repository>` case.
**Surfaced by:** Phase C (wire-mvc-examples mocked suite). **Phase C forces this.**

## What it is

Phase B re-emits a mock-consuming lifted `@Factory` as a variant factory whose `create(doubles:)` sources the
mocked `@Inject` from the per-request doubles. It handles the case where the mocked dependency is an
**existential** (`@Inject var repository: any AppScopedRepository`): the dep's spelled type equals the
`@BindType` slot type, and the factory struct's generics are untouched.

It does **not** handle a factory generic over its injected axis:

```swift
@Factory(ControllerMiddleware.audit)
@MiddlewareFactory(.responseSender, .reader, .requestContext)
struct AuditGate<Sender, Reader, Ctx, Repository: TodoRepository>: Middleware … {
    @Inject var log: AuditLog          // non-mock
    @Inject var repository: Repository // the mocked TodoRepository axis, spelled as the generic param
}
```

Two distinct failures:

1. **Detection never fires.** `mockedDoublesField` matches `strippedSlotType(dep.type)` against the slot type.
   For `@Inject var repository: Repository`, `dep.type` is the *parameter name* `Repository`, which never
   equals the slot type `TodoRepository`, so `variantFactoryTransforms` leaves the factory untransformed.
2. **Emitter wouldn't concretize even if detected.** `renderVariantFactoryDeclaration` keeps
   `structGenerics = injected`, so the variant factory would stay generic over `Repository` while
   `create(doubles:)` tries to source a *concrete* `MockMockableTodoRepository` — a type mismatch, and the
   `create` return type (`AuditGate<…, Repository>`) is never rewritten to the mock type.

## Use case blocked

The wire-mvc-examples mocked suite: `TodosController<Repository>` carries `@Middleware(ControllerMiddleware.audit)`
(`AuditGate`), which shares the controller's `TodoRepository` backend via the injected generic. Under
`@BindType(TodoRepository.self, Mock.self)`, the audit middleware must see the same per-request mock — which
requires the variant factory to concretize `Repository → Mock` and source it from the doubles.

## State / evidence

- Detection: `Sources/WireGen/TestingVariantSeedlessRoots.swift` — `mockedDoublesField(for:substitutions:)`
  matches on `strippedSlotType(dependency.type)`.
- Emission: `Sources/WireGenCore/FactorySynthesis.swift` — `renderVariantFactoryDeclaration`,
  `structGenerics = injected` (unchanged), and its doc comment already states: *"a mocked generic axis would
  need concretization, which the caller gates out."*
- The Phase B fixture (`Tests/IntegrationTests/ScopableRouteContributorExample.swift`, `AppScopedAudit`)
  deliberately used an existential `any AppScopedRepository`, so this path was never exercised.

## Repro (to confirm the exact failure mode)

Extend the swift-wire fixture: give the generic seedless subject (`GenAppController<Backend>`) a
mock-consuming `@Middleware`/`@Factory` that `@Inject`s `Backend` (the injected axis bound to the `@BindType`'d
slot), then build the IntegrationTests target and inspect the generated variant factory / bootstrap.

## Fix sketch

In `variantFactoryTransforms` / `renderVariantFactoryDeclaration`:
1. Detect a mocked dep whose type is an **injected generic parameter** bound to the `@BindType` slot (match the
   parameter's *constraint* against the slot, not the bare param name — the constraint `Repository: TodoRepository`
   names the slot).
2. Drop that parameter from the variant factory struct's generics (concretize the axis).
3. Rewrite the `create` return type's corresponding generic argument to the concrete mock type.
4. Source the dep from `doubles.<field>`.

This mirrors the generic *subject* reconstruction (`GenAppController<Backend>` → `GenAppController<MockGenAppBackend>`)
that already works — but the factory emitter is a separate path, which is why the subject's handling doesn't
carry over.
