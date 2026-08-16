// Contributor-proxy synthesis — the plugin half of the contributor proxy (M5.3, 3.1c).
//
// An adapter annotation declaring `.contributesProxy(to: key, proxyTypePrefix: prefix)` (e.g. WireMVC's
// `@Controller`) does NOT contribute the annotated binding itself. Its macro generates a peer type
// `<prefix><Binding>` that holds the binding (constructed its ordinary way) plus any factories the
// binding's input-edge use-sites demand, conforms to the adapter's contributor protocol, and carries
// the adapter's witness. This pass synthesises that proxy's *binding*: a scope-bound type depending on
// the subject binding — and, after the factory pass runs, on the demanded factories — that contributes
// to the key in the subject's place. The subject stays a plain, footgun-free binding.
//
// The proxy is generic exactly when the subject is: it restates the subject's generic parameters and
// depends on `Subject<Params>`, which threads the graph's lift parameter transitively (see
// `undeterminedGenericParameters` / `bridgedDependencyIdentity`).
//
// Domain-free: Wire wraps a binding in a synthesised contributor; it never learns what the binding is.

/// Synthesise a contributor proxy beside each `.contributesProxy` binding and re-attribute that
/// binding's input-edge use-sites (factory / dependency) onto the proxy, so the later factory and
/// adapter-dependency passes land those edges on the proxy — the type they are lifted onto — rather
/// than the now-plain subject. Returns the updated bindings and use-sites; runs after alias
/// contributions and before adapter-dependency / factory synthesis.
package func applyContributorProxies(
    to allBindings: [Partition: [DiscoveredBinding]],
    annotations: [DiscoveredAdapterAnnotation],
    useSites: [ContributionAliasUseSite]
) -> (
    bindings: [Partition: [DiscoveredBinding]],
    useSites: [ContributionAliasUseSite],
    proxyIdentities: Set<String>
) {
    let directiveBySubject = contributorProxyDirectives(annotations: annotations, useSites: useSites)
    let aggregates = aggregateProxyDirectives(annotations: annotations, useSites: useSites)
    guard !directiveBySubject.isEmpty || !aggregates.isEmpty else { return (allBindings, useSites, []) }

    // Synthesise a proxy beside each proxied subject, recording subject identity → proxy identity. The
    // proxy is placed in the partition of its declared `proxyScope`, which is where its collated
    // multibinding aggregates and where it is registered — NOT necessarily the subject's partition. A
    // `.singleton` proxy over a `@Scoped` subject (a bridge) therefore leaves the subject's seeded
    // partition and joins this container's app (scope-nil) partition; the subject stays where it is.
    var proxyBySubject: [String: String] = [:]
    var result = allBindings
    for (partition, bindings) in allBindings {
        for binding in bindings {
            guard case .scopeBound(let subject) = binding,
                let identity = binding.aliasTargetIdentity,
                let directive = directiveBySubject[identity]
            else { continue }
            let proxy = contributorProxyBinding(
                for: subject,
                key: directive.key,
                prefix: directive.prefix,
                proxyScope: directive.proxyScope
            )
            proxyBySubject[identity] = proxy.qualifiedTypeName
            let target = proxyPartition(directive.proxyScope, subjectPartition: partition)
            result[target, default: []].append(.scopeBound(proxy))
        }
    }

    // Aggregates: one proxy per *group*, holding every subject in it. Unlike the per-subject
    // loop above, hold-vs-bridge is decided per subject, so one aggregate can store an app-scoped subject
    // directly and carry a scope-entry thunk for a `@Scoped(seed:)` peer. Subjects are gathered across
    // partitions (an app subject and a seeded subject live in different ones) and ordered deterministically
    // by type name so emission is stable.
    for (_, aggregate) in aggregates.sorted(by: { $0.value.typeName < $1.value.typeName }) {
        var subjects: [AggregateSubject] = []
        for (partition, bindings) in allBindings {
            for binding in bindings {
                guard case .scopeBound(let subject) = binding,
                    let identity = binding.aliasTargetIdentity,
                    aggregate.subjectIdentities.contains(identity)
                else { continue }
                subjects.append(AggregateSubject(subject: subject, identity: identity, partition: partition))
            }
        }
        guard !subjects.isEmpty else { continue }
        subjects.sort { $0.subject.typeName < $1.subject.typeName }

        let proxy = aggregateProxyBinding(
            for: subjects.map(\.subject),
            key: aggregate.key,
            typeName: aggregate.typeName,
            proxyScope: aggregate.proxyScope
        )
        for entry in subjects {
            proxyBySubject[entry.identity] = proxy.qualifiedTypeName
        }
        // Every subject's input edges lift onto the one aggregate, so it is placed once, in the app
        // partition of the container the subjects share.
        let target = proxyPartition(aggregate.proxyScope, subjectPartition: subjects[0].partition)
        result[target, default: []].append(.scopeBound(proxy))
    }

    let reattributed = reattributingInputEdges(useSites, toProxies: proxyBySubject, annotations: annotations)
    // The qualified names of the proxies synthesised here — the plugin renders each one's *structural*
    // declaration (`renderContributorProxyDeclaration`) into the consumer graph file, since Phase A moves
    // proxy-type emission out of the adapter macro and into the plugin.
    return (result, reattributed, Set(proxyBySubject.values))
}

