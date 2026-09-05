// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Testing

@testable import WireGenCore

/// Imports reach the generated files from every source file discovery parses — the consumer's and, under
/// cross-module composition, its Wire-aware dependencies' — each written at whatever access level suited
/// the file it came from, and some re-exporting. These pin the canonical form the generated files carry
/// instead: one import per module, at internal level, re-exporting nothing.
@Suite("ImportNormalization")
struct ImportNormalizationTests {
    @Test("One module reached at several access levels collapses to one internal import")
    func collapsesAccessLevels() {
        #expect(
            normalizedImports([
                "import Wire",
                "public import Wire",
                "package import Wire",
                "private import Wire",
            ]) == ["import Wire"]
        )
    }

    @Test("The access-level modifier is dropped, whatever it was")
    func dropsAccessModifier() {
        #expect(normalizedImports(["public import Logging"]) == ["import Logging"])
        #expect(normalizedImports(["package import Configuration"]) == ["import Configuration"])
        #expect(normalizedImports(["fileprivate import Yams"]) == ["import Yams"])
    }

    /// A dependency's re-export is not the consumer's to inherit: carried over, the module holding the
    /// generated file would re-export whatever that dependency does.
    @Test("`@_exported` is dropped — a re-export is not propagated")
    func dropsExported() {
        #expect(normalizedImports(["@_exported public import HTTPAPIs"]) == ["import HTTPAPIs"])
        #expect(
            normalizedImports([
                "@_exported public import HTTPTypes",
                "import HTTPTypes",
                "package import HTTPTypes",
            ]) == ["import HTTPTypes"]
        )
    }

    /// Attributes grant things the generated file may need — SPI declarations, a concurrency relaxation,
    /// internal visibility — and it composes code from every file they came from, so they are unioned
    /// rather than picked from one spelling.
    @Test("Attributes are kept, and unioned across spellings")
    func unionsAttributes() {
        #expect(
            normalizedImports([
                "@_spi(Generated) public import OpenAPIRuntime",
                "@preconcurrency import OpenAPIRuntime",
                "import OpenAPIRuntime",
            ]) == ["@_spi(Generated) @preconcurrency import OpenAPIRuntime"]
        )
        #expect(normalizedImports(["@testable import Controllers"]) == ["@testable import Controllers"])
    }

    @Test("An import-kind specifier is part of the import's identity, and is kept")
    func keepsKindSpecifier() {
        #expect(
            normalizedImports(["public import struct Foundation.Data", "import Foundation"])
                == ["import Foundation", "import struct Foundation.Data"]
        )
    }

    /// The platform-selection block is captured whole by discovery, so normalisation has to reach the
    /// imports *inside* it — an access level or a re-export written in one clause would otherwise be the
    /// one place the rule does not apply.
    @Test("Imports inside an `#if` block normalise too, guard and all")
    func normalizesInsideIfConfig() {
        let block = """
            #if canImport(FoundationEssentials)
            @_exported public import FoundationEssentials
            #else
            package import Foundation
            #endif
            """
        #expect(
            normalizedImports([block]) == [
                """
                #if canImport(FoundationEssentials)
                import FoundationEssentials
                #else
                import Foundation
                #endif
                """
            ]
        )
    }

    @Test("Output is sorted and deduplicated for stability across runs")
    func sortsAndDeduplicates() {
        #expect(
            normalizedImports(["import Wire", "import HTTPTypes", "public import Wire"])
                == ["import HTTPTypes", "import Wire"]
        )
    }

    @Test("The emitted files carry the canonical form")
    func emittersNormalize() {
        let imports = [
            "public import Wire",
            "import Wire",
            "package import Wire",
            "@_exported public import HTTPAPIs",
            "import HTTPAPIs",
        ]
        let graph = renderWireGraph(imports: imports, topologicalOrder: [])
        let checks = renderWireKeyChecks(imports: imports, allBindings: [])
        for generated in [graph, checks] {
            #expect(generated.contains("\nimport Wire\n"))
            #expect(generated.contains("\nimport HTTPAPIs\n"))
            #expect(!generated.contains("public import"))
            #expect(!generated.contains("package import"))
            #expect(!generated.contains("@_exported"))
        }
    }
}
