// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Synchronization
import Wire

/// The graph the task group exists for: two async bindings that can be in flight at once, and a
/// dependent of the *faster* one.
///
/// `SchedulerContainerExample` proves the state struct's shape; this one proves it schedules. The gate is
/// that `FastDependent` is constructed while `makeSlowSignal` is still suspended, which no sequential
/// ordering can produce — under the linear chain, or under the construction state struct's inline cascade, the slow binding runs
/// to completion before the fast one is even started.
///
/// **Observed rather than timed.** The obvious fixture sleeps 200 ms in one binding and 5 ms in the other
/// and asserts on the wall clock, which makes the gate a race on a loaded CI runner. Here the slow binding
/// *waits for* the dependent instead: it polls the shared clock, bounded, and records itself afterwards.
/// Concurrent construction settles it in one poll interval; sequential construction cannot satisfy it at
/// all and falls out at the bound with the timeline in the opposite order. So the assertion is on the
/// order of two recorded events, not on how long either took.
///
/// Everything here is `Sendable` by necessity, and that is the milestone's constraint in executable form:
/// both async bindings' products cross a task boundary as `ChildTaskResult`s, and `ConstructionClock` —
/// the slow binding's dependency — is captured by its `addTask` closure. `SchedulerContainerExample`'s
/// non-Sendable `SchedulerCounter` is the complementary case: nothing schedules it, so it is never asked.

package struct SlowSignal: Sendable {
    package let label: String
}

package struct FastSignal: Sendable {
    package let label: String
}

@Container
package enum ParallelSchedulerContainer {
    /// The shared timeline both async bindings write to. A binding rather than a global so each bootstrap
    /// gets its own — the suite runs its tests in parallel, and a module-scope recorder would interleave
    /// them.
    @Singleton(allowUnused: true)
    package final class ConstructionClock: Sendable {
        private let events = Mutex<[String]>([])

        @Inject package init() {}

        package func record(_ event: String) {
            events.withLock { $0.append(event) }
        }

        package var timeline: [String] {
            events.withLock { $0 }
        }
    }

    /// The fast half: resolves almost immediately, and its resolution is what fires `FastDependent` on the
    /// draining parent.
    @Provides(allowUnused: true)
    package static func makeFastSignal() async throws -> FastSignal {
        try await Task.sleep(for: .milliseconds(1))
        return FastSignal(label: "fast")
    }

    /// The slow half: suspends until the fast binding's dependent has been built, then records itself.
    ///
    /// Bounded at a second so a regression fails the assertion rather than hanging the suite. It has no
    /// dependency on either of the two — the trigger needs an *independent* pair, and a dependency here
    /// would make this a chain, which no scheduler can overlap.
    @Provides(allowUnused: true)
    package static func makeSlowSignal(clock: ConstructionClock) async throws -> SlowSignal {
        for _ in 0..<200 {
            if clock.timeline.contains("dependent") { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        clock.record("slow")
        return SlowSignal(label: "slow")
    }

    /// Reached only through the cascade from `makeFastSignal`, and sync — so it is constructed on the
    /// parent, during the drain, while the slow child task is still suspended.
    @Singleton(allowUnused: true)
    package struct FastDependent {
        package let signal: FastSignal
        /// Whether the slow binding had already finished when this was built. The scheduler's whole claim
        /// is that this is `false`.
        package let sawSlowAlready: Bool

        @Inject package init(fast: FastSignal, clock: ConstructionClock) {
            self.signal = fast
            self.sawSlowAlready = clock.timeline.contains("slow")
            clock.record("dependent")
        }
    }
}
