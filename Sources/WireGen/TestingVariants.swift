import Foundation
import WireGenCore

/// Test-graph variant construction — the executable half of the M6a Phase 1 primitives. Each
/// `TestingKey` selects a graph variant: its `@BindType` substitutions rewrite the named slots into
/// doubles-sourced bindings, and the variant is emitted alongside the production graphs as a
/// container-shaped `_<KeyRef>WireGraph` + its seed scopes (threaded with the variant's `_<Key>Doubles`)
/// + the doubles struct. The production graph is untouched — a module with no `TestingKey` emits exactly
/// what it did before.
extension WireGen {
    /// One test-graph variant ready for emission: its `_<Key>Doubles` struct declaration, the
    /// doubles-threaded variant seed scopes, the rule-3 promotions across them, any scope that failed
    /// validation (surfaced then aborted on), and the source-pattern diagnostics the variant raised (the
    /// cascade's unmarked-`@Scopable` hops and stale-`@BindType` substitutions).
    struct TestingVariant {
        let doublesStruct: String
        let seedScopes: [SeedScopeEmission]
        /// The doubles-threaded contributor-proxy artifacts this variant emits — for each production
        /// bridging proxy over a `@Scoped(seed:)` subject the variant touches, the variant proxy `struct`
        /// declaration and its `Wire.bootstrap<Variant>_<Subject>Contributor(wireGraph:)` facade. Each is a
        /// full declaration emitted alongside the doubles struct; empty when the variant proxies nothing.
        let contributorFacades: [String]
        let existentialPromotions: [ExistentialPromotion]
        let validationFailures: [(name: String, errors: GraphResult.ValidationErrors)]
        let diagnostics: [Diagnostic]
        /// The variant's own app-graph name (`<Variant>` → `_<Variant>WireGraph` / `Wire.bootstrap<Variant>()`)
        /// and its topological order = production default order MINUS the bindings the variant reconstructs
        /// per scope entry (the `@BindType`'d/lifted mocked eager `@Singleton`s + `@Scopable` hops) and the
        /// contributor proxies (rebuilt by façades). Empty order → no variant app graph is emitted for this
        /// key (an opaque-axis-dropping variant, deferred to a later phase); its seed + proxy façades keep the
        /// production `_WireGraph`.
        let appGraphName: String
        let appGraphOrder: [DiscoveredBinding]
    }

    /// The production-graph inputs the per-partition accumulation reuses across a testing key's seed
    /// partitions: the default-graph seed partitions to vary, the app singletons the cascade may lift, the
    /// production app graph's resolved adjacency the cascade walks, and the singleton borrow set the
    /// variant scopes reuse.
    fileprivate struct VariantPartitionInputs {
        let seedPartitions: [(key: Partition, value: [DiscoveredBinding])]
        let defaultSingletons: [DiscoveredBinding]
        let appEdges: [BindingIdentity: [BindingIdentity]]
        let borrows: [DiscoveredBinding]
    }

    /// One testing key's variant seed scopes accumulated across the default-graph seed partitions: the
    /// doubles fields collected per scope, the built variant seed scopes, their existential promotions,
    /// the scopes that failed validation, and the cascade diagnostics raised.
    fileprivate struct VariantScopeAccumulation {
        var doublesFields: [String: DoublesField] = [:]
        var seedScopes: [SeedScopeEmission] = []
        var promotions: [ExistentialPromotion] = []
        var failures: [(name: String, errors: GraphResult.ValidationErrors)] = []
        var diagnostics: [Diagnostic] = []
        /// The app-singleton identities the cascade lifts into scopes across this key's seeds — dropped from
        /// the variant app graph (reconstructed per scope entry), so their `init` never runs there.
        var liftedIdentities: Set<BindingIdentity> = []
    }

