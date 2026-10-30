import Foundation

public enum NoveoPeerKind: String, Codable, Sendable { case user, chat }
public enum NoveoPeerIdentityError: Error { case corruptSnapshot, accountMismatch, exhausted }

/// Per-account UUID mapping. Persist its snapshot in the same transaction as native peers.
/// Direct-message peers use the other user's identity; `chat` is for groups/channels.
/// Message IDs need their own ordered adapter and must never use this allocator.
public struct NoveoPeerIdentityMap: Sendable {
    public struct Identity: Codable, Hashable, Sendable {
        public let kind: NoveoPeerKind
        public let serverId: UUID
        public init(kind: NoveoPeerKind, serverId: UUID) {
            self.kind = kind
            self.serverId = serverId
        }
    }
    private struct Entry: Codable { let identity: Identity; let nativeId: Int64 }
    private struct Snapshot: Codable { let version: Int; let accountUserId: UUID; let entries: [Entry] }
    public let accountUserId: UUID
    private var forward: [Identity: Int64] = [:]
    private var reverse: [Int64: Identity] = [:]
    private var nextId: Int64 = 1

    public init(accountUserId: UUID) { self.accountUserId = accountUserId }

    public init(snapshot: Data, accountUserId: UUID) throws {
        let saved = try JSONDecoder().decode(Snapshot.self, from: snapshot)
        guard saved.accountUserId == accountUserId else { throw NoveoPeerIdentityError.accountMismatch }
        guard saved.version == 1 else { throw NoveoPeerIdentityError.corruptSnapshot }
        self.init(accountUserId: accountUserId)
        for entry in saved.entries {
            guard entry.nativeId > 0, entry.nativeId <= Int64(Int32.max),
                  forward[entry.identity] == nil, reverse[entry.nativeId] == nil else {
                throw NoveoPeerIdentityError.corruptSnapshot
            }
            forward[entry.identity] = entry.nativeId
            reverse[entry.nativeId] = entry.identity
            nextId = max(nextId, entry.nativeId + 1)
        }
    }

    public mutating func nativeId(for identity: Identity) throws -> Int64 {
        if let existing = forward[identity] { return existing }
        guard nextId <= Int64(Int32.max) else { throw NoveoPeerIdentityError.exhausted }
        let result = nextId
        nextId += 1
        forward[identity] = result
        reverse[result] = identity
        return result
    }

    public func identity(for nativeId: Int64) -> Identity? { reverse[nativeId] }

    public func snapshot() throws -> Data {
        let entries = reverse.map { Entry(identity: $0.value, nativeId: $0.key) }
            .sorted { $0.nativeId < $1.nativeId }
        return try JSONEncoder().encode(Snapshot(version: 1, accountUserId: accountUserId, entries: entries))
    }
}
