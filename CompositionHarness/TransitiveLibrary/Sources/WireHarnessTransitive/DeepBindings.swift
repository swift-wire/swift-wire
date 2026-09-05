// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Wire

/// A binding that lives two packages away from the consumer. The consumer never depends on this package,
/// so this type is not in its parse set at all — and `LibraryBindingNeedingDeep` in the middle package
/// depends on it, which is the shape that would break the consumer's build if reachability did not strip
/// unreached bindings before resolving them.
@Singleton
public struct DeepConfig {
    public let label: String

    @Inject
    public init() {
        self.label = "deep"
    }
}

/// A simple-name collision with a binding the *consumer* declares. Wire keys bindings by simple type name,
/// so if this package were ever activated the merged graph would carry two `HarnessSharedService`
/// bindings and fail with a duplicate-binding error. The consumer building at all is the assertion that a
/// transitive Wire-aware package stays out.
@Singleton
public struct HarnessSharedService {
    public let origin: String

    @Inject
    public init() {
        self.origin = "transitive"
    }
}
