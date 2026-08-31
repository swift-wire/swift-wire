// Iteration 5α dead-binding warning: a binding declared but consumed by
// nothing in Wire's visible build. Visibility-gated — `internal`/`package`
// warn (Wire sees all consumers at that scope), `public`/`open` stay
// silent (downstream consumers may exist). `fileprivate`/`private` never
// reach here (the declaration-too-private error already failed the build).
// See `Documentation/Notes/VisibilityModel.md`.
//
// Consumption is judged from both the discovered bindings and the resolved
// graph. A generic binding's dependency reaches a concrete producer only
// after specialisation (a `table: Table` parameter substituted to
// `table: ConcreteTable`); that substituted edge lives in the resolved
// graph's bindings, so feeding those in keeps the concrete producer live.
//
// First-order only: a binding consumed solely by another dead binding is
// not yet detected (no fixed-point pass). Runs per container — each graph
// is atomic, so liveness is judged within the container's own bindings.

/// Dead-binding warnings across a module, grouped by container. Liveness
/// is judged per *container* (all of a container's scopes merged), not per
/// `(container, scope)` partition: a seed scope borrows its container's
/// singletons, so a singleton consumed only by a scope binding must still
/// count as live. Containers are atomic, so each is judged independently.
///
/// `resolvedByContainer` carries each container's resolved-graph bindings
/// (post-specialisation). Their dependency edges count toward liveness on
/// top of the discovered bindings'; a container with no resolved entry
/// falls back to its discovered bindings alone.
///
/// A binding that *carries* an adapter annotation is live: the annotation is an
/// explicit declaration that it's adapted (like a multibinding contributor is
/// live via its aggregate). Only the annotated binding counts — not the
/// adapter's declared dependencies, whose use is the adapter's own opaque logic,
/// so a binding provided solely for an adapter to use stays subject to the
/// normal check. M1 adapters register in the default graph, so these apply to
/// the default (`nil`) container.
/// `pruned` are the identities reachability already dropped and reported (`prunedBindingDiagnostics`).
/// They are skipped here: the two diagnostics describe one fact — nothing reaches this binding — and the
/// pruning one says more, so reporting both would double every message. M7b.4 finishes the merge by
/// replacing this first-order consumption check with reachability itself.
package func deadBindingDiagnostics(
    across bindingsByPartition: [Partition: [DiscoveredBinding]],
    resolvedByContainer: [String?: [DiscoveredBinding]] = [:],
    pruned: Set<BindingIdentity> = []
) -> [Diagnostic] {
    var bindingsByContainer: [String?: [DiscoveredBinding]] = [:]
    for (partition, bindings) in bindingsByPartition {
        bindingsByContainer[partition.container, default: []].append(contentsOf: bindings)
    }
    let diagnostics = bindingsByContainer.flatMap { container, discovered in
        deadBindingDiagnostics(
            in: discovered.filter { !pruned.contains($0.identity) },
            consumers: discovered + (resolvedByContainer[container] ?? [])
        )
    }
    return diagnostics.sorted { $0.location < $1.location }
}

/// Warn for each binding in `bindings` that no binding consumes, subject to
/// the visibility gate. Consumption is read from the same `bindings`.
package func deadBindingDiagnostics(in bindings: [DiscoveredBinding]) -> [Diagnostic] {
    deadBindingDiagnostics(in: bindings, consumers: bindings)
}

/// Warn for each binding in `bindings` (one container's discovered
/// bindings, no synthesised aggregates) that nothing in `consumers`
/// consumes, subject to the visibility gate. `consumers` is the set whose
/// dependency edges establish liveness — the discovered bindings plus the
/// resolved graph's specialised bindings. Output is sorted by source
/// location for stable build output.
package func deadBindingDiagnostics(
    in bindings: [DiscoveredBinding],
    consumers: [DiscoveredBinding]
) -> [Diagnostic] {
    deadBindingDiagnostics(in: bindings, consumers: consumers, additionallyConsumed: [])
}

/// The implementation, with `additionallyConsumed` — identities consumed by
/// something other than a binding's own dependency edge (an adapter
/// registration). Internal: `BindingIdentity` can't cross the package boundary.
func deadBindingDiagnostics(
    in bindings: [DiscoveredBinding],
    consumers: [DiscoveredBinding],
    additionallyConsumed: Set<BindingIdentity>
) -> [Diagnostic] {
    var producerByIdentity: [BindingIdentity: DiscoveredBinding] = [:]
    for binding in bindings {
        producerByIdentity[binding.identity] = binding
    }
    var consumed = consumedIdentities(in: consumers, producers: producerByIdentity)
    // Adapter-consumed identities resolve through `matchProducer` too, so an
    // optional-promoting or exact match keeps the producer live.
    for identity in additionallyConsumed {
        if case .resolved(let producer) = matchProducer(for: identity, in: producerByIdentity) {
            consumed.insert(producer)
        }
    }

    var diagnostics: [Diagnostic] = []
    for identity in producerByIdentity.keys.sorted() where !consumed.contains(identity) {
        guard let binding = producerByIdentity[identity], shouldWarnUnused(binding) else { continue }
        diagnostics.append(
            Diagnostic(
                location: binding.location,
                message:
                    "\(describeSlot(binding)) is declared but nothing in the build consumes it. Inject it somewhere, raise it to 'public' if it's consumed outside this \(binding.accessLevel == .package ? "package" : "target"), or mark it 'allowUnused: true' to silence.",
                severity: .warning
            )
        )
    }
    return diagnostics.sorted { $0.location < $1.location }
}

