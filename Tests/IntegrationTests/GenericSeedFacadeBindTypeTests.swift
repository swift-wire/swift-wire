import Testing

/// Seed-façade generic gate — a generic `@Scoped(seed:)` subject over an opaque `@BindType`'d
/// backend, entered through the seed façade. The variant app graph drops the mocked `some GenBackend` axis
/// (re-indexing the rest), and the scope concretizes the subject to `GenSeedConsumer<MockGenBackend>`
/// (rather than an illegal stored `some P`); entering the scope with the double resolves the backend to the
/// mock.
@Suite("GenericSeedFacadeBindType")
struct GenericSeedFacadeBindTypeTests {
    @Test func genericSeedSubjectConcretizesToMockOverTheVariantGraph() async throws {
        let graph = try await Wire.bootstrapGenSeedFixture_bindMock()

        let mock = MockGenBackend()
        let doubles = _GenSeedFixture_bindMockDoubles(genBackend: mock)

        let scope = try await Wire.bootstrapGenSeedFixture_bindMock_GenSeedRequestSeedScope(
            seed: GenSeedRequestSeed(id: "req-1"),
            wireGraph: graph,
            doubles: doubles
        )

        #expect(scope.genSeedConsumerOfSomeGenBackend.label() == "mock")
    }
}
