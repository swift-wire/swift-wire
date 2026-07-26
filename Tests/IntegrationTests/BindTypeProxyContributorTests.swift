import Synchronization
import Testing

/// H2.2a gate — the doubles-threaded contributor-proxy scope entry driven over the *proxy* the variant
/// emits (not the seed-scope façade). `Wire.bootstrap<Variant>_<Subject>Contributor(wireGraph:)` builds the
/// variant proxy against the variant app graph; `proxy._wireEnterScope(seed, doubles:)` enters request
/// scope, threading the key's doubles. Proves the three properties the shipped façade path loses: the mock
/// is read at the lifted singleton's `init`, the returned teardown runs, and a sibling seed-scoped subject
/// sharing the seed is not constructed (per-root pruning).
@Suite("BindTypeProxyContributor")
struct BindTypeProxyContributorTests {
    @Test func variantProxyEntersScopeWithDoubles() async throws {
        // The variant app graph — production minus the mocked/lifted bindings and the production proxies —
        // is what the variant proxy façade builds from.
        let graph = try await Wire.bootstrapWireProxyFixture_bindMock()

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

    /// Phase-2 leak-freedom — the route-carrying analog of the `EagerSingletonBindType` gate. The eager
    /// `@Singleton` `ProxyAccountController` (reading its `@BindType`'d slot at `init`) is `@Scopable`-lifted,
    /// so the variant app graph drops it: `Wire.bootstrap<Variant>()` never forces `RealProxyRepository`'s
    /// construction. The keyless `Wire.bootstrap()` constructs the eager controller at app bootstrap, which
    /// forces exactly one real construction.
    @Test func eagerSingletonInitDoesNotRunUnderTheVariantGraph() async throws {
        let variantInits = ProxyInitCounter()
        _ = try await ProxyInitProbe.$current.withValue(variantInits) {
            try await Wire.bootstrapWireProxyFixture_bindMock()
        }
        #expect(variantInits.count == 0)

        let keylessInits = ProxyInitCounter()
        _ = try await ProxyInitProbe.$current.withValue(keylessInits) {
            try await Wire.bootstrap()
        }
        #expect(keylessInits.count == 1)
    }
}
