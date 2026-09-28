import Foundation

/// Holds whatever session material a live integration needs, in the secret store only.
///
/// The export-based flow needs no session at all. A future official integration (e.g. an
/// OAuth token) stores its credential here so logout can remove it with everything else.
public struct SessionVault: Sendable {
    private let store: SecretStore
    private let key = "integration.session"

    public init(store: SecretStore) {
        self.store = store
    }

    public func save(_ material: Sensitive<Data>) throws {
        try store.set(material.value, for: key)
    }

    public func load() throws -> Sensitive<Data>? {
        try store.data(for: key).map(Sensitive.init)
    }

    public var hasSession: Bool {
        ((try? store.data(for: key)) ?? nil) != nil
    }

    public func clear() throws {
        try store.removeValue(for: key)
    }
}
