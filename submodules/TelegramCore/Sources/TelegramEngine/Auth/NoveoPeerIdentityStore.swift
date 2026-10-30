import Foundation
import NoveoTransport
import Postbox

/// Stored only in this account's Postbox, without modifying any existing peer encoding.
private struct NoveoPeerIdentitySnapshot: Codable {
    let data: Data
}

/// Account adapters call this inside their existing Postbox transaction, before inserting peers.
/// Keep the mapping and peer writes in that single transaction; never persist it in preferences
/// outside Postbox or derive IDs from a truncated UUID/hash.
@available(iOS 15.0, macOS 12.0, *)
struct NoveoPeerIdentityStore {
    private static var key: ValueBoxKey {
        // Longer than the core Int32 preference keys and distinct from application-specific keys.
        let bytes = Array("noveo.peer.ids.v1".utf8)
        let key = ValueBoxKey(length: bytes.count)
        for (index, byte) in bytes.enumerated() { key.setInt8(index, value: Int8(bitPattern: byte)) }
        return key
    }

    private static func load(transaction: Transaction, accountUserId: UUID) throws -> NoveoPeerIdentityMap {
        guard let entry = transaction.getPreferencesEntry(key: self.key) else {
            return NoveoPeerIdentityMap(accountUserId: accountUserId)
        }
        guard let saved = entry.get(NoveoPeerIdentitySnapshot.self) else {
            // Never recreate a corrupt map: it could silently assign existing histories to others.
            throw NoveoPeerIdentityError.corruptSnapshot
        }
        return try NoveoPeerIdentityMap(snapshot: saved.data, accountUserId: accountUserId)
    }

    static func resolve(transaction: Transaction, accountUserId: UUID,
                        identities: [NoveoPeerIdentityMap.Identity]) throws -> [PeerId] {
        var map = try self.load(transaction: transaction, accountUserId: accountUserId)
        let peers = try identities.map { identity -> PeerId in
            let id = try map.nativeId(for: identity)
            // All Noveo groups start as channel peers, so enabling topics/supergroup features
            // doesn't change their native peer key and detach their local history.
            return PeerId(namespace: identity.kind == .user ? Namespaces.Peer.CloudUser : Namespaces.Peer.CloudChannel,
                          id: PeerId.Id._internalFromInt64Value(id))
        }
        let snapshot = try map.snapshot()
        transaction.setPreferencesEntry(key: self.key, value: PreferencesEntry(NoveoPeerIdentitySnapshot(data: snapshot)))
        return peers
    }

    static func identity(transaction: Transaction, accountUserId: UUID,
                         peerId: PeerId) throws -> NoveoPeerIdentityMap.Identity? {
        let map = try self.load(transaction: transaction, accountUserId: accountUserId)
        guard let identity = map.identity(for: peerId.id._internalGetInt64Value()) else { return nil }
        let namespace = identity.kind == .user ? Namespaces.Peer.CloudUser : Namespaces.Peer.CloudChannel
        return peerId.namespace == namespace ? identity : nil
    }
}
