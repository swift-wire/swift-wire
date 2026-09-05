// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

@testable import WireGenCore

/// A stable mock location derived from a file path. Line and column
/// default to 1 so synthetic test bindings have something deterministic
/// for `formattedPrefix`-style assertions.
func mockLocation(_ file: String, line: Int = 1, column: Int = 1) -> SourceLocation {
    SourceLocation(file: file, line: line, column: column)
}

/// The stand-in module name tests pass to `discover(...)` and to direct
/// binding/key constructions — the synthetic-context equivalent of the
/// consumer target name the build plugin supplies. `originModule` is a
/// required non-optional `String`, so tests model the real build by
/// always providing one.
let testModule = "TestModule"

/// A stand-in *dependency* module — a Wire-aware library the consumer composes, passed to the graph as an
/// external module. The home/external split is what reachability pruning turns on, so tests that exercise
/// it need bindings on both sides of it.
let libraryModule = "LibraryModule"

/// A `ScopeEntryDescriptor` for a test fixture, named exactly as the synthesis names it. Tests that hand-
/// build a bridging proxy need the descriptor *and* the type it renders to stay in step — they are two
/// views of one thing, and a fixture that set only the type would be describing a proxy the synthesis
/// cannot produce.
func scopeEntryDescriptor(
    seed: String,
    subject: String,
    yields: [String] = [],
    doubles: String? = nil,
    genericParameterNames: [String] = [],
    genericParameterConstraints: [String: String] = [:],
    genericWhereClause: String? = nil
) -> ScopeEntryDescriptor {
    ScopeEntryDescriptor(
        seed: seed,
        subject: subject,
        yields: yields,
        doubles: doubles,
        entryStructName: scopeEntryStructName(subjectTypeName: String(subject.prefix { $0 != "<" })),
        genericParameterNames: genericParameterNames,
        genericParameterConstraints: genericParameterConstraints,
        genericWhereClause: genericWhereClause
    )
}
