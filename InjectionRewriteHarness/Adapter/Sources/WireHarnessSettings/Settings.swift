public import Wire

/// The harness adapter's provider — the binding a rewritten site reads its value out of. A dictionary,
/// because what it *is* is exactly what Wire must not need to know.
public struct SettingsSource: Sendable {
    private let values: [String: String]
    public init(_ values: [String: String]) { self.values = values }

    public func string(named name: String) -> String? { values[name] }
}

/// The harness's rewriting annotation. Stands in for `@Configuration` without being it: same shape, no
/// swift-configuration anywhere, so what this proves is that the pass is domain-free.
///
/// Dispatch is by constrained initialiser, as the real adapter's is — `String` reads directly, `Int`
/// parses. An unsupported type has no initialiser and so fails at the user's own annotation.
@propertyWrapper
public struct FromSettings<Value>: WireInjectionRewrite {
    public typealias Provider = SettingsSource

    private var storage: Value?
    private let read: @Sendable (SettingsSource) throws -> Value

    public var wrappedValue: Value {
        get {
            guard let storage else {
                preconditionFailure("wrappedValue read on a Wire-synthesised instance")
            }
            return storage
        }
        set { storage = newValue }
    }

    public func wireValue(from provider: SettingsSource) throws -> Value { try read(provider) }

    private init(storage: Value?, read: @escaping @Sendable (SettingsSource) throws -> Value) {
        self.storage = storage
        self.read = read
    }

    // MARK: String

    public init(wrappedValue: Value, named name: String, default value: Value) where Value == String {
        self.init(storage: wrappedValue, read: { $0.string(named: name) ?? value })
    }
    public init(named name: String, default value: Value) where Value == String {
        self.init(storage: nil, read: { $0.string(named: name) ?? value })
    }
    /// No default: absent is a startup failure, the shape the real adapter's `required*` forms take.
    /// Needs an attachment overload too — a property wrapper on a parameter requires a matching
    /// `init(wrappedValue:…)`, which is what the compiler calls at the use site.
    public init(wrappedValue: Value, named name: String) where Value == String {
        self.init(
            storage: wrappedValue,
            read: {
                guard let found = $0.string(named: name) else { throw MissingSetting(name: name) }
                return found
            }
        )
    }
    public init(named name: String) where Value == String {
        self.init(
            storage: nil,
            read: {
                guard let found = $0.string(named: name) else { throw MissingSetting(name: name) }
                return found
            }
        )
    }

    // MARK: Int

    public init(wrappedValue: Value, named name: String, default value: Value) where Value == Int {
        self.init(storage: wrappedValue, read: { $0.string(named: name).flatMap(Int.init) ?? value })
    }
    public init(named name: String, default value: Value) where Value == Int {
        self.init(storage: nil, read: { $0.string(named: name).flatMap(Int.init) ?? value })
    }
}

extension FromSettings: Sendable where Value: Sendable {}

public struct MissingSetting: Error {
    public let name: String
}

/// The declaration Wire discovers. `provider:` is the one thing it cannot derive — it matches
/// dependencies by canonical type text, so it cannot see through `FromSettings<Value>.Provider`.
public let wireHarnessSettingsAnnotation = WireAdapterAnnotationV1(
    annotation: "FromSettings",
    capability: .rewritesInjection(provider: "SettingsSource")
)
