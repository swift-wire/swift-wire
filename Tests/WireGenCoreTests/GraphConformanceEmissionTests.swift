// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Testing

@testable import WireGenCore

/// graph conformance: graph-conformance emission. Pins that a discovered
/// `WireGraphConformanceV1` emits `extension _WireGraph: <Protocol>`, mapping each
/// member to the aggregate binding for its multibinding key — the member's type
/// spelled from the aggregate's product type so the protocol's associated types
/// are inferred from the witness.
@Suite("Graph conformance emission")
struct GraphConformanceEmissionTests {
    private func contributor(_ name: String, to keyReference: String) -> DiscoveredBinding {
        .scopeBound(
            DiscoveredScopeBoundType(
                typeName: name,
                typeKind: "struct",
                genericParameterNames: [],
                dependencies: [],
                location: mockLocation("\(name).swift"),
                contributions: [
                    Contribution(keyReference: keyReference, location: mockLocation("\(name).swift"))
                ],
                originModule: testModule
            )
        )
    }

    private func collectedKey(_ reference: String, element: String) -> DiscoveredMultibindingKey {
        DiscoveredMultibindingKey(
            keyReference: reference,
            flavour: .collected,
            typeArguments: [element],
            location: mockLocation("\(reference).swift"),
            accessLevel: .internal,
            originModule: testModule
        )
    }

    @Test func emitsExtensionMappingMemberToAggregateProperty() throws {
        // A `CollectedKey<any RouteContributor>` with one contributor synthesises an
        // aggregate `[any RouteContributor]` binding; the conformance maps `routes`
        // to it.
        let graph = buildDependencyGraph(
            from: [contributor("HelloController", to: "App.routes")],
            multibindingKeys: [collectedKey("App.routes", element: "any RouteContributor")]
        )
        let order = try #require(graph.outcome.topologicalOrder)

        let conformance = DiscoveredGraphConformance(
            protocolName: "HummingbirdComposable",
            members: [.init(name: "routes", keyReference: "App.routes")],
            location: mockLocation("Conformance.swift"),
            originModule: testModule
        )

        let output = renderWireGraph(imports: [], topologicalOrder: order, graphConformances: [conformance])

        #expect(output.contains("extension _WireGraph: HummingbirdComposable {"))
        // Member type is the aggregate's product type; the body reads it off the graph.
        #expect(output.contains("var routes: [any RouteContributor] { self."))
    }

    @Test func memberWithNoContributorsMapsToEmptyCollection() {
        // A conformance whose key has no contributors in this graph still emits — the
        // absent member maps to an empty collection, so the graph conforms and a
        // facade's `apply` works even when nothing is contributed.
        let order: [DiscoveredBinding] = [
            .scopeBound(
                DiscoveredScopeBoundType(
                    typeName: "App",
                    typeKind: "struct",
                    genericParameterNames: [],
                    dependencies: [],
                    location: mockLocation("App.swift"),
                    originModule: testModule
                )
            )
        ]

        let conformance = DiscoveredGraphConformance(
            protocolName: "HummingbirdComposable",
            members: [
                .init(name: "routes", keyReference: "App.routes"),
                .init(name: "services", keyReference: "App.services"),
            ],
            location: mockLocation("Conformance.swift"),
            originModule: testModule
        )

        let output = renderWireGraph(
            imports: [],
            topologicalOrder: order,
            graphConformances: [conformance],
            multibindingKeys: [
                collectedKey("App.routes", element: "any RouteContributor"),
                collectedKey("App.services", element: "any Service"),
            ]
        )

        #expect(output.contains("extension _WireGraph: HummingbirdComposable {"))
        #expect(output.contains("var routes: [any RouteContributor] { [] }"))
        #expect(output.contains("var services: [any Service] { [] }"))
    }

    @Test func noConformancesEmitNoExtension() {
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [
                .scopeBound(
                    DiscoveredScopeBoundType(
                        typeName: "App",
                        typeKind: "struct",
                        genericParameterNames: [],
                        dependencies: [],
                        location: mockLocation("App.swift"),
                        originModule: testModule
                    )
                )
            ]
        )
        #expect(!output.contains("extension _WireGraph:"))
    }

    @Test func memberWithAnUndeclaredKeyIsAnErrorNamingConformanceMemberAndKey() throws {
        // `App.missing` matches no multibinding key in the parse set, so emission has
        // nothing to witness `extras` with. WireGen reports it rather than leaving the
        // member out silently; the declared `App.routes` member is not reported.
        let conformance = DiscoveredGraphConformance(
            protocolName: "HummingbirdComposable",
            members: [
                .init(name: "routes", keyReference: "App.routes"),
                .init(name: "extras", keyReference: "App.missing"),
            ],
            location: mockLocation("Conformance.swift", line: 4, column: 16),
            originModule: testModule
        )
        let diagnostics = graphConformanceUnknownKeyDiagnostics(
            conformances: [conformance],
            declaredMultibindingKeyReferences: ["App.routes"]
        )
        #expect(diagnostics.count == 1)
        let diagnostic = try #require(diagnostics.first)
        #expect(diagnostic.severity == .error)
        #expect(diagnostic.location == conformance.location)
        #expect(
            diagnostic.message.hasPrefix(
                "graph conformance to 'HummingbirdComposable' maps member 'extras' to 'App.missing', which matches no CollectedKey, MappedKey or BuilderKey declared in the parse set"
            )
        )
    }

    @Test func memberMappedToASingleBindingKeyIsReported() {
        // A `BindingKey` is a declared key, but not a multibinding one: there is no
        // aggregate for it, so the member can't be witnessed either.
        let conformance = DiscoveredGraphConformance(
            protocolName: "Composable",
            members: [.init(name: "database", keyReference: "Keys.primary")],
            location: mockLocation("Conformance.swift"),
            originModule: testModule
        )
        let diagnostics = graphConformanceUnknownKeyDiagnostics(
            conformances: [conformance],
            declaredMultibindingKeyReferences: []
        )
        #expect(diagnostics.map(\.severity) == [.error])
    }

    @Test func membersWithDeclaredKeysAreNotReported() {
        // Every key declared — including one with no contributors, which emits an
        // empty accessor — so nothing is reported.
        let conformance = DiscoveredGraphConformance(
            protocolName: "HummingbirdComposable",
            members: [
                .init(name: "routes", keyReference: "App.routes"),
                .init(name: "services", keyReference: "App.services"),
            ],
            location: mockLocation("Conformance.swift"),
            originModule: testModule
        )
        let diagnostics = graphConformanceUnknownKeyDiagnostics(
            conformances: [conformance],
            declaredMultibindingKeyReferences: ["App.routes", "App.services"]
        )
        #expect(diagnostics.isEmpty)
    }
}
