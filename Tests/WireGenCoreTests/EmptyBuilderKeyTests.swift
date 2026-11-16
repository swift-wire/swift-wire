// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Testing

@testable import WireGenCore

/// multibindings and graph conformance: a `BuilderKey` with no contributors. When the builder
/// declares a `buildBlock` callable with no arguments (no parameters, or each one variadic or
/// defaulted), the consumer gets the empty `@<Builder>` fold, and a conformance member gets an
/// empty `@<Builder>` accessor. Otherwise the fold wouldn't compile, so WireGen reports an error
/// naming the key, builder, consumer and the fix, at the injection site or the member's element.
@Suite("Empty builder key")
struct EmptyBuilderKeyTests {
    // MARK: - Builder shapes

    private static let variadic = """
        @resultBuilder
        enum HookBuilder {
            static func buildBlock(_ hooks: any Hook...) -> [any Hook] { hooks }
        }
        """
    private static let finalResult = """
        @resultBuilder
        enum HookBuilder {
            static func buildBlock(_ hooks: any Hook...) -> [any Hook] { hooks }
            static func buildFinalResult(_ hooks: [any Hook]) -> Chain { Chain(hooks: hooks) }
        }
        """
    private static let zeroParameter = """
        @resultBuilder
        enum HookBuilder {
            static func buildBlock() -> [any Hook] { [] }
            static func buildBlock(_ hook: any Hook) -> [any Hook] { [hook] }
        }
        """
    /// `buildFinalResult` gives the result type: a builder with neither it nor a `buildBlock` has no
    /// discovered result type, and so no aggregate whether or not anything contributes.
    private static let partialOnly = """
        @resultBuilder
        enum HookBuilder {
            static func buildPartialBlock(first: any Hook) -> [any Hook] { [first] }
            static func buildPartialBlock(accumulated: [any Hook], next: any Hook) -> [any Hook] { accumulated + [next] }
            static func buildFinalResult(_ hooks: [any Hook]) -> [any Hook] { hooks }
        }
        """
    private static let fixedArity = """
        @resultBuilder
        enum HookBuilder {
            static func buildBlock(_ hook: any Hook) -> [any Hook] { [hook] }
        }
        """

    /// The builder, the key and a consumer. After a four-line builder the injected `hooks` property is at line 8,
    /// column 29; after the six-line partial-block one, line 10.
    private func consumerSource(builder: String, resultType: String = "[any Hook]") -> String {
        builder + "\n"
            + """
            enum Keys { static let hooks = BuilderKey<HookBuilder>(allowUnused: true) }
            @Singleton(allowUnused: true)
            struct Runner {
                @Inject(Keys.hooks) var hooks: \(resultType)
            }
            """
    }

    private struct Built {
        let discovery: SourceFileDiscovery
        let graph: GraphResult
    }

    private func build(_ source: String) -> Built {
        let discovery = discover(in: source, sourcePath: "Hooks.swift", module: testModule)
        let graph = buildDependencyGraph(
            from: discovery.bindings,
            multibindingKeys: discovery.multibindingKeys,
            resultBuilders: discovery.resultBuilders
        )
        return Built(discovery: discovery, graph: graph)
    }

    private func render(_ built: Built, conformances: [DiscoveredGraphConformance] = []) throws -> String {
        let order = try #require(built.graph.outcome.topologicalOrder)
        return renderWireGraph(
            imports: [],
            topologicalOrder: order,
            graphConformances: conformances,
            multibindingKeys: built.discovery.multibindingKeys,
            resultBuilders: built.discovery.resultBuilders
        )
    }

    // MARK: - Consumed key, builder folds an empty body

