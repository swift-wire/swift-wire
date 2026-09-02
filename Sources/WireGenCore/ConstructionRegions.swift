// M7c.4 — how much of one graph the task group spans.
//
// M7c.3 decided *whether* a graph is scheduled and said nothing about how much of it is, so the answer it
// inherited was "all of it": every binding got a cell, an `add` and an `update` arm. The argument M7c.3
// made for the trigger runs one level down and had never been applied there — a group only pays where two
// async bindings can overlap, and inside a scheduled graph a binding that cannot overlap with anything
// gains nothing from a cell either. Measured on the integration corpus, the region that can overlap is
// **four bindings out of a hundred and ten**.
//
// So a graph splits three ways, and both boundaries come out of the dependency order rather than out of
// any model of what runs when. `Documentation/Notes/ConstructionScheduling.md` § "The scheduled region"
// carries the reasoning and the measurements; this file computes it.

/// One graph's construction plan: which bindings are built serially before the group, which are scheduled
/// in it, and which are built serially after it.
///
/// The three partition the topological order, and each keeps that order internally. Two closure properties
/// are what let the emitted body stay one shape — chain, group, chain — rather than interleaving:
///
/// - **`prefix` is downward-closed.** If a binding has no Overlap ancestor then neither does any of its
///   own dependencies, so the prefix is a valid topological head and can be built first, whole.
/// - **`suffix` is upward-closed.** If a binding waits on *all* of Overlap then so does everything
///   downstream of it, so nothing in the group can depend on a suffix binding.
///
/// Both hold under *construction* edges. Member-injection parameters are deliberately not construction
/// edges (`Graph.swift`: "post-init delivery, so excluded from graph edges. Cycle through these is
/// legal"), which is the whole point of `@Inject weak var` — so an injection reads across regions in
/// either direction, and the injection block stays where it already is, after everything is constructed.
struct ConstructionRegions {
    /// Built serially, before the group opens. May contain **async** bindings: a source everything else
    /// waits on is serial by definition, and putting it in the group would buy a child task the parent
    /// immediately blocks on.
    let prefix: [DiscoveredBinding]
    /// Scheduled: a cell each, an `add` each, and a task for each that suspends.
    let group: [DiscoveredBinding]
    /// Built serially, after the group has drained and its cells have become locals again.
    let suffix: [DiscoveredBinding]
    /// The prefix bindings a group binding reads — the only values that cross the seam.
    ///
    /// They cannot be locals as far as the building struct is concerned (its methods cannot see the
    /// bootstrap frame), so each becomes a plain stored property on it, handed over at its
    /// initialiser. Not a cell: it is already constructed, and a cell would only add a state transition
    /// that can never fail.
    let frontier: [DiscoveredBinding]
}

/// Split a graph into prefix / group / suffix, or answer `nil` when there is nothing to schedule.
///
/// **Overlap** — the async bindings with at least one *independent* async partner — is the seed, and it is
/// the same set M7c.3's trigger turns on. An async binding comparable with every other async binding never
/// runs beside anything, so it is not a reason to open a group.
///
/// - `prefix` — no Overlap ancestor, and not in Overlap.
/// - `suffix` — waits on *every* member of Overlap; strictly serial, since nothing is still outstanding by
///   the time one of these can start.
/// - `group` — the rest: Overlap, plus the descendants that can begin while some other branch is still in
///   flight, which is exactly the population the cascade exists for.
func constructionRegions(for topologicalOrder: [DiscoveredBinding]) -> ConstructionRegions? {
    let edges = constructionEdges(in: topologicalOrder)
    guard let overlap = overlappingAsyncBindings(in: topologicalOrder, edges: edges) else { return nil }

    // Which members of Overlap each binding transitively waits on. One pass, in topological order, so a
    // binding's producers are always already folded.
    var awaited: [String: Set<String>] = [:]
    for binding in topologicalOrder {
        let name = propertyName(for: binding)
        var accumulated: Set<String> = []
        for producer in edges.producers[name] ?? [] {
            accumulated.formUnion(awaited[producer] ?? [])
            if overlap.contains(producer) { accumulated.insert(producer) }
        }
        awaited[name] = accumulated
    }

    var prefix: [DiscoveredBinding] = []
    var group: [DiscoveredBinding] = []
    var suffix: [DiscoveredBinding] = []
    for binding in topologicalOrder {
        let name = propertyName(for: binding)
        let waitsOn = awaited[name] ?? []
        if overlap.contains(name) {
            group.append(binding)
        } else if waitsOn.isEmpty {
            prefix.append(binding)
        } else if waitsOn == overlap {
            suffix.append(binding)
        } else {
            group.append(binding)
        }
    }

    let groupNames = Set(group.map { propertyName(for: $0) })
    var crossing: Set<String> = []
    for binding in group {
        for local in constructionDependencyLocals(of: binding)
        where edges.names.contains(local) && !groupNames.contains(local) {
            crossing.insert(local)
        }
    }
    return ConstructionRegions(
        prefix: prefix,
        group: group,
        suffix: suffix,
        frontier: prefix.filter { crossing.contains(propertyName(for: $0)) }
    )
}

/// The graph's construction edges in both directions, keyed by property name — the same local names the
/// construction expressions reference, so nothing here can disagree with what the emitter renders.
private struct ConstructionEdges {
    let names: Set<String>
    /// Consumer → the bindings it reads.
    let producers: [String: [String]]
    /// Producer → the bindings that read it.
    let consumers: [String: [String]]
}

private func constructionEdges(in topologicalOrder: [DiscoveredBinding]) -> ConstructionEdges {
    let names = Set(topologicalOrder.map { propertyName(for: $0) })
    var producers: [String: [String]] = [:]
    var consumers: [String: [String]] = [:]
    for binding in topologicalOrder {
        let consumer = propertyName(for: binding)
        for local in Set(constructionDependencyLocals(of: binding)) where names.contains(local) {
            producers[consumer, default: []].append(local)
            consumers[local, default: []].append(consumer)
        }
    }
    return ConstructionEdges(names: names, producers: producers, consumers: consumers)
}

/// The async bindings with at least one *independent* async partner, or `nil` when there are none — which
/// is the whole of the between-graphs trigger. An async binding comparable with every other async binding
/// never runs beside anything, so it is not a reason to open a group.
private func overlappingAsyncBindings(
    in topologicalOrder: [DiscoveredBinding],
    edges: ConstructionEdges
) -> Set<String>? {
    let asyncNames = topologicalOrder.filter(bindingIsAsync).map { propertyName(for: $0) }
    guard asyncNames.count >= 2 else { return nil }

    // Downstream closure of each async binding, so "independent" is decidable both ways.
    var downstream: [String: Set<String>] = [:]
    for source in asyncNames {
        var reached: Set<String> = []
        var stack = edges.consumers[source] ?? []
        while let next = stack.popLast() {
            guard reached.insert(next).inserted else { continue }
            stack.append(contentsOf: edges.consumers[next] ?? [])
        }
        downstream[source] = reached
    }

    var overlap: Set<String> = []
    for (index, first) in asyncNames.enumerated() {
        for second in asyncNames[(index + 1)...]
        where !(downstream[first]?.contains(second) ?? false)
            && !(downstream[second]?.contains(first) ?? false)
        {
            overlap.insert(first)
            overlap.insert(second)
        }
    }
    return overlap.isEmpty ? nil : overlap
}
