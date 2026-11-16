// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

/// One `@Provides` site found inside an unannotated extension.
/// Carried through discovery as a candidate; the build plugin
/// resolves it into a `Diagnostic` after the module-wide
/// `@Container`-name set is available.
package struct UnannotatedExtensionProvides: Sendable {
    /// The extension's extended type name — what the warning checks
    /// against the container set.
    package let extendedType: String
    /// Display name of the offending `@Provides` declaration, for
    /// the warning message (e.g. property/function source name).
    package let providerName: String
    /// Anchor for the warning's `file:line:col:` prefix.
    package let location: SourceLocation
    /// The module the extension is written in. The cross-module-extension
    /// warning checks the extended type against the types declared in this
    /// module only, not in every module WireGen scanned (swift-wire#434).
    package let module: String

    package init(extendedType: String, providerName: String, location: SourceLocation, module: String) {
        self.extendedType = extendedType
        self.providerName = providerName
        self.location = location
        self.module = module
    }
}
