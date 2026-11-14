// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

/// The generic parameters a graph or seed-scope struct lifts for its bare `some P` bindings, keyed by the
/// **binding identity** of the binding each one stands for — type and key together.
///
/// Keying on the identity rather than the type text is what lets two keyed `some P` bindings of the same
/// protocol lift a parameter each: `@Provides(K.a) … -> some P` and `@Provides(K.b) … -> some P` are two
/// identities, so they map to `T0` and `T1`. Keyed on `some P` alone, the second collapsed onto the first
/// and a consumer spelled itself `Consumer<T0, T0>`, which does not compile (swift-wire#368).
///
/// A structural lift node (`Consumer<X: P, Y: P>`) has no parameter of its own; it spells itself with the
/// parameters of the bindings that fill its generic parameters. Which binding fills a parameter is decided
/// by the dependency the parameter appears in, followed to its producer, never by the parameter's
/// constraint — two parameters with the same constraint are filled by different bindings whenever their
/// dependencies carry different keys.
struct LiftedParameters {
    /// Each lifted opaque identity to its spelling: a lifted parameter (`T0`), or, for a `@BindType`d opaque
    /// binding in a test-variant seed scope, the concrete mock type.
    var parameterForIdentity: [BindingIdentity: String]
    /// The graph's bindings by identity, so a dependency can be followed to the producer it resolves to.
    let producers: [BindingIdentity: DiscoveredBinding]
    /// The liftable identities in lift order — the constraint-text fallback's search order. See
    /// `opaqueIdentity(filling:of:)`.
    let liftOrder: [BindingIdentity]
    private let liftable: Set<BindingIdentity>

    init(
        parameterForIdentity: [BindingIdentity: String],
        bindings: [DiscoveredBinding],
        liftOrder: [BindingIdentity]
    ) {
        self.parameterForIdentity = parameterForIdentity
        self.producers = Dictionary(bindings.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
        self.liftOrder = liftOrder
        self.liftable = Set(liftOrder)
    }

    /// The spelling of one generic parameter of a structural lift node: the lifted parameter of the opaque
    /// binding that fills it, or `nil` when no lifted binding does.
    func spelling(of parameter: String, in binding: DiscoveredBinding) -> String? {
        opaqueIdentity(filling: parameter, of: binding).flatMap { parameterForIdentity[$0] }
    }

    /// The identity of the opaque binding that fills `parameter` of the structural lift node `binding`.
    ///
    /// - A dependency that *is* the parameter (`@Inject(K.a) var x: X`) bridges to `some P` keyed `K.a`
    ///   (`bridgedDependencyIdentity`'s rule 2a) and resolves to that producer.
    /// - A dependency the parameter appears in as a top-level generic argument (`Box<X>`, rule 2b) resolves
    ///   to another structural lift node; the parameter is filled by whatever fills that node's parameter at
    ///   the same position, recursively.
    /// - Otherwise — a parameter nested deeper than a top-level argument, or a dependency that resolves to
    ///   nothing lifted — the first lifted identity spelled `some <constraint>`, whatever its key. That is
    ///   the constraint-text lookup this replaced, kept only as the last resort.
    func opaqueIdentity(filling parameter: String, of binding: DiscoveredBinding) -> BindingIdentity? {
        opaqueIdentity(filling: parameter, of: binding, visited: [])
    }

    private func opaqueIdentity(
        filling parameter: String,
        of binding: DiscoveredBinding,
        visited: Set<BindingIdentity>
    ) -> BindingIdentity? {
        let dependencies = binding.dependencies + binding.memberInjections.flatMap(\.parameters)
        if let direct = dependencies.first(where: { canonicalTypeName($0.type) == parameter }),
            let producer = resolvedProducer(of: direct, in: binding),
            liftable.contains(producer) || parameterForIdentity[producer] != nil
        {
            return producer
        }
        let visited = visited.union([binding.identity])
        for dependency in dependencies {
            let arguments = topLevelGenericArguments(of: canonicalTypeName(dependency.type))
            guard let position = arguments.firstIndex(of: parameter),
                let producerIdentity = resolvedProducer(of: dependency, in: binding),
                !visited.contains(producerIdentity),
                let producer = producers[producerIdentity],
                producer.allGenericParametersDetermined,
                position < producer.genericParameterNames.count,
                let filled = opaqueIdentity(
                    filling: producer.genericParameterNames[position],
                    of: producer,
                    visited: visited
                )
            else { continue }
            return filled
        }
        let constraint = binding.genericParameterConstraints[parameter] ?? ""
        let byText = identityComponents("some \(constraint)")
        return liftOrder.first {
            $0.qualifier == byText.qualifier && $0.base == byText.base && $0.isOptional == byText.isOptional
        }
    }

    private func resolvedProducer(
        of dependency: DependencyParameter,
        in binding: DiscoveredBinding
    ) -> BindingIdentity? {
        guard
            case .resolved(let identity) = matchProducer(
                for: bridgedDependencyIdentity(dependency, in: binding),
                in: producers
            )
        else { return nil }
        return identity
    }
}
