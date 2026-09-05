// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import SwiftParser
import SwiftSyntax
import Testing

@testable import WireGenCore

/// `.rewritesInjection` — the pass behind `@ConfigProperty` and anything shaped like it. These pin the
/// generic half: what Wire synthesises, how it deduplicates, and that it stays out of the way of
/// everything it was not pointed at. What the annotation *means* is the adapter's, and is tested there.
@Suite("Injection rewrites")
struct InjectionRewriteTests {
    private func annotation(
        _ name: String = "Configuration",
        provider: String = "ConfigReader",
        selectorLabel: String? = nil
    )
        -> DiscoveredAdapterAnnotation
    {
        DiscoveredAdapterAnnotation(
            annotationName: name,
            capability: .rewritesInjection(provider: provider, selectorLabel: selectorLabel),
            location: mockLocation("Adapter.swift"),
            originModule: testModule
        )
    }

    /// A `@Provides` whose parameters carry the given rewrite sites.
    private func provider(
        _ name: String,
        parameters: [(type: String, site: InjectionRewriteSite?)]
    ) -> DiscoveredBinding {
        .provider(
            DiscoveredProvider(
                boundType: "Endpoint",
                accessPath: name,
                form: .function,
                dependencies: parameters.map {
                    DependencyParameter(
                        name: "p",
                        type: $0.type,
                        kind: .providerFunctionParameter,
                        location: mockLocation("\(name).swift"),
                        injectionRewrite: $0.site
                    )
                },
                genericParameterNames: [],
                location: mockLocation("\(name).swift"),
                originModule: testModule
            )
        )
    }

    /// A site built by parsing the attribute as written and running discovery's own scanner, so these
    /// pin the real path from source text to structured arguments rather than a hand-built stand-in.
    private func site(_ arguments: String, annotation: String = "Configuration") -> InjectionRewriteSite {
        let source = "@\(annotation)(\(arguments)) var x: Int"
        let variable = Parser.parse(source: source).statements.first?.item.as(VariableDeclSyntax.self)
        return injectionRewriteCandidate(in: variable!.attributes)!
    }

    // MARK: - What gets synthesised

