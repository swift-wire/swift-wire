// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Wire

/// The teardown of `ExtensionTeardownResource`, declared away from the type — see
/// `ExtensionTeardownExample.swift`.
extension ExtensionTeardownContainer.ExtensionTeardownResource {
    @Teardown
    package func close() async throws {
        extensionTeardownLog.withLock { $0.append("closed") }
    }
}
