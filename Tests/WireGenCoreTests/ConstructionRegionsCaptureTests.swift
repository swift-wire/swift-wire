// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Testing

@testable import WireGenCore

/// A bridging proxy's scope-entry thunk captures are construction edges for the region split.
///
/// The thunk is emitted on the proxy's own construction line and names each captured local there, so a
/// proxy has to be built after everything it captures — even though a capture passes no argument. When the
/// regions ignored captures, a proxy whose only link to a scheduled binding was a capture had no Overlap
/// ancestor, landed in the serial prefix, and its thunk named a local the seam had not bound yet.
@Suite("Construction regions — scope-entry captures")
struct ConstructionRegionsCaptureTests {
    private func singleton(
        _ name: String,
        dependencies: [(name: String, type: String)] = [],
        initIsAsync: Bool = false
    ) -> DiscoveredBinding {
        .scopeBound(
            DiscoveredScopeBoundType(
                typeName: name,
                typeKind: "struct",
                genericParameterNames: [],
                dependencies: dependencies.map {
                    DependencyParameter(
                        name: $0.name,
                        type: $0.type,
                        kind: .injectInitParameter,
                        location: mockLocation("\(name).swift")
                    )
                },
                location: mockLocation("\(name).swift"),
                initIsAsync: initIsAsync,
                allowUnused: true,
                originModule: testModule
            )
        )
    }

    private func syntheticProvider(boundType: String, accessPath: String) -> DiscoveredBinding {
        .provider(
            DiscoveredProvider(
                boundType: boundType,
                accessPath: accessPath,
                form: .property,
                dependencies: [],
                genericParameterNames: [],
                location: mockLocation("<synthetic>"),
                originModule: testModule
            )
        )
    }

    /// `Pool` and `Cache` are the Overlap pair; `Host` waits on both, so it is the suffix.
    private func scheduledGraph() -> [DiscoveredBinding] {
        [
            singleton("Config"),
            singleton("Pool", initIsAsync: true),
            singleton("Cache", initIsAsync: true),
            singleton("Host", dependencies: [(name: "pool", type: "Pool"), (name: "cache", type: "Cache")]),
        ]
    }

    /// A route-controller bridge proxy over a `@Scoped(seed: RequestSeed)` subject that borrows `borrowed`
    /// and nothing else, carrying the `.scopeCapture` edge scope-entry linking gives it — and no other
    /// dependency on the borrow, which is exactly the shape the regions used to misplace.
    private func bridgeProxy(capturing borrowed: String) -> DiscoveredBinding {
        let subject = DiscoveredScopeBoundType(
            typeName: "SessionController",
            typeKind: "struct",
            genericParameterNames: [],
            dependencies: [
                DependencyParameter(
                    name: "seed",
                    type: "RequestSeed",
                    kind: .injectInitParameter,
                    location: mockLocation("S.swift")
                ),
                DependencyParameter(
                    name: "borrowed",
                    type: borrowed,
                    kind: .injectInitParameter,
                    location: mockLocation("S.swift")
                ),
            ],
            location: mockLocation("S.swift"),
            scopeKey: ScopeKey(seed: "RequestSeed"),
            originModule: testModule
        )
        let proxy = contributorProxyBinding(
            for: subject,
            key: "WireMVCKeys.routeContributors",
            prefix: "_WireRouteContributor_",
            proxyScope: .singleton
        )
        return DiscoveredBinding.scopeBound(proxy).appendingDependencies([
            DependencyParameter(
                name: nil,
                type: borrowed,
                kind: .scopeCapture,
                location: mockLocation("\(borrowed).swift")
            )
        ])
    }

