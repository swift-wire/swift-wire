// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import WireGenCore

// Refusing the aggregate case the variant pass does not build — a contributor proxy over more than one
// subject (swift-wire/swift-wire#362).
//
// `.contributesAggregateProxy` names a lone subject positionally (`_wireSubject` / `_wireEnterScope`) and
// labels each of several (`_wireSubject_<Subject>` / `_wireEnterScope_<Subject>`), so that a one-member group
// emits byte-identically to `.contributesProxy`. Every root finder in this pass looks for the singular
// spellings, which is correct at one subject and matches nothing at several — so a group of two or more used
// to be skipped in silence by all of them at once. The whole variant then collapsed: no graph, no doubles
// structs, no proxies, no facades, and not even the `@TestScopable` guidance that would have led the author
// somewhere. This file is what the pass says instead.
//
// Split from `TestingVariantSeedlessRoots` because it is the opposite question — that file asks which proxies
// a variant *can* re-emit, this one which it must refuse — and to keep both within the file-length budget.
extension WireGen {
    /// What makes one group offend: the subject a variant would have had to rebuild, the mocked slot it
    /// reaches, and where the author wrote that slot. A named type rather than a tuple because the diagnostic
    /// reads all three and SwiftLint's `large_tuple` starts at three.
    private struct AggregateRefusal {
        let subject: String
        let slot: String
        let location: SourceLocation
    }

    /// The refusals for contributor proxies over **more than one subject** that this key would have to
    /// re-emit doubles-threaded.
    ///
    /// Reported over both proxy lists, because both halves of the pass skip such a proxy and each skips it
    /// into a different silence: a held subject reaching a mock produces no reconstruction (and, before this,
    /// no diagnostic either, so the variant collapsed to nothing at all), while a bridged subject whose seed
    /// the variant covers is *dropped* from the variant graph with no replacement emitted — the group's routes
    /// vanish from a suite that otherwise builds. One diagnostic covers both, because the cause and the fix
    /// are the same: the group, not the subject.
    ///
    /// One per proxy rather than per subject. A three-subject group reaching one mock is one arrangement to
    /// change, and three copies of the same sentence would read as three problems.
    static func aggregateVariantUnsupportedDiagnostics(
        key: DiscoveredTestingKey,
        holdProxies: [DiscoveredScopeBoundType],
        bridgeProxies: [DiscoveredScopeBoundType],
        appSingletons: [DiscoveredBinding],
        appEdges: [BindingIdentity: [BindingIdentity]],
        coveredSeeds: Set<String>
    ) -> [Diagnostic] {
        var subjectByBareName: [String: DiscoveredScopeBoundType] = [:]
        for case .scopeBound(let type) in appSingletons { subjectByBareName[type.typeName] = type }
        let mockSlots = mockedSlots(key: key, appSingletons: appSingletons)

        var diagnostics: [Diagnostic] = []
        var reported: Set<String> = []
        // Deduplicated across the two lists: a mixed group that holds one subject and bridges another appears
        // in both, and it is still one group.
        for proxy in (holdProxies + bridgeProxies).sorted(by: { $0.typeName < $1.typeName }) {
            guard proxy.subjectCount > 1, reported.insert(proxy.typeName).inserted else { continue }
            guard
                let refusal = refusal(
                    for: proxy,
                    key: key,
                    subjectByBareName: subjectByBareName,
                    mockSlots: mockSlots,
                    appEdges: appEdges,
                    coveredSeeds: coveredSeeds
                )
            else { continue }
            diagnostics.append(
                aggregateVariantUnsupportedDiagnostic(
                    proxyTypeName: proxy.typeName,
                    subjectNames: subjectNames(of: proxy),
                    reachingSubjectName: refusal.subject,
                    slotDisplay: refusal.slot,
                    location: refusal.location
                )
            )
        }
        return diagnostics
    }

    /// Every app singleton this key substitutes, to the slot display and the `@BindType`'s own location — so
    /// the diagnostic lands on the line the author wrote rather than on a synthesised proxy.
    private static func mockedSlots(
        key: DiscoveredTestingKey,
        appSingletons: [DiscoveredBinding]
    ) -> [BindingIdentity: (slot: String, location: SourceLocation)] {
        var slots: [BindingIdentity: (slot: String, location: SourceLocation)] = [:]
        for binding in appSingletons {
            guard let match = key.substitutions.first(where: { substitutionMatches($0, binding) }) else { continue }
            slots[binding.identity] = (match.slotType ?? match.slotKey ?? binding.boundType, match.location)
        }
        return slots
    }

    /// Every subject the proxy carries, held first then bridged — what the diagnostic lists as the group.
    private static func subjectNames(of proxy: DiscoveredScopeBoundType) -> [String] {
        proxy.heldSubjectDependencies.map { seedlessBareTypeName($0.type) }
            + proxy.scopeEntryDependencies.compactMap { $0.scopeEntry.map { bareTypeName($0.subject) } }
    }

    /// Whether this group would have needed a variant at all, and on account of which subject. `nil` when no
    /// subject of it is touched by the key — a multi-subject group under a key that does not reach it is
    /// served unchanged by the variant graph and is not this diagnostic's business.
    private static func refusal(
        for proxy: DiscoveredScopeBoundType,
        key: DiscoveredTestingKey,
        subjectByBareName: [String: DiscoveredScopeBoundType],
        mockSlots: [BindingIdentity: (slot: String, location: SourceLocation)],
        appEdges: [BindingIdentity: [BindingIdentity]],
        coveredSeeds: Set<String>
    ) -> AggregateRefusal? {
        // A held subject that reaches a mock is what the seedless half would have reconstructed.
        for dependency in proxy.heldSubjectDependencies {
            let name = seedlessBareTypeName(dependency.type)
            guard let subject = subjectByBareName[name] else { continue }
            let reaches = reachable(from: [DiscoveredBinding.scopeBound(subject).identity], over: appEdges)
            guard let mock = reaches.first(where: { mockSlots[$0] != nil }), let slot = mockSlots[mock] else {
                continue
            }
            return AggregateRefusal(subject: name, slot: slot.slot, location: slot.location)
        }
        // A bridged subject whose seed this variant covers is what the seeded half would have re-emitted. Its
        // mock is request-scoped, so app-graph reachability cannot see it; covering the seed is the same test
        // `seedScopedFactoryTransforms` and `buildVariantContributorFacades` apply before re-emitting.
        for dependency in proxy.scopeEntryDependencies {
            guard let descriptor = dependency.scopeEntry, coveredSeeds.contains(descriptor.seed),
                let substitution = key.substitutions.first
            else { continue }
            return AggregateRefusal(
                subject: bareTypeName(descriptor.subject),
                slot: substitution.slotType ?? substitution.slotKey ?? substitution.mockType,
                location: substitution.location
            )
        }
        return nil
    }
}
