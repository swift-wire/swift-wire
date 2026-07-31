import Testing

@testable import WireGenCore

/// M6a Phase 1: `@BindType` / `TestingKey` discovery. Pins that a `TestingKey`
/// static is recognised, its canonical reference captured, and each stacked
/// `@BindType(slot, Mock)` marker read into a substitution — the type form and
/// the keyed form alike, mirroring `@Provides` / `@Replaces` argument reading.
@Suite("BindType discovery")
struct BindTypeDiscoveryTests {
    private func keys(in source: String) -> [DiscoveredTestingKey] {
        discover(in: source, sourcePath: "Testing.swift", module: testModule).testingKeys
    }

    @Test func testingKeyFromInitialiserCapturesReferenceAndSubstitution() throws {
        let source = """
            enum MyTests {
                @BindType(BackendRepository.self, MockBackendRepository.self)
                static let testSetup = TestingKey()
            }
            """
        let key = try #require(keys(in: source).first)
        #expect(keys(in: source).count == 1)
        #expect(key.keyReference == "MyTests.testSetup")
        #expect(key.substitutions.count == 1)
        let substitution = try #require(key.substitutions.first)
        #expect(substitution.slotType == "BackendRepository")
        #expect(substitution.slotKey == nil)
        #expect(substitution.mockType == "MockBackendRepository")
    }

    @Test func testingKeyFromExplicitAnnotationIsRecognised() throws {
        let source = """
            enum MyTests {
                @BindType(Repo.self, MockRepo.self)
                static let setup: TestingKey = TestingKey()
            }
            """
        let key = try #require(keys(in: source).first)
        #expect(key.keyReference == "MyTests.setup")
        #expect(key.substitutions.first?.slotType == "Repo")
    }

    @Test func stackedBindTypesAllCaptured() throws {
        let source = """
            enum MyTests {
                @BindType(Repo.self, MockRepo.self)
                @BindType(Clock.self, FakeClock.self)
                static let testSetup = TestingKey()
            }
            """
        let key = try #require(keys(in: source).first)
        #expect(key.substitutions.count == 2)
        #expect(key.substitutions.map(\.slotType) == ["Repo", "Clock"])
        #expect(key.substitutions.map(\.mockType) == ["MockRepo", "FakeClock"])
    }

    @Test func keyedBindTypeReadsKeyReference() throws {
        let source = """
            enum MyTests {
                @BindType(Repo.primary, MockRepo.self)
                static let testSetup = TestingKey()
            }
            """
        let key = try #require(keys(in: source).first)
        let substitution = try #require(key.substitutions.first)
        #expect(substitution.slotType == nil)
        #expect(substitution.slotKey == "Repo.primary")
        #expect(substitution.mockType == "MockRepo")
    }

    @Test func nonTestingKeyDeclarationIsIgnored() {
        let source = """
            enum MyTests {
                static let notAKey = BindingKey<Repo>()
            }
            """
        #expect(keys(in: source).isEmpty)
    }

    // MARK: - The `--testing-variants` gate

    /// A key in the target being built, on a run that did not opt in. WireGen cannot tell a production target
    /// from a test target whose plugin is not passing the flag, so the message must name **both** — naming
    /// only the first sends someone to inspect a `.testTarget` declaration that is already correct, which is
    /// what CI hit when wire-mvc's plugin predated the flag.
    @Test func keyWithoutOptInNamesTheFlagAndBothExplanations() throws {
        let source = """
            enum ProdFixture {
                @BindType(Repo.self, MockRepo.self)
                static let bindMock = TestingKey()
            }
            """
        let key = try #require(keys(in: source).first)
        let diagnostic = testingVariantsNotEnabledDiagnostic(key, consumerModule: testModule)
        #expect(diagnostic.severity == .error)
        #expect(diagnostic.message.contains("'ProdFixture.bindMock'"))
        #expect(diagnostic.message.contains(testingVariantsFlag))
        // Both explanations, so neither reading is ruled out for the reader.
        #expect(diagnostic.message.contains("If '\(testModule)' is a production target"))
        #expect(diagnostic.message.contains("its build plugin is not passing"))
    }

    /// A key composed in from a Wire-aware dependency points at that dependency instead — the fix is on the
    /// library's side, and the message says why (its key reaches every consumer that re-parses it).
    @Test func foreignKeyNamesTheOriginModule() throws {
        let source = """
            enum LibFixture {
                @BindType(Repo.self, MockRepo.self)
                static let bindMock = TestingKey()
            }
            """
        let key = try #require(
            discover(in: source, sourcePath: "Lib.swift", module: "SharedLib").testingKeys.first
        )
        let diagnostic = foreignTestingKeyDiagnostic(key, consumerModule: "App")
        #expect(diagnostic.severity == .error)
        #expect(diagnostic.message.contains("composed into 'App' from module 'SharedLib'"))
        #expect(diagnostic.message.contains("Only the target that declares a TestingKey"))
        #expect(diagnostic.message.contains("Move the TestingKey out of 'SharedLib'"))
    }
}
