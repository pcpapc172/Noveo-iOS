import Foundation
import XCTest
import NoveoTransport

final class PeerIdentityTests: XCTestCase {
    private let account = UUID(uuidString: "0dae68d7-141f-407f-84b9-2a3749c40d95")!
    func testStableAcrossRestartAndUUIDCase() throws {
        var original = NoveoPeerIdentityMap(accountUserId: account)
        let identity = NoveoPeerIdentityMap.Identity(kind: .user, serverId: account)
        let id = try original.nativeId(for: identity)
        var restored = try NoveoPeerIdentityMap(snapshot: original.snapshot(), accountUserId: account)
        let uppercase = NoveoPeerIdentityMap.Identity(kind: .user, serverId: UUID(uuidString: account.uuidString.uppercased())!)
        XCTAssertEqual(try restored.nativeId(for: uppercase), id)
        XCTAssertEqual(restored.identity(for: id), identity)
    }
    func testKindsCannotAliasAndNewPeersDoNotReuseIDs() throws {
        var map = NoveoPeerIdentityMap(accountUserId: account)
        let userId = try map.nativeId(for: .init(kind: .user, serverId: account))
        let chatId = try map.nativeId(for: .init(kind: .chat, serverId: account))
        XCTAssertNotEqual(userId, chatId)
        var restored = try NoveoPeerIdentityMap(snapshot: map.snapshot(), accountUserId: account)
        XCTAssertGreaterThan(try restored.nativeId(for: .init(kind: .chat, serverId: UUID())), chatId)
    }
    func testRejectsAnotherAccountsSnapshot() throws {
        let map = NoveoPeerIdentityMap(accountUserId: account)
        XCTAssertThrowsError(try NoveoPeerIdentityMap(snapshot: map.snapshot(), accountUserId: UUID()))
    }
    func testRejectsDuplicateAndOutOfRangeNativeIDs() throws {
        let identity: [String: Any] = ["kind": "user", "serverId": account.uuidString]
        for entries: [[String: Any]] in [
            [["identity": identity, "nativeId": 0]],
            [["identity": identity, "nativeId": Int64(Int32.max) + 1]],
            [["identity": identity, "nativeId": 1], ["identity": identity, "nativeId": 2]],
            [["identity": identity, "nativeId": 1], ["identity": ["kind": "chat", "serverId": UUID().uuidString], "nativeId": 1]]
        ] {
            let data = try JSONSerialization.data(withJSONObject: ["version": 1, "accountUserId": account.uuidString, "entries": entries])
            XCTAssertThrowsError(try NoveoPeerIdentityMap(snapshot: data, accountUserId: account))
        }
    }
}
