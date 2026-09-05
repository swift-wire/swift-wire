// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Testing

@testable import WireGenCore

/// `@Inject` is a marker: it does nothing on its own, and is read by whichever macro the enclosing type
/// carries. Warning when nothing reads it is worth doing — the alternative is a dependency that silently
/// never resolves — but the check is only as good as its list of readers, and a wrong "no effect" on a
/// type that *is* wired is worse than no warning at all: it reads as an instruction to change working code,
/// and in a dependency's source it cannot even be acted on.
@Suite("Stray @Inject diagnostic")
struct StrayInjectDiagnosticTests {
    private func warnings(_ source: String) -> [String] {
        discover(in: source, sourcePath: "Source.swift", module: testModule)
            .warnings
            .map(\.message)
            .filter { $0.contains("@Inject") && $0.contains("has no effect") }
    }

    @Test("A type no macro reads gets the warning, per marked member")
    func straySites() {
        let found = warnings(
            """
            struct Loose {
                @Inject var first: Dep
                @Inject var second: Dep
            }
            """
        )
        #expect(found.count == 2)
        #expect(found.contains { $0.contains("'first'") })
        #expect(found.contains { $0.contains("'second'") })
    }

    @Test("An `@Inject init` on such a type is reported too")
    func strayInitialiser() {
        let found = warnings(
            """
            struct Loose {
                @Inject init(dep: Dep) {}
            }
            """
        )
        #expect(found.count == 1)
        #expect(found.first?.contains("this initialiser") == true)
    }

    /// The message enumerates every macro that would make the marker mean something, so the reader does
    /// not have to know the list to act on it.
    @Test("The message names all three readers")
    func messageNamesTheOptions() {
        let message = try! #require(
            warnings(
                """
                struct Loose {
                    @Inject var dep: Dep
                }
                """
            ).first
        )
        #expect(message.contains("@Singleton"))
        #expect(message.contains("@Scoped(seed:)"))
        #expect(message.contains("@Factory(key)"))
    }

    @Test("A scope macro reads them, so there is nothing to warn about")
    func scopeMacrosAreSilent() {
        #expect(warnings("@Singleton struct S { @Inject var dep: Dep }").isEmpty)
        #expect(warnings("@Scoped(seed: RequestSeed.self) struct S { @Inject var dep: Dep }").isEmpty)
    }

    /// The regression this suite exists for. `@Factory` synthesises its initialiser from the type's
    /// `@Inject` members — the plugin resolves them once and stores them on the concrete factory it
    /// synthesises per key — so the marker is read, and a warning here is false. It fired on every
    /// `@Factory` middleware a consumer wrote, and on WireMVC's own `CORSMiddleware`, where the consumer
    /// could not have acted on it.
    @Test("A factory template reads them too")
    func factoryTemplateIsSilent() {
        #expect(
            warnings(
                """
                @Factory(CORSKeys.factory)
                struct CORSMiddleware<Ctx, Reader, Sender> {
                    @Inject var configuration: CORSConfiguration
                }
                """
            ).isEmpty
        )
        #expect(
            warnings("@Factory(Keys.audit) struct Gate { @Inject init(log: AuditLog) {} }").isEmpty
        )
    }

    /// `@Factory` is not a scope, and the `@Container` conflict rule is about scopes — a type is either a
    /// grouping for one graph or a node in another. Recognising the template as an `@Inject` reader must
    /// not quietly make it a scope for that rule as well.
    @Test("Recognising it does not make it a scope for the @Container rule")
    func factoryIsNotAScope() {
        let conflicts = discover(
            in: "@Container @Factory(Keys.k) struct Both { @Inject var dep: Dep }",
            sourcePath: "Source.swift",
            module: testModule
        )
        .warnings
        .map(\.message)
        .filter { $0.contains("@Container") }
        #expect(conflicts.isEmpty)
    }
}
