import Testing

@testable import WireGenCore

/// `.rewritesInjection` — the pass behind `@Configuration` and anything shaped like it. These pin the
/// generic half: what Wire synthesises, how it deduplicates, and that it stays out of the way of
/// everything it was not pointed at. What the annotation *means* is the adapter's, and is tested there.
@Suite("Injection rewrites")
struct InjectionRewriteTests {
    private func annotation(
        _ name: String = "Configuration",
        provider: String = "ConfigReader"
    )
        -> DiscoveredAdapterAnnotation
    {
        DiscoveredAdapterAnnotation(
            annotationName: name,
            capability: .rewritesInjection(provider: provider),
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

    private func site(_ arguments: String) -> InjectionRewriteSite {
        InjectionRewriteSite(annotationName: "Configuration", arguments: arguments)
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
        // The wrapper is constructed with the site's arguments *verbatim* — Wire never reads the labels —
        // and asked for the value through the protocol's single requirement.
        #expect(rewrite.declaration.contains(#"Configuration<String>(forKey: "a", default: "x")"#))
        #expect(rewrite.declaration.contains(".wireValue(from: _wireProvider)"))
        #expect(rewrite.declaration.contains("_wireProvider: Configuration<String>.Provider"))
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
