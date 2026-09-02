import Testing

/// M7c.2 — behaviour of a graph built through the construction state struct rather than the linear chain.
///
/// These assert *what the graph is*, not what it looks like: the emitted text is guarded by
/// `GoldenHarness`, but the note's finding is that the noncopyable spellings pass `-typecheck` and fail at
/// `-c`, so the load-bearing gate is that this compiles and runs at all.
@Suite("Scheduled construction")
struct SchedulerContainerTests {
    @Test func fanInConsumerSeesEveryDependencyResolved() async throws {
        // `SchedulerService` depends on two async bindings and one sync non-Sendable one, so no source
        // ordering resolves it — it is fired three times and constructs on the last, when its guard
        // finally passes. Reading all three fields back is the assertion that the cascade waited.
        let graph = try await Wire.bootstrapSchedulerContainer()
        #expect(graph.schedulerService.describe() == "config:scheduled:0")
    }

    @Test func aNonSendableBindingIsSharedNotReconstructed() async throws {
        // The note's central claim in executable form. `SchedulerCounter` is a non-Sendable class that
        // lives in a cell and is read as a dependency across both async bindings' suspensions under
        // `-strict-concurrency=complete`. `value()` copies the *reference*, so the graph's property and
        // the service's field must be one object — a re-construction would give the service its own.
        let graph = try await Wire.bootstrapSchedulerContainer()
        #expect(graph.schedulerCounter.bump() == 1)
        #expect(graph.schedulerService.counter.count == 1)
        #expect(graph.schedulerService.counter === graph.schedulerCounter)
    }

    @Test func anAggregateResolvesThroughTheCascadeInContributorOrder() async throws {
        // The `.aggregate` binding is fired by each contributor and folds on the second, then cascades
        // into its own consumer — two cascade hops, neither of which the source order performs.
        let graph = try await Wire.bootstrapSchedulerContainer()
        #expect(graph.probeHost.ids() == ["alpha", "beta"])
    }

    @Test func aScheduledGraphStillIntrospectsEveryBinding() async throws {
        // Introspection describes what was *built*, so the scheduled form must not narrow it — the
        // contributors are constructed and reachable here even though neither is a stored property.
        let graph = try await Wire.bootstrapSchedulerContainer()
        let types = Set(graph.introspect().bindings.map(\.type))
        #expect(types.contains("SchedulerService"))
        #expect(types.contains("AlphaProbe"))
        #expect(types.contains("BetaProbe"))
    }
}
