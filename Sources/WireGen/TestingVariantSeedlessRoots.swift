import WireGenCore

// Seedless reconstruction root identification — the executable half of the root-driven `@Scopable` algorithm.
//
// Walk back from each `@BindType` mock to the route-contributor roots that consume it. A root whose subject is
// a `@Scoped(seed:)` binding takes the existing seeded bridge path; a root whose subject is an app-`@Singleton`
// takes the seedless path (rebuilt per request from the doubles alone). This file finds the singleton roots.
extension WireGen {
    /// A seedless reconstruction root — a `@Scopable`'d app-`@Singleton` route contributor whose subject
    /// transitively consumes a `@BindType`'d mock. Under the key its subject is rebuilt per-request seedlessly.
    struct SeedlessRoot {
        /// The production hold proxy (`_wireSubject`) — dropped from the variant graph and re-emitted as a
        /// seedless variant proxy.
        let proxy: DiscoveredScopeBoundType
        /// The app-`@Singleton` subject the proxy holds — substituted (mock → `doubles.<field>`) and
        /// reconstructed in the seedless thunk.
        let subject: DiscoveredScopeBoundType
    }

    /// The production **hold** contributor proxies — proxy bindings (in `proxyIdentities`) that hold their
    /// subject directly (`_wireSubject`), i.e. over an app-`@Singleton` subject, as opposed to the **bridge**
    /// proxies (`_wireEnterScope`) over `@Scoped(seed:)` subjects that `productionBridgeProxies` returns.
    static func productionHoldProxies(
        in aggregate: DiscoveryAggregate,
        proxyIdentities: Set<String>
    ) -> [DiscoveredScopeBoundType] {
        aggregate.allBindings.values.flatMap { $0 }.compactMap { binding in
            guard case .scopeBound(let type) = binding,
                proxyIdentities.contains(type.qualifiedTypeName),
                !type.dependencies.contains(where: { $0.name == contributorProxyScopeEntryFieldName })
            else { return nil }
            return type
        }
    }

    /// The seedless reconstruction roots for `key`: each hold proxy whose subject is `@Scopable`'d and
    /// transitively consumes a `@BindType`'d mock (reachable from the subject over the app graph's adjacency).
    /// Deterministic order by proxy type name.
    static func seedlessReconstructionRoots(
        key: DiscoveredTestingKey,
        holdProxies: [DiscoveredScopeBoundType],
        appSingletons: [DiscoveredBinding],
        appEdges: [BindingIdentity: [BindingIdentity]],
        scopableTypeNames: Set<String>
    ) -> [SeedlessRoot] {
        let mockIdentities = Set(
            appSingletons
                .filter { binding in key.substitutions.contains { substitutionMatches($0, binding) } }
                .map(\.identity)
        )
        guard !mockIdentities.isEmpty else { return [] }

        var subjectByBareName: [String: DiscoveredScopeBoundType] = [:]
        for case .scopeBound(let type) in appSingletons { subjectByBareName[type.typeName] = type }

        var roots: [SeedlessRoot] = []
        for proxy in holdProxies.sorted(by: { $0.typeName < $1.typeName }) {
            guard let subjectDep = proxy.dependencies.first(where: { $0.name == nil }),
                let subject = subjectByBareName[seedlessBareTypeName(subjectDep.type)],
                scopableTypeNames.contains(subject.typeName)
            else { continue }
            let subjectReaches = reachable(from: [DiscoveredBinding.scopeBound(subject).identity], over: appEdges)
            guard !subjectReaches.isDisjoint(with: mockIdentities) else { continue }
            roots.append(SeedlessRoot(proxy: proxy, subject: subject))
        }
        return roots
    }

