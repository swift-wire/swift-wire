import Testing

/// H2.2a regression gate — a variant-proxy subject that borrows a plain app `@Singleton` (the shape that
/// reproduced the non-Sendable `_WireGraph` capture bug). Drives the variant proxy and asserts the facade
/// compiles and behaves: the mock is reached with the borrowed store's value, the teardown runs, and a
/// sibling sharing the seed is pruned.
@Suite("BorrowingProxyContributor")
struct BorrowingProxyContributorTests {
    @Test func variantProxyBorrowsAppSingletonAcrossScopeEntry() async throws {
        let graph = try await Wire.bootstrapBorrowFixture_bindMock()

        let mock = MockBorrowRepository()
        let doubles = _BorrowFixture_bindMock_BorrowRouteControllerDoubles(borrowRepository: mock)

        let proxy = Wire.bootstrapBorrowFixture_bindMock_BorrowRouteControllerContributor(wireGraph: graph)
        let (subject, teardown) = try await proxy._wireEnterScope(BorrowRequestSeed(id: "req-1"), doubles)

        // Mock reached, keyed by the borrowed app singleton's value ("store").
        #expect(subject.tag() == "mock:store")
        #expect(mock.recordedTags == ["store"])

        // Teardown runs the request scope's @Teardown walk.
        let errors = await teardown()
        #expect(errors.isEmpty)
        #expect(mock.recordedTags == ["store", "teardown"])

        // Pruning — the sibling sharing the seed was never constructed.
        #expect(!mock.recordedTags.contains("sibling"))
    }
}
