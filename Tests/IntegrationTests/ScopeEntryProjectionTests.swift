import Testing
import Wire

/// `WireScopeEntry` — recovering a request-scoped subject's *type* from a scope-entry thunk without naming
/// it.
///
/// This is the one thing the entry struct cannot do concretely. An adapter emitting a generic declaration
/// over a request-scoped subject has no name for that subject: the proxy holds a thunk rather than the
/// subject, and the concrete type is a specialisation the adapter's emitter deliberately never writes. A
/// tuple made it structurally recoverable — `(Subject, Teardown)` decomposes into generic parameters — and
/// the named struct that replaced it does not, so the struct carries the projection instead.
///
/// **Compiling is the test.** Every assertion here is a type-checking one: that `Entry.Subject` resolves to
/// the concrete subject, and that it does so for a subject over an opaque backend, which is the case that
/// motivated the protocol. WireOpenAPI's `noSubject` helper is this function, emitted into a generated
/// conformer for a field whose type it could not otherwise spell.
@Suite("Scope entry projection")
struct ScopeEntryProjectionTests {
    /// WireOpenAPI's helper, verbatim in shape: a typed `nil` whose type is read off the thunk. The thunk
    /// is never called — only its return type is.
    private func noSubject<Seed, Doubles, Entry: WireScopeEntry>(
        _ thunk: @Sendable (Seed, Doubles) async throws -> Entry
    ) -> Entry.Subject? { nil }

    @Test func aSubjectsTypeIsRecoverableFromItsThunk() async throws {
        let graph = try await Wire.bootstrapGenProxyFixture_bindMock()
        let proxy = Wire.bootstrapGenProxyFixture_bindMock_GenProxyRouteControllerContributor(wireGraph: graph)

        // The projection, over a subject generic in an opaque backend. That this line type-checks is the
        // assertion: `Entry.Subject` resolved to `GenProxyRouteController<…>` without the specialisation
        // being written anywhere here.
        let recovered = noSubject(proxy._wireEnterScope)
        #expect(recovered == nil)

        // And the recovered type is the subject's, not merely *some* type — pinned by handing a real
        // subject back into the same slot, which only compiles if the two agree.
        let mock = MockGenProxyRepository()
        let doubles = _GenProxyFixture_bindMock_GenProxyRouteControllerDoubles(genProxyRepository: mock)
        let entered = try await proxy._wireEnterScope(GenProxyRequestSeed(id: "projection"), doubles)
        var slot = recovered
        slot = entered._wireSubject
        #expect(slot?.tag() == "mock:routed")
        _ = await entered._wireScopeTeardown()
    }

    @Test func theTeardownIsReachableThroughTheProtocolToo() async throws {
        // Generic code holding an entry it cannot name still has to end the scope it opened, which is why
        // the teardown is a requirement rather than left to the concrete type.
        func endScope(_ entry: some WireScopeEntry) async -> [any Error] {
            await entry._wireScopeTeardown()
        }
        let graph = try await Wire.bootstrapGenProxyFixture_bindMock()
        let proxy = Wire.bootstrapGenProxyFixture_bindMock_GenProxyRouteControllerContributor(wireGraph: graph)
        let doubles = _GenProxyFixture_bindMock_GenProxyRouteControllerDoubles(
            genProxyRepository: MockGenProxyRepository()
        )
        let entered = try await proxy._wireEnterScope(GenProxyRequestSeed(id: "teardown"), doubles)
        #expect(await endScope(entered).isEmpty)
    }
}
