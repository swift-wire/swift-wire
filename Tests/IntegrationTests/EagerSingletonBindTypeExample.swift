import Synchronization
import Wire
import WireTesting

/// The complete-replacement gate — an eager `@BindType`'d binding whose backing `init` runs a side-effect. It is
/// constructed at app bootstrap (the `@Provides` is called by `_wireBootstrap()` because a `@Scoped(seed:)`
/// consumer borrows it), but under a `@BindType` variant it must NOT be constructed (the wire-mvc overlay
/// leak: a mocked CouchDB binding still connecting in its `init`). The variant app graph drops it; the
/// keyless path keeps it. Existential (`any`), so no opaque axis is dropped — the generic-subject
/// opaque-axis case is a later phase.
protocol EagerWidget: Sendable {
    func label() -> String
}

/// Counts `RealEagerWidget.init`s (the observable side-effect — a CouchDB connect, a registry register).
/// A reference-type counter so the `@TaskLocal` can carry it: `Atomic` is `~Copyable` and a task-local
/// (copied into child tasks) can't hold one, so the atomic lives behind a `final class` reference.
final class EagerInitCounter: Sendable {
    private let value = Atomic<Int>(0)
    func increment() { value.add(1, ordering: .relaxed) }
    var count: Int { value.load(ordering: .relaxed) }
}

/// Task-local-scoped so it's isolated in the parallel suite: a bootstrap that binds a counter tallies only
/// its own `RealEagerWidget.init`s; an unrelated `Wire.bootstrap()` elsewhere (probe unbound → `nil`) doesn't
/// touch it. That lets the gate assert the side-effect *directly* — init count `0` under the variant.
enum EagerInitProbe {
    @TaskLocal static var current: EagerInitCounter?
}

/// Its `init` records into the current probe — the observable side-effect that must not run under the mock.
final class RealEagerWidget: EagerWidget {
    init() { EagerInitProbe.current?.increment() }
    func label() -> String { "real" }
}

/// The eager app binding for `any EagerWidget` — called by `_wireBootstrap()`, so `RealEagerWidget.init`
/// runs at bootstrap. Under the variant this whole binding is dropped from `_wireBootstrap<Variant>()`.
enum EagerWidgetModule {
    @Provides static func widget() -> any EagerWidget { RealEagerWidget() }
}

final class MockEagerWidget: EagerWidget {
    func label() -> String { "mock" }
}

struct EagerRequestSeed: Sendable {
    let id: String
}

/// A `@Scoped(seed:)` consumer injecting `any EagerWidget` — its scope borrows the app binding, so the app
/// binding is constructed at bootstrap in production, and lifted to `doubles.eagerWidget` under the variant.
@Scoped(seed: EagerRequestSeed.self, allowUnused: true)
struct EagerConsumer {
    @Inject var widget: any EagerWidget
    @Inject var eagerRequestSeed: EagerRequestSeed

    func label() -> String { widget.label() }
}

enum EagerFixture {
    @BindType(EagerWidget.self, MockEagerWidget.self)
    static let bindMock = TestingKey()
}