    /// The guided diagnostics for the *unmarked* seedless candidates — a hold proxy whose subject consumes a
    /// mock but the key hasn't `@Scopable`'d. Without the mark the variant graph would drop the mock and orphan
    /// the contributor, so each is a build error naming the fix (the marked-vs-unmarked mirror of
    /// `seedlessReconstructionRoots`).
    static func unmarkedSeedlessRootDiagnostics(
        key: DiscoveredTestingKey,
        holdProxies: [DiscoveredScopeBoundType],
        appSingletons: [DiscoveredBinding],
        appEdges: [BindingIdentity: [BindingIdentity]],
        scopableTypeNames: Set<String>
    ) -> [Diagnostic] {
        var mockSlot: [BindingIdentity: (slot: String, location: SourceLocation)] = [:]
        for binding in appSingletons {
            guard let match = key.substitutions.first(where: { substitutionMatches($0, binding) }) else { continue }
            mockSlot[binding.identity] = (match.slotType ?? match.slotKey ?? binding.boundType, match.location)
        }
        guard !mockSlot.isEmpty else { return [] }

        var subjectByBareName: [String: DiscoveredScopeBoundType] = [:]
        for case .scopeBound(let type) in appSingletons { subjectByBareName[type.typeName] = type }

        var diagnostics: [Diagnostic] = []
        for proxy in holdProxies.sorted(by: { $0.typeName < $1.typeName }) {
            guard let subjectDep = proxy.dependencies.first(where: { $0.name == nil }),
                let subject = subjectByBareName[seedlessBareTypeName(subjectDep.type)],
                !scopableTypeNames.contains(subject.typeName)
            else { continue }
            let subjectReaches = reachable(from: [DiscoveredBinding.scopeBound(subject).identity], over: appEdges)
            guard let reachedMock = subjectReaches.first(where: { mockSlot[$0] != nil }),
                let slot = mockSlot[reachedMock]
            else { continue }
            diagnostics.append(
                unmarkedSeedlessRootDiagnostic(
                    slotDisplay: slot.slot,
                    subjectName: subject.typeName,
                    location: slot.location
                )
            )
        }
        return diagnostics
    }
}

extension WireGen {
    /// A built seedless reconstruction for one root: the seedless variant proxy binding, the reconstruction
    /// scope carrying the thunk's bindings, the doubles fields, and the identities dropped from the variant
    /// graph (the reconstruction set — subject + mock(s) + hops — plus the production hold proxy).
    struct SeedlessReconstruction {
        let proxy: DiscoveredScopeBoundType
        let scope: SeedScopeEmission
        let doublesFields: [DoublesField]
        let droppedIdentities: Set<BindingIdentity>
        let facadeMethod: String
        /// The variant factory `struct` declarations for the proxy's mock-consuming lifted `@Factory`s — each
        /// a `create(doubles:)` form the seedless proxy holds in place of the (dropped) production factory.
        let variantFactoryDeclarations: [String]
        /// Facade construction expressions keyed by the lifted-factory local the seedless facade binds — a
        /// mock-consuming factory local is *constructed* (variant factory from the non-mock graph deps) rather
        /// than borrowed from the variant graph.
        let factoryConstructions: [String: String]
    }

