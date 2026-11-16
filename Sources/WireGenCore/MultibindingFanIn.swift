// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

// Fan-in: synthesise one aggregate binding per declared multibinding key
// by collecting the contributions that target it. The aggregate is an
// ordinary `DiscoveredBinding` with a `(collectionType, keyReference)`
// identity and one dependency edge per contributor, so the rest of the
// graph pipeline (split, resolve, topological sort) handles it with no
// special-casing. See
// `Documentation/Notes/MultibindingsImplementationPlan.md` (Step 4).

/// Synthesise the aggregate bindings for one partition's bindings. Called
/// per graph (default, each container, each seed scope) so each partition
/// aggregates its own contributors atomically. Only keys *used* in this
/// partition — contributed to, or consumed by an `@Inject` here — produce
/// an aggregate, so declared-but-unused keys don't leak empty aggregates
/// into every partition.
func synthesizeAggregates(
    keys: [DiscoveredMultibindingKey],
    bindings: [DiscoveredBinding],
    resultBuilders: [DiscoveredResultBuilder] = []
) -> [DiscoveredBinding] {
    // Index contributions by the key they target, pairing each with its
    // contributing binding (the graph edge points there).
    var entriesByKey: [String: [ContributorEntry]] = [:]
    for binding in bindings {
        for contribution in binding.contributions {
            entriesByKey[contribution.keyReference, default: []]
                .append(ContributorEntry(binding: binding, contribution: contribution))
        }
    }
    let buildersByName = resultBuildersByName(resultBuilders)
    let consumedKeys = consumedKeyReferences(in: bindings, among: Set(keys.map(\.keyReference)))

    return keys.compactMap { key in
        let contributors = orderedContributors(entriesByKey[key.keyReference] ?? [])
        // Skip keys neither contributed to nor consumed here.
        guard !contributors.isEmpty || consumedKeys.contains(key.keyReference) else { return nil }
        guard
            let shape = aggregateShape(
                for: key,
                buildersByName: buildersByName,
                contributorCount: contributors.count
            )
        else { return nil }
        return .aggregate(
            DiscoveredAggregate(
                keyReference: key.keyReference,
                collectionType: shape.collectionType,
                flavour: key.flavour,
                builderTypeName: shape.builderTypeName,
                contributors: contributors,
                location: key.location,
                originModule: key.originModule
            )
        )
    }
}

/// Multibinding key references consumed by an `@Inject` dependency among
/// these bindings.
private func consumedKeyReferences(
    in bindings: [DiscoveredBinding],
    among keyReferences: Set<String>
) -> Set<String> {
    var consumed: Set<String> = []
    for binding in bindings {
        for dependency in binding.dependencies {
            if let key = dependency.keyIdentifier, keyReferences.contains(key) {
                consumed.insert(key)
            }
        }
    }
    return consumed
}

private struct ContributorEntry {
    let binding: DiscoveredBinding
    let contribution: Contribution
}

/// The aggregate's type and (for builder) the `@resultBuilder` name, or
/// `nil` when the aggregate can't be formed: a malformed collected/mapped
/// declaration (wrong generic arity), a builder whose result type isn't
/// discoverable, or an *empty* builder key whose builder can't fold an empty
/// body (no zero-argument `buildBlock`). An empty builder key whose builder
/// can fold one gets the empty fold, as an empty collected key gets `[]`.
private func aggregateShape(
    for key: DiscoveredMultibindingKey,
    buildersByName: [String: DiscoveredResultBuilder],
    contributorCount: Int
) -> (collectionType: String, builderTypeName: String?)? {
    switch (key.flavour, key.typeArguments) {
    case (.collected, let arguments) where arguments.count == 1:
        return ("[\(arguments[0])]", nil)
    case (.mapped, let arguments) where arguments.count == 2:
        return ("[\(arguments[0]): \(arguments[1])]", nil)
    case (.builder, let arguments) where arguments.count == 1:
        let builderTypeName = arguments[0]
        guard let builder = buildersByName[builderTypeName],
            contributorCount > 0 || builder.acceptsEmptyBlock
        else { return nil }
        return (builder.resultType, builderTypeName)
    default:
        return nil
    }
}

/// Discovered result builders by simple name, the first declaration winning — the lookup a
/// `BuilderKey<Builder>`'s generic argument text resolves through.
func resultBuildersByName(_ resultBuilders: [DiscoveredResultBuilder]) -> [String: DiscoveredResultBuilder] {
    Dictionary(resultBuilders.map { ($0.typeName, $0) }, uniquingKeysWith: { first, _ in first })
}

/// The key, as an unfoldable empty builder key, when it is a `BuilderKey` whose builder is
/// discovered but can't fold an empty body; `nil` for any other key. Whether the key has
/// contributors is the caller's question.
func unfoldableEmptyBuilderKey(
    _ key: DiscoveredMultibindingKey,
    buildersByName: [String: DiscoveredResultBuilder]
) -> UnfoldableEmptyBuilderKey? {
    guard key.flavour == .builder, key.typeArguments.count == 1,
        let builder = buildersByName[key.typeArguments[0]], !builder.acceptsEmptyBlock
    else { return nil }
    return UnfoldableEmptyBuilderKey(
        keyReference: key.keyReference,
        builderTypeName: builder.typeName,
        resultType: builder.resultType
    )
}

/// Attach the empty-builder diagnostic to each missing binding that is a consumer of a
/// `BuilderKey` nothing in this partition contributes to and whose builder can't fold an empty
/// body — the case `aggregateShape` leaves without an aggregate. Every other missing binding is
/// returned unchanged.
func attachingEmptyBuilderFolds(
    to missing: [MissingBinding],
    keys: [DiscoveredMultibindingKey],
    bindings: [DiscoveredBinding],
    resultBuilders: [DiscoveredResultBuilder]
) -> [MissingBinding] {
    let buildersByName = resultBuildersByName(resultBuilders)
    let contributed = Set(bindings.flatMap { $0.contributions.map(\.keyReference) })
    var unfoldable: [String: UnfoldableEmptyBuilderKey] = [:]
    for key in keys where !contributed.contains(key.keyReference) {
        unfoldable[key.keyReference] = unfoldableEmptyBuilderKey(key, buildersByName: buildersByName)
    }
    guard !unfoldable.isEmpty else { return missing }
    return missing.map { entry in
        guard let key = entry.dependency.keyIdentifier, let fold = unfoldable[key] else { return entry }
        return entry.withEmptyBuilderFold(fold)
    }
}

/// Build aggregate contributors in final order: by `withOrder:` when
/// ranked, otherwise by source location. Step 3 has already rejected
/// mixed and duplicate ranks, so for valid input this is a total order.
/// Each contributor carries a dependency edge whose identity matches the
/// contributing binding's, so the aggregate sorts after it.
private func orderedContributors(_ entries: [ContributorEntry]) -> [AggregateContributor] {
    entries
        .map { entry in
            AggregateContributor(
                dependency: DependencyParameter(
                    name: nil,
                    type: entry.binding.boundType,
                    kind: .injectInitParameter,
                    location: entry.contribution.location,
                    keyIdentifier: entry.binding.keyIdentifier
                ),
                order: entry.contribution.order,
                mapKeyExpression: entry.contribution.mapKeyExpression
            )
        }
        .sorted { lhs, rhs in
            switch (lhs.order, rhs.order) {
            case let (left?, right?) where left != right:
                return left < right
            default:
                return lhs.dependency.location < rhs.dependency.location
            }
        }
}
