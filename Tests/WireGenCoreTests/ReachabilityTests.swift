import Testing

@testable import WireGenCore

/// M7b.1 — the reachability walk, computed but not yet applied. Two halves, and they fail in different
/// ways: a wrong **root set** silently drops a binding the app pulls out some way Wire cannot see, while a
/// wrong **edge set** drops one the graph itself constructs. The edge cases below are the ones the sort's
/// own edges do not carry (member injection, scope-entry thunks) plus the ones the note calls out
/// (diamonds, cycles among unreachable nodes, generic specialisation).
///
/// See `Documentation/Notes/MultiModuleComposition.md` § "Reachability roots (M7b.0)".
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
    private func genericRepositoryProvider() -> DiscoveredBinding {
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
                originModule: testModule
            )
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
    private func reachableNames(
        _ bindings: [DiscoveredBinding],
        keys: [DiscoveredMultibindingKey] = [],
        conformances: [DiscoveredGraphConformance] = [],
        externalModules: Set<String> = []
    ) -> Set<String> {
        let result = buildDependencyGraph(
            from: bindings,
            multibindingKeys: keys,
            homeModule: testModule,
            externalModules: externalModules,
            reachabilityRootPolicy: .appGraph(conformances: conformances)
        )
        let reachable = result.reachable ?? []
        return Set(reachable.map(\.base))
    }

    // MARK: - The walk

    @Test("A diamond is walked once, and everything under the root survives")
    func diamond() {
        let names = reachableNames([
            singleton("Root", deps: ["Left", "Right"], allowUnused: true),
            singleton("Left", deps: ["Shared"]),
            singleton("Right", deps: ["Shared"]),
            singleton("Shared"),
            singleton("Orphan"),
        ])
        #expect(names == ["Root", "Left", "Right", "Shared"])
    }

    @Test("A cycle among unreachable bindings is not reached — and does not hang the walk")
    func unreachableCycle() {
        let names = reachableNames([
            singleton("Root", allowUnused: true),
            singleton("A", deps: ["B"]),
            singleton("B", deps: ["A"]),
        ])
        #expect(names == ["Root"])
    }

    @Test("A cycle inside the reachable set terminates, keeping both nodes")
    func reachableCycle() {
        let names = reachableNames([
            singleton("Root", deps: ["A"], allowUnused: true),
            singleton("A", deps: ["B"]),
            singleton("B", deps: ["A"]),
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
            singleton("ConcreteTable"),
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
            singleton("Late"),
        ])
        #expect(names == ["Root", "Late"])
    }

    @Test("A bridging proxy's subject and yields are reachable through its scope-entry thunk")
    func scopeEntryThunkConstructed() {
        // The thunk's own identity is a function type that matches no producer, so `resolveDependencies`
        // forms no edge for it at all — without the widening, both subject and yield look dead.
        let names = reachableNames([
            bridgeProxy("MeControllerProxy", seed: "RequestSeed", subject: "MeController", yields: ["Session"]),
            singleton("MeController"),
            singleton("Session"),
            singleton("Unreached"),
        ])
        #expect(names == ["MeControllerProxy", "MeController", "Session"])
    }

    // MARK: - The roots

    @Test("`@Teardown` does not root a binding — a resource nothing reaches is never constructed")
    func teardownDoesNotRoot() {
        // Teardown is a property of a *constructed* binding, not a reason to construct one. Rooting on
        // the annotation would pin every dependency's `@Teardown` binding into every consumer's graph.
        let names = reachableNames([
            singleton("Client", deps: ["Config"], teardown: true),
            singleton("Config"),
            singleton("Unrelated"),
        ])
        #expect(names.isEmpty)
    }

    @Test("A reached `@Teardown` binding stays reachable, and so does what it holds")
    func teardownRidesReachability() {
        // The shape `TeardownExample` already uses: the consumer is the declared root, and the resources
        // it holds are torn down because they were constructed for it.
        let names = reachableNames([
            singleton("Consumer", deps: ["Client"], allowUnused: true, teardown: true),
            singleton("Client", deps: ["Config"], teardown: true),
            singleton("Config"),
            singleton("Unrelated"),
        ])
        #expect(names == ["Consumer", "Client", "Config"])
    }

    @Test("An aggregate a graph conformance names is a root, and pulls its contributors in")
    func conformanceNamedAggregateIsARoot() {
        // The failure this guards is silent: a conformance member whose key has no aggregate falls back
        // to an empty accessor, so pruning this yields a graph that compiles and serves nothing.
        let names = reachableNames(
            [
                singleton("HomeRoute", contributesTo: "App.routes"),
                singleton("Unrelated"),
            ],
            keys: [collectedKey("App.routes", element: "any Route", access: .internal)],
            conformances: [conformance("Composable", member: "routes", key: "App.routes")]
        )
        #expect(names.contains("HomeRoute"))
        #expect(!names.contains("Unrelated"))
    }

    @Test("A key's visibility does not root its aggregate — nothing outside the graph can read one")
    func keyVisibilityDoesNotRoot() {
        // `_WireGraph` is `internal`, so an aggregate's product has no downstream reader for `public` to
        // be protecting. Visibility gates diagnostics; consumption gates construction.
        for access in [AccessLevel.public, .open, .package, .internal] {
            let names = reachableNames(
                [singleton("Plugin", contributesTo: "App.plugins")],
                keys: [collectedKey("App.plugins", element: "any Plugin", access: access)]
            )
            #expect(names.isEmpty, "a \(access) key should not root its aggregate")
        }
    }

    @Test("A consumed aggregate keeps its contributors, whatever the key's visibility")
    func consumedAggregateKeepsContributors() {
        let names = reachableNames(
            [
                singleton("App", keyedDeps: [(type: "[any Plugin]", key: "App.plugins")], allowUnused: true),
                singleton("Plugin", contributesTo: "App.plugins"),
            ],
            keys: [collectedKey("App.plugins", element: "any Plugin", access: .internal)]
        )
        #expect(names.contains("Plugin"))
    }

    @Test("A key marked `allowUnused` in the home package roots its aggregate")
    func allowUnusedKeyIsARoot() {
        let names = reachableNames(
            [singleton("Plugin", contributesTo: "App.plugins")],
            keys: [collectedKey("App.plugins", element: "any Plugin", access: .internal, allowUnused: true)]
        )
        #expect(names.contains("Plugin"))

        // A library's key cannot pin itself into a consumer's graph, exactly as a library's binding cannot.
        let library = reachableNames(
            [singleton("Plugin", contributesTo: "Library.plugins", module: "Library")],
            keys: [
                collectedKey(
                    "Library.plugins",
                    element: "any Plugin",
                    access: .public,
                    allowUnused: true,
                    module: "Library"
                )
            ],
            externalModules: ["Library"]
        )
        #expect(library.isEmpty)
    }

    @Test("`allowUnused` roots a home-package binding; a library's is ignored")
    func allowUnusedIsHomePackageOnly() {
        let home = reachableNames([
            singleton("PulledOutThroughGraph", deps: ["Support"], allowUnused: true),
            singleton("Support"),
        ])
        #expect(home == ["PulledOutThroughGraph", "Support"])

        // The same annotation in a dependency: it keeps its diagnostic meaning, but a library cannot pin
        // itself into a consumer's graph.
        let library = reachableNames(
            [
                singleton("LibraryBinding", deps: ["LibrarySupport"], allowUnused: true, module: "Library"),
                singleton("LibrarySupport", module: "Library"),
            ],
            externalModules: ["Library"]
        )
        #expect(library.isEmpty)
    }

    @Test("A library binding is live exactly when a home root reaches it")
    func libraryBindingLiveViaHomeRoot() {
        let names = reachableNames(
            [
                singleton("App", deps: ["UsedLibraryBinding"], allowUnused: true),
                singleton("UsedLibraryBinding", module: "Library"),
                singleton("UnusedLibraryBinding", module: "Library"),
            ],
            externalModules: ["Library"]
        )
        #expect(names == ["App", "UsedLibraryBinding"])
    }

    // MARK: - Policy

    @Test("A graph asking for no reachability computes none")
    func noPolicyComputesNothing() {
        let result = buildDependencyGraph(
            from: [singleton("Root", allowUnused: true)],
            homeModule: testModule
        )
        #expect(result.reachable == nil)
    }
}
