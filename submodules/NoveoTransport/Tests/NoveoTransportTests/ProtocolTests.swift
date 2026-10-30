import Foundation
import XCTest
import NoveoTransport

final class ProtocolTests: XCTestCase {
    func testDocumentIDsKeepAllDigits() throws {
        let data = Data(#"{"type":"forum_update","iconEmojiId":"4907219728767910669","integer":4907219728767910669}"#.utf8)
        let frame = try JSONDecoder().decode(NoveoFrame.self, from: data)
        XCTAssertEqual(frame.fields["iconEmojiId"], .string("4907219728767910669"))
        XCTAssertEqual(frame.fields["integer"], .integer(4_907_219_728_767_910_669))
        XCTAssertEqual(try JSONDecoder().decode(NoveoFrame.self, from: JSONEncoder().encode(frame)), frame)
    }
    func testLoginUsesNoveoFirstFrameAndCorrectClientIdentity() {
        let frame = NoveoFrame.login(username: "test", password: "test", version: "0.1.0", device: "iPhone", osVersion: "26")
        XCTAssertEqual(frame.type, "login_with_password")
        XCTAssertEqual(frame.fields["clientInfo"]?.object?["platform"], .string("iOS"))
        XCTAssertEqual(frame.fields["clientInfo"]?.object?["clientName"], .string("Noveo for iOS"))
    }
    func testResumeRetainsTokenButRejectsDifferentAccount() throws {
        let old = NoveoSession(userId: "one", token: "token")
        let frame = NoveoFrame(["type": .string("login_success"), "user": .object(["userId": .string("one")])])
        XCTAssertEqual(try NoveoSession.authenticated(frame, fallback: old), old)
        XCTAssertThrowsError(try NoveoSession.authenticated(frame, fallback: NoveoSession(userId: "two", token: "token")))
        XCTAssertThrowsError(try NoveoSession.authenticated(frame))
    }
    func testTopicMessagesRetainThreadAndRetryIdentity() throws {
        let frame = NoveoFrame.message(chatId: "group", text: "ai test", topicId: "topic", replyToId: "root", temporaryId: "retry")
        let sent = try JSONDecoder().decode(NoveoFrame.self, from: JSONEncoder().encode(frame))
        XCTAssertEqual(sent.fields["topicId"], .string("topic"))
        XCTAssertEqual(sent.fields["replyToId"], .string("root"))
        XCTAssertEqual(sent.fields["clientTempId"], .string("retry"))
    }
    func testUploadPlanLimits() {
        XCTAssertEqual(NoveoMembership.free.maximumUploadBytes, 52_428_800)
        XCTAssertEqual(NoveoMembership.silver.maximumUploadBytes, 104_857_600)
        XCTAssertEqual(NoveoMembership.premium.maximumUploadBytes, 524_288_000)
    }
    func testSocketCannotSendMessagesBeforeAuthentication() async {
        let client = NoveoClient()
        do { try await client.send(.message(chatId: "group", text: "test")); XCTFail("must reject unauthenticated send") }
        catch NoveoTransportError.disconnected {} catch { XCTFail("unexpected error") }
    }
}