    private func requestScope(borrowing borrowed: String) -> SeedScopeEmission {
        let borrowName = identifierName(forType: borrowed, key: nil)
        return SeedScopeEmission(
            seedTypeExpression: "RequestSeed",
            identifierSuffix: "RequestSeed",
            parentGraphType: "_WireGraph",
            topologicalOrder: [
                syntheticProvider(boundType: "RequestSeed", accessPath: "requestSeed"),
                syntheticProvider(boundType: borrowed, accessPath: "_wireGraph.\(borrowName)"),
                .scopeBound(
                    DiscoveredScopeBoundType(
                        typeName: "SessionController",
                        typeKind: "struct",
                        genericParameterNames: [],
                        dependencies: [
                            DependencyParameter(
                                name: "seed",
                                type: "RequestSeed",
                                kind: .injectInitParameter,
                                location: mockLocation("S.swift")
                            ),
                            DependencyParameter(
                                name: "borrowed",
                                type: borrowed,
                                kind: .injectInitParameter,
                                location: mockLocation("S.swift")
                            ),
                        ],
                        location: mockLocation("S.swift"),
                        scopeKey: ScopeKey(seed: "RequestSeed"),
                        originModule: testModule
                    )
                ),
            ],
            borrowedBindingPropertyNames: [borrowName]
        )
    }

    private func regionNames(_ bindings: [DiscoveredBinding]) -> [String] {
        bindings.map { propertyName(for: $0) }
    }

    private let proxyName = "_WireRouteContributor_SessionController"

    // MARK: - Region assignment

    @Test func aCaptureOfAnOverlapBindingPutsTheProxyInTheGroup() throws {
        // The proxy's only edge to `Pool` is the capture. It waits on `Pool` but not on `Cache`, so it is
        // group — not prefix, which is where it landed when captures were not edges.
        let regions = try #require(constructionRegions(for: scheduledGraph() + [bridgeProxy(capturing: "Pool")]))
        #expect(regionNames(regions.group).contains(proxyName))
        #expect(!regionNames(regions.prefix).contains(proxyName))
    }

    @Test func aCaptureOfASuffixBindingPutsTheProxyInTheSuffix() throws {
        // `Host` waits on all of Overlap, so a proxy capturing it does too, transitively through the capture.
        let regions = try #require(constructionRegions(for: scheduledGraph() + [bridgeProxy(capturing: "Host")]))
        #expect(regionNames(regions.suffix) == ["host", proxyName])
        #expect(!regionNames(regions.prefix).contains(proxyName))
    }

    @Test func aCaptureOfAPrefixBindingLeavesTheProxyInThePrefix() throws {
        // Counting captures is not a reason to schedule a proxy: one that captures only a serial binding
        // still has no Overlap ancestor, and stays on the chain ahead of the group.
        let regions = try #require(constructionRegions(for: scheduledGraph() + [bridgeProxy(capturing: "Config")]))
        #expect(regionNames(regions.prefix) == ["config", proxyName])
    }

    // MARK: - Emitted order

    @Test func aProxyCapturingAGroupBindingKeepsTheGraphOnTheChainAfterTheCapture() throws {
        // With the proxy in the group, the scheduler's thunk exclusion applies and the graph is emitted as
        // the linear chain, in topological order — so the thunk follows the `Pool` it captures.
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: scheduledGraph() + [bridgeProxy(capturing: "Pool")],
            seedScopeOrders: [requestScope(borrowing: "Pool")]
        )
        #expect(!output.contains("WireBuilding"))
        let pool = try #require(output.firstRange(of: "let pool = await Pool()"))
        let thunk = try #require(output.firstRange(of: "{ @Sendable (requestSeed: RequestSeed) async throws in"))
        #expect(pool.lowerBound < thunk.lowerBound)
        #expect(output.contains("SessionController(seed: requestSeed, borrowed: pool)"))
    }

    @Test func aProxyCapturingASuffixBindingIsEmittedAfterTheSeam() throws {
        // The graph stays scheduled — the proxy is outside the group — and the thunk is emitted after the
        // drain, once `Host` is a local again.
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: scheduledGraph() + [bridgeProxy(capturing: "Host")],
            seedScopeOrders: [requestScope(borrowing: "Host")]
        )
        #expect(output.contains("private struct _WireBuilding: ~Copyable {"))
        let seam = try #require(output.firstRange(of: "let cache = building._wireState_cache.take()"))
        let host = try #require(output.firstRange(of: "let host = Host(pool: pool, cache: cache)"))
        let thunk = try #require(output.firstRange(of: "{ @Sendable (requestSeed: RequestSeed) async throws in"))
        #expect(seam.lowerBound < host.lowerBound)
        #expect(host.lowerBound < thunk.lowerBound)
    }
}
