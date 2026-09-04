import Testing

@testable import WireGenCore

/// home-module pruning's migration diagnostic. Pruning the home module is the milestone's one behaviour change, and
/// this is the only place a developer can see it happen — a binding read solely through `graph.x` is gone,
/// and without a message the first sign would be a "has no member" error at the use site.
@Suite("Pruned binding diagnostics")
struct PrunedBindingDiagnosticsTests {
    private func singleton(
        _ name: String,
        access: AccessLevel = .internal,
        teardown: Bool = false,
        key: String? = nil,
        module: String = testModule
    ) -> DiscoveredBinding {
        .scopeBound(
            DiscoveredScopeBoundType(
                typeName: name,
                typeKind: "struct",
                genericParameterNames: [],
                dependencies: [],
                location: mockLocation("\(name).swift"),
                accessLevel: access,
                teardown: teardown
                    ? TeardownAction(
                        kind: .member(methodName: "shutdown", isAsync: false, isThrowing: false),
                        location: mockLocation("\(name).swift")
                    )
                    : nil,
                originModule: module
            )
        )
    }

    private func root(_ name: String, deps: [String]) -> DiscoveredBinding {
        consumer(name, deps: deps, allowUnused: true)
    }

    private func consumer(
        _ name: String,
        deps: [String],
        allowUnused: Bool = false
    ) -> DiscoveredBinding {
        .scopeBound(
            DiscoveredScopeBoundType(
                typeName: name,
                typeKind: "struct",
                genericParameterNames: [],
                dependencies: deps.map {
                    DependencyParameter(
                        name: "d",
                        type: $0,
                        kind: .injectInitParameter,
                        location: mockLocation("\(name).swift")
                    )
                },
                location: mockLocation("\(name).swift"),
                allowUnused: allowUnused,
                originModule: testModule
            )
        )
    }

    private func contributor(
        _ name: String,
        access: AccessLevel,
        to keyReference: String
    ) -> DiscoveredBinding {
        .scopeBound(
            DiscoveredScopeBoundType(
                typeName: name,
                typeKind: "struct",
                genericParameterNames: [],
                dependencies: [],
                location: mockLocation("\(name).swift"),
                accessLevel: access,
                contributions: [Contribution(keyReference: keyReference, location: mockLocation("\(name).swift"))],
                originModule: testModule
            )
        )
    }

    private func messages(_ pruned: [DiscoveredBinding]) -> [String] {
        prunedBindingDiagnostics(pruned, externalModules: [libraryModule]).map(\.message)
    }

    @Test("An internal home binding that was pruned is reported, with the fix-it")
    func internalPrunedIsReported() {
        let message = try? #require(messages([singleton("UserStore")]).first)
        #expect(message?.contains("'UserStore' is declared but nothing reachable") == true)
        #expect(message?.contains("'allowUnused: true'") == true)
        // The fix-it names the property the developer would have read, so the message matches the code
        // they are looking at.
        #expect(message?.contains("graph.userStore") == true)
    }

    @Test("Every visibility is reported — a pruned `public` binding is not a downstream question")
    func visibilityDoesNotGateTheReport() {
        // The dead-binding gate stays silent on `public` because Wire cannot see every consumer of a
        // public declaration. Here it can: the only thing that constructs a binding is this graph, and
        // `_WireGraph` is `internal` to its module, so no downstream consumer can be the reason a public
        // binding went missing. Silence would buy a "has no member" error instead of a message.
        for access in [AccessLevel.internal, .package, .public, .open] {
            #expect(messages([singleton("A", access: access)]).count == 1, "\(access) should be reported")
        }
    }

    @Test("A dependency-module binding is never reported")
    func libraryPrunedIsSilent() {
        // A library binding a consumer does not reach is the milestone working, not a problem to fix —
        // and the consumer could not act on the message anyway.
        #expect(messages([singleton("LibraryBinding", module: libraryModule)]).isEmpty)
    }

