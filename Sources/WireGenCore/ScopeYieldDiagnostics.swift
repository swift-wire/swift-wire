// Validation for scope yields — the bindings a bridged subject's scope entry hands back because its route
// parameters name them.
//
// Yields are inferred, not declared, so there is no annotation for a user to get wrong. What is left is a
// route that asks for a scope binding its controller's scope cannot give it — and the failure is otherwise
// invisible at the point it is made, because a candidate that matches nothing is simply not yielded and
// nothing says so. The adapter's codegen then reads a field the entry struct does not have, which fails
// later, further away, and about a generated type the user never wrote.

/// Diagnose every route parameter that names a `@Scoped` binding its enclosing subject cannot yield.
///
/// - **The subject enters no scope.** A `@Singleton` controller's proxy *holds* it, so there is no scope
///   entry and nothing to hand a scope binding back through. The parameter names a real binding, so this
///   is a mistake rather than an unrelated attribute — a controller taking a request-scoped argument has
///   to be request-scoped itself.
/// - **The binding lives in a different scope.** A `@Scoped(seed: A)` subject cannot hand back a
///   `@Scoped(seed: B)` binding: sibling seeded scopes are isolated by design, and the entry only
///   constructs its own.
///
/// Parameters naming something that is no binding anywhere (`@Path`, `@JSONBody`, a plain property
/// wrapper) are silent — the overwhelming majority, and none of Wire's business.
///
/// Errors rather than warnings: the adapter's generated code is written against the entry struct's fields,
/// so a yield that did not happen is a compile failure somewhere less legible.
package func scopeYieldDiagnostics(
    bindings: [Partition: [DiscoveredBinding]],
    candidates: [ScopeYieldCandidate]
) -> [Diagnostic] {
    guard !candidates.isEmpty else { return [] }

    // Every scope-bound binding, by type name → the partitions it is bound in. A candidate naming a type
    // absent from this map is not a binding at all, which is the common case and is silent.
    var scopedPartitions: [String: [Partition]] = [:]
    for (partition, partitionBindings) in bindings where partition.scope != nil {
        for binding in partitionBindings {
            scopedPartitions[canonicalTypeName(binding.boundType), default: []].append(partition)
        }
    }
    guard !scopedPartitions.isEmpty else { return [] }

    // The partition each *subject* lives in, by qualified name — how a candidate's enclosing type is
    // resolved to the scope its entry would construct.
    var subjectPartitions: [String: Partition] = [:]
    for (partition, partitionBindings) in bindings {
        for case .scopeBound(let type) in partitionBindings {
            subjectPartitions[type.qualifiedTypeName] = partition
        }
    }

    var diagnostics: [Diagnostic] = []
    var reported: Set<String> = []
    for candidate in candidates {
        let type = canonicalTypeName(candidate.typeName)
        guard let boundIn = scopedPartitions[type] else { continue }
        guard let subjectPartition = subjectPartitions[candidate.targetIdentity] else { continue }
        guard subjectPartition.scope == nil || !boundIn.contains(subjectPartition) else { continue }
        // One report per (subject, binding): several routes taking the same argument is one mistake.
        guard reported.insert("\(candidate.targetIdentity)|\(type)").inserted else { continue }
        let subject = candidate.targetIdentity
        if subjectPartition.scope == nil {
            diagnostics.append(
                Diagnostic(
                    location: candidate.location,
                    message:
                        "'\(candidate.typeName)' is bound in \(describeScopeYieldPartition(boundIn[0])), but '\(subject)' is not scoped — its contributor proxy holds it directly and enters no scope, so there is nothing to construct '\(candidate.typeName)' in. Mark '\(subject)' @Scoped(seed:) with the same seed.",
                    severity: .error
                )
            )
        } else {
            diagnostics.append(
                Diagnostic(
                    location: candidate.location,
                    message:
                        "'\(candidate.typeName)' is bound in \(describeScopeYieldPartition(boundIn[0])), but '\(subject)' is in \(describeScopeYieldPartition(subjectPartition)) — sibling seeded scopes are isolated by design, so its scope entry constructs only its own. Bind '\(candidate.typeName)' in \(describeScopeYieldPartition(subjectPartition)), or move '\(subject)' to the other seed.",
                    severity: .error
                )
            )
        }
    }
    return diagnostics.sorted { ($0.location.file, $0.location.line) < ($1.location.file, $1.location.line) }
}

/// A partition as a scope-yield diagnostic names it — the same spelling the cross-scope hint uses, so a
/// reader meeting both sees one vocabulary.
private func describeScopeYieldPartition(_ partition: Partition) -> String {
    guard let scope = partition.scope else { return "@Singleton" }
    return "@Scoped(seed: \(scope.seed).self)"
}
