// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Wire

/// End-to-end fixture for injecting a **multibinding aggregate through a parameter** rather than a
/// stored property. `@Inject(K)` keys a property and has overloads for all three multibinding key
/// kinds, but `@Inject` is a peer macro and cannot attach to a parameter — so a keyed `@Provides func`
/// / `@Inject init` parameter carries `@Bind(K)`. Until the matching `@Bind` overloads existed, that
/// parameter form was single-bindings-only: a `@Provides` that needed a collection had no spelling.
///
/// Pins both halves of the fix: that the aggregate resolves through a parameter at all, and that the
/// `CollectedKey`/`MappedKey` overloads pin `Value` to the shape the key fixes (a wrong element type
/// fails at the declaration, not as a missing binding at codegen time).

protocol Formatter: Sendable {
    func format(_ value: String) -> String
}

enum FormatterKeys {
    static let all = CollectedKey<any Formatter>()
    static let byName = MappedKey<String, any Formatter>()
}

struct UpperFormatter: Formatter {
    func format(_ value: String) -> String { value.uppercased() }
}

struct BracketFormatter: Formatter {
    func format(_ value: String) -> String { "[\(value)]" }
}

@Singleton @Contributes(to: FormatterKeys.all, withOrder: 1)
@Contributes(to: FormatterKeys.byName, atKey: "upper")
struct UpperFormatterBinding: Formatter {
    @Inject init() {}
    func format(_ value: String) -> String { UpperFormatter().format(value) }
}

@Singleton @Contributes(to: FormatterKeys.all, withOrder: 2)
@Contributes(to: FormatterKeys.byName, atKey: "bracket")
struct BracketFormatterBinding: Formatter {
    @Inject init() {}
    func format(_ value: String) -> String { BracketFormatter().format(value) }
}

/// The ordered aggregate reaching a `@Provides` **function parameter**.
struct FormatterChain: Sendable {
    let formatters: [any Formatter]
    func format(_ value: String) -> String { formatters.reduce(value) { $1.format($0) } }
}

@Provides
func formatterChain(@Bind(FormatterKeys.all) formatters: [any Formatter]) -> FormatterChain {
    FormatterChain(formatters: formatters)
}

/// The mapped aggregate reaching an `@Inject init` **parameter**, alongside a single-binding parameter
/// — the two `@Bind` kinds side by side on one initialiser.
@Singleton(allowUnused: true)
struct FormatterRegistry: Sendable {
    let names: [String]
    let chained: String

    @Inject init(
        @Bind(FormatterKeys.byName) byName: [String: any Formatter],
        chain: FormatterChain
    ) {
        self.names = byName.keys.sorted()
        self.chained = chain.format("x")
    }
}
