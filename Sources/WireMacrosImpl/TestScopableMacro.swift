// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import SwiftSyntax
import SwiftSyntaxMacros

/// `@TestScopable` is a bare marker peer macro attached to a **type declaration**. It generates no code —
/// its purpose is to be recognised by the build plugin's source scan, which records that the app-scoped
/// (`@Singleton`) type may be rebuilt per-request under a test `TestingKey` when a `@BindType` mock reaches
/// it (lifted into a seed scope, or reconstructed seedlessly if it's its own route-contributor root).
///
/// It has effect only when a `TestingKey`'s `@BindType` mocks a slot the type consumes — a test-only
/// construct — so in a production build (no `TestingKey`) it is inert. Like `@BindType`/`@Replaces`, the work
/// happens in the plugin's parse, not in expansion.
public struct TestScopableMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}
