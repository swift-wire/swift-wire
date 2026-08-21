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

    // The *attachment* role. Optional-backed because the property-site declaration constructs the wrapper
    // with no value to carry yet — the generated initialiser assigns through the setter afterwards.
    private var storage: Value?
    public var wrappedValue: Value {
        get { storage! }
        set { storage = newValue }
    }

    private init(_ storage: Value?) { self.storage = storage }

    // MARK: Attachment — String

    public init(wrappedValue: Value, named name: String, default value: Value) where Value == String {
        self.init(wrappedValue)
    }
    public init(named name: String, default value: Value) where Value == String { self.init(nil) }

    /// No default: the value is optional, and an absent setting is `nil`. Absence is what `Optional`
    /// means, so there is nothing to invent an error for — the site declares `String?` and decides.
    public init(wrappedValue: Value, named name: String) where Value == String? { self.init(wrappedValue) }
    public init(named name: String) where Value == String? { self.init(nil) }

    // MARK: Attachment — Int

    public init(wrappedValue: Value, named name: String, default value: Value) where Value == Int {
        self.init(wrappedValue)
    }
    public init(named name: String, default value: Value) where Value == Int { self.init(nil) }

    // MARK: Resolution — static, so no instance is built to resolve

    public static func wireValue(from provider: SettingsSource, named name: String, default value: Value)
        -> Value
    where Value == String {
        provider.string(named: name) ?? value
    }
    public static func wireValue(from provider: SettingsSource, named name: String) -> Value
    where Value == String? {
        provider.string(named: name)
    }
    public static func wireValue(from provider: SettingsSource, named name: String, default value: Value)
        -> Value
    where Value == Int {
        provider.string(named: name).flatMap(Int.init) ?? value
    }
}

extension FromSettings: Sendable where Value: Sendable {}

/// The declaration Wire discovers. `provider:` is the one thing it cannot derive — it matches
/// dependencies by canonical type text, so it cannot see through `FromSettings<Value>.Provider`.
public let wireHarnessSettingsAnnotation = WireAdapterAnnotationV1(
    annotation: "FromSettings",
    capability: .rewritesInjection(provider: "SettingsSource")
)

/// The *macro* half of `@FromSettings`, sharing the wrapper's name. Swift resolves each use site to
/// whichever declaration can apply there: a parameter takes the property wrapper (a macro cannot attach to
/// one), and a `let` property takes this (a property wrapper cannot attach to one). It generates nothing —
/// Wire reads the attribute syntactically either way.
///
/// The two forms are therefore equivalent and both expressible, including with `let`:
///
///     @Inject @FromSettings(named: "host", default: "127.0.0.1") let host: String
///     @Inject init(@FromSettings(named: "host", default: "127.0.0.1") host: String) { … }
@attached(peer)
public macro FromSettings<Value>(named: String, default: Value) =
    #externalMacro(module: "WireHarnessSettingsMacros", type: "FromSettingsMacro")

@attached(peer)
public macro FromSettings(named: String) =
    #externalMacro(module: "WireHarnessSettingsMacros", type: "FromSettingsMacro")
