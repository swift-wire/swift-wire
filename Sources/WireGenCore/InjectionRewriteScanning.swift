import SwiftSyntax

// Recognition and synthesis for `.rewritesInjection` annotations — the pass behind `@ConfigProperty` and
// anything shaped like it (`@Secret`, `@FeatureFlag`, `@Clock`).
//
// The annotated site stops resolving by its own type. Instead Wire synthesises a producer that asks the
// annotation's own property wrapper for the value:
//
//     private func _wireRewrite_…(_wireProvider: Configuration<String>.Provider) throws -> String {
//         try Configuration<String>.wireValue(from: _wireProvider, forKey: "couchdb.host", default: "localhost")
//     }
//
// Every part of that is derivable without knowing what the annotation *means*: the wrapper's name is the
// annotation's, the generic argument is the site's own type, and the argument list is copied **verbatim**
// after `from:`. The call is static, so the wrapper's initialisers — its *attachment* role — play no part
// in resolution, and no instance is built to hold a value it does not have. The provider's type is the one thing
// Wire cannot derive — it matches dependencies by canonical type text and cannot see through the wrapper's
// `Provider` associated type — so the adapter names it in `.rewritesInjection(provider:)`.
//
// Domain-free in the same sense as `ContributorProxySynthesis`: Wire wires a value it never inspects.

/// A `.rewritesInjection` annotation as written at an injection site.
package struct InjectionRewriteSite: Sendable, Equatable {
    /// The annotation (and so the property wrapper) name — `Configuration`.
    package let annotationName: String
    /// The argument list verbatim, without the enclosing parentheses — `forKey: "PORT", default: 8080`.
    /// Never parsed: it is spliced straight into the wrapper's initialiser call, so whatever the wrapper
    /// accepts, the annotation accepts.
    package let arguments: String

    package init(annotationName: String, arguments: String) {
        self.annotationName = annotationName
        self.arguments = arguments
    }
}

/// The `.rewritesInjection` annotation on a parameter or property, or `nil`.
///
/// `annotationNames` are the declared rewriting annotations, so an attribute is only treated as one when an
/// adapter said it is — an unknown attribute stays an ordinary attribute.
func injectionRewriteSite(
    in attributes: AttributeListSyntax,
    annotationNames: Set<String>
) -> InjectionRewriteSite? {
    for case let .attribute(attribute) in attributes {
        let name = attribute.attributeName.trimmedDescription
        guard annotationNames.contains(name) else { continue }
        guard case let .argumentList(list) = attribute.arguments else {
            // A bare `@X` carries nothing to construct the wrapper from; the wrapper decides whether an
            // empty argument list is valid by whether it has a matching initialiser.
            return InjectionRewriteSite(annotationName: name, arguments: "")
        }
        return InjectionRewriteSite(annotationName: name, arguments: list.trimmedDescription)
    }
    return nil
}

/// The names of every declared `.rewritesInjection` annotation, mapped to the provider type it reads from.
package func injectionRewriteProviders(
    _ annotations: [DiscoveredAdapterAnnotation]
) -> [String: String] {
    var providers: [String: String] = [:]
    for annotation in annotations {
        if case .rewritesInjection(let provider) = annotation.capability {
            providers[annotation.annotationName] = provider
        }
    }
    return providers
}

/// One synthesised rewrite producer — the binding a rewritten site resolves to.
package struct SynthesizedInjectionRewrite: Sendable {
    /// The generated function's name, and so the binding's access path.
    package let functionName: String
    /// The value type it produces — the annotated site's own type.
    package let valueType: String
    /// The provider it depends on, as the adapter named it.
    package let providerType: String
    /// The key the binding is registered under, so two sites with the same annotation arguments and type
    /// share one binding and different ones stay distinct.
    package let keyIdentifier: String
    /// The whole declaration, ready to emit.
    package let declaration: String
}

