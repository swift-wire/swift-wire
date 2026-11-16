// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Testing

@testable import WireGenCore

/// The cross-module-extension warning checks an extension's target against the top-level type names
/// declared in the extension's own module, not in every module WireGen scanned (swift-wire#434). Each test discovers its sources per
/// module and keys the declared names by module, the way WireGen aggregates them.
@Suite("Cross-module extension diagnostics")
struct CrossModuleExtensionDiagnosticsTests {
    /// Discover each `(module, source)` pair and run the warning over every candidate, with the
    /// declared names keyed by the module that declared them.
    private func warnings(for sources: [(module: String, source: String)]) -> [Diagnostic] {
        var candidates: [UnannotatedExtensionProvides] = []
        var declared: [String: Set<String>] = [:]
        for (index, entry) in sources.enumerated() {
            let discovery = discover(in: entry.source, sourcePath: "File\(index).swift", module: entry.module)
            candidates += discovery.unannotatedExtensionProvides
            declared[entry.module, default: []].formUnion(discovery.declaredTypeNames)
        }
        return crossModuleExtensionDiagnostics(
            candidates: candidates,
            containerNames: [],
            declaredTypeNames: declared
        )
    }

    private let extensionOfFoo = """
        extension Foo {
            @Provides static let value: Int = 42
        }
        """

    @Test func firesWhenTheTypeIsDeclaredOnlyInAnotherScannedModule() {
        // `Foo` is declared in the composed dependency `LibA`, not in `App`, so `App`'s extension
        // extends an imported type. The declared names used to be one union across every module
        // WireGen scanned, which silenced this.
        let warnings = warnings(for: [
            (module: "App", source: extensionOfFoo),
            (module: "LibA", source: "public struct Foo {}"),
        ])
        #expect(warnings.count == 1)
        #expect(
            warnings.first?.message
                == "@Provides 'value' in an extension of 'Foo' — 'Foo' isn't declared in this module, so the binding falls through to the default graph and any @Container on 'Foo' elsewhere isn't visible to discovery. Move the declaration to module scope or to a type declared in this module if the fall-through wasn't intentional."
        )
        #expect(warnings.first?.location == SourceLocation(file: "File0.swift", line: 2, column: 26))
    }

    @Test func staysSilentWhenTheTypeIsDeclaredInTheExtensionsOwnModule() {
        // The same `Foo` declared in `App` itself, in another file, with an unrelated dependency.
        let warnings = warnings(for: [
            (module: "App", source: extensionOfFoo),
            (module: "App", source: "struct Foo {}"),
            (module: "LibA", source: "public struct Other {}"),
        ])
        #expect(warnings.isEmpty)
    }

    @Test func checksADependencyModulesExtensionAgainstThatModule() {
        // Candidates from a composed dependency are checked against the dependency's own
        // declarations: `LibA` extending its own `Foo` is silent even though `App` declares no
        // `Foo`, and `App` extending it still warns.
        let warnings = warnings(for: [
            (module: "App", source: extensionOfFoo),
            (module: "LibA", source: "public struct Foo {}\n" + extensionOfFoo),
        ])
        #expect(warnings.map(\.location.file) == ["File0.swift"])
    }
}