/// Identities consumed by any consumer's init-time dependencies or member-
/// injection parameters, resolved through `matchProducer` so optional
/// promotion is honoured (a `T?` dependency keeps the `T` producer live).
private func consumedIdentities(
    in consumers: [DiscoveredBinding],
    producers: [BindingIdentity: DiscoveredBinding]
) -> Set<BindingIdentity> {
    var consumed: Set<BindingIdentity> = []
    func record(_ dependencyIdentity: BindingIdentity) {
        if case .resolved(let producer) = matchProducer(for: dependencyIdentity, in: producers) {
            consumed.insert(producer)
        }
    }
    for binding in consumers {
        for dependency in binding.dependencies {
            record(bridgedDependencyIdentity(dependency, in: binding))
            // A bridging proxy consumes its subject — and anything the thunk yields — *through* the
            // scope-entry thunk, so the edge's own identity is the closure type and both would otherwise
            // look dead. See below.
            for identity in scopeEntryConstructedIdentities(of: dependency) { record(identity) }
        }
        for injection in binding.memberInjections {
            for parameter in injection.parameters {
                record(bridgedDependencyIdentity(parameter, in: binding))
            }
        }
    }
    return consumed
}

/// The identities a bridging contributor proxy's scope-entry thunk constructs — its *subject*, plus every
/// `.yieldsFromScope` binding the thunk hands back.
///
/// A `.singleton` proxy over a `@Scoped(seed:)` subject doesn't depend on the subject's type — it depends
/// on a thunk that constructs one: `@Sendable (Seed) async throws -> (Subject, Teardown)`. That edge's
/// identity is the *function* type, which matches no producer, so the subject was reported dead even
/// though the proxy is exactly what constructs it. (The `.singleton` case never had the problem: its proxy
/// holds `_wireSubject` by type, an ordinary edge.)
///
/// **A yield is the sharper form of the same problem.** Its whole purpose is to leave the scope through
/// the thunk, so by construction nothing *inside* the scope depends on it — a yielded binding has no
/// in-scope consumer at all, and without this every one of them would warn as dead. The advice such a
/// warning gives ("delete it, or mark it `allowUnused:`") is wrong in both halves.
///
/// Empty for every other dependency, so the analysis is otherwise unchanged. A *generic* proxy's thunk
/// names a specialised subject (`MeController<Repository>`) that won't match the generic template's
/// identity, but generic bindings are already exempt from the warning, so nothing is missed.
///
/// Matched on `kind`, not on the field name: an aggregate proxy names its thunks
/// `_wireEnterScope_<Subject>`, one per bridged member, and the kind is the classifier the name only
/// approximates. Widening it can only mark *more* bindings live, so it cannot introduce a false warning.
func scopeEntryConstructedIdentities(of dependency: DependencyParameter) -> [BindingIdentity] {
    guard dependency.kind == .scopeEntryThunk, let descriptor = dependency.scopeEntry else { return [] }
    return ([descriptor.subject] + descriptor.yields).map { type in
        let components = identityComponents(type)
        // Unkeyed: `@Scoped`/`@Singleton` self-producers carry no user-facing key.
        return BindingIdentity(
            qualifier: components.qualifier,
            base: components.base,
            isOptional: components.isOptional,
            key: nil
        )
    }
}

/// Whether an unconsumed binding should warn. An explicit `allowUnused:
/// true` silences it. Generic bindings are skipped — their liveness is via
/// specialisation (consumed as `Foo<Concrete>`), which this first-order
/// analysis doesn't track. A binding that contributes to a multibinding is
/// live via its aggregate's consumer, so it's skipped too (the
/// multibinding empty/dead-key cases handle aggregates separately).
/// `public`/`open` stay silent (external consumers may exist).
private func shouldWarnUnused(_ binding: DiscoveredBinding) -> Bool {
    guard !binding.allowUnused else { return false }
    guard binding.genericParameterNames.isEmpty else { return false }
    guard binding.contributions.isEmpty else { return false }
    switch binding.accessLevel {
    case .internal, .package: return true
    case .public, .open, .fileprivate, .private: return false
    }
}

/// Human-facing identifier for the dead binding — the bound type, with a
/// keyed slot rendered as `T (key)` so two same-type bindings are
/// distinguishable.
private func describeSlot(_ binding: DiscoveredBinding) -> String {
    if let key = binding.keyIdentifier {
        return "'\(binding.boundType)' (key \(key))"
    }
    return "'\(binding.boundType)'"
}
