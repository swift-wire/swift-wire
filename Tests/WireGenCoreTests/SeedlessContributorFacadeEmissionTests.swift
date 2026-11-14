// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Testing

@testable import WireGenCore

/// The seedless reconstruction thunk's teardown accumulator and unwind (swift-wire#431), driven at the
/// emission level. The integration fixtures exercise this path only through the out-of-process generator,
/// so without these the emitter's choices are pinned by golden output alone.
///
/// Two decisions are under test. A torn thunk declares the accumulator and appends each `@Teardown`
/// binding's action as it is built. Whether the thunk unwinds is decided from the construction lines
/// alone: a throwing teardown puts a `try` inside an append closure, and a `try` in a closure does not
/// make the enclosing `do` throw, so it must not by itself produce a `do`/`catch` the compiler rejects.
@Suite("SeedlessContributorFacadeEmission")
struct SeedlessContributorFacadeEmissionTests {
    private let doublesType = "_MyTests_bindMockDoubles"

    private func facade(resourceInitThrows: Bool, teardownThrows: Bool?) -> String {
        let descriptor = seedlessScopeEntryDescriptor(
            subject: "AController",
            doubles: doublesType,
            entryStructName: scopeEntryStructName(subjectTypeName: "AController", variant: "MyTests_bindMock")
        )
        let proxy = DiscoveredScopeBoundType(
            typeName: "_MyTests_bindMock_AControllerContributor",
            typeKind: "struct",
            genericParameterNames: [],
            dependencies: [
                DependencyParameter(
                    name: contributorProxyScopeEntryFieldName,
                    type: descriptor.thunkType,
                    kind: .scopeEntryThunk,
                    location: mockLocation("Proxy.swift"),
                    scopeEntry: descriptor
                )
            ],
            location: mockLocation("Proxy.swift"),
            originModule: testModule
        )
        let repo = DiscoveredBinding.provider(
            DiscoveredProvider(
                boundType: "BackendRepository",
                accessPath: "doubles.backendRepository",
                form: .property,
                dependencies: [],
                genericParameterNames: [],
                location: mockLocation("<doubles>"),
                originModule: testModule
            )
        )
        let resource = DiscoveredBinding.scopeBound(
            DiscoveredScopeBoundType(
                typeName: "AResource",
                typeKind: "struct",
                genericParameterNames: [],
                dependencies: [],
                location: mockLocation("AResource.swift"),
                initIsThrowing: resourceInitThrows,
                teardown: teardownThrows.map {
                    TeardownAction(
                        kind: .member(methodName: "close", isAsync: true, isThrowing: $0),
                        location: mockLocation("AResource.swift")
                    )
                },
                originModule: testModule
            )
        )
        let controller = DiscoveredBinding.scopeBound(
            DiscoveredScopeBoundType(
                typeName: "AController",
                typeKind: "struct",
                genericParameterNames: [],
                dependencies: [
                    DependencyParameter(
                        name: "resource",
                        type: "AResource",
                        kind: .injectInitParameter,
                        location: mockLocation("A.swift")
                    ),
                    DependencyParameter(
                        name: "repo",
                        type: "BackendRepository",
                        kind: .injectInitParameter,
                        location: mockLocation("A.swift")
                    ),
                ],
                location: mockLocation("A.swift"),
                originModule: testModule
            )
        )
        let scope = SeedScopeEmission(
            seedTypeExpression: "AController",
            identifierSuffix: "MyTests_bindMock_AController",
            parentGraphType: "_WireGraph",
            topologicalOrder: [repo, resource, controller],
            borrowedBindingPropertyNames: [],
            edges: [controller.identity: [resource.identity, repo.identity]],
            doublesType: doublesType
        )
        return renderSeedlessContributorFacade(
            proxy: proxy,
            scope: scope,
            parentGraphTypeReference: "_MyTests_bindMockWireGraph",
            facadeMethodName: "bootstrapMyTests_bindMock_AControllerContributor"
        )
    }

    @Test func throwingTeardownAloneAccumulatesWithoutUnwinding() {
        let output = facade(resourceInitThrows: false, teardownThrows: true)

        #expect(output.contains("doubles: \(doublesType)) async throws in"))
        #expect(output.contains("var _wireScopeTeardownActions: [@Sendable () async -> [any Error]] = []"))
        #expect(output.contains("let aResource = AResource()"))
        #expect(output.contains("_wireScopeTeardownActions.append({"))
        #expect(output.contains("try await aResource.close()"))
        // Nothing in construction throws, so there is nothing to unwind: the `try` inside the append
        // closure must not be read as one. (The closure's own `do`/`catch` is the teardown's, not an unwind.)
        #expect(!output.contains("_ = await action()"))
    }

    @Test func throwingConstructionUnwindsTheAccumulatedTeardown() {
        let output = facade(resourceInitThrows: true, teardownThrows: false)

        #expect(output.contains("var _wireScopeTeardownActions: [@Sendable () async -> [any Error]] = []"))
        #expect(output.contains("let aResource = try AResource()"))
        #expect(output.contains("_ = await action()"))
        #expect(output.contains("throw error"))
    }

    @Test func untornThunkDeclaresNoAccumulator() {
        let output = facade(resourceInitThrows: true, teardownThrows: nil)

        #expect(output.contains("let aResource = try AResource()"))
        #expect(!output.contains("_wireScopeTeardownActions"))
        #expect(!output.contains("_ = await action()"))
        #expect(output.contains("return _WireScopeEntry_MyTests_bindMock_AController(_wireSubject: aController"))
    }
}
