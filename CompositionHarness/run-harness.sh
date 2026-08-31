#!/usr/bin/env bash
#
# Iteration-7g multi-module composition gate.
#
# This runs OUTSIDE `swift test`: the harness library uses Wire's macros,
# so it depends on swift-wire — and a fixture package that swift-wire's own
# test targets depended on would form a circular package dependency. So the
# external-`.product` activation path is exercised by a separate
# consumer+library package pair that depend on swift-wire (one direction),
# run here. The CompositionHarness CI job invokes this script.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

echo "== 7g positive: external-package composition =="
# Builds the consumer (its WireBuildPlugin re-parses and composes the
# external WireHarnessLibrary), then runs it — main.swift bootstraps the
# generated graph and asserts the library's unkeyed + keyed bindings
# composed across the package boundary, printing OK or trapping. It also
# carries the M7b reachability gates: an unreached library binding and an
# unreached home binding both trap on construction, and a
# conformance-rooted aggregate must keep its external contributor.
#
# The plugin outputs are cleared first so its diagnostics are re-emitted
# rather than served from a previous run's cache — the warning assertion
# below needs the plugin to actually run.
rm -rf "$DIR/Consumer/.build/plugins"
BUILD_LOG="$(mktemp)"
trap 'rm -f "$BUILD_LOG"' EXIT
swift build --package-path "$DIR/Consumer" 2>&1 | tee "$BUILD_LOG"

echo "== 7g: the pruning warning names the home binding it dropped =="
# The other half of the M7b.3 gate. Pruning a home-module binding is a
# behaviour change, so it has to be *said* — and said with the fix. Without
# this, the trap above would still pass if the diagnostic silently stopped
# firing, which is the failure mode most worth catching.
if ! grep -q "'UnreachedHomeBinding' is declared but nothing reachable" "$BUILD_LOG"; then
    echo "!! the pruning diagnostic did not name 'UnreachedHomeBinding'"
    exit 1
fi
if ! grep -q "mark it 'allowUnused: true'" "$BUILD_LOG"; then
    echo "!! the pruning diagnostic did not carry its fix-it"
    exit 1
fi

swift run --package-path "$DIR/Consumer"

echo "== 7g gate passed =="
