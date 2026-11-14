// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Synchronization
import Wire
import WireTestLibrary
import WireTesting

/// swift-wire#366 and swift-wire#431 — every pairing of *construction throws or doesn't* with *teardown
/// throws or doesn't*, once for an app graph and once for a seeded scope entry.
///
/// The two effects are separate questions for the emitter, and both defects came from answering one with
/// the other. A graph that is torn must declare its teardown accumulator whether or not construction can
/// throw, because the happy path folds it too (#366: a graph whose construction could not throw appended
/// to an accumulator it never declared, and did not compile). And whether the body is wrapped in
/// `do`/`catch` is a question about *construction* alone, because a `try` inside a teardown closure does
/// not make the enclosing `do` throw (#431: a throwing teardown alone drew `'catch' block is unreachable`).
///
/// The fixtures are pinned by compiling at all, and by the golden recording; `TeardownEffectPairsTests`
/// then drives each through bootstrap and teardown. Each construction that "throws" is declared `throws`
/// and never does, so every graph builds and its teardown can be observed. Each teardown that throws
/// does, so its error is seen to come back through `teardown()`.

/// Shared across the pairs; each writes under its own prefix and each test reads only its own.
package let teardownEffectPairsLog = Mutex<[String]>([])

package func recordTeardownEffectPair(_ event: String) {
    teardownEffectPairsLog.withLock { $0.append(event) }
}

package func teardownEffectPairEvents(withPrefix prefix: String) -> [String] {
    teardownEffectPairsLog.withLock { $0.filter { $0.hasPrefix(prefix) } }
}

package struct TeardownEffectPairFailure: Error, Equatable {
    package let pair: String
}

// MARK: - app graphs, one container per pair

/// Neither construction nor teardown can throw — the shape that did not compile (#366).
@Container
package enum PlainBuildPlainTeardownContainer {
    @Singleton(allowUnused: true)
    package struct PlainPlainResource: Sendable {
        @Inject package init() {}

        @Teardown
        package func close() async {
            recordTeardownEffectPair("graph.plainPlain.closed")
        }
    }
}

/// Only teardown can throw — the shape that drew the unreachable `catch` (#431).
@Container
package enum PlainBuildThrowingTeardownContainer {
    @Singleton(allowUnused: true)
    package struct PlainThrowingResource: Sendable {
        @Inject package init() {}

        @Teardown
        package func close() async throws {
            recordTeardownEffectPair("graph.plainThrowing.closed")
            throw TeardownEffectPairFailure(pair: "graph.plainThrowing")
        }
    }
}

/// Only construction can throw — the shape that always unwound correctly.
@Container
package enum ThrowingBuildPlainTeardownContainer {
    @Singleton(allowUnused: true)
    package struct ThrowingPlainResource: Sendable {
        @Inject package init() throws {}

        @Teardown
        package func close() async {
            recordTeardownEffectPair("graph.throwingPlain.closed")
        }
    }
}

/// Both can throw.
@Container
package enum ThrowingBuildThrowingTeardownContainer {
    @Singleton(allowUnused: true)
    package struct ThrowingThrowingResource: Sendable {
        @Inject package init() throws {}

        @Teardown
        package func close() async throws {
            recordTeardownEffectPair("graph.throwingThrowing.closed")
            throw TeardownEffectPairFailure(pair: "graph.throwingThrowing")
        }
    }
}

// MARK: - seeded scope entries, one seed per pair

package struct PlainPlainScopeSeed: Sendable {}
package struct PlainThrowingScopeSeed: Sendable {}
package struct ThrowingPlainScopeSeed: Sendable {}
package struct ThrowingThrowingScopeSeed: Sendable {}

@Scoped(seed: PlainPlainScopeSeed.self, allowUnused: true)
@AggregateController(spec: "plainPlainTeardown")
package final class PlainPlainScopeController: Sendable {
    @Inject package init() {}

    @Teardown
    package func close() async {
        recordTeardownEffectPair("scope.plainPlain.closed")
    }
}

@Scoped(seed: PlainThrowingScopeSeed.self, allowUnused: true)
@AggregateController(spec: "plainThrowingTeardown")
package final class PlainThrowingScopeController: Sendable {
    @Inject package init() {}

    @Teardown
    package func close() async throws {
        recordTeardownEffectPair("scope.plainThrowing.closed")
        throw TeardownEffectPairFailure(pair: "scope.plainThrowing")
    }
}

@Scoped(seed: ThrowingPlainScopeSeed.self, allowUnused: true)
@AggregateController(spec: "throwingPlainTeardown")
package final class ThrowingPlainScopeController: Sendable {
    @Inject package init() throws {}

    @Teardown
    package func close() async {
        recordTeardownEffectPair("scope.throwingPlain.closed")
    }
}

@Scoped(seed: ThrowingThrowingScopeSeed.self, allowUnused: true)
@AggregateController(spec: "throwingThrowingTeardown")
package final class ThrowingThrowingScopeController: Sendable {
    @Inject package init() throws {}

    @Teardown
    package func close() async throws {
        recordTeardownEffectPair("scope.throwingThrowing.closed")
        throw TeardownEffectPairFailure(pair: "scope.throwingThrowing")
    }
}

// MARK: - a seedless reconstruction, whose only throw is in teardown

/// The testing-variant path's thunk: `Wire.bootstrapAppScopedFixture_bindMock()` drops the controller,
/// because it reads the `@BindType`'d `AppScopedRepository`, and its seedless proxy rebuilds it from the
/// doubles alone. Construction cannot throw and teardown can, which is #431's shape on the third call
/// site. It rides `ScopableRouteContributorExample`'s key rather than declaring its own, because every
/// `TestingKey` is a whole variant graph in the generated file.
///
/// The teardown is declared `throws` and never does, unlike the pairs above: the controller is an app
/// singleton, so the default graph builds and tears it down too, and a suite asserting that graph's
/// teardown comes back empty would read a thrown error as a regression of its own.
@TestScopable
@Singleton
@RouteController
struct SeedlessTeardownController: Sendable {
    @Inject var repository: any AppScopedRepository

    @Teardown
    func close() async throws {
        recordTeardownEffectPair("seedless.plainThrowing.closed")
    }
}
