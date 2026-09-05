// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import WireGenCore

// Per-subject doubles — `_<Variant>_<Subject>Doubles`, carrying only the fields a given routed subject
// reaches rather than every field the `TestingKey` declares.
//
// The key-wide `_<Key>Doubles` forces a test to supply every mocked slot on every request, including for a
// route that consumes none of them. What a request actually needs is what *its subject* consumes, which is a
// narrower set the variant already has the pieces to compute. This file computes it and renders one struct per
// subject alongside the key-wide one; the key-wide struct is unchanged, so nothing that reads it moves.
//
// The two subject kinds arrive at their set differently:
//
//  • **Seedless** (an app-`@Singleton` `@TestScopable` route contributor) — already per-subject. Its
//    reconstruction is built from that subject's cone intersected with what reaches a mock, and its
//    `doublesFields` folds in its mock-consuming factories. Read it as-is.
//
//  • **Seed-scoped** (`@Scoped(seed:)`) — *not* per-subject. A seed scope is partitioned by seed type, so
//    every controller on `HTTPRequest` shares one scope and one `doublesFields`. The subject's own share is
//    that set intersected with `reachableBindings(from:)` — the same per-root BFS the scope-entry thunk uses
//    to prune construction and teardown — unioned with its proxy's mock-consuming factory fields,
//    which are *not* reachable from the subject (a middleware is not a dependency of the controller) but are
//    consumed on its behalf per request.
extension WireGen {
    /// One rendered `_<Variant>_<Subject>Doubles` struct, with the subject it belongs to.
    struct SubjectDoubles {
        let subjectTypeName: String
        let fields: [DoublesField]
        let declaration: String
    }

    /// The per-subject doubles structs for a variant — one per routed subject the variant covers, seedless and
    /// seed-scoped alike, in subject-name order so the emission is deterministic. A subject that reaches no
    /// mocked slot still gets a struct: its memberwise init takes no arguments, which is the point (a route
    /// consuming no doubles should be callable without naming any).
    static func subjectDoublesStructs(
        seedScopes: [SeedScopeEmission],
        productionProxies: [DiscoveredScopeBoundType],
        factoryTransformsByProxy: [String: [VariantFactoryTransform]],
        seedlessReconstructions: [SeedlessReconstruction],
        variantName: String
    ) -> [SubjectDoubles] {
        var scopeBySeed: [String: SeedScopeEmission] = [:]
        for scope in seedScopes { scopeBySeed[scope.seedTypeExpression] = scope }

        var bySubject: [String: [DoublesField]] = [:]
        for proxy in productionProxies {
            guard
                let scopeEntry = proxy.dependencies.first(where: { $0.name == contributorProxyScopeEntryFieldName }),
                let parsed = scopeEntry.scopeEntry,
                let scope = scopeBySeed[parsed.seed]
            else { continue }
            let subjectTypeName = bareTypeName(parsed.subject)
            let factoryFields = (factoryTransformsByProxy[proxy.typeName] ?? []).flatMap(\.doublesFields)
            bySubject[subjectTypeName] = mergingFields(
                seedScopedDoublesFields(subject: parsed.subject, in: scope) + factoryFields
            )
        }
        for reconstruction in seedlessReconstructions {
            bySubject[reconstruction.subjectTypeName] = mergingFields(reconstruction.doublesFields)
        }

        return bySubject.keys.sorted().map { subjectTypeName in
            let fields = bySubject[subjectTypeName] ?? []
            return SubjectDoubles(
                subjectTypeName: subjectTypeName,
                fields: fields,
                declaration: renderDoublesStruct(
                    typeName: subjectDoublesStructTypeName(
                        variantName: variantName,
                        subjectTypeName: subjectTypeName
                    ),
                    fields: fields
                )
            )
        }
    }

    /// The doubles fields `subject` consumes from its (seed-shared) scope — the scope's doubles-sourced
    /// bindings pruned to what the subject reaches. A binding the variant rewrote reads `doubles.<field>`, so
    /// the field is recovered from its access path rather than needing an identity on `DoublesField`.
    ///
    /// `reachableBindings` returns `nil` when the scope carries no edges or the subject binding isn't found,
    /// meaning "no pruning" — the same fallback the scope-entry thunk takes, which here yields the whole
    /// scope's set. That is over-broad rather than wrong: it is what the key-wide struct would have given.
    private static func seedScopedDoublesFields(
        subject: String,
        in scope: SeedScopeEmission
    ) -> [DoublesField] {
        let reachable = reachableBindings(from: identifierName(forType: subject, key: nil), in: scope)
        let consumed = Set(
            scope.topologicalOrder
                .filter { reachable?.contains($0.identity) ?? true }
                .compactMap { doublesSourcedFieldName(of: $0) }
        )
        return scope.doublesFields.filter { consumed.contains($0.name) }
    }

    /// Dedupe by field name, keeping first occurrence and sorting by name — matching how the key-wide struct
    /// is rendered, so a subject's field order is the same as its slice of the key-wide one.
    private static func mergingFields(_ fields: [DoublesField]) -> [DoublesField] {
        var byName: [String: DoublesField] = [:]
        for field in fields where byName[field.name] == nil { byName[field.name] = field }
        return byName.values.sorted { $0.name < $1.name }
    }
}