    /// Build a variant per discovered `TestingKey` (deduped by reference). The variant reuses the production
    /// `_WireGraph` as its parent — the app graph is unchanged — and diverges only in its seed scopes:
    ///
    /// - **Phase 1 (no cascade):** a `@BindType` substitutes a binding *already inside a seed scope*, which
    ///   is rewritten so the slot resolves to `doubles.<field>`.
    /// - **Phase 2 (the `@Scopable` cascade):** a `@BindType`d binding reached through *app-scoped*
    ///   consumers. `cascadeLift` walks from it up to the seed roots; every app singleton on the path (the
    ///   mocked leaf plus each `@Scopable`d hop) is *lifted* out of the borrow set and into the scope's own
    ///   binding set, so it's reconstructed per scope entry and a `@Singleton` consumer sees the double —
    ///   including at its `init`. An unmarked hop raises a guided diagnostic instead.
    ///
    /// The affected scopes are disambiguated from production by the key (`_<KeyRef>_<Seed>WireScope`) and
    /// thread the variant's `_<Key>Doubles` alongside the seed. `appEdges` is the production app graph's
    /// resolved adjacency, which the cascade walks.
    static func buildTestingVariants(
        in aggregate: DiscoveryAggregate,
        appEdges: [BindingIdentity: [BindingIdentity]],
        defaultOrder: [DiscoveredBinding]
    ) -> [TestingVariant] {
        // The opaque-erased reused graph type a variant proxy facade borrows from (`_WireGraph`, or
        // `_WireGraph<some P>` when the app graph lifts opaque axes) — the same reference the seed-scope
        // facade names for its `wireGraph:` parameter.
        let parentGraphTypeReference = openGraphTypeReference(structName: "_WireGraph", topologicalOrder: defaultOrder)
        let productionProxies = productionBridgeProxies(in: aggregate)
        // Resolve `@Replaces` per partition *before* deriving the variant, so the variant is built from the
        // same `@Replaces`-resolved set the production graphs use — the replaced (real) binding is gone from
        // every graph, and the `@Replaces` fake is the sole binding a later `@BindType` supersedes. Deriving
        // from the raw real+fake pair would substitute both into doubles-sourced providers and leave the
        // variant graph unable to dedup them (`multiple bindings; ambiguous`).
        let resolvedBindings = aggregate.allBindings.mapValues {
            replacesResolvedBindings($0, homeModule: aggregate.module)
        }
        // Production default-graph singletons and the borrow set the variant scopes reuse — the variant
        // borrows the production `_WireGraph` for every app singleton it does not lift.
        let defaultSingletons =
            resolvedBindings
            .filter { $0.key.container == nil && $0.key.scope == nil }
            .flatMap { $0.value }
        let borrows = syntheticSingletonBorrowBindings(from: defaultSingletons, inWireGraphOfType: "_WireGraph")
        // Default-graph seed partitions, deterministically ordered by seed.
        let seedPartitions =
            resolvedBindings
            .filter { $0.key.container == nil && $0.key.scope != nil }
            .sorted { ($0.key.scope?.seed ?? "") < ($1.key.scope?.seed ?? "") }
        let allProductionBindings = defaultSingletons + seedPartitions.flatMap { $0.value }
        let partitionInputs = VariantPartitionInputs(
            seedPartitions: seedPartitions,
            defaultSingletons: defaultSingletons,
            appEdges: appEdges,
            borrows: borrows
        )

        let inputs = VariantBuildInputs(
            partitionInputs: partitionInputs,
            aggregate: aggregate,
            allProductionBindings: allProductionBindings,
            productionProxies: productionProxies,
            parentGraphTypeReference: parentGraphTypeReference,
            defaultOrder: defaultOrder
        )

        var variants: [TestingVariant] = []
        var seen: Set<String> = []
        for key in aggregate.testingKeys where seen.insert(key.keyReference).inserted {
            if let variant = buildVariant(for: key, inputs: inputs) { variants.append(variant) }
        }
        return variants
    }

