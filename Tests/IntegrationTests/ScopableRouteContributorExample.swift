import Synchronization
import Wire
import WireTestLibrary

/// Phase-1 gate for seedless `@Scopable` — an **app-scoped** (`@Singleton`) route contributor that consumes a
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

/// The app-scoped route contributor — `@Singleton` (not `@Scoped(seed:)`), reached through its plain
/// (non-bridge) contributor proxy in production, and rebuilt seedlessly per request under the variant. Injects
/// both the `@BindType`'d slot (rebuilt with the mock) and a non-mock singleton (borrowed). `@TestScopable`
/// marks it eligible for the per-request rebuild — a property of the definition, on the type.
@TestScopable
@Singleton
@RouteController
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
    func note(_ id: String) -> String { "mock:\(id)" }
}

/// Bound opaquely (`some GenAppBackend`) so the generic consumer lifts over it — the axis the variant drops.
enum GenAppBackendModule {
    @Provides static func backend() -> some GenAppBackend { RealGenAppBackend() }
}

@TestScopable
@Singleton
@RouteController
struct GenAppController<Backend: GenAppBackend>: Sendable {
    @Inject var backend: Backend

    func note() -> String { backend.note("routed") }
}

enum GenAppScopedFixture {
    @BindType(GenAppBackend.self, MockGenAppBackend.self)
    static let bindMock = TestingKey()
}
