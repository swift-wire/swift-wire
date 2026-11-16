// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

// Emission of graph conformances — `extension _WireGraph: <Protocol>` for each
// discovered `WireGraphConformanceV1` declaration. Each member maps to the
// aggregate binding for its multibinding key; the aggregate's product type is
// spelled explicitly so the protocol's associated types are inferred from the
// witnesses (e.g. a `Context` associated type from a `[any RouteContributor<Ctx>]`
// member). Wire knows nothing about what the protocol means.

/// Emit `extension _WireGraph: <Protocol> { … }` for each conformance, mapping each
/// member to the default graph's aggregate binding for its key. A member whose key
/// has *no* contributors in this graph maps to an empty collection (`[]` / `[:]`), or
/// to an empty fold for a `BuilderKey` whose builder can fold one, so the conformance
/// holds even when the consumer contributes nothing — an adapter's
/// `apply` then works whether or not this particular graph feeds it. The imports the
/// referenced protocol and element types need are collected upstream (a conformance is
/// an import source, like a binding — see `WireGen`).
/// Emit the adapter-declared graph conformances on the default graph and on each variant app graph — the
/// variant's aggregate carries the same key (only its dropped contributors are shed), so the member mapping
/// is identical apart from the struct name, and `apply(variantGraph)` needs the conformance just as the
/// default graph does.
func appendAllGraphConformances(
    _ conformances: [DiscoveredGraphConformance],
    defaultOrder: [DiscoveredBinding],
    variantAppOrders: [String: [DiscoveredBinding]],
    multibindingKeys: [DiscoveredMultibindingKey],
    resultBuilders: [DiscoveredResultBuilder] = [],
    into lines: inout [String]
) {
    appendGraphConformances(
        conformances,
        topologicalOrder: defaultOrder,
        multibindingKeys: multibindingKeys,
        resultBuilders: resultBuilders,
        into: &lines
    )
    for (name, order) in variantAppOrders.sorted(by: { $0.key < $1.key }) {
        appendGraphConformances(
            conformances,
            structName: "_\(name)WireGraph",
            topologicalOrder: order,
            multibindingKeys: multibindingKeys,
            resultBuilders: resultBuilders,
            into: &lines
        )
    }
}

func appendGraphConformances(
    _ conformances: [DiscoveredGraphConformance],
    structName: String = "_WireGraph",
    topologicalOrder: [DiscoveredBinding],
    multibindingKeys: [DiscoveredMultibindingKey],
    resultBuilders: [DiscoveredResultBuilder] = [],
    into lines: inout [String]
) {
    guard !conformances.isEmpty else { return }
    let buildersByName = resultBuildersByName(resultBuilders)

    // Aggregate bindings keyed by their multibinding-key reference, so a member's
    // `from:` reference resolves to the graph property carrying that key's product.
    var aggregatesByKey: [String: DiscoveredBinding] = [:]
    for binding in topologicalOrder {
        if case .aggregate = binding, let key = binding.keyIdentifier {
            aggregatesByKey[key] = binding
        }
    }
    // Keys by reference, so a member whose key has no aggregate (no contributors)
    // still resolves its collection type for an empty accessor.
    var keysByReference: [String: DiscoveredMultibindingKey] = [:]
    for key in multibindingKeys {
        keysByReference[key.keyReference] = key
    }

    for conformance in conformances {
        lines.append("")
        lines.append("extension \(structName): \(conformance.protocolName) {")
        for member in conformance.members {
            if let aggregate = aggregatesByKey[member.keyReference] {
                lines.append(
                    "    var \(member.name): \(aggregate.boundTypeReference) "
                        + "{ self.\(propertyName(for: aggregate)) }"
                )
            } else if let accessor = emptyMemberAccessor(
                member: member,
                key: keysByReference[member.keyReference],
                buildersByName: buildersByName
            ) {
                lines.append(accessor)
            }
            // A member whose key is unknown, or a `BuilderKey` whose builder can't fold
            // an empty body, can't form an empty value — it's skipped. Both are reported
            // before emission: an unknown key by `graphConformanceUnknownKeyDiagnostics`,
            // an unfoldable builder by `graphConformanceEmptyBuilderDiagnostics`.
        }
        lines.append("}")
    }
}

/// The `var <name>: <collectionType> { <empty> }` accessor for a member whose key has
/// no contributors in this graph — an empty `[]` for a `CollectedKey`, `[:]` for a
/// `MappedKey`, and `@<Builder> var <name>: <ResultType> { }`, the empty fold, for a
/// `BuilderKey` whose builder can fold an empty body. Returns `nil` for any other
/// `BuilderKey` or an unknown key (no empty value to witness the member with). Mirrors
/// `aggregateShape`'s type derivation.
private func emptyMemberAccessor(
    member: DiscoveredGraphConformance.Member,
    key: DiscoveredMultibindingKey?,
    buildersByName: [String: DiscoveredResultBuilder]
) -> String? {
    guard let key else { return nil }
    switch (key.flavour, key.typeArguments) {
    case (.collected, let arguments) where arguments.count == 1:
        return "    var \(member.name): [\(arguments[0])] { [] }"
    case (.mapped, let arguments) where arguments.count == 2:
        return "    var \(member.name): [\(arguments[0]): \(arguments[1])] { [:] }"
    case (.builder, let arguments) where arguments.count == 1:
        guard let builder = buildersByName[arguments[0]], builder.acceptsEmptyBlock else { return nil }
        return "    @\(builder.typeName) var \(member.name): \(builder.resultType) { }"
    default:
        return nil
    }
}

