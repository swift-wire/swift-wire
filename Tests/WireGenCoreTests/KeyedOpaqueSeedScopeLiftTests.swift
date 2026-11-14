// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Testing

@testable import WireGenCore

/// The seed-scope half of swift-wire#368, driven at the emission level. A seed scope lifts the parent
/// graph's opaque axes its stored bindings use; with two keyed `some P` axes of one protocol, which axes
/// are used has to be decided by identity, so a scope binding that reads only `K.b` lifts `K.b`'s axis and
/// leaves `K.a`'s opaque. The integration fixture exercises this through the out-of-process generator; this
/// pins it where the emitter runs in-process.
@Suite("KeyedOpaqueSeedScopeLift")
struct KeyedOpaqueSeedScopeLiftTests {
    private func render(_ source: String) throws -> String {
        let discovery = discover(in: source, sourcePath: "Keyed.swift", module: testModule)
        let seedKey = ScopeKey(seed: "RequestSeed")
        let appBindings = discovery.allBindings.filter { $0.key.scope == nil }.flatMap(\.value)
        let app = buildDependencyGraph(from: appBindings)
        #expect(app.outcome.validationErrors == nil)
        let appOrder = try #require(app.outcome.topologicalOrder)
        let orchestration = orchestrateSeedScope(
            seedKey: seedKey,
            scopeBindings: discovery.allBindings.filter { $0.key.scope == seedKey }.flatMap(\.value),
            borrowBindings: syntheticSingletonBorrowBindings(from: appOrder),
            typealiases: [],
            module: testModule,
            homeModule: testModule
        )
        #expect(orchestration.result.outcome.validationErrors == nil)
        let scope = SeedScopeEmission(
            seedTypeExpression: orchestration.seedTypeExpression,
            identifierSuffix: orchestration.identifierSuffix,
            parentGraphType: orchestration.parentGraphType,
            topologicalOrder: try #require(orchestration.result.outcome.topologicalOrder),
            borrowedBindingPropertyNames: orchestration.borrowedBindingPropertyNames
        )
        return renderWireGraph(imports: [], topologicalOrder: appOrder, seedScopeOrders: [scope])
    }

    @Test func aScopeBindingReadingOneKeyLiftsOnlyThatKeysAxis() throws {
        let output = try render(
            """
            @Provides(K.a) func makeA() -> some P { A() }
            @Provides(K.b) func makeB() -> some P { Bee() }

            @Scoped(seed: RequestSeed.self, allowUnused: true)
            struct Reader<Y: P> {
                @Inject(K.b) var y: Y
            }
            """
        )
        // Both keyed axes lift on the app graph…
        #expect(output.contains("internal struct _WireGraph<T0: P, T1: P>: Introspectable, Teardownable {"))
        // …but the scope uses only `K.b`'s, the second, so it lifts one parameter and threads it through
        // that position, leaving `K.a`'s opaque. Keyed on the type text, both axes read as `some P` and the
        // scope lifted both.
        #expect(output.contains("internal struct _RequestSeedWireScope<T0: P> {"))
        #expect(output.contains("    let readerOfSomeP: Reader<T0>\n"))
        #expect(
            output.contains(
                "wireGraph _wireGraph: _WireGraph<some P, T0>) async throws -> _RequestSeedWireScope<some P>"
            )
        )
        #expect(output.contains("Reader(y: _wireGraph.somePKeyedKB)"))
    }

    @Test func aMockedOpaqueScopeBindingIsSpelledWithItsMockType() {
        // A `@BindType`d `some P` in a test-variant scope is sourced from its double, which is a concrete
        // mock: it has no parent axis to lift, so its field and any consumer's parameter take the mock type.
        let mocked = DiscoveredBinding.provider(
            DiscoveredProvider(
                boundType: "some Store",
                accessPath: "doubles.store",
                form: .property,
                dependencies: [],
                genericParameterNames: [],
                location: mockLocation("<doubles>"),
                scopeKey: ScopeKey(seed: "RequestSeed"),
                originModule: testModule
            )
        )
        let scope = SeedScopeEmission(
            seedTypeExpression: "RequestSeed",
            identifierSuffix: "RequestSeed",
            parentGraphType: "_WireGraph",
            topologicalOrder: [mocked],
            borrowedBindingPropertyNames: [],
            doublesType: "_MyTests_bindMockDoubles",
            doublesFields: [DoublesField(name: "store", mockType: "MockStore")]
        )
        let output = renderWireGraph(imports: [], topologicalOrder: [], seedScopeOrders: [scope])
        #expect(output.contains("internal struct _RequestSeedWireScope {\n    let someStore: MockStore\n}"))
        #expect(output.contains("let someStore = doubles.store"))
    }

    @Test func aParameterNoDependencyFillsFallsBackToTheFirstAxisOfItsConstraint() throws {
        // The last resort: a parameter that no dependency carries is matched by its constraint text to the
        // first lifted axis spelled `some <constraint>`, whatever that axis's key.
        let discovery = discover(
            in: """
                @Provides(K.a) func makeA() -> some P { A() }
                @Provides(K.b) func makeB() -> some P { Bee() }
                """,
            sourcePath: "Keyed.swift",
            module: testModule
        )
        let axes = discovery.bindings.map(\.identity)
        #expect(axes.count == 2)
        let holder = DiscoveredBinding.scopeBound(
            DiscoveredScopeBoundType(
                typeName: "Holder",
                typeKind: "struct",
                genericParameterNames: ["R"],
                genericParameterConstraints: ["R": "P"],
                dependencies: [],
                location: mockLocation("Holder.swift"),
                originModule: testModule
            )
        )
        let lifted = LiftedParameters(
            parameterForIdentity: [axes[1]: "T0", axes[0]: "T1"],
            bindings: discovery.bindings + [holder],
            liftOrder: [axes[1], axes[0]]
        )
        #expect(lifted.opaqueIdentity(filling: "R", of: holder) == axes[1])
        #expect(lifted.spelling(of: "R", in: holder) == "T0")
        #expect(lifted.opaqueIdentity(filling: "Unconstrained", of: holder) == nil)
    }
}
