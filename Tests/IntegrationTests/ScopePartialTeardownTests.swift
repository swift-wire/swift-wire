import Testing

/// PendingIssues/21's gate — a scope entry that throws unwinds what it had already built.
///
/// Serialized because both scopes write to one module-scope recorder: a thrown entry returns nothing to
/// hang a per-entry recorder off, which is the same constraint `PartialTeardownTests` works under.
@Suite("Scope-entry partial teardown", .serialized)
struct ScopePartialTeardownTests {
    @Test func aThrowingScopeEntryTearsDownWhatTheChainAlreadyBuilt() async throws {
        // The linear-chain shape. `ChainScopeResource` is built, the controller's init throws, and the
        // thunk must not abandon the resource on its way out.
        let graph = try await Wire.bootstrap()
        await #expect(throws: ScopeEntryFailure.self) {
            _ = try await graph._WireAggregateContributor_chainUnwind._wireEnterScope(
                ChainScopeSeed(id: "chain")
            )
        }
        #expect(scopeTeardownEvents(withPrefix: "chain.") == ["chain.built", "chain.closed"])
    }

    @Test func aThrowingScopeEntryTearsDownAScheduledBindingTheDrainHadResolved() async throws {
        // The scheduled shape, and the case the accumulator alone cannot reach: `GroupScopeResource` is
        // built inside a method of the thunk's building struct, so its action is recovered from its *cell*
        // by the drain's own `catch` when the sibling task throws.
        let graph = try await Wire.bootstrap()
        await #expect(throws: ScopeEntryFailure.self) {
            _ = try await graph._WireAggregateContributor_groupUnwind._wireEnterScope(
                GroupScopeSeed(id: "group")
            )
        }
        #expect(scopeTeardownEvents(withPrefix: "group.") == ["group.built", "group.closed"])
    }

    @Test func eachFailedEntryUnwindsOnlyItsOwn() async throws {
        // Per request means per request on the failure path too: a second failing entry tears down its own
        // resource, not the first's again.
        let graph = try await Wire.bootstrap()
        let before = scopeTeardownEvents(withPrefix: "chain.").count
        await #expect(throws: ScopeEntryFailure.self) {
            _ = try await graph._WireAggregateContributor_chainUnwind._wireEnterScope(
                ChainScopeSeed(id: "second")
            )
        }
        // Exactly one more construction and one more teardown, not a replay of the earlier entry's.
        #expect(scopeTeardownEvents(withPrefix: "chain.").count == before + 2)
    }
}
