import Synchronization
import Wire
import WireTestLibrary

/// PendingIssues/21 — a **scope entry** that throws partway tears down the scope bindings it had already
/// built, in reverse, before the original error reaches the caller.
///
/// M7c.5 gave this to the app bootstrap and left scope entry without it. The gap is worse here than it was
/// there, and for the reason M4's deferral does *not* transfer: a failed bootstrap ends in process exit, so
/// the OS reclaims the half-built resources, while a failed scope entry leaks per request in a process that
/// keeps serving.
///
/// **Two scopes, because M7c.6 left two construction shapes here too.** `ChainScopeSeed`'s scope is wholly
/// synchronous, so it is the linear chain; `GroupScopeSeed`'s has an independent async pair, so it takes
/// the scheduler — and its torn binding sits **in the group region**, which is the case the accumulator
/// cannot reach at its construction site and the drain's own `catch` has to recover from a cell.
///
/// Both are entered through their own `@AggregateController` spec group, so neither perturbs the others.

/// Shared across entries, because a thrown scope entry returns nothing to hang a per-entry recorder off —
/// the same reason `PartialTeardownExample` uses a module-scope one. Each scope writes under its own
/// prefix, and the suite is serialized.
package let scopePartialTeardownLog = Mutex<[String]>([])

package func recordScopeTeardown(_ event: String) {
    scopePartialTeardownLog.withLock { $0.append(event) }
}

package func scopeTeardownEvents(withPrefix prefix: String) -> [String] {
    scopePartialTeardownLog.withLock { $0.filter { $0.hasPrefix(prefix) } }
}

package struct ScopeEntryFailure: Error {}

// MARK: - the linear-chain scope

package struct ChainScopeSeed: Sendable {
    package let id: String
}

/// Built first, and the thing that must be torn down when the entry fails.
@Scoped(seed: ChainScopeSeed.self, allowUnused: true)
package final class ChainScopeResource: Sendable {
    @Inject package init() {
        recordScopeTeardown("chain.built")
    }

    @Teardown
    package func close() async {
        recordScopeTeardown("chain.closed")
    }
}

/// Downstream of it, and throws — so the thunk unwinds with the resource already live.
@Scoped(seed: ChainScopeSeed.self, allowUnused: true)
@AggregateController(spec: "chainUnwind")
package struct ChainScopeController: Sendable {
    @Inject package init(resource: ChainScopeResource) throws {
        throw ScopeEntryFailure()
    }
}

// MARK: - the scheduled scope

package struct GroupScopeSeed: Sendable {
    package let id: String
}

/// One half of the pair, and the reason this scope schedules.
@Scoped(seed: GroupScopeSeed.self, allowUnused: true)
package struct GroupScopeSignal: Sendable {
    @Inject package init() async throws {
        try await Task.sleep(for: .milliseconds(1))
    }
}

/// Waits on the signal only — a proper subset of the scope's Overlap — so it is built **inside the group**,
/// where its teardown action cannot be recorded at its construction site.
@Scoped(seed: GroupScopeSeed.self, allowUnused: true)
package final class GroupScopeResource: Sendable {
    @Inject package init(signal: GroupScopeSignal) {
        recordScopeTeardown("group.built")
    }

    @Teardown
    package func close() async {
        recordScopeTeardown("group.closed")
    }
}

/// The other half of the pair, and the failure. Waits until the group's resource has been built before
/// throwing — bounded at a second — so the scope is unwound from a state where a *scheduled* `@Teardown`
/// binding really had resolved.
@Scoped(seed: GroupScopeSeed.self, allowUnused: true)
package struct GroupScopeFailure: Sendable {
    @Inject package init() async throws {
        for _ in 0..<200 {
            if scopeTeardownEvents(withPrefix: "group.").contains("group.built") { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw ScopeEntryFailure()
    }
}

@Scoped(seed: GroupScopeSeed.self, allowUnused: true)
@AggregateController(spec: "groupUnwind")
package struct GroupScopeController: Sendable {
    @Inject package init(resource: GroupScopeResource, failure: GroupScopeFailure) {}
}
