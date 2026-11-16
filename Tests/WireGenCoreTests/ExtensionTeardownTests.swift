// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Testing

@testable import WireGenCore

/// swift-wire#429 — a member `@Teardown` declared in an extension of a `@Singleton`/`@Scoped` type is
/// recorded as if it were declared in the type's body, with the same shape checks and the same
/// one-teardown-per-type rule. The extension may sit in another file, so discovery only records a
/// candidate per method and `attachExtensionTeardowns` joins it once every file is read; these tests
/// drive that join the way `WireGen` does, over one discovery per file.
@Suite("Extension teardown")
struct ExtensionTeardownTests {
    /// The bindings and the join's diagnostics for `files`, discovered in order and joined module-wide.
    private func join(
        _ files: [(path: String, source: String)],
        module: (String) -> String = { _ in testModule }
    ) -> (bindings: [DiscoveredScopeBoundType], diagnostics: [Diagnostic]) {
        var allBindings: [Partition: [DiscoveredBinding]] = [:]
        var candidates: [ExtensionTeardownCandidate] = []
        var diagnostics: [Diagnostic] = []
        for file in files {
            let discovery = discover(in: file.source, sourcePath: file.path, module: module(file.path))
            for (partition, bindings) in discovery.allBindings {
                allBindings[partition, default: []] += bindings
            }
            candidates += discovery.extensionTeardowns
            diagnostics += discovery.warnings
        }
        diagnostics += attachExtensionTeardowns(candidates, to: &allBindings)
        let bindings = allBindings.values.flatMap { $0 }.compactMap { binding -> DiscoveredScopeBoundType? in
            if case .scopeBound(let scopeBound) = binding { return scopeBound }
            return nil
        }
        return (bindings, diagnostics)
    }

    private func memberName(_ binding: DiscoveredScopeBoundType?) -> String? {
        guard case .member(let name, _, _)? = binding?.teardown?.kind else { return nil }
        return name
    }

    // MARK: - Recorded

    @Test func aTeardownInAnExtensionInTheSameFileIsRecorded() {
        let result = join([
            (
                "Pool.swift",
                """
                @Singleton(allowUnused: true)
                final class Pool {
                    @Inject init() {}
                }

                extension Pool {
                    @Teardown func close() async throws {}
                }
                """
            )
        ])
        guard case .member(let name, let isAsync, let isThrowing)? = result.bindings.first?.teardown?.kind else {
            Issue.record("expected the extension's teardown to be recorded")
            return
        }
        #expect(name == "close")
        #expect(isAsync)
        #expect(isThrowing)
        #expect(result.bindings.first?.teardown?.location.formattedPrefix == "Pool.swift:7:20")
        #expect(result.diagnostics.isEmpty)
    }

    @Test func aTeardownInAnExtensionInAnotherFileIsRecordedWhicheverFileIsReadFirst() {
        let type = (
            path: "Pool.swift",
            source: """
            @Singleton(allowUnused: true)
            final class Pool {
                @Inject init() {}
            }
            """
        )
        let extensionFile = (
            path: "Pool+Teardown.swift",
            source: """
            extension Pool {
                @Teardown func close() {}
            }
            """
        )
        for files in [[type, extensionFile], [extensionFile, type]] {
            let result = join(files)
            #expect(memberName(result.bindings.first) == "close")
            #expect(result.diagnostics.isEmpty)
        }
    }

    @Test func aTeardownInAnExtensionOfANestedTypeIsRecorded() {
        let result = join([
            (
                "Nested.swift",
                """
                @Container
                enum Infra {
                    @Singleton(allowUnused: true)
                    final class Pool {
                        @Inject init() {}
                    }
                }

                extension Infra.Pool {
                    @Teardown func close() {}
                }
                """
            )
        ])
        #expect(memberName(result.bindings.first) == "close")
        #expect(result.diagnostics.isEmpty)
    }