    /// The production-graph inputs `buildVariant` reuses across every testing key — the seed-partition
    /// accumulation inputs, the aggregate, the whole production binding set (for stale-`@BindType`
    /// diagnostics), the production bridging proxies to re-emit doubles-threaded, and the reused graph type
    /// reference the proxy facades borrow from.
    fileprivate struct VariantBuildInputs {
        let partitionInputs: VariantPartitionInputs
        let aggregate: DiscoveryAggregate
        let allProductionBindings: [DiscoveredBinding]
        let productionProxies: [DiscoveredScopeBoundType]
        let parentGraphTypeReference: String
        /// The production default-graph topological order — the base the variant app graph drops from.
        let defaultOrder: [DiscoveredBinding]
    }

    /// Build one testing key's variant — its doubles struct, doubles-threaded seed scopes, contributor-proxy
    /// artifacts, promotions, validation failures, and diagnostics — or `nil` when the key touches nothing
    /// (no substituted/lifted slot, no failure, no diagnostic), so it emits no code.
    fileprivate static func buildVariant(for key: DiscoveredTestingKey, inputs: VariantBuildInputs) -> TestingVariant? {
        let variantName = key.keyReference.split(separator: ".").map(String.init).joined(separator: "_")
        let doublesType = doublesStructTypeName(forKeyReference: key.keyReference)
        let scopeContext = VariantScopeContext(
            keyReference: key.keyReference,
            variantName: variantName,
            doublesType: doublesType,
            aggregate: inputs.aggregate
        )
        let accumulation = accumulateVariantScopes(key: key, partitions: inputs.partitionInputs, context: scopeContext)

        // A `@BindType` whose slot no production binding produces is stale — surfaced, not discarded.
        var diagnostics = accumulation.diagnostics
        diagnostics += unmatchedSubstitutions(key.substitutions, against: inputs.allProductionBindings)
            .map(unmatchedBindTypeDiagnostic)

        guard !accumulation.doublesFields.isEmpty || !accumulation.failures.isEmpty || !diagnostics.isEmpty
        else { return nil }

        // The variant app graph = the production default order MINUS the lifted identities (mocked eager
        // singletons + `@Scopable` hops the variant reconstructs per scope entry, so their `init` never runs
        // under `Wire.bootstrap<Variant>()`) and every contributor proxy (rebuilt by the variant façades
        // against the variant graph — the production proxies' scope-entry thunks borrow dropped bindings). It
        // is emitted unless a dropped binding is opaque (`some P`): dropping an opaque axis re-indexes the
        // variant graph's generics (the generic-subject case is a later phase), so such a variant keeps the
        // production `_WireGraph` for its seed + proxy façades. Existential/concrete mocked bindings drop no
        // axis, so the variant graph shares the production axes.
        let bridgeProxyIdentities = Set(inputs.productionProxies.map { DiscoveredBinding.scopeBound($0).identity })
        var seedScopes = accumulation.seedScopes
        // Drop the mocked/lifted bindings and the contributor proxies, then rewrite any surviving aggregate to
        // shed its dropped contributors — a `routeContributors` fan-in keeps its non-scoped contributors and
        // sheds the dropped scoped-subject proxies (the harness registers those from the variant proxies), so
        // its `[…]` fold references only surviving locals rather than a dropped proxy's bare type.
        let dropped = accumulation.liftedIdentities.union(bridgeProxyIdentities)
        let appGraphOrder = droppingRemovedAggregateContributors(
            from: inputs.defaultOrder.filter { !dropped.contains($0.identity) },
            dropped: dropped
        )
        // Re-point this variant's seed + proxy façades' `wireGraph:` parameter *type* to the variant app
        // graph (the borrow name stays `_wireGraph`). A dropped opaque (`some P`) binding drops its axis, so
        // the reference is re-indexed off the filtered order — consistent across the struct, façades, seed
        // lift, and borrows because each derives its axes from this same reference.
        let appGraphReference = openGraphTypeReference(
            structName: "_\(variantName)WireGraph",
            topologicalOrder: appGraphOrder
        )
        let facadeParentReference = appGraphReference
        for index in seedScopes.indices { seedScopes[index].variantAppGraphReference = appGraphReference }

        let contributorFacades = buildVariantContributorFacades(
            seedScopes: seedScopes,
            productionProxies: inputs.productionProxies,
            variantName: variantName,
            doublesType: doublesType,
            parentGraphTypeReference: facadeParentReference
        )

        return TestingVariant(
            doublesStruct: renderDoublesStruct(
                typeName: doublesType,
                fields: accumulation.doublesFields.values.sorted { $0.name < $1.name }
            ),
            seedScopes: seedScopes,
            contributorFacades: contributorFacades,
            existentialPromotions: accumulation.promotions,
            validationFailures: accumulation.failures,
            diagnostics: diagnostics,
            appGraphName: variantName,
            appGraphOrder: appGraphOrder
        )
    }

