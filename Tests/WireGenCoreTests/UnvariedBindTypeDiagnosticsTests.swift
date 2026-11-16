// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Testing

@testable import WireGenCore

/// The one check that says why a `TestingKey`'s `@BindType` varies nothing: nothing produces the slot, only a
/// `@Container` graph produces it, or the default graph produces it but no seed scope or seedless route
/// contributor reads it — an error when the whole key then varies nothing, a warning when another substitution
/// still makes the variant emit. Each message is pinned by its exact text and its `file:line:col`.
@Suite("Unvaried @BindType diagnostics (core)")
struct UnvariedBindTypeDiagnosticsTests {
    private let keyReference = "AppTests.bindDoubles"

    /// An unkeyed provider producing `boundType`.
    private func provider(_ boundType: String) -> DiscoveredBinding {
        .provider(
            DiscoveredProvider(
                boundType: boundType,
                accessPath: "make()",
                form: .function,
                dependencies: [],
                genericParameterNames: [],
                location: mockLocation("\(boundType).swift"),
                originModule: testModule
            )
        )
    }

    /// A `@BindType(<slot>.self, <mock>.self)` attribute at `Key.swift:<line>:5`.
    private func bindType(_ slot: String, _ mock: String, line: Int) -> BindTypeSubstitution {
        BindTypeSubstitution(
            slotType: slot,
            slotKey: nil,
            mockType: mock,
            location: mockLocation("Key.swift", line: line, column: 5)
        )
    }

    private func diagnostics(
        _ substitutions: [BindTypeSubstitution],
        production: [DiscoveredBinding] = [],
        containers: [String: [DiscoveredBinding]] = [:],
        varied: Set<String> = [],
        diagnosed: Set<WireGenCore.SourceLocation> = []
    ) -> [Diagnostic] {
        unvariedBindTypeDiagnostics(
            key: DiscoveredTestingKey(
                keyReference: keyReference,
                substitutions: substitutions,
                location: mockLocation("Key.swift", line: 1, column: 5),
                accessLevel: .internal,
                originModule: testModule
            ),
            productionBindings: production,
            containerBindings: containers,
            variedFieldNames: varied,
            diagnosedLocations: diagnosed
        )
    }

    @Test func slotNothingProducesKeepsTheStaleBindTypeError() throws {
        let found = diagnostics([bindType("NotBound", "MockNotBound", line: 3)], production: [provider("any Clock")])
        let diagnostic = try #require(found.first)
        #expect(found.count == 1)
        #expect(diagnostic.severity == .error)
        #expect(diagnostic.location == mockLocation("Key.swift", line: 3, column: 5))
        #expect(
            diagnostic.message
                == "@BindType(NotBound, MockNotBound.self) substitutes a slot no binding under test produces — "
                + "check the slot type or key."
        )
    }

    @Test func slotOnlyAContainerProducesSaysContainersAreNotVaried() throws {
        let found = diagnostics(
            [bindType("Repo", "MockRepo", line: 4)],
            containers: ["Feature": [provider("any Repo")], "Other": [provider("any Clock")]]
        )
        let diagnostic = try #require(found.first)
        #expect(found.count == 1)
        #expect(diagnostic.severity == .error)
        #expect(diagnostic.location == mockLocation("Key.swift", line: 4, column: 5))
        #expect(
            diagnostic.message
                == "@BindType(Repo, MockRepo.self) substitutes a slot produced only in @Container 'Feature', and "
                + "@Container graphs are not varied under a TestingKey — so this substitution cannot take effect."
        )
    }

    @Test func slotSeveralContainersProduceNamesEachContainer() throws {
        let found = diagnostics(
            [bindType("Repo", "MockRepo", line: 4)],
            containers: ["Feature": [provider("any Repo")], "Admin": [provider("any Repo")]]
        )
        let diagnostic = try #require(found.first)
        #expect(diagnostic.message.contains("produced only in @Container graphs 'Admin', 'Feature', and"))
    }

    @Test func keyVaryingNothingIsOneErrorAtItsFirstUnreadBindType() throws {
        let found = diagnostics(
            [
                bindType("NotBound", "MockNotBound", line: 2),
                bindType("Clock", "MockClock", line: 3),
                bindType("Logger", "MockLogger", line: 4),
            ],
            production: [provider("any Clock"), provider("any Logger")]
        )
        #expect(found.count == 2)
        #expect(found.first?.message.contains("no binding under test produces") == true)
        let diagnostic = try #require(found.last)
        #expect(diagnostic.severity == .error)
        #expect(diagnostic.location == mockLocation("Key.swift", line: 3, column: 5))
        #expect(
            diagnostic.message
                == "@BindType(Clock, MockClock.self) substitutes a slot no seed scope or seedless route contributor "
                + "reads (nor does any other slot this key substitutes: Logger), so nothing under "
                + "'AppTests.bindDoubles' is varied and neither _AppTests_bindDoublesDoubles nor "
                + "Wire.bootstrapAppTests_bindDoubles() is generated."
        )
    }

    @Test func keyWhoseOnlyBindTypeIsUnreadNamesNoOtherSlot() throws {
        let found = diagnostics([bindType("Clock", "MockClock", line: 3)], production: [provider("any Clock")])
        let diagnostic = try #require(found.first)
        #expect(found.count == 1)
        #expect(
            diagnostic.message
                == "@BindType(Clock, MockClock.self) substitutes a slot no seed scope or seedless route contributor "
                + "reads, so nothing under 'AppTests.bindDoubles' is varied and neither "
                + "_AppTests_bindDoublesDoubles nor Wire.bootstrapAppTests_bindDoubles() is generated."
        )
    }

    @Test func unreadSlotInAVariantThatEmitsWarnsAtItsBindType() throws {
        let found = diagnostics(
            [bindType("Repo", "MockRepo", line: 3), bindType("Clock", "MockClock", line: 4)],
            production: [provider("any Repo"), provider("any Clock")],
            varied: ["repo"]
        )
        let diagnostic = try #require(found.first)
        #expect(found.count == 1)
        #expect(diagnostic.severity == .warning)
        #expect(diagnostic.location == mockLocation("Key.swift", line: 4, column: 5))
        #expect(
            diagnostic.message
                == "@BindType(Clock, MockClock.self) substitutes a slot no seed scope or seedless route contributor "
                + "reaches, so under 'AppTests.bindDoubles' it keeps its production binding and the MockClock "
                + "double is never read."
        )
    }

    @Test func variedOrAlreadyReportedBindTypesRaiseNothing() {
        let unmarked = bindType("Clock", "MockClock", line: 4)
        let found = diagnostics(
            [bindType("Repo", "MockRepo", line: 3), unmarked],
            production: [provider("any Repo"), provider("any Clock")],
            varied: ["repo"],
            diagnosed: [unmarked.location]
        )
        #expect(found.isEmpty)
    }
}
