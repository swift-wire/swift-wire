import SwiftSyntax

// `@Provides` extraction — the producer half of discovery, split out of `BindingDiscovery.swift` (which was
// at its length budget). A `@Provides` property or function is a binding in its own right, captured with
// its access path rather than a type name, which is what separates it from the scope-bound path next door.

extension BindingDiscovery {
    func extractProvidesProperty(_ node: VariableDeclSyntax) {
        // Multi-binding declarations (`let a = 1, b = 2`) are skipped:
        // they're a rare style and supporting them complicates the
        // `accessPath` story for no real-world gain.
        guard node.bindings.count == 1, let binding = node.bindings.first else { return }
        guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { return }

        guard let boundType = providesPropertyBoundType(binding) else {
            // Can't determine the bound type without running type
            // inference. Skip silently — same posture as `@Inject`
            // properties without annotations.
            return
        }

        let propertyName = pattern.identifier.text
        let accessPath = (scopes.map(\.typeName) + [propertyName]).joined(separator: ".")
        recordAdapterUseSites(targetIdentity: accessPath, attributes: node.attributes)
        let providesAttribute = attribute(in: node.attributes, named: "Provides")
        let key = providesAttribute.flatMap { keyIdentifier(from: $0) }
        let scopeKey = scopes.last?.seedScope
        let providerLocation = location(of: pattern.identifier)
        // Computed properties (`@Provides var x: T { get async throws { … } }`)
        // can carry effect specifiers on the `get` accessor. Stored
        // `@Provides let` bindings can't, so the flags stay `false`
        // for those.
        let propertyEffects = computedPropertyEffectFlags(binding)
        let providerAccess = accessLevel(from: node.modifiers)
        if let diagnostic = declarationTooPrivateDiagnostic(
            surfaceLabel: "@Provides declaration",
            name: propertyName,
            ownAccess: providerAccess,
            enclosing: scopes.map { ($0.typeName, $0.access) },
            location: providerLocation
        ) {
            warnings.append(diagnostic)
        }
        let teardown = providerTeardownAction(
            in: node.attributes,
            sourcePath: sourcePath,
            converter: converter
        )
        warnings.append(contentsOf: teardown.diagnostics)
        record(
            .provider(
                DiscoveredProvider(
                    boundType: boundType,
                    accessPath: accessPath,
                    form: .property,
                    dependencies: [],
                    genericParameterNames: [],
                    location: providerLocation,
                    keyIdentifier: key,
                    isAsync: propertyEffects.isAsync,
                    isThrowing: propertyEffects.isThrowing,
                    accessLevel: providerAccess,
                    scopeKey: scopeKey,
                    contributions: contributions(
                        in: node.attributes,
                        sourcePath: sourcePath,
                        converter: converter
                    ),
                    allowUnused: providesAttribute.map { allowUnusedFlag(from: $0) } ?? false,
                    teardown: teardown.action,
                    isReplacer: hasReplacesMarker(in: node.attributes),
                    originModule: module
                )
            )
        )
        unannotatedExtensionProvides.append(
            contentsOf: unannotatedExtensionProvidesCandidates(
                providerName: propertyName,
                location: providerLocation,
                extendedType: scopes.last?.unannotatedExtensionTarget
            )
        )
    }

    func extractProvidesFunction(_ node: FunctionDeclSyntax) {
        guard let returnClause = node.signature.returnClause else {
            // Void-returning `@Provides func` produces nothing
            // injectable. Silently skip.
            return
        }
        let functionName = node.name.text
        let accessPath = (scopes.map(\.typeName) + [functionName]).joined(separator: ".")
        recordAdapterUseSites(targetIdentity: accessPath, attributes: node.attributes)
        let dependencies = node.signature.parameterClause.parameters.map { parameter in
            // Per-parameter `@Bind(<key>)` lets a consumer name the keyed
            // binding it wants (`@Inject` is a peer macro, so it can't
            // attach to a parameter). A bare parameter (no attribute) is
            // an unkeyed dep, resolved by type — the common case, since
            // `@Provides func` parameters are implicitly deps.
            let parameterKey = parameterKeyIdentifier(from: parameter)
            return DependencyParameter(
                name: parameterName(parameter),
                type: parameter.type.trimmedDescription,
                kind: .providerFunctionParameter,
                location: location(of: parameter.firstName),
                keyIdentifier: parameterKey,
                injectionRewrite: parameterInjectionRewrite(from: parameter)
            )
        }
        let genericParameterNames =
            node.genericParameterClause?.parameters.map { $0.name.text } ?? []
        let providesAttribute = attribute(in: node.attributes, named: "Provides")
        let key = providesAttribute.flatMap { keyIdentifier(from: $0) }
        let scopeKey = scopes.last?.seedScope
        let providerLocation = location(of: node.name)
        unannotatedExtensionProvides.append(
            contentsOf: unannotatedExtensionProvidesCandidates(
                providerName: functionName,
                location: providerLocation,
                extendedType: scopes.last?.unannotatedExtensionTarget
            )
        )
        let effects = functionEffectFlags(node.signature.effectSpecifiers)
        let providerAccess = accessLevel(from: node.modifiers)
        if let diagnostic = declarationTooPrivateDiagnostic(
            surfaceLabel: "@Provides function",
            name: functionName,
            ownAccess: providerAccess,
            enclosing: scopes.map { ($0.typeName, $0.access) },
            location: providerLocation
        ) {
            warnings.append(diagnostic)
        }
        let teardown = providerTeardownAction(
            in: node.attributes,
            sourcePath: sourcePath,
            converter: converter
        )
        warnings.append(contentsOf: teardown.diagnostics)
        record(
            .provider(
                DiscoveredProvider(
                    boundType: returnClause.type.trimmedDescription,
                    accessPath: accessPath,
                    form: .function,
                    dependencies: dependencies,
                    genericParameterNames: genericParameterNames,
                    location: providerLocation,
                    keyIdentifier: key,
                    isAsync: effects.isAsync,
                    isThrowing: effects.isThrowing,
                    accessLevel: providerAccess,
                    scopeKey: scopeKey,
                    contributions: contributions(
                        in: node.attributes,
                        sourcePath: sourcePath,
                        converter: converter
                    ),
                    allowUnused: providesAttribute.map { allowUnusedFlag(from: $0) } ?? false,
                    teardown: teardown.action,
                    isReplacer: hasReplacesMarker(in: node.attributes),
                    originModule: module
                )
            )
        )
    }
}
