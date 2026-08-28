import Testing

/// Phase-3 generic-subject gate — shape 1 (full concretization). Drives the variant proxy for a
/// `@RouteController @Scoped(seed:)` subject generic over the `@BindType`'d protocol, built from the variant
/// app graph (which drops the mocked `some GenProxyRepository` and re-indexes its remaining opaque axes), and
/// asserts the mock is reached through the concretized subject.
@Suite("GenericProxyContributor")
struct GenericProxyContributorTests {
    @Test func genericSubjectFullyConcretizesToMock() async throws {
        let graph = try await Wire.bootstrapGenProxyFixture_bindMock()

        let mock = MockGenProxyRepository()
        let doubles = _GenProxyFixture_bindMock_GenProxyRouteControllerDoubles(genProxyRepository: mock)

        let proxy = Wire.bootstrapGenProxyFixture_bindMock_GenProxyRouteControllerContributor(wireGraph: graph)
        let entered = try await proxy._wireEnterScope(GenProxyRequestSeed(id: "req-1"), doubles)
        let subject = entered._wireSubject
        let teardown = entered._wireScopeTeardown

        #expect(subject.tag() == "mock:routed")
        let errors = await teardown()
        #expect(errors.isEmpty)
        #expect(mock.recordedTags == ["routed"])
    }

    /// Shape 2 (partial concretization) — subject generic over the mocked R (concrete) and a non-mocked G
    /// (app-scoped opaque backend the variant scope borrows). The borrow is bound outside the `@Sendable`
    /// thunk, so the facade compiles and the mock is reached alongside the borrowed backend.
    @Test func partiallyGenericSubjectBorrowsNonMockedBackend() async throws {
        let graph = try await Wire.bootstrapGenProxyFixture_bindMock()

        let mock = MockGenProxyRepository()
        let doubles = _GenProxyFixture_bindMock_GenPartialRouteControllerDoubles(genProxyRepository: mock)

        let proxy = Wire.bootstrapGenProxyFixture_bindMock_GenPartialRouteControllerContributor(wireGraph: graph)
        let entered = try await proxy._wireEnterScope(GenPartialRequestSeed(id: "req-1"), doubles)
        let subject = entered._wireSubject
        let teardown = entered._wireScopeTeardown

        #expect(subject.tag() == "mock:partial:else")
        let errors = await teardown()
        #expect(errors.isEmpty)
        #expect(mock.recordedTags == ["partial"])
    }
}
