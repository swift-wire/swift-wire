// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Testing

/// scheduled scope entry's gate — a request scope's two independent async bindings are in flight at once.
///
/// This is the scheduler pointed at the path it was always meant for. Per-request construction runs once
/// per request rather than once per process, so the same structure that saves a few milliseconds at
/// bootstrap saves them on every request here.
@Suite("Async scope entry")
struct AsyncScopeEntryTests {
    private func enterScope(id: String) async throws -> _WireScopeEntry_AsyncScopeController {
        let graph = try await Wire.bootstrap()
        return try await graph._WireAggregateContributor_async._wireEnterScope(AsyncScopeSeed(id: id))
    }

    @Test func bothIndependentAsyncBindingsAreInFlightAtOnce() async throws {
        // Each half records that it started and then waits for the other to do the same. Serial
        // construction cannot make both true whichever order the sort produces — the first to run waits out
        // its bound with the second not yet begun.
        let entry = try await enterScope(id: "overlap")
        #expect(entry._wireSubject.slow.sawPartner)
        #expect(entry._wireSubject.dependent.observed == "fast")
        let timeline = entry._wireSubject.timeline()
        // Both starts precede either completion, which is the same claim stated over the recorded order.
        let firstStart = try #require(timeline.firstIndex(of: "fast.started"))
        let secondStart = try #require(timeline.firstIndex(of: "slow.started"))
        let dependentBuilt = try #require(timeline.firstIndex(of: "dependent.built"))
        #expect(max(firstStart, secondStart) < dependentBuilt)
    }

    @Test func theScopeStillBuildsEveryBindingAndSeedsThem() async throws {
        // The regions have to compose: a prefix binding (the clock) read across the seam, a group binding
        // (the dependent) fired by the cascade, and a suffix binding (the subject) built after the drain
        // from locals — with the seed threaded through to the last of them.
        let entry = try await enterScope(id: "compose")
        #expect(entry._wireSubject.describe() == "compose:fast:slow")
    }

    @Test func eachEntryGetsItsOwnScopeAndItsOwnTeardown() async throws {
        // Per-request means per-request: two entries share nothing, and the scope's own teardown closure
        // still reaches a binding the scheduler constructed.
        let first = try await enterScope(id: "a")
        let second = try await enterScope(id: "b")
        #expect(first._wireSubject.session !== second._wireSubject.session)
        #expect(!first._wireSubject.session.isClosed)
        _ = await first._wireScopeTeardown()
        #expect(first._wireSubject.session.isClosed)
        #expect(!second._wireSubject.session.isClosed)
    }
}
