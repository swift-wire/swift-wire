// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import WireGenCore

// The two steps between a variant's accumulated scopes and its rendered output: computing the variant app
// graph (what the production order drops, and the type reference the façades are built against), and folding
// the doubles-threaded factory paths into one emission. Both are `buildVariant`'s, split out so it reads as
// the sequence of steps rather than their bodies.
extension WireGen {
    /// The variant app graph: the surviving topological order and the opaque-erased type reference the seed +
    /// proxy façades take as their `wireGraph:` parameter, alongside the seed-scoped factory transforms that
    /// helped produce it.
    struct VariantAppGraph {
        let factoryTransforms: [String: [VariantFactoryTransform]]
        let order: [DiscoveredBinding]
        let reference: String
    }

    /// Build the variant app graph — the production default order MINUS the lifted identities (mocked eager
    /// singletons + `@Scopable` hops the variant reconstructs per scope entry, so their `init` never runs under
    /// `Wire.bootstrap<Variant>()`), every contributor proxy (rebuilt by the variant façades against the variant
    /// graph — the production proxies' scope-entry thunks borrow dropped bindings), and the production factories
    /// the mock-consuming transforms replace. Any surviving aggregate is rewritten to shed its dropped
    /// contributors: a `routeContributors` fan-in keeps its non-scoped contributors and sheds the dropped
    /// scoped-subject proxies (the harness registers those from the variant proxies), so its `[…]` fold
    /// references only surviving locals rather than a dropped proxy's bare type.
    ///
    /// The graph is emitted unless a dropped binding is opaque (`some P`): dropping an opaque axis re-indexes
    /// the variant graph's generics (the generic-subject case is a later phase), so such a variant keeps the
    /// production `_WireGraph` for its seed + proxy façades. Existential/concrete mocked bindings drop no axis,
    /// so the variant graph shares the production axes.
    ///
    /// The seed-scoped factory transforms are computed here rather than at emission time because each drops a
    /// production factory binding and the graph is built from what survives — while the façades that consume
    /// them need the reference this produces.
    static func buildVariantAppGraph(
        key: DiscoveredTestingKey,
        inputs: VariantBuildInputs,
        accumulation: VariantScopeAccumulation,
        seedlessReconstructions: [SeedlessReconstruction]
    ) -> VariantAppGraph {
        let factoryTransforms = seedScopedFactoryTransforms(
            seedScopes: accumulation.seedScopes,
            productionProxies: inputs.productionProxies,
            factories: inputs.factories,
            key: key,
            module: inputs.aggregate.module
        )
        let bridgeProxyIdentities = Set(inputs.productionProxies.map { DiscoveredBinding.scopeBound($0).identity })
        let seedlessDropped = seedlessReconstructions.reduce(into: Set<BindingIdentity>()) {
            $0.formUnion($1.droppedIdentities)
        }
        let dropped = accumulation.liftedIdentities
            .union(bridgeProxyIdentities)
            .union(seedlessDropped)
            .union(Set(factoryTransforms.values.flatMap { $0 }.map(\.droppedIdentity)))
        let order = droppingRemovedAggregateContributors(
            from: inputs.defaultOrder.filter { !dropped.contains($0.identity) },
            dropped: dropped
        )
        // The borrow *name* stays `parentGraphType`'s (`_wireGraph`); only the parameter type re-points. A
        // dropped opaque binding drops its axis, so the reference is re-indexed off the filtered order —
        // consistent across the struct, façades, seed lift, and borrows because each derives its axes from it.
        return VariantAppGraph(
            factoryTransforms: factoryTransforms,
            order: order,
            reference: openGraphTypeReference(
                structName: "_\(variantName(for: key))WireGraph",
                topologicalOrder: order
            )
        )
    }

    /// A variant's folded emission — the doubles fields its `_<Key>Doubles` struct carries, the variant factory
    /// declarations, and the contributor façades.
    struct VariantEmission {
        var doublesFields: [String: DoublesField]
        var factoryDeclarations: [String]
        var contributorFacades: [String]
    }

    /// Fold the variant's two doubles-threaded factory paths into one emission.
    ///
    /// The seed-scoped transforms come first, in proxy-name order so the emission is deterministic. Their
    /// doubles fields join the struct because a factory can consume a slot no controller injects directly, and
    /// the field has to exist for its `create(doubles:)` to read. Each seedless reconstruction then adds its own
    /// fields, its variant factory declarations, and a variant proxy declaration + `(doubles)`-only façade that
    /// rebuilds the subject on demand against the variant graph.
    static func foldVariantEmissions(
        doublesFields: [String: DoublesField],
        contributorFacades: [String],
        seedScopedFactoryTransforms: [String: [VariantFactoryTransform]],
        seedlessReconstructions: [SeedlessReconstruction],
        facadeParentReference: String
    ) -> VariantEmission {
        var emission = VariantEmission(
            doublesFields: doublesFields,
            factoryDeclarations: [],
            contributorFacades: contributorFacades
        )
        for proxyName in seedScopedFactoryTransforms.keys.sorted() {
            for transform in seedScopedFactoryTransforms[proxyName] ?? [] {
                for field in transform.doublesFields { emission.doublesFields[field.name] = field }
                emission.factoryDeclarations.append(transform.declaration)
            }
        }
        for reconstruction in seedlessReconstructions {
            for field in reconstruction.doublesFields { emission.doublesFields[field.name] = field }
            emission.factoryDeclarations.append(contentsOf: reconstruction.variantFactoryDeclarations)
            emission.contributorFacades.append(renderContributorProxyDeclaration(reconstruction.proxy))
            emission.contributorFacades.append(
                renderSeedlessContributorFacade(
                    proxy: reconstruction.proxy,
                    scope: reconstruction.scope,
                    parentGraphTypeReference: facadeParentReference,
                    facadeMethodName: reconstruction.facadeMethod,
                    factoryConstructions: reconstruction.factoryConstructions
                )
            )
        }
        return emission
    }
}
