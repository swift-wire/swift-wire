// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

// Small standalone discovery-result models. Each is a plain value type
// captured during the parse and consumed at validation time.

/// One module-scope `typealias` declaration captured during discovery.
/// Used at validation time to enrich missing-binding diagnostics: if
/// `@Inject var x: UserID` fails to resolve but `UserID` is a typealias
/// of a type that IS bound, a `note:` line points at the underlying
/// type so the user understands why the lookup didn't match. Typealiases
/// are not unwrapped during resolution — `typealias UserID = UUID`
/// followed by separate keyed bindings for each is a legitimate
/// discriminator pattern.
package struct DiscoveredTypealias: Sendable {
    /// The typealias's own name, as written (e.g. `"UserID"`).
    package let name: String
    /// The right-hand-side type expression, trimmed (e.g. `"UUID"`).
    package let underlyingType: String
    package let location: SourceLocation

    package init(name: String, underlyingType: String, location: SourceLocation) {
        self.name = name
        self.underlyingType = underlyingType
        self.location = location
    }
}

/// One `@Teardown` method found inside an extension, checked for shape where it was found but
/// not yet joined to a binding: the extended type may be declared in another file. `WireGen`
/// joins it module-wide in `attachExtensionTeardowns`, which records `action` on the
/// `@Singleton`/`@Scoped` type named `extendedType` in `module` and reports `diagnostics` there.
/// A candidate that names no such type is dropped, as is everything else in that extension.
package struct ExtensionTeardownCandidate: Sendable {
    /// The extended type as written (`Pool`, or `Outer.Pool` for a nested type), matched against
    /// a binding's qualified type name.
    package let extendedType: String
    /// The module the extension was discovered in; only a binding of the same module is joined.
    package let module: String
    /// The method name's position, where the duplicate-teardown error is anchored.
    package let location: SourceLocation
    /// The recorded action, or `nil` when the method's shape is malformed.
    package let action: TeardownAction?
    /// The shape diagnostics `teardownMethodAction` reported for the method, reported only when
    /// the candidate joins a binding.
    package let diagnostics: [Diagnostic]

    package init(
        extendedType: String,
        module: String,
        location: SourceLocation,
        action: TeardownAction?,
        diagnostics: [Diagnostic]
    ) {
        self.extendedType = extendedType
        self.module = module
        self.location = location
        self.action = action
        self.diagnostics = diagnostics
    }
}

/// One `init` site found inside an extension that doesn't carry
/// `@Inject`. Recorded as a candidate; resolves to a warning when the
/// extended type is `@Singleton`-annotated somewhere in the module —
/// the macro-generated init either collides with this one (Swift
/// redeclaration error) or silently shadows it. The Wire diagnostic
/// fires before either of those confusing outcomes does.
package struct NonInjectExtensionInit: Sendable {
    /// Simple name of the extended type — what we cross-reference
    /// against the module-wide `@Singleton`-name set.
    package let extendedType: String
    /// Anchor at the `init` keyword.
    package let location: SourceLocation

    package init(extendedType: String, location: SourceLocation) {
        self.extendedType = extendedType
        self.location = location
    }
}
