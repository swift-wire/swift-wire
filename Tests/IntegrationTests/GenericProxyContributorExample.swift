// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Synchronization
import Wire
import WireTestLibrary
import WireTesting

/// Generic-subject case — shape 1 (full concretization). A `@RouteController @Scoped(seed:)` subject
/// generic *only* over the `@BindType`'d protocol (`<R: GenProxyRepository>`, the idiomatic Wire opaque-lift:
/// inject a protocol dep by making the consumer generic over it). Under the key the slot resolves to the
/// concrete `MockGenProxyRepository`, so the variant subject fully concretizes to
/// `GenProxyRouteController<MockGenProxyRepository>`. Spike-only: determines whether the variant-proxy facade
/// emits correct, compiling code for a generic subject.
struct GenProxyRequestSeed: Sendable {
    let id: String
}

protocol GenProxyRepository: Sendable {
    func tag(_ id: String) -> String
}

final class RealGenProxyRepository: GenProxyRepository {
    func tag(_ id: String) -> String { "real:\(id)" }
}

final class MockGenProxyRepository: GenProxyRepository {
    private let calls = Mutex<[String]>([])

    func tag(_ id: String) -> String {
        calls.withLock { $0.append(id) }
        return "mock:\(id)"
    }

    var recordedTags: [String] { calls.withLock { $0 } }
}

/// Bound opaquely (`some GenProxyRepository`) so a generic consumer can lift over it.
enum GenProxyRepositoryModule {
    @Provides static func repository() -> some GenProxyRepository { RealGenProxyRepository() }
}

/// The routed subject — generic over the mocked protocol, reached through its bridging contributor proxy.
@Scoped(seed: GenProxyRequestSeed.self, allowUnused: true)
@RouteController
struct GenProxyRouteController<R: GenProxyRepository>: Sendable {
    @Inject var repository: R
    @Inject var genProxyRequestSeed: GenProxyRequestSeed

    func tag() -> String { repository.tag("routed") }
}

// --- Shape 2 (partial concretization) — subject generic over the mocked dep AND a non-mocked one. Only R
// is bound to the concrete mock; G stays an app-scoped opaque backend borrowed from the graph, so the
// variant subject is partially generic (`GenPartialRouteController<MockGenProxyRepository, some
// GenSomethingElse>`). Exercises the facade's return-type erasure together with the borrow path (the borrow
// is bound as a local outside the @Sendable thunk).

struct GenPartialRequestSeed: Sendable {
    let id: String
}

protocol GenSomethingElse: Sendable {
    func label() -> String
}

final class RealGenSomethingElse: GenSomethingElse {
    func label() -> String { "else" }
}

/// A second app-scoped opaque backend the partial subject stays generic over (not mocked) — borrowed by the
/// variant scope from the reused graph.
enum GenSomethingElseModule {
    @Provides static func something() -> some GenSomethingElse { RealGenSomethingElse() }
}

@Scoped(seed: GenPartialRequestSeed.self, allowUnused: true)
@RouteController
struct GenPartialRouteController<R: GenProxyRepository, G: GenSomethingElse>: Sendable {
    @Inject var repository: R
    @Inject var helper: G
    @Inject var genPartialRequestSeed: GenPartialRequestSeed

    func tag() -> String { repository.tag("partial") + ":" + helper.label() }
}

/// The test-graph variant: bind the `GenProxyRepository` slot to the concrete `MockGenProxyRepository`.
/// Applies to both the fully-generic (shape 1) and partially-generic (shape 2) subjects.
enum GenProxyFixture {
    @BindType(GenProxyRepository.self, MockGenProxyRepository.self)
    static let bindMock = TestingKey()
}
