/// A namespace identifier for a *test-graph variant* — the config a test target
/// selects to substitute bindings under test.
///
/// `TestingKey` joins Wire's key family (`BindingKey<Value>` / `FactoryKey` /
/// `CollectedKey` / `MappedKey` / `BuilderKey`), and like `FactoryKey` it is a
/// pure *namespace token*: its identity is the *canonical text* of its declaring
/// reference (`MyTests.testSetup`), from which the build plugin derives the
/// variant's doubles-struct type name (`_MyTests_testSetupDoubles`).
///
/// Declare one as a static member and attach `@BindType` (and, from Phase 2,
/// `@Scopable`) to it to describe the substitutions the variant applies:
///
///     enum MyTests {
///         @BindType(BackendRepository.self, MockBackendRepository.self)
///         static let testSetup = TestingKey()
///     }
///
/// One key is one test-graph variant: two suites wanting different substitutions
/// use two keys. It mirrors `@Container` selection, for tests — the substitutions
/// live only in the test graph, so the production graph is untouched. The
/// substituted slot is sourced from a per-scope-entry *doubles* value the test
/// holds and inspects, threaded into the scope exactly as the scope's seed is.
///
/// ## Runtime identity
///
/// The *declaration* is what codegen sees, but a key is also passed around as a
/// **value** — an adapter's suite trait takes one to select which variant graph
/// to serve (`@Suite(.wiremvc(MyTests.testSetup))`). A plain value carries none
/// of its declaring reference, and the reference is a compile-time name, so the
/// value alone cannot say *which* generated variant it means.
///
/// Its **source location** bridges that: `init` captures its own call site
/// through `#fileID`/`#line` default arguments, so `TestingKey()` — written
/// exactly as before — yields a value that is unique per declaration and
/// reproducible by a code generator reading the same source. A generated
/// dispatch can then compare against `TestingKey(fileID:line:)` values it
/// reconstructs for each variant it emitted; both come from one source in one
/// build, so they cannot drift.
///
/// No adapter dispatches on this yet — wire-mvc serves one key per target and
/// rejects a second (`PendingIssues/11`), because serving several needs the
/// per-key doubles model reworked, not this identity. The capture is here
/// because it is the piece that would otherwise be missing, and it is free.
///
/// The captured location is deliberately not readable: it exists for that
/// dispatch, and equality is the whole contract. Two keys declared at the same
/// location are the same key; anywhere else, different.
public struct TestingKey: Sendable, Hashable {
    /// `#fileID` of the `TestingKey()` call — `ModuleName/FileName.swift`.
    private let fileID: String
    /// `#line` of the `TestingKey()` call.
    private let line: Int

    /// A key identified by where it is declared. Both parameters default to the
    /// call site, so a declaration is written `TestingKey()`; a code generator
    /// reconstructing a key for its dispatch passes them explicitly.
    public init(fileID: String = #fileID, line: Int = #line) {
        self.fileID = fileID
        self.line = line
    }
}