/// One aggregate member as gathered from the graph: the subject, the identity its use-sites match on,
/// and the partition it was found in (which locates the proxy). A named type rather than a tuple —
/// three members is past what reads legibly, and past SwiftLint's `large_tuple`.
private struct AggregateSubject {
    let subject: DiscoveredScopeBoundType
    let identity: String
    let partition: Partition
}

/// The partition a contributor proxy is placed in, derived from its `proxyScope`. `.singleton` → the
/// app (scope-nil) partition of the subject's container: a bridge proxy leaves the subject's seeded
/// partition and joins the app graph, where its route-contributor collation aggregates and where it is
/// applied once at bootstrap.
private func proxyPartition(_ proxyScope: DiscoveredProxyScope, subjectPartition: Partition) -> Partition {
    switch proxyScope {
    case .singleton: return Partition(container: subjectPartition.container, scope: nil)
    }
}

/// Map each proxied subject's identity to the proxy directive (multibinding key + type-name prefix) it
/// carries, reading the `.contributesProxy` annotations' use-sites. Empty when nothing requests a proxy
/// — the pass then no-ops.
private func contributorProxyDirectives(
    annotations: [DiscoveredAdapterAnnotation],
    useSites: [ContributionAliasUseSite]
) -> [String: (key: String?, prefix: String, proxyScope: DiscoveredProxyScope)] {
    // `key == nil` is a `.liftsPeersToProxy` directive: synthesise + reattribute exactly like
    // `.contributesProxy`, but contribute to no multibinding (a standalone, addressable proxy).
    var proxyAnnotations: [String: (key: String?, prefix: String, proxyScope: DiscoveredProxyScope)] = [:]
    for annotation in annotations {
        switch annotation.capability {
        case .contributesProxy(let key, let prefix, let proxyScope):
            proxyAnnotations[annotation.annotationName] = (key, prefix, proxyScope)
        case .liftsPeersToProxy(let prefix, let proxyScope):
            proxyAnnotations[annotation.annotationName] = (nil, prefix, proxyScope)
        default:
            break
        }
    }
    var directiveBySubject: [String: (key: String?, prefix: String, proxyScope: DiscoveredProxyScope)] = [:]
    for site in useSites {
        if let directive = proxyAnnotations[site.annotationName] {
            directiveBySubject[site.targetIdentity] = directive  // first-seen wins
        }
    }
    return directiveBySubject
}

/// Re-point each input-edge (factory / dependency) use-site sitting on a proxied subject at that
/// subject's proxy, so the factory and adapter-dependency passes land the edge on the proxy — the type
/// they are lifted onto. Other use-sites (and the inert proxy-annotation site itself) pass through
/// unchanged.
private func reattributingInputEdges(
    _ useSites: [ContributionAliasUseSite],
    toProxies proxyBySubject: [String: String],
    annotations: [DiscoveredAdapterAnnotation]
) -> [ContributionAliasUseSite] {
    let inputEdgeAnnotations = Set(
        annotations
            .filter { $0.capability == .injectsFromGraph }
            .map(\.annotationName)
    )
    return useSites.map { site in
        guard inputEdgeAnnotations.contains(site.annotationName),
            let proxyIdentity = proxyBySubject[site.targetIdentity]
        else { return site }
        return ContributionAliasUseSite(
            annotationName: site.annotationName,
            targetIdentity: proxyIdentity,
            argument: site.argument,
            arguments: site.arguments,
            location: site.location,
            originModule: site.originModule
        )
    }
}

