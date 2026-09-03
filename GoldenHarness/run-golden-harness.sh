#!/usr/bin/env bash
#
# Golden gate — the byte-identical invariant reachability pruning and
# noncopyable bindings both lean on.
#
#   A graph in which every binding is already reachable from a root produces
#   byte-identical generated output before and after pruning.
#
# The corpus is `Tests/IntegrationTests` — ~70 example files covering containers,
# seed scopes, contributor proxies, graph conformances, teardown, member
# injection, opaque lifts and testing variants — plus its Wire-aware sibling
# `WireTestLibrary`, exactly the two module groups the build plugin passes for
# that target. So this runs the real `WireGen` over the real corpus, not a
# re-implementation of the plugin's argument shape.
#
# Runs OUTSIDE `swift test`: the guard is over WireGen's *output files*, and
# WireGen is an executable target a test target cannot import.
#
#   bash GoldenHarness/run-golden-harness.sh            # compare, fail on any drift
#   bash GoldenHarness/run-golden-harness.sh --update    # re-record the golden
#
# A diff here is not automatically a bug — it is a change to generated output
# that must be *intended*. Read the diff, then re-record with `--update` and
# commit it as part of the change that caused it.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
GOLDEN="$DIR/Golden"
UPDATE="${1:-}"

echo "== golden: building WireGen =="
swift build --package-path "$ROOT" --product WireGen

BIN="$(swift build --package-path "$ROOT" --product WireGen --show-bin-path)/WireGen"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "== golden: generating over Tests/IntegrationTests =="
# Module groups mirror WireBuildPlugin's for this target: the consumer first,
# then its Wire-aware same-package dependency. `--testing-variants` is what the
# plugin passes for a test target, and it is what puts the variant graphs in.
# Globs (not `find`) so the file order is lexicographic and stable everywhere.
#
# Run from the repository root with **relative** source paths. WireGen echoes the
# path it was handed straight into `#sourceLocation(file:)`, so absolute paths
# would bake this checkout's location into the recording — the golden would then
# pass only on the machine that recorded it, which is how the first version of
# this harness failed in CI.
cd "$ROOT"
"$BIN" \
    "$WORK/_WireGraph.swift" \
    "$WORK/_WireKeyChecks.swift" \
    --testing-variants \
    --module IntegrationTests Tests/IntegrationTests/*.swift \
    --module WireTestLibrary Sources/WireTestLibrary/*.swift \
    > "$WORK/discovery-report.txt"

# Self-check, so machine-independence is a property this gate *enforces* rather
# than a convention the next edit can quietly drop.
if grep -qF "$ROOT" "$WORK/_WireGraph.swift" "$WORK/_WireKeyChecks.swift"; then
    echo "!! golden: generated output contains this checkout's absolute path."
    echo "!! Source paths must stay relative to the repository root, or the"
    echo "!! recording only ever matches on the machine that made it."
    grep -nF "$ROOT" "$WORK/_WireGraph.swift" "$WORK/_WireKeyChecks.swift" | head -5
    exit 1
fi

# Recorded as `.swift.golden`, not `.swift`: the repo's format job runs
# `swift-format format --recursive --in-place .` and fails on any resulting
# diff, so a committed *generated* Swift file would be reformatted under it and
# break the build. The extension keeps the recording out of every tool's reach
# while leaving it a readable Swift file.
if [ "$UPDATE" = "--update" ]; then
    mkdir -p "$GOLDEN"
    cp "$WORK/_WireGraph.swift" "$GOLDEN/_WireGraph.swift.golden"
    cp "$WORK/_WireKeyChecks.swift" "$GOLDEN/_WireKeyChecks.swift.golden"
    echo "== golden: re-recorded ($(wc -l < "$GOLDEN/_WireGraph.swift.golden" | tr -d ' ') lines of graph) =="
    exit 0
fi

status=0
for file in _WireGraph.swift _WireKeyChecks.swift; do
    if ! diff -u "$GOLDEN/$file.golden" "$WORK/$file"; then
        echo "!! golden: $file differs from the recorded output"
        status=1
    fi
done

if [ "$status" -ne 0 ]; then
    echo "!! golden gate FAILED — generated output changed."
    echo "!! If the change is intended, re-record with:"
    echo "!!     bash GoldenHarness/run-golden-harness.sh --update"
    exit 1
fi

echo "== golden gate passed ($(wc -l < "$GOLDEN/_WireGraph.swift.golden" | tr -d ' ') lines of graph, byte-identical) =="
