import Testing

@testable import WireGenCore

/// M7c.2 — the per-graph trigger, and the shape the scheduled emission produces.
///
/// The trigger is the whole of this step's blast radius: a graph that does not qualify keeps the linear
/// `let` chain byte for byte, which is what let M7c.2 land with every pre-existing graph in
/// `GoldenHarness` unchanged. So the negative cases matter at least as much as the positive one.
@Suite("Construction scheduling")
struct ConstructionSchedulingTests {
    private func singleton(
        _ name: String,
        dependencies: [(name: String?, type: String)] = [],
        initIsAsync: Bool = false,
        memberInjections: [MemberInjection] = [],
        teardown: TeardownAction? = nil
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
                initIsAsync: initIsAsync,
                memberInjections: memberInjections,
                allowUnused: true,
                teardown: teardown,
                originModule: testModule
            )
        )
    }

    private func provider(_ accessPath: String, boundType: String, isAsync: Bool = false) -> DiscoveredBinding {
        .provider(
            DiscoveredProvider(
                boundType: boundType,
                accessPath: accessPath,
                form: .property,
                dependencies: [],
                genericParameterNames: [],
                location: mockLocation("\(accessPath).swift"),
                isAsync: isAsync,
                allowUnused: true,
                originModule: testModule
            )
        )
    }

    // MARK: - The trigger

    @Test func aWhollySyncGraphKeepsTheLinearChain() {
        // The negative case that protects every existing graph: no suspension, nothing to schedule
        // around, so not one line of the machinery is emitted.
        let output = renderWireGraph(imports: [], topologicalOrder: [singleton("Leaf")])
        #expect(output.contains("let leaf = Leaf()"))
        #expect(!output.contains("_WireBindingState"))
        #expect(!output.contains("WireBuilding"))
    }

    @Test func anAsyncGraphIsScheduled() {
        let output = renderWireGraph(imports: [], topologicalOrder: [singleton("Pool", initIsAsync: true)])
        #expect(output.contains("private struct _WireBuilding: ~Copyable {"))
        #expect(output.contains("var _wireState_pool: _WireBindingState<Pool> = .unmarked"))
        #expect(output.contains("_wireState_pool.asResolved(await Pool())"))
        #expect(!output.contains("let pool = await Pool()"))
    }

    @Test func theCellTypeComesFromTheLibraryRatherThanBeingEmitted() {
        // `_WireBindingState` is `Wire`'s, so however many graphs a file schedules it is never declared
        // here — only referenced. Generated code already names Wire's public types for the graph struct's
        // own conformances, so the import that makes this resolve is one every graph file already needs.
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [singleton("Pool", initIsAsync: true)],
            containerTopologicalOrders: ["Other": [singleton("Cache", initIsAsync: true)]]
        )
        #expect(!output.contains("enum _WireBindingState"))
        #expect(output.contains("private struct _WireBuilding: ~Copyable {"))
        #expect(output.contains("private struct _OtherWireBuilding: ~Copyable {"))
    }

    // MARK: - The exclusions M7c.4 owns

    @Test func aMemberInjectionKeepsTheGraphOnTheLinearChain() {
        // Member injections run as one post-construction block over every local at once, so they have no
        // single resolution to hang off.
        let injected = singleton(
            "Hub",
            initIsAsync: true,
            memberInjections: [
                MemberInjection(
                    shape: .propertyAssignment(propertyName: "spoke"),
                    parameters: [
                        DependencyParameter(
                            name: nil,
                            type: "Spoke",
                            kind: .injectInitParameter,
                            location: mockLocation("Hub.swift")
                        )
                    ],
                    location: mockLocation("Hub.swift")
                )
            ]
        )
        let output = renderWireGraph(imports: [], topologicalOrder: [injected, singleton("Spoke")])
        #expect(!output.contains("_WireBindingState"))
    }

    @Test func aTeardownBindingKeepsTheGraphOnTheLinearChain() {
        // The teardown closure captures each binding's concrete *local*, which the scheduled form does
        // not have.
        let torn = singleton(
            "Pool",
            initIsAsync: true,
            teardown: TeardownAction(
                kind: .member(methodName: "close", isAsync: true, isThrowing: false),
                location: mockLocation("Pool.swift")
            )
        )
        let output = renderWireGraph(imports: [], topologicalOrder: [torn])
        #expect(!output.contains("_WireBindingState"))
    }

    @Test func anExistentialPromotionKeepsTheGraphOnTheLinearChain() {
        let consumer = singleton(
            "Reporter",
            dependencies: [(name: "greeting", type: "any Greeting")],
            initIsAsync: true
        )
        let producer = provider("someGreeting", boundType: "some Greeting")
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [producer, consumer],
            existentialPromotions: [
                ExistentialPromotion(
                    consumer: consumer.identity,
                    producer: producer.identity,
                    existentialType: "any Greeting"
                )
            ]
        )
        #expect(!output.contains("_WireBindingState"))
    }

    @Test func anOpaqueLiftKeepsTheGraphOnTheLinearChain() {
        // A `some P` binding puts a generic parameter on the graph struct that the building struct would
        // have to mirror and the bootstrap infer through both.
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [provider("someGreeting", boundType: "some Greeting", isAsync: true)]
        )
        #expect(!output.contains("_WireBindingState"))
    }

    // MARK: - The cascade

    @Test func aDependentIsFiredFromEveryDependencyAndGuardedUntilAllResolve() {
        // The structure the whole design rests on. `Service` is fired by both dependencies, and its
        // dependency check precedes the pending transition so that whichever resolves last constructs it
        // — claiming the cell first would strand it.
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [
                singleton("Pool", initIsAsync: true),
                singleton("Cache", initIsAsync: true),
                singleton("Service", dependencies: [(name: "pool", type: "Pool"), (name: "cache", type: "Cache")]),
            ]
        )
        #expect(output.ranges(of: "try await _wireAdd_service()").count == 2)
        let guardLine = "guard let pool = _wireState_pool.value(), let cache = _wireState_cache.value() else { return }"
        #expect(output.contains(guardLine))
        let depCheck = output.firstRange(of: guardLine)!
        let pending = output.firstRange(of: "guard _wireState_service.asPending() else { return }")!
        #expect(depCheck.lowerBound < pending.lowerBound)
    }

    @Test func onlySourceBindingsAreDrivenFromTheBootstrap() {
        // Driving from the sources is what makes the cascade load-bearing rather than decorative: under
        // the topological order every `add` would already find its dependencies resolved.
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [
                singleton("Pool", initIsAsync: true),
                singleton("Service", dependencies: [(name: "pool", type: "Pool")]),
            ]
        )
        #expect(output.contains("    try await building._wireAdd_pool()"))
        #expect(!output.contains("    try await building._wireAdd_service()"))
    }

    @Test func theMemberwiseInitTakesEachStoredBindingOutOfItsCell() {
        // M7c.1's retained set still decides *what* is stored; the scheduled form only changes where the
        // value comes from — a cell rather than a `let` the scheduled body never bound.
        let output = renderWireGraph(imports: [], topologicalOrder: [singleton("Pool", initIsAsync: true)])
        #expect(output.contains("return _WireGraph(pool: building._wireState_pool.take())"))
    }
}
