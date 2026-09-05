// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Testing

/// The scheduling trigger's gate — a dependent of a fast async binding is constructed before a slow, independent async
/// binding finishes.
///
/// This is the one thing the task group buys and the sequential form cannot produce, so it is asserted on
/// the graph's own behaviour rather than on the emitted text (which `GoldenHarness` guards) or on elapsed
/// time (which a loaded runner decides). See `ParallelSchedulerExample` for why the fixture observes an
/// ordering instead of racing two sleeps.
@Suite("Parallel scheduled construction")
struct ParallelSchedulerTests {
    @Test func aDependentOfTheFastBindingRunsBeforeTheSlowOneFinishes() async throws {
        let graph = try await Wire.bootstrapParallelSchedulerContainer()
        // Recorded inside `FastDependent.init` — the direct form of the claim, taken at the moment that
        // matters rather than reconstructed afterwards.
        #expect(graph.fastDependent.sawSlowAlready == false)
        // And the timeline from the other side: the slow binding was still suspended, waiting, when the
        // dependent was built. Sequential construction inverts this pair.
        #expect(graph.constructionClock.timeline == ["dependent", "slow"])
    }

    @Test func bothIndependentAsyncBindingsStillResolve() async throws {
        // The scheduler must not lose a child result: the drain runs until the group empties, and every
        // cell the memberwise init takes from has to have reached `.resolved`.
        let graph = try await Wire.bootstrapParallelSchedulerContainer()
        #expect(graph.fastSignal.label == "fast")
        #expect(graph.slowSignal.label == "slow")
        #expect(graph.fastDependent.signal.label == "fast")
    }
}