    @Test func synthesisesAProducerCallingTheWrappersOwnValue() throws {
        let result = applyInjectionRewrites(
            to: [.default: [provider("endpoint", parameters: [("String", site(#"forKey: "a", default: "x""#))])]],
            annotations: [annotation()],
            consumerModule: testModule
        )
        let rewrite = try #require(result.synthesized.first)
        #expect(rewrite.valueType == "String")
        #expect(rewrite.providerType == "ConfigReader")
        // A *static* call, with the site's arguments copied verbatim after `from:` — Wire never reads the
        // labels, and builds no instance to resolve.
        #expect(
            rewrite.declaration.contains(
                #"Configuration<String>.wireValue(from: _wireProvider, forKey: "a", default: "x")"#
            )
        )
        // The provider is spelled as the capability named it — one source of truth, rather than also
        // relying on an associated type on the wrapper that would have to agree with it.
        #expect(rewrite.declaration.contains("_wireProvider: ConfigReader"))
    }

    /// Whether the adapter's `wireValue` throws is invisible here — it is another module's static method,
    /// picked by overload resolution over an argument list Wire copies without reading, and the same
    /// annotation resolves to a throwing overload at one site and a non-throwing one at the next. So the
    /// call is routed through an always-throwing `@autoclosure` and one `try` is correct for both.
    @Test func theProducerCarriesATryThatIsCorrectEitherWay() throws {
        let result = applyInjectionRewrites(
            to: [.default: [provider("host", parameters: [("String", site(#"forKey: "a", default: "x""#))])]],
            annotations: [annotation()],
            consumerModule: testModule
        )
        let rewrite = try #require(result.synthesized.first)
        #expect(
            rewrite.declaration.contains(
                #"try _wireRewritten(Configuration<String>.wireValue(from: _wireProvider, forKey: "a", default: "x"))"#
            )
        )
        // The producer still declares `throws`, so a throwing adapter needs no separate shape.
        #expect(rewrite.declaration.contains("throws -> String"))
    }

    /// The helper the producers route through: emitted into the generated file, `private` to it, and
    /// unconditionally throwing — which is what makes the caller's `try` justified when the adapter's
    /// call throws nothing.
    @Test func theHelperIsPrivateAndAlwaysThrowing() {
        #expect(injectionRewriteHelperDeclaration.contains("private func _wireRewritten<Value>"))
        #expect(injectionRewriteHelperDeclaration.contains("@autoclosure () throws -> Value"))
        #expect(injectionRewriteHelperDeclaration.contains(") throws -> Value {"))
    }

    @Test func theAnnotatedSiteResolvesToTheSynthesisedProducer() throws {
        let result = applyInjectionRewrites(
            to: [.default: [provider("endpoint", parameters: [("Int", site(#"forKey: "p", default: 1"#))])]],
            annotations: [annotation()],
            consumerModule: testModule
        )
        let rewrite = try #require(result.synthesized.first)
        let consumer = try #require(result.bindings[.default]?.first { $0.boundType == "Endpoint" })
        // Keyed to the synthesised binding, so it cannot capture — or be captured by — a plain `Int`.
        #expect(consumer.dependencies.first?.keyIdentifier == rewrite.keyIdentifier)
        #expect(consumer.dependencies.first?.type == "Int")
    }

    // MARK: - Deduplication

    @Test func identicalSitesShareOneProducer() {
        let same = site(#"forKey: "a", default: "x""#)
        let result = applyInjectionRewrites(
            to: [
                .default: [
                    provider("one", parameters: [("String", same)]),
                    provider("two", parameters: [("String", same)]),
                ]
            ],
            annotations: [annotation()],
            consumerModule: testModule
        )
        // One binding, read once — not once per site.
        #expect(result.synthesized.count == 1)
    }

    @Test func differentArgumentsOrTypesStayDistinct() {
        let result = applyInjectionRewrites(
            to: [
                .default: [
                    provider(
                        "one",
                        parameters: [
                            ("String", site(#"forKey: "a", default: "x""#)),
                            ("String", site(#"forKey: "b", default: "x""#)),  // different key
                            ("Int", site(#"forKey: "a", default: "x""#)),  // same key, other type
                        ]
                    )
                ]
            ],
            annotations: [annotation()],
            consumerModule: testModule
        )
        #expect(result.synthesized.count == 3)
    }

    // MARK: - Selecting which provider to read from

    /// The declared selector argument leaves the spliced list and keys the provider dependency instead.
    /// By resolution time the provider is already resolved, so passing it on would be meaningless.
    @Test func aDeclaredSelectorKeysTheProviderAndLeavesTheArgumentList() throws {
        let result = applyInjectionRewrites(
            to: [
                .default: [
                    provider(
                        "one",
                        parameters: [("String", site(#"reader: Keys.testReader, forKey: "a", default: "x""#))]
                    )
                ]
            ],
            annotations: [annotation(selectorLabel: "reader")],
            consumerModule: testModule
        )
        let synthesized = try #require(result.synthesized.first)
        #expect(synthesized.providerKey == "Keys.testReader")
        // Spliced verbatim, minus the selector.
        #expect(synthesized.declaration.contains(#"wireValue(from: _wireProvider, forKey: "a", default: "x")"#))
        #expect(!synthesized.declaration.contains("Keys.testReader"))
    }

    /// The same label without the adapter declaring a selector is an ordinary argument, spliced like any
    /// other: recognition is driven by what the adapter declared, never by the spelling.
    @Test func anUndeclaredSelectorLabelIsJustAnArgument() throws {
        let result = applyInjectionRewrites(
            to: [
                .default: [provider("one", parameters: [("String", site(#"reader: Keys.testReader, forKey: "a""#))])]
            ],
            annotations: [annotation()],
            consumerModule: testModule
        )
        let synthesized = try #require(result.synthesized.first)
        #expect(synthesized.providerKey == nil)
        #expect(synthesized.declaration.contains("reader: Keys.testReader"))
    }

    /// Omitting the selector at a site whose adapter declares one resolves the provider by type, which is
    /// what every pre-selector site does.
    @Test func omittingTheSelectorLeavesTheProviderUnkeyed() throws {
        let result = applyInjectionRewrites(
            to: [.default: [provider("one", parameters: [("String", site(#"forKey: "a", default: "x""#))])]],
            annotations: [annotation(selectorLabel: "reader")],
            consumerModule: testModule
        )
        #expect(try #require(result.synthesized.first).providerKey == nil)
    }

    /// The failure this change could most easily introduce, and the quietest: the selector leaves the
    /// argument list, so if it also left the dedup identity these two sites would collapse into one
    /// binding and both would read from whichever provider won.
    @Test func sameArgumentsFromDifferentProvidersAreDistinctBindings() {
        let result = applyInjectionRewrites(
            to: [
                .default: [
                    provider(
                        "one",
                        parameters: [
                            ("String", site(#"reader: Keys.primary, forKey: "a", default: "x""#)),
                            ("String", site(#"reader: Keys.secondary, forKey: "a", default: "x""#)),
                        ]
                    )
                ]
            ],
            annotations: [annotation(selectorLabel: "reader")],
            consumerModule: testModule
        )
        #expect(result.synthesized.count == 2)
        #expect(Set(result.synthesized.map(\.providerKey)) == ["Keys.primary", "Keys.secondary"])
        // Distinct binding keys too, or the two producers collide on one name.
        #expect(Set(result.synthesized.map(\.keyIdentifier)).count == 2)
    }

    /// A rewritten site's synthesised provider dependency is anchored at the annotation the user wrote.
    /// Without this, an undeclared selector key reports against `<synthetic>:0:0` — an error with no
    /// file and no line.
    @Test func theSynthesisedProviderIsAnchoredAtARealSite() throws {
        let result = applyInjectionRewrites(
            to: [
                .default: [
                    provider("one", parameters: [("String", site(#"reader: Keys.testReader, forKey: "a""#))])
                ]
            ],
            annotations: [annotation(selectorLabel: "reader")],
            consumerModule: testModule
        )
        #expect(try #require(result.synthesized.first).location.file == "one.swift")
    }

    // MARK: - Staying out of the way

    @Test func anUnannotatedDependencyIsUntouched() {
        let input: [Partition: [DiscoveredBinding]] = [
            .default: [provider("plain", parameters: [("String", nil)])]
        ]
        let result = applyInjectionRewrites(to: input, annotations: [annotation()], consumerModule: testModule)
        #expect(result.synthesized.isEmpty)
        #expect(result.bindings[.default]?.first?.dependencies.first?.keyIdentifier == nil)
    }

    /// An attribute Wire has not been *told* is a rewrite stays an ordinary attribute — recognition is
    /// driven by what an adapter declared, never by the attribute's spelling.
    @Test func anUndeclaredAnnotationIsNotARewrite() {
        let result = applyInjectionRewrites(
            to: [.default: [provider("one", parameters: [("String", site(#"forKey: "a""#))])]],
            annotations: [annotation("SomethingElse")],
            consumerModule: testModule
        )
        #expect(result.synthesized.isEmpty)
    }

    @Test func noRewritingAnnotationsIsANoOp() {
        let input: [Partition: [DiscoveredBinding]] = [
            .default: [provider("one", parameters: [("String", site(#"forKey: "a""#))])]
        ]
        let result = applyInjectionRewrites(to: input, annotations: [], consumerModule: testModule)
        #expect(result.synthesized.isEmpty)
        #expect(result.bindings[.default]?.count == 1)
    }
}