    /// Accumulate one testing key's variant seed scopes across the default-graph seed partitions. Per
    /// partition it applies the Phase-1 `@BindType` substitutions (a slot already inside the seed scope)
    /// and the Phase-2 `@Scopable` cascade (app singletons lifted into the scope), then orchestrates the
    /// substituted + lifted scope — folding the doubles fields, built scopes, existential promotions,
    /// validation failures, and cascade diagnostics into one accumulation.
    fileprivate static func accumulateVariantScopes(
        key: DiscoveredTestingKey,
        partitions: VariantPartitionInputs,
        context: VariantScopeContext
    ) -> VariantScopeAccumulation {
        let scopableTypeNames = Set(key.scopables.map(\.typeName))
        var accumulation = VariantScopeAccumulation()

        for (partition, bindings) in partitions.seedPartitions {
            guard let seedKey = partition.scope else { continue }

            // Phase 1 — substitutions that hit a binding already in this seed scope.
            let seedSubstituted = applyBindTypeSubstitutions(to: bindings, substitutions: key.substitutions)

            // Phase 2 — the cascade: the app singletons (mocked leaf + `@Scopable`d hops) to lift in.
            let cascade = cascadeLift(
                seedBindings: bindings,
                appSingletons: partitions.defaultSingletons,
                appEdges: partitions.appEdges,
                substitutions: key.substitutions,
                scopableTypeNames: scopableTypeNames
            )
            accumulation.diagnostics += cascade.unmarkedHops.map(unmarkedCascadeHopDiagnostic)
            let liftedBindings = partitions.defaultSingletons.filter { cascade.liftedIdentities.contains($0.identity) }
            let liftedSubstituted = applyBindTypeSubstitutions(
                to: liftedBindings,
                substitutions: key.substitutions
            )

            // A scope neither directly substituted nor reached by a lift needs no variant.
            let scopeDoublesFields = seedSubstituted.doublesFields + liftedSubstituted.doublesFields
            guard !scopeDoublesFields.isEmpty else { continue }
            for field in scopeDoublesFields { accumulation.doublesFields[field.name] = field }
            // Record the lifted identities — dropped from the variant app graph.
            accumulation.liftedIdentities.formUnion(cascade.liftedIdentities)

            // The lifted app singletons construct *in the scope* — so they leave the borrow set (else a
            // borrow and a scope-bound binding would collide on one identity).
            let scopeBorrows = partitions.borrows.filter { !cascade.liftedIdentities.contains($0.identity) }

            switch orchestrateVariantScope(
                seedKey: seedKey,
                scopeBindings: seedSubstituted.bindings + liftedSubstituted.bindings,
                scopeBorrows: scopeBorrows,
                doublesFields: scopeDoublesFields,
                context: context
            ) {
            case .failed(let name, let errors):
                accumulation.failures.append((name: name, errors: errors))
            case .built(let seedScope, let scopePromotions):
                accumulation.promotions += scopePromotions
                accumulation.seedScopes.append(seedScope)
            }
        }
        return accumulation
    }

