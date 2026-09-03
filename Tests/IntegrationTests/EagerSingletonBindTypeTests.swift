import Testing

/// The complete-replacement gate — `@BindType` as a true complete-replacement. The eager `@BindType`'d binding (`any
/// EagerWidget`, backed by `RealEagerWidget.init`'s side-effect) is DROPPED from the variant app graph, so
/// `Wire.bootstrapEagerFixture_bindMock()` never constructs it; the keyless `Wire.bootstrap()` keeps it. The
/// gate asserts the side-effect *directly* via a task-local-scoped init counter (`0` under the variant, `1`
/// under keyless), with the graph's deterministic `introspect()` presence/absence as a complementary check.
/// The variant scope then resolves the consumer to the mock; the keyless scope to the real.
@Suite("EagerSingletonBindType")
struct EagerSingletonBindTypeTests {
    @Test func eagerBindTypedBindingIsDroppedFromTheVariantAppGraph() async throws {
        // The variant app graph = production minus the `@BindType`'d `any EagerWidget`, so
        // `_wireBootstrapEagerFixture_bindMock()` never calls the provider — the real init's side-effect
        // does NOT run under the variant. Assert that directly via the task-local probe (0 inits), with
        // the structural `introspect()` absence as a complementary check.
        let variantInits = EagerInitCounter()
        let variantGraph = try await EagerInitProbe.$current.withValue(variantInits) {
            try await Wire.bootstrapEagerFixture_bindMock()
        }
        #expect(variantInits.count == 0)
        #expect(!variantGraph.introspect().bindings.contains { $0.type == "any EagerWidget" })

        // The keyless production graph constructs it once at app bootstrap (the production suite needs it) —
        // the real init's side-effect DOES run.
        let keylessInits = EagerInitCounter()
        let productionGraph = try await EagerInitProbe.$current.withValue(keylessInits) {
            try await Wire.bootstrap()
        }
        #expect(keylessInits.count == 1)
        #expect(productionGraph.introspect().bindings.contains { $0.type == "any EagerWidget" })

        // Variant scope-entry → the consumer resolves to the supplied mock.
        let mock = MockEagerWidget()
        let doubles = _EagerFixture_bindMockDoubles(eagerWidget: mock)
        let variantScope = try await Wire.bootstrapEagerFixture_bindMock_EagerRequestSeedScope(
            seed: EagerRequestSeed(id: "req-variant"),
            wireGraph: variantGraph,
            doubles: doubles
        )
        #expect(variantScope.eagerConsumer.label() == "mock")

        // Keyless scope-entry over the production graph → the consumer resolves to the real binding.
        let defaultScope = try await Wire.bootstrapEagerRequestSeedScope(
            seed: EagerRequestSeed(id: "req-keyless"),
            wireGraph: productionGraph
        )
        #expect(defaultScope.eagerConsumer.label() == "real")
    }
}
