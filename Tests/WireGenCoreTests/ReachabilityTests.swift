// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Testing

@testable import WireGenCore

/// Reachability pruning. Two halves, and they fail in different ways: a wrong **root set** silently drops
/// a binding the app pulls out some way Wire cannot see, while a wrong **edge set** drops one the graph
/// itself constructs.
///
/// The fixtures are split home/library on purpose, because that split *is* the first cut of pruning: every home-module
/// binding is retained (and is a retention root, so its dependencies come with it), while a
/// dependency-module binding survives only if something reaches it. A test that used home bindings
/// throughout would pass no matter what the walk did.
///
/// See `Documentation/Notes/MultiModuleComposition.md` § "Reachability roots (the roots model)".
@Suite("Reachability")
struct ReachabilityTests {
    // MARK: - Fixtures

    private func singleton(
        _ name: String,
        deps: [String] = [],
        keyedDeps: [(type: String, key: String)] = [],
        memberDeps: [String] = [],
        allowUnused: Bool = false,
        teardown: Bool = false,
        contributesTo keyReference: String? = nil,
        module: String = testModule,
        genericParameterNames: [String] = []
    ) -> DiscoveredBinding {
        .scopeBound(
            DiscoveredScopeBoundType(
                typeName: name,
                typeKind: "struct",
                genericParameterNames: genericParameterNames,
                dependencies: deps.map {
                    DependencyParameter(
                        name: "d",
                        type: $0,
                        kind: .injectInitParameter,
                        location: mockLocation("\(name).swift")
                    )
                }
                    + keyedDeps.map {
                        DependencyParameter(
                            name: "k",
                            type: $0.type,
                            kind: .injectInitParameter,
                            location: mockLocation("\(name).swift"),
                            keyIdentifier: $0.key
                        )
                    },
                location: mockLocation("\(name).swift"),
                memberInjections: memberDeps.isEmpty
                    ? []
                    : [
                        MemberInjection(
                            shape: .methodCall(methodName: "inject"),
                            parameters: memberDeps.map {
                                DependencyParameter(
                                    name: "m",
                                    type: $0,
                                    kind: .injectMethodParameter,
                                    location: mockLocation("\(name).swift")
                                )
                            },
                            location: mockLocation("\(name).swift")
                        )
                    ],
                contributions: keyReference.map {
                    [Contribution(keyReference: $0, location: mockLocation("\(name).swift"))]
                } ?? [],
                allowUnused: allowUnused,
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

    /// A bridging contributor proxy: it depends on a scope-entry *thunk*, whose identity is a function
    /// type matching no producer, so the subject and yields hang off no ordinary edge.
    private func bridgeProxy(
        _ name: String,
        seed: String,
        subject: String,
        yields: [String] = []
    ) -> DiscoveredBinding {
        .scopeBound(
            DiscoveredScopeBoundType(
                typeName: name,
                typeKind: "struct",
                genericParameterNames: [],
                dependencies: [
                    DependencyParameter(
                        name: "_wireEnterScope_\(subject)",
                        type: "@Sendable (\(seed)) async throws -> \(subject)",
                        kind: .scopeEntryThunk,
                        location: mockLocation("\(name).swift"),
                        scopeEntry: scopeEntryDescriptor(seed: seed, subject: subject, yields: yields)
                    )
                ],
                location: mockLocation("\(name).swift"),
                allowUnused: true,
                originModule: testModule
            )
        )
    }

    /// A generic `@Provides func makeRepository<T>(table: T) -> Repository<T>` — the specialisation
    /// route, since a generic `@Singleton` that is not a lift node is an error rather than a template.
    private func genericRepositoryProvider(module: String = libraryModule) -> DiscoveredBinding {
        .provider(
            DiscoveredProvider(
                boundType: "Repository<T>",
                accessPath: "makeRepository",
                form: .function,
                dependencies: [
                    DependencyParameter(
                        name: "table",
                        type: "T",
                        kind: .providerFunctionParameter,
                        location: mockLocation("Repository.swift")
                    )
                ],
                genericParameterNames: ["T"],
                location: mockLocation("Repository.swift"),
                originModule: module
            )
        )
    }

    /// The same fixture, in a dependency module — the half the first cut of pruning is allowed to prune.
    private func library(
        _ name: String,
        deps: [String] = [],
        keyedDeps: [(type: String, key: String)] = [],
        memberDeps: [String] = [],
        allowUnused: Bool = false,
        teardown: Bool = false,
        contributesTo keyReference: String? = nil
    ) -> DiscoveredBinding {
        singleton(
            name,
            deps: deps,
            keyedDeps: keyedDeps,
            memberDeps: memberDeps,
            allowUnused: allowUnused,
            teardown: teardown,
            contributesTo: keyReference,
            module: libraryModule
        )
    }

    private func collectedKey(
        _ reference: String,
        element: String,
        access: AccessLevel,
        allowUnused: Bool = false,
        module: String = testModule
    ) -> DiscoveredMultibindingKey {
        DiscoveredMultibindingKey(
            keyReference: reference,
            flavour: .collected,
            typeArguments: [element],
            location: mockLocation("Keys.swift"),
            accessLevel: access,
            allowUnused: allowUnused,
            originModule: module
        )
    }

    private func conformance(_ protocolName: String, member: String, key: String) -> DiscoveredGraphConformance {
        DiscoveredGraphConformance(
            protocolName: protocolName,
            members: [DiscoveredGraphConformance.Member(name: member, keyReference: key)],
            location: mockLocation("Conformance.swift"),
            originModule: testModule
        )
    }

    /// The reachable set for a graph built from `bindings`, as bare type names, so assertions read as the
    /// developer would describe them.
    private func graph(
        _ bindings: [DiscoveredBinding],
        keys: [DiscoveredMultibindingKey] = [],
        conformances: [DiscoveredGraphConformance] = [],
        borrowedByScopes: Set<BindingIdentity> = []
    ) -> GraphResult {
        buildDependencyGraph(
            from: bindings,
            multibindingKeys: keys,
            homeModule: testModule,
            externalModules: [libraryModule],
            reachabilityPolicy: .prune(
                conformances: conformances,
                borrowedByScopes: borrowedByScopes
            )
        )
    }

    /// The retained set, as bare type names, so assertions read as the developer would describe them.
    private func reachableNames(
        _ bindings: [DiscoveredBinding],
        keys: [DiscoveredMultibindingKey] = [],
        conformances: [DiscoveredGraphConformance] = [],
        borrowedByScopes: Set<BindingIdentity> = []
    ) -> Set<String> {
        Set(
            (graph(bindings, keys: keys, conformances: conformances, borrowedByScopes: borrowedByScopes)
                .reachable ?? []).map(\.base)
        )
    }

    /// What the graph actually emits — the restriction's real output, and the thing codegen walks.
    private func emittedNames(
        _ bindings: [DiscoveredBinding],
        keys: [DiscoveredMultibindingKey] = [],
        conformances: [DiscoveredGraphConformance] = []
    ) -> Set<String> {
        Set((graph(bindings, keys: keys, conformances: conformances).outcome.topologicalOrder ?? []).map(\.boundType))
    }

    // MARK: - The walk

    @Test("A diamond is walked once, and everything under the root survives")
    func diamond() {
        let names = reachableNames([
            singleton("Root", deps: ["Left", "Right"], allowUnused: true),
            library("Left", deps: ["Shared"]),
            library("Right", deps: ["Shared"]),
            library("Shared"),
            library("Orphan"),
        ])
        #expect(names == ["Root", "Left", "Right", "Shared"])
    }

    @Test("A cycle among unreachable bindings is not reached — and does not hang the walk")
    func unreachableCycle() {
        let names = reachableNames([
            singleton("Root", allowUnused: true),
            library("A", deps: ["B"]),
            library("B", deps: ["A"]),
        ])
        #expect(names == ["Root"])
    }

    @Test("A cycle inside the reachable set terminates, keeping both nodes")
    func reachableCycle() {
        let names = reachableNames([
            singleton("Root", deps: ["A"], allowUnused: true),
            library("A", deps: ["B"]),
            library("B", deps: ["A"]),
        ])
        #expect(names == ["Root", "A", "B"])
    }

    @Test("A concrete producer reached only through generic specialisation stays reachable")
    func reachedAfterSpecialisation() {
        // `Root` injects `Repository<ConcreteTable>`; the generic template specialises, and the
        // specialised binding's substituted dependency is what reaches `ConcreteTable`. The walk runs
        // after specialisation, so the substituted edge is the one it sees.
        let names = reachableNames([
            singleton("Root", deps: ["Repository<ConcreteTable>"], allowUnused: true),
            genericRepositoryProvider(),
            library("ConcreteTable"),
            library("UnusedTable"),
        ])
        #expect(names == ["Root", "Repository<ConcreteTable>", "ConcreteTable"])
    }

    // MARK: - The edges the sort does not carry

    @Test("A binding consumed only by member injection is reachable")
    func memberInjectionOnly() {
        // The sort excludes member-injection parameters so cycles through them stay legal; the value is
        // still constructed and delivered, so the walk must include them or `Late` is pruned.
        let names = reachableNames([
            singleton("Root", memberDeps: ["Late"], allowUnused: true),
            library("Late"),
            library("Unreached"),
        ])
        #expect(names == ["Root", "Late"])
    }

    @Test("A bridging proxy's subject and yields are reachable through its scope-entry thunk")
    func scopeEntryThunkConstructed() {
        // The thunk's own identity is a function type that matches no producer, so `resolveDependencies`
        // forms no edge for it at all — without the widening, both subject and yield look dead.
        let names = reachableNames([
            bridgeProxy("MeControllerProxy", seed: "RequestSeed", subject: "MeController", yields: ["Session"]),
            library("MeController"),
            library("Session"),
            library("Unreached"),
        ])
        #expect(names == ["MeControllerProxy", "MeController", "Session"])
    }

    // MARK: - The roots

    @Test("`@Teardown` does not root a binding — a resource nothing reaches is never constructed")
    func teardownDoesNotRoot() {
        // Teardown is a property of a *constructed* binding, not a reason to construct one. Rooting on
        // the annotation would pin every dependency's `@Teardown` binding into every consumer's graph.
        let names = reachableNames([
            library("Client", deps: ["Config"], teardown: true),
            library("Config"),
        ])
        #expect(names.isEmpty)
    }

    @Test("A reached `@Teardown` binding stays reachable, and so does what it holds")
    func teardownRidesReachability() {
        // The shape `TeardownExample` already uses: the consumer is the declared root, and the resources
        // it holds are torn down because they were constructed for it.
        let names = reachableNames([
            singleton("Consumer", deps: ["Client"], allowUnused: true, teardown: true),
            library("Client", deps: ["Config"], teardown: true),
            library("Config"),
            library("Unrelated"),
        ])
        #expect(names == ["Consumer", "Client", "Config"])
    }

    @Test("An aggregate a graph conformance names is a root, and pulls its contributors in")
    func conformanceNamedAggregateIsARoot() {
        // The failure this guards is silent: a conformance member whose key has no aggregate falls back
        // to an empty accessor, so pruning this yields a graph that compiles and serves nothing.
        let names = reachableNames(
            [
                library("LibraryRoute", contributesTo: "App.routes"),
                library("Unrelated"),
            ],
            keys: [collectedKey("App.routes", element: "any Route", access: .internal)],
            conformances: [conformance("Composable", member: "routes", key: "App.routes")]
        )
        #expect(names.contains("LibraryRoute"))
        #expect(!names.contains("Unrelated"))
    }

    @Test("A key's visibility does not root its aggregate — nothing outside the graph can read one")
    func keyVisibilityDoesNotRoot() {
        // `_WireGraph` is `internal`, so an aggregate's product has no downstream reader for `public` to
        // be protecting. Visibility gates diagnostics; consumption gates construction.
        // The key is the library's, so its aggregate is a library binding — the first cut of pruning retains every *home*
        // binding, a synthesised aggregate included, which would otherwise mask what is being tested.
        for access in [AccessLevel.public, .open, .package, .internal] {
            let names = reachableNames(
                [library("Plugin", contributesTo: "Library.plugins")],
                keys: [
                    collectedKey("Library.plugins", element: "any Plugin", access: access, module: libraryModule)
                ]
            )
            #expect(names.isEmpty, "a \(access) key should not root its aggregate")
        }
    }

    @Test("A consumed aggregate keeps its contributors, whatever the key's visibility")
    func consumedAggregateKeepsContributors() {
        let names = reachableNames(
            [
                singleton("App", keyedDeps: [(type: "[any Plugin]", key: "App.plugins")], allowUnused: true),
                library("Plugin", contributesTo: "App.plugins"),
            ],
            keys: [collectedKey("App.plugins", element: "any Plugin", access: .internal)]
        )
        #expect(names.contains("Plugin"))
    }

    @Test("A key marked `allowUnused` in the home package roots its aggregate")
    func allowUnusedKeyIsARoot() {
        let names = reachableNames(
            [library("Plugin", contributesTo: "App.plugins")],
            keys: [collectedKey("App.plugins", element: "any Plugin", access: .internal, allowUnused: true)]
        )
        #expect(names.contains("Plugin"))

        // A library's key cannot pin itself into a consumer's graph, exactly as a library's binding cannot.
        let libraryKeyed = reachableNames(
            [library("Plugin", contributesTo: "Library.plugins")],
            keys: [
                collectedKey(
                    "Library.plugins",
                    element: "any Plugin",
                    access: .public,
                    allowUnused: true,
                    module: libraryModule
                )
            ]
        )
        #expect(libraryKeyed.isEmpty)
    }

    @Test("A library's `allowUnused` is ignored — it cannot pin itself into a consumer's graph")
    func allowUnusedIsHomePackageOnly() {
        let names = reachableNames([
            library("LibraryBinding", deps: ["LibrarySupport"], allowUnused: true),
            library("LibrarySupport"),
        ])
        #expect(names.isEmpty)
    }

    @Test("A library binding is live exactly when a home root reaches it")
    func libraryBindingLiveViaHomeRoot() {
        let names = reachableNames([
            singleton("App", deps: ["UsedLibraryBinding"], allowUnused: true),
            library("UsedLibraryBinding"),
            library("UnusedLibraryBinding"),
        ])
        #expect(names == ["App", "UsedLibraryBinding"])
    }

    // MARK: - Policy

    @Test("A graph asking for no reachability computes none, and prunes nothing")
    func noPolicyComputesNothing() {
        let result = buildDependencyGraph(
            from: [singleton("Root", allowUnused: true), library("Unreached")],
            homeModule: testModule,
            externalModules: [libraryModule]
        )
        #expect(result.reachable == nil)
        #expect(result.outcome.topologicalOrder?.count == 2)
    }

    // MARK: - The restriction (the first cut of pruning)

    @Test("An unreached dependency-module binding is not emitted")
    func unreachedLibraryBindingIsNotEmitted() {
        let emitted = emittedNames([
            singleton("App", deps: ["UsedLibraryBinding"], allowUnused: true),
            library("UsedLibraryBinding"),
            library("UnusedLibraryBinding", deps: ["UnusedLibrarySupport"]),
            library("UnusedLibrarySupport"),
        ])
        #expect(emitted == ["App", "UsedLibraryBinding"])
    }

    @Test("An unreached home binding is pruned too — the home-module pruning behaviour change")
    func unreachedHomeBindingIsPruned() {
        // The first cut of pruning retained the home half wholesale. Home-module pruning does not: a binding the app reaches only through
        // `graph.x` is gone unless it says so, which is the whole reason this ships with a diagnostic.
        let emitted = emittedNames([
            singleton("DeclaredRoot", deps: ["Reached"], allowUnused: true),
            singleton("Reached"),
            singleton("UnreachedHomeBinding"),
        ])
        #expect(emitted == ["DeclaredRoot", "Reached"])
    }

    @Test("A retained binding never points at a pruned one")
    func retentionIsClosedUnderDependencies() {
        // Everything a root reaches comes with it, however deep, or the emitted graph reads a property
        // that was never declared.
        let emitted = emittedNames([
            singleton("DeclaredRoot", deps: ["LibrarySupport"], allowUnused: true),
            library("LibrarySupport", deps: ["DeeperLibrarySupport"]),
            library("DeeperLibrarySupport"),
            library("Unrelated"),
        ])
        #expect(emitted == ["DeclaredRoot", "LibrarySupport", "DeeperLibrarySupport"])
    }

    @Test("A singleton a seed scope borrows is retained, though this graph has no edge to it")
    func scopeBorrowedSingletonIsRetained() {
        // A request-scoped binding's use of an app singleton is an edge in the *scope's* graph. The app
        // graph cannot see it, so WireGen carries the used-borrow set in as a retention root.
        let borrowed = library("BorrowedByRequestScope")
        let emitted = Set(
            (graph(
                [singleton("App", allowUnused: true), borrowed, library("Unrelated")],
                borrowedByScopes: [borrowed.identity]
            ).outcome.topologicalOrder ?? []).map(\.boundType)
        )
        #expect(emitted == ["App", "BorrowedByRequestScope"])
    }

    @Test("A missing dependency inside a pruned binding stops being an error")
    func missingBindingInPrunedSubgraphIsNotAnError() {
        // The enabling case for retiring `_WireExports.swift`: once every direct Wire-dependency's
        // bindings enter the parse set, a library binding whose own dependency lives in a package the
        // consumer never depended on must be a non-event rather than a build failure.
        let result = graph([
            singleton("App", allowUnused: true),
            library("UnreachedLibraryBinding", deps: ["TypeFromAPackageTheConsumerNeverDependedOn"]),
        ])
        #expect(result.outcome.topologicalOrder != nil, "the unreachable binding's missing dep failed the build")
        #expect(Set((result.outcome.topologicalOrder ?? []).map(\.boundType)) == ["App"])
    }

    @Test("A cycle among pruned bindings stops failing the build")
    func cycleInPrunedSubgraphIsNotAnError() {
        let result = graph([
            singleton("App", allowUnused: true),
            library("A", deps: ["B"]),
            library("B", deps: ["A"]),
        ])
        #expect(result.outcome.topologicalOrder != nil, "a cycle nothing constructs failed the build")
    }

    @Test("A missing dependency inside a retained binding is still an error")
    func missingBindingInRetainedSubgraphStillFails() {
        let result = graph([
            singleton("App", deps: ["UsedLibraryBinding"], allowUnused: true),
            library("UsedLibraryBinding", deps: ["GenuinelyMissing"]),
        ])
        #expect(result.outcome.topologicalOrder == nil, "a reachable binding's missing dep must still fail")
    }
}
