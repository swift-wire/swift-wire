import Testing

@testable import WireGenCore

/// M7c.4 — which bindings a graph schedules, and the shape the scheduled emission produces.
///
/// Two predicates decide everything here and the negative cases matter at least as much as the positive
/// ones. **Between graphs:** a graph is scheduled only if two of its async bindings can be in flight at
/// once. **Within one:** only the region that can overlap is scheduled — a serial prefix and a serial
/// suffix stay the linear `let` chain, which is what holds the machinery to four bindings on a
/// hundred-and-ten-binding graph, and what makes the constructs M7c.4 has not translated a question about
/// the *group region* rather than about the graph.
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

    /// One graph exercising all three regions and the seam between them:
    ///
    /// - `Config` — sync, upstream of `Pool`: **prefix**, and on the **frontier**, because a scheduled
    ///   binding reads it;
    /// - `Pool`, `Cache` — independent async: **Overlap**, so both are scheduled;
    /// - `Service` — waits on `Pool` only, so it can be built while `Cache` is still in flight: **group**;
    /// - `Host` — waits on both, so nothing is outstanding by the time it can start: **suffix**.
    private func threeRegionGraph() -> [DiscoveredBinding] {
        [
            singleton("Config"),
            singleton("Pool", dependencies: [(name: "config", type: "Config")], initIsAsync: true),
            singleton("Cache", initIsAsync: true),
            singleton("Service", dependencies: [(name: "pool", type: "Pool")]),
            singleton(
                "Host",
                dependencies: [(name: "service", type: "Service"), (name: "cache", type: "Cache")]
            ),
        ]
    }

    // MARK: - Whether a graph is scheduled at all

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
        // sequential chain plus machinery, and the `Sendable` requirement for nothing.
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

    @Test func twoIndependentAsyncBindingsAreScheduled() {
        let output = renderWireGraph(imports: [], topologicalOrder: independentAsyncPair())
        #expect(output.contains("private struct _WireBuilding: ~Copyable {"))
        #expect(output.contains("var _wireState_pool: _WireBindingState<Pool> = .unmarked"))
        #expect(output.contains("_wireGroup.addTask { .pool(await Pool()) }"))
        #expect(!output.contains("let pool = await Pool()"))
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

    // MARK: - How much of a graph is scheduled

    @Test func aBindingUpstreamOfEveryAsyncOneStaysOnTheChain() {
        // The prefix. `Config` has no Overlap ancestor, so it is built before the group opens and costs
        // no cell — the whole point of scoping the scheduler to a region.
        let output = renderWireGraph(imports: [], topologicalOrder: threeRegionGraph())
        #expect(output.contains("    let config = Config()"))
        #expect(!output.contains("_wireState_config"))
        let chainLine = output.firstRange(of: "    let config = Config()")!
        let groupLine = output.firstRange(of: "return try await withThrowingTaskGroup")!
        #expect(chainLine.lowerBound < groupLine.lowerBound)
    }

    @Test func aBindingWaitingOnOnlySomeAsyncBindingsIsScheduled() {
        // The group's real population beyond Overlap itself: `Service` waits on `Pool` but not on
        // `Cache`, so it can be constructed while `Cache` is still in flight — which is the whole
        // latency claim, and it only holds if `Service` is in the cascade.
        let output = renderWireGraph(imports: [], topologicalOrder: threeRegionGraph())
        #expect(output.contains("var _wireState_service: _WireBindingState<Service> = .unmarked"))
        #expect(output.contains("guard let pool = _wireState_pool.value() else { return }"))
        #expect(output.contains("            try _wireAdd_service(&_wireGroup)"))
    }

    @Test func aBindingWaitingOnEveryAsyncOneReturnsToTheChain() {
        // The suffix. `Host` waits on both, so nothing is still outstanding when it can start and a cell
        // would buy it nothing. It is emitted after the seam, as a plain `let` over locals.
        let output = renderWireGraph(imports: [], topologicalOrder: threeRegionGraph())
        #expect(output.contains("        let host = Host(service: service, cache: cache)"))
        #expect(!output.contains("_wireState_host"))
        let seam = output.firstRange(of: "let cache = building._wireState_cache.take()")!
        let host = output.firstRange(of: "let host = Host(service: service, cache: cache)")!
        #expect(seam.lowerBound < host.lowerBound)
    }

    @Test func aPrefixBindingAScheduledOneReadsCrossesAsAStoredProperty() {
        // The seam, inbound. The building struct's methods cannot see the bootstrap's locals, so a
        // frontier value is handed over at the initialiser — as a `let`, not a cell: it is already
        // constructed, and a cell would add a transition that can never fail.
        let output = renderWireGraph(imports: [], topologicalOrder: threeRegionGraph())
        #expect(output.contains("    let config: Config"))
        #expect(output.contains("var building = _WireBuilding(config: config)"))
        // Copied to a local before the construction, because naming it inside `addTask`'s escaping
        // closure would capture `self`, which is `inout` in a mutating method.
        #expect(output.contains("        let config = self.config"))
        // And it is not guarded: a frontier value is resolved before the struct exists.
        #expect(!output.contains("_wireState_config.value()"))
    }

    // MARK: - The exclusions, scoped to the group region

    @Test func aTeardownBindingNoLongerBlocksScheduling() {
        // Gone rather than narrowed: the teardown closure is built at the end of the bootstrap over each
        // binding's concrete local, and after the seam every scheduled binding is a local again.
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
        #expect(output.contains("_WireBindingState"))
        #expect(output.contains("let pool = building._wireState_pool.take()"))
        #expect(output.contains("await pool.close()"))
    }

    @Test func aMemberInjectionNoLongerBlocksScheduling() {
        // Also gone, and it could not have been region-scoped anyway: injection parameters are
        // deliberately not construction edges, so an injection reads across regions in either direction
        // and has to stay where it is — a block after everything is constructed.
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
        #expect(output.contains("_WireBindingState"))
        #expect(output.contains("        hub.spoke = spoke"))
    }

    @Test func aBuilderFoldInThePrefixDoesNotBlockScheduling() {
        // The region change stated as a test. The fold is emitted by the linear chain exactly as it
        // always was, so it is not the scheduler's business.
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [
                builderAggregate("Keys.routes", element: "any Route", contributors: ["AlphaRoute"]),
                singleton("AlphaRoute"),
                singleton("Pool", initIsAsync: true),
                singleton("Cache", initIsAsync: true),
            ]
        )
        #expect(output.contains("_WireBindingState"))
        #expect(output.contains("    func _wireFoldKeysRoutes() -> [any Route] {"))
    }

    @Test func aBuilderFoldInTheGroupRegionStillBlocksScheduling() {
        // A builder aggregate emits a `@resultBuilder`-annotated local function rather than a single
        // expression, so there is nothing to hand `asResolved`. Downstream of an async contributor, it
        // lands in the region and the whole graph stays on the chain.
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [
                singleton("AlphaRoute", initIsAsync: true),
                builderAggregate("Keys.routes", element: "any Route", contributors: ["AlphaRoute"]),
                singleton("Cache", initIsAsync: true),
            ]
        )
        #expect(!output.contains("_WireBindingState"))
    }

    @Test func aCollectedAggregateInTheGroupRegionIsScheduled() {
        // The flavour that was never excluded, asserted because it is the case most likely to arise: an
        // aggregate folding async contributors is a single expression, so it takes the `asResolved` form
        // and fires from whichever contributor lands last.
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [
                singleton("AlphaProbe", initIsAsync: true),
                singleton("BetaProbe", initIsAsync: true),
                // A third, independent async binding the aggregate does not consume, so the fold can run
                // while that one is still in flight and the aggregate is a *group* binding rather than a
                // suffix one.
                singleton("Spare", initIsAsync: true),
                collectedAggregate("Keys.probes", element: "any Probe", contributors: ["AlphaProbe", "BetaProbe"]),
            ]
        )
        #expect(
            output.contains(
                "guard let alphaProbe = _wireState_alphaProbe.value(), "
                    + "let betaProbe = _wireState_betaProbe.value() else { return }"
            )
        )
        #expect(output.contains(".asResolved([alphaProbe, betaProbe] as [any Probe])"))
    }

    @Test func anOpaqueLiftInTheGroupRegionBlocksScheduling() {
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

    @Test func anExistentialPromotionInTheGroupRegionBlocksScheduling() {
        // Tested on either endpoint: the alias is a second definition site bound after the producer's
        // construction, and a scheduled producer has no construction line to hang it off.
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

    // MARK: - The cascade

    @Test func aDependentIsFiredFromEveryDependencyAndGuardedUntilAllResolve() {
        // The structure the whole design rests on. `Service` is fired by both of its scheduled
        // dependencies, and its dependency check precedes the pending transition so that whichever
        // resolves last constructs it — claiming the cell first would strand it. `Spare` keeps `Service`
        // out of the suffix by giving Overlap a third member it does not wait on.
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: independentAsyncPair() + [
                singleton("Spare", initIsAsync: true),
                singleton("Service", dependencies: [(name: "pool", type: "Pool"), (name: "cache", type: "Cache")]),
            ]
        )
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
        let output = renderWireGraph(imports: [], topologicalOrder: threeRegionGraph())
        #expect(output.contains("case .pool(let _wireValue):"))
        #expect(output.contains("            _wireState_pool.asResolved(_wireValue)"))
        #expect(output.contains("            try _wireAdd_service(&_wireGroup)"))
    }

    @Test func onlyReadyBindingsAreDrivenFromTheBootstrap() {
        // Driving from the ready bindings is what makes the cascade load-bearing rather than decorative:
        // walked in the group's own order, every `add` would already find its dependencies resolved.
        // "Ready" counts *group* dependencies only — `Pool` reads `Config` across the seam and is still
        // started immediately, because a frontier value is resolved before the struct exists.
        let output = renderWireGraph(imports: [], topologicalOrder: threeRegionGraph())
        #expect(output.contains("        try building._wireAdd_pool(&_wireGroup)"))
        #expect(output.contains("        try building._wireAdd_cache(&_wireGroup)"))
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

    @Test func theSeamTurnsEveryScheduledBindingBackIntoALocal() {
        // What keeps M7c.4 small. After the drain the suffix chain, the injection block, the teardown
        // closure and the memberwise init are all standing on locals — the ground each was written
        // against — so none of them has to know a scheduler exists.
        let output = renderWireGraph(imports: [], topologicalOrder: independentAsyncPair())
        #expect(output.contains("        let pool = building._wireState_pool.take()"))
        #expect(output.contains("        let cache = building._wireState_cache.take()"))
        #expect(output.contains("        return _WireGraph(pool: pool, cache: cache)"))
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

    @Test func aFrontierValueCapturedByAScheduledBindingIsAssertedTooButOthersAreNot() {
        // `addTask`'s closure is `sending`, so a prefix value a scheduled binding captures crosses the
        // boundary with it and is asserted even though it is not itself scheduled. A binding only ever
        // read on the parent does not cross, and asserting it would reject graphs that compile.
        let output = renderWireGraph(imports: [], topologicalOrder: threeRegionGraph())
        #expect(output.contains("_check((Config).self)"))
        #expect(output.contains("_check((Pool).self)"))
        #expect(output.contains("_check((Cache).self)"))
        #expect(!output.contains("_check((Service).self)"))
        #expect(!output.contains("_check((Host).self)"))
    }

    @Test func theTaskResultMarkerCarriesOnlyTheScheduledBindingsThatSuspend() {
        // One case per suspension inside the region. A sync binding never returns from a child task, and
        // neither does a prefix or suffix one, so putting either in the marker would impose `Sendable`
        // for nothing.
        let output = renderWireGraph(imports: [], topologicalOrder: threeRegionGraph())
        #expect(output.contains("    case pool(Pool)"))
        #expect(output.contains("    case cache(Cache)"))
        #expect(!output.contains("    case service(Service)"))
        #expect(!output.contains("    case config(Config)"))
        #expect(!output.contains("    case host(Host)"))
    }

    // MARK: - Aggregate helpers

    private func aggregate(
        _ keyReference: String,
        element: String,
        contributors: [String],
        flavour: MultibindingKeyFlavour,
        builderTypeName: String? = nil
    ) -> DiscoveredBinding {
        .aggregate(
            DiscoveredAggregate(
                keyReference: keyReference,
                collectionType: "[\(element)]",
                flavour: flavour,
                builderTypeName: builderTypeName,
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

    private func collectedAggregate(
        _ keyReference: String,
        element: String,
        contributors: [String]
    ) -> DiscoveredBinding {
        aggregate(keyReference, element: element, contributors: contributors, flavour: .collected)
    }

    private func builderAggregate(
        _ keyReference: String,
        element: String,
        contributors: [String]
    ) -> DiscoveredBinding {
        aggregate(
            keyReference,
            element: element,
            contributors: contributors,
            flavour: .builder,
            builderTypeName: "RouteBuilder"
        )
    }
}
