// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Testing
import Wire

/// swift-wire#366 and swift-wire#431's gate — each pairing of a construction that can or cannot throw with
/// a teardown that can or cannot throw builds, and its teardown runs and reports what it threw.
///
/// The defects were compile-time ones, so the first half of the gate is that `TeardownEffectPairsExample`
/// compiles at all (#366) and compiles without `'catch' block is unreachable` (#431, pinned by the golden
/// recording rather than here). These tests are the runtime half: separating the two effects must not
/// have cost the accumulator any action it used to fold.
@Suite("Teardown effect pairs")
struct TeardownEffectPairsTests {
    private func drive(_ graph: some Teardownable) async -> [any Error] {
        await graph.teardown()
    }

    private func pairs(_ errors: [any Error]) -> [String] {
        errors.compactMap { ($0 as? TeardownEffectPairFailure)?.pair }
    }

    @Test func aGraphThatCannotThrowAnywhereStillTearsDown() async throws {
        let errors = await drive(try await Wire.bootstrapPlainBuildPlainTeardownContainer())
        #expect(errors.isEmpty)
        #expect(teardownEffectPairEvents(withPrefix: "graph.plainPlain.") == ["graph.plainPlain.closed"])
    }

    @Test func aGraphWhoseOnlyThrowIsInTeardownReportsIt() async throws {
        let errors = await drive(try await Wire.bootstrapPlainBuildThrowingTeardownContainer())
        #expect(pairs(errors) == ["graph.plainThrowing"])
        #expect(teardownEffectPairEvents(withPrefix: "graph.plainThrowing.") == ["graph.plainThrowing.closed"])
    }

    @Test func aGraphWhoseOnlyThrowIsInConstructionTearsDown() async throws {
        let errors = await drive(try await Wire.bootstrapThrowingBuildPlainTeardownContainer())
        #expect(errors.isEmpty)
        #expect(teardownEffectPairEvents(withPrefix: "graph.throwingPlain.") == ["graph.throwingPlain.closed"])
    }

    @Test func aGraphThatCanThrowInBothReportsTheTeardownError() async throws {
        let errors = await drive(try await Wire.bootstrapThrowingBuildThrowingTeardownContainer())
        #expect(pairs(errors) == ["graph.throwingThrowing"])
        #expect(
            teardownEffectPairEvents(withPrefix: "graph.throwingThrowing.") == ["graph.throwingThrowing.closed"]
        )
    }

    @Test func aScopeThatCannotThrowAnywhereStillTearsDown() async throws {
        let graph = try await Wire.bootstrap()
        let entry = try await graph._WireAggregateContributor_plainPlainTeardown._wireEnterScope(
            PlainPlainScopeSeed()
        )
        let errors = await entry._wireScopeTeardown()
        #expect(errors.isEmpty)
        #expect(teardownEffectPairEvents(withPrefix: "scope.plainPlain.") == ["scope.plainPlain.closed"])
    }

    @Test func aScopeWhoseOnlyThrowIsInTeardownReportsIt() async throws {
        let graph = try await Wire.bootstrap()
        let entry = try await graph._WireAggregateContributor_plainThrowingTeardown._wireEnterScope(
            PlainThrowingScopeSeed()
        )
        let errors = await entry._wireScopeTeardown()
        #expect(pairs(errors) == ["scope.plainThrowing"])
        #expect(teardownEffectPairEvents(withPrefix: "scope.plainThrowing.") == ["scope.plainThrowing.closed"])
    }

    @Test func aScopeWhoseOnlyThrowIsInConstructionTearsDown() async throws {
        let graph = try await Wire.bootstrap()
        let entry = try await graph._WireAggregateContributor_throwingPlainTeardown._wireEnterScope(
            ThrowingPlainScopeSeed()
        )
        let errors = await entry._wireScopeTeardown()
        #expect(errors.isEmpty)
        #expect(teardownEffectPairEvents(withPrefix: "scope.throwingPlain.") == ["scope.throwingPlain.closed"])
    }

    @Test func aScopeThatCanThrowInBothReportsTheTeardownError() async throws {
        let graph = try await Wire.bootstrap()
        let entry = try await graph._WireAggregateContributor_throwingThrowingTeardown._wireEnterScope(
            ThrowingThrowingScopeSeed()
        )
        let errors = await entry._wireScopeTeardown()
        #expect(pairs(errors) == ["scope.throwingThrowing"])
        #expect(
            teardownEffectPairEvents(withPrefix: "scope.throwingThrowing.") == ["scope.throwingThrowing.closed"]
        )
    }

    @Test func aSeedlessReconstructionWhoseOnlyThrowIsInTeardownTearsDown() async throws {
        let graph = try await Wire.bootstrapAppScopedFixture_bindMock()
        let doubles = _AppScopedFixture_bindMock_SeedlessTeardownControllerDoubles(
            appScopedRepository: MockAppScopedRepository()
        )
        let proxy = Wire.bootstrapAppScopedFixture_bindMock_SeedlessTeardownControllerContributor(wireGraph: graph)
        let before = teardownEffectPairEvents(withPrefix: "seedless.").count
        let entry = try await proxy._wireEnterScope(doubles)
        let errors = await entry._wireScopeTeardown()
        #expect(errors.isEmpty)
        #expect(teardownEffectPairEvents(withPrefix: "seedless.").count == before + 1)
    }
}
