// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Testing

@testable import WireGenCore

/// An extension's explicit access modifier is the default access of its members (swift-wire#342,
/// swift-wire#441). Each discovery surface that records a member's access is pinned on the three idioms
/// against each other: a member with no modifier in a `public extension` (public), an explicitly
/// `public` member of a plain extension (public), and no modifier in either place (internal). A
/// member's own modifier still overrides the extension's default, and `private extension` members
/// default to `fileprivate`, as Swift makes them.
@Suite("Extension access default")
struct ExtensionAccessDefaultTests {
    private static let idioms: [(declarationPrefix: String, expected: AccessLevel)] = [
        ("public extension Holder { static let key = ", .public),
        ("extension Holder { public static let key = ", .public),
        ("extension Holder { static let key = ", .internal),
        ("public extension Holder { internal static let key = ", .internal),
        ("package extension Holder { static let key = ", .package),
        ("private extension Holder { static let key = ", .private),
    ]

    private func source(_ idiom: String, key: String) -> String {
        // Each idiom ends at the key's `=`; the initialiser and the closing brace complete it.
        "public enum Holder {}\n" + idiom + key + " }"
    }

    // MARK: - Keys

    @Test(arguments: idioms)
    func bindingKeyAccess(idiom: String, expected: AccessLevel) throws {
        let discovery = discover(
            in: source(idiom, key: "BindingKey<Database>()"),
            sourcePath: "Keys.swift",
            module: testModule
        )
        let key = try #require(discovery.bindingKeys.first)
        #expect(key.accessLevel == expected)
    }

    @Test(arguments: idioms)
    func multibindingKeyAccess(idiom: String, expected: AccessLevel) throws {
        let discovery = discover(
            in: source(idiom, key: "CollectedKey<any Service>()"),
            sourcePath: "Keys.swift",
            module: testModule
        )
        let key = try #require(discovery.multibindingKeys.first)
        #expect(key.accessLevel == expected)
    }

    @Test(arguments: idioms)
    func testingKeyAccess(idiom: String, expected: AccessLevel) throws {
        let discovery = discover(
            in: source(idiom, key: "TestingKey()"),
            sourcePath: "Keys.swift",
            module: testModule
        )
        let key = try #require(discovery.testingKeys.first)
        #expect(key.accessLevel == expected)
    }

    /// The symptom #342 reports: an unconsumed key that is public only through its extension's
    /// default warned "no consumer" as though it were internal.
    @Test func unconsumedDefaultedKeyOfPublicExtensionDoesNotWarn() {
        #expect(liveness(in: "public extension Holder { static let services = CollectedKey<any Service>() }").isEmpty)
        #expect(liveness(in: "extension Holder { public static let services = CollectedKey<any Service>() }").isEmpty)
    }

    @Test func unconsumedUnmodifiedKeyOfPlainExtensionStillWarns() throws {
        let diagnostic = try #require(
            liveness(in: "extension Holder { static let services = CollectedKey<any Service>() }").first
        )
        #expect(diagnostic.message.contains("has no consumer"))
    }

    private func liveness(in idiom: String) -> [Diagnostic] {
        let discovery = discover(in: "public enum Holder {}\n" + idiom, sourcePath: "M.swift", module: testModule)
        return multibindingLivenessDiagnostics(
            multibindingKeys: discovery.multibindingKeys,
            bindingsByPartition: discovery.allBindings,
            conformanceConsumedKeys: []
        )
    }

    // MARK: - Bindings

    private func bindings(in source: String, module: String = testModule) -> [DiscoveredBinding] {
        discover(in: source, sourcePath: "Config.swift", module: module).allBindings.values.flatMap { $0 }
    }

    @Test func defaultedProvidesOfPublicExtensionIsPublic() throws {
        let property = try #require(
            bindings(in: "public extension Holder { @Provides static let baseURL: URL = URL(string: \"x\")! }").first
        )
        #expect(property.accessLevel == .public)
        let function = try #require(
            bindings(in: "public extension Holder { @Provides static func makeLogger() -> Logger { Logger() } }")
                .first
        )
        #expect(function.accessLevel == .public)
    }

    @Test func unmodifiedProvidesOfPlainExtensionIsInternal() throws {
        let binding = try #require(
            bindings(in: "extension Holder { @Provides static let baseURL: URL = URL(string: \"x\")! }").first
        )
        #expect(binding.accessLevel == .internal)
    }

    /// A type declared in a `public extension` takes the extension's default too; the default comes
    /// from the frame enclosing the type, not the type's own frame.
    @Test func singletonNestedInPublicExtensionIsPublic() throws {
        let binding = try #require(bindings(in: "public extension Holder { @Singleton struct Inner {} }").first)
        #expect(binding.accessLevel == .public)
    }

    /// Only the immediately enclosing declaration gives the default: a member of a type nested in a
    /// `public extension` is `internal`, like any type's member.
    @Test func memberOfTypeNestedInPublicExtensionIsInternal() throws {
        let discovery = discover(
            in:
                "public enum Holder {}\npublic extension Holder { enum Keys { static let key = BindingKey<Database>() } }",
            sourcePath: "Keys.swift",
            module: testModule
        )
        let key = try #require(discovery.bindingKeys.first)
        #expect(key.accessLevel == .internal)
    }

    /// The #441 symptom: a sibling module's defaulted `@Provides` in a `public extension` falsely
    /// failed the cross-module visibility check as `internal`.
    @Test func siblingModuleDefaultedProvidesOfPublicExtensionPassesCrossModuleCheck() {
        let defaulted = bindings(
            in: "public extension Holder { @Provides static let config: Config = Config() }",
            module: "Sibling"
        )
        #expect(defaulted.count == 1)
        #expect(
            crossModuleVisibilityDiagnostics(bindings: defaulted, consumerModule: "App", externalModules: [])
                .isEmpty
        )
        let unmodified = bindings(
            in: "extension Holder { @Provides static let config: Config = Config() }",
            module: "Sibling"
        )
        let diagnostics = crossModuleVisibilityDiagnostics(
            bindings: unmodified,
            consumerModule: "App",
            externalModules: []
        )
        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.message.contains("'Config' is 'internal'") == true)
    }

    /// A provider with no modifier in a `private extension` defaults to `fileprivate`, but the
    /// too-private error still blames the extension, which is where the fix belongs.
    @Test func defaultedProvidesOfPrivateExtensionBlamesTheExtension() throws {
        let discovery = discover(
            in: "private extension Holder { @Provides static let config: Config = Config() }",
            sourcePath: "Config.swift",
            module: testModule
        )
        let binding = try #require(discovery.allBindings.values.flatMap { $0 }.first)
        #expect(binding.accessLevel == .fileprivate)
        let errors = discovery.warnings.filter { $0.severity == .error }
        #expect(errors.count == 1)
        #expect(errors.first?.message.contains("because its enclosing scope 'Holder' is 'private'") == true)
    }
}
