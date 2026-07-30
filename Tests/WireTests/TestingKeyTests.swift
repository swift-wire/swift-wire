import Testing

@testable import Wire

// `TestingKey`'s runtime identity. A key is passed to an adapter's suite trait as a *value*, and the value
// has to say which declaration it came from — its declaring reference is a compile-time name the value does
// not carry. The `#fileID`/`#line` defaults on `init` make the declaration site that identity, and equality
// is the whole contract: a generated dispatch reconstructs `TestingKey(fileID:line:)` for each variant it
// emitted and matches the key it was handed against them.

@Suite struct TestingKeyTests {
    // Two keys declared on separate lines — the ordinary shape, one variant each.
    private enum Keys {
        static let first = TestingKey()
        static let second = TestingKey()
    }

    /// Distinct declarations are distinct keys. Without this a target with two keys could not say which
    /// variant graph a suite meant.
    @Test func distinctDeclarationsAreDistinct() {
        #expect(Keys.first != Keys.second)
    }

    /// The same declaration read twice is the same key — the value is stable, not freshly identified per
    /// access, so a suite trait and a later lookup agree.
    @Test func theSameDeclarationIsStable() {
        #expect(Keys.first == Keys.first)
        #expect(Keys.first.hashValue == Keys.first.hashValue)
    }

    /// The identity a code generator reconstructs: passing the declaration's `#fileID`/`#line` explicitly
    /// produces a value equal to the declared key. This is exactly what a generated `switch` over variants
    /// relies on, and it is why the generator must reproduce the *call site* of `TestingKey()`.
    @Test func anExplicitlyReconstructedKeyMatchesItsDeclaration() {
        let reconstructed = TestingKey(fileID: #fileID, line: 14)
        #expect(reconstructed == Keys.first)
        #expect(reconstructed != Keys.second)
    }

    // A declaration split across lines: the `static let` is on one line, the `TestingKey()` call on the
    // next. Which line the key carries is the precision requirement a generator has to meet.
    private enum SplitKeys {
        static let split =
            TestingKey()
    }

    /// `#line` is stamped at the `TestingKey()` **call expression**, not at the `static let` that binds it.
    /// A generator that recorded the declaration's line would emit a dispatch that silently matches nothing
    /// for any key written this way, so this pins the rule down.
    @Test func theLineIsTheInitCallNotTheDeclaration() {
        let atInitCall = TestingKey(fileID: #fileID, line: 44)
        let atDeclaration = TestingKey(fileID: #fileID, line: 43)
        #expect(atInitCall == SplitKeys.split)
        #expect(atDeclaration != SplitKeys.split)
    }

    /// A key is `Hashable`, so a dispatch may index variants by key rather than chain comparisons.
    @Test func keysAreUsableAsDictionaryKeys() {
        let variants = [Keys.first: "A", Keys.second: "B"]
        #expect(variants[Keys.first] == "A")
        #expect(variants[Keys.second] == "B")
    }
}
