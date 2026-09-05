// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Synchronization
import Wire

/// partial teardown — the fixture [TeardownDesign.md](../../Documentation/Notes/TeardownDesign.md) asks for: a
/// throwing init downstream of a constructed `@Teardown` binding, asserting the earlier action fired.
///
/// **Two containers, because there are two construction shapes and the point of deferring this from the teardown walk was
/// to implement it once against the final one.** `PartialTeardownContainer` is wholly sync, so it is the
/// linear `let` chain; `ScheduledPartialTeardownContainer` has an independent async pair, so it is the
/// prefix / group / suffix split — and its torn binding is *in the group*, which is the case the
/// accumulator cannot reach at the construction site and the drain's own `catch` has to recover from a
/// cell instead.
///
/// **Observed rather than timed**, like `ParallelSchedulerExample`: the scheduled fixture's failing binding
/// waits for the torn one to be recorded before it throws, bounded, so "the resource was already built when
/// the init failed" is a fact rather than a race.

/// Shared across bootstraps, so it is a module-scope recorder rather than a binding: a failed bootstrap
/// returns no graph, and a graph is the only thing a binding could be read back through.
///
/// Each container writes under its own prefix and each test reads only its own, so the suite's parallelism
/// cannot cross them.
package let partialTeardownLog = Mutex<[String]>([])

package func recordPartialTeardown(_ event: String) {
    partialTeardownLog.withLock { $0.append(event) }
}

package func partialTeardownEvents(withPrefix prefix: String) -> [String] {
    partialTeardownLog.withLock { $0.filter { $0.hasPrefix(prefix) } }
}

package struct PartialTeardownFailure: Error {}

@Container
package enum PartialTeardownContainer {
    /// Constructed first, and the thing that must be torn down when the graph fails to build.
    @Singleton(allowUnused: true)
    package struct ChainResource: Sendable {
        @Inject package init() {
            recordPartialTeardown("chain.built")
        }

        @Teardown
        package func close() async {
            recordPartialTeardown("chain.closed")
        }
    }

    /// Downstream of it, and throws — so the bootstrap unwinds with `ChainResource` already live.
    @Singleton(allowUnused: true)
    package struct ChainFailingConsumer: Sendable {
        @Inject package init(resource: ChainResource) throws {
            throw PartialTeardownFailure()
        }
    }
}

@Container
package enum ScheduledPartialTeardownContainer {
    /// Async, and the reason this graph schedules at all. Independent of `makeScheduledFailure`, so the
    /// two are the Overlap pair.
    @Provides(allowUnused: true)
    package static func makeScheduledSignal() async throws -> ScheduledSignal {
        try await Task.sleep(for: .milliseconds(1))
        return ScheduledSignal()
    }

    /// Waits on `ScheduledSignal` only — a proper subset of Overlap — so it lands **in the group**, and its
    /// teardown action cannot be recorded at its construction site the way a prefix binding's is.
    @Singleton(allowUnused: true)
    package struct ScheduledResource: Sendable {
        @Inject package init(signal: ScheduledSignal) {
            recordPartialTeardown("scheduled.built")
        }

        @Teardown
        package func close() async {
            recordPartialTeardown("scheduled.closed")
        }
    }

    /// The other half of the pair, and the failure. It waits until `ScheduledResource` has been built
    /// before throwing, so the graph is unwound from a state where a scheduled `@Teardown` binding really
    /// had resolved — bounded at a second, so a regression fails the assertion rather than hanging.
    @Provides(allowUnused: true)
    package static func makeScheduledFailure() async throws -> ScheduledFailureMarker {
        for _ in 0..<200 {
            if partialTeardownEvents(withPrefix: "scheduled.").contains("scheduled.built") { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw PartialTeardownFailure()
    }
}

package struct ScheduledSignal: Sendable {}
package struct ScheduledFailureMarker: Sendable {}
