// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

// Why a `TestingKey`'s `@BindType` varies nothing — the one check that classifies every substitution the
// variant pass did not turn into a doubles field, and says which of the three reasons applies:
//
// - **Nothing produces the slot.** No binding anywhere matches it: a stale or mistyped `@BindType`.
// - **Only a `@Container` graph produces it.** The slot is real, but variants vary the default graph only,
//   so the substitution can never take effect. Reported on its own rather than as "nothing produces it",
//   which sent the author looking for a typo that was not there.
// - **The default graph produces it, but nothing under test reads it per scope entry.** A mocked app
//   singleton is varied only when a seed scope's borrow boundary reaches it (it is then lifted into the
//   scope) or a seedless route contributor consumes it. Otherwise the variant keeps its production binding.
//   When *no* substitution in the key is varied the key emits no variant at all — an error, because the
//   test then names generated types that do not exist. When another substitution is varied the variant
//   does emit and only this mock goes unread — a warning.

/// The classifying diagnostics for one testing key's `@BindType` substitutions.
///
/// - Parameters:
///   - key: the testing key, whose substitutions are classified in source order.
///   - productionBindings: the default graph's production-retained app singletons and seed-scope bindings —
///     the set a variant derives from.
///   - containerBindings: every `@Container` graph's bindings (its singletons and its seed scopes), keyed by
///     container name — matched only to tell "produced in a container" apart from "produced nowhere".
///   - variedFieldNames: the doubles fields the variant actually emits (direct seed-scope substitutions,
///     cascade lifts, seed-scoped factory transforms, seedless reconstructions). A substitution whose field
///     is among them is varied and needs no diagnostic.
///   - diagnosedLocations: the `@BindType` attributes another variant check has already reported (an
///     unmarked seedless root, an unsupported aggregate proxy). Those already say why the slot is not
///     varied, so this check stays quiet about them.
package func unvariedBindTypeDiagnostics(
    key: DiscoveredTestingKey,
    productionBindings: [DiscoveredBinding],
    containerBindings: [String: [DiscoveredBinding]],
    variedFieldNames: Set<String>,
    diagnosedLocations: Set<SourceLocation>
) -> [Diagnostic] {
    var diagnostics: [Diagnostic] = []
    var unread: [BindTypeSubstitution] = []
    let keyReference = key.keyReference
    let unproduced = unmatchedSubstitutions(key.substitutions, against: productionBindings)
    for substitution in key.substitutions where !diagnosedLocations.contains(substitution.location) {
        if unproduced.contains(substitution) {
            let containers = containerBindings.keys.sorted().filter { name in
                containerBindings[name, default: []].contains { substitutionMatches(substitution, $0) }
            }
            diagnostics.append(
                containers.isEmpty
                    ? unmatchedBindTypeDiagnostic(substitution)
                    : containerOnlyBindTypeDiagnostic(substitution, containers: containers)
            )
            continue
        }
        let fields = productionBindings.filter { substitutionMatches(substitution, $0) }.map(doublesFieldName)
        if !fields.contains(where: variedFieldNames.contains) { unread.append(substitution) }
    }
    guard let first = unread.first else { return diagnostics }
    if variedFieldNames.isEmpty {
        // The anchor is the key's first unread `@BindType` in source order; the rest are named in its message,
        // so one key that varies nothing reads as one error rather than one per attribute.
        diagnostics.append(
            emptyVariantBindTypeDiagnostic(first, others: Array(unread.dropFirst()), keyReference: keyReference)
        )
    } else {
        diagnostics += unread.map { unreadBindTypeDiagnostic($0, keyReference: keyReference) }
    }
    return diagnostics
}

/// The error for a `@BindType` whose slot only a `@Container` graph (or a seed scope under one) produces.
package func containerOnlyBindTypeDiagnostic(
    _ substitution: BindTypeSubstitution,
    containers: [String]
) -> Diagnostic {
    let quoted = containers.map { "'\($0)'" }.joined(separator: ", ")
    let place = containers.count == 1 ? "@Container \(quoted)" : "@Container graphs \(quoted)"
    return Diagnostic(
        location: substitution.location,
        message:
            "\(bindTypeSpelling(substitution)) substitutes a slot produced only in \(place), and @Container "
            + "graphs are not varied under a TestingKey — so this substitution cannot take effect.",
        severity: .error
    )
}

/// The error for a key none of whose `@BindType`s reaches a seed scope or a seedless route contributor: the
/// variant would be empty, so none of its generated names exist.
package func emptyVariantBindTypeDiagnostic(
    _ substitution: BindTypeSubstitution,
    others: [BindTypeSubstitution],
    keyReference: String
) -> Diagnostic {
    let variantName = keyReference.split(separator: ".").joined(separator: "_")
    let otherSlots = others.map(slotSpelling).joined(separator: ", ")
    let alsoOthers = others.isEmpty ? "" : " (nor does any other slot this key substitutes: \(otherSlots))"
    return Diagnostic(
        location: substitution.location,
        message:
            "\(bindTypeSpelling(substitution)) substitutes a slot no seed scope or seedless route contributor "
            + "reads\(alsoOthers), so nothing under '\(keyReference)' is varied and neither "
            + "\(doublesStructTypeName(forKeyReference: keyReference)) nor Wire.bootstrap\(variantName)() is "
            + "generated.",
        severity: .error
    )
}

/// The warning for a `@BindType` on an app singleton no seed scope's borrow boundary and no seedless route
/// contributor reaches, in a key whose variant does emit through another substitution.
package func unreadBindTypeDiagnostic(_ substitution: BindTypeSubstitution, keyReference: String) -> Diagnostic {
    Diagnostic(
        location: substitution.location,
        message:
            "\(bindTypeSpelling(substitution)) substitutes a slot no seed scope or seedless route contributor "
            + "reaches, so under '\(keyReference)' it keeps its production binding and the "
            + "\(substitution.mockType) double is never read.",
        severity: .warning
    )
}

/// `@BindType(<slot>, <Mock>.self)` — the attribute as every `@BindType` diagnostic spells it.
func bindTypeSpelling(_ substitution: BindTypeSubstitution) -> String {
    "@BindType(\(slotSpelling(substitution)), \(substitution.mockType).self)"
}

private func slotSpelling(_ substitution: BindTypeSubstitution) -> String {
    substitution.slotType ?? substitution.slotKey ?? "?"
}
