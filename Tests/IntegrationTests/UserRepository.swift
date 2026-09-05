// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Wire

/// Property-injection consumer. Exercises the "macro synthesises an
/// init from `@Inject` stored properties" path; the resulting init's
/// parameter list is what WireGen emits at the bootstrap call site.
@Singleton(allowUnused: true)
struct UserRepository {
    @Inject var logger: Logger

    func describe() -> String {
        logger.log("UserRepository")
    }
}
