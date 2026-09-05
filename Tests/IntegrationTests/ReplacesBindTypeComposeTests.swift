// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Testing
import WireTestLibrary

/// `@Replaces` + `@BindType` composition gate. The precedence chain per type is
///     real → `@Replaces` (all graphs) → `@BindType` (its keyed variant only, wins).
/// Proves the combination compiles (no `multiple bindings; ambiguous`), the keyless scope-entry resolves to
/// the `@Replaces` Fake, the keyed variant (with doubles) resolves to the `@BindType` Mock, and the real
/// binding is never constructed in either path.
@Suite("ReplacesBindTypeCompose")
struct ReplacesBindTypeComposeTests {
    @Test func replacesAndBindTypeComposeWithCorrectPrecedence() async throws {
        // Keyless scope-entry over the production graph → the @Replaces Fake supersedes the library's real.
        let graph = try await Wire.bootstrap()
        let defaultScope = try await Wire.bootstrapComposeRequestSeedScope(
            seed: ComposeRequestSeed(id: "req-default"),
            wireGraph: graph
        )
        #expect(defaultScope.composeConsumer.label() == "fake")

        // Keyed variant scope-entry over the variant app graph → @BindType Mock supersedes on top, in this
        // variant only. The variant threads its own graph (the `@BindType`'d ComposeWidget dropped from it).
        let variantGraph = try await Wire.bootstrapComposeFixture_bindMock()
        let mock = MockComposeWidget()
        let doubles = _ComposeFixture_bindMockDoubles(composeWidget: mock)
        let variantScope = try await Wire.bootstrapComposeFixture_bindMock_ComposeRequestSeedScope(
            seed: ComposeRequestSeed(id: "req-variant"),
            wireGraph: variantGraph,
            doubles: doubles
        )
        #expect(variantScope.composeConsumer.label() == "mock")

        // The real binding is superseded in every graph — it was never constructed in either path.
        #expect(realComposeWidgetInits.load(ordering: .relaxed) == 0)
    }
}
