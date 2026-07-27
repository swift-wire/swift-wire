import Synchronization
import Wire
import WireTestLibrary

/// H2.2a runtime fixture — the doubles-threaded contributor-proxy scope entry. A `@RouteController`-marked
/// `@Scoped(seed:)` subject is reached, in production, through a bridging contributor proxy whose
/// `_wireEnterScope(seed)` thunk constructs it fresh per request (returning `(subject, teardown)`, pruned to
/// the subject's reachable subgraph). This fixture drives the *variant* proxy the M6a testing key emits:
/// `Wire.bootstrap<Variant>_<Subject>Contributor(wireGraph:)` builds a variant proxy whose
/// `_wireEnterScope(seed, doubles:)` threads the key's `_<Key>Doubles`, so a `@BindType`d dependency resolves
/// to the supplied mock — including at the `init` of a `@Scopable` singleton lifted into the scope.
///
/// `BindTypeProxyContributorTests` drives it and asserts, over the returned proxy, the three distinguishing
/// properties the shipped seed-scope *facade* loses: (a) the mock is read at the lifted singleton's `init`,
/// (b) the returned teardown runs, and (c) a sibling seed-scoped subject sharing the seed is not constructed.

/// Counts `RealProxyRepository` constructions — the phase-2 eager-singleton leak probe. Under
/// `Wire.bootstrap()` the eager `ProxyAccountController` forces one construction at app bootstrap; under
/// `Wire.bootstrap<Variant>()` the `@Scopable`-lifted controller is dropped from the variant app graph, so
/// the real repository is never constructed. Task-local-scoped for the parallel suite (see
/// `EagerSingletonBindTypeExample`).
final class ProxyInitCounter: Sendable {
    private let value = Atomic<Int>(0)
    func increment() { value.add(1, ordering: .relaxed) }
    var count: Int { value.load(ordering: .relaxed) }
}

enum ProxyInitProbe {
    @TaskLocal static var current: ProxyInitCounter?
}

/// Seed value for the request scope — carries an id.
struct ProxyRequestSeed: Sendable {
    let id: String
}

/// The slot under test. Existential so producer and consumer match directly.
protocol ProxyRepository: Sendable {
    func tag(_ id: String) -> String
}

/// The production binding — replaced by `MockProxyRepository` under the key. Its `init` records into the
/// leak probe: constructed once under `Wire.bootstrap()` (forced by the eager controller), never under the
/// variant graph.
final class RealProxyRepository: ProxyRepository {
    init() { ProxyInitProbe.current?.increment() }
    func tag(_ id: String) -> String { "real:\(id)" }
}

/// A test-held mock recording every call, so the assertions can prove the exact supplied instance flowed
/// through the reconstructed singleton's `init` *and* the scope teardown, and that a pruned sibling never
/// ran.
final class MockProxyRepository: ProxyRepository {
    private let calls = Mutex<[String]>([])

    func tag(_ id: String) -> String {
        calls.withLock { $0.append(id) }
        return "mock:\(id)"
    }

    var recordedTags: [String] { calls.withLock { $0 } }
}

/// The `@BindType`d binding — an app-scoped (module-scope) `@Provides`.
enum ProxyRepositoryModule {
    @Provides static func repository() -> any ProxyRepository { RealProxyRepository() }
}

/// The app-scoped consumer that reads its `@BindType`d dependency **in `init`** — the property Phase 2 mocks.
/// `@TestScopable` lifts it into the scope under test so this read sees the per-entry double.
@TestScopable
@Singleton
final class ProxyAccountController: Sendable {
    let tag: String

    @Inject init(repository: any ProxyRepository) {
        self.tag = repository.tag("init")
    }
}

/// A request-scoped resource with a `@Teardown` — reachable from the routed subject, so the returned
/// teardown runs its `close()`. It records through the same mock, so the test observes teardown by the tag.
@Scoped(seed: ProxyRequestSeed.self, allowUnused: true)
final class ProxySession: Sendable {
    private let repository: any ProxyRepository

    @Inject init(repository: any ProxyRepository) {
        self.repository = repository
    }

    @Teardown
    func close() { _ = repository.tag("teardown") }
}

/// The routed subject — a `@Scoped(seed:)` `@RouteController`, reached through its bridging contributor
/// proxy. Injects the lifted singleton (for the init-time read) and the teardown resource.
@Scoped(seed: ProxyRequestSeed.self, allowUnused: true)
@RouteController
struct ProxyRouteController {
    @Inject var controller: ProxyAccountController
    @Inject var session: ProxySession
    @Inject var proxyRequestSeed: ProxyRequestSeed

    func tag() -> String { controller.tag }
}

/// A sibling seed-scoped subject sharing the seed — it injects the repository and would record `"sibling"`
/// at `init`, but it is unreachable from the routed subject, so the routed entry must not construct it
/// (per-root pruning).
@Scoped(seed: ProxyRequestSeed.self, allowUnused: true)
struct ProxySiblingController {
    let marker: String

    @Inject init(repository: any ProxyRepository, seed: ProxyRequestSeed) {
        self.marker = repository.tag("sibling")
    }
}

/// The test-graph variant: bind the `ProxyRepository` slot to `MockProxyRepository`, and permit the cascade
/// to lift the app-scoped `ProxyAccountController` into the scope under test.
enum WireProxyFixture {
    @BindType(ProxyRepository.self, MockProxyRepository.self)
    static let bindMock = TestingKey()
}
