import Testing

/// H2.2a generic-subject spike — shape 1 (full concretization). Drives the variant proxy for a
/// `@RouteController @Scoped(seed:)` subject generic over the `@BindType`'d protocol and asserts the mock is
/// reached through the concretized subject.
@Suite("GenericProxyContributor")
struct GenericProxyContributorTests {
    @Test func genericSubjectFullyConcretizesToMock() async throws {
        let graph = try await Wire.bootstrap()

        let mock = MockGenProxyRepository()
        let doubles = _GenProxyFixture_bindMockDoubles(genProxyRepository: mock)

        let proxy = Wire.bootstrapGenProxyFixture_bindMock_GenProxyRouteControllerContributor(wireGraph: graph)
        let (subject, teardown) = try await proxy._wireEnterScope(GenProxyRequestSeed(id: "req-1"), doubles)

        #expect(subject.tag() == "mock:routed")
        let errors = await teardown()
        #expect(errors.isEmpty)
        #expect(mock.recordedTags == ["routed"])
    }

    /// Shape 2 (partial concretization) — subject generic over the mocked R (concrete) and a non-mocked G
    /// (app-scoped opaque backend the variant scope borrows). The borrow is bound outside the `@Sendable`
    /// thunk, so the facade compiles and the mock is reached alongside the borrowed backend.
    @Test func partiallyGenericSubjectBorrowsNonMockedBackend() async throws {
        let graph = try await Wire.bootstrap()

        let mock = MockGenProxyRepository()
        let doubles = _GenProxyFixture_bindMockDoubles(genProxyRepository: mock)

        let proxy = Wire.bootstrapGenProxyFixture_bindMock_GenPartialRouteControllerContributor(wireGraph: graph)
        let (subject, teardown) = try await proxy._wireEnterScope(GenPartialRequestSeed(id: "req-1"), doubles)

        #expect(subject.tag() == "mock:partial:else")
        let errors = await teardown()
        #expect(errors.isEmpty)
        #expect(mock.recordedTags == ["partial"])
    }
}