    @Test("A pruned `@Teardown` binding says so")
    func teardownIsNamed() {
        // The intent least visible in the code and most surprising to lose: a resource nothing reaches is
        // never constructed, so it is never torn down either.
        let message = try? #require(messages([singleton("Client", teardown: true)]).first)
        #expect(message?.contains("which declares a '@Teardown'") == true)
    }

    @Test("A synthesised aggregate is not reported — the multibinding diagnostics speak for it")
    func aggregateIsSilent() {
        let aggregate = DiscoveredBinding.aggregate(
            DiscoveredAggregate(
                keyReference: "App.routes",
                collectionType: "[any Route]",
                flavour: .collected,
                contributors: [],
                location: mockLocation("Keys.swift"),
                originModule: testModule
            )
        )
        #expect(messages([aggregate]).isEmpty)
    }

    @Test("A binding reachability judged is not judged again by the dead-binding pass")
    func reachabilitySupersedesTheDeadBindingWarning() {
        // The diagnostic fold. A pruned binding is reported here in terms that say more, and a *retained* one is
        // live because a root reaches it — so neither is re-judged by the first-order check. What that
        // check still covers is what reachability did not decide: seed-scope partitions.
        let binding = singleton("UserStore")
        #expect(
            deadBindingDiagnostics(
                across: [.default: [binding]],
                judgedByReachability: [binding.identity]
            ).isEmpty
        )
        // Unjudged — a seed-scope partition — and the first-order check still speaks for it.
        #expect(deadBindingDiagnostics(across: [.default: [binding]]).count == 1)
    }

    // MARK: - The fixed point (the diagnostic fold)

    /// A graph built the way WireGen builds the default one, with `root` as the only declared root.
    private func prunedDiagnostics(
        _ bindings: [DiscoveredBinding],
        keys: [DiscoveredMultibindingKey] = []
    ) -> [String] {
        let result = buildDependencyGraph(
            from: bindings,
            multibindingKeys: keys,
            homeModule: testModule,
            externalModules: [],
            reachabilityPolicy: .prune(conformances: [], borrowedByScopes: [])
        )
        return prunedBindingDiagnostics(result.pruned, externalModules: []).map(\.message)
    }

    @Test("A binding consumed solely by another dead binding is reported — the case only a fixed point catches")
    func transitivelyDeadBindingIsReported() {
        // `DeadBindingDiagnostics.swift` recorded this as its limitation: first-order analysis sees `Deep`
        // as live, because `Dead` consumes it. Reachability sees that nothing reaches `Dead` either, so
        // both go — the fixed point arrives by construction rather than as a separate feature.
        let messages = prunedDiagnostics([
            root("Root", deps: ["Used"]),
            singleton("Used"),
            consumer("Dead", deps: ["Deep"]),
            singleton("Deep"),
        ])
        #expect(messages.contains { $0.contains("'Dead'") })
        #expect(messages.contains { $0.contains("'Deep'") })
        #expect(!messages.contains { $0.contains("'Used'") })
    }

    @Test("A package-local contributor to an unconsumed public aggregate is reported; the aggregate is not")
    func packageLocalContributorToUnconsumedPublicKeyIsReported() {
        // The subtlety worth pinning. The aggregate stays silent — a public key is permissively
        // public and its own liveness diagnostic speaks for it — while the contributor folded into it is
        // genuinely dead and says so.
        let messages = prunedDiagnostics(
            [
                root("Root", deps: ["Used"]),
                singleton("Used"),
                contributor("PackageLocalContributor", access: .package, to: "Keys.widgets"),
            ],
            keys: [
                DiscoveredMultibindingKey(
                    keyReference: "Keys.widgets",
                    flavour: .collected,
                    typeArguments: ["any Widget"],
                    location: mockLocation("Keys.swift"),
                    accessLevel: .public,
                    originModule: testModule
                )
            ]
        )
        #expect(messages.count == 1)
        #expect(messages[0].contains("'PackageLocalContributor'"))
    }
}
