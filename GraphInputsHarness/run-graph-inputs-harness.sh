#!/usr/bin/env bash
#
# Graph-inputs gate — `@GraphInputs` / `Wire.bootstrap(inputs:)`.
#
# Runs OUTSIDE `swift test`, for a different reason than the other harnesses:
# `@GraphInputs` changes the signature of `Wire.bootstrap` for its whole module,
# so a fixture inside swift-wire's shared IntegrationTests would force all 62 of
# that module's `Wire.bootstrap()` call sites to pass inputs they don't care
# about. A package of its own gives it a graph of its own.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

echo "== graph inputs: @GraphInputs reaches consumers by type and by key =="
# Builds the consumer — its WireBuildPlugin turns each stored property of the
# @GraphInputs struct into an app-scope binding sourced from the bootstrap's
# `inputs` parameter — then runs it. main.swift bootstraps with real values and
# asserts they reached two separate consumers, printing OK or trapping.
swift run --package-path "$DIR/Consumer"

echo "== graph inputs gate passed =="
