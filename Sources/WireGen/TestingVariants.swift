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
        /// The per-subject `_<Variant>_<Subject>Doubles` declarations — one per routed subject, carrying only
        /// the fields that subject reaches. Emitted alongside the key-wide struct, which is unchanged.
        let subjectDoublesStructs: [String]
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
        /// The variant factory `struct` declarations this variant emits — one per mock-consuming lifted
        /// `@Factory` on a seedless root's proxy, holding a `create(doubles:)` the seedless facade constructs
        /// in place of the dropped production factory. Empty when no seedless root lifts a mock-consuming
        /// factory.
        let variantFactoryDeclarations: [String]
    }

    /// The production-graph inputs the per-partition accumulation reuses across a testing key's seed
    /// partitions: the default-graph seed partitions to vary, the app singletons the cascade may lift, the
    /// production app graph's resolved adjacency the cascade walks, and the singleton borrow set the
    /// variant scopes reuse.
    struct VariantPartitionInputs {
        let seedPartitions: [(key: Partition, value: [DiscoveredBinding])]
        let defaultSingletons: [DiscoveredBinding]
        let appEdges: [BindingIdentity: [BindingIdentity]]
        let borrows: [DiscoveredBinding]
    }

    /// One testing key's variant seed scopes accumulated across the default-graph seed partitions: the
    /// doubles fields collected per scope, the built variant seed scopes, their existential promotions,
    /// the scopes that failed validation, and the cascade diagnostics raised.
    struct VariantScopeAccumulation {
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
        defaultOrder: [DiscoveredBinding],
        proxyIdentities: Set<String>,
        factories: [SynthesizedFactory]
    ) -> [TestingVariant] {
        // The opaque-erased reused graph type a variant proxy facade borrows from (`_WireGraph`, or
        // `_WireGraph<some P>` when the app graph lifts opaque axes) — the same reference the seed-scope
        // facade names for its `wireGraph:` parameter.
        let parentGraphTypeReference = openGraphTypeReference(structName: "_WireGraph", topologicalOrder: defaultOrder)
        let productionProxies = productionBridgeProxies(in: aggregate)
        let holdProxies = productionHoldProxies(in: aggregate, proxyIdentities: proxyIdentities)
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
            appSingletons: defaultSingletons,
            productionProxies: productionProxies,
            holdProxies: holdProxies,
            parentGraphTypeReference: parentGraphTypeReference,
            defaultOrder: defaultOrder,
            factories: factories
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
    struct VariantBuildInputs {
        let partitionInputs: VariantPartitionInputs
        let aggregate: DiscoveryAggregate
        let allProductionBindings: [DiscoveredBinding]
        /// The production default-graph app singletons — the set the seedless reconstruction resolves its
        /// subject, mock(s), hops, and borrows against.
        let appSingletons: [DiscoveredBinding]
        let productionProxies: [DiscoveredScopeBoundType]
        /// The production *hold* proxies (`_wireSubject`, over app-`@Singleton` subjects) — the seedless
        /// reconstruction candidates.
        let holdProxies: [DiscoveredScopeBoundType]
        let parentGraphTypeReference: String
        /// The production default-graph topological order — the base the variant app graph drops from.
        let defaultOrder: [DiscoveredBinding]
        /// The synthesised factories — a seedless reconstruction re-emits any the root proxy lifts that
        /// consume a mock as a `create(doubles:)` variant factory.
        let factories: [SynthesizedFactory]
    }

    /// Build one testing key's variant — its doubles struct, doubles-threaded seed scopes, contributor-proxy
    /// artifacts, promotions, validation failures, and diagnostics — or `nil` when the key touches nothing
    /// (no substituted/lifted slot, no failure, no diagnostic), so it emits no code.
    /// The seedless reconstructions for `key` — one per `@Scopable`'d app-`@Singleton` route contributor whose
    /// subject consumes a mock.
    fileprivate static func seedlessReconstructions(
        key: DiscoveredTestingKey,
        variantName: String,
        doublesType: String,
        inputs: VariantBuildInputs
    ) -> [SeedlessReconstruction] {
        seedlessReconstructionRoots(
            key: key,
            holdProxies: inputs.holdProxies,
            appSingletons: inputs.appSingletons,
            appEdges: inputs.partitionInputs.appEdges,
            scopableTypeNames: inputs.aggregate.testScopableTypes
        ).compactMap {
            buildSeedlessReconstruction(
                root: $0,
                key: key,
                variantName: variantName,
                doublesType: doublesType,
                appSingletons: inputs.appSingletons,
                appEdges: inputs.partitionInputs.appEdges,
                factories: inputs.factories,
                aggregate: inputs.aggregate
            )
        }
    }

    /// The variant's source-pattern diagnostics: the accumulation's cascade diagnostics, stale `@BindType`
    /// substitutions (no binding produces the slot), and unmarked seedless roots (an app-scoped route
    /// contributor consuming the mock but not `@Scopable`'d, which would otherwise orphan).
    fileprivate static func variantDiagnostics(
        key: DiscoveredTestingKey,
        accumulation: VariantScopeAccumulation,
        inputs: VariantBuildInputs
    ) -> [Diagnostic] {
        accumulation.diagnostics
            + unmatchedSubstitutions(key.substitutions, against: inputs.allProductionBindings)
            .map(unmatchedBindTypeDiagnostic)
            + unmarkedSeedlessRootDiagnostics(
                key: key,
                holdProxies: inputs.holdProxies,
                appSingletons: inputs.appSingletons,
                appEdges: inputs.partitionInputs.appEdges,
                scopableTypeNames: inputs.aggregate.testScopableTypes
            )
    }

    /// The variant's generated-type prefix, derived from its key reference (`MyTests.setup` → `MyTests_setup`).
    /// Every step that names a variant type derives it from the key this way rather than passing it along.
    static func variantName(for key: DiscoveredTestingKey) -> String {
        key.keyReference.split(separator: ".").map(String.init).joined(separator: "_")
    }

    fileprivate static func buildVariant(for key: DiscoveredTestingKey, inputs: VariantBuildInputs) -> TestingVariant? {
        let variantName = variantName(for: key)
        let doublesType = doublesStructTypeName(forKeyReference: key.keyReference)
        let scopeContext = VariantScopeContext(
            keyReference: key.keyReference,
            variantName: variantName,
            doublesType: doublesType,
            aggregate: inputs.aggregate
        )
        let accumulation = accumulateVariantScopes(key: key, partitions: inputs.partitionInputs, context: scopeContext)

        // Seedless reconstructions — app-`@Singleton` route contributors the key `@Scopable`s that consume a
        // mock, rebuilt per-request from the doubles alone (no seed). Each drops its subject + hold proxy +
        // mock-consuming hops from the variant graph and contributes its doubles fields.
        let seedlessReconstructions = seedlessReconstructions(
            key: key,
            variantName: variantName,
            doublesType: doublesType,
            inputs: inputs
        )

        let diagnostics = variantDiagnostics(key: key, accumulation: accumulation, inputs: inputs)

        guard
            !accumulation.doublesFields.isEmpty || !seedlessReconstructions.isEmpty
                || !accumulation.failures.isEmpty || !diagnostics.isEmpty
        else { return nil }

        let appGraph = buildVariantAppGraph(
            key: key,
            inputs: inputs,
            accumulation: accumulation,
            seedlessReconstructions: seedlessReconstructions
        )
        // Re-point this variant's seed + proxy façades' `wireGraph:` parameter *type* to the variant app graph.
        var seedScopes = accumulation.seedScopes
        for index in seedScopes.indices { seedScopes[index].variantAppGraphReference = appGraph.reference }

        let folded = foldVariantEmissions(
            doublesFields: accumulation.doublesFields,
            contributorFacades: buildVariantContributorFacades(
                seedScopes: seedScopes,
                productionProxies: inputs.productionProxies,
                factoryTransformsByProxy: appGraph.factoryTransforms,
                key: key,
                parentGraphTypeReference: appGraph.reference
            ),
            seedScopedFactoryTransforms: appGraph.factoryTransforms,
            seedlessReconstructions: seedlessReconstructions,
            facadeParentReference: appGraph.reference
        )

        return TestingVariant(
            doublesStruct: renderDoublesStruct(
                typeName: doublesType,
                fields: folded.doublesFields.values.sorted { $0.name < $1.name }
            ),
            subjectDoublesStructs: subjectDoublesStructs(
                seedScopes: seedScopes,
                productionProxies: inputs.productionProxies,
                factoryTransformsByProxy: appGraph.factoryTransforms,
                seedlessReconstructions: seedlessReconstructions,
                variantName: variantName
            ).map(\.declaration),
            seedScopes: seedScopes,
            contributorFacades: folded.contributorFacades,
            existentialPromotions: accumulation.promotions,
            validationFailures: accumulation.failures,
            diagnostics: diagnostics,
            appGraphName: variantName,
            appGraphOrder: appGraph.order,
            variantFactoryDeclarations: folded.factoryDeclarations
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
        let scopableTypeNames = context.aggregate.testScopableTypes
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
