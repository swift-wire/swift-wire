// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Testing

@testable import WireGenCore

/// Step 2 of iteration 5β: contribution discovery. These pin that
/// `@Contributes(to:withOrder:atKey:)` annotations are captured onto the
/// producer (both `@Singleton`/`@Scoped` types and `@Provides`
/// providers), including the order/atKey arguments and multiple keys per
/// contributor. Contributions are captured-but-unused at this step; the
/// fan-in pass (Step 4) consumes them.
@Suite("Contribution discovery")
struct ContributionDiscoveryTests {
    /// Contributions on the first discovered default-graph binding.
    private func contributions(in source: String) -> [Contribution] {
        discover(in: source, sourcePath: "C.swift", module: testModule).bindings.first?.contributions ?? []
    }

    @Test func singletonContributionCapturesKeyReference() throws {
        let source = """
            @Singleton @Contributes(to: App.services)
            struct AuthService {}
            """
        let contribution = try #require(contributions(in: source).first)
        #expect(contributions(in: source).count == 1)
        #expect(contribution.keyReference == "App.services")
        #expect(contribution.order == nil)
        #expect(contribution.mapKeyExpression == nil)
    }

    @Test func withOrderArgumentIsCaptured() throws {
        let source = """
            @Singleton @Contributes(to: App.middleware, withOrder: 2)
            struct LoggingMiddleware {}
            """
        let contribution = try #require(contributions(in: source).first)
        #expect(contribution.order == 2)
        #expect(contribution.mapKeyExpression == nil)
    }

    @Test func withOrderLiteralWithSeparatorsIsRanked() throws {
        // swift-wire#419. The rank is read from the integer literal's syntax, not by handing its
        // source text to `Int(_:)`, so `_` separators, other radixes and a prefix `-` all parse.
        let source = """
            @Singleton
            @Contributes(to: App.alpha, withOrder: 1_000)
            @Contributes(to: App.beta, withOrder: 0x10)
            @Contributes(to: App.gamma, withOrder: -2)
            struct Ranked {}
            """
        #expect(contributions(in: source).map(\.order) == [1000, 16, -2])
        #expect(contributions(in: source).allSatisfy { !$0.hasUnreadableOrder })
        let discovery = discover(in: source, sourcePath: "C.swift", module: testModule)
        #expect(discovery.warnings.isEmpty)
    }

    @Test func withOrderThatIsNotAnIntegerLiteralIsAnError() throws {
        // A named constant compiles against `withOrder: Int`, but its value is not in the syntax.
        // It used to be recorded as unranked with no diagnostic; it is now an error at the argument.
        let source = """
            @Singleton
            @Contributes(to: App.middleware, withOrder: Rank.auth)
            struct AuthMiddleware {}
            """
        let discovery = discover(in: source, sourcePath: "C.swift", module: testModule)
        let errors = discovery.warnings.filter { $0.severity == .error }
        #expect(errors.count == 1)
        let error = try #require(errors.first)
        #expect(
            error.message.contains(
                "'withOrder: Rank.auth' on @Contributes(to: App.middleware) is not an integer literal"
            )
        )
        #expect(error.location.line == 2)
        let contribution = try #require(contributions(in: source).first)
        #expect(contribution.order == nil)
        #expect(contribution.hasUnreadableOrder)
    }

    @Test func atKeyArgumentIsCapturedVerbatim() throws {
        let source = """
            @Singleton @Contributes(to: App.strategies, atKey: "fast")
            struct FastStrategy {}
            """
        let contribution = try #require(contributions(in: source).first)
        #expect(contribution.mapKeyExpression == "\"fast\"")
        #expect(contribution.order == nil)
    }

    @Test func multipleContributesAttributesYieldMultipleContributions() throws {
        // Repeated `@Contributes` (multiple keys per contributor) —
        // confirmed to compile by spike #1.
        let source = """
            @Singleton
            @Contributes(to: App.alpha)
            @Contributes(to: App.beta, withOrder: 1)
            struct MultiContributor {}
            """
        let result = contributions(in: source)
        #expect(result.count == 2)
        #expect(result.map(\.keyReference) == ["App.alpha", "App.beta"])
        #expect(result[1].order == 1)
    }

    @Test func providesPropertyContributionIsCaptured() throws {
        let source = """
            @Provides @Contributes(to: App.services)
            let authService: any Service = AuthService()
            """
        let contribution = try #require(contributions(in: source).first)
        #expect(contribution.keyReference == "App.services")
    }

    @Test func providesFunctionContributionIsCaptured() throws {
        let source = """
            @Provides @Contributes(to: App.middleware, withOrder: 3)
            func makeMiddleware() -> any Middleware { LoggingMiddleware() }
            """
        let contribution = try #require(contributions(in: source).first)
        #expect(contribution.keyReference == "App.middleware")
        #expect(contribution.order == 3)
    }

    @Test func plainProducerHasNoContributions() {
        let source = """
            @Singleton
            struct PlainService {}
            """
        #expect(contributions(in: source).isEmpty)
    }

    @Test func moduleQualifiedContributesSelectorIsRecognised() throws {
        // SE-0491 `@Wire::Contributes` resolves to the same macro.
        let source = """
            @Singleton @Wire::Contributes(to: App.services)
            struct AuthService {}
            """
        let contribution = try #require(contributions(in: source).first)
        #expect(contribution.keyReference == "App.services")
    }
}
