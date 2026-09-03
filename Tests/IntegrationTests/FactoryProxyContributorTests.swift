import Testing

/// factory-carrying-proxy gate — a variant proxy whose subject carries a lifted `@Factory` (via
/// `@RouteMiddleware`), so the proxy has a `_wireFactory_<key>` field. Before the fix this failed to compile
/// (`_WireFactory_<key>.Type` passed where an instance was expected); the facade now binds the factory
/// instance as a local. Drives the variant proxy and asserts it enters cleanly and the mock threads.
@Suite("FactoryProxyContributor")
struct FactoryProxyContributorTests {
    @Test func factoryCarryingProxyEntersScopeWithDoubles() async throws {
        let graph = try await Wire.bootstrapFactoryProxyFixture_bindMock()

        let mock = MockFactoryProxyRepository()
        let doubles = _FactoryProxyFixture_bindMock_FactoryProxyRouteControllerDoubles(factoryProxyRepository: mock)

        let proxy = Wire.bootstrapFactoryProxyFixture_bindMock_FactoryProxyRouteControllerContributor(wireGraph: graph)
        let entered = try await proxy._wireEnterScope(FactoryProxyRequestSeed(id: "req-1"), doubles)
        let subject = entered._wireSubject
        let teardown = entered._wireScopeTeardown

        #expect(subject.tag() == "mock:routed")
        let errors = await teardown()
        #expect(errors.isEmpty)
        #expect(mock.recordedTags == ["routed"])
    }
}