    /// Build the seedless reconstruction for `root`: the subject + the mock(s) it reaches + any hops (its cone
    /// intersected with what reaches the mock) are substituted (mock → `doubles.<field>`) and topologically
    /// ordered into a reconstruction scope; its non-mock deps borrow the variant graph. The production hold
    /// proxy is re-typed to a seedless `_wireEnterScope(doubles)`. `nil` when the subject reaches no mock.
    static func buildSeedlessReconstruction(
        root: SeedlessRoot,
        key: DiscoveredTestingKey,
        variantName: String,
        doublesType: String,
        appSingletons: [DiscoveredBinding],
        appEdges: [BindingIdentity: [BindingIdentity]],
        factories: [SynthesizedFactory],
        aggregate: DiscoveryAggregate
    ) -> SeedlessReconstruction? {
        guard
            let built = buildReconstructionScope(
                root: root,
                key: key,
                variantName: variantName,
                doublesType: doublesType,
                appSingletons: appSingletons,
                appEdges: appEdges,
                aggregate: aggregate
            )
        else { return nil }

        // Mock-consuming lifted `@Factory`s on the proxy: each becomes a variant factory the proxy holds in
        // place of the (dropped) production factory, its mocked deps sourced from `create(doubles:)`.
        let factoryTransforms = variantFactoryTransforms(
            proxy: root.proxy,
            factories: factories,
            key: key,
            variantName: variantName,
            doublesType: doublesType,
            module: aggregate.module
        )
        let factoryRetypes = Dictionary(
            factoryTransforms.map { ($0.productionDepName, $0.variantType) },
            uniquingKeysWith: { first, _ in first }
        )

        let subjectDepType = root.proxy.dependencies.first(where: { $0.name == nil })?.type ?? root.subject.typeName
        return SeedlessReconstruction(
            proxy: seedlessVariantProxy(
                from: root.proxy,
                subjectDepType: subjectDepType,
                variantName: variantName,
                doublesType: doublesType,
                factoryRetypes: factoryRetypes
            ),
            scope: built.scope,
            doublesFields: built.doublesFields + factoryTransforms.flatMap { $0.doublesFields },
            droppedIdentities: built.reconstructionSet
                .union([DiscoveredBinding.scopeBound(root.proxy).identity])
                .union(factoryTransforms.map { $0.droppedIdentity }),
            facadeMethod: "bootstrap\(variantName)_\(root.subject.typeName)Contributor",
            variantFactoryDeclarations: factoryTransforms.map { $0.declaration },
            factoryConstructions: Dictionary(
                factoryTransforms.map { ($0.constructionLocal, $0.constructionExpression) },
                uniquingKeysWith: { first, _ in first }
            )
        )
    }

