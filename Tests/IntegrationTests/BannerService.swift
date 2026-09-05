// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Wire

/// `@Singleton` consumer that pulls a `@Provides`-supplied `Banner`
/// through `@Inject`. Closes the loop: `@Provides` declarations enter
/// the graph, get topologically ordered, and reach a `@Singleton`'s
/// dependency slot just like another `@Singleton` would.
@Singleton(allowUnused: true)
struct BannerService {
    @Inject var banner: Banner

    func display() -> String {
        banner.text
    }
}
