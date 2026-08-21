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
///         try Configuration<String>.wireValue(from: _wireProvider, forKey: "couchdb.host", default: "localhost")
///     }
///
/// Wire copies the annotation's argument list **verbatim** — it does not read the labels, the key, or the
/// default — and appends it to a static `wireValue(from:)`. So it never learns what the value means or how
/// it is read. That lives in the wrapper, as ordinary Swift, type-checked where the user writes it: an
/// annotated site whose type the wrapper has no initialiser for fails to compile at the annotation,
/// naming the types it does support.
///
/// The wrapper therefore plays two separable roles, and they stay separate: its **initialisers** are the
/// attachment role (carry the value the compiler passes at the use site), and a **static**
/// `wireValue(from:…)` is the resolution role (read the value, given a provider). Wire constructs no
/// instance to resolve, so nothing has to pretend to hold a value it does not have.
///
/// Implementing one is the whole contract: conform the wrapper, add a `wireValue` overload per supported
/// shape, and declare `.rewritesInjection(provider:)` naming the provider's type as written.
public protocol WireInjectionRewrite {
    /// The binding the synthesised producer depends on — where the value is read from. Wire resolves it
    /// like any other dependency, so the graph must bind it (as a `@Provides`, or a `@GraphInputs` value
    /// the caller passes to `Wire.bootstrap(inputs:)`).
    ///
    /// This is all the protocol requires. Resolution itself is a **static** method Wire calls
    /// structurally — `wireValue(from:)` plus the annotation's own arguments — which cannot be a protocol
    /// requirement, because its signature is whatever the annotation's arguments are. That is the same
    /// footing the wrapper's initialisers are already on: an annotation whose arguments match no
    /// initialiser fails at the use site, and one whose arguments match no `wireValue` overload fails the
    /// first time it is wired.
    associatedtype Provider
}
