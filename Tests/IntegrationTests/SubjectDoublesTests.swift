import Testing

/// Per-subject doubles — each routed subject gets a `_<Variant>_<Subject>Doubles` carrying only the slots it
/// reaches, rather than every slot the `TestingKey` declares.
///
/// The assertions are mostly *compile-time*: naming a field the subject doesn't reach, or omitting one it
/// does, would fail to build. Each test therefore constructs the struct with exactly the arguments it expects
/// to be required — that construction succeeding is the assertion — and then proves the supplied instance
/// actually reaches the subject through the variant proxy.
@Suite("SubjectDoubles")
struct SubjectDoublesTests {
    /// `SubjectAlphaController` reaches the alpha slot only, and only *transitively* (through the scope-bound
    /// `SubjectAlphaService`). Its struct takes `alphaBackend` alone — no `subjectBetaBackend`, though the key declares it.
    @Test func subjectDoublesCarryOnlyTheSlotsTheSubjectReaches() async throws {
        let graph = try await Wire.bootstrapSubjectDoublesFixture_bindBoth()
        let alpha = MockSubjectAlphaBackend()

        // Compile-time: the memberwise init is exactly (subjectAlphaBackend:). Adding subjectBetaBackend would not compile.
        let doubles = _SubjectDoublesFixture_bindBoth_SubjectAlphaControllerDoubles(subjectAlphaBackend: alpha)

        // The key-wide struct still carries both — the per-subject structs are additional, not a replacement.
        let keyWide = _SubjectDoublesFixture_bindBothDoubles(
            subjectAlphaBackend: alpha,
            subjectBetaBackend: MockSubjectBetaBackend()
        )
        _ = keyWide

        let proxy = Wire.bootstrapSubjectDoublesFixture_bindBoth_SubjectAlphaControllerContributor(wireGraph: graph)
        let (subject, teardown) = try await proxy._wireEnterScope(SubjectSeed(id: "x"), keyWide)

        // The mock reached the subject through the transitive hop the BFS had to walk to include it.
        #expect(subject.tag() == "mock-alpha:x")
        #expect(alpha.recordedCalls == ["x"])
        _ = doubles

        let errors = await teardown()
        #expect(errors.isEmpty)
    }

    /// `SubjectBetaController` shares the seed with `SubjectAlphaController`, so it shares one scope and one scope-wide
    /// `doublesFields` — but its struct takes `betaBackend` alone. This is the pair that proves the set is
    /// per-*subject* and not per-*scope*.
    @Test func siblingSubjectsOnOneSeedGetDisjointDoubles() async throws {
        let graph = try await Wire.bootstrapSubjectDoublesFixture_bindBoth()
        let beta = MockSubjectBetaBackend()

        // Compile-time: exactly (subjectBetaBackend:) — the sibling's subjectAlphaBackend is absent.
        let doubles = _SubjectDoublesFixture_bindBoth_SubjectBetaControllerDoubles(subjectBetaBackend: beta)
        _ = doubles

        let keyWide = _SubjectDoublesFixture_bindBothDoubles(
            subjectAlphaBackend: MockSubjectAlphaBackend(),
            subjectBetaBackend: beta
        )
        let proxy = Wire.bootstrapSubjectDoublesFixture_bindBoth_SubjectBetaControllerContributor(wireGraph: graph)
        let (subject, teardown) = try await proxy._wireEnterScope(SubjectSeed(id: "y"), keyWide)

        #expect(subject.tag() == "mock-beta:y")
        #expect(beta.recordedCalls == ["y"])

        let errors = await teardown()
        #expect(errors.isEmpty)
    }

    /// A subject reaching no mocked slot gets an empty struct — the over-specification this whole idea exists
    /// to remove. Under the key-wide struct a `/plain` request would still have to name both mocks.
    @Test func subjectReachingNoMockGetsAnEmptyDoublesStruct() async throws {
        let graph = try await Wire.bootstrapSubjectDoublesFixture_bindBoth()

        // Compile-time: the memberwise init takes no arguments at all.
        let doubles = _SubjectDoublesFixture_bindBoth_SubjectPlainControllerDoubles()
        _ = doubles

        let keyWide = _SubjectDoublesFixture_bindBothDoubles(
            subjectAlphaBackend: MockSubjectAlphaBackend(),
            subjectBetaBackend: MockSubjectBetaBackend()
        )
        let proxy = Wire.bootstrapSubjectDoublesFixture_bindBoth_SubjectPlainControllerContributor(wireGraph: graph)
        let (subject, teardown) = try await proxy._wireEnterScope(SubjectSeed(id: "z"), keyWide)

        #expect(subject.tag() == "plain:z")

        let errors = await teardown()
        #expect(errors.isEmpty)
    }
}
