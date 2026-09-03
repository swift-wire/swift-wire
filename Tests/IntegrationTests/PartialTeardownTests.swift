import Testing

/// partial teardown's gate — a bootstrap that throws partway tears down what it had already built, in reverse, and
/// then rethrows the *original* error.
///
/// Serialized because both containers write to one module-scope recorder: a failed bootstrap returns no
/// graph, so there is nothing to hang a per-run recorder off, which is the one place this differs from
/// `ParallelSchedulerExample`.
@Suite("Partial teardown on init failure", .serialized)
struct PartialTeardownTests {
    @Test func aThrowingInitTearsDownWhatTheChainAlreadyBuilt() async throws {
        // The linear-chain shape. `ChainResource` is constructed, `ChainFailingConsumer` throws, and the
        // bootstrap must not abandon the resource on its way out.
        await #expect(throws: PartialTeardownFailure.self) {
            _ = try await Wire.bootstrapPartialTeardownContainer()
        }
        #expect(partialTeardownEvents(withPrefix: "chain.") == ["chain.built", "chain.closed"])
    }

    @Test func aThrowingInitTearsDownAScheduledBindingTheDrainHadResolved() async throws {
        // The scheduled shape, and the case the accumulator alone cannot reach: `ScheduledResource` is
        // built inside a method of the building struct, so its action is recovered from its *cell* by the
        // drain's own `catch` when a sibling task throws. Without that recovery this graph would unwind
        // with the resource still open.
        await #expect(throws: PartialTeardownFailure.self) {
            _ = try await Wire.bootstrapScheduledPartialTeardownContainer()
        }
        #expect(partialTeardownEvents(withPrefix: "scheduled.") == ["scheduled.built", "scheduled.closed"])
    }

    @Test func theOriginalErrorPropagatesRatherThanATeardownOne() async throws {
        // Teardown errors are discarded on this path deliberately: the caller is being told why the graph
        // could not be built, and the answer is the init that failed, not a secondary failure while
        // abandoning resources. Asserted by the error type surviving the unwind above.
        do {
            _ = try await Wire.bootstrapPartialTeardownContainer()
            Issue.record("bootstrap should have thrown")
        } catch is PartialTeardownFailure {
            // The construction's own error, not a teardown one.
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
