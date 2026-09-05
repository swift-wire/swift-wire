// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct WireRoutingPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [HarnessRouteMacro.self]
}
