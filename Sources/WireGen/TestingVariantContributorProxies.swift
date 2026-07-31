import WireGenCore

// Test-graph variant contributor-proxy driving — the executable half of H2.2a.
//
// A shipped M6a variant emits only a seed-scope *facade* returning a scope struct, which loses the teardown
// + per-root pruning an HTTP adapter reaches request scope through in production (the M5.4 contributor
// proxy's `_wireEnterScope(seed)` thunk). This file drives the missing piece: for each production bridging
// proxy over a `@Scoped(seed:)` subject a variant touches, a distinct doubles-threaded variant proxy +
// `Wire.bootstrap<Variant>_<Subject>Contributor(wireGraph:)` facade (rendered by
// `WireGenCore.renderContributorProxyFacade`). A consumer enters request scope with the doubles via
// `variantProxy._wireEnterScope(seed, doubles)`. The seed-only production proxy path is untouched.
extension WireGen {
    /// The production bridging contributor proxies discovered across every partition — a scope-bound type
    /// carrying a `_wireEnterScope` scope-entry thunk (a `.contributesProxy`/`.liftsPeersToProxy` proxy over
    /// a `@Scoped(seed:)` subject). These are the subjects a variant re-emits a doubles-threaded proxy +
    /// facade for.
    static func productionBridgeProxies(in aggregate: DiscoveryAggregate) -> [DiscoveredScopeBoundType] {
        aggregate.allBindings.values.flatMap { $0 }.compactMap { binding in
            // Detect by dependency *kind*, not by the `_wireEnterScope` field name: an aggregate proxy
            // names its thunks `_wireEnterScope_<Subject>`, and must still be recognised as bridging so
            // the variant drops it (a variant carries no doubles-threaded aggregate facade yet — the
            // rewrite sites below skip it, which is the shipped behaviour for any uncovered seed).
            guard case .scopeBound(let type) = binding, type.isBridgeProxy else { return nil }
            return type
        }
    }

    /// The mock-consuming factory transforms for each seed-scoped contributor proxy this variant covers, keyed
    /// by production-proxy type name.
    ///
    /// Computed *before* the variant app graph, because each transform drops a production factory binding and
    /// the graph is built from what survives — while the facades that consume these transforms need the graph
    /// reference that dropping produces. Splitting the computation from the emission breaks that cycle;
    /// `buildVariantContributorFacades` takes the result rather than recomputing it.
    static func seedScopedFactoryTransforms(
        seedScopes: [SeedScopeEmission],
        productionProxies: [DiscoveredScopeBoundType],
        factories: [SynthesizedFactory],
        key: DiscoveredTestingKey,
        module: String
    ) -> [String: [VariantFactoryTransform]] {
        let coveredSeeds = Set(seedScopes.map(\.seedTypeExpression))
        var transformsByProxy: [String: [VariantFactoryTransform]] = [:]
        for proxy in productionProxies {
            guard
                let scopeEntry = proxy.dependencies.first(where: { $0.name == contributorProxyScopeEntryFieldName }),
                let parsed = parsedContributorScopeEntryThunkType(scopeEntry.type),
                coveredSeeds.contains(parsed.seed)
            else { continue }
            let transforms = variantFactoryTransforms(
                proxy: proxy,
                factories: factories,
                key: key,
                variantName: variantName(for: key),
                doublesType: subjectDoublesStructTypeName(
                    variantName: variantName(for: key),
                    subjectTypeName: bareTypeName(parsed.subject)
                ),
                module: module
            )
            if !transforms.isEmpty { transformsByProxy[proxy.typeName] = transforms }
        }
        return transformsByProxy
    }

