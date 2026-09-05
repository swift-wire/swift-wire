// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import SwiftSyntax

// Scope-yield candidates — the parameter attributes a bridged subject's routes carry.
//
// A scope entry hands back the bindings its subject's *route parameters* name. Nothing declares that and
// nothing annotates for it: the attribute a parameter already carries **is** the request, because in the
// shape this serves the attribute name and the binding type are the same identifier. `@AuthorizedDocument`
// on a parameter is `AuthorizedDocument` the `@Scoped` binding; `@Path` is a type that is no binding at
// all, so it never matches. The match is identity, not a heuristic, which is what lets this be inferred
// rather than declared.
//
// Discovery is deliberately dumb here — it records every parameter attribute on every method of every
// type, with no idea which are bindings. The filtering happens where the graph's bindings are known
// (`scopeYieldsBySubject`), because "is this a `@Scoped` binding in this subject's scope" is not a
// question a syntax scan can answer.

/// One attribute on one method parameter, attributed to the type the method is declared in.
///
/// Methods are not bindings, so — like a route-scope `@Middleware(key)` on a member method — a parameter's
/// attribute attributes to its *enclosing type*, which is the binding a scope entry is built for.
package struct ScopeYieldCandidate: Sendable, Equatable {
    /// The qualified name of the type declaring the method — matched against a bridged subject.
    package let targetIdentity: String
    /// The attribute's name, which for a match is also the binding's type name.
    package let typeName: String
    /// The parameter's position in source — where a diagnostic about it should point.
    package let location: SourceLocation

    package init(targetIdentity: String, typeName: String, location: SourceLocation) {
        self.targetIdentity = targetIdentity
        self.typeName = typeName
        self.location = location
    }
}

/// Every attribute on `parameters`, attributed to `targetIdentity`. Deliberately unfiltered — see above.
func scopeYieldCandidates(
    targetIdentity: String,
    parameters: FunctionParameterListSyntax,
    sourcePath: String,
    converter: SourceLocationConverter
) -> [ScopeYieldCandidate] {
    parameters.flatMap { parameter in
        parameter.attributes.compactMap { element -> ScopeYieldCandidate? in
            guard case .attribute(let attribute) = element else { return nil }
            let name = attribute.attributeName.trimmedDescription
            guard !name.isEmpty else { return nil }
            return ScopeYieldCandidate(
                targetIdentity: targetIdentity,
                typeName: name,
                location: makeSourceLocation(
                    of: parameter.firstName,
                    sourcePath: sourcePath,
                    converter: converter
                )
            )
        }
    }
}