    @Test func aTeardownInAnExtensionOfAScopedTypeIsRecorded() {
        let result = join([
            (
                "Tx.swift",
                """
                @Scoped(seed: RequestSeed.self)
                struct RequestTx {
                    @Inject init() {}
                }

                extension RequestTx {
                    @Teardown func rollback() async {}
                }
                """
            )
        ])
        #expect(memberName(result.bindings.first) == "rollback")
        #expect(result.diagnostics.isEmpty)
    }

    @Test func aJoinedTeardownIsCalledByTheGeneratedGraph() throws {
        let result = join([
            (
                "Pool.swift",
                """
                @Singleton(allowUnused: true)
                final class Pool {
                    @Inject init() {}
                }

                extension Pool {
                    @Teardown func close() async throws {}
                }
                """
            )
        ])
        let pool = try #require(result.bindings.first)
        let output = renderWireGraph(imports: [], topologicalOrder: [.scopeBound(pool)])
        #expect(output.contains("let _wireTeardown: @Sendable () async -> [any Error]"))
        #expect(output.contains("try await pool.close()"))
    }

    // MARK: - Shape checks

    @Test func aStaticTeardownInAnExtensionIsAnErrorAndRecordsNothing() {
        let result = join([
            (
                "Pool.swift",
                """
                @Singleton(allowUnused: true)
                final class Pool {
                    @Inject init() {}
                }
                """
            ),
            (
                "Pool+Teardown.swift",
                """
                extension Pool {
                    @Teardown static func close() {}
                }
                """
            ),
        ])
        #expect(
            renderDiagnostics(result.diagnostics)
                == "Pool+Teardown.swift:2:27: error: @Teardown method 'close' is 'static' — teardown runs on the constructed instance, so the method must be an instance method."
        )
        #expect(result.bindings.first?.teardown == nil)
    }

    @Test func aTeardownWithParametersInAnExtensionIsAnError() {
        let result = join([
            (
                "Pool.swift",
                """
                @Singleton(allowUnused: true)
                final class Pool {
                    @Inject init() {}
                }

                extension Pool {
                    @Teardown func close(other: Int) {}
                }
                """
            )
        ])
        #expect(
            renderDiagnostics(result.diagnostics)
                == "Pool.swift:7:20: error: @Teardown method 'close' takes parameters — a teardown method must take none (it is called on the instance with no resolved dependencies)."
        )
        #expect(result.bindings.first?.teardown == nil)
    }

    @Test func anArgumentOnATeardownInAnExtensionIsAnError() {
        let result = join([
            (
                "Pool.swift",
                """
                @Singleton(allowUnused: true)
                final class Pool {
                    @Inject init() {}
                }

                extension Pool {
                    @Teardown({ (p: Pool) in }) func close() {}
                }
                """
            )
        ])
        #expect(
            renderDiagnostics(result.diagnostics)
                == "Pool.swift:7:38: error: the owned-type @Teardown takes no argument — it marks the teardown method on a @Singleton/@Scoped type. Remove the argument; the action-carrying form '@Teardown({ ... })' belongs on a @Provides."
        )
        #expect(result.bindings.first?.teardown == nil)
    }

    @Test func aPrivateTeardownInAnExtensionIsAnErrorButStillRecorded() {
        let result = join([
            (
                "Pool.swift",
                """
                @Singleton(allowUnused: true)
                final class Pool {
                    @Inject init() {}
                }

                extension Pool {
                    @Teardown private func close() {}
                }
                """
            )
        ])
        #expect(result.diagnostics.count == 1)
        #expect(
            result.diagnostics.first.map { "\($0.location.formattedPrefix): \($0.message)" }
                == "Pool.swift:7:28: @Teardown method 'close' is 'private' but must be at least 'internal' — Wire's generated bootstrap calls it at scope teardown and lives in a separate file. Change to 'internal', 'package', or 'public'."
        )
        #expect(memberName(result.bindings.first) == "close")
    }

    // MARK: - One teardown per type

    @Test func aTeardownInTheBodyAndOneInAnExtensionIsTheDuplicateError() {
        let result = join([
            (
                "Pool.swift",
                """
                @Singleton(allowUnused: true)
                final class Pool {
                    @Inject init() {}
                    @Teardown func first() {}
                }
                """
            ),
            (
                "Pool+Teardown.swift",
                """
                extension Pool {
                    @Teardown func second() {}
                }
                """
            ),
        ])
        #expect(
            renderDiagnostics(result.diagnostics)
                == """
                Pool+Teardown.swift:2:20: error: more than one @Teardown on this type — a binding may declare at most one teardown method.
                Pool.swift:4:20: note: first @Teardown declared here
                """
        )
        #expect(memberName(result.bindings.first) == "first")
    }

    @Test func theBodysTeardownCountsFirstEvenWhenTheExtensionsFileIsReadFirst() {
        let result = join([
            (
                "A+Teardown.swift",
                """
                extension Pool {
                    @Teardown func second() {}
                }
                """
            ),
            (
                "Pool.swift",
                """
                @Singleton(allowUnused: true)
                final class Pool {
                    @Inject init() {}
                    @Teardown func first() {}
                }
                """
            ),
        ])
        #expect(result.diagnostics.map(\.location.formattedPrefix) == ["A+Teardown.swift:2:20"])
        #expect(memberName(result.bindings.first) == "first")
    }

    @Test func teardownsInTwoExtensionsAreTheDuplicateError() {
        let result = join([
            (
                "Pool.swift",
                """
                @Singleton(allowUnused: true)
                final class Pool {
                    @Inject init() {}
                }

                extension Pool {
                    @Teardown func first() {}
                }
                """
            ),
            (
                "Pool+Second.swift",
                """
                extension Pool {
                    @Teardown func second() {}
                }
                """
            ),
        ])
        #expect(
            renderDiagnostics(result.diagnostics)
                == """
                Pool+Second.swift:2:20: error: more than one @Teardown on this type — a binding may declare at most one teardown method.
                Pool.swift:7:20: note: first @Teardown declared here
                """
        )
        #expect(memberName(result.bindings.first) == "first")
    }

    /// As in the body, a second `@Teardown` is the duplicate error whatever its own shape.
    @Test func aMalformedSecondTeardownInAnExtensionIsTheDuplicateError() {
        let result = join([
            (
                "Pool.swift",
                """
                @Singleton(allowUnused: true)
                final class Pool {
                    @Inject init() {}
                    @Teardown func first() {}
                }

                extension Pool {
                    @Teardown static func second() {}
                }
                """
            )
        ])
        #expect(result.diagnostics.map(\.message).allSatisfy { $0.hasPrefix("more than one @Teardown") })
        #expect(result.diagnostics.count == 1)
        #expect(memberName(result.bindings.first) == "first")
    }

    // MARK: - Not joined

    /// An extension of a type that is not a `@Singleton`/`@Scoped` binding is not looked at, as a
    /// `@Teardown` on any unbound type is not: even a malformed one draws nothing.
    @Test func aTeardownInAnExtensionOfAnUnboundTypeIsIgnored() {
        let result = join([
            (
                "Plain.swift",
                """
                struct Plain {}

                @Factory(Keys.access)
                struct Access<T> {
                    @Inject var x: Int
                }

                extension Plain {
                    @Teardown static func close() {}
                }

                extension Access {
                    @Teardown func close() {}
                }

                extension Imported {
                    @Teardown func close(other: Int) {}
                }
                """
            )
        ])
        #expect(result.bindings.isEmpty)
        #expect(result.diagnostics.filter { $0.severity == .error }.isEmpty)
    }

    @Test func aTeardownInAnotherModulesExtensionOfTheTypeIsIgnored() {
        let result = join(
            [
                (
                    "Pool.swift",
                    """
                    @Singleton(allowUnused: true)
                    final class Pool {
                        @Inject init() {}
                    }
                    """
                ),
                (
                    "Other/Pool+Teardown.swift",
                    """
                    extension Pool {
                        @Teardown func close() {}
                    }
                    """
                ),
            ],
            module: { $0.hasPrefix("Other/") ? "Other" : testModule }
        )
        #expect(result.bindings.first?.teardown == nil)
        #expect(result.diagnostics.isEmpty)
    }
}
