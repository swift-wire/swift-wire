// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Foundation
import ManifestHarnessLibrary

// The assertion runs in the built product, not over build log text: the
// generated `manifestsReadAtBuildTime` can only carry the library's manifest if
// the consumer's build command read the dependency's plugin output, and could
// only have read it if llbuild ordered the producing command first.
//
// `MANIFEST_HARNESS_EXPECT` is what the library's sources say the manifest
// should contain *on this build*. Comparing against it — rather than against a
// fixed string — is what makes the harness's second phase meaningful: a stale
// manifest is a failure, not a pass.
let expected = ProcessInfo.processInfo.environment["MANIFEST_HARNESS_EXPECT"] ?? "ExternalService"

guard manifestsReadAtBuildTime.count == 1 else {
    fatalError(
        """
        expected exactly one dependency manifest, read \(manifestsReadAtBuildTime.count). \
        An empty list means the consumer's command ran before the producer's — the \
        `inputFiles` edge is no longer ordering the build.
        """
    )
}

let manifest = manifestsReadAtBuildTime[0]
let types =
    manifest
    .components(separatedBy: #""type":""#)
    .dropFirst()
    .compactMap { $0.split(separator: "\"").first.map(String.init) }
    .sorted()

guard types == expected.split(separator: ",").map(String.init).sorted() else {
    fatalError(
        """
        the manifest read at build time describes \(types), expected [\(expected)]. \
        A manifest carrying the previous build's contents means the `inputFiles` edge \
        no longer re-runs the consumer when the dependency's manifest changes.
        """
    )
}

// The type itself crosses by ordinary linking — asserted so the harness fails
// loudly if the package boundary it is testing over stops existing.
guard ExternalService().name == "external" else {
    fatalError("the library's own type did not compose")
}

print("OK — manifest describes \(types), read from the dependency's plugin output")
