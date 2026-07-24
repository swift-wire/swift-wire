import Testing

/// H2.2a gate — the doubles-threaded contributor-proxy scope entry driven over the *proxy* the variant
/// emits (not the seed-scope façade). `Wire.bootstrap<Variant>_<Subject>Contributor(wireGraph:)` builds the
/// variant proxy against the reused production graph; `proxy._wireEnterScope(seed, doubles:)` enters request
/// scope, threading the key's doubles. Proves the three properties the shipped façade path loses: the mock
/// is read at the lifted singleton's `init`, the returned teardown runs, and a sibling seed-scoped subject
/// sharing the seed is not constructed (per-root pruning).
@Suite("BindTypeProxyContributor")
struct BindTypeProxyContributorTests {
    @Test func variantProxyEntersScopeWithDoubles() async throws {
        // The variant reuses the production app graph; only the request scope diverges.
        let graph = try await Wire.bootstrap()

        // The test holds the mock and supplies it through the generated doubles struct.
        let mock = MockProxyRepository()
        let doubles = _WireProxyFixture_bindMockDoubles(proxyRepository: mock)

        // Build the variant proxy once (like production), then enter request scope with the doubles.
        let proxy = Wire.bootstrapWireProxyFixture_bindMock_ProxyRouteControllerContributor(wireGraph: graph)
        // `_wireEnterScope` is a stored closure, so the seed and doubles are passed positionally (no labels).
        let (subject, teardown) = try await proxy._wireEnterScope(ProxyRequestSeed(id: "req-1"), doubles)

        // (a) Init-time mock — the lifted `@Singleton` controller was reconstructed in the scope, and its
        // `init` read the supplied mock (`"mock:init"`, not the production `"real:init"`). The distinguishing
        // Phase-2 property a per-call proxy would miss.
        #expect(subject.tag() == "mock:init")
        #expect(mock.recordedTags == ["init"])

        // (b) Teardown — the returned closure runs the request scope's `@Teardown` walk; `ProxySession.close()`
        // records through the same mock.
        let errors = await teardown()
        #expect(errors.isEmpty)
        #expect(mock.recordedTags == ["init", "teardown"])

        // (c) Pruning — the sibling seed-scoped subject sharing the seed is unreachable from the routed
        // subject, so this entry never constructed it: its `init` (which records `"sibling"`) never ran.
        #expect(!mock.recordedTags.contains("sibling"))
    }
}
