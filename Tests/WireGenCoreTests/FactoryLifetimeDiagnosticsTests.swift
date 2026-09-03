import Testing

@testable import WireGenCore

/// `@Factory` is a lifetime in its own right, and it is not a scope. These pin the two halves of saying
/// so from the plugin's side: refusing a scope macro on a template, and — for the case that motivated it
/// — telling a reader who injects a scoped binding into a template something that is actually true.
///
/// The forcing case is #337. The shipped fix-it named `_WireFactory_<key>`, a type the
/// plugin synthesises and the user has no declaration for, and its alternative (annotate the template)
/// took a reader from one error to three. Both halves are asserted here in full, because the failure mode
/// being guarded against is advice that reads plausibly and cannot be followed.
@Suite("FactoryLifetimeDiagnostics")
struct FactoryLifetimeDiagnosticsTests {
    // MARK: - Harness

    /// Discovery → factory synthesis → graph → cross-scope enrichment → rendered text. The factory
    /// synthesis step is what the other diagnostic suites leave out, and it is exactly what puts a
    /// synthesised `_WireFactory_<key>` in the graph as a consumer.
    private func validate(source: String, sourcePath: String) -> String {
        let discovery = discover(in: source, sourcePath: sourcePath, module: testModule)
        let synthesis = applyFactorySynthesis(
            to: discovery.allBindings,
            templates: discovery.factoryTemplates,
            annotations: discovery.adapterAnnotations,
            useSites: discovery.aliasUseSites,
            consumerModule: testModule
        )
        let result = buildDependencyGraph(
            from: synthesis.bindings[.default] ?? [],
            typealiases: discovery.typealiases
        )
        let enriched = enrichMissingBindingsWithCrossScopeHints(
            result,
            consumerPartition: .default,
            allBindings: synthesis.bindings
        )
        return enriched.outcome.validationErrors.map { renderValidationErrors($0) } ?? ""
    }

    /// A `@Factory` template injecting a `@Scoped` binding, with a consumer that demands its key — the
    /// `auth-abac` shape, reduced.
    private let templateInjectingAScopedBinding = """
        enum WireMVCAdapter {
            static let middleware = WireAdapterAnnotationV1(
                annotation: "Middleware", capability: .injectsFromGraph)
        }

        enum ControllerMiddleware {
            static let screenAccess = FactoryKey()
        }

        struct HTTPRequest {}

        @Singleton
        struct PolicyEngine {}

        @Scoped(seed: HTTPRequest.self)
        struct Caller {}

        @Factory(ControllerMiddleware.screenAccess)
        struct ScreenAccess<Ctx> {
            @Inject var engine: PolicyEngine
            @Inject var caller: Caller
        }

        @Singleton
        @Middleware(ControllerMiddleware.screenAccess)
        struct DocumentsController {}
        """

    // MARK: - The cross-scope note

    @Test func aTemplateInjectingAScopedBindingIsNamedByTheTemplate() {
        // The synthesised factory is what consumes `Caller`, but naming it in the advice is what made the
        // old fix-it unfollowable: `_WireFactory_ControllerMiddleware_screenAccess` is not a declaration
        // the user wrote, so there is nothing to go and change. The note names `ScreenAccess`.
        let rendered = validate(source: templateInjectingAScopedBinding, sourcePath: "App.swift")
        #expect(rendered.contains("error: no binding produces 'Caller'"))
        #expect(rendered.contains("'ScreenAccess' is a @Factory template"))
        #expect(!rendered.contains("scope '_WireFactory_ControllerMiddleware_screenAccess'"))
    }

    @Test func theNoteStatesTheConstraintThatActuallyBites() {
        // Not "this type is in the wrong scope" — a template has no scope at all. What bites is *when*
        // its `@Inject` members resolve: once, where the synthesised factory is constructed. The
        // template's own per-`create` lifetime was never the obstacle, and a reader who thinks it was
        // will reach for a scope macro, which is how the old advice arose.
        let rendered = validate(source: templateInjectingAScopedBinding, sourcePath: "App.swift")
        #expect(rendered.contains("constructed per `create` call"))
        #expect(rendered.contains("its @Inject members resolve once"))
        #expect(rendered.contains("A @Scoped(seed: HTTPRequest.self) binding can't be one of them"))
    }