    @Test func variadicBuildBlockFoldsAnEmptyBody() throws {
        let output = try render(build(consumerSource(builder: Self.variadic)))
        #expect(
            output.contains(
                """
                    @HookBuilder
                    func _wireFoldKeysHooks() -> [any Hook] {
                    }
                    let anyHookKeyedKeysHooks = _wireFoldKeysHooks()
                """
            )
        )
    }

    @Test func buildFinalResultWithVariadicBuildBlockFoldsToTheFinalResultType() throws {
        let output = try render(build(consumerSource(builder: Self.finalResult, resultType: "Chain")))
        #expect(
            output.contains(
                """
                    @HookBuilder
                    func _wireFoldKeysHooks() -> Chain {
                    }
                """
            )
        )
    }

    @Test func zeroParameterBuildBlockFoldsAnEmptyBody() throws {
        let output = try render(build(consumerSource(builder: Self.zeroParameter)))
        #expect(
            output.contains(
                """
                    @HookBuilder
                    func _wireFoldKeysHooks() -> [any Hook] {
                    }
                """
            )
        )
    }

    // MARK: - Consumed key, builder can't fold an empty body

    private func renderedErrors(_ source: String) throws -> String {
        let errors = try #require(build(source).graph.outcome.validationErrors)
        return renderValidationErrors(errors)
    }

    @Test func partialBlockOnlyBuilderIsAnErrorAtTheInjectionSite() throws {
        let rendered = try renderedErrors(consumerSource(builder: Self.partialOnly))
        #expect(
            rendered
                == "Hooks.swift:10:29: error: 'Runner' injects 'Keys.hooks', a BuilderKey with no @Contributes contributors in this graph, and its builder 'HookBuilder' declares no zero-argument buildBlock, so an empty '@HookBuilder' fold can't be formed. Declare 'static func buildBlock() -> [any Hook]' in 'HookBuilder', or contribute to 'Keys.hooks'."
        )
    }

    @Test func fixedArityBuildBlockIsAnErrorAtTheInjectionSite() throws {
        let rendered = try renderedErrors(consumerSource(builder: Self.fixedArity))
        #expect(
            rendered
                == "Hooks.swift:8:29: error: 'Runner' injects 'Keys.hooks', a BuilderKey with no @Contributes contributors in this graph, and its builder 'HookBuilder' declares no zero-argument buildBlock, so an empty '@HookBuilder' fold can't be formed. Declare 'static func buildBlock() -> [any Hook]' in 'HookBuilder', or contribute to 'Keys.hooks'."
        )
    }

    @Test func aContributedKeyOverAnUnfoldableBuilderStillFolds() throws {
        // The error is about the empty case only: one contributor folds with a fixed-arity `buildBlock`.
        let source =
            consumerSource(builder: Self.fixedArity) + "\n"
            + "@Singleton @Contributes(to: Keys.hooks) struct AuditHook: Hook {}"
        let output = try render(build(source))
        #expect(output.contains("func _wireFoldKeysHooks() -> [any Hook] {"))
    }

    // MARK: - Unconsumed key

    @Test func unconsumedEmptyBuilderKeyHasNoAggregate() {
        // As an unconsumed empty `CollectedKey` has none: nothing contributes to or injects it here.
        let source =
            Self.variadic + "\n"
            + "enum Keys { static let hooks = BuilderKey<HookBuilder>(allowUnused: true) }"
        let order = build(source).graph.outcome.topologicalOrder
        #expect(order?.contains { $0.keyIdentifier == "Keys.hooks" } == false)
    }

    // MARK: - Graph-conformance member

    /// The builder, the key and a conformance. After a four-line builder the `hooks` member's
    /// `.init(…)` element is at line 9, column 19; after the six-line partial-block one, line 11.
    private func conformanceSource(builder: String) -> String {
        builder + "\n"
            + """
            enum Keys { static let hooks = BuilderKey<HookBuilder>(allowUnused: true) }
            enum Conformance {
                static let decl = WireGraphConformanceV1(
                    conformsTo: (any Hooked).self,
                    members: [.init("hooks", from: Keys.hooks)]
                )
            }
            """
    }

    private func conformanceOutput(builder: String) throws -> String {
        let built = build(conformanceSource(builder: builder))
        return try render(built, conformances: built.discovery.graphConformances)
    }

    private func conformanceDiagnostics(builder: String) throws -> [Diagnostic] {
        let built = build(conformanceSource(builder: builder))
        return graphConformanceEmptyBuilderDiagnostics(
            conformances: built.discovery.graphConformances,
            topologicalOrder: try #require(built.graph.outcome.topologicalOrder),
            multibindingKeys: built.discovery.multibindingKeys,
            resultBuilders: built.discovery.resultBuilders
        )
    }

    @Test func variadicBuilderMemberIsAnEmptyFoldAccessor() throws {
        #expect(
            try conformanceOutput(builder: Self.variadic)
                .contains("    @HookBuilder var hooks: [any Hook] { }")
        )
        #expect(try conformanceDiagnostics(builder: Self.variadic).isEmpty)
    }

    @Test func buildFinalResultBuilderMemberIsAnEmptyFoldAccessorOfTheFinalResultType() throws {
        #expect(
            try conformanceOutput(builder: Self.finalResult)
                .contains("    @HookBuilder var hooks: Chain { }")
        )
        #expect(try conformanceDiagnostics(builder: Self.finalResult).isEmpty)
    }

    @Test func zeroParameterBuilderMemberIsAnEmptyFoldAccessor() throws {
        #expect(
            try conformanceOutput(builder: Self.zeroParameter)
                .contains("    @HookBuilder var hooks: [any Hook] { }")
        )
        #expect(try conformanceDiagnostics(builder: Self.zeroParameter).isEmpty)
    }

    @Test func partialBlockOnlyBuilderMemberIsAnErrorAtTheMember() throws {
        let diagnostics = try conformanceDiagnostics(builder: Self.partialOnly)
        #expect(diagnostics.map(\.location) == [SourceLocation(file: "Hooks.swift", line: 11, column: 19)])
        #expect(diagnostics.map(\.severity) == [.error])
        #expect(
            diagnostics.map(\.message) == [
                "graph conformance to 'Hooked' maps member 'hooks' to 'Keys.hooks', a BuilderKey with no @Contributes contributors in this graph, and its builder 'HookBuilder' declares no zero-argument buildBlock, so an empty '@HookBuilder' fold can't be formed. Declare 'static func buildBlock() -> [any Hook]' in 'HookBuilder', or contribute to 'Keys.hooks'."
            ]
        )
        #expect(!(try conformanceOutput(builder: Self.partialOnly).contains("var hooks")))
    }

    @Test func fixedArityBuilderMemberIsAnErrorAtTheMember() throws {
        let diagnostics = try conformanceDiagnostics(builder: Self.fixedArity)
        #expect(diagnostics.map(\.location) == [SourceLocation(file: "Hooks.swift", line: 9, column: 19)])
        #expect(
            diagnostics.map(\.message) == [
                "graph conformance to 'Hooked' maps member 'hooks' to 'Keys.hooks', a BuilderKey with no @Contributes contributors in this graph, and its builder 'HookBuilder' declares no zero-argument buildBlock, so an empty '@HookBuilder' fold can't be formed. Declare 'static func buildBlock() -> [any Hook]' in 'HookBuilder', or contribute to 'Keys.hooks'."
            ]
        )
        #expect(!(try conformanceOutput(builder: Self.fixedArity).contains("var hooks")))
    }

    @Test func aContributedMemberOverAnUnfoldableBuilderIsNotReported() throws {
        let built = build(
            conformanceSource(builder: Self.fixedArity) + "\n"
                + "@Singleton @Contributes(to: Keys.hooks) struct AuditHook: Hook {}"
        )
        let diagnostics = graphConformanceEmptyBuilderDiagnostics(
            conformances: built.discovery.graphConformances,
            topologicalOrder: try #require(built.graph.outcome.topologicalOrder),
            multibindingKeys: built.discovery.multibindingKeys,
            resultBuilders: built.discovery.resultBuilders
        )
        #expect(diagnostics.isEmpty)
    }

    @Test func wireGensConformanceCheckReportsUnfoldableMembersOnlyForAGraphThatResolved() throws {
        // The combined check WireGen runs: the unknown-key error always, the empty-builder error
        // only when the default graph has an order to judge against.
        let built = build(
            Self.fixedArity + "\n"
                + """
                enum Keys { static let hooks = BuilderKey<HookBuilder>(allowUnused: true) }
                enum Conformance {
                    static let decl = WireGraphConformanceV1(
                        conformsTo: (any Hooked).self,
                        members: [.init("hooks", from: Keys.hooks), .init("extras", from: Keys.missing)]
                    )
                }
                """
        )
        func messages(defaultOrder: [DiscoveredBinding]?) -> [String] {
            graphConformanceDiagnostics(
                built.discovery.graphConformances,
                defaultOrder: defaultOrder,
                multibindingKeys: built.discovery.multibindingKeys,
                resultBuilders: built.discovery.resultBuilders
            ).map(\.message)
        }
        let resolved = messages(defaultOrder: try #require(built.graph.outcome.topologicalOrder))
        #expect(resolved.count == 2)
        #expect(resolved.contains { $0.contains("maps member 'extras' to 'Keys.missing', which matches no") })
        #expect(resolved.contains { $0.contains("maps member 'hooks' to 'Keys.hooks', a BuilderKey") })
        #expect(messages(defaultOrder: nil).map { $0.contains("'extras'") } == [true])
    }

    @Test func aMemberBuiltWithoutALocationIsReportedAtTheConformance() {
        let conformance = DiscoveredGraphConformance(
            protocolName: "Hooked",
            members: [.init(name: "hooks", keyReference: "Keys.hooks")],
            location: mockLocation("Conformance.swift", line: 3, column: 7),
            originModule: testModule
        )
        let diagnostics = graphConformanceEmptyBuilderDiagnostics(
            conformances: [conformance],
            topologicalOrder: [],
            multibindingKeys: [
                DiscoveredMultibindingKey(
                    keyReference: "Keys.hooks",
                    flavour: .builder,
                    typeArguments: ["HookBuilder"],
                    location: mockLocation("Keys.swift"),
                    accessLevel: .internal,
                    originModule: testModule
                )
            ],
            resultBuilders: [
                DiscoveredResultBuilder(
                    typeName: "HookBuilder",
                    resultType: "[any Hook]",
                    location: mockLocation("HookBuilder.swift")
                )
            ]
        )
        #expect(diagnostics.map(\.location) == [mockLocation("Conformance.swift", line: 3, column: 7)])
    }
}
