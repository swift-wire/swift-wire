import Testing

@testable import WireGenCore

/// M7c.3 — the per-graph trigger, and the shape the scheduled emission produces.
///
/// The trigger is the whole of this step's blast radius: a graph that does not qualify keeps the linear
/// `let` chain byte for byte, which is what lets the scheduler land with every other graph in
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

    /// Two async bindings with nothing between them — the smallest graph that qualifies.
    private func independentAsyncPair() -> [DiscoveredBinding] {
        [singleton("Pool", initIsAsync: true), singleton("Cache", initIsAsync: true)]
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

    @Test func aSingleAsyncBindingKeepsTheLinearChain() {
        // One async binding in a group is one child task the parent immediately blocks on — the
        // sequential chain plus machinery, and the `Sendable` requirement for nothing. M7c.2's staging
        // emitted the state struct here; M7c.3 narrows the trigger to graphs a group can actually win on.
        let output = renderWireGraph(imports: [], topologicalOrder: [singleton("Pool", initIsAsync: true)])
        #expect(output.contains("let pool = await Pool()"))
        #expect(!output.contains("_WireBindingState"))
    }

    @Test func aChainOfAsyncBindingsKeepsTheLinearChain() {
        // Two async bindings, but the second consumes the first, so nothing can overlap: a scheduler
        // would emit the same order it already has.
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [
                singleton("Pool", initIsAsync: true),
                singleton("Service", dependencies: [(name: "pool", type: "Pool")], initIsAsync: true),
            ]
        )
        #expect(!output.contains("_WireBindingState"))
    }

    @Test func twoIndependentAsyncBindingsAreScheduled() {
        let output = renderWireGraph(imports: [], topologicalOrder: independentAsyncPair())
        #expect(output.contains("private struct _WireBuilding: ~Copyable {"))
        #expect(output.contains("var _wireState_pool: _WireBindingState<Pool> = .unmarked"))
        #expect(output.contains("_wireGroup.addTask { .pool(await Pool()) }"))
        #expect(!output.contains("let pool = await Pool()"))
    }

    @Test func independenceIsTransitiveThroughSyncBindings() {
        // `Cache` reaches `Pool` only through a sync binding, so the two are a chain and the graph does
        // not qualify. The walk has to follow every edge, not just the async ones.
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [
                singleton("Pool", initIsAsync: true),
                singleton("Bridge", dependencies: [(name: "pool", type: "Pool")]),
                singleton("Cache", dependencies: [(name: "bridge", type: "Bridge")], initIsAsync: true),
            ]
        )
        #expect(!output.contains("_WireBindingState"))
    }

    @Test func theCellTypeComesFromTheLibraryRatherThanBeingEmitted() {
        // `_WireBindingState` is `Wire`'s, so however many graphs a file schedules it is never declared
        // here — only referenced. Generated code already names Wire's public types for the graph struct's
        // own conformances, so the import that makes this resolve is one every graph file already needs.
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: independentAsyncPair(),
            containerTopologicalOrders: [
                "Other": [singleton("Store", initIsAsync: true), singleton("Index", initIsAsync: true)]
            ]
        )
        #expect(!output.contains("enum _WireBindingState"))
        #expect(output.contains("private struct _WireBuilding: ~Copyable {"))
        #expect(output.contains("private struct _OtherWireBuilding: ~Copyable {"))
        // Each graph owns its own marker type, since the cases are its own bindings.
        #expect(output.contains("private enum _WireTaskResult: Sendable {"))
        #expect(output.contains("private enum _OtherWireTaskResult: Sendable {"))
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
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [injected, singleton("Cache", initIsAsync: true), singleton("Spoke")]
        )
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
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [torn, singleton("Cache", initIsAsync: true)]
        )
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
            topologicalOrder: [producer, consumer, singleton("Cache", initIsAsync: true)],
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
            topologicalOrder: [
                provider("someGreeting", boundType: "some Greeting", isAsync: true),
                singleton("Cache", initIsAsync: true),
            ]
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
            topologicalOrder: independentAsyncPair() + [
                singleton("Service", dependencies: [(name: "pool", type: "Pool"), (name: "cache", type: "Cache")])
            ]
        )
        // Both firings are from the drain, since both dependencies resolve in a child task.
        #expect(output.ranges(of: "try _wireAdd_service(&_wireGroup)").count == 2)
        let guardLine = "guard let pool = _wireState_pool.value(), let cache = _wireState_cache.value() else { return }"
        #expect(output.contains(guardLine))
        let depCheck = output.firstRange(of: guardLine)!
        let pending = output.firstRange(of: "guard _wireState_service.asPending() else { return }")!
        #expect(depCheck.lowerBound < pending.lowerBound)
    }

    @Test func aScheduledBindingCascadesFromTheDrainRatherThanFromItsOwnAdd() {
        // The parent's half of the task boundary. An `add` that scheduled its construction has no value
        // to cascade with, so `_wireUpdate` — running on the frame that owns every cell — applies the
        // child's result and fires the dependents.
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: independentAsyncPair() + [
                singleton("Service", dependencies: [(name: "pool", type: "Pool")])
            ]
        )
        #expect(output.contains("case .pool(let _wireValue):"))
        #expect(output.contains("            _wireState_pool.asResolved(_wireValue)"))
        #expect(output.contains("            try _wireAdd_service(&_wireGroup)"))
        // The scheduling `add` itself ends at `addTask` — no cascade, and nothing resolved.
        #expect(!output.contains("_wireGroup.addTask { .pool(await Pool()) }\n        try _wireAdd_service"))
    }

    @Test func aSyncBindingStillConstructsAndCascadesOnTheParent() {
        // Only suspension moves into a child task. A sync binding downstream of a scheduled one is built
        // inline during the drain, which is what lets it read a non-Sendable dependency out of its cell.
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: independentAsyncPair() + [
                singleton("Service", dependencies: [(name: "pool", type: "Pool")]),
                singleton("Host", dependencies: [(name: "service", type: "Service")]),
            ]
        )
        #expect(output.contains("_wireState_service.asResolved(Service(pool: pool))"))
        #expect(output.contains("        try _wireAdd_host(&_wireGroup)"))
    }

    @Test func onlySourceBindingsAreDrivenFromTheBootstrap() {
        // Driving from the sources is what makes the cascade load-bearing rather than decorative: under
        // the topological order every `add` would already find its dependencies resolved.
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: independentAsyncPair() + [
                singleton("Service", dependencies: [(name: "pool", type: "Pool")])
            ]
        )
        #expect(output.contains("        try building._wireAdd_pool(&_wireGroup)"))
        #expect(!output.contains("        try building._wireAdd_service(&_wireGroup)"))
    }

    @Test func theDrainRunsUntilTheGroupEmpties() {
        // `while let … = try await next()` rather than `for try await … in`: the body needs the group
        // `inout` to schedule from a cascade, and iterating it while mutating it is an overlapping access.
        let output = renderWireGraph(imports: [], topologicalOrder: independentAsyncPair())
        #expect(output.contains("return try await withThrowingTaskGroup(of: _WireTaskResult.self) { _wireGroup in"))
        #expect(output.contains("while let _wireResult = try await _wireGroup.next() {"))
        #expect(output.contains("try building._wireUpdate(_wireResult, &_wireGroup)"))
    }

    @Test func theMemberwiseInitTakesEachStoredBindingOutOfItsCell() {
        // M7c.1's retained set still decides *what* is stored; the scheduled form only changes where the
        // value comes from — a cell rather than a `let` the scheduled body never bound — and that it is
        // written inside the group closure, one indent deeper.
        let output = renderWireGraph(imports: [], topologicalOrder: independentAsyncPair())
        #expect(
            output.contains(
                "        return _WireGraph(pool: building._wireState_pool.take(), "
                    + "cache: building._wireState_cache.take())"
            )
        )
    }

    // MARK: - The Sendable requirement

    @Test func everyBindingCrossingTheTaskBoundaryIsAssertedSendableAtItsOwnSourceLine() {
        // Wire reads syntax and cannot see a conformance, so the requirement is asserted rather than
        // decided. `#sourceLocation` puts the resulting error on the user's binding instead of on the
        // generated enum, which is the same instrument `_WireKeyChecks.swift` uses for a keyed mismatch.
        let output = renderWireGraph(imports: [], topologicalOrder: independentAsyncPair())
        #expect(output.contains("private func _wireSendableChecks_WireGraph() {"))
        #expect(output.contains("    func _check<T: Sendable>(_: T.Type) {}"))
        #expect(output.contains("    #sourceLocation(file: \"Pool.swift\", line: 1)"))
        #expect(output.contains("    _check((Pool).self)"))
        #expect(output.contains("    #sourceLocation()"))
    }

    @Test func aDependencyCapturedByAScheduledBindingIsAssertedTooButOthersAreNot() {
        // `addTask`'s closure is `sending`, so what a scheduled binding reads out of a cell crosses the
        // boundary with it. A binding only ever read by a binding built on the parent does not, and
        // asserting it would reject graphs that compile — which is the whole reason the requirement is
        // per binding rather than per graph.
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [
                singleton("Config"),
                singleton("Counter"),
                singleton("Pool", dependencies: [(name: "config", type: "Config")], initIsAsync: true),
                singleton("Cache", initIsAsync: true),
                singleton("Service", dependencies: [(name: "counter", type: "Counter")]),
            ]
        )
        #expect(output.contains("_check((Config).self)"))
        #expect(output.contains("_check((Pool).self)"))
        #expect(!output.contains("_check((Counter).self)"))
        #expect(!output.contains("_check((Service).self)"))
    }

    @Test func theTaskResultMarkerCarriesOnlyTheScheduledBindings() {
        // One case per suspension. A sync binding never returns from a child task, so putting it in the
        // marker would impose `Sendable` on it for nothing.
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: independentAsyncPair() + [
                singleton("Service", dependencies: [(name: "pool", type: "Pool")])
            ]
        )
        #expect(output.contains("    case pool(Pool)"))
        #expect(output.contains("    case cache(Cache)"))
        #expect(!output.contains("    case service(Service)"))
    }
}