    @Test func theNoteOffersOnlyMovesThatCanBeWritten() {
        // The two that exist, and an explicit refusal of the one that does not. Asserting the refusal
        // matters as much as the offers: this is the note a reader reaches after being told a scoped
        // binding is unreachable, and "scope it too" is the first thing they will otherwise try.
        let rendered = validate(source: templateInjectingAScopedBinding, sourcePath: "App.swift")
        #expect(rendered.contains("Produce 'Caller' at @Singleton"))
        #expect(rendered.contains("into a binding that lives in the scope"))
        #expect(rendered.contains("Annotating 'ScreenAccess' with a scope is not a move"))
    }

    @Test func aDeclaredConsumerStillGetsTheOrdinaryAdvice() {
        // The regression guard on the branch. "Scope the consumer too" is right for the ordinary
        // singleton-wants-scoped case, and the factory branch must not have taken it over — the two are
        // told apart by a field on the binding, not by the shape of the mismatch.
        let source = """
            struct HTTPRequest {}

            @Scoped(seed: HTTPRequest.self)
            struct Caller {}

            @Singleton
            struct Auditor {
                @Inject var caller: Caller
            }
            """
        let rendered = validate(source: source, sourcePath: "App.swift")
        #expect(rendered.contains("scope 'Auditor' to @Scoped(seed: HTTPRequest.self) too"))
        #expect(!rendered.contains("@Factory template"))
    }

    // MARK: - The mutual-exclusion diagnostic

    @Test func aScopeMacroOnAFactoryTemplateIsRefused() {
        let source = """
            struct HTTPRequest {}

            @Factory(ControllerMiddleware.screenAccess)
            @Scoped(seed: HTTPRequest.self)
            struct ScreenAccess<Ctx> {
                @Inject var caller: Caller
            }
            """
        let discovery = discover(in: source, sourcePath: "App.swift", module: testModule)
        let errors = discovery.warnings.filter { $0.severity == .error }
        #expect(errors.count == 1)
        #expect(errors.first?.message.contains("carries both @Factory and @Scoped") == true)
        #expect(errors.first?.message.contains("two lifetime macros on one declaration") == true)
    }

    @Test func aRefusedDeclarationIsRecordedAsNeitherRoleRatherThanBoth() {
        // The reason the error is worth having at discovery as well as at expansion. Recorded as both, a
        // template with a scope macro is a binding whose generic parameters must be bound *and* a
        // template whose generic parameters are assisted by definition — so the contradiction resurfaced
        // downstream as a generic-arity error about a type nobody asked to be a singleton. Dropping it
        // from both lists leaves the one error that was reported.
        let source = """
            struct HTTPRequest {}

            @Singleton
            @Factory(ControllerMiddleware.screenAccess)
            struct ScreenAccess<Ctx> {
                @Inject var caller: Caller
            }
            """
        let discovery = discover(in: source, sourcePath: "App.swift", module: testModule)
        #expect(discovery.factoryTemplates.isEmpty)
        #expect(
            !discovery.allBindings.values.joined().contains { $0.boundType == "ScreenAccess" }
        )
    }

    @Test func aTemplateWithNoScopeMacroIsUnaffected() {
        // The case that must keep working: the exclusion check runs on every type declaration.
        let source = """
            @Factory(MyMiddleware.session)
            struct SessionMiddleware<Ctx> {
                @Inject var store: SessionStore
            }
            """
        let discovery = discover(in: source, sourcePath: "App.swift", module: testModule)
        #expect(discovery.warnings.filter { $0.severity == .error }.isEmpty)
        #expect(discovery.factoryTemplates.count == 1)
        #expect(discovery.factoryTemplates.first?.typeName == "SessionMiddleware")
    }
}
