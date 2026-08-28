import Testing

@testable import WireGenCore

/// A seeded scope yielding **more than its subject**.
///
/// The scope-entry thunk is the only door into a request scope from outside it: a bridging proxy stores
/// the thunk in place of the subject, and the thunk enters, constructs, and hands back
/// `(Subject, teardown)`. Everything else the scope binds is constructed *inside* that closure and is
/// unreachable from the caller — not because it is unbound, but because there is no slot to return it
/// through. `.yieldsFromScope` adds slots.
///
/// Two properties carry the weight and are asserted separately throughout: the tuple's **shape** (what the
/// thunk type declares, since the caller destructures positionally and has only the type to go on), and
/// the thunk **body**'s construction set (since a yielded binding is a reachability root of its own —
/// nothing in the scope depends on it, so pruning from the subject alone would drop it).
@Suite("Scope yields")
struct ScopeYieldTests {
    // MARK: - Helpers

    private func scoped(
        _ name: String,
        seed: String,
        dependencies: [(name: String?, type: String)] = []
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
                scopeKey: ScopeKey(seed: seed),
                originModule: testModule
            )
        )
    }

    private func syntheticProvider(boundType: String, accessPath: String) -> DiscoveredBinding {
        .provider(
            DiscoveredProvider(
                boundType: boundType,
                accessPath: accessPath,
                form: .property,
                dependencies: [],
                genericParameterNames: [],
                location: mockLocation("<synthetic>"),
                originModule: testModule
            )
        )
    }

    private func subjectDeclaration(
        _ name: String,
        seed: String,
        dependencies: [(name: String?, type: String)] = []
    ) -> DiscoveredScopeBoundType {
        guard case .scopeBound(let type) = scoped(name, seed: seed, dependencies: dependencies) else {
            fatalError("scoped() builds a scope-bound binding")
        }
        return type
    }

    // MARK: - The thunk's return type

    @Test func theThunkReturnsANamedStructRatherThanATuple() {
        // A tuple is read by position, and the thunk's return is a contract an adapter's generated code
        // reads. Adding a yield to a tuple moves every element after it, and the reader goes on compiling
        // while reading the wrong one. A named struct makes an addition additive — which is also why the
        // no-yield case gets a struct too rather than staying a tuple: one shape, always.
        let descriptor = scopeEntryDescriptor(seed: "RequestSeed", subject: "SessionController")
        #expect(
            descriptor.thunkType
                == "@Sendable (RequestSeed) async throws -> _WireScopeEntry_SessionController"
        )
    }

    @Test func yieldsAreNamedFieldsOnTheEntryStruct() {
        let descriptor = scopeEntryDescriptor(
            seed: "RequestSeed",
            subject: "DocumentsController",
            yields: ["AuthorizedDocument", "Caller"]
        )
        #expect(
            renderScopeEntryStructDeclaration(descriptor) == """
                struct _WireScopeEntry_DocumentsController: Sendable, WireScopeEntry {
                    let _wireSubject: DocumentsController
                    let authorizedDocument: AuthorizedDocument
                    let caller: Caller
                    let _wireScopeTeardown: @Sendable () async -> [any Error]
                }
                """
        )
    }

    @Test func theEntryStructIsGenericExactlyAsItsSubject() {
        // The case the design turned on, and the one worth pinning: a subject over an opaque backend has
        // no spellable return type at the closure, so the entry struct has to be generic over the *proxy's*
        // parameters and have its arguments inferred where the thunk constructs it. Declaring it with a
        // parameter none of its fields mention would make that inference impossible — which is why the
        // parameters come from the subject rather than from an aggregate proxy's union of every member's.
        let descriptor = scopeEntryDescriptor(
            seed: "HTTPRequest",
            subject: "MeController<Repository, Manager>",
            genericParameterNames: ["Repository", "Manager"],
            genericParameterConstraints: ["Repository": "TodoRepository", "Manager": "SessionManager"]
        )
        #expect(
            renderScopeEntryStructDeclaration(descriptor) == """
                struct _WireScopeEntry_MeController<Repository: TodoRepository, Manager: SessionManager>: Sendable, WireScopeEntry {
                    let _wireSubject: MeController<Repository, Manager>
                    let _wireScopeTeardown: @Sendable () async -> [any Error]
                }
                """
        )
        #expect(
            descriptor.thunkType
                == "@Sendable (HTTPRequest) async throws -> _WireScopeEntry_MeController<Repository, Manager>"
        )
    }

    @Test func aVariantsEntryStructCannotCollideWithTheProductionOne() {
        // Both are emitted into the same module, and a variant proxy is derived from the production one —
        // so the struct names have to differ even though the subject does not.
        #expect(scopeEntryStructName(subjectTypeName: "MeController") == "_WireScopeEntry_MeController")
        #expect(
            scopeEntryStructName(subjectTypeName: "MeController", variant: "MyKey")
                == "_WireScopeEntry_MyKey_MeController"
        )
    }

    // MARK: - Detection

    /// A route parameter carrying `attribute`, on a method of `subject`.
    private func candidate(_ attribute: String, on subject: String) -> ScopeYieldCandidate {
        ScopeYieldCandidate(
            targetIdentity: subject,
            typeName: attribute,
            location: mockLocation("\(subject).swift")
        )
    }

    @Test func aParameterNamingAScopeBindingIsTheRequest() {
        // The whole seam: nothing is declared and nothing is annotated for. `@AuthorizedDocument` on a
        // route parameter *is* `AuthorizedDocument` the binding — an attribute name and a type name are the
        // same identifier in Swift — so the match is identity rather than a heuristic.
        let yields = scopeYields(
            for: subjectDeclaration("DocumentsController", seed: "RequestSeed"),
            candidates: [candidate("AuthorizedDocument", on: "DocumentsController")],
            inScopeWith: [scoped("AuthorizedDocument", seed: "RequestSeed")]
        )
        #expect(yields == ["AuthorizedDocument"])
    }

    @Test func anAttributeThatIsNoBindingIsIgnored() {
        // Why the rule needs no list of attributes to skip. `@Path` and `@JSONBody` are types that are no
        // binding at all, so they cannot match — and a request-binding vocabulary Wire has never heard of
        // is filtered by the same test, without Wire learning what a route is.
        let yields = scopeYields(
            for: subjectDeclaration("DocumentsController", seed: "RequestSeed"),
            candidates: [
                candidate("Path", on: "DocumentsController"),
                candidate("JSONBody", on: "DocumentsController"),
                candidate("AuthorizedDocument", on: "DocumentsController"),
            ],
            inScopeWith: [scoped("AuthorizedDocument", seed: "RequestSeed")]
        )
        #expect(yields == ["AuthorizedDocument"])
    }

    @Test func aBindingInAnotherScopeIsNotYielded() {
        // The subject's *own* partition is the whole test — `inScopeWith` is the seed scope the entry
        // constructs. A binding of that name elsewhere is not in this list, and the diagnostics below
        // report the ones that were plainly meant to be.
        let yields = scopeYields(
            for: subjectDeclaration("DocumentsController", seed: "RequestSeed"),
            candidates: [candidate("AuthorizedDocument", on: "DocumentsController")],
            inScopeWith: [scoped("SomethingElse", seed: "RequestSeed")]
        )
        #expect(yields.isEmpty)
    }

    @Test func anUnscopedSubjectYieldsNothing() {
        // A held subject enters no scope, so there is no thunk to yield through whatever its parameters
        // name. Reported by `scopeYieldDiagnostics`; here it simply produces no yields.
        let held = DiscoveredScopeBoundType(
            typeName: "DocumentsController",
            typeKind: "struct",
            genericParameterNames: [],
            dependencies: [],
            location: mockLocation("C.swift"),
            originModule: testModule
        )
        #expect(
            scopeYields(
                for: held,
                candidates: [candidate("AuthorizedDocument", on: "DocumentsController")],
                inScopeWith: [scoped("AuthorizedDocument", seed: "RequestSeed")]
            ).isEmpty
        )
    }

    @Test func aSubjectNeverYieldsItself() {
        // A route taking its own controller as an argument would otherwise construct it twice — once as
        // the entry's subject and once as a yield.
        #expect(
            scopeYields(
                for: subjectDeclaration("DocumentsController", seed: "RequestSeed"),
                candidates: [candidate("DocumentsController", on: "DocumentsController")],
                inScopeWith: [scoped("DocumentsController", seed: "RequestSeed")]
            ).isEmpty
        )
    }

    @Test func yieldsAreDeduplicatedAndOrderedByTypeName() {
        // Two routes naming the same binding ask for one value — twice would be a struct with a duplicated
        // field name, which does not compile. The order is for a stable emitted file rather than for
        // correctness: the entry struct names its fields, so a re-order could never silently misread.
        let yields = scopeYields(
            for: subjectDeclaration("DocumentsController", seed: "RequestSeed"),
            candidates: [
                candidate("Zebra", on: "DocumentsController"),
                candidate("Aardvark", on: "DocumentsController"),
                candidate("Zebra", on: "DocumentsController"),
            ],
            inScopeWith: [scoped("Zebra", seed: "RequestSeed"), scoped("Aardvark", seed: "RequestSeed")]
        )
        #expect(yields == ["Aardvark", "Zebra"])
    }

    // MARK: - Emission

    /// Just the scope-entry thunk's closure body, out of the whole generated file.
    ///
    /// Asserting against the file would be asserting nothing: `renderWireGraph` *also* emits the seed
    /// scope's own standalone bootstrap (`_wireBootstrapRequestSeedScope`), which constructs every binding
    /// in the scope unpruned — so "the output contains `AuthorizedDocument(`" is true whether the thunk
    /// built it or not. Pruning is a property of the thunk alone, so the assertions have to be too.
    private func thunkBody(of output: String) -> String {
        guard let start = output.firstRange(of: "{ @Sendable (requestSeed: RequestSeed) async throws in"),
            let end = output[start.upperBound...].firstRange(of: "\n    }")
        else {
            Issue.record("no scope-entry thunk in the generated output")
            return ""
        }
        return String(output[start.upperBound..<end.lowerBound])
    }

    /// A scope with a controller, a yielded binding nothing depends on, and a third binding reachable
    /// only through the yielded one — the shape that separates "yields are returned" from "yields are
    /// construction roots".
    private func documentsScope() -> SeedScopeEmission {
        SeedScopeEmission(
            seedTypeExpression: "RequestSeed",
            identifierSuffix: "RequestSeed",
            parentGraphType: "_WireGraph",
            topologicalOrder: [
                syntheticProvider(boundType: "RequestSeed", accessPath: "requestSeed"),
                scoped("Caller", seed: "RequestSeed", dependencies: [(name: "seed", type: "RequestSeed")]),
                scoped("DocumentsController", seed: "RequestSeed", dependencies: [(name: "seed", type: "RequestSeed")]),
                scoped(
                    "AuthorizedDocument",
                    seed: "RequestSeed",
                    dependencies: [(name: "caller", type: "Caller")]
                ),
            ],
            borrowedBindingPropertyNames: [],
            edges: [
                scoped("DocumentsController", seed: "RequestSeed").identity: [
                    syntheticProvider(boundType: "RequestSeed", accessPath: "requestSeed").identity
                ],
                scoped("AuthorizedDocument", seed: "RequestSeed").identity: [
                    scoped("Caller", seed: "RequestSeed").identity
                ],
                scoped("Caller", seed: "RequestSeed").identity: [
                    syntheticProvider(boundType: "RequestSeed", accessPath: "requestSeed").identity
                ],
            ]
        )
    }

    @Test func aYieldIsReturnedAlongsideTheSubjectAndBeforeTheTeardown() {
        let proxy = contributorProxyBinding(
            for: subjectDeclaration(
                "DocumentsController",
                seed: "RequestSeed",
                dependencies: [(name: "seed", type: "RequestSeed")]
            ),
            key: "WireMVCKeys.routeContributors",
            prefix: "_WireRouteContributor_",
            proxyScope: .singleton,
            yields: ["AuthorizedDocument"]
        )
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [.scopeBound(proxy)],
            seedScopeOrders: [documentsScope()]
        )
        #expect(
            thunkBody(of: output).contains(
                "return _WireScopeEntry_DocumentsController(_wireSubject: documentsController, authorizedDocument: authorizedDocument, _wireScopeTeardown: _wireScopeTeardown)"
            )
        )
    }

    @Test func aYieldIsAConstructionRootAndPullsItsOwnSubgraphIn() {
        // The property that makes this more than a wider `return`. Per-root pruning constructs only what
        // the routed controller reaches, so before this a yielded binding — which nothing in the scope
        // depends on — was pruned away and the `return` would have named a local nothing bound. `Caller`
        // is reachable *only* through `AuthorizedDocument`, so its presence is what proves the root is a
        // root rather than merely exempted from pruning.
        let proxy = contributorProxyBinding(
            for: subjectDeclaration(
                "DocumentsController",
                seed: "RequestSeed",
                dependencies: [(name: "seed", type: "RequestSeed")]
            ),
            key: "WireMVCKeys.routeContributors",
            prefix: "_WireRouteContributor_",
            proxyScope: .singleton,
            yields: ["AuthorizedDocument"]
        )
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [.scopeBound(proxy)],
            seedScopeOrders: [documentsScope()]
        )
        let thunk = thunkBody(of: output)
        #expect(thunk.contains("let authorizedDocument = AuthorizedDocument(caller: caller)"))
        #expect(thunk.contains("let caller = Caller(seed: requestSeed)"))
    }

    @Test func withoutTheYieldNeitherIsConstructed() {
        // The other half of the previous test, and what makes it an assertion about yields rather than
        // about this scope happening to build everything: the same graph, the same pruning, no annotation.
        let proxy = contributorProxyBinding(
            for: subjectDeclaration(
                "DocumentsController",
                seed: "RequestSeed",
                dependencies: [(name: "seed", type: "RequestSeed")]
            ),
            key: "WireMVCKeys.routeContributors",
            prefix: "_WireRouteContributor_",
            proxyScope: .singleton
        )
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [.scopeBound(proxy)],
            seedScopeOrders: [documentsScope()]
        )
        let thunk = thunkBody(of: output)
        #expect(
            thunk.contains(
                "return _WireScopeEntry_DocumentsController(_wireSubject: documentsController, _wireScopeTeardown: _wireScopeTeardown)"
            )
        )
        #expect(!thunk.contains("AuthorizedDocument("))
        #expect(!thunk.contains("Caller("))
    }

    // MARK: - End to end, from source

    @Test func aRouteParameterIsDetectedThroughDiscoveryAndSynthesis() throws {
        // The unit tests above call `scopeYields` directly; this one runs what actually happens —
        // `discover()` reading a parameter attribute out of a method signature, then synthesis matching it
        // against the subject's own seed partition. It is the test that catches a plumbing break, since
        // every step between the two is otherwise unasserted.
        let source = """
            enum Adapter {
                static let controller = WireAdapterAnnotationV1(
                    annotation: "Controller",
                    capability: .contributesProxy(to: Keys.routes, proxyTypePrefix: "_WireRouteContributor_"))
            }

            struct RequestSeed {}
            struct Document {}

            @Scoped(seed: RequestSeed.self)
            struct AuthorizedDocument {}

            @Scoped(seed: RequestSeed.self)
            struct Caller {}

            @Scoped(seed: RequestSeed.self)
            @Controller
            struct DocumentsController {
                func read(@AuthorizedDocument document: Document) {}
                func list(@Path id: String) {}
            }
            """
        let discovery = discover(in: source, sourcePath: "App.swift", module: testModule)
        // Discovery is deliberately unfiltered: it records `@Path` too, and knows nothing about bindings.
        #expect(discovery.scopeYieldCandidates.map(\.typeName).sorted() == ["AuthorizedDocument", "Path"])

        let proxied = applyContributorProxies(
            to: discovery.allBindings,
            annotations: discovery.adapterAnnotations,
            useSites: discovery.aliasUseSites,
            scopeYieldCandidates: discovery.scopeYieldCandidates
        )
        let proxy = try #require(
            proxied.bindings.values.joined().compactMap { binding -> DiscoveredScopeBoundType? in
                guard case .scopeBound(let type) = binding,
                    type.typeName == "_WireRouteContributor_DocumentsController"
                else { return nil }
                return type
            }.first
        )
        let descriptor = try #require(proxy.scopeEntryDependencies.first?.scopeEntry)
        // `AuthorizedDocument` is yielded; `Path` is not a binding, and `Caller` is in the scope but no
        // route asked for it — a yield is a *root*, not everything the scope happens to hold.
        #expect(descriptor.yields == ["AuthorizedDocument"])
        #expect(descriptor.subject == "DocumentsController")
    }

    // MARK: - Diagnostics

    private func partitioned(
        seed: String? = nil,
        _ bindings: [DiscoveredBinding]
    ) -> [Partition: [DiscoveredBinding]] {
        [Partition(container: nil, scope: seed.map { ScopeKey(seed: $0) }): bindings]
    }

    @Test func aScopeBindingAskedForByAnUnscopedControllerIsRefused() {
        // The mistake a user can now make by accident, which is the reason the diagnostic survives the
        // annotation it used to be about: the route asks for a request-scoped argument on a controller
        // that is not request-scoped, so there is no scope to build it in and the yield silently does not
        // happen.
        var bindings = partitioned(seed: "RequestSeed", [scoped("AuthorizedDocument", seed: "RequestSeed")])
        bindings[Partition(container: nil, scope: nil)] = [
            .scopeBound(
                DiscoveredScopeBoundType(
                    typeName: "DocumentsController",
                    typeKind: "struct",
                    genericParameterNames: [],
                    dependencies: [],
                    location: mockLocation("C.swift"),
                    originModule: testModule
                )
            )
        ]
        let diagnostics = scopeYieldDiagnostics(
            bindings: bindings,
            candidates: [candidate("AuthorizedDocument", on: "DocumentsController")]
        )
        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.severity == .error)
        #expect(diagnostics.first?.message.contains("'DocumentsController' is not scoped") == true)
    }

    @Test func aScopeBindingFromASiblingSeedIsRefused() {
        var bindings = partitioned(seed: "OtherSeed", [scoped("AuthorizedDocument", seed: "OtherSeed")])
        bindings[Partition(container: nil, scope: ScopeKey(seed: "RequestSeed"))] = [
            scoped("DocumentsController", seed: "RequestSeed")
        ]
        let diagnostics = scopeYieldDiagnostics(
            bindings: bindings,
            candidates: [candidate("AuthorizedDocument", on: "DocumentsController")]
        )
        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.message.contains("sibling seeded scopes are isolated") == true)
    }

    @Test func anAttributeThatIsNoBindingIsNeverReported() {
        // The overwhelming majority of parameter attributes, and none of Wire's business. A diagnostic
        // here would fire on every `@Path` in every app.
        let diagnostics = scopeYieldDiagnostics(
            bindings: partitioned(seed: "RequestSeed", [scoped("DocumentsController", seed: "RequestSeed")]),
            candidates: [
                candidate("Path", on: "DocumentsController"),
                candidate("JSONBody", on: "DocumentsController"),
            ]
        )
        #expect(diagnostics.isEmpty)
    }

    @Test func aYieldThatWorksIsSilent() {
        let diagnostics = scopeYieldDiagnostics(
            bindings: partitioned(
                seed: "RequestSeed",
                [
                    scoped("DocumentsController", seed: "RequestSeed"),
                    scoped("AuthorizedDocument", seed: "RequestSeed"),
                ]
            ),
            candidates: [candidate("AuthorizedDocument", on: "DocumentsController")]
        )
        #expect(diagnostics.isEmpty)
    }

    @Test func oneMistakeIsReportedOnceAcrossSeveralRoutes() {
        var bindings = partitioned(seed: "OtherSeed", [scoped("AuthorizedDocument", seed: "OtherSeed")])
        bindings[Partition(container: nil, scope: ScopeKey(seed: "RequestSeed"))] = [
            scoped("DocumentsController", seed: "RequestSeed")
        ]
        let diagnostics = scopeYieldDiagnostics(
            bindings: bindings,
            candidates: [
                candidate("AuthorizedDocument", on: "DocumentsController"),
                candidate("AuthorizedDocument", on: "DocumentsController"),
                candidate("AuthorizedDocument", on: "DocumentsController"),
            ]
        )
        #expect(diagnostics.count == 1)
    }
}
