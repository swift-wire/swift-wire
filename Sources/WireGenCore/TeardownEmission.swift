// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

/// Emission of the graph's `@Teardown` orchestration — the `teardown()` method on the graph
/// struct and the per-binding call lines every teardown action is built from. The captured
/// `_wireTeardown` closure itself is folded in the bootstrap body from the `_wireTeardownActions`
/// accumulator (`PartialTeardownEmission.swift`). Split out of `CodeEmission.swift` (file-length)
/// but part of the same `renderWireGraph` pipeline; the shared `propertyName`/`effectPrefix`
/// helpers live there.
///
/// The load-bearing idea: an `@Singleton(as: P.self)` binding is stored on the graph under a
/// lifted `some P` identity, so its concrete `@Teardown` members aren't visible there. The
/// teardown closure is therefore built at bootstrap — where each binding's local still carries
/// its concrete type — and captured onto the graph, which just runs it.

/// The `func teardown() async -> [any Error]` emitted on the graph struct — the
/// app-scope teardown walk. Calls each `@Teardown` binding's action in **reverse**
/// construction order (dependents before dependencies), collecting rather than
/// propagating errors so one failing action doesn't stop the rest. Emitted only when the
/// graph has at least one teardown action; otherwise the `Teardownable` default (an empty
/// `[]`) stands in, so no method is emitted on a graph with nothing to tear down.
func teardownMethodLines(_ torn: [DiscoveredBinding]) -> [String] {
    guard !torn.isEmpty else { return [] }
    // The teardown actions are captured at bootstrap, where the concrete types are live: each
    // `@Teardown` binding appends one as it is built (`teardownActionAppendLines`), and
    // `accumulatedTeardownClosureLines` folds them into the closure the graph stores. This
    // method just runs it — necessary because the graph's stored properties may be lifted
    // `some P` and can't name the concrete members the actions call.
    return [
        "",
        "    func teardown() async -> [any Error] {",
        "        await _wireTeardown()",
        "    }",
    ]
}

/// The call lines for one binding's teardown action, for the body of the closure that
/// `teardownActionAppendLines` appends to the accumulator (and of the scope-entry teardown
/// closure). The action runs against the binding's bootstrap *local* (a bare name, concrete
/// type) — not `self.<property>` — so an opaquely-bound type's concrete members stay in reach.
/// A throwing action is wrapped in `do`/`catch` that appends to `errors`; a non-throwing member
/// action needs no wrapping. The producer action coerces to the macro's
/// `@Sendable (T) async throws -> Void` type — pinned via a typed local so a sync,
/// non-throwing action coerces cleanly — and so is always `try await`.
func teardownCallLines(for binding: DiscoveredBinding, indent: String = "        ") -> [String] {
    guard let action = binding.teardown else { return [] }
    let property = propertyName(for: binding)
    switch action.kind {
    case .member(let methodName, let isAsync, let isThrowing):
        let call = "\(effectPrefix(isAsync: isAsync, isThrowing: isThrowing))\(property).\(methodName)()"
        guard isThrowing else { return ["\(indent)\(call)"] }
        return [
            "\(indent)do {",
            "\(indent)    \(call)",
            "\(indent)} catch {",
            "\(indent)    errors.append(error)",
            "\(indent)}",
        ]
    case .action(let expression):
        return [
            "\(indent)do {",
            "\(indent)    let action: @Sendable (\(binding.boundTypeReference)) async throws -> Void = \(expression)",
            "\(indent)    try await action(\(property))",
            "\(indent)} catch {",
            "\(indent)    errors.append(error)",
            "\(indent)}",
        ]
    }
}
