// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Testing

/// A bridging proxy whose only scheduled dependency is its thunk's capture is built after that capture.
///
/// That this file compiles is most of the assertion: before the construction regions counted a thunk's
/// captures as edges, the proxy landed in the serial prefix and its thunk named `scheduledCaptureReceipt`
/// before the seam bound it — `cannot find 'scheduledCaptureReceipt' in scope` in the generated bootstrap.
@Suite("Scheduled capture proxy")
struct ScheduledCaptureProxyTests {
    @Test func theProxyEntersTheScopeAndReadsTheCapturedSuffixBinding() async throws {
        let graph = try await Wire.bootstrap()
        let entry = try await graph._WireRouteContributor_ScheduledCaptureController._wireEnterScope(
            ScheduledCaptureSeed(id: "req")
        )
        // The thunk captured the receipt the suffix built from both scheduled bindings, not a stale or
        // default value: its summary carries both of their products.
        #expect(entry._wireSubject.describe() == "req:async-token-resolved+computed-property-resolved")
        #expect(entry._wireSubject.receipt.summary == graph.scheduledCaptureReceipt.summary)
        #expect(await entry._wireScopeTeardown().isEmpty)
    }
}
