// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Testing
import Wire

/// swift-wire#429's runtime gate — a `@Teardown` method declared in an extension of the bound type, in
/// another file, is called by the generated graph's `teardown()`.
@Suite("Extension teardown")
struct ExtensionTeardownTests {
    @Test func aTeardownInAnExtensionInAnotherFileRunsAtGraphTeardown() async throws {
        let graph = try await Wire.bootstrapExtensionTeardownContainer()
        #expect(extensionTeardownLog.withLock { $0 }.isEmpty)
        let errors = await graph.teardown()
        #expect(errors.isEmpty)
        #expect(extensionTeardownLog.withLock { $0 } == ["closed"])
    }
}
