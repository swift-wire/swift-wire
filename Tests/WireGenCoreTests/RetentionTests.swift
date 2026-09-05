// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Testing

@testable import WireGenCore

/// retention narrowing — what the emitted graph *stores*, as distinct from what it constructs.
///
/// The distinction is the point: every binding here is constructed in the bootstrap body whatever these
/// tests assert; the question is only whether the graph holds a reference afterwards. Where a test wants
/// the *construction* to be visible it reads the bootstrap body, and where it wants the *retention*
/// decision it reads the struct.
@Suite("Retention")
struct RetentionTests {
    private func singleton(
        _ name: String,
        dependencies: [(name: String?, type: String)] = [],
        allowUnused: Bool = false,
        teardown: TeardownAction? = nil,
        module: String = testModule
    ) -> DiscoveredBinding {
        .scopeBound(
            DiscoveredScopeBoundType(
                typeName: name,
                typeKind: "struct",
                genericParameterNames: [],
                dependencies: dependencies.map {
                    DependencyParameter(
                        name: $0.name,
                        type: $0.type,
                        kind: .injectInitParameter,
                        location: mockLocation("\(name).swift")
                    )
                },
                location: mockLocation("\(name).swift"),
                allowUnused: allowUnused,
                teardown: teardown,
                originModule: module
            )
        )
    }

    private func aggregate(_ keyReference: String, element: String, contributors: [String]) -> DiscoveredBinding {
        .aggregate(
            DiscoveredAggregate(
                keyReference: keyReference,
                collectionType: "[\(element)]",
                flavour: .collected,
                contributors: contributors.map {
                    AggregateContributor(
                        dependency: DependencyParameter(
                            name: nil,
                            type: $0,
                            kind: .injectInitParameter,
                            location: mockLocation("\($0).swift")
                        )
                    )
                },
                location: mockLocation("\(keyReference).swift"),
                originModule: testModule
            )
        )
    }

