import Testing

/// Phase-1 gate — `@Scopable` extended to an app-scoped (`@Singleton`) route contributor. The variant app
/// graph drops `AppScopedController` (and its slot + hold proxy), so `Wire.bootstrap<Variant>()` never
/// constructs it; the keyless `Wire.bootstrap()` keeps it. The seedless variant proxy rebuilds the controller
/// on demand from the doubles alone — `_wireEnterScope(doubles)`, no seed — so the mock reaches it.
@Suite("ScopableRouteContributor")
struct ScopableRouteContributorTests {
    @Test func appScopedRouteContributorRebuildsSeedlesslyWithTheMock() async throws {
        // The variant graph drops the app-scoped subject; the facade builds its seedless proxy against it.
        let graph = try await Wire.bootstrapAppScopedFixture_bindMock()

        let mock = MockAppScopedRepository()
        let doubles = _AppScopedFixture_bindMockDoubles(appScopedRepository: mock)

        let proxy = Wire.bootstrapAppScopedFixture_bindMock_AppScopedControllerContributor(wireGraph: graph)
        // Seedless entry — the doubles are the only argument (no seed); the controller is rebuilt on demand.
        let (subject, teardown) = try await proxy._wireEnterScope(doubles)

        // The mock reaches the rebuilt subject; the non-mock `AppScopedLog` is borrowed from the variant graph.
        #expect(subject.tag() == "mock:routed:log")
        #expect(mock.recordedTags == ["routed"])

        let errors = await teardown()
        #expect(errors.isEmpty)
    }

    /// A **generic** app-scoped route contributor over the opaque mocked slot — the seedless reconstruction
    /// concretizes it to `GenAppController<MockGenAppBackend>` and threads the mock. `@TestScopable` on the
    /// generic type is what makes it referenceable (a key-side metatype can't spell an unbound generic).
    @Test func genericAppScopedRouteContributorConcretizesToTheMock() async throws {
        let graph = try await Wire.bootstrapGenAppScopedFixture_bindMock()

        let mock = MockGenAppBackend()
        let doubles = _GenAppScopedFixture_bindMockDoubles(genAppBackend: mock)

        let proxy = Wire.bootstrapGenAppScopedFixture_bindMock_GenAppControllerContributor(wireGraph: graph)
        let (subject, teardown) = try await proxy._wireEnterScope(doubles)

        #expect(subject.note() == "mock:routed")
        _ = await teardown()
    }
}
