import Synchronization
import Wire

/// H2.2a "B" gate — an eager `@BindType`'d binding whose backing `init` runs a side-effect. It is
/// constructed at app bootstrap (the `@Provides` is called by `_wireBootstrap()` because a `@Scoped(seed:)`
/// consumer borrows it), but under a `@BindType` variant it must NOT be constructed (the wire-mvc overlay
/// leak: a mocked CouchDB binding still connecting in its `init`). The variant app graph drops it; the
/// keyless path keeps it. Existential (`any`), so no opaque axis is dropped — the generic-subject
/// opaque-axis case is a later phase.
protocol EagerWidget: Sendable {
    func label() -> String
}

/// Bumped by `RealEagerWidget.init` — the observable side-effect (a CouchDB connect, a registry register).
/// The gate proves it can't run under the variant *structurally* (the binding is dropped from the variant
/// app graph, via `introspect()`), rather than by an absolute counter — the global counter can't be isolated
/// because every `Wire.bootstrap()` across the parallel suite bumps it.
let realEagerWidgetInits = Atomic<Int>(0)

/// Its `init` records — the observable side-effect that must not run under the mocked variant.
final class RealEagerWidget: EagerWidget {
    init() { realEagerWidgetInits.add(1, ordering: .relaxed) }
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