/// Rewrite every annotated injection site: synthesise one producer per distinct
/// (annotation, arguments, type) and re-point the site's dependency at it.
///
/// Deduplication is by that triple, so the same `@ConfigProperty(forKey: "PORT", default: 8080) port: Int`
/// written at three sites yields one binding read once, while a different key — or the same key at a
/// different type — is a different binding.
package func applyInjectionRewrites(
    to allBindings: [Partition: [DiscoveredBinding]],
    annotations: [DiscoveredAdapterAnnotation],
    consumerModule: String
) -> (bindings: [Partition: [DiscoveredBinding]], synthesized: [SynthesizedInjectionRewrite]) {
    let providers = injectionRewriteProviders(annotations)
    guard !providers.isEmpty else { return (allBindings, []) }

    var synthesized: [String: SynthesizedInjectionRewrite] = [:]
    var result = allBindings
    for (partition, bindings) in allBindings {
        result[partition] = bindings.map { binding in
            rewriting(binding, providers: providers, into: &synthesized, module: consumerModule)
        }
    }
    // The synthesised producers are app-scope bindings: they depend only on the provider, so they belong
    // wherever it does, and a scoped consumer borrows them like any other singleton.
    let ordered = synthesized.values.sorted { $0.functionName < $1.functionName }
    for rewrite in ordered {
        result[.default, default: []].append(
            .provider(
                DiscoveredProvider(
                    boundType: rewrite.valueType,
                    accessPath: rewrite.functionName,
                    form: .function,
                    dependencies: [
                        DependencyParameter(
                            name: "_wireProvider",
                            type: rewrite.providerType,
                            kind: .injectInitParameter,
                            location: SourceLocation(file: "<synthetic>", line: 0, column: 0)
                        )
                    ],
                    genericParameterNames: [],
                    location: SourceLocation(file: "<synthetic>", line: 0, column: 0),
                    keyIdentifier: rewrite.keyIdentifier,
                    isThrowing: true,
                    originModule: consumerModule
                )
            )
        )
    }
    return (result, ordered)
}

/// Re-point one binding's rewritten dependencies, recording the producers they need.
private func rewriting(
    _ binding: DiscoveredBinding,
    providers: [String: String],
    into synthesized: inout [String: SynthesizedInjectionRewrite],
    module: String
) -> DiscoveredBinding {
    func rewritten(_ dependency: DependencyParameter) -> DependencyParameter {
        guard let site = dependency.injectionRewrite,
            let provider = providers[site.annotationName]
        else { return dependency }
        let rewrite = record(site, valueType: dependency.type, provider: provider, into: &synthesized)
        // The site now resolves to the synthesised producer: same type, but keyed to it, so it cannot
        // collide with an ordinary binding of that type (a plain `String` binding stays reachable).
        return DependencyParameter(
            name: dependency.name,
            type: dependency.type,
            kind: dependency.kind,
            location: dependency.location,
            keyIdentifier: rewrite.keyIdentifier
        )
    }
    switch binding {
    case .provider(let provider):
        guard provider.dependencies.contains(where: { $0.injectionRewrite != nil }) else { return binding }
        return .provider(provider.replacingDependencies(provider.dependencies.map(rewritten)))
    case .scopeBound(let scopeBound):
        let hasRewrite =
            scopeBound.dependencies.contains { $0.injectionRewrite != nil }
            || scopeBound.memberInjections.contains { $0.parameters.contains { $0.injectionRewrite != nil } }
        guard hasRewrite else { return binding }
        return .scopeBound(
            scopeBound.replacingDependencies(
                scopeBound.dependencies.map(rewritten),
                memberInjections: scopeBound.memberInjections.map { injection in
                    injection.replacingParameters(injection.parameters.map(rewritten))
                }
            )
        )
    case .aggregate:
        return binding
    }
}

/// Record the producer a site needs, deduplicating by (annotation, arguments, type).
private func record(
    _ site: InjectionRewriteSite,
    valueType: String,
    provider: String,
    into synthesized: inout [String: SynthesizedInjectionRewrite]
) -> SynthesizedInjectionRewrite {
    let identity = "\(site.annotationName)|\(site.arguments)|\(canonicalTypeName(valueType))"
    if let existing = synthesized[identity] { return existing }
    let suffix = sanitizeIdentifier("\(site.annotationName)_\(canonicalTypeName(valueType))_\(site.arguments)")
    let functionName = "_wireRewrite_\(suffix)"
    // The wrapper is constructed exactly as written at the site and asked for the value. Wire supplies the
    // wrapper name, the site's type, and the provider parameter; the argument list is the user's, verbatim.
    let wrapper = "\(site.annotationName)<\(valueType)>"
    // A *static* call: the wrapper's initialisers are its attachment role and play no part here, so no
    // instance is constructed to resolve. `from:` leads; the annotation's own arguments follow verbatim.
    let arguments = site.arguments.isEmpty ? "" : ", \(site.arguments)"
    let declaration = """
        private func \(functionName)(_wireProvider: \(provider)) throws -> \(valueType) {
            try \(wrapper).wireValue(from: _wireProvider\(arguments))
        }
        """
    let rewrite = SynthesizedInjectionRewrite(
        functionName: functionName,
        valueType: valueType,
        providerType: provider,
        // A generated key, so the binding is addressable and deduplicated without colliding with any
        // user key: keys are matched by canonical text, and no user writes this one.
        keyIdentifier: "_wireRewriteKey_\(suffix)",
        declaration: declaration
    )
    synthesized[identity] = rewrite
    return rewrite
}
