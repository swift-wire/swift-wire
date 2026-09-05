// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Synchronization
import Wire
import WireTestLibrary
import WireTesting

/// Seedless `@Scopable` gate — an **app-scoped** (`@Singleton`) route contributor that consumes a
/// `@BindType`'d slot. `AppScopedController` is a `@Singleton @RouteController` (its own request entry, not a
/// `@Scoped(seed:)` subject), so in production it's built once with the real repository. Under the key it's
/// `@Scopable`'d, so the variant rebuilds it **per-request, seedlessly** — its variant proxy carries
/// `_wireEnterScope(doubles)` (no seed) that constructs `AppScopedController(repository: doubles.<field>)`
/// fresh on demand with the mock — rather than leaving it in the variant graph referencing the dropped
/// binding (which is the orphan-codegen bug this gate locks against).
protocol AppScopedRepository: Sendable {
    func tag(_ id: String) -> String
}

final class RealAppScopedRepository: AppScopedRepository {
    func tag(_ id: String) -> String { "real:\(id)" }
}

final class MockAppScopedRepository: AppScopedRepository {
    private let calls = Mutex<[String]>([])

    func tag(_ id: String) -> String {
        calls.withLock { $0.append(id) }
        return "mock:\(id)"
    }

    var recordedTags: [String] { calls.withLock { $0 } }
}

/// The `@BindType`'d slot — an app-scoped (module-scope) `@Provides`, existential so producer and consumer
/// match directly (no opaque axis — the generic-subject case is covered elsewhere).
enum AppScopedRepositoryModule {
    @Provides static func repository() -> any AppScopedRepository { RealAppScopedRepository() }
}

/// A non-mock app `@Singleton` the controller also injects — the variant borrows it from the graph unchanged
/// (it doesn't reach the mock), so the reconstruction thunk captures `_wireGraph.appScopedLog`.
@Singleton
final class AppScopedLog: Sendable {
    func label() -> String { "log" }
}

enum AppScopedKeys {
    static let audit = FactoryKey()
}

/// A lifted middleware `@Factory` that **also consumes the mocked slot** (the example's `audit` shape). Under
/// the key it's re-emitted as a variant factory: its mocked `@Inject` (`repository`) rides the per-request
/// `create(doubles:)` sourced from the doubles, and its non-mock `@Inject` (`log`) stays a held field.
@Factory(AppScopedKeys.audit)
struct AppScopedAudit {
    @Inject var repository: any AppScopedRepository
    @Inject var log: AppScopedLog

    func run() -> String { "\(repository.tag("audit")):\(log.label())" }
}

/// The app-scoped route contributor — `@Singleton` (not `@Scoped(seed:)`), reached through its plain
/// (non-bridge) contributor proxy in production, and rebuilt seedlessly per request under the variant. Injects
/// both the `@BindType`'d slot (rebuilt with the mock) and a non-mock singleton (borrowed), and carries a
/// mock-consuming lifted `@Factory` via `@RouteMiddleware`. `@TestScopable` marks it eligible for the
/// per-request rebuild — a property of the definition, on the type.
@TestScopable
@Singleton
@RouteController
@RouteMiddleware(AppScopedKeys.audit)
struct AppScopedController {
    @Inject var repository: any AppScopedRepository
    @Inject var log: AppScopedLog

    func tag() -> String { "\(repository.tag("routed")):\(log.label())" }
}

/// The test-graph variant: bind the slot to the mock, and `@Scopable` the app-scoped route contributor so the
/// variant rebuilds it per request (seedlessly) instead of orphaning it.
enum AppScopedFixture {
    @BindType(AppScopedRepository.self, MockAppScopedRepository.self)
    static let bindMock = TestingKey()
}

// --- Generic app-scoped route contributor over an OPAQUE mocked slot (the example's `TodosController<Repository>`
// shape). The subject is generic over the `@BindType`'d backend, bound opaquely (`some GenAppBackend`), so the
// seedless reconstruction concretizes it to `GenAppController<MockGenAppBackend>`. `@TestScopable` marks the
// generic type — a key-side `@Scopable(GenAppController.self)` couldn't spell an unbound generic's metatype.

protocol GenAppBackend: Sendable {
    func note(_ id: String) -> String
}

final class RealGenAppBackend: GenAppBackend {
    func note(_ id: String) -> String { "real:\(id)" }
}

final class MockGenAppBackend: GenAppBackend {
    private let calls = Mutex<[String]>([])

    func note(_ id: String) -> String {
        calls.withLock { $0.append(id) }
        return "mock:\(id)"
    }

    var recordedNotes: [String] { calls.withLock { $0 } }
}

/// Bound opaquely (`some GenAppBackend`) so the generic consumer lifts over it — the axis the variant drops.
enum GenAppBackendModule {
    @Provides static func backend() -> some GenAppBackend { RealGenAppBackend() }
}

enum GenAppKeys {
    static let audit = FactoryKey()
}

/// A mock-consuming lifted `@Factory` **generic over the injected mocked axis** (`@Inject var backend: Backend`,
/// where `Backend` is the `@BindType`'d slot) — the example's `AuditGate` shape. Under the key its `Backend`
/// generic concretizes to the mock and `create(doubles:)` sources `backend` from the doubles.
@Factory(GenAppKeys.audit)
struct GenAppAudit<Backend: GenAppBackend> {
    @Inject var backend: Backend

    func run() -> String { backend.note("audit") }
}

@TestScopable
@Singleton
@RouteController
@RouteMiddleware(GenAppKeys.audit)
struct GenAppController<Backend: GenAppBackend>: Sendable {
    @Inject var backend: Backend

    func note() -> String { backend.note("routed") }
}

enum GenAppScopedFixture {
    @BindType(GenAppBackend.self, MockGenAppBackend.self)
    static let bindMock = TestingKey()
}
