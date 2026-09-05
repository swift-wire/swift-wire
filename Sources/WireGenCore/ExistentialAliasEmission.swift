// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

// Existential-alias emission for the graph bootstrap and scope bodies — split out of
// CodeEmission.swift to keep that file under the file-length cap. Same module (WireGenCore).

/// How one body binds its existential aliases: those whose producer is
/// constructed here, emitted right after that construction line, and those whose
/// producer is already in scope — a borrowed singleton, or a captured bootstrap
/// local — which are bound up front instead, since no construction line will
/// come along to hang them off.
struct ExistentialAliasPlan {
    let afterConstruction: [BindingIdentity: ExistentialPromotion]
    let upFront: [ExistentialPromotion]
}

/// Plan one body's existential aliases. `consumers` is the set of identities
/// actually constructed in that body (already reachability-pruned by the caller):
/// an alias nothing reads would be an unused local, which Swift warns on. At most
/// one alias per producer even when several consumers share it — they all derive
/// the same name from the same identity, so a second would be an invalid
/// redeclaration. See `ExistentialPromotion`.
func existentialAliasPlan(
    from promotions: [ExistentialPromotion],
    consumers: Set<BindingIdentity>,
    producersWithLetLine: Set<BindingIdentity>
) -> ExistentialAliasPlan {
    let needed = Dictionary(
        grouping: promotions.filter { consumers.contains($0.consumer) },
        by: \.producer
    ).compactMapValues { sharing in
        // Deterministic pick: consumers may spell the existential differently
        // (`any P` vs `any  P`) while sharing one alias.
        sharing.min { $0.existentialType < $1.existentialType }
    }
    var afterConstruction: [BindingIdentity: ExistentialPromotion] = [:]
    var upFront: [ExistentialPromotion] = []
    for producer in needed.keys.sorted() {
        guard let alias = needed[producer] else { continue }
        if producersWithLetLine.contains(producer) {
            afterConstruction[producer] = alias
        } else {
            upFront.append(alias)
        }
    }
    return ExistentialAliasPlan(afterConstruction: afterConstruction, upFront: upFront)
}

/// The `let anyP: any P = someP` line binding one existential alias, or nothing
/// when this binding isn't promoted to by anything in the body.
func existentialAliasLines(
    _ alias: ExistentialPromotion?,
    boundTo value: String,
    indent: String = "    "
) -> [String] {
    guard let alias else { return [] }
    return ["\(indent)let \(alias.aliasName): \(alias.existentialType) = \(value)"]
}

/// A scope body's alias plan. Both scope bodies — the whole-scope façade and the
/// per-request thunk — share it: `constructedHere` is whatever that body actually
/// builds (reachability-pruned for the thunk), and a *borrowed* producer gets no
/// construction line in either, so its alias lands in `upFront`.
func scopeExistentialAliasPlan(
    _ scope: SeedScopeEmission,
    constructedHere: [DiscoveredBinding]
) -> ExistentialAliasPlan {
    existentialAliasPlan(
        from: scope.existentialPromotions,
        consumers: Set(constructedHere.map(\.identity)),
        producersWithLetLine: Set(
            constructedHere
                .filter { !scope.borrowedBindingPropertyNames.contains(propertyName(for: $0)) }
                .map(\.identity)
        )
    )
}

/// The bootstrap body constructs everything it references, so every alias hangs
/// off the producer it aliases and none needs binding up front.
func bootstrapExistentialAliasPlan(
    _ promotions: [ExistentialPromotion],
    constructedIn topologicalOrder: [DiscoveredBinding]
) -> ExistentialAliasPlan {
    let identities = Set(topologicalOrder.map(\.identity))
    return existentialAliasPlan(
        from: promotions,
        consumers: identities,
        producersWithLetLine: identities
    )
}
