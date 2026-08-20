#!/usr/bin/env bash
#
# Injection-rewrite gate — `.rewritesInjection`, exercised through the WireConfiguration adapter.
#
# Runs OUTSIDE `swift test` for the same reason AdapterHarness does: the adapter is a separate package
# that depends on swift-wire, so a fixture inside swift-wire's own tests would cycle.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

echo "== injection rewrites: @Configuration at all three sites =="
# Builds the consumer — its WireBuildPlugin sees `@Configuration` declaring `.rewritesInjection`,
# synthesises one producer per distinct (annotation, arguments, type), and re-points each annotated
# site at it — then runs it. main.swift asserts the values reached the graph, printing OK or trapping.
swift run --package-path "$DIR/Consumer"

echo "== injection rewrite gate passed =="
