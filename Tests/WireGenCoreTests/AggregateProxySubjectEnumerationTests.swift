// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Testing

@testable import WireGenCore

/// `heldSubjectDependencies` / `subjectCount` — how a pass asks a contributor proxy what it carries.
///
/// Asserted against `aggregateProxyBinding`'s real output rather than a hand-built dependency list, because
/// the accessors are the *inverse* of that function's naming: it decides positional-vs-labelled per subject
/// and these recover the set. A fixture spelling the names itself would agree with a copy of the rule rather
/// than with the rule.
///
/// The variant pass reads them to answer one question — "does this proxy carry exactly one subject?" — which
/// it previously answered by looking for an unlabelled dependency or a dependency named `_wireEnterScope`.
/// Both spellings are correct at one subject and match nothing at several, so a group of two or more was
/// invisible rather than refused (swift-wire/swift-wire#362).
@Suite("Aggregate proxy subject enumeration")
struct AggregateProxySubjectEnumerationTests {

    private func subject(
        _ name: String,
        seed: String? = nil,
        params: [String] = [],
        constraints: [String: String] = [:]
    ) -> DiscoveredScopeBoundType {
        DiscoveredScopeBoundType(
            typeName: name,
            typeKind: "struct",
            genericParameterNames: params,
            genericParameterConstraints: constraints,
            dependencies: [],
            location: mockLocation("C.swift"),
            scopeKey: seed.map { ScopeKey(seed: $0) },
            accessLevel: .public,
            originModule: testModule
        )
    }

    private func aggregate(over subjects: [DiscoveredScopeBoundType]) -> DiscoveredScopeBoundType {
        aggregateProxyBinding(
            for: subjects,
            key: "TransportKeys.handlers",
            typeName: "_WireOpenAPIContributor_TaskAPI",
            proxyScope: .singleton
        )
    }

    /// One held subject: the positional `_wireSubject`, byte-identical to `.contributesProxy`. This is the
    /// arrangement the variant pass supports, and the one its old `name == nil` test happened to match.
    @Test func aLoneHeldSubjectIsFoundPositionally() {
        let proxy = aggregate(over: [subject("TaskController")])

        #expect(proxy.heldSubjectDependencies.map(\.type) == ["TaskController"])
        #expect(proxy.heldSubjectDependencies.allSatisfy { $0.name == nil })
        #expect(proxy.scopeEntryDependencies.isEmpty)
        #expect(proxy.subjectCount == 1)
    }

    /// One bridged subject: `_wireEnterScope`, no held subject. The seeded counterpart of the case above,
    /// and the one the old `name == contributorProxyScopeEntryFieldName` test matched.
    @Test func aLoneBridgedSubjectIsFoundAsAScopeEntry() {
        let proxy = aggregate(over: [subject("SessionController", seed: "HTTPRequest")])

        #expect(proxy.heldSubjectDependencies.isEmpty)
        #expect(proxy.scopeEntryDependencies.map(\.name) == [contributorProxyScopeEntryFieldName])
        #expect(proxy.subjectCount == 1)
        #expect(proxy.isBridgeProxy)
    }

    /// Several subjects, mixed hold and bridge — the case both old tests missed. Every subject is labelled
    /// here, so neither `name == nil` nor `name == "_wireEnterScope"` matches any of them.
    @Test func aMixedGroupEnumeratesEverySubjectThoughNoneIsSpelledSingularly() {
        let proxy = aggregate(
            over: [
                subject("TaskController"),
                subject("CancelController"),
                subject("SessionController", seed: "HTTPRequest"),
            ]
        )

        #expect(
            proxy.heldSubjectDependencies.map(\.name) == [
                "_wireSubject_TaskController", "_wireSubject_CancelController",
            ]
        )
        #expect(proxy.scopeEntryDependencies.map(\.name) == ["_wireEnterScope_SessionController"])
        #expect(proxy.subjectCount == 3)

        // The spellings the variant pass used to look for, absent — which is why the group was skipped in
        // silence rather than refused.
        #expect(!proxy.dependencies.contains { $0.name == nil })
        #expect(!proxy.dependencies.contains { $0.name == contributorProxyScopeEntryFieldName })
    }

    /// A lifted `@Factory` is a labelled `.injectInitParameter` exactly as a held aggregate subject is, so
    /// kind alone cannot separate them — the label is the discriminator, and only this accessor may know it.
    /// Without that, `subjectCount` would grow with a proxy's factories and refuse arrangements that work.
    @Test func aLiftedFactoryIsNotCountedAsASubject() {
        var proxy = aggregate(over: [subject("TaskController")])
        proxy = DiscoveredScopeBoundType(
            typeName: proxy.typeName,
            typeKind: proxy.typeKind,
            genericParameterNames: proxy.genericParameterNames,
            dependencies: proxy.dependencies + [
                DependencyParameter(
                    name: factoryDependencyName(forKey: "AuditKeys.factory"),
                    type: factoryTypeName(forKey: "AuditKeys.factory"),
                    kind: .injectInitParameter,
                    location: mockLocation("M.swift")
                )
            ],
            location: proxy.location,
            accessLevel: proxy.accessLevel,
            originModule: proxy.originModule
        )

        #expect(proxy.heldSubjectDependencies.map(\.type) == ["TaskController"])
        #expect(proxy.subjectCount == 1)
    }

    /// Generic subjects rename on collision, and the held subject's *type* carries the renaming while its
    /// label carries the bare type name — so the enumeration must read the label, not the type.
    @Test func collidingGenericParametersDoNotDisturbTheEnumeration() {
        let proxy = aggregate(
            over: [
                subject("TaskController", params: ["Repository"], constraints: ["Repository": "TaskRepository"]),
                subject("CancelController", params: ["Repository"], constraints: ["Repository": "TaskRepository"]),
            ]
        )

        #expect(proxy.subjectCount == 2)
        #expect(
            proxy.heldSubjectDependencies.map(\.name) == [
                "_wireSubject_TaskController", "_wireSubject_CancelController",
            ]
        )
        // The second subject's parameter was renamed positionally; the label was not.
        #expect(
            proxy.heldSubjectDependencies.map(\.type) == [
                "TaskController<Repository>", "CancelController<Repository2>",
            ]
        )
    }
}