    /// The subject reconstruction for `root`: its cone intersected with what reaches the mock (subject +
    /// mock(s) + hops) substituted (mock → `doubles.<field>`) and topologically ordered into a scope, its
    /// non-mock deps borrowed from the variant graph. `nil` when the subject reaches no mock or the scope
    /// doesn't order. The `reconstructionSet` is the identities the variant graph drops.
    private static func buildReconstructionScope(
        root: SeedlessRoot,
        key: DiscoveredTestingKey,
        variantName: String,
        doublesType: String,
        appSingletons: [DiscoveredBinding],
        appEdges: [BindingIdentity: [BindingIdentity]],
        aggregate: DiscoveryAggregate
    ) -> (scope: SeedScopeEmission, reconstructionSet: Set<BindingIdentity>, doublesFields: [DoublesField])? {
        var reverseEdges: [BindingIdentity: [BindingIdentity]] = [:]
        for (consumer, deps) in appEdges { for dep in deps { reverseEdges[dep, default: []].append(consumer) } }
        let mockIdentities = Set(
            appSingletons
                .filter { binding in key.substitutions.contains { substitutionMatches($0, binding) } }
                .map(\.identity)
        )
        let subjectIdentity = DiscoveredBinding.scopeBound(root.subject).identity
        let subjectCone = reachable(from: [subjectIdentity], over: appEdges)
        let mockReaching = reachable(from: Array(mockIdentities), over: reverseEdges)
        // The bindings rebuilt with the mock: the subject's cone that reaches a mock (subject + mock(s) + hops).
        let reconstructionSet = subjectCone.intersection(mockReaching)
        // Everything else the subject needs is borrowed from the variant graph unchanged.
        let borrowSet = subjectCone.subtracting(reconstructionSet)

        let byIdentity = Dictionary(appSingletons.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
        let substituted = applyBindTypeSubstitutions(
            to: reconstructionSet.compactMap { byIdentity[$0] },
            substitutions: key.substitutions
        )
        guard !substituted.doublesFields.isEmpty else { return nil }

        let borrows = syntheticSingletonBorrowBindings(
            from: borrowSet.compactMap { byIdentity[$0] },
            inWireGraphOfType: "_WireGraph"
        )
        let graph = buildDependencyGraph(
            from: substituted.bindings + borrows,
            typealiases: aggregate.typealiases,
            multibindingKeys: aggregate.multibindingKeys,
            resultBuilders: aggregate.resultBuilders,
            homeModule: aggregate.module,
            externalModules: aggregate.externalModules
        )
        guard let order = graph.outcome.topologicalOrder else { return nil }

        var borrowedNames: Set<String> = []
        for borrow in borrows {
            borrowedNames.insert(identifierName(forType: borrow.boundType, key: borrow.keyIdentifier))
        }

        let scope = SeedScopeEmission(
            seedTypeExpression: root.subject.typeName,
            identifierSuffix: "\(variantName)_\(root.subject.typeName)",
            parentGraphType: "_WireGraph",
            topologicalOrder: order,
            borrowedBindingPropertyNames: borrowedNames,
            edges: graph.edges,
            existentialPromotions: graph.existentialPromotions,
            doublesType: doublesType,
            doublesFields: substituted.doublesFields
        )
        return (scope, reconstructionSet, substituted.doublesFields)
    }

    /// Derive the seedless variant proxy from the production hold proxy — the same binding renamed
    /// `_<Variant><HoldProxy>` with its unlabelled `_wireSubject` dependency replaced by a seedless
    /// `_wireEnterScope(doubles)` scope-entry thunk. A mock-consuming lifted-factory dependency is re-typed to
    /// its variant factory (`factoryRetypes[name]`); other lifted-factory dependencies carry through unchanged.
    /// Contributes to nothing (reached only through the generated facade).
    private static func seedlessVariantProxy(
        from proxy: DiscoveredScopeBoundType,
        subjectDepType: String,
        variantName: String,
        doublesType: String,
        factoryRetypes: [String: String]
    ) -> DiscoveredScopeBoundType {
        let thunkType = seedlessScopeEntryThunkType(subject: subjectDepType, doubles: doublesType)
        let dependencies = proxy.dependencies.map { dependency -> DependencyParameter in
            if dependency.name == nil {
                // The unlabelled `_wireSubject` → the seedless `_wireEnterScope(doubles)` scope-entry thunk.
                return DependencyParameter(
                    name: contributorProxyScopeEntryFieldName,
                    type: thunkType,
                    kind: .scopeEntryThunk,
                    location: dependency.location
                )
            }
            // A mock-consuming lifted factory → its variant factory type; other lifted deps carry unchanged.
            guard let name = dependency.name, let variantType = factoryRetypes[name] else { return dependency }
            return DependencyParameter(
                name: name,
                type: variantType,
                kind: dependency.kind,
                location: dependency.location,
                keyIdentifier: dependency.keyIdentifier
            )
        }
        return DiscoveredScopeBoundType(
            typeName: "_\(variantName)\(proxy.typeName)",
            qualifiedTypeName: "_\(variantName)\(proxy.qualifiedTypeName)",
            typeKind: proxy.typeKind,
            genericParameterNames: proxy.genericParameterNames,
            genericParameterConstraints: proxy.genericParameterConstraints,
            genericWhereClause: proxy.genericWhereClause,
            explicitIdentity: proxy.explicitIdentity,
            dependencies: dependencies,
            location: proxy.location,
            scopeKey: proxy.scopeKey,
            initIsAsync: proxy.initIsAsync,
            initIsThrowing: proxy.initIsThrowing,
            memberInjections: proxy.memberInjections,
            accessLevel: proxy.accessLevel,
            contributions: [],
            allowUnused: proxy.allowUnused,
            teardown: proxy.teardown,
            isReplacer: proxy.isReplacer,
            originModule: proxy.originModule
        )
    }
}

/// The bare type name of a subject expression — `MeController<Repository>` → `MeController` — for matching a
/// proxy's `_wireSubject` dependency type to its subject binding.
private func seedlessBareTypeName(_ typeExpression: String) -> String {
    guard let angle = typeExpression.firstIndex(of: "<") else { return typeExpression }
    return String(typeExpression[typeExpression.startIndex..<angle])
}

extension WireGen {
    /// A mock-consuming lifted `@Factory` on a seedless root's proxy, resolved to its variant form. Carries
    /// what the reconstruction needs: the retyped proxy field (`productionDepName` → `variantType`), the
    /// variant factory declaration, its doubles fields, the dropped production factory identity, and the
    /// facade construction (the local the proxy references ← the variant factory built from non-mock graph
    /// deps).
    struct VariantFactoryTransform {
        let productionDepName: String
        let variantType: String
        let declaration: String
        let doublesFields: [DoublesField]
        let droppedIdentity: BindingIdentity
        let constructionLocal: String
        let constructionExpression: String
    }

