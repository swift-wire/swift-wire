// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import SwiftSyntax

// Recognition of `@resultBuilder` type declarations and the result type
// of their `buildBlock` / `buildFinalResult`. A `BuilderKey<Builder>`
// aggregate produces that result type; codegen needs it spelled out
// because a result-builder fold function requires an explicit concrete
// return type. See
// `Documentation/Notes/MultibindingsImplementationPlan.md` (Step 5b).

/// Recognise a `@resultBuilder` type and capture its result type and whether
/// it can fold an empty body, or `nil` when the declaration isn't a result builder or has neither
/// `buildFinalResult` nor `buildBlock` with a return clause.
func resultBuilder(
    named nameToken: TokenSyntax,
    attributes: AttributeListSyntax,
    members: MemberBlockItemListSyntax,
    sourcePath: String,
    converter: SourceLocationConverter
) -> DiscoveredResultBuilder? {
    guard hasAttribute(attributes, named: "resultBuilder") else { return nil }
    guard let resultType = resultBuilderResultType(members) else { return nil }
    return DiscoveredResultBuilder(
        typeName: nameToken.text,
        resultType: resultType,
        acceptsEmptyBlock: declaresZeroArgumentBuildBlock(members),
        location: makeSourceLocation(of: nameToken, sourcePath: sourcePath, converter: converter)
    )
}

/// The fold result type: `buildFinalResult`'s return when present (it has
/// the final say in the result-builder protocol), otherwise `buildBlock`'s.
private func resultBuilderResultType(_ members: MemberBlockItemListSyntax) -> String? {
    returnType(ofMethodNamed: "buildFinalResult", in: members)
        ?? returnType(ofMethodNamed: "buildBlock", in: members)
}

/// Whether the builder's own body declares a `buildBlock` callable with no
/// arguments — no parameters, or every parameter variadic or defaulted — which is
/// what an empty `@Builder` body needs to compile. A `buildPartialBlock`-only
/// builder, or one whose every `buildBlock` has a required parameter, can't fold
/// an empty body. Like the result type, only the type's own body is read.
private func declaresZeroArgumentBuildBlock(_ members: MemberBlockItemListSyntax) -> Bool {
    members.contains { member in
        guard let function = member.decl.as(FunctionDeclSyntax.self),
            function.name.text == "buildBlock"
        else { return false }
        return function.signature.parameterClause.parameters.allSatisfy {
            $0.ellipsis != nil || $0.defaultValue != nil
        }
    }
}

private func returnType(
    ofMethodNamed name: String,
    in members: MemberBlockItemListSyntax
) -> String? {
    for member in members {
        guard let function = member.decl.as(FunctionDeclSyntax.self),
            function.name.text == name,
            let returnClause = function.signature.returnClause
        else { continue }
        return returnClause.type.trimmedDescription
    }
    return nil
}

extension BindingDiscovery {
    /// Capture a `@resultBuilder` type's fold result type. A no-op for declarations that aren't result
    /// builders (including protocols). Beside its scanner, as `recordGraphInputs` is beside its own.
    func recordResultBuilder(
        name: TokenSyntax,
        attributes: AttributeListSyntax,
        members: MemberBlockItemListSyntax
    ) {
        if let builder = resultBuilder(
            named: name,
            attributes: attributes,
            members: members,
            sourcePath: sourcePath,
            converter: converter
        ) {
            resultBuilders.append(builder)
        }
    }
}
