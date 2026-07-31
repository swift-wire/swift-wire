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

    /// A key declared in the target being built names that target and tells the author to move it. This is
    /// the diagnostic standing between a `TestingKey` in production sources and a variant graph compiled
    /// into the shipping binary, so it is pinned rather than left to the caller's phrasing.
    @Test func keyInNonTestConsumerNamesTheTargetAndTheFix() throws {
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
        #expect(diagnostic.message.contains("'\(testModule)' is not a test target"))
        #expect(diagnostic.message.contains("Move the TestingKey into a test target."))
    }

    /// A key composed in from a Wire-aware dependency points at that dependency instead — the fix is on the
    /// library's side, and the message says why (its key reaches every consumer that re-parses it).
    @Test func keyComposedFromDependencyNamesTheOriginModule() throws {
        let source = """
            enum LibFixture {
                @BindType(Repo.self, MockRepo.self)
                static let bindMock = TestingKey()
            }
            """
        let key = try #require(
            discover(in: source, sourcePath: "Lib.swift", module: "SharedLib").testingKeys.first
        )
        let diagnostic = testingVariantsNotEnabledDiagnostic(key, consumerModule: "App")
        #expect(diagnostic.severity == .error)
        #expect(diagnostic.message.contains("composed into 'App' from module 'SharedLib'"))
        #expect(diagnostic.message.contains("Move the TestingKey out of 'SharedLib'"))
    }
}
