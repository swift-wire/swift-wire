// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Wire

/// Scope-bound type that depends on another scope-bound type within
/// the same seed scope. Exercises in-scope dependency resolution: the
/// generated bootstrap must construct `RequestLogger` before
/// `RequestHandler` and pass the same `RequestLogger` instance.
@Scoped(seed: TestRequestSeed.self, allowUnused: true)
struct RequestHandler {
    @Inject var requestLogger: RequestLogger

    func handle(_ action: String) -> String {
        requestLogger.log("handling \(action)")
    }
}
