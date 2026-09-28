import Foundation
#if canImport(Security)
import Security
#endif

public enum SecretStoreError: Error, Equatable, Sendable {
    case unexpectedStatus(Int32)
    case encodingFailed
}

/// Storage for credentials and other secrets. Production uses the Keychain; never UserDefaults.
public protocol SecretStore: Sendable {
    func data(for key: String) throws -> Data?
    func set(_ data: Data, for key: String) throws
    func removeValue(for key: String) throws
    func removeAll() throws
}

extension SecretStore {
    public func string(for key: String) throws -> String? {
        try data(for: key).flatMap { String(data: $0, encoding: .utf8) }
    }

    public func set(_ string: String, for key: String) throws {
        try set(Data(string.utf8), for: key)
    }
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    public init() {}

    public func data(for key: String) throws -> Data? { lock.withLock { values[key] } }
    public func set(_ data: Data, for key: String) throws { lock.withLock { values[key] = data } }
    public func removeValue(for key: String) throws { lock.withLock { values[key] = nil } }
    public func removeAll() throws { lock.withLock { values.removeAll() } }

    public var isEmpty: Bool { lock.withLock { values.isEmpty } }
}

#if canImport(Security)
/// Keychain-backed store. Items are device-only (never synced or migrated to a new device)
/// and readable after first unlock so an in-progress cleanup survives a locked screen.
public final class KeychainSecretStore: SecretStore, @unchecked Sendable {
    private let service: String

    public init(service: String) {
        self.service = service
    }

    private func baseQuery(for key: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        if let key { query[kSecAttrAccount as String] = key }
        return query
    }

    public func data(for key: String) throws -> Data? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw SecretStoreError.unexpectedStatus(status)
        }
    }

    public func set(_ data: Data, for key: String) throws {
        let query = baseQuery(for: key)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw SecretStoreError.unexpectedStatus(updateStatus) }
        var addQuery = query
        attributes.forEach { addQuery[$0.key] = $0.value }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw SecretStoreError.unexpectedStatus(addStatus) }
    }

    public func removeValue(for key: String) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.unexpectedStatus(status)
        }
    }

    public func removeAll() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.unexpectedStatus(status)
        }
    }
}
#endif