    /// For each production bridging contributor proxy over a seed-scoped subject that this variant's seed
    /// scopes touch, emit a doubles-threaded variant proxy `struct` + its
    /// `Wire.bootstrap<VariantName>_<Subject>Contributor(wireGraph:)` facade. The variant proxy is the
    /// production proxy renamed with the variant prefix (`_<VariantName><ProductionProxy>`, sharing the
    /// seed-scope facade's disambiguation) and its `_wireEnterScope` thunk re-typed to carry the variant's
    /// `_<Key>Doubles`; the facade builds it against the reused `_WireGraph`, threading the doubles through
    /// the `_wireEnterScope` call. A proxy whose seed no variant scope covers is skipped. Deterministic order
    /// by production-proxy type name.
    ///
    /// A lifted `@Factory` on the proxy that itself consumes a mocked slot gets the same treatment as on a
    /// seedless root: the production factory can't hold a double that only arrives per request, so it is
    /// re-emitted as a variant factory sourcing its mocked deps from `create(doubles:)`, the proxy's field is
    /// re-typed to it, and the facade constructs it instead of reading the (dropped) production binding off
    /// the graph.
    static func buildVariantContributorFacades(
        seedScopes: [SeedScopeEmission],
        productionProxies: [DiscoveredScopeBoundType],
        factoryTransformsByProxy: [String: [VariantFactoryTransform]],
        key: DiscoveredTestingKey,
        parentGraphTypeReference: String
    ) -> [String] {
        var scopeBySeed: [String: SeedScopeEmission] = [:]
        for scope in seedScopes { scopeBySeed[scope.seedTypeExpression] = scope }

        var declarations: [String] = []
        for proxy in productionProxies.sorted(by: { $0.typeName < $1.typeName }) {
            guard
                let scopeEntry = proxy.dependencies.first(where: { $0.name == contributorProxyScopeEntryFieldName }),
                let parsed = parsedContributorScopeEntryThunkType(scopeEntry.type),
                let scope = scopeBySeed[parsed.seed]
            else { continue }
            let factoryTransforms = factoryTransformsByProxy[proxy.typeName] ?? []
            let variantProxy = variantContributorProxy(
                from: proxy,
                seed: parsed.seed,
                subject: parsed.subject,
                key: key,
                factoryRetypes: Dictionary(
                    factoryTransforms.map { ($0.productionDepName, $0.variantType) },
                    uniquingKeysWith: { first, _ in first }
                )
            )
            let facadeMethod = "bootstrap\(variantName(for: key))_\(bareTypeName(parsed.subject))Contributor"
            declarations.append(renderContributorProxyDeclaration(variantProxy))
            declarations.append(
                renderContributorProxyFacade(
                    proxy: variantProxy,
                    scope: scope,
                    parentGraphTypeReference: parentGraphTypeReference,
                    facadeMethodName: facadeMethod,
                    factoryConstructions: Dictionary(
                        factoryTransforms.map { ($0.constructionLocal, $0.constructionExpression) },
                        uniquingKeysWith: { first, _ in first }
                    )
                )
            )
        }
        return declarations
    }

    /// Derive a variant proxy from a production bridging proxy: the same binding with its type renamed
    /// `_<VariantName><ProductionProxy>` (so it doesn't collide with the production proxy in the shared
    /// module) and its `_wireEnterScope` scope-entry thunk re-typed to thread the variant's `_<Key>Doubles`
    /// alongside the seed. Contributes to nothing — it is reached only through the generated facade, never a
    /// production multibinding. A mock-consuming lifted factory is re-typed to its variant factory (named by
    /// `factoryRetypes`); every other dependency carries through unchanged.
    fileprivate static func variantContributorProxy(
        from proxy: DiscoveredScopeBoundType,
        seed: String,
        subject: String,
        key: DiscoveredTestingKey,
        factoryRetypes: [String: String]
    ) -> DiscoveredScopeBoundType {
        let variantName = variantName(for: key)
        let doublesThunkType = contributorScopeEntryThunkType(
            seed: seed,
            subject: subject,
            doubles: subjectDoublesStructTypeName(
                variantName: variantName,
                subjectTypeName: bareTypeName(subject)
            )
        )
        let dependencies = proxy.dependencies.map { dependency -> DependencyParameter in
            guard dependency.name == contributorProxyScopeEntryFieldName else {
                guard let name = dependency.name, let variantType = factoryRetypes[name] else { return dependency }
                return DependencyParameter(
                    name: name,
                    type: variantType,
                    kind: dependency.kind,
                    location: dependency.location,
                    keyIdentifier: dependency.keyIdentifier,
                    nonOwningInitForm: dependency.nonOwningInitForm
                )
            }
            return DependencyParameter(
                name: dependency.name,
                type: doublesThunkType,
                kind: dependency.kind,
                location: dependency.location,
                keyIdentifier: dependency.keyIdentifier,
                nonOwningInitForm: dependency.nonOwningInitForm
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

    /// The bare type name of a subject expression — `MeController<Repository>` → `MeController`, used to
    /// name the variant proxy's facade method (`bootstrap<Variant>_<Subject>Contributor`) and its per-subject
    /// doubles struct. A non-generic subject passes through unchanged.
    static func bareTypeName(_ typeExpression: String) -> String {
        guard let angle = typeExpression.firstIndex(of: "<") else { return typeExpression }
        return String(typeExpression[typeExpression.startIndex..<angle])
    }
}
