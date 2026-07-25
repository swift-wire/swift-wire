import Synchronization
import Wire

/// A slot the IntegrationTests `@Replaces` + `@BindType` composition test overrides. Published by this
/// Wire-aware library so the `@Replaces` in the consumer target supersedes a *dependency-module* binding
/// (a same-module `@Replaces` would be the rule-3 duplicate error) — the cross-module shape `@Replaces` is
/// for.
public protocol ComposeWidget: Sendable {
    func label() -> String
}

/// Bumped by `RealComposeWidget.init`. The `@Replaces` + `@BindType` gate asserts it stays zero — the real
/// binding must never be constructed in any graph (the `@Replaces` fake supersedes it everywhere).
public let realComposeWidgetInits = Atomic<Int>(0)

public struct RealComposeWidget: ComposeWidget {
    public init() { realComposeWidgetInits.add(1, ordering: .relaxed) }
    public func label() -> String { "real" }
}

/// The real, dependency-module binding for `any ComposeWidget` — composed into the consumer's graph, then
/// superseded there by the consumer's `@Replaces` fake.
public enum ComposeWidgetModule {
    @Provides public static func widget() -> any ComposeWidget { RealComposeWidget() }
}
