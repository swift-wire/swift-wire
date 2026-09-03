#!/usr/bin/env bash
#
# Plugin-output gate.
#
# Pins the one mechanism manifest-based discovery would be built on: a consumer's build command
# reading a *dependency's* build-tool-plugin output, ordered by a derived path
# declared in `inputFiles`. Both halves of that are undocumented SPM behaviour
# rather than API — the `.build/plugins/outputs/…` layout and llbuild's
# ordering — so this gate exists to fail if either changes, rather than to let
# #338's central claim quietly rot.
#
# Unlike the other harnesses here, neither package depends on swift-wire: the
# claim under test is a toolchain capability, not Wire behaviour. It runs
# outside `swift test` because it needs a real two-package build with plugins on
# both sides.
#
# The manifest route is deferred (see #338), so this gate guards a *finding*, not a
# shipping path. Its failure means the finding needs re-checking, not that
# anything users have is broken.
#
# Two phases, because only the second is deterministic:
#
#   1. Clean build. Proves the derived path resolves — a wrong path reads
#      nothing and traps. The producer's delay makes an unordered consumer
#      likely to fail here, but scheduling can still let it win the race, so
#      this phase alone would not catch a missing edge.
#   2. Change the library, rebuild. Now the manifest's *contents* change, and
#      nothing but the declared edge would re-run the consumer's command. A
#      stale manifest fails. This is the phase that actually tests the edge.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
ADDED="$DIR/Library/Sources/ManifestHarnessLibrary/AddedService.swift"

cleanup() { rm -f "$ADDED"; }
trap cleanup EXIT

cleanup
rm -rf "$DIR/Consumer/.build" "$DIR/Library/.build"

echo "== phase 1: a consumer's build command reads a dependency's plugin output =="
MANIFEST_HARNESS_EXPECT="ExternalService" \
    swift run --package-path "$DIR/Consumer" ManifestHarnessConsumer

echo "== phase 2: changing the dependency re-runs the consumer's codegen =="
cat > "$ADDED" <<'SWIFT'
// Written by run-manifest-harness.sh for phase 2, and deleted after. Its
// presence changes what the library's manifest describes.
public struct AddedService: Sendable {
    public init() {}
}
SWIFT
MANIFEST_HARNESS_EXPECT="AddedService,ExternalService" \
    swift run --package-path "$DIR/Consumer" ManifestHarnessConsumer

# The Swift Build backend was verified to keep both the layout and the ordering.
# Opt-in rather than default: it is a second toolchain surface, and a failure
# there is a different finding from a failure above.
if [ "${MANIFEST_HARNESS_SWIFTBUILD:-0}" = "1" ]; then
    echo "== phase 3: same, under the Swift Build backend =="
    rm -rf "$DIR/Consumer/.build" "$DIR/Library/.build"
    cleanup
    MANIFEST_HARNESS_EXPECT="ExternalService" \
        swift run --build-system swiftbuild --package-path "$DIR/Consumer" ManifestHarnessConsumer
fi

echo "== plugin-output gate passed =="