/// Every graph-conformance diagnostic WireGen reports: members whose key is unknown, and members whose
/// empty `BuilderKey` can't be folded. The latter is judged against the default graph, where the
/// conformance's members read their aggregates; a graph that failed has no order (`nil`), and its own
/// errors already stop the build.
package func graphConformanceDiagnostics(
    _ conformances: [DiscoveredGraphConformance],
    defaultOrder: [DiscoveredBinding]?,
    multibindingKeys: [DiscoveredMultibindingKey],
    resultBuilders: [DiscoveredResultBuilder]
) -> [Diagnostic] {
    let unknownKeys = graphConformanceUnknownKeyDiagnostics(
        conformances: conformances,
        declaredMultibindingKeyReferences: Set(multibindingKeys.map(\.keyReference))
    )
    guard let defaultOrder else { return unknownKeys }
    return unknownKeys
        + graphConformanceEmptyBuilderDiagnostics(
            conformances: conformances,
            topologicalOrder: defaultOrder,
            multibindingKeys: multibindingKeys,
            resultBuilders: resultBuilders
        )
}

/// A graph-conformance member whose `BuilderKey` has no aggregate in the default graph
/// (nothing there contributes to it) and whose builder declares no zero-argument
/// `buildBlock`. Emission can't fold an empty body for it and leaves the member out,
/// which would otherwise surface as the compiler's generic "does not conform" error,
/// or not at all when the protocol has a default implementation for the member. An
/// error at the member's `.init(…)` element, naming the conformance, member, key,
/// builder and the fix.
package func graphConformanceEmptyBuilderDiagnostics(
    conformances: [DiscoveredGraphConformance],
    topologicalOrder: [DiscoveredBinding],
    multibindingKeys: [DiscoveredMultibindingKey],
    resultBuilders: [DiscoveredResultBuilder]
) -> [Diagnostic] {
    let buildersByName = resultBuildersByName(resultBuilders)
    let aggregatedKeys = Set(
        topologicalOrder.compactMap { binding -> String? in
            guard case .aggregate = binding else { return nil }
            return binding.keyIdentifier
        }
    )
    var keysByReference: [String: DiscoveredMultibindingKey] = [:]
    for key in multibindingKeys {
        keysByReference[key.keyReference] = key
    }
    var diagnostics: [Diagnostic] = []
    for conformance in conformances {
        for member in conformance.members where !aggregatedKeys.contains(member.keyReference) {
            guard let key = keysByReference[member.keyReference],
                let fold = unfoldableEmptyBuilderKey(key, buildersByName: buildersByName)
            else { continue }
            diagnostics.append(
                Diagnostic(
                    location: member.location ?? conformance.location,
                    message:
                        "graph conformance to '\(conformance.protocolName)' maps member '\(member.name)' to '\(member.keyReference)', \(fold.reasonAndFix)",
                    severity: .error
                )
            )
        }
    }
    return diagnostics.sorted { $0.location < $1.location }
}

/// A graph-conformance member whose `from:` key matches no multibinding key
/// (`CollectedKey`, `MappedKey` or `BuilderKey`) declared in the parse set — a
/// single-binding `BindingKey`, a key declared in a module WireGen doesn't scan, or
/// a reference spelled differently from the declaration (`from:` is matched by text,
/// as `@Contributes(to:)` is). Emission can't witness such a member (there is neither an aggregate nor a
/// key type to spell an empty accessor from) and leaves it out, which otherwise
/// shows up only as the compiler's generic "does not conform" error, or not at all
/// when the protocol has a default implementation for the member. An error, like
/// `@Contributes(to:)` or `@Inject(K)` against an undeclared key, anchored at the
/// conformance declaration.
package func graphConformanceUnknownKeyDiagnostics(
    conformances: [DiscoveredGraphConformance],
    declaredMultibindingKeyReferences: Set<String>
) -> [Diagnostic] {
    var diagnostics: [Diagnostic] = []
    for conformance in conformances {
        for member in conformance.members
        where !declaredMultibindingKeyReferences.contains(member.keyReference) {
            diagnostics.append(
                Diagnostic(
                    location: conformance.location,
                    message:
                        "graph conformance to '\(conformance.protocolName)' maps member '\(member.name)' to '\(member.keyReference)', which matches no CollectedKey, MappedKey or BuilderKey declared in the parse set — Wire can't witness '\(member.name)' and leaves it out of the conformance. Declare the key in a module Wire scans, or fix the reference.",
                    severity: .error
                )
            )
        }
    }
    return diagnostics.sorted { $0.location < $1.location }
}
