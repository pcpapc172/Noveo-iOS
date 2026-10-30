import Foundation
#if canImport(Security)
import Security
#endif

/// Synchronous storage lets the authentication actor commit a session atomically with its state.
public protocol NoveoSessionStorage: Sendable {
    func load(accountSlot: String) throws -> NoveoSession?
    func save(_ session: NoveoSession, accountSlot: String) throws
    func remove(accountSlot: String) throws
}
public enum NoveoSessionStorageError: Error { case invalidSlot, corruptData, unavailable(Int32) }

#if canImport(Security)
/// Tokens are device-only Keychain items, isolated by Telegram's local AccountRecordId.
public struct NoveoKeychainSessionStorage: NoveoSessionStorage {
    private let service: String
    public init(service: String = "ir.noveo.ios.sessions") { self.service = service }
    private func query(_ slot: String) throws -> [String: Any] {
        guard !slot.isEmpty else { throw NoveoSessionStorageError.invalidSlot }
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: self.service,
                kSecAttrAccount as String: slot, kSecAttrSynchronizable as String: false]
    }
    public func load(accountSlot: String) throws -> NoveoSession? {
        var query = try self.query(accountSlot)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw NoveoSessionStorageError.unavailable(status) }
        guard let data = item as? Data, let session = try? JSONDecoder().decode(NoveoSession.self, from: data),
              !session.userId.isEmpty, !session.token.isEmpty else { throw NoveoSessionStorageError.corruptData }
        return session
    }
    public func save(_ session: NoveoSession, accountSlot: String) throws {
        guard !session.userId.isEmpty, !session.token.isEmpty else { throw NoveoSessionStorageError.corruptData }
        var query = try self.query(accountSlot)
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(session),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw NoveoSessionStorageError.unavailable(updated) }
        query.merge(attributes) { _, new in new }
        let inserted = SecItemAdd(query as CFDictionary, nil)
        guard inserted == errSecSuccess else { throw NoveoSessionStorageError.unavailable(inserted) }
    }
    public func remove(accountSlot: String) throws {
        let status = SecItemDelete(try self.query(accountSlot) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw NoveoSessionStorageError.unavailable(status) }
    }
}
#endif
