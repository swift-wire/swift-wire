import Synchronization
import Wire
import WireTestLibrary

/// scheduled scope entry — an async **request scope**: the case the construction scheduler was built for and had never
/// been pointed at.
///
/// Every other scope in this corpus is wholly synchronous, which is a gap in the fixtures rather than a
/// fact about applications — a controller that loads two independent things before it can serve is the
/// ordinary shape, and per-request construction is the *hot* path, unlike app bootstrap which runs once.
/// So this scope is built to have the same structure `ParallelSchedulerExample` gives the app graph, one
/// level down: two independent async bindings, a dependent of the faster one, and a `@Teardown` binding to
/// keep the scope's own teardown closure in the picture.
///
/// Entered through a bridged contributor proxy (`@AggregateController`), which is what puts it on
/// `ScopeEntryEmission`'s per-request thunk rather than on the whole-scope façade. Its own spec group, so
/// it neither joins nor perturbs `AggregateProxyContributorExample`'s two.
///
/// **Observed rather than timed, and order-independent.** `ParallelSchedulerExample` has its slow binding
/// wait for a dependent, which works there because the topological order puts the slow one first. Here it
/// does not, and that assertion would pass under serial construction too — so instead **each half waits for
/// the other to have started**. Serial construction cannot satisfy that at all: whichever runs first waits
/// out its bound and reports that it never saw its partner. Concurrent construction settles it in one poll
/// interval, whatever order the sort happens to produce.

package struct AsyncScopeSeed: Sendable {
    package let id: String
}

@Scoped(seed: AsyncScopeSeed.self, allowUnused: true)
package final class AsyncScopeClock: Sendable {
    private let events = Mutex<[String]>([])

    @Inject package init() {}

    package func record(_ event: String) {
        events.withLock { $0.append(event) }
    }

    package var timeline: [String] {
        events.withLock { $0 }
    }

    /// Record that this binding started, then wait for the other one to do the same. Answers whether the
    /// partner was seen — `false` means the wait timed out, which is what serial construction produces.
    package func waitForPartner(recording mine: String, awaiting theirs: String) async throws -> Bool {
        record("\(mine).started")
        for _ in 0..<200 {
            if timeline.contains("\(theirs).started") { return true }
            try await Task.sleep(for: .milliseconds(5))
        }
        return false
    }
}

/// One half of the scope's Overlap pair. Records that it started, then waits for its partner to record the
/// same — bounded at a second, so a regression fails the assertion rather than hanging the suite.
@Scoped(seed: AsyncScopeSeed.self, allowUnused: true)
package struct AsyncScopeFast: Sendable {
    package let label = "fast"
    /// Whether the other half had started by the time this one finished. Serial construction cannot make
    /// this true for both.
    package let sawPartner: Bool

    @Inject package init(clock: AsyncScopeClock) async throws {
        self.sawPartner = try await clock.waitForPartner(recording: "fast", awaiting: "slow")
    }
}

/// The other half, and independent of the first — which is what makes them the scope's Overlap pair.
@Scoped(seed: AsyncScopeSeed.self, allowUnused: true)
package struct AsyncScopeSlow: Sendable {
    package let label = "slow"
    package let sawPartner: Bool

    @Inject package init(clock: AsyncScopeClock) async throws {
        self.sawPartner = try await clock.waitForPartner(recording: "slow", awaiting: "fast")
    }
}

/// Waits on the fast binding only — a proper subset of the scope's Overlap — so it is built during the
/// drain, while the slow one is still suspended.
@Scoped(seed: AsyncScopeSeed.self, allowUnused: true)
package struct AsyncScopeDependent: Sendable {
    package let observed: String

    @Inject package init(fast: AsyncScopeFast, clock: AsyncScopeClock) {
        self.observed = fast.label
        clock.record("dependent.built")
    }
}

/// A scope-scoped resource with a teardown, so the scope's own `_wireScopeTeardown` closure has to keep
/// working across the seam the scheduler introduces.
@Scoped(seed: AsyncScopeSeed.self, allowUnused: true)
package final class AsyncScopeSession: Sendable {
    private let closed = Mutex<Bool>(false)

    @Inject package init() {}

    @Teardown
    package func close() async {
        closed.withLock { $0 = true }
    }

    package var isClosed: Bool { closed.withLock { $0 } }
}

/// The subject. Waits on both halves of the pair, so it is the scope's serial suffix — built after the
/// drain, on locals, exactly as a suffix binding is in the app graph.
@Scoped(seed: AsyncScopeSeed.self, allowUnused: true)
@AggregateController(spec: "async")
package struct AsyncScopeController: Sendable {
    @Inject package var clock: AsyncScopeClock
    @Inject package var dependent: AsyncScopeDependent
    @Inject package var slow: AsyncScopeSlow
    @Inject package var session: AsyncScopeSession
    @Inject package var asyncScopeSeed: AsyncScopeSeed

    package func timeline() -> [String] { clock.timeline }
    package func describe() -> String { "\(asyncScopeSeed.id):\(dependent.observed):\(slow.label)" }
}
