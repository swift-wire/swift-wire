/// The seam a `.rewritesInjection` annotation implements — the one thing Wire's generated code calls on it.
///
/// An injection-rewriting annotation is a property wrapper attached to an injection site: an `@Inject`
/// property, an `@Inject init` parameter, or a `@Provides func` parameter. The site stops resolving by its
/// own type and instead resolves to a binding Wire synthesises, which reads the value out of a *provider*
/// the graph supplies:
///
///     @Provides static func couchDB(
///         @Configuration(forKey: "couchdb.host", default: "localhost") host: String
///     ) -> Client
///
///     // Wire synthesises, and `host` resolves to it:
///     private func _wireRewrite_…(_wireProvider: Configuration<String>.Provider) throws -> String {
///         try Configuration<String>(forKey: "couchdb.host", default: "localhost").wireValue(from: _wireProvider)
///     }
///
/// Wire copies the annotation's argument list **verbatim** — it does not read the labels, the key, or the
/// default — and calls ``wireValue(from:)``. So it never learns what the value means or how it is read.
/// That lives in the wrapper's own initialisers, as ordinary Swift, type-checked where the user writes it:
/// an annotated site whose type the wrapper has no initialiser for fails to compile at the annotation,
/// naming the types it does support.
///
/// Implementing one is the whole contract: conform the wrapper, and declare
/// `.rewritesInjection(provider:)` naming the provider's type as written.
public protocol WireInjectionRewrite {
    /// The binding the synthesised producer depends on — where the value is read from. Wire resolves it
    /// like any other dependency, so the graph must bind it (as a `@Provides`, or a `@GraphInputs` value
    /// the caller passes to `Wire.bootstrap(inputs:)`).
    associatedtype Provider

    /// The value the annotated site receives.
    associatedtype Value

    /// Read the value. Called once per construction of the synthesised binding, so a value read this way
    /// has the scope of that binding — app scope unless the annotated site is itself scoped.
    func wireValue(from provider: Provider) throws -> Value
}
