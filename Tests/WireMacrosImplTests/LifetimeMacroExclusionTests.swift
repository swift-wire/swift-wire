import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

@testable import WireMacrosImpl

/// `@Singleton`, `@Scoped(seed:)` and `@Factory(key)` each name a lifetime, and a declaration has one.
///
/// The point of these tests is the *expansion*, not only the message: before this, two lifetime macros
/// each synthesised an initialiser from the same `@Inject` members and the user got
/// `invalid redeclaration of 'init(…)'` — a name collision standing in for a contradiction, from which
/// nothing about the mistake could be read. The expanded sources below show one `init`, so the collision
/// is not merely diagnosed alongside; it stops being reachable.
final class LifetimeMacroExclusionTests: XCTestCase {
    let macros: [String: Macro.Type] = [
        "Singleton": SingletonMacro.self,
        "Scoped": ScopedMacro.self,
        "Factory": FactoryMacro.self,
        "Inject": InjectMacro.self,
    ]

    func test_singletonThenFactory_diagnosesOnceAndSynthesisesOneInit() {
        // `@Singleton` is first, so it expands normally — one `init`, one `static key`. `@Factory` is
        // superseded: it reports, and synthesises nothing.
        assertMacroExpansion(
            """
            @Singleton
            @Factory(ControllerMiddleware.screenAccess)
            struct ScreenAccess<Ctx> {
                @Inject var engine: PolicyEngine
            }
            """,
            expandedSource: """
                struct ScreenAccess<Ctx> {
                    var engine: PolicyEngine

                    init(engine: PolicyEngine) {
                        self.engine = engine
                    }

                    static var key: BindingKey<ScreenAccess<Ctx>> {
                        BindingKey<ScreenAccess<Ctx>>()
                    }
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "@Factory and @Singleton both declare a lifetime, and a declaration has one. @Singleton is one instance for the process, @Scoped(seed:) one per scope entry, and @Factory no scope at all — its template is constructed per `create` call, and the binding with a lifetime is the factory Wire synthesises for the key. Remove @Factory.",
                    line: 2,
                    column: 1,
                    severity: .error
                )
            ],
            macros: macros
        )
    }

    func test_factoryThenSingleton_reportsTheLaterAttribute() {
        // Source order decides, not macro identity: whichever lifetime macro is written second is the
        // one reported and the one that synthesises nothing. That keeps the diagnostic pointing at an
        // attribute the user can delete, and keeps exactly one `init` in either arrangement — here the
        // `@Factory` one, which carries no `static key`.
        assertMacroExpansion(
            """
            @Factory(ControllerMiddleware.screenAccess)
            @Singleton
            struct ScreenAccess<Ctx> {
                @Inject var engine: PolicyEngine
            }
            """,
            expandedSource: """
                struct ScreenAccess<Ctx> {
                    var engine: PolicyEngine

                    init(engine: PolicyEngine) {
                        self.engine = engine
                    }
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "@Singleton and @Factory both declare a lifetime, and a declaration has one. @Singleton is one instance for the process, @Scoped(seed:) one per scope entry, and @Factory no scope at all — its template is constructed per `create` call, and the binding with a lifetime is the factory Wire synthesises for the key. Remove @Singleton.",
                    line: 2,
                    column: 1,
                    severity: .error
                )
            ],
            macros: macros
        )
    }

    func test_scopedAndFactory_isTheCombinationTheFixItUsedToRecommend() {
        // The exact spelling `PendingIssues/16`'s fix-it told a reader to write. It is refused here, which
        // is what lets the cross-scope note offer moves that exist instead.
        assertMacroExpansion(
            """
            @Factory(ControllerMiddleware.screenAccess)
            @Scoped(seed: HTTPRequest.self)
            struct ScreenAccess<Ctx> {
                @Inject var caller: Caller
            }
            """,
            expandedSource: """
                struct ScreenAccess<Ctx> {
                    var caller: Caller

                    init(caller: Caller) {
                        self.caller = caller
                    }
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "@Scoped and @Factory both declare a lifetime, and a declaration has one. @Singleton is one instance for the process, @Scoped(seed:) one per scope entry, and @Factory no scope at all — its template is constructed per `create` call, and the binding with a lifetime is the factory Wire synthesises for the key. Remove @Scoped.",
                    line: 2,
                    column: 1,
                    severity: .error
                )
            ],
            macros: macros
        )
    }

    func test_oneLifetimeMacro_isUnaffected() {
        // The regression guard: a well-formed declaration expands byte-for-byte as it did before, with
        // no diagnostic. The exclusion check runs on every expansion, so this is the case that matters.
        assertMacroExpansion(
            """
            @Factory(MyMiddleware.session)
            struct SessionMiddleware<Ctx> {
                @Inject var store: SessionStore
            }
            """,
            expandedSource: """
                struct SessionMiddleware<Ctx> {
                    var store: SessionStore

                    init(store: SessionStore) {
                        self.store = store
                    }
                }
                """,
            macros: macros
        )
    }
}