    /// The default: a binding a consumer reaches is built, used and dropped. `Consumer` is a root, so it
    /// stays; `Leaf` is reached only *through* it and becomes a bootstrap local.
    @Test func aReachedButUnrootedBindingIsConstructedAndNotStored() {
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [
                singleton("Leaf"),
                singleton("Consumer", dependencies: [(name: "leaf", type: "Leaf")], allowUnused: true),
            ]
        )
        // Constructed — the narrowing is about retention, never about what runs.
        #expect(output.contains("let leaf = Leaf()"))
        #expect(output.contains("let consumer = Consumer(leaf: leaf)"))
        // Not stored, and absent from the memberwise init.
        #expect(!output.contains("    let leaf: Leaf"))
        #expect(output.contains("return _WireGraph(consumer: consumer)"))
    }

    /// The migration diagnostic. It has to name the property the developer reads, the annotation that
    /// brings it back, and where to put it — the read site and the declaration are in different files.
    @Test func aDroppedPropertyLeavesAnUnavailableStubNamingItsFix() {
        let output = renderWireGraph(imports: [], topologicalOrder: [singleton("Leaf")])
        #expect(output.contains("@available(*, unavailable, message:"))
        #expect(output.contains("'leaf' is constructed by the graph but not a direct property of it"))
        #expect(output.contains("To read it as 'graph.leaf'"))
        #expect(output.contains("mark its binding at Leaf.swift:1 'allowUnused: true'"))
        // A computed stub, so it is absent from the memberwise init and stores nothing.
        #expect(output.contains("internal var leaf: Leaf { fatalError() }"))
        #expect(output.contains("return _WireGraph()"))
    }

    /// The stub costs exactly what the stored property cost — one line — so narrowing retention does not
    /// trade against the generated-volume axis reachability pruning optimised.
    @Test func theStubIsLineForLineWhatTheStoredPropertyWas() {
        let stored = renderWireGraph(imports: [], topologicalOrder: [singleton("Leaf", allowUnused: true)])
        let dropped = renderWireGraph(imports: [], topologicalOrder: [singleton("Leaf")])
        #expect(stored.split(separator: "\n").count == dropped.split(separator: "\n").count)
    }

    @Test func anAllowUnusedHomeBindingIsStored() {
        let output = renderWireGraph(imports: [], topologicalOrder: [singleton("Leaf", allowUnused: true)])
        #expect(output.contains("    let leaf: Leaf"))
        #expect(output.contains("return _WireGraph(leaf: leaf)"))
    }

    /// A *library's* `allowUnused` keeps its diagnostic meaning only — the same home-package rule
    /// `declaredRoots` applies to reachability, for the same reason: a library cannot declare itself a
    /// root of its consumer's graph.
    @Test func aLibrarysAllowUnusedDoesNotRetain() {
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [singleton("Leaf", allowUnused: true, module: "LibraryModule")],
            externalModules: ["LibraryModule"]
        )
        #expect(!output.contains("    let leaf: Leaf"))
        #expect(output.contains("internal var leaf: Leaf { fatalError() }"))
    }

    /// `@Teardown` is the one place reachability pruning's answer and retention narrowing's differ, deliberately. It does **not** root a
    /// binding for reachability — a resource nothing reaches is never built — but it does retain one that
    /// is built, because the teardown closure captures the local either way.
    @Test func aTeardownBindingIsStoredWithoutAllowUnused() {
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [
                singleton(
                    "Pool",
                    teardown: TeardownAction(
                        kind: .member(methodName: "close", isAsync: true, isThrowing: false),
                        location: mockLocation("Pool.swift")
                    )
                )
            ]
        )
        #expect(output.contains("    let pool: Pool"))
        #expect(output.contains("pool: pool"))
    }

    /// An opaquely-bound binding lifts a generic parameter onto the struct, so the graph's *type* names
    /// it — `_WireGraph<some Greeting>`, which every bootstrap return type and `wireGraph:` parameter
    /// spells. Dropping it would be a change to the graph's type identity rather than to what it retains.
    @Test func anOpaqueLiftedBindingIsStored() {
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [
                .provider(
                    DiscoveredProvider(
                        boundType: "some Greeting",
                        accessPath: "greeting",
                        form: .property,
                        dependencies: [],
                        genericParameterNames: [],
                        location: mockLocation("Greeting.swift"),
                        originModule: testModule
                    )
                )
            ]
        )
        #expect(output.contains("internal struct _WireGraph<T0: Greeting>"))
        #expect(output.contains("    let someGreeting: T0"))
    }

    /// The silent root: a conformance member whose key has no aggregate falls back to an empty accessor
    /// by design, so an aggregate dropped from storage would leave a graph that compiles, boots and
    /// serves nothing. The witness reads it off `self`.
    @Test func anAggregateAGraphConformanceNamesIsStored() {
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [
                singleton("Alpha"),
                aggregate("ServiceKey.services", element: "any Service", contributors: ["Alpha"]),
            ],
            graphConformances: [
                DiscoveredGraphConformance(
                    protocolName: "Composable",
                    members: [.init(name: "services", keyReference: "ServiceKey.services")],
                    location: mockLocation("Conformance.swift"),
                    originModule: testModule
                )
            ]
        )
        #expect(output.contains("    let anyServiceKeyedServiceKeyServices: [any Service]"))
        #expect(output.contains("extension _WireGraph: Composable {"))
    }

    /// Introspection is baked string literals with no property reads, so it keeps describing the whole
    /// graph — what was *built* — regardless of what is retained. Losing that would make the narrowing
    /// visible in the wiring model, which is a view of the graph, not of the struct.
    @Test func introspectionStillDescribesEveryBinding() {
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [
                singleton("Leaf"),
                singleton("Consumer", dependencies: [(name: "leaf", type: "Leaf")], allowUnused: true),
            ]
        )
        #expect(output.contains("BindingInfo(type: \"Leaf\""))
        #expect(output.contains("BindingInfo(type: \"Consumer\""))
    }
}
