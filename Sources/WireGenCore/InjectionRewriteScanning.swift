// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

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

/// The declaration every synthesised producer routes its adapter call through — emitted once into the
/// generated file when the module has any injection rewrite, and `private` because nothing outside that
/// file names it.
///
/// It exists to make one emission correct for a throwing and a non-throwing adapter alike; see the note on
/// the producer's own `try`. `@autoclosure` is what carries the callee's effect to the call site: a
/// throwing argument expression is covered by the caller's `try`, and this function's own `throws` covers
/// the case where the argument throws nothing.
package let injectionRewriteHelperDeclaration = """
    private func _wireRewritten<Value>(_ value: @autoclosure () throws -> Value) throws -> Value {
        try value()
    }
    """

/// A `.rewritesInjection` annotation as written at an injection site.
package struct InjectionRewriteSite: Sendable, Equatable {
    /// One argument as written — `forKey: "PORT"` is `(label: "forKey", text: "\"PORT\"")`.
    ///
    /// Kept split by label only so a declared *selector* can be lifted out by name; the text itself is
    /// never interpreted. Everything else about the list is still verbatim.
    package struct Argument: Sendable, Equatable {
        package let label: String?
        package let text: String

        package init(label: String?, text: String) {
            self.label = label
            self.text = text
        }
    }

    /// The annotation (and so the property wrapper) name — `ConfigProperty`.
    package let annotationName: String
    /// The argument list, without the enclosing parentheses. Spliced back into the wrapper's `wireValue`
    /// call as written, so whatever the wrapper accepts, the annotation accepts.
    package let arguments: [Argument]

    package init(annotationName: String, arguments: [Argument]) {
        self.annotationName = annotationName
        self.arguments = arguments
    }

    /// The arguments rendered back to source, minus the one labelled `selectorLabel` if the adapter
    /// declared one — what gets spliced after `from:`.
    ///
    /// Returns the selector's own text separately: it keys the synthesised producer's dependency on the
    /// provider instead of being passed along, since by resolution time the provider is already resolved.
    func splittingSelector(labelled selectorLabel: String?) -> (providerKey: String?, rendered: String) {
        guard let selectorLabel else { return (nil, render(arguments)) }
        guard let index = arguments.firstIndex(where: { $0.label == selectorLabel }) else {
            return (nil, render(arguments))
        }
        var remaining = arguments
        let selector = remaining.remove(at: index)
        return (selector.text, render(remaining))
    }

    private func render(_ arguments: [Argument]) -> String {
        arguments.map { argument in
            argument.label.map { "\($0): \(argument.text)" } ?? argument.text
        }
        .joined(separator: ", ")
    }
}

/// What a declared `.rewritesInjection` annotation reads from.
package struct InjectionRewriteProvider: Sendable, Equatable {
    /// The provider type as the adapter named it — `"ConfigReader"`.
    package let type: String
    /// The argument label naming which provider binding to read from, or `nil` if the adapter did not
    /// opt into selection.
    package let selectorLabel: String?
}

/// Every declared `.rewritesInjection` annotation, mapped to what it reads from.
package func injectionRewriteProviders(
    _ annotations: [DiscoveredAdapterAnnotation]
) -> [String: InjectionRewriteProvider] {
    var providers: [String: InjectionRewriteProvider] = [:]
    for annotation in annotations {
        if case .rewritesInjection(let provider, let selectorLabel) = annotation.capability {
            providers[annotation.annotationName] = InjectionRewriteProvider(
                type: provider,
                selectorLabel: selectorLabel
            )
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
    /// The key naming *which* provider binding to read from, or `nil` to resolve it by type.
    package let providerKey: String?
    /// A real annotated site this producer was synthesised for — the first one, since the rest
    /// deduplicated into it. Carried so a diagnostic about the provider (an undeclared selector key, an
    /// unbound provider) anchors at source a user wrote rather than at the synthesised dependency.
    package let location: SourceLocation
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
                            location: rewrite.location,
                            keyIdentifier: rewrite.providerKey
                        )
                    ],
                    genericParameterNames: [],
                    location: rewrite.location,
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
    providers: [String: InjectionRewriteProvider],
    into synthesized: inout [String: SynthesizedInjectionRewrite],
    module: String
) -> DiscoveredBinding {
    func rewritten(_ dependency: DependencyParameter) -> DependencyParameter {
        guard let site = dependency.injectionRewrite,
            let provider = providers[site.annotationName]
        else { return dependency }
        let rewrite = record(
            site,
            valueType: dependency.type,
            provider: provider,
            location: dependency.location,
            into: &synthesized
        )
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
    provider: InjectionRewriteProvider,
    location: SourceLocation,
    into synthesized: inout [String: SynthesizedInjectionRewrite]
) -> SynthesizedInjectionRewrite {
    // The selector leaves the argument list here and becomes the provider dependency's key. It stays in
    // the identity: two sites reading the *same* key at the same type from *different* providers are
    // different bindings, and collapsing them would silently read one value for both.
    let (providerKey, arguments) = site.splittingSelector(labelled: provider.selectorLabel)
    let identity =
        "\(site.annotationName)|\(providerKey ?? "")|\(arguments)|\(canonicalTypeName(valueType))"
    if let existing = synthesized[identity] { return existing }
    // The selector contributes a name segment only when written, so a site that does not select one keeps
    // the name it had before selectors existed rather than gaining an empty `__` segment.
    let selected = providerKey.map { "_\($0)" } ?? ""
    let suffix = sanitizeIdentifier(
        "\(site.annotationName)_\(canonicalTypeName(valueType))\(selected)_\(arguments)"
    )
    let functionName = "_wireRewrite_\(suffix)"
    // The wrapper is constructed exactly as written at the site and asked for the value. Wire supplies the
    // wrapper name, the site's type, and the provider parameter; the argument list is the user's, verbatim.
    let wrapper = "\(site.annotationName)<\(valueType)>"
    // A *static* call: the wrapper's initialisers are its attachment role and play no part here, so no
    // instance is constructed to resolve. `from:` leads; the annotation's own arguments follow verbatim.
    let spliced = arguments.isEmpty ? "" : ", \(arguments)"
    // `try _wireRewritten(...)` rather than a bare `try` on the call: whether the adapter's `wireValue`
    // throws is not something Wire can see. It is a static method in another module, chosen by overload
    // resolution over the argument list Wire copied without reading — wire-configuration's `default:`
    // overloads do not throw while its required ones do, so the effect differs *between two sites of the
    // same annotation*. Emitting a bare `try` was therefore right about half the time and an
    // `UnnecessaryEffectMarker` warning the rest, in a file the consumer cannot edit. Routed through an
    // always-throwing `@autoclosure`, one spelling is correct either way: a throwing call is covered by the
    // `try`, and a non-throwing one is covered by `_wireRewritten` itself.
    let declaration = """
        private func \(functionName)(_wireProvider: \(provider.type)) throws -> \(valueType) {
            try _wireRewritten(\(wrapper).wireValue(from: _wireProvider\(spliced)))
        }
        """
    let rewrite = SynthesizedInjectionRewrite(
        functionName: functionName,
        valueType: valueType,
        providerType: provider.type,
        // A generated key, so the binding is addressable and deduplicated without colliding with any
        // user key: keys are matched by canonical text, and no user writes this one.
        keyIdentifier: "_wireRewriteKey_\(suffix)",
        providerKey: providerKey,
        location: location,
        declaration: declaration
    )
    synthesized[identity] = rewrite
    return rewrite
}
