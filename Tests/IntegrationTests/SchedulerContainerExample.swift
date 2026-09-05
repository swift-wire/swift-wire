// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Wire

/// The first graph built through the **construction state struct** rather than the linear `let`
/// chain. A `@Container` because the trigger is per graph (`schedulerApplies`): a container is a separate
/// wiring, so this exercises the scheduled emission without moving the default graph, which still carries
/// builder folds, member injections and existential aliases that the region split owns.
///
/// What it is built to cover, since the scheduled form is a different emission for each of these:
///
/// - an **async `@Provides func`** and an **async `@Inject init`** — the two suspension shapes, and the
///   reason the graph qualifies at all;
/// - a **non-Sendable class** binding, which is the note's central claim in executable form: it lives in a
///   cell, is read as a dependency and is held across the `await` points of the two async bindings, clean
///   under `-strict-concurrency=complete`, because it never enters a task;
/// - a **`.aggregate`** binding, so all three `DiscoveredBinding` cases appear;
/// - a **fan-in consumer** whose dependencies resolve at different times, so the cascade — not the
///   topological order — is what fires it. `SchedulerService` is reachable only by being triggered from
///   whichever of its three dependencies resolves last.
///
/// Deliberately absent, because each is excluded from the trigger and belongs to the region split: builder
/// aggregates, scope-entry thunks, existential promotions, member injections, `@Teardown`, opaque lifts.

package protocol SchedulerProbe: Sendable {
    func id() -> String
}

package struct SchedulerToken: Sendable {
    package let value: String
}

@Container
package enum SchedulerContainer {
    package static let probes = CollectedKey<any SchedulerProbe>()

    /// Source binding, async: suspends before it produces.
    @Provides(allowUnused: true)
    package static func makeSchedulerToken() async throws -> SchedulerToken {
        try await Task.sleep(nanoseconds: 1)
        return SchedulerToken(value: "scheduled")
    }

    /// Source binding, **non-Sendable**. Held in its cell across both async bindings' suspensions.
    @Singleton(allowUnused: true)
    package final class SchedulerCounter {
        package var count = 0
        @Inject package init() {}
        package func bump() -> Int {
            count += 1
            return count
        }
    }

    /// Source binding with an async `@Inject init` — the second suspension shape.
    @Singleton(allowUnused: true)
    package struct SchedulerConfig {
        package let label: String
        @Inject package init() async throws {
            try await Task.sleep(nanoseconds: 1)
            self.label = "config"
        }
    }

    /// Fan-in. Fires from whichever of its three dependencies resolves last, never from source order.
    @Singleton(allowUnused: true)
    package struct SchedulerService {
        package let token: SchedulerToken
        package let counter: SchedulerCounter
        package let config: SchedulerConfig

        @Inject package init(token: SchedulerToken, counter: SchedulerCounter, config: SchedulerConfig) {
            self.token = token
            self.counter = counter
            self.config = config
        }

        package func describe() -> String { "\(config.label):\(token.value):\(counter.count)" }
    }

    @Singleton @Contributes(to: SchedulerContainer.probes, withOrder: 1)
    package struct AlphaProbe: SchedulerProbe {
        package func id() -> String { "alpha" }
    }

    @Singleton @Contributes(to: SchedulerContainer.probes, withOrder: 2)
    package struct BetaProbe: SchedulerProbe {
        package func id() -> String { "beta" }
    }

    /// Consumes the aggregate, so the `.aggregate` binding has a dependent to cascade into.
    @Singleton(allowUnused: true)
    package struct ProbeHost {
        @Inject(SchedulerContainer.probes) package var probes: [any SchedulerProbe]
        package func ids() -> [String] { probes.map { $0.id() } }
    }
}
