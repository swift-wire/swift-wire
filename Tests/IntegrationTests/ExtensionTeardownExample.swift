// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Synchronization
import Wire

/// swift-wire#429 — a `@Teardown` method declared in an extension of the bound type, in another file
/// (`ExtensionTeardownExample+Teardown.swift`). WireGen used to read a member teardown only from the
/// type's body, so this graph built and its `teardown()` called nothing. The extension's file sorts
/// before this one, so WireGen reads the method before it reads the type it joins.

/// What `ExtensionTeardownResource.close()` recorded; read by `ExtensionTeardownTests`.
package let extensionTeardownLog = Mutex<[String]>([])

@Container
package enum ExtensionTeardownContainer {
    @Singleton(allowUnused: true)
    package final class ExtensionTeardownResource: Sendable {
        @Inject package init() {}
    }
}
