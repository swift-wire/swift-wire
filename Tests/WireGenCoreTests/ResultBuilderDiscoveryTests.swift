// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Testing

@testable import WireGenCore

/// Step 5b: discovery of `@resultBuilder` types and their fold result
/// type, which a `BuilderKey` aggregate produces. The result type comes
/// from `buildFinalResult` when present, else `buildBlock`.
@Suite("Result builder discovery")
struct ResultBuilderDiscoveryTests {
    private func builders(in source: String) -> [DiscoveredResultBuilder] {
        discover(in: source, sourcePath: "B.swift", module: testModule).resultBuilders
    }

    @Test func buildBlockResultTypeIsCaptured() throws {
        let source = """
            @resultBuilder
            enum MiddlewarePipeline {
                static func buildBlock(_ parts: any Middleware...) -> Pipeline {
                    Pipeline(steps: parts.map(\\.step))
                }
            }
            """
        let builder = try #require(builders(in: source).first)
        #expect(builder.typeName == "MiddlewarePipeline")
        #expect(builder.resultType == "Pipeline")
    }

    @Test func buildFinalResultIsPreferredOverBuildBlock() throws {
        let source = """
            @resultBuilder
            struct ChainBuilder {
                static func buildBlock(_ parts: Part...) -> [Part] { parts }
                static func buildFinalResult(_ parts: [Part]) -> Chain { Chain(parts) }
            }
            """
        let builder = try #require(builders(in: source).first)
        #expect(builder.resultType == "Chain")
    }

    /// Whether the builder's own `buildBlock`s include one callable with no arguments.
    private func acceptsEmptyBlock(_ members: String) throws -> Bool {
        let source = "@resultBuilder\nenum HookBuilder {\n" + members + "\n}"
        return try #require(builders(in: source).first).acceptsEmptyBlock
    }

    @Test func buildBlockCallableWithNoArgumentsAcceptsAnEmptyBlock() throws {
        #expect(try acceptsEmptyBlock("static func buildBlock(_ hooks: any Hook...) -> [any Hook] { hooks }"))
        #expect(try acceptsEmptyBlock("static func buildBlock() -> [any Hook] { [] }"))
        #expect(try acceptsEmptyBlock("static func buildBlock(_ hook: (any Hook)? = nil) -> [any Hook] { [] }"))
        #expect(
            try acceptsEmptyBlock(
                """
                static func buildBlock(_ hook: any Hook) -> [any Hook] { [hook] }
                static func buildBlock() -> [any Hook] { [] }
                """
            )
        )
    }

    @Test func buildBlockNeedingAnArgumentOrPartialBlockOnlyDoesNotAcceptAnEmptyBlock() throws {
        #expect(try !acceptsEmptyBlock("static func buildBlock(_ hook: any Hook) -> [any Hook] { [hook] }"))
        #expect(
            try !acceptsEmptyBlock(
                "static func buildBlock(_ first: any Hook, _ rest: any Hook...) -> [any Hook] { [first] + rest }"
            )
        )
        #expect(
            try !acceptsEmptyBlock(
                """
                static func buildPartialBlock(first: any Hook) -> [any Hook] { [first] }
                static func buildFinalResult(_ hooks: [any Hook]) -> [any Hook] { hooks }
                """
            )
        )
    }

    @Test func buildBlockInAnExtensionIsNotRead() throws {
        // Consistent with the result type, which is also read from the type's own body only (#420).
        let source = """
            @resultBuilder
            enum HookBuilder {
                static func buildFinalResult(_ hooks: [any Hook]) -> [any Hook] { hooks }
            }
            extension HookBuilder {
                static func buildBlock(_ hooks: any Hook...) -> [any Hook] { hooks }
            }
            """
        #expect(try !#require(builders(in: source).first).acceptsEmptyBlock)
    }

    @Test func nonResultBuilderTypeIsIgnored() {
        let source = """
            enum NotABuilder {
                static func buildBlock(_ parts: Part...) -> [Part] { parts }
            }
            """
        #expect(builders(in: source).isEmpty)
    }
}
