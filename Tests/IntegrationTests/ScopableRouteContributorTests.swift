import Testing

/// Seedless gate — `@Scopable` extended to an app-scoped (`@Singleton`) route contributor. The variant app
/// graph drops `AppScopedController` (and its slot + hold proxy), so `Wire.bootstrap<Variant>()` never
/// constructs it; the keyless `Wire.bootstrap()` keeps it. The seedless variant proxy rebuilds the controller
/// on demand from the doubles alone — `_wireEnterScope(doubles)`, no seed — so the mock reaches it.
@Suite("ScopableRouteContributor")
struct ScopableRouteContributorTests {
    @Test func appScopedRouteContributorRebuildsSeedlesslyWithTheMock() async throws {
        // The variant graph drops the app-scoped subject; the facade builds its seedless proxy against it.
        let graph = try await Wire.bootstrapAppScopedFixture_bindMock()

        let mock = MockAppScopedRepository()
        let doubles = _AppScopedFixture_bindMock_AppScopedControllerDoubles(appScopedRepository: mock)

        let proxy = Wire.bootstrapAppScopedFixture_bindMock_AppScopedControllerContributor(wireGraph: graph)
        // Seedless entry — the doubles are the only argument (no seed); the controller is rebuilt on demand.
        let entered = try await proxy._wireEnterScope(doubles)
        let subject = entered._wireSubject
        let teardown = entered._wireScopeTeardown

        // The mock reaches the rebuilt subject; the non-mock `AppScopedLog` is borrowed from the variant graph.
        #expect(subject.tag() == "mock:routed:log")
        #expect(mock.recordedTags == ["routed"])

        // The mock-consuming lifted `@Factory` the proxy carries is the variant factory: it holds only the
        // non-mock `log`, and its mocked `repository` rides `create(doubles:)` — sourced from the same doubles,
        // per request. Invoking it proves the mock threads the factory's product (the `audit` middleware) too.
        let audit = proxy._wireFactory_AppScopedKeys_audit.create(doubles: doubles)
        #expect(audit.run() == "mock:audit:log")
        #expect(mock.recordedTags == ["routed", "audit"])

        let errors = await teardown()
        #expect(errors.isEmpty)
    }

    /// A **generic** app-scoped route contributor over the opaque mocked slot — the seedless reconstruction
    /// concretizes it to `GenAppController<MockGenAppBackend>` and threads the mock. `@TestScopable` on the
    /// generic type is what makes it referenceable (a key-side metatype can't spell an unbound generic). It also
    /// carries a mock-consuming lifted `@Factory` **generic over the same injected axis** (`GenAppAudit<Backend>`,
    /// `@Inject var backend: Backend`): the variant factory concretizes that axis to
    /// `GenAppAudit<MockGenAppBackend>` and its `create(doubles:)` sources `backend` from the doubles — the
    /// generic-factory-concretization case (issue 01).
    @Test func genericAppScopedRouteContributorConcretizesToTheMock() async throws {
        let graph = try await Wire.bootstrapGenAppScopedFixture_bindMock()

        let mock = MockGenAppBackend()
        let doubles = _GenAppScopedFixture_bindMock_GenAppControllerDoubles(genAppBackend: mock)

        let proxy = Wire.bootstrapGenAppScopedFixture_bindMock_GenAppControllerContributor(wireGraph: graph)
        let entered = try await proxy._wireEnterScope(doubles)
        let subject = entered._wireSubject
        let teardown = entered._wireScopeTeardown
        #expect(subject.note() == "mock:routed")

        // The generic mock-consuming factory concretized to `GenAppAudit<MockGenAppBackend>`: its
        // `create(doubles:)` sources `backend` from the same doubles, proving the injected generic axis was
        // concretized to the mock (not left generic over the dropped opaque backend). The one instance threads
        // both the subject reconstruction and the factory.
        let audit = proxy._wireFactory_GenAppKeys_audit.create(doubles: doubles)
        #expect(audit.run() == "mock:audit")
        #expect(mock.recordedNotes == ["routed", "audit"])

        _ = await teardown()
    }
}
