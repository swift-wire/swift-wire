// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Wire

/// End-to-end fixture for swift-wire#368 — two keyed `some P` bindings of one protocol, each lifting its
/// own generic parameter on `_WireGraph`, and consumers generic over both. A consumer's parameters are
/// filled by the keys its dependencies carry, so the graph stores `KeyedNamerPair<T_a, T_b>` with two
/// distinct lifted parameters.
///
/// Compiling this file at all is most of the point. Before the fix, both bindings resolved to one
/// parameter and the consumer was spelled `KeyedNamerPair<T0, T0>`, which fails to type-check with
/// "generic parameter 'T1' could not be inferred".
protocol KeyedNamer: Sendable {
    func name() -> String
}

struct AlphaNamer: KeyedNamer {
    func name() -> String { "alpha" }
}

struct BetaNamer: KeyedNamer {
    func name() -> String { "beta" }
}

enum KeyedNamerKeys {
    static let alpha = BindingKey<any KeyedNamer>()
    static let beta = BindingKey<any KeyedNamer>()
}

@Provides(KeyedNamerKeys.alpha)
func makeAlphaNamer() -> some KeyedNamer { AlphaNamer() }

@Provides(KeyedNamerKeys.beta)
func makeBetaNamer() -> some KeyedNamer { BetaNamer() }

@Singleton(allowUnused: true)
struct KeyedNamerPair<X: KeyedNamer, Y: KeyedNamer> {
    @Inject(KeyedNamerKeys.alpha) var x: X
    @Inject(KeyedNamerKeys.beta) var y: Y
}

/// The same pair inside a seeded scope: it borrows both keyed bindings from the app graph, so the scope
/// lifts the two app-graph axes as two parameters of its own.
@Scoped(seed: TestRequestSeed.self, allowUnused: true)
struct ScopedKeyedNamerPair<X: KeyedNamer, Y: KeyedNamer> {
    @Inject(KeyedNamerKeys.beta) var first: Y
    @Inject(KeyedNamerKeys.alpha) var second: X
}
