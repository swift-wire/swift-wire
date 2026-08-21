#!/usr/bin/env bash
#
# Injection-rewrite gate — the `.rewritesInjection` pass.
#
# Runs OUTSIDE `swift test` for the same reason AdapterHarness does: the fixture adapter depends on
# swift-wire, so a package inside swift-wire's own tests would cycle.
#
# The adapter here is synthetic (`@FromSettings` over a dictionary) rather than the real
# WireConfiguration one. swift-wire must not depend on one of its own adapters — that is a package cycle,
# and it would make this gate depend on an external repo existing — and a fixture with nothing to do with
# configuration is better evidence anyway: if the pass wires this, it learned nothing domain-specific.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

echo "== injection rewrites: all three annotated sites, dedup, and no capture of plain bindings =="
# Builds the consumer — its WireBuildPlugin sees `@FromSettings` declaring `.rewritesInjection`,
# synthesises one producer per distinct (annotation, arguments, type), and re-points each annotated site
# at it — then runs it. main.swift asserts the values reached the graph, printing OK or trapping.
swift run --package-path "$DIR/Consumer"

echo "== injection rewrite gate passed =="
