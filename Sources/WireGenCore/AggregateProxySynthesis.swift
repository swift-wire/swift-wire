// Aggregate contributor-proxy synthesis — one proxy over a *group* of subjects.
//
// `.contributesProxy` synthesises a proxy per subject and decides hold-vs-bridge once per proxy.
// `.contributesAggregateProxy` synthesises one per group, deciding hold-vs-bridge per *subject*, so a
// single proxy stores an app-scoped subject and bridges into a `@Scoped(seed:)` peer beside it. The
// forcing case is a framework demanding one conformer for several user types (WireOpenAPI's
// `registerHandlers`, emitted once per document). Split from `ContributorProxySynthesis` to keep both
// files within the length limit; the orchestration loop stays there.
//
// Domain-free throughout: the group key is an opaque string read off the use-site.

/// One `.contributesAggregateProxy` directive: the multibinding key, the fixed proxy type name, and the
/// identities of every subject bearing the annotation — the group the single proxy is synthesised over.
struct AggregateProxyDirective {
    let key: String
    let typeName: String
    let proxyScope: DiscoveredProxyScope
    var subjectIdentities: Set<String>
}

/// One `.contributesAggregateProxy` declaration as read off an annotation, before its use-sites are
/// partitioned into groups. A named type rather than a tuple: four members is past what a tuple carries
/// legibly (and past SwiftLint's `large_tuple`).
struct AggregateProxyCapability {
    let key: String
    let typeName: String
    let proxyScope: DiscoveredProxyScope
    let groupedByAttribute: String
}

/// Gather the aggregate directives — one per *group*, not per annotation. The group is the value of the
/// use-site argument the capability names (`groupedByAttribute`), so `@X(spec: "TaskAPI")` and
/// `@X(spec: "AdminAPI")` yield two proxies from one annotation. Subjects whose attribute omits the
/// argument share the default group, whose proxy keeps the bare `proxyTypeName`.
///
/// Grouping has to be declared rather than inferred: a spec's generated types and the controllers that
/// implement it routinely live in different modules (task-cluster defines its spec in `TaskAPI` and its
/// controllers in `TaskClusterApp`), so neither the subject's module nor the annotation alone identifies
/// the group. Keyed by `<annotation>|<group>` so two annotations can each carry their own groups.
func aggregateProxyDirectives(
    annotations: [DiscoveredAdapterAnnotation],
    useSites: [ContributionAliasUseSite]
) -> [String: AggregateProxyDirective] {
    var capabilities: [String: AggregateProxyCapability] = [:]
    for annotation in annotations {
        guard
            case .contributesAggregateProxy(let key, let typeName, let proxyScope, let attribute) =
                annotation.capability
        else { continue }
        capabilities[annotation.annotationName] = AggregateProxyCapability(
            key: key,
            typeName: typeName,
            proxyScope: proxyScope,
            groupedByAttribute: attribute
        )
    }
    guard !capabilities.isEmpty else { return [:] }

    var directives: [String: AggregateProxyDirective] = [:]
    for site in useSites {
        guard let capability = capabilities[site.annotationName] else { continue }
        // The group is the attribute's argument when it names one, and otherwise **the module the
        // annotation is written in**. That makes a bare annotation mean "the group belonging to my own
        // module", which is what an author reading the file can see — rather than "whatever the target
        // being compiled is", which they cannot: the answer would depend on which executable pulled the
        // library in, and two libraries each shipping their own bare-annotated subjects would collide on
        // one proxy. The adapter's own generator resolves the same way, so both sides agree without
        // either needing to know which module is consuming.
        let group = site.argumentValue(labelled: capability.groupedByAttribute) ?? site.originModule
        let identity = "\(site.annotationName)|\(group)"
        directives[
            identity,
            default: AggregateProxyDirective(
                key: capability.key,
                typeName: aggregateProxyTypeName(capability.typeName, group: group),
                proxyScope: capability.proxyScope,
                subjectIdentities: []
            )
        ].subjectIdentities.insert(site.targetIdentity)
    }
    return directives
}

/// `<proxyTypeName>_<group>` for a grouped aggregate, or the bare name for the default group. The group
/// is sanitised to an identifier: it reaches here from a use-site string literal, so it may hold
/// characters a type name can't.
func aggregateProxyTypeName(_ base: String, group: String?) -> String {
    guard let group, !group.isEmpty else { return base }
    let sanitised = String(group.map { $0.isLetter || $0.isNumber ? $0 : "_" })
    return "\(base)_\(sanitised)"
}

