// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Testing

/// The `@Scopable` cascade's gate — the `@Scopable` cascade runtime chain: variant seed scope → the app-scoped
/// `@Singleton` consumer is lifted in and reconstructed per scope entry, so its **init-time** read of the
/// `@BindType`d dependency sees the per-entry double. This is the cascade's distinguishing property over the
/// per-call proxy alternative (which would miss the init read). Hand-builds the `doubles` (standing in for
/// the not-yet-built adapter witness) and drives the generated `bootstrap…Scope(seed:wireGraph:doubles:)`.
@Suite("ScopableCascade")
struct ScopableCascadeTests {
    @Test func liftedSingletonReadsDoubleAtInit() async throws {
        // The variant builds its own app graph — the lifted controller + repository are dropped from it, so
        // their eager inits don't run at app bootstrap; the seed scope reconstructs them per entry.
        let graph = try await Wire.bootstrapWireScopableFixture_bindMockRepo()

        // "Registry-style" B proof: the eager `@Singleton AccountController` (whose `init` reads the repo —
        // the overlay-leak analog of a registry/pool connecting at construction) and its `@BindType`'d
        // `any AccountRepository` are absent from the variant app graph, so neither is constructed under
        // `Wire.bootstrapWireScopableFixture_bindMockRepo()`.
        let variantBindings = graph.introspect().bindings.map(\.type)
        #expect(!variantBindings.contains("AccountController"))
        #expect(!variantBindings.contains("any AccountRepository"))
        // The keyless production graph keeps both (the real suite constructs the eager singleton).
        let productionBindings = try await Wire.bootstrap().introspect().bindings.map(\.type)
        #expect(productionBindings.contains("AccountController"))
        #expect(productionBindings.contains("any AccountRepository"))

        // The test constructs and holds the mock, then supplies it through the generated doubles struct.
        let mock = MockAccountRepository()
        let doubles = _WireScopableFixture_bindMockRepoDoubles(accountRepository: mock)

        // The generated scope-entry threads the doubles alongside the seed and reconstructs the lifted
        // singleton controller — whose `init` reads the repository.
        let scope = try await Wire.bootstrapWireScopableFixture_bindMockRepo_AccountRequestSeedScope(
            seed: AccountRequestSeed(id: "req-1"),
            wireGraph: graph,
            doubles: doubles
        )

        // The reconstructed controller captured its `tag` at `init` from the supplied mock — `"mock:init"`,
        // not the production `RealAccountRepository`'s `"real:init"`. The mock recorded the init-time call,
        // proving the exact supplied instance flowed into the lifted consumer's constructor.
        #expect(scope.accountController.tag == "mock:init")
        #expect(mock.recordedTags == ["init"])

        // The seed root, borrowing nothing, observes the same lifted controller.
        #expect(scope.accountRequestController.handle() == "mock:init")
    }
}
