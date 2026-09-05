// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import SwiftSyntax
import SwiftSyntaxMacros

/// `@RouteMiddleware(key)` is a bare marker peer macro used only by swift-wire's own IntegrationTests to
/// stand in for an adapter's factory-injecting annotation (e.g. WireMVC's `@Middleware(key)`). It generates
/// nothing — a `WireTestLibrary` `WireAdapterAnnotationV1` declaration binds the name to `.injectsFromGraph`,
/// so the build plugin lifts the named `@Factory` onto the annotated binding's contributor proxy. Lives in
/// this test-only macro plugin, off the production `WireMacrosImpl`.
public struct RouteMiddlewareMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}
