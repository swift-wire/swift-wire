// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Testing

@testable import WireGenCore

/// `@GraphInputs` — the root graph's counterpart of a seeded scope's seed. These pin what the scanner
/// reads out of the declaration (which properties are inputs, and how one is keyed), the bindings it
/// turns them into, and the diagnostics for the two shapes that would otherwise fail quietly.
@Suite("Graph inputs discovery")
struct GraphInputsDiscoveryTests {
    private func inputs(in source: String) -> [DiscoveredGraphInputs] {
        discover(in: source, sourcePath: "Inputs.swift", module: testModule).graphInputs
    }

    // MARK: - Scanner

    @Test func storedPropertiesBecomeInputsAndComputedOnesDoNot() throws {
        let declaration = try #require(
            inputs(
                in: """
                    @GraphInputs
                    struct AppInputs: Sendable {
                        let configuration: RuntimeConfiguration
                        var mutableToo: Int
                        // Not an input: there is no value to pass in.
                        var described: String { "x" }
                        // Still stored — observers don't make a property computed.
                        var observed: Bool = false { didSet {} }
                    }
                    """
            ).first
        )
        #expect(declaration.typeName == "AppInputs")
        #expect(declaration.properties.map(\.name) == ["configuration", "mutableToo", "observed"])
        #expect(declaration.properties.map(\.type) == ["RuntimeConfiguration", "Int", "Bool"])
    }

    @Test func providesKeysAnInputSoSameTypedInputsCoexist() throws {
        let declaration = try #require(
            inputs(
                in: """
                    @GraphInputs
                    struct AppInputs: Sendable {
                        @Provides(InputKeys.region) let region: String
                        @Provides(InputKeys.stage) let stage: String
                        let unkeyed: String
                    }
                    """
            ).first
        )
        #expect(declaration.properties.map(\.keyIdentifier) == ["InputKeys.region", "InputKeys.stage", nil])
    }

    /// A `static` stored property belongs to the type, not to the value passed to
    /// `Wire.bootstrap(inputs:)`: taking it as an input emitted `_wireInputs.fallback`, which does not
    /// compile. A `static` computed property and a `static func` were never inputs (one has a getter, the
    /// other is not a property), so only the stored statics are recorded as skipped.
    @Test func staticStoredPropertiesAreNotInputs() throws {
        let declaration = try #require(
            inputs(
                in: """
                    @GraphInputs
                    struct AppInputs: Sendable {
                        let configuration: RuntimeConfiguration
                        static let fallback: Int = 0
                        static var described: String { "x" }
                        static func make() -> AppInputs { fatalError() }
                        nonisolated(unsafe) static var counter: Int = 0
                        class let legacy: String = ""
                    }
                    """
            ).first
        )
        #expect(declaration.properties.map(\.name) == ["configuration"])
        #expect(declaration.staticMembers.map(\.name) == ["fallback", "counter", "legacy"])
        let bindings = graphInputBindings(declaration, inputsLocal: "_wireInputs", module: testModule)
        let accessPaths: [String] = bindings.compactMap {
            if case .provider(let provider) = $0 { return provider.accessPath }
            return nil
        }
        #expect(accessPaths == ["_wireInputs.configuration"])
    }

    @Test func anUnannotatedStructIsNotInputs() {
        #expect(inputs(in: "struct AppInputs { let x: Int }").isEmpty)
    }

    // MARK: - Bindings

    @Test func eachInputBecomesAProviderReadingTheBootstrapParameter() throws {
        let declaration = try #require(
            inputs(
                in: """
                    @GraphInputs
                    struct AppInputs: Sendable {
                        let configuration: RuntimeConfiguration
                        @Provides(InputKeys.region) let region: String
                    }
                    """
            ).first
        )
        let bindings = graphInputBindings(declaration, inputsLocal: "_wireInputs", module: testModule)
        let providers: [DiscoveredProvider] = bindings.compactMap {
            if case .provider(let provider) = $0 { return provider }
            return nil
        }
        #expect(providers.map(\.accessPath) == ["_wireInputs.configuration", "_wireInputs.region"])
        #expect(providers.map(\.boundType) == ["RuntimeConfiguration", "String"])
        #expect(providers.map(\.keyIdentifier) == [nil, "InputKeys.region"])
        // An input the graph doesn't consume is the caller's business — it stays a required argument of
        // `Wire.bootstrap(inputs:)` either way, so it must not read as a dead binding.
        #expect(providers.map(\.allowUnused) == [true, true])
    }

    // MARK: - Diagnostics

    @Test func twoGraphInputsTypesIsAnError() {
        let declarations = inputs(
            in: """
                @GraphInputs struct AppInputs: Sendable { let a: Int }
                @GraphInputs struct OtherInputs: Sendable { let b: Int }
                """
        )
        let diagnostics = graphInputsDiagnostics(declarations)
        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.severity == .error)
        // Names both, so the fix (merge them) is obvious from the message alone.
        #expect(diagnostics.first?.message.contains("AppInputs") == true)
        #expect(diagnostics.first?.message.contains("OtherInputs") == true)
    }

    @Test func inputsWithNoStoredPropertiesWarns() {
        let source = "@GraphInputs struct AppInputs: Sendable { var described: String { 42 } }"
        let diagnostics = graphInputsDiagnostics(inputs(in: source))
        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.severity == .warning)
    }

    @Test func aStaticStoredPropertyWarnsWhereItIsDeclared() {
        let source = """
            @GraphInputs
            struct AppInputs: Sendable {
                let configuration: RuntimeConfiguration
                static let fallback: Int = 0
                static var described: String { "x" }
            }
            """
        let diagnostics = graphInputsDiagnostics(inputs(in: source))
        #expect(diagnostics.count == 1)
        let warning = diagnostics.first
        #expect(warning?.severity == .warning)
        #expect(
            warning?.message
                == "@GraphInputs 'AppInputs' property 'fallback' is static, so it is not a graph input — inputs are read from the value passed to 'Wire.bootstrap(inputs:)', and a static belongs to the type. Read it directly as 'AppInputs.fallback'."
        )
        #expect(warning?.location == SourceLocation(file: "Inputs.swift", line: 4, column: 16))
    }

    @Test func oneWellFormedDeclarationIsSilent() {
        #expect(
            graphInputsDiagnostics(
                inputs(in: "@GraphInputs struct AppInputs: Sendable { let a: Int }")
            ).isEmpty
        )
    }

    // MARK: - Only the consumer's package supplies inputs

    /// A declaration in a *dependency* package is not honoured. Inputs become parameters of the consumer's
    /// `Wire.bootstrap`, and only the program assembling the graph knows where its `ConfigReader` or
    /// event-loop group comes from — so a library cannot dictate what its consumers must pass in.
    @Test func aDependencysInputsAreIgnoredAndDiagnosed() {
        let library = DiscoveredGraphInputs(
            typeName: "LibraryInputs",
            properties: [
                GraphInput(name: "a", type: "Int", keyIdentifier: nil, location: mockLocation("Lib.swift"))
            ],
            // Ignored with the rest of the declaration: no static-member warning beside the dependency one.
            staticMembers: [GraphInputsStaticMember(name: "fallback", location: mockLocation("Lib.swift"))],
            location: mockLocation("Lib.swift"),
            originModule: "SomeLibrary"
        )
        #expect(resolvedGraphInputs([library], externalModules: ["SomeLibrary"]) == nil)

        let diagnostics = graphInputsDiagnostics([library], externalModules: ["SomeLibrary"])
        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.severity == .warning)
        // Names the dependency, since that is the one thing the consumer can act on.
        #expect(diagnostics.first?.message.contains("SomeLibrary") == true)
    }

    /// A same-*package* module's declaration IS honoured — which is what lets a test target re-composing
    /// an executable inherit the app's inputs instead of redeclaring them.
    @Test func aSamePackageModulesInputsAreUsed() throws {
        let declaration = try #require(
            inputs(in: "@GraphInputs struct AppInputs: Sendable { let a: Int }").first
        )
        // `externalModules` names only genuine cross-package dependencies, so this module is not in it.
        #expect(resolvedGraphInputs([declaration], externalModules: ["SomeLibrary"])?.typeName == "AppInputs")
        #expect(graphInputsDiagnostics([declaration], externalModules: ["SomeLibrary"]).isEmpty)
    }

    /// An ignored dependency declaration must not make a home-package one ambiguous — only home-package
    /// declarations compete for the single `inputs:` parameter.
    @Test func aDependencysInputsDoNotCollideWithTheConsumersOwn() throws {
        let home = try #require(inputs(in: "@GraphInputs struct AppInputs: Sendable { let a: Int }").first)
        let library = DiscoveredGraphInputs(
            typeName: "LibraryInputs",
            properties: [
                GraphInput(name: "b", type: "Int", keyIdentifier: nil, location: mockLocation("Lib.swift"))
            ],
            location: mockLocation("Lib.swift"),
            originModule: "SomeLibrary"
        )
        let diagnostics = graphInputsDiagnostics([home, library], externalModules: ["SomeLibrary"])
        // The ignored-dependency warning, and no "multiple @GraphInputs" error.
        #expect(diagnostics.count == 1)
        #expect(diagnostics.allSatisfy { $0.severity == .warning })
        #expect(resolvedGraphInputs([home, library], externalModules: ["SomeLibrary"])?.typeName == "AppInputs")
    }
}
