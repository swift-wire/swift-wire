// `@Replaces` resolution for test-graph variant derivation.
//
// `@Replaces` and `@BindType` compose on one type via the precedence chain
//     real binding → @Replaces (all graphs) → @BindType (its keyed variant only, wins).
// A test-graph variant must be derived from the same `@Replaces`-resolved binding set the production graphs
// use, so `@BindType` supersedes the `@Replaces` fake (not a raw real+fake pair). This file resolves
// `@Replaces` over a partition's bindings before the variant is derived.

/// Resolve `@Replaces` overrides across `bindings` before a test-graph variant is derived — drop each
/// binding an active `@Replaces` replacer supersedes (a binding of the same identity), keeping the replacer,
/// so the variant is built from the same `@Replaces`-resolved set the production graphs use.
///
/// `@Replaces` applies to *all* graphs: the replaced binding is gone everywhere, and a `@BindType` then
/// supersedes on top in its keyed variant only. Without this pass, `applyBindTypeSubstitutions` runs on the
/// raw real+fake pair and substitutes *both* into doubles-sourced providers — which carry no `@Replaces`
/// marker — so the variant graph can no longer dedup them (`type '…' has multiple bindings; ambiguous`).
/// Resolving first leaves the `@Replaces` fake as the sole binding for the slot, which the substitution then
/// supersedes into the single doubles-sourced mock.
///
/// An active replacer is honoured exactly as the production resolution honours it (`resolveReplacements`):
/// from the home module, or from any module when no home module is modelled. Invalid `@Replaces` (nothing to
/// replace, two replacers, same-module) is a production-graph validation error already, so this pass doesn't
/// re-diagnose it — it applies the supersede where a replacer is present and passes everything else through.
package func replacesResolvedBindings(
    _ bindings: [DiscoveredBinding],
    homeModule: String?
) -> [DiscoveredBinding] {
    func isActiveReplacer(_ binding: DiscoveredBinding) -> Bool {
        guard binding.isReplacer else { return false }
        guard let homeModule else { return true }
        return binding.originModule == homeModule
    }
    let supersededIdentities = Set(bindings.filter(isActiveReplacer).map(\.identity))
    guard !supersededIdentities.isEmpty else { return bindings }
    // Drop every non-replacer binding whose identity an active replacer claims, and keep the replacer with
    // its `@Replaces` marker CLEARED: the supersede is complete (the replaced binding is already gone), so
    // the kept binding must not re-fire the "nothing to supersede" rule when a variant seed scope that
    // borrows it re-resolves `@Replaces` in its own graph.
    return bindings.compactMap { binding -> DiscoveredBinding? in
        guard supersededIdentities.contains(binding.identity) else { return binding }
        guard isActiveReplacer(binding) else { return nil }
        return clearingReplacerFlag(binding)
    }
}

/// The binding with its `@Replaces` marker cleared — a plain, non-superseding copy. Used by
/// `replacesResolvedBindings` on a kept replacer once its replaced sibling is dropped. Aggregates carry no
/// `@Replaces`, so they pass through unchanged.
private func clearingReplacerFlag(_ binding: DiscoveredBinding) -> DiscoveredBinding {
    switch binding {
    case .scopeBound(let type):
        return .scopeBound(
            DiscoveredScopeBoundType(
                typeName: type.typeName,
                qualifiedTypeName: type.qualifiedTypeName,
                typeKind: type.typeKind,
                genericParameterNames: type.genericParameterNames,
                genericParameterConstraints: type.genericParameterConstraints,
                genericWhereClause: type.genericWhereClause,
                explicitIdentity: type.explicitIdentity,
                dependencies: type.dependencies,
                location: type.location,
                scopeKey: type.scopeKey,
                initIsAsync: type.initIsAsync,
                initIsThrowing: type.initIsThrowing,
                memberInjections: type.memberInjections,
                accessLevel: type.accessLevel,
                contributions: type.contributions,
                allowUnused: type.allowUnused,
                teardown: type.teardown,
                isReplacer: false,
                originModule: type.originModule
            )
        )
    case .provider(let provider):
        return .provider(
            DiscoveredProvider(
                boundType: provider.boundType,
                accessPath: provider.accessPath,
                form: provider.form,
                dependencies: provider.dependencies,
                genericParameterNames: provider.genericParameterNames,
                location: provider.location,
                keyIdentifier: provider.keyIdentifier,
                concreteGenericArguments: provider.concreteGenericArguments,
                isAsync: provider.isAsync,
                isThrowing: provider.isThrowing,
                accessLevel: provider.accessLevel,
                scopeKey: provider.scopeKey,
                contributions: provider.contributions,
                allowUnused: provider.allowUnused,
                teardown: provider.teardown,
                isReplacer: false,
                originModule: provider.originModule
            )
        )
    case .aggregate:
        return binding
    }
}
