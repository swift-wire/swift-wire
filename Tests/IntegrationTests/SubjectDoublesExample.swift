import Synchronization
import Wire
import WireTestLibrary
import WireTesting

/// Per-subject doubles fixture — the case every other `@BindType` fixture leaves untested, because they all
/// carry a single mocked slot and so cannot tell a per-subject set apart from the key-wide one.
///
/// Here the key declares **two** slots and three routed subjects share one seed: `SubjectAlphaController` reaches
/// only the alpha slot (and reaches it *transitively*, through a scope-bound hop, so the BFS has to walk more
/// than direct injection), `SubjectBetaController` reaches only the beta slot, and `SubjectPlainController` reaches neither.
/// Because a seed scope is partitioned by seed type, all three share one scope and one `doublesFields` — so a
/// per-subject struct that is not pruned would hand each of them both fields.
///
/// `SubjectDoublesTests` asserts each subject's struct carries exactly its own slot, and that the key-wide
/// struct still carries both.

/// Seed value for the request scope.
struct SubjectSeed: Sendable {
    let id: String
}

protocol SubjectAlphaBackend: Sendable {
    func alpha(_ id: String) -> String
}

protocol SubjectBetaBackend: Sendable {
    func beta(_ id: String) -> String
}

final class RealSubjectAlphaBackend: SubjectAlphaBackend {
    func alpha(_ id: String) -> String { "real-alpha:\(id)" }
}

final class RealSubjectBetaBackend: SubjectBetaBackend {
    func beta(_ id: String) -> String { "real-beta:\(id)" }
}

final class MockSubjectAlphaBackend: SubjectAlphaBackend {
    private let calls = Mutex<[String]>([])
    func alpha(_ id: String) -> String {
        calls.withLock { $0.append(id) }
        return "mock-alpha:\(id)"
    }
    var recordedCalls: [String] { calls.withLock { $0 } }
}

final class MockSubjectBetaBackend: SubjectBetaBackend {
    private let calls = Mutex<[String]>([])
    func beta(_ id: String) -> String {
        calls.withLock { $0.append(id) }
        return "mock-beta:\(id)"
    }
    var recordedCalls: [String] { calls.withLock { $0 } }
}

enum SubjectSlotModule {
    @Provides static func alpha() -> any SubjectAlphaBackend { RealSubjectAlphaBackend() }
    @Provides static func beta() -> any SubjectBetaBackend { RealSubjectBetaBackend() }
}

/// The transitive hop — `SubjectAlphaController` reaches the alpha slot only through this, so a per-subject set that
/// only looked at direct injection would miss it.
@Scoped(seed: SubjectSeed.self, allowUnused: true)
struct SubjectAlphaService {
    @Inject var backend: any SubjectAlphaBackend

    func run(_ id: String) -> String { backend.alpha(id) }
}

/// Reaches the alpha slot transitively, and the beta slot not at all.
@Scoped(seed: SubjectSeed.self, allowUnused: true)
@RouteController
struct SubjectAlphaController {
    @Inject var service: SubjectAlphaService
    @Inject var subjectSeed: SubjectSeed

    func tag() -> String { service.run(subjectSeed.id) }
}

/// Reaches the beta slot directly, and the alpha slot not at all.
@Scoped(seed: SubjectSeed.self, allowUnused: true)
@RouteController
struct SubjectBetaController {
    @Inject var backend: any SubjectBetaBackend
    @Inject var subjectSeed: SubjectSeed

    func tag() -> String { backend.beta(subjectSeed.id) }
}

/// Reaches neither slot — its per-subject struct has no fields at all, so a test for this route supplies
/// nothing. Under the key-wide struct it would still have to name both mocks.
@Scoped(seed: SubjectSeed.self, allowUnused: true)
@RouteController
struct SubjectPlainController {
    @Inject var subjectSeed: SubjectSeed

    func tag() -> String { "plain:\(subjectSeed.id)" }
}

/// The test-graph variant: both slots mocked under one key.
enum SubjectDoublesFixture {
    @BindType(SubjectAlphaBackend.self, MockSubjectAlphaBackend.self)
    @BindType(SubjectBetaBackend.self, MockSubjectBetaBackend.self)
    static let bindBoth = TestingKey()
}
