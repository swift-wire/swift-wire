// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Wire

/// End-to-end fixture for keyed injection into an optional site (swift-wire#421). `borrowed` is a
/// `AppName?` consumer of a `BindingKey<AppName>` key with a non-optional producer, which the graph
/// satisfies by promotion; `exact` is an `AppName?` consumer of a `BindingKey<AppName?>` key with an
/// optional producer, which the graph matches first. The generated `_WireKeyChecks.swift` must accept
/// both pairings — before the fix the first one's `_check(AppName.borrowedOptional, AppName?.self)`
/// did not compile.
extension AppName {
    static let borrowedOptional = BindingKey<AppName>()
    static let exactOptional = BindingKey<AppName?>()
}

@Provides(AppName.borrowedOptional, allowUnused: true)
let borrowedOptionalAppName: AppName = AppName(value: "borrowed")

@Provides(AppName.exactOptional, allowUnused: true)
let exactOptionalAppName: AppName? = AppName(value: "exact")

@Singleton(allowUnused: true)
struct KeyedOptionalConsumer {
    @Inject(AppName.borrowedOptional) var borrowed: AppName?
    @Inject(AppName.exactOptional) var exact: AppName?

    func describe() -> String {
        "optional consumer with \(borrowed?.value ?? "nil") and \(exact?.value ?? "nil")"
    }
}
