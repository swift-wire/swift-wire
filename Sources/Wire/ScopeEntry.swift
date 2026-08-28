/// The shape a bridging contributor proxy's scope-entry thunk returns — the constructed subject, anything
/// its scope yields alongside, and the closure that tears that scope down.
///
/// Wire synthesises a `_WireScopeEntry_<Subject>` struct per bridged subject and returns it from the
/// thunk, rather than a tuple, so that a scope able to hand back *more* than its subject can grow a field
/// without moving anything a reader already reads. The struct is generated, named after a type the adapter
/// never spells, and generic exactly as its subject — so an adapter's own codegen usually receives one and
/// reads its fields concretely, and needs nothing here.
///
/// **This exists for the case that cannot.** An adapter emitting a *generic* declaration over a
/// request-scoped subject has no name for that subject: the proxy holds a thunk rather than the subject
/// itself, and the concrete type is a specialisation the adapter's emitter deliberately never writes. The
/// tuple made that recoverable structurally — `(Subject, Teardown)` decomposes into generic parameters —
/// and a named struct does not. So the struct carries the projection instead:
///
///     static func noSubject<Seed, Entry: WireScopeEntry>(
///         _ thunk: @Sendable (Seed) async throws -> Entry
///     ) -> Entry.Subject? { nil }
///
/// which recovers the subject's type from the thunk without ever naming it. (WireOpenAPI needs exactly
/// this, for a conformer field whose type it cannot otherwise write.)
///
/// `Sendable` because an entry crosses an async boundary out of the `@Sendable` thunk that built it; every
/// synthesised entry is.
///
/// > Note: the requirements are spelled with their leading underscores because they *are* the generated
/// > field names — the protocol describes a synthesised type rather than proposing a convention, and a
/// > tidier spelling here would be one the emitted struct does not satisfy. (Write neither the linter's
/// > suppression token nor an example of one in prose anywhere in this file: SwiftLint scans comments for
/// > them and reports the surrounding words as rules that do not exist.)
public protocol WireScopeEntry: Sendable {
    /// The subject the scope entry constructed — the type an adapter cannot otherwise name.
    associatedtype Subject

    // The two requirements below keep their leading underscores because they *are* the synthesised
    // struct's field names: a tidier spelling would be one the emitted type does not satisfy. Disabled as
    // a region rather than per declaration, so each doc comment stays adjacent to what it documents.
    // swiftlint:disable identifier_name

    /// The constructed subject.
    var _wireSubject: Subject { get }

    /// The scope's teardown, to run after the response. Collects errors rather than throwing, matching the
    /// graph's own `teardown()`; a caller that ignores the result discards them deliberately.
    ///
    /// Exposed alongside the subject rather than left to the concrete type because entering a scope and
    /// tearing it down are one contract: generic code holding an entry it cannot name still has to be able
    /// to end the scope it opened. A yield, by contrast, is per-subject and has no place in a protocol —
    /// it is read off the concrete entry, whose fields the adapter's codegen does know.
    var _wireScopeTeardown: @Sendable () async -> [any Error] { get }

    // swiftlint:enable identifier_name
}