/// The proxy binding for one `.contributesProxy` subject — a scope-bound `<prefix><Subject>` generic
/// exactly as the subject is, contributing to the directive's key. The proxy lives at `proxyScope`
/// (always `.singleton` today — collated into the app graph), and swift-wire compares that against the
/// subject's own scope to pick the proxy's primary dependency:
///   • **hold** (subject at the proxy's scope — a `@Singleton` subject under a `.singleton` proxy): the
///     subject is the proxy's first, **unlabelled** dependency (`_wireSubject`), so Wire names no member;
///   • **bridge** (subject narrower — a `@Scoped(seed:)` subject under a `.singleton` proxy): storing the
///     seeded subject on an app-scoped proxy would be the cross-scope violation the bridge resolves, so
///     instead of the subject the proxy takes a **labelled** scope-entry thunk `(Seed) async throws ->
///     Subject` (`_wireEnterScope`) that constructs the subject fresh per request. Its producer is
///     synthesised in M5.4.2; here we emit the field/dependency.
/// Either way the demanded factory dependencies are appended later by the factory-synthesis pass.
func contributorProxyBinding(
    for subject: DiscoveredScopeBoundType,
    key: String?,
    prefix: String,
    proxyScope: DiscoveredProxyScope,
    doubles: String? = nil
) -> DiscoveredScopeBoundType {
    let subjectDependencyType =
        subject.genericParameterNames.isEmpty
        ? subject.typeName
        : "\(subject.typeName)<\(subject.genericParameterNames.joined(separator: ", "))>"

    // A `.singleton` proxy over a seeded (`@Scoped`) subject bridges; over a `@Singleton` subject it
    // holds. `subject.scopeKey == nil` means `@Singleton`. (Only `.singleton` proxyScope exists today;
    // the comparison is written against it so a future seeded proxy scope slots in.)
    let subjectIsNarrower = proxyScope == .singleton && subject.scopeKey != nil
    let primaryDependency: DependencyParameter
    if subjectIsNarrower, let seed = subject.scopeKey?.seed {
        primaryDependency = DependencyParameter(
            name: contributorProxyScopeEntryFieldName,  // labelled — stored/inited as `_wireEnterScope`
            // A test-graph variant threads its `_<Key>Doubles` in alongside the seed, so the thunk (and
            // this field) takes `(Seed, Doubles)`; `doubles == nil` is the production proxy (seed only).
            type: contributorScopeEntryThunkType(seed: seed, subject: subjectDependencyType, doubles: doubles),
            // Emission-only: emitted as the proxy's `_wireEnterScope` field/arg, but not graph-resolved
            // (synthesised inline as the capturing thunk). Ordering comes from `.scopeCapture` deps the
            // linking pass adds.
            kind: .scopeEntryThunk,
            location: subject.location
        )
    } else {
        primaryDependency = DependencyParameter(
            name: nil,  // positional — the proxy's initialiser takes the subject unlabelled
            type: subjectDependencyType,
            kind: .injectInitParameter,
            location: subject.location
        )
    }

    return DiscoveredScopeBoundType(
        typeName: prefix + subject.typeName,
        qualifiedTypeName: prefix + subject.qualifiedTypeName,
        typeKind: "struct",
        genericParameterNames: subject.genericParameterNames,
        genericParameterConstraints: subject.genericParameterConstraints,
        // Restated on the emitted proxy struct (generic exactly as the subject) so a
        // `where`-constrained subject's proxy still type-checks. See `renderContributorProxyDeclaration`.
        genericWhereClause: subject.genericWhereClause,
        dependencies: [primaryDependency],
        location: subject.location,
        accessLevel: subject.accessLevel,
        // A `.liftsPeersToProxy` proxy (key == nil) contributes to nothing — a standalone addressable
        // binding the adapter's codegen reads directly.
        contributions: key.map { [Contribution(keyReference: $0, location: subject.location)] } ?? [],
        // A synthesised proxy is never a user declaration, so a dead-binding warning about it can only
        // mislead: it is anchored at the *subject's* location, so it reads as "your type is unused" about
        // a type the user did not write and cannot annotate. A keyless (`.liftsPeersToProxy`) proxy is
        // exactly the case that warns — its consumer is the adapter's generated code, which Wire never
        // sees — while a keyed proxy escapes only incidentally, via its contribution. Exempting both
        // states the rule once. The *subject* is still checked normally, so a genuinely unused type is
        // still reported.
        allowUnused: true,
        originModule: subject.originModule
    )
}
