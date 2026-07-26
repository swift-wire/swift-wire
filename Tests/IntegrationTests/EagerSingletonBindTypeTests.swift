import Testing

/// H2.2a "B" gate — `@BindType` as a true complete-replacement. The eager `@BindType`'d binding (`any
/// EagerWidget`, backed by `RealEagerWidget.init`'s side-effect) is DROPPED from the variant app graph, so
/// `Wire.bootstrapEagerFixture_bindMock()` never constructs it; the keyless `Wire.bootstrap()` keeps it. The
/// structural drop is asserted via the graph's deterministic `introspect()` (the global side-effect counter
/// can't be isolated — every `Wire.bootstrap()` across the parallel suite bumps it — but a binding absent
/// from the graph is never constructed, which is exactly "its `init` doesn't run"). The variant scope then
/// resolves the consumer to the mock; the keyless scope to the real.
@Suite("EagerSingletonBindType")
struct EagerSingletonBindTypeTests {
    @Test func eagerBindTypedBindingIsDroppedFromTheVariantAppGraph() async throws {
        // The variant app graph = production minus the `@BindType`'d `any EagerWidget` — so
        // `_wireBootstrapEagerFixture_bindMock()` never calls the provider, and `RealEagerWidget.init` (its
        // side-effect) never runs under the variant.
        let variantGraph = try await Wire.bootstrapEagerFixture_bindMock()
        #expect(!variantGraph.introspect().bindings.contains { $0.type == "any EagerWidget" })

        // The keyless production graph keeps it (constructed at app bootstrap; the production suite needs it).
        let productionGraph = try await Wire.bootstrap()
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
