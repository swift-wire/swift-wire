// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Wire

/// No-dependency leaf in the integration graph. Exercises the
/// "macro synthesises a parameterless init" path.
@Singleton
struct Logger {
    func log(_ message: String) -> String {
        "[log] \(message)"
    }
}
