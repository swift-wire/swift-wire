import Synchronization
import Wire
import WireTestLibrary

/// H2.2a regression fixture — the borrow case the original proxy gate missed. A non-generic
/// `@RouteController @Scoped(seed:)` subject that injects a **plain app `@Singleton`** (a `UserStore`-style
/// store, neither `@BindType`'d nor `@Scopable`-lifted) alongside its mocked request-scoped dependency. The
/// variant scope *borrows* that singleton from the reused graph, so the facade must bind it as a Sendable
/// local outside the `@Sendable` scope-entry thunk (else the thunk captures the non-Sendable `_WireGraph`).
/// `BorrowingProxyContributorTests` asserts it compiles, the mock is reached (with the borrowed store's
/// value), the teardown runs, and a sibling sharing the seed is pruned.
struct BorrowRequestSeed: Sendable {
    let id: String
}

/// A plain app `@Singleton` the routed subject injects but the variant neither mocks nor lifts — so the
/// variant scope borrows it from the graph.
@Singleton
final class BorrowStore: Sendable {
    let name: String

    @Inject init() { self.name = "store" }
}

protocol BorrowRepository: Sendable {
    func tag(_ id: String) -> String
}

final class RealBorrowRepository: BorrowRepository {
    func tag(_ id: String) -> String { "real:\(id)" }
}

final class MockBorrowRepository: BorrowRepository {
    private let calls = Mutex<[String]>([])

    func tag(_ id: String) -> String {
        calls.withLock { $0.append(id) }
        return "mock:\(id)"
    }

    var recordedTags: [String] { calls.withLock { $0 } }
}

/// The `@BindType`d binding — an app-scoped `@Provides`.
enum BorrowRepositoryModule {
    @Provides static func repository() -> any BorrowRepository { RealBorrowRepository() }
}

/// A request-scoped resource with a `@Teardown`, reachable from the routed subject — records through the mock
/// so the test observes teardown.
@Scoped(seed: BorrowRequestSeed.self, allowUnused: true)
final class BorrowSession: Sendable {
    private let repository: any BorrowRepository

    @Inject init(repository: any BorrowRepository) {
        self.repository = repository
    }

    @Teardown
    func close() { _ = repository.tag("teardown") }
}

/// The routed subject — injects the borrowed app `@Singleton` (`store`), the mocked repository, and the
/// teardown resource. Its `tag()` reads the mock keyed by the borrowed store's value, proving both flow.
@Scoped(seed: BorrowRequestSeed.self, allowUnused: true)
@RouteController
struct BorrowRouteController {
    @Inject var store: BorrowStore
    @Inject var repository: any BorrowRepository
    @Inject var session: BorrowSession
    @Inject var borrowRequestSeed: BorrowRequestSeed

    func tag() -> String { repository.tag(store.name) }
}

/// A sibling seed-scoped subject sharing the seed — records `"sibling"` at `init`, but is unreachable from
/// the routed subject, so this entry must not construct it (per-root pruning).
@Scoped(seed: BorrowRequestSeed.self, allowUnused: true)
struct BorrowSiblingController {
    let marker: String

    @Inject init(repository: any BorrowRepository, seed: BorrowRequestSeed) {
        self.marker = repository.tag("sibling")
    }
}

/// The test-graph variant: bind the `BorrowRepository` slot to `MockBorrowRepository`. `BorrowStore` stays a
/// plain, borrowed app singleton.
enum BorrowFixture {
    @BindType(BorrowRepository.self, MockBorrowRepository.self)
    static let bindMock = TestingKey()
}
