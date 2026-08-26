import Testing

/// Per-subject doubles — each routed subject's `_wireEnterScope` takes a `_<Variant>_<Subject>Doubles`
/// carrying only the slots that subject reaches, rather than every slot the `TestingKey` declares.
///
/// The assertions are mostly *compile-time*: the entry point will not accept the key-wide struct, and naming
/// a field the subject doesn't reach (or omitting one it does) would not build. Each test therefore supplies
/// exactly what it expects to be required — that it compiles is the assertion — then proves the supplied
/// instance actually reaches the subject.
@Suite("SubjectDoubles")
struct SubjectDoublesTests {
    /// `SubjectAlphaController` reaches the alpha slot only, and only *transitively* (through the scope-bound
    /// `SubjectAlphaService`). Its entry takes `subjectAlphaBackend` alone — no beta slot, though the key
    /// declares it — so a BFS that stopped at direct injection would fail to compile this.
    @Test func subjectDoublesCarryOnlyTheSlotsTheSubjectReaches() async throws {
        let graph = try await Wire.bootstrapSubjectDoublesFixture_bindBoth()
        let alpha = MockSubjectAlphaBackend()

        // The memberwise init is exactly (subjectAlphaBackend:). Adding subjectBetaBackend would not compile,
        // and neither would passing the key-wide _SubjectDoublesFixture_bindBothDoubles here.
        let doubles = _SubjectDoublesFixture_bindBoth_SubjectAlphaControllerDoubles(subjectAlphaBackend: alpha)

        let proxy = Wire.bootstrapSubjectDoublesFixture_bindBoth_SubjectAlphaControllerContributor(wireGraph: graph)
        let entered = try await proxy._wireEnterScope(SubjectSeed(id: "x"), doubles)
        let subject = entered._wireSubject
        let teardown = entered._wireScopeTeardown

        // The mock reached the subject through the transitive hop the BFS had to walk to include it.
        #expect(subject.tag() == "mock-alpha:x")
        #expect(alpha.recordedCalls == ["x"])

        let errors = await teardown()
        #expect(errors.isEmpty)
    }

    /// `SubjectBetaController` shares the seed with `SubjectAlphaController`, so the two share one scope and
    /// one scope-wide `doublesFields` — but its entry takes `subjectBetaBackend` alone. This is the pair that
    /// proves the set is per-*subject* and not per-*scope*.
    @Test func siblingSubjectsOnOneSeedGetDisjointDoubles() async throws {
        let graph = try await Wire.bootstrapSubjectDoublesFixture_bindBoth()
        let beta = MockSubjectBetaBackend()

        // Exactly (subjectBetaBackend:) — the sibling's slot is absent from this subject's entry.
        let doubles = _SubjectDoublesFixture_bindBoth_SubjectBetaControllerDoubles(subjectBetaBackend: beta)

        let proxy = Wire.bootstrapSubjectDoublesFixture_bindBoth_SubjectBetaControllerContributor(wireGraph: graph)
        let entered = try await proxy._wireEnterScope(SubjectSeed(id: "y"), doubles)
        let subject = entered._wireSubject
        let teardown = entered._wireScopeTeardown

        #expect(subject.tag() == "mock-beta:y")
        #expect(beta.recordedCalls == ["y"])

        let errors = await teardown()
        #expect(errors.isEmpty)
    }

    /// A subject reaching no mocked slot enters scope supplying *nothing* — the over-specification this whole
    /// idea exists to remove. Under the key-wide struct this route would still have to name both mocks.
    @Test func subjectReachingNoMockEntersScopeWithNoDoubles() async throws {
        let graph = try await Wire.bootstrapSubjectDoublesFixture_bindBoth()

        let doubles = _SubjectDoublesFixture_bindBoth_SubjectPlainControllerDoubles()

        let proxy = Wire.bootstrapSubjectDoublesFixture_bindBoth_SubjectPlainControllerContributor(wireGraph: graph)
        let entered = try await proxy._wireEnterScope(SubjectSeed(id: "z"), doubles)
        let subject = entered._wireSubject
        let teardown = entered._wireScopeTeardown

        #expect(subject.tag() == "plain:z")

        let errors = await teardown()
        #expect(errors.isEmpty)
    }

    /// The key-wide struct is unchanged and still carries every slot — the per-subject structs are additional,
    /// not a replacement. It remains what the per-seed scope façade takes.
    @Test func keyWideDoublesStillCarriesEverySlot() {
        let keyWide = _SubjectDoublesFixture_bindBothDoubles(
            subjectAlphaBackend: MockSubjectAlphaBackend(),
            subjectBetaBackend: MockSubjectBetaBackend()
        )
        #expect(keyWide.subjectAlphaBackend.alpha("a") == "mock-alpha:a")
        #expect(keyWide.subjectBetaBackend.beta("b") == "mock-beta:b")
    }
}
