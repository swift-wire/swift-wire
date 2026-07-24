import Testing

@testable import WireGenCore

/// H2.2a gate (emission level) — the doubles-threaded contributor-proxy facade. A shipped variant emits
/// only a seed-scope *facade* returning a scope struct, losing the teardown + per-root pruning an HTTP
/// adapter reaches request scope through in production (the M5.4 proxy's `_wireEnterScope` thunk). This
/// suite drives `renderContributorProxyFacade` over a doubles-threaded variant proxy and asserts the facade
/// (a) threads the doubles into the `_wireEnterScope` thunk and sources a `@BindType`d binding from
/// `doubles.<field>`, (b) prunes to the routed subject's reachable subgraph (a sibling subject sharing the
/// seed is not constructed), (c) tears down the scope's own reachable `@Teardown` bindings, and (d) returns
/// the constructed variant proxy. The complementary runtime proof (init-time mock over a real proxy) lives
/// in `IntegrationTests/BindTypeProxyContributor…`.
@Suite("ContributorProxyFacadeEmission")
struct ContributorProxyFacadeEmissionTests {
    private func doublesSourced(_ boundType: String, field: String, seed: String) -> DiscoveredBinding {
        .provider(
            DiscoveredProvider(
                boundType: boundType,
                accessPath: "doubles.\(field)",
                form: .property,
                dependencies: [],
                genericParameterNames: [],
                location: mockLocation("<doubles>"),
                scopeKey: ScopeKey(seed: seed),
                originModule: testModule
            )
        )
    }

    private func syntheticSeed(_ seed: String, accessPath: String) -> DiscoveredBinding {
        .provider(
            DiscoveredProvider(
                boundType: seed,
                accessPath: accessPath,
                form: .property,
                dependencies: [],
                genericParameterNames: [],
                location: mockLocation("<synthetic>"),
                originModule: testModule
            )
        )
    }

    private func scoped(
        _ name: String,
        seed: String,
        dependencies: [(name: String?, type: String)],
        teardown: TeardownAction? = nil
    ) -> DiscoveredBinding {
        .scopeBound(
            DiscoveredScopeBoundType(
                typeName: name,
                typeKind: "struct",
                genericParameterNames: [],
                dependencies: dependencies.map {
                    DependencyParameter(name: $0.name, type: $0.type, kind: .injectInitParameter, location: mockLocation("\(name).swift"))
                },
                location: mockLocation("\(name).swift"),
                scopeKey: ScopeKey(seed: seed),
                teardown: teardown,
                originModule: testModule
            )
        )
    }

    @Test func facadeThreadsDoublesPrunesAndTearsDown() {
        let doublesType = "_MyTests_bindMockDoubles"
        let seed = "RequestSeed"

        // The routed subject injects the seed, a scoped resource (with a `@Teardown`), and the `@BindType`d
        // repository (doubles-sourced). A sibling subject shares the seed but is unreachable from the routed
        // subject over the resolved edges.
        let subject = DiscoveredScopeBoundType(
            typeName: "AController",
            typeKind: "struct",
            genericParameterNames: [],
            dependencies: [
                DependencyParameter(name: "seed", type: seed, kind: .injectInitParameter, location: mockLocation("A.swift")),
                DependencyParameter(name: "resource", type: "AResource", kind: .injectInitParameter, location: mockLocation("A.swift")),
                DependencyParameter(name: "repo", type: "BackendRepository", kind: .injectInitParameter, location: mockLocation("A.swift")),
            ],
            location: mockLocation("A.swift"),
            scopeKey: ScopeKey(seed: seed),
            originModule: testModule
        )
        let proxy = contributorProxyBinding(
            for: subject,
            key: "WireMVCKeys.routeContributors",
            prefix: "_MyTests_bindMock_WireRouteContributor_",
            proxyScope: .singleton,
            doubles: doublesType
        )

        let seedBinding = syntheticSeed(seed, accessPath: "requestSeed")
        let repo = doublesSourced("BackendRepository", field: "backendRepository", seed: seed)
        let close = TeardownAction(
            kind: .member(methodName: "close", isAsync: true, isThrowing: false),
            location: mockLocation("AResource.swift")
        )
        let resource = scoped("AResource", seed: seed, dependencies: [(name: "seed", type: seed)], teardown: close)
        let sibling = scoped(
            "BController",
            seed: seed,
            dependencies: [(name: "seed", type: seed), (name: "repo", type: "BackendRepository")]
        )
        let controller = scoped(
            "AController",
            seed: seed,
            dependencies: [(name: "seed", type: seed), (name: "resource", type: "AResource"), (name: "repo", type: "BackendRepository")]
        )
        let scope = SeedScopeEmission(
            seedTypeExpression: seed,
            identifierSuffix: "MyTests_bindMock_RequestSeed",
            parentGraphType: "_WireGraph",
            topologicalOrder: [seedBinding, repo, resource, sibling, controller],
            borrowedBindingPropertyNames: [],
            edges: [
                controller.identity: [seedBinding.identity, resource.identity, repo.identity],
                resource.identity: [seedBinding.identity],
                sibling.identity: [seedBinding.identity, repo.identity],
            ],
            doublesType: doublesType
        )

        let facade = renderContributorProxyFacade(
            proxy: proxy,
            scope: scope,
            parentGraphTypeReference: "_WireGraph",
            facadeMethodName: "bootstrapMyTests_bindMock_AControllerContributor"
        )

        // (a) The facade is a non-async/throws `Wire` static method borrowing the reused graph, returning the
        // variant proxy — the consumer builds the proxy once, then enters per request.
        #expect(
            facade.contains(
                "extension Wire {\n    static func bootstrapMyTests_bindMock_AControllerContributor(wireGraph _wireGraph: _WireGraph) -> _MyTests_bindMock_WireRouteContributor_AController {"
            )
        )
        // (a) The `_wireEnterScope` thunk threads the doubles, and the `@BindType`d binding reads its double.
        #expect(facade.contains("doubles: \(doublesType)) async throws in"))
        #expect(facade.contains("let backendRepository = doubles.backendRepository"))
        // The routed subject and its reachable resource construct, wired to the double.
        #expect(facade.contains("let aResource = AResource(seed: requestSeed)"))
        #expect(facade.contains("let aController = AController(seed: requestSeed, resource: aResource, repo: backendRepository)"))
        // (b) Pruning — the sibling sharing the seed is unreachable from the routed subject, so it is not
        // constructed by this entry.
        #expect(!facade.contains("BController("))
        // (c) Teardown — the scope's own reachable `@Teardown` binding is torn down; the thunk returns it.
        #expect(facade.contains("let _wireScopeTeardown: @Sendable () async -> [any Error] = {"))
        #expect(facade.contains("await aResource.close()"))
        #expect(facade.contains("return (aController, _wireScopeTeardown)"))
        // (d) The facade returns the constructed variant proxy, entered with `_wireEnterScope(seed, doubles:)`.
        #expect(facade.contains("return _MyTests_bindMock_WireRouteContributor_AController(_wireEnterScope:"))
    }
}
