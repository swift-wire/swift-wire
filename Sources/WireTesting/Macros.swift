// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Wire

// The test-graph vocabulary's macro surface — just `@BindType`. It lives here rather than in `Wire` so that
// writing a variant is a dependency a target takes deliberately: a production target that does not link
// `WireTesting` cannot spell `@BindType` or `TestingKey()`, so the mistake fails at the declaration rather
// than downstream in WireGen.
//
// `@TestScopable` stays in `Wire` — it marks a *production* type as safe to rebuild per request under test,
// so it is written in production sources. Moving it would make every module carrying one depend on the
// testing target, which is exactly what this split is trying to avoid.

/// Substitutes a slot's type in a *test-graph variant*, sourcing the slot's
/// instance from a test-held double — the inspectable / generated-mock
/// counterpart to `@Replaces`.
///
/// Attach it to a `TestingKey` static; the first argument names the slot, the
/// second the concrete `Mock` type it is bound to in this variant. Wire
/// specialises the test graph to `Mock` — the same opaque-lift it already does
/// for the real binding, just pointed at the mock — and sources the instance
/// from a `doubles` value threaded into the scope at entry, so the test holds
/// and inspects it (`verify`). Because it *references* `Mock` rather than
/// annotating it, a generated mock (whose type you can't annotate) fits with no
/// wrapper.
///
///     import WireTesting
///
///     enum MyTests {
///         @BindType(BackendRepository.self, MockBackendRepository.self)
///         static let testSetup = TestingKey()
///     }
///
/// The slot is the first argument, mirroring `@Provides` / `@Replaces`:
/// `@BindType(Repo.self, Mock.self)` for the unkeyed slot,
/// `@BindType(Repo.primary, Mock.self)` for a keyed one.
///
/// `@BindType` itself contributes no code — it's a marker the build plugin
/// recognises during source scanning. Stack several on one `TestingKey` to
/// substitute several slots in the one variant. Unlike `@Replaces`, `@BindType`
/// lives only in the test graph; the production graph never sees it.
@attached(peer)
public macro BindType<Slot, Mock>(_ slot: Slot.Type, _ mock: Mock.Type) =
    #externalMacro(module: "WireMacrosImpl", type: "BindTypeMacro")

/// The keyed form — the slot is named by its ``Wire/BindingKey``, mirroring
/// `@Provides(key)` / `@Replaces(key)`.
@attached(peer)
public macro BindType<Slot, Mock>(_ key: BindingKey<Slot>, _ mock: Mock.Type) =
    #externalMacro(module: "WireMacrosImpl", type: "BindTypeMacro")
