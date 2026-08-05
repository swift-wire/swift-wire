import Testing
import WireTestLibrary

/// Gates `.contributesAggregateProxy` — ONE synthesised proxy holding several subjects, each held or
/// bridged independently. See `AggregateProxyContributorExample.swift` for the fixture.
@Suite("Aggregate contributor proxy")
struct AggregateProxyContributorTests {

    @Test func oneProxyHoldsEveryAnnotatedSubject() async throws {
        // The aggregate is a single graph binding carrying all three subjects: two held (one of them
        // generic, making the proxy a lift node) and one bridged. Where `.contributesProxy` would have
        // synthesised three proxies, this is one.
        let graph = try await Wire.bootstrap()
        let aggregate = graph._WireAggregateContributor_alphaOfSomeAggregateSearchBackend

        #expect(aggregate._wireSubject_AggregateReportController.reports() == "r1,r2")
        #expect(aggregate._wireSubject_AggregateSearchController.search("swift") == "hit(swift)")

        // The multibinding receives ONE element for three annotated subjects — where `.contributesProxy`
        // would have contributed three separate proxies.
        // Two groups on one annotation → two aggregates in the multibinding, one per spec.
        #expect(graph.aggregateContributorHost.controllers.count == 2)
        #expect(graph.aggregateContributorHost.soloControllers.count == 1)
    }

    @Test func aBridgedSubjectIsBuiltPerRequestWhileHeldPeersAreShared() async throws {
        let graph = try await Wire.bootstrap()
        let aggregate = graph._WireAggregateContributor_alphaOfSomeAggregateSearchBackend

        let (first, firstTeardown) = try await aggregate._wireEnterScope_AggregateTaskController(
            AggregateRequestSeed(id: "bridge-a")
        )
        let (second, secondTeardown) = try await aggregate._wireEnterScope_AggregateTaskController(
            AggregateRequestSeed(id: "bridge-b")
        )

        // Hold vs bridge is decided per subject: the bridged subject is rebuilt per entry, carrying that
        // entry's seed…
        #expect(first.task("1") == "task 1 for user-bridge-a")
        #expect(second.task("2") == "task 2 for user-bridge-b")

        // …while the held peer on the same proxy IS the graph's own app-scoped singleton, not a rebuild.
        #expect(aggregate._wireSubject_AggregateReportController.store === graph.aggregateReportStore)

        // Request-scope teardown (M5.4.5) runs per entry, through the aggregate's own thunk. Asserted
        // against the seed, since every test in this process bootstraps the graph and they run in
        // parallel — a process-global construction count would be measuring the whole suite.
        #expect(await firstTeardown().isEmpty)
        #expect(AggregateConstructionLog.shared.count("teardown-bridge-a") == 1)
        #expect(await secondTeardown().isEmpty)
        #expect(AggregateConstructionLog.shared.count("teardown-bridge-b") == 1)
    }

    @Test func aSecondGroupOnTheSameAnnotationGetsItsOwnProxy() async throws {
        // `@AggregateController(spec: "beta")` groups separately from `spec: "alpha"`, so one annotation
        // yields two proxies — the multi-spec case. Grouping is declared at the use site because a
        // spec's generated types and its controllers routinely live in different modules.
        let graph = try await Wire.bootstrap()
        #expect(graph._WireAggregateContributor_beta._wireSubject.beta() == "beta")
    }

    @Test func aOneSubjectAggregateKeepsTheSingularFieldName() async throws {
        // The compatibility rule: with one subject there is nothing to disambiguate, so the field stays
        // `_wireSubject` — positional, exactly what `.contributesProxy` emits. This test compiles only if
        // that holds (a suffixed `_wireSubject_SoloAggregateOnlyController` would not resolve).
        //
        // The *type* name carries the group, and a bare annotation's group is the module it is written
        // in — here the test module. That is what makes a group stable: it does not depend on which
        // target consumes the annotation.
        let graph = try await Wire.bootstrap()
        #expect(graph._WireSoloAggregateContributor_IntegrationTests._wireSubject.solo() == "solo")
    }

    @Test func perRootReachabilitySurvivesTheAggregate() async throws {
        // M5.4.6 — the aggregate's scope entry constructs only the subgraph reachable from its own
        // bridged subject, so a seed-scoped sibling the subject can't reach is never built.
        let graph = try await Wire.bootstrap()
        let (subject, _) =
            try await graph
            ._WireAggregateContributor_alphaOfSomeAggregateSearchBackend
            ._wireEnterScope_AggregateTaskController(AggregateRequestSeed(id: "pruning"))

        #expect(subject.identity.userID == "user-pruning")
        #expect(AggregateConstructionLog.shared.count("unreachable-pruning") == 0)
    }
}
