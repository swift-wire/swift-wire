import Synchronization
import Wire
import WireTesting
import WireTestLibrary

/// H2.2a factory-carrying-proxy regression — a `@RouteController @Scoped(seed:)` subject that also carries a
/// lifted `@Factory` (via `@RouteMiddleware(key)`), so its contributor proxy has a `_wireFactory_<key>` field
/// alongside the scope-entry thunk. The variant facade must bind that factory instance as a local (like the
/// production bootstrap body) before constructing the variant proxy — else the bare `_WireFactory_<key>`
/// reference resolves to the type, not an instance. A `@BindType`'d slot in the subject's subtree threads a
/// mock, driven through `proxy._wireEnterScope(seed, doubles)`.
struct FactoryProxyRequestSeed: Sendable {
    let id: String
}

protocol FactoryProxyRepository: Sendable {
    func tag(_ id: String) -> String
}

final class RealFactoryProxyRepository: FactoryProxyRepository {
    func tag(_ id: String) -> String { "real:\(id)" }
}

final class MockFactoryProxyRepository: FactoryProxyRepository {
    private let calls = Mutex<[String]>([])

    func tag(_ id: String) -> String {
        calls.withLock { $0.append(id) }
        return "mock:\(id)"
    }

    var recordedTags: [String] { calls.withLock { $0 } }
}

/// The `@BindType`d binding — an app-scoped `@Provides`.
enum FactoryProxyRepositoryModule {
    @Provides static func repository() -> any FactoryProxyRepository { RealFactoryProxyRepository() }
}

enum FactoryProxyKeys {
    static let probe = FactoryKey()
}

/// A `@Factory` template lifted onto the proxy through `@RouteMiddleware`. Dep-free, so its synthesised
/// factory (`_WireFactory_FactoryProxyKeys_probe`) constructs with a bare `()` — the case the facade must
/// bind as a local.
@Factory(FactoryProxyKeys.probe)
struct ProbeMiddleware {
    func run() -> String { "probe" }
}

/// The routed subject — carries the lifted factory (`@RouteMiddleware`) and injects the mocked repository.
@Scoped(seed: FactoryProxyRequestSeed.self, allowUnused: true)
@RouteController
@RouteMiddleware(FactoryProxyKeys.probe)
struct FactoryProxyRouteController {
    @Inject var repository: any FactoryProxyRepository
    @Inject var factoryProxyRequestSeed: FactoryProxyRequestSeed

    func tag() -> String { repository.tag("routed") }
}

/// The test-graph variant: bind the `FactoryProxyRepository` slot to `MockFactoryProxyRepository`.
enum FactoryProxyFixture {
    @BindType(FactoryProxyRepository.self, MockFactoryProxyRepository.self)
    static let bindMock = TestingKey()
}