    /// The variant factory transforms for `proxy`'s lifted `@Factory` dependencies — one per factory that
    /// consumes a `@BindType`'d slot (a mocked `@Inject`). A factory reaching no mock is left alone (it carries
    /// through the proxy unchanged); a mock-consuming one is re-emitted as `_<Variant><FactoryType>` whose
    /// `create(doubles:)` sources the mocked deps from the doubles and holds only the non-mock deps.
    static func variantFactoryTransforms(
        proxy: DiscoveredScopeBoundType,
        factories: [SynthesizedFactory],
        key: DiscoveredTestingKey,
        variantName: String,
        doublesType: String,
        module: String
    ) -> [VariantFactoryTransform] {
        let factoriesByType = Dictionary(
            factories.map { ($0.factoryTypeName, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return proxy.dependencies.compactMap { dependency in
            guard dependency.kind == .injectInitParameter, let depName = dependency.name,
                let factory = factoriesByType[dependency.type]
            else { return nil }

            var mockedFields: [String: String] = [:]
            var doublesFields: [DoublesField] = []
            for factoryDep in factory.dependencies {
                guard let field = mockedDoublesField(for: factoryDep, substitutions: key.substitutions),
                    let name = factoryDep.name
                else { continue }
                mockedFields[name] = field.name
                doublesFields.append(field)
            }
            guard !mockedFields.isEmpty else { return nil }  // reaches no mock — the production factory stands

            let variantType = "_\(variantName)\(factory.factoryTypeName)"
            let heldArguments = factory.dependencies
                .filter { ($0.name.map { mockedFields[$0] == nil }) ?? true }
                .map { dep in
                    "\(dep.name ?? dep.type): _wireGraph.\(identifierName(forType: dep.type, key: dep.keyIdentifier))"
                }
                .joined(separator: ", ")
            return VariantFactoryTransform(
                productionDepName: depName,
                variantType: variantType,
                declaration: renderVariantFactoryDeclaration(
                    factory,
                    typeName: variantType,
                    doublesType: doublesType,
                    mockedDoublesFields: mockedFields
                ),
                doublesFields: doublesFields,
                droppedIdentity: DiscoveredBinding.scopeBound(factoryBinding(factory, module: module)).identity,
                constructionLocal: identifierName(forType: variantType, key: nil),
                constructionExpression: "\(variantType)(\(heldArguments))"
            )
        }
    }
}

/// The doubles field a mock-consuming factory dependency reads from, or `nil` when the dependency isn't a
/// `@BindType`'d slot. Matches the type form on the stripped bound type (`any Repo` / `some Repo` → `Repo`)
/// and the keyed form on the `@Inject(key)` identifier — the same match `substitutionMatches` makes for a
/// binding — and names the field exactly as `applyBindTypeSubstitutions` does, so the factory and the subject
/// share the one doubles field for a shared mock.
private func mockedDoublesField(
    for dependency: DependencyParameter,
    substitutions: [BindTypeSubstitution]
) -> DoublesField? {
    let strippedType = strippedSlotType(dependency.type)
    for substitution in substitutions {
        if let slotType = substitution.slotType, dependency.keyIdentifier == nil, slotType == strippedType {
            return DoublesField(name: identifierName(forType: strippedType, key: nil), mockType: substitution.mockType)
        }
        if let slotKey = substitution.slotKey, dependency.keyIdentifier == slotKey {
            return DoublesField(
                name: identifierName(forType: strippedType, key: slotKey),
                mockType: substitution.mockType
            )
        }
    }
    return nil
}
