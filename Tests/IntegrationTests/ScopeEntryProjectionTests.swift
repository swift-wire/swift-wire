// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

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
///
/// The teardown is *not* a requirement, and the reason is a cross-module one worth knowing: a protocol
/// requirement spelled `@Sendable () async -> [any Error]` means `@concurrent` in swift-wire and
/// `nonisolated(nonsending)` in a consumer that enables `NonisolatedNonsendingByDefault` — which every
/// adapter here does — so a conformance would fail on a type that prints the same in both.
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
}
