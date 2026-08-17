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

    @Test func oneWellFormedDeclarationIsSilent() {
        #expect(
            graphInputsDiagnostics(
                inputs(in: "@GraphInputs struct AppInputs: Sendable { let a: Int }")
            ).isEmpty
        )
    }
}
