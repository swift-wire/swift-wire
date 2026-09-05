// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import SwiftSyntax
import SwiftSyntaxMacros

/// `@RouteController` is a bare marker peer macro used only by swift-wire's own IntegrationTests to stand in
/// for an adapter's proxy-contributing annotation (e.g. WireMVC's `@Controller`). Real adapters live in
/// their own repos; swift-wire ships no adapter, so this marker lets the framework's own tests exercise the
/// contributor-proxy codegen end-to-end. It lives in this test-only macro plugin — off the production
/// `WireMacrosImpl` — so it is built only for swift-wire's tests, never for a consumer's macro plugin. Like
/// `@Scopable`/`@BindType`, it generates nothing — a `WireTestLibrary` `WireAdapterAnnotationV1` declaration
/// binds the name to a `.liftsPeersToProxy` directive the build plugin reads from the parse.
public struct RouteControllerMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}
