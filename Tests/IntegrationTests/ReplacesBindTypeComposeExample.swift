import Synchronization
import Wire
import WireTesting
import WireTestLibrary

/// H2.2a `@Replaces` + `@BindType` composition — the precedence chain per type:
///     real binding → `@Replaces` (all graphs) → `@BindType` (its keyed variant only, wins)
/// The library's real `any ComposeWidget` is superseded by this target's `@Replaces` fake in *every* graph;
/// a `TestingKey`'s `@BindType` then supersedes it again, but only in that keyed variant. So the keyless
/// scope-entry resolves to Fake, the keyed variant resolves to Mock, and the real binding is never built.
/// `ReplacesBindTypeComposeTests` proves it compiles (no `multiple bindings; ambiguous`) and resolves right.
struct ComposeRequestSeed: Sendable {
    let id: String
}

/// The `@Replaces` fake — supersedes the library's real `ComposeWidget` in ALL graphs (default + variant).
struct FakeComposeWidget: ComposeWidget {
    func label() -> String { "fake" }
}

enum FakeComposeWidgetModule {
    @Provides
    @Replaces
    static func widget() -> any ComposeWidget { FakeComposeWidget() }
}

/// The `@BindType` mock — supersedes `ComposeWidget` in the keyed variant only.
final class MockComposeWidget: ComposeWidget {
    func label() -> String { "mock" }
}

/// A `@Scoped(seed:)` consumer of `ComposeWidget` — reads the slot back so each scope-entry proves which
/// binding won.
@Scoped(seed: ComposeRequestSeed.self, allowUnused: true)
struct ComposeConsumer {
    @Inject var widget: any ComposeWidget
    @Inject var composeRequestSeed: ComposeRequestSeed

    func label() -> String { widget.label() }
}

/// The test-graph variant: bind the `ComposeWidget` slot to `MockComposeWidget`, on top of the `@Replaces`.
enum ComposeFixture {
    @BindType(ComposeWidget.self, MockComposeWidget.self)
    static let bindMock = TestingKey()
}
