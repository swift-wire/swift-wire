// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Wire

/// End-to-end fixture for generic specialisation. A parameterised factory
/// `@Provides func makeContainer<T>` and a concrete consumer asking for
/// `Container<DataPoint>`. The build plugin specialises the factory with
/// `T = DataPoint`, substitutes the dep type through, and emits a concrete
/// `Container<DataPoint>` binding the consumer resolves against — without a
/// separate `@Provides` per instantiation. (A generic `@Singleton` can't do
/// this: it must be a single instance — see the invalid-generic-singleton
/// diagnostic — so parameterised, multi-instance families are `@Provides func`.)
struct DataPoint: Sendable {
    let value: Int
}

// Consumed via Container<DataPoint> specialisation, which the
// first-order dead-binding analysis doesn't track.
@Provides(allowUnused: true)
let dataPoint: DataPoint = DataPoint(value: 42)

struct Container<T: Sendable>: Sendable {
    let item: T

    func describe() -> String {
        "Container(\(String(describing: item)))"
    }
}

@Provides(allowUnused: true)
func makeContainer<T: Sendable>(item: T) -> Container<T> {
    Container(item: item)
}

@Singleton(allowUnused: true)
struct GenericConsumer {
    @Inject var container: Container<DataPoint>

    func describe() -> String {
        container.describe()
    }
}

/// The same family through an `async throws` factory. Specialisation copies the template's effects onto
/// `Envelope<DataPoint>`, so the graph calls `try await makeEnvelope(item:after:)`; a specialisation
/// that dropped them called it bare, and this target did not compile (swift-wire#428).
///
/// `after:` only orders it behind `AsyncInitConsumer`, the corpus's async binding in a scheduled graph's
/// suffix, so it joins that suffix rather than the group. Without it the two would be independent async
/// bindings that overlap, which pulls `AsyncInitConsumer` into the group and leaves the corpus with no
/// async construction in a suffix.
struct Envelope<T: Sendable>: Sendable {
    let item: T

    func describe() -> String {
        "Envelope(\(String(describing: item)))"
    }
}

@Provides(allowUnused: true)
func makeEnvelope<T: Sendable>(item: T, after: AsyncInitConsumer) async throws -> Envelope<T> {
    Envelope(item: item)
}

@Singleton(allowUnused: true)
struct EnvelopeConsumer {
    @Inject var envelope: Envelope<DataPoint>

    func describe() -> String {
        envelope.describe()
    }
}
