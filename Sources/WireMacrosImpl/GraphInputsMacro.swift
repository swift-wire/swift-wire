// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import SwiftSyntax
import SwiftSyntaxMacros

/// `@GraphInputs` is a marker peer macro. It generates no code on its own — its
/// purpose is to be recognised by the build plugin's source scan, which turns each
/// of the annotated struct's stored properties into an app-scope binding sourced
/// from the value the caller passes to `Wire.bootstrap(inputs:)`.
///
/// The values are constructed *before* the graph and handed to it, so they are
/// necessarily leaves: an input cannot depend on a graph binding, because none
/// exist yet. That is what makes them the answer for things the graph cannot make
/// for itself — a `ConfigReader` read from the environment, CLI arguments, an
/// externally-owned `EventLoopGroup`.
public struct GraphInputsMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}
