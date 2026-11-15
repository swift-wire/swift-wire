// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Wire

/// End-to-end fixture for a keyed `@Inject weak var` (swift-wire#425). A weak var is a member
/// injection, assigned after construction, and is always optional, so its key check names the
/// optional type and needs the `T?.Type` overload. `optional` is spelled `T?`; `unwrapped` is spelled
/// `T!`, which cannot be written as a metatype and is checked as `T?`. The generated
/// `_WireKeyChecks.swift` must compile for both.
///
/// Honestly non-Sendable, like `View` in `WeakCycleExample.swift`: the weak vars are mutable storage
/// written during bootstrap and read afterwards in the same task.
final class KeyedWeakTarget {
    let name: String

    init(name: String) {
        self.name = name
    }

    static let primary = BindingKey<KeyedWeakTarget>()
}

@Provides(KeyedWeakTarget.primary, allowUnused: true)
func primaryKeyedWeakTarget() -> KeyedWeakTarget {
    KeyedWeakTarget(name: "primary")
}

@Singleton(allowUnused: true)
final class KeyedWeakVarConsumer {
    @Inject(KeyedWeakTarget.primary) weak var optional: KeyedWeakTarget?
    @Inject(KeyedWeakTarget.primary) weak var unwrapped: KeyedWeakTarget!

    func describe() -> String {
        "weak consumer with \(optional?.name ?? "nil") and \(unwrapped?.name ?? "nil")"
    }
}
