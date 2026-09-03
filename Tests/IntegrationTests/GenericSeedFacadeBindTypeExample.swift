import Wire
import WireTesting

/// Seed-façade generic gate — a plain (non-route) generic `@Scoped(seed:)` subject over an opaque
/// `@BindType`'d backend, entered via the seed façade (`Wire.bootstrap<Variant>_<Seed>Scope`) rather than a
/// contributor proxy. Locks the opaque-axis drop + concretization on the seed-façade path: the variant app
/// graph drops the mocked `some GenBackend` axis (re-indexing its remaining opaque axes), and the scope
/// spells the subject `GenSeedConsumer<MockGenBackend>` concretely rather than the illegal stored `some P`.
protocol GenBackend: Sendable {
    func label() -> String
}

final class RealGenBackend: GenBackend {
    func label() -> String { "real" }
}

final class MockGenBackend: GenBackend {
    func label() -> String { "mock" }
}

/// Bound opaquely (`some GenBackend`) so the generic consumer lifts over it — the opaque axis the variant
/// drops.
enum GenBackendModule {
    @Provides static func backend() -> some GenBackend { RealGenBackend() }
}

struct GenSeedRequestSeed: Sendable {
    let id: String
}

/// The seed-scoped subject, generic over the mocked backend — under the key its slot resolves to the
/// concrete `MockGenBackend`, so the variant subject fully concretizes to `GenSeedConsumer<MockGenBackend>`.
@Scoped(seed: GenSeedRequestSeed.self, allowUnused: true)
struct GenSeedConsumer<B: GenBackend>: Sendable {
    @Inject var backend: B
    @Inject var genSeedRequestSeed: GenSeedRequestSeed

    func label() -> String { backend.label() }
}

enum GenSeedFixture {
    @BindType(GenBackend.self, MockGenBackend.self)
    static let bindMock = TestingKey()
}
