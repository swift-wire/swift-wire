import SwiftSyntax

// Recognition of `@GraphInputs` — the app-scope counterpart of a seeded scope's seed.
//
// A seeded scope takes a value the graph cannot construct (the request); `@GraphInputs` gives the *root*
// graph the same door. Each stored property of the annotated struct becomes an ordinary app-scope binding
// whose producer is the caller-supplied value, so `Wire.bootstrap(inputs:)` is how a `ConfigReader` read
// from the environment, CLI arguments, or an externally-owned client reach the graph.
//
// Syntax-only, like every other scanner here: the plugin reads the declaration, never the values.

/// One `@GraphInputs` struct found in source.
package struct DiscoveredGraphInputs: Sendable, Equatable {
    /// The struct's name — the type of the generated `inputs:` parameter.
    package let typeName: String
    /// Its stored properties, in declaration order. Each becomes a binding.
    package let properties: [GraphInput]
    package let location: SourceLocation

    package init(typeName: String, properties: [GraphInput], location: SourceLocation) {
        self.typeName = typeName
        self.properties = properties
        self.location = location
    }
}

/// One stored property of a `@GraphInputs` struct — a binding of `type`, sourced from `name` on the
/// caller-supplied value.
package struct GraphInput: Sendable, Equatable {
    package let name: String
    package let type: String
    /// Canonical text of a `@Provides(key)` annotation on the property, or `nil` for the unkeyed form.
    /// Keying is how two inputs of the same type coexist, spelled exactly as a `@Provides` keys a binding.
    package let keyIdentifier: String?
    package let location: SourceLocation

    package init(name: String, type: String, keyIdentifier: String?, location: SourceLocation) {
        self.name = name
        self.type = type
        self.keyIdentifier = keyIdentifier
        self.location = location
    }
}

/// The `@GraphInputs` declaration on `node`, or `nil` when it carries no such attribute.
///
/// A property with no explicit type annotation is skipped: Wire reads syntax, never infers, and an input
/// whose type it cannot see cannot become a binding. `graphInputsDiagnostics` reports those rather than
/// letting them vanish.
func graphInputsDeclaration(
    named name: TokenSyntax,
    attributes: AttributeListSyntax,
    members: MemberBlockItemListSyntax,
    sourcePath: String,
    converter: SourceLocationConverter
) -> DiscoveredGraphInputs? {
    guard hasAttribute(attributes, named: "GraphInputs") else { return nil }
    var properties: [GraphInput] = []
    for member in members {
        guard let variable = member.decl.as(VariableDeclSyntax.self) else { continue }
        for binding in variable.bindings {
            guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                let type = binding.typeAnnotation?.type.trimmedDescription,
                isStoredProperty(binding)
            else { continue }
            properties.append(
                GraphInput(
                    name: identifier,
                    type: type,
                    keyIdentifier: providesKeyIdentifier(in: variable.attributes),
                    location: makeSourceLocation(of: binding.pattern, sourcePath: sourcePath, converter: converter)
                )
            )
        }
    }
    return DiscoveredGraphInputs(
        typeName: name.text,
        properties: properties,
        location: makeSourceLocation(of: name, sourcePath: sourcePath, converter: converter)
    )
}

/// Whether a pattern binding is *stored* — a computed property (`var x: T { … }`) produces no value to
/// pass in, so it is not an input. An initialised stored property (`let x: T = …`) still is.
private func isStoredProperty(_ binding: PatternBindingSyntax) -> Bool {
    switch binding.accessorBlock?.accessors {
    case .none: return true
    case .accessors(let accessors):
        // `willSet`/`didSet` observers leave the property stored; a getter does not.
        return accessors.allSatisfy { $0.accessorSpecifier.tokenKind != .keyword(.get) }
    case .getter: return false
    }
}

/// The canonical key text of a `@Provides(key)` attribute on an input property, or `nil` when unkeyed
/// (or when `@Provides` is written bare, which is the same as omitting it here).
private func providesKeyIdentifier(in attributes: AttributeListSyntax) -> String? {
    guard let attribute = attribute(in: attributes, named: "Provides"),
        case let .argumentList(list) = attribute.arguments,
        let first = list.first,
        first.label == nil  // `allowUnused:` is labelled; the key rides positionally
    else { return nil }
    return first.expression.trimmedDescription
}

/// Diagnostics for the `@GraphInputs` declarations across a module: more than one is ambiguous (which
/// would `Wire.bootstrap` take?), and a stored property Wire cannot type is silently absent from the
/// graph unless it is reported.
package func graphInputsDiagnostics(_ declarations: [DiscoveredGraphInputs]) -> [Diagnostic] {
    var diagnostics: [Diagnostic] = []
    if declarations.count > 1 {
        for extra in declarations.dropFirst() {
            diagnostics.append(
                Diagnostic(
                    location: extra.location,
                    message:
                        "multiple @GraphInputs types are declared ('\(declarations[0].typeName)' and '\(extra.typeName)') — the graph takes one 'inputs:' value, so merge them into a single type.",
                    severity: .error
                )
            )
        }
    }
    for declaration in declarations where declaration.properties.isEmpty {
        diagnostics.append(
            Diagnostic(
                location: declaration.location,
                message:
                    "@GraphInputs '\(declaration.typeName)' declares no stored properties, so it contributes no bindings — give it the values the graph needs from outside, or remove the annotation.",
                severity: .warning
            )
        )
    }
    return diagnostics
}

/// The generated bootstrap's inputs-parameter name — the local every input binding's access path reads
/// through. Leading underscore so it can't collide with a user binding whose property name is `inputs`,
/// mirroring `wireGraphParameterInternalName`'s reasoning for the parent-graph parameter.
package let graphInputsParameterName = "_wireInputs"

/// The app-scope bindings a `@GraphInputs` declaration contributes — one property-form provider per stored
/// property, reading `<inputsLocal>.<name>`.
///
/// The same shape as a seeded scope's synthetic seed binding (`syntheticSeedBinding`): a provider whose
/// access path names a parameter of the generated bootstrap function, so emission renders it as an
/// ordinary `let <name> = <inputsLocal>.<name>` and every downstream consumer resolves against it with no
/// special case anywhere in the graph.
package func graphInputBindings(
    _ declaration: DiscoveredGraphInputs,
    inputsLocal: String,
    module: String
) -> [DiscoveredBinding] {
    declaration.properties.map { property in
        .provider(
            DiscoveredProvider(
                boundType: property.type,
                accessPath: "\(inputsLocal).\(property.name)",
                form: .property,
                dependencies: [],
                genericParameterNames: [],
                location: property.location,
                keyIdentifier: property.keyIdentifier,
                // Inputs are supplied by the caller, so an unconsumed one is the caller's business, not a
                // dead binding: it stays a required argument of `Wire.bootstrap(inputs:)` either way.
                allowUnused: true,
                originModule: module
            )
        )
    }
}
