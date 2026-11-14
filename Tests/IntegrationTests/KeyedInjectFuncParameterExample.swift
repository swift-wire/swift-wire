// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Wire

/// End-to-end fixture for keyed injection through an `@Inject func` *parameter*. As on an `@Inject init`
/// parameter, `@Inject(Key)` cannot attach to a parameter (it is a peer macro), so the key is carried by the
/// `@Bind(Key)` property wrapper. The method asks for the keyed `AppName.boundViaInit` binding declared in
/// `KeyedInitParameterExample.swift`, beside the unkeyed module-scope `appName`; bootstrap must call it with
/// the keyed one, and the generated `_WireKeyChecks.swift` must accept the `BindingKey<AppName>` / `AppName`
/// pair.
///
/// Honestly non-Sendable, like `NoteBoard`: the method writes mutable class storage during bootstrap and the
/// test reads it afterwards in the same task.
@Singleton(allowUnused: true)
final class KeyedInjectFuncConsumer {
    private var received: String = "uninitialised"

    @Inject
    func receive(@Bind(AppName.boundViaInit) name: AppName) {
        received = name.value
    }

    func current() -> String {
        received
    }
}
