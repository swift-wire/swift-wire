import Wire

/// A `public @Singleton` published by an external Wire-aware library. The
/// consumer composes it across a package boundary; `public` (and a public
/// `@Inject init`) satisfies the cross-module visibility threshold (7f).
@Singleton
public struct ExternalService {
    public let name: String

    @Inject
    public init() {
        self.name = "external"
    }
}

extension ExternalService {
    /// A named key published by the library, referenced by the consumer
    /// across the package boundary — exercises cross-module key resolution
    /// (7a's tracking + 7f's "key in the parse set" widening).
    public static let primary = BindingKey<ExternalService>()
}

/// A second, keyed binding of `ExternalService` so the consumer can
/// `@Inject(ExternalService.primary)` across modules alongside the unkeyed
/// `@Singleton`.
@Provides(ExternalService.primary)
public func makePrimaryExternalService() -> ExternalService {
    ExternalService()
}

/// A `public @Singleton` the consumer never reaches — the M7b.2 gate.
///
/// Reachability pruning has to drop this from the consumer's graph: nothing injects it, no conformance
/// names it, and a *library's* `allowUnused` is ignored for reachability. Construction traps, so a
/// regression is loud and behavioural rather than a diff in generated text — if the consumer emits the
/// property, bootstrapping it aborts the harness.
@Singleton
public struct UnreachedExternalService {
    @Inject
    public init() {
        fatalError("UnreachedExternalService was constructed — reachability pruning (M7b.2) should have dropped it")
    }
}

/// A key the *consumer* declares a conformance over, contributed to from here — the other half of the
/// gate. This one must survive: the aggregate is rooted by the graph conformance, so an external
/// contributor stays reachable even though nothing `@Inject`s the collection.
public protocol HarnessRouteContributor: Sendable {
    var label: String { get }
}

@Singleton @Contributes(to: HarnessRouteKeys.contributors)
public struct ExternalRouteContributor: HarnessRouteContributor {
    public let label = "external-route"

    @Inject
    public init() {}
}

public enum HarnessRouteKeys {
    public static let contributors = CollectedKey<any HarnessRouteContributor>()
}
