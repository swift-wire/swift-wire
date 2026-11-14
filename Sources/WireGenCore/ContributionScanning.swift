// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import SwiftSyntax

// Parsing of `@Contributes(to:withOrder:atKey:)` annotations into
// `Contribution` values, shared by the scope-bound and `@Provides`
// producer paths so any producer can contribute uniformly. See
// `Documentation/Notes/MultibindingsImplementationPlan.md` (Step 2).

/// Every `@Contributes(to:)` annotation on a declaration, in source
/// order. A contributor may target several keys via repeated
/// `@Contributes` (Swift permits the same attached macro multiple times),
/// so this returns a list rather than a single optional. Tolerates the
/// SE-0491 `@Wire::Contributes` selector via `wireMacroNameMatches`.
///
/// Also returns an error for each `withOrder:` that is not an integer
/// literal: the rank is read from syntax, so a named constant has no value
/// WireGen can see. See `withOrderRank(of:)`.
func contributions(
    in attributes: AttributeListSyntax,
    sourcePath: String,
    converter: SourceLocationConverter
) -> (contributions: [Contribution], diagnostics: [Diagnostic]) {
    var contributions: [Contribution] = []
    var diagnostics: [Diagnostic] = []
    for element in attributes {
        guard let attribute = element.as(AttributeSyntax.self) else { continue }
        guard wireMacroNameMatches(attribute.attributeName.trimmedDescription, "Contributes") else {
            continue
        }
        guard let scanned = contribution(from: attribute, sourcePath: sourcePath, converter: converter)
        else { continue }
        contributions.append(scanned.contribution)
        if let diagnostic = scanned.diagnostic { diagnostics.append(diagnostic) }
    }
    return (contributions, diagnostics)
}

/// Parse a single `@Contributes(to:withOrder:atKey:)` attribute. Returns
/// `nil` when the required `to:` argument is absent — a malformed form
/// the compiler also rejects (no matching `@Contributes` overload).
private func contribution(
    from attribute: AttributeSyntax,
    sourcePath: String,
    converter: SourceLocationConverter
) -> (contribution: Contribution, diagnostic: Diagnostic?)? {
    guard case let .argumentList(arguments) = attribute.arguments else { return nil }
    guard let toArgument = arguments.first(where: { $0.label?.text == "to" }) else { return nil }
    let keyReference = toArgument.expression.trimmedDescription

    let orderArgument = arguments.first(where: { $0.label?.text == "withOrder" })
    let order = orderArgument.flatMap { withOrderRank(of: $0.expression) }
    let mapKeyExpression =
        arguments
        .first(where: { $0.label?.text == "atKey" })?
        .expression.trimmedDescription

    var diagnostic: Diagnostic?
    if let orderArgument, order == nil {
        diagnostic = Diagnostic(
            location: makeSourceLocation(
                of: orderArgument.expression,
                sourcePath: sourcePath,
                converter: converter
            ),
            message:
                "'withOrder: \(orderArgument.expression.trimmedDescription)' on @Contributes(to: \(keyReference)) is not an integer literal — WireGen reads a contributor's rank from source, so it can't evaluate a named constant or other expression. Write the rank as an integer literal, e.g. 'withOrder: 10'.",
            severity: .error
        )
    }

    return (
        Contribution(
            keyReference: keyReference,
            order: order,
            hasUnreadableOrder: orderArgument != nil && order == nil,
            mapKeyExpression: mapKeyExpression,
            location: makeSourceLocation(of: attribute, sourcePath: sourcePath, converter: converter)
        ),
        diagnostic
    )
}

/// The rank a `withOrder:` expression denotes, when syntax alone says: an
/// integer literal in any radix and with `_` separators (`1_000`, `0x10`), or
/// one negated by a prefix `-` (`-1`). `nil` for anything else, such as
/// `Rank.auth` or `1 + 1`, whose value only the type checker knows.
func withOrderRank(of expression: ExprSyntax) -> Int? {
    if let literal = expression.as(IntegerLiteralExprSyntax.self) {
        return literal.representedLiteralValue
    }
    if let prefix = expression.as(PrefixOperatorExprSyntax.self),
        prefix.operator.text == "-",
        let magnitude = prefix.expression.as(IntegerLiteralExprSyntax.self)?.representedLiteralValue
    {
        return -magnitude
    }
    return nil
}

extension BindingDiscovery {
    /// The declaration's contributions, with any `withOrder:` diagnostics appended to `warnings`.
    func scanContributions(in attributes: AttributeListSyntax) -> [Contribution] {
        let scan = contributions(in: attributes, sourcePath: sourcePath, converter: converter)
        warnings.append(contentsOf: scan.diagnostics)
        return scan.contributions
    }

    /// A `@Contributes` with no co-located producer macro. Beside its scanner, as the other per-concern
    /// `record…`/diagnostic helpers are beside theirs.
    func producerlessMarkerDiagnostics(in attributes: AttributeListSyntax) -> [Diagnostic] {
        strayContributesDiagnostics(
            in: attributes,
            producerMacros: ["Provides"],
            sourcePath: sourcePath,
            converter: converter
        )
    }
}