    /// Write any test-graph variant's source-pattern diagnostics (the cascade's unmarked-`@Scopable` hops
    /// and stale-`@BindType` substitutions) and validation failures to stderr, and `exit(1)` on any error —
    /// same discipline as the production graphs, so a broken variant fails the build with a guided message
    /// rather than emitting code that won't compile.
    static func failIfAnyTestingVariantInvalid(_ variants: [TestingVariant]) {
        let diagnostics = variants.flatMap { $0.diagnostics }
        printDiagnostics(diagnostics)

        let failures = variants.flatMap { $0.validationFailures }
        for failure in failures {
            FileHandle.standardError.write(Data("\nin \(failure.name):\n".utf8))
            FileHandle.standardError.write(Data(renderValidationErrors(failure.errors).utf8))
            FileHandle.standardError.write(Data("\n".utf8))
        }

        let hasError = diagnostics.contains { $0.severity == .error } || !failures.isEmpty
        if hasError { exit(1) }
    }
}

extension WireGen {
    /// The inputs `orchestrateVariantScope` needs beyond the per-partition bindings — constant across a
    /// testing key's seed partitions.
    fileprivate struct VariantScopeContext {
        let keyReference: String
        let variantName: String
        let doublesType: String
        let aggregate: DiscoveryAggregate
    }

    /// The outcome of orchestrating one variant seed scope: a validation failure to collect, or the built
    /// scope emission with its existential promotions.
    fileprivate enum VariantScopeOutcome {
        case failed(name: String, errors: GraphResult.ValidationErrors)
        case built(SeedScopeEmission, [ExistentialPromotion])
    }

    /// Orchestrate one testing-variant seed scope — run its substituted + lifted bindings through
    /// `orchestrateSeedScope` against the reused production `_WireGraph`, and package the result.
    fileprivate static func orchestrateVariantScope(
        seedKey: ScopeKey,
        scopeBindings: [DiscoveredBinding],
        scopeBorrows: [DiscoveredBinding],
        doublesFields: [DoublesField],
        context: VariantScopeContext
    ) -> VariantScopeOutcome {
        let orchestration = orchestrateSeedScope(
            seedKey: seedKey,
            containerName: context.variantName,  // disambiguates the emitted names; the parent stays `_WireGraph`
            scopeBindings: scopeBindings,
            borrowBindings: scopeBorrows,
            parentGraphType: "_WireGraph",
            typealiases: context.aggregate.typealiases,
            multibindingKeys: context.aggregate.multibindingKeys,
            resultBuilders: context.aggregate.resultBuilders,
            module: context.aggregate.module,
            homeModule: context.aggregate.module,
            externalModules: context.aggregate.externalModules
        )
        guard let order = orchestration.result.outcome.topologicalOrder else {
            let errors =
                orchestration.result.outcome.validationErrors
                ?? GraphResult.ValidationErrors(cycles: [], missingBindings: [], duplicateBindings: [])
            return .failed(
                name: "testing variant '\(context.keyReference)' scope '\(seedKey.seed)'",
                errors: errors
            )
        }
        return .built(
            SeedScopeEmission(
                seedTypeExpression: orchestration.seedTypeExpression,
                identifierSuffix: orchestration.identifierSuffix,
                parentGraphType: orchestration.parentGraphType,
                topologicalOrder: order,
                borrowedBindingPropertyNames: orchestration.borrowedBindingPropertyNames,
                edges: orchestration.result.edges,
                existentialPromotions: orchestration.result.existentialPromotions,
                doublesType: context.doublesType,
                doublesFields: doublesFields
            ),
            orchestration.result.existentialPromotions
        )
    }
}