/// The single proxy binding for a group of subjects — one **labelled** dependency per subject, each
/// independently *held* (the subject stored directly) or *bridged* (a `_wireEnterScope_<Subject>` thunk),
/// exactly as `contributorProxyBinding` decides for one. Two departures from the per-subject form, both
/// forced by there being more than one subject:
///
///   • **Field names carry the subject.** A single proxy names its subject positionally (`_wireSubject`,
///     unlabelled so the graph names no member); N subjects cannot all be positional, so each is labelled
///     `_wireSubject_<Subject>` / `_wireEnterScope_<Subject>`. **At one subject the singular names are
///     kept**, so a one-member aggregate emits byte-identically to `.contributesProxy` and the existing
///     field-name contract with domain tools is untouched.
///   • **Generic parameters union.** The proxy restates every generic subject's parameters. Two subjects
///     may declare the same parameter name (both `T`), so parameters are renamed positionally on
///     collision and the renaming is applied to that subject's dependency type — the same substitution
///     `liftSpecialised` performs for lift nodes. Verified by spike-29: the graph then carries one lift
///     axis per generic subject and maps them positionally, even when it orders the axes differently.
func aggregateProxyBinding(
    for subjects: [DiscoveredScopeBoundType],
    key: String,
    typeName: String,
    proxyScope: DiscoveredProxyScope,
    yieldsBySubject: [String: [String]] = [:]
) -> DiscoveredScopeBoundType {
    let single = subjects.count == 1
    var takenParameters: Set<String> = []
    var names: [String] = []
    var constraints: [String: String] = [:]
    var whereClauses: [String] = []
    var dependencies: [DependencyParameter] = []

    for subject in subjects {
        // Rename this subject's parameters only where they collide with one already claimed by an
        // earlier subject, so the common (no-collision) case emits the subject's own spellings.
        var renaming: [String: String] = [:]
        for parameter in subject.genericParameterNames {
            var name = parameter
            var disambiguator = 2
            while takenParameters.contains(name) {
                name = "\(parameter)\(disambiguator)"
                disambiguator += 1
            }
            if name != parameter { renaming[parameter] = name }
            takenParameters.insert(name)
            names.append(name)
            if let constraint = subject.genericParameterConstraints[parameter] {
                constraints[name] = constraint
            }
        }
        if let clause = subject.genericWhereClause {
            whereClauses.append(renaming.isEmpty ? clause : substitutingIdentifierTokens(clause, renaming))
        }
        dependencies.append(
            aggregateSubjectDependency(
                for: subject,
                proxyScope: proxyScope,
                renaming: renaming,
                labelled: !single,
                yields: yieldsBySubject[subject.typeName] ?? []
            )
        )
    }

    return DiscoveredScopeBoundType(
        typeName: typeName,
        qualifiedTypeName: typeName,
        typeKind: "struct",
        genericParameterNames: names,
        genericParameterConstraints: constraints,
        genericWhereClause: whereClauses.isEmpty ? nil : whereClauses.joined(separator: ", "),
        dependencies: dependencies,
        location: subjects[0].location,
        accessLevel: subjects[0].accessLevel,
        contributions: [Contribution(keyReference: key, location: subjects[0].location)],
        originModule: subjects[0].originModule
    )
}

/// One aggregate member's dependency — hold or bridge, decided against *this* subject's own scope (the
/// per-subject property that replaces `contributorProxyBinding`'s single `subjectIsNarrower`).
func aggregateSubjectDependency(
    for subject: DiscoveredScopeBoundType,
    proxyScope: DiscoveredProxyScope,
    renaming: [String: String],
    labelled: Bool,
    yields: [String] = []
) -> DependencyParameter {
    let parameters = subject.genericParameterNames.map { renaming[$0] ?? $0 }
    let subjectType =
        parameters.isEmpty ? subject.typeName : "\(subject.typeName)<\(parameters.joined(separator: ", "))>"

    if proxyScope == .singleton, let seed = subject.scopeKey?.seed {
        // A yield is asked for on a *subject*, and each aggregate member bridges into its own scope, so
        // these are this subject's alone. A held subject has no thunk and so nothing to yield through —
        // the diagnostics say so rather than dropping the annotation silently.
        //
        // The entry struct is generic over *this member's* parameters, in their renamed form. The proxy is
        // generic over the union of every member's, and a struct declared with a parameter none of its
        // fields mention could not be inferred where the thunk constructs it.
        let descriptor = ScopeEntryDescriptor(
            seed: seed,
            subject: subjectType,
            yields: yields,
            entryStructName: scopeEntryStructName(subjectTypeName: subject.typeName),
            genericParameterNames: parameters,
            genericParameterConstraints: Dictionary(
                subject.genericParameterConstraints.map { (renaming[$0.key] ?? $0.key, $0.value) },
                uniquingKeysWith: { first, _ in first }
            ),
            genericWhereClause: subject.genericWhereClause.map {
                renaming.isEmpty ? $0 : substitutingIdentifierTokens($0, renaming)
            }
        )
        return DependencyParameter(
            name: labelled
                ? "\(contributorProxyScopeEntryFieldName)_\(subject.typeName)"
                : contributorProxyScopeEntryFieldName,
            type: descriptor.thunkType,
            kind: .scopeEntryThunk,
            location: subject.location,
            scopeEntry: descriptor
        )
    }
    return DependencyParameter(
        // A lone held subject stays positional (`_wireSubject`), matching `.contributesProxy` exactly.
        name: labelled ? "\(contributorProxySubjectFieldName)_\(subject.typeName)" : nil,
        type: subjectType,
        kind: .injectInitParameter,
        location: subject.location
    )
}
