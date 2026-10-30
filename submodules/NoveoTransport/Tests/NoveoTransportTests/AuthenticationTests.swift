import Foundation
import XCTest
import NoveoTransport

private final class MemorySessions: NoveoSessionStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: NoveoSession] = [:]
    func load(accountSlot: String) throws -> NoveoSession? { self.lock.lock(); defer { self.lock.unlock() }; return self.values[accountSlot] }
    func save(_ session: NoveoSession, accountSlot: String) throws { self.lock.lock(); defer { self.lock.unlock() }; self.values[accountSlot] = session }
    func remove(accountSlot: String) throws { self.lock.lock(); defer { self.lock.unlock() }; self.values.removeValue(forKey: accountSlot) }
}
private actor ScriptedAuthentication: NoveoAuthenticating {
    var outcomes: [NoveoAuthenticationOutcome]
    var failure: Error?
    var deferred: CheckedContinuation<NoveoAuthenticationOutcome, Error>?
    var deferNext = false
    var started = false
    var verificationCalls = 0
    init(_ outcomes: [NoveoAuthenticationOutcome] = [], failure: Error? = nil) { self.outcomes = outcomes; self.failure = failure }
    func delayNext() { self.deferNext = true }
    func beginAuthentication(_ firstFrame: NoveoFrame, resuming session: NoveoSession?) async throws -> NoveoAuthenticationOutcome {
        self.started = true
        if self.deferNext {
            self.deferNext = false
            return try await withCheckedThrowingContinuation { self.deferred = $0 }
        }
        if let failure = self.failure { throw failure }
        return self.outcomes.removeFirst()
    }
    func finish(_ outcome: NoveoAuthenticationOutcome) { self.deferred?.resume(returning: outcome); self.deferred = nil }
    func verifyCode(_ code: String) async throws -> NoveoAuthenticationOutcome { self.verificationCalls += 1; return self.outcomes.removeFirst() }
    func disconnect() async {}
}
final class AuthenticationTests: XCTestCase {
    private func login(_ coordinator: NoveoAuthenticationCoordinator) async throws {
        try await coordinator.login(username: "test", password: "never-persist-this", version: "0.1.0", device: "iPhone", osVersion: "26")
    }
    func testTwoFactorStoresTokenOnlyAfterSuccessfulCode() async throws {
        let session = NoveoSession(userId: "user", token: "token")
        let storage = MemorySessions(); let client = ScriptedAuthentication([.codeRequired, .incorrectCode, .authenticated(session)])
        let coordinator = NoveoAuthenticationCoordinator(accountSlot: "one", storage: storage, client: client)
        try await self.login(coordinator)
        XCTAssertNil(try storage.load(accountSlot: "one"))
        let first = await coordinator.state; XCTAssertEqual(first, .codeRequired(incorrect: false))
        try await coordinator.submitCode("123456")
        let wrong = await coordinator.state; XCTAssertEqual(wrong, .codeRequired(incorrect: true))
        XCTAssertNil(try storage.load(accountSlot: "one"))
        try await coordinator.submitCode("234567")
        XCTAssertEqual(try storage.load(accountSlot: "one"), session)
    }
    func testInvalidCodeNeverGoesToNetwork() async throws {
        let client = ScriptedAuthentication([.codeRequired]);let coordinator = NoveoAuthenticationCoordinator(accountSlot: "one", storage: MemorySessions(), client: client)
        try await self.login(coordinator)
        do { try await coordinator.submitCode("１２３４５６"); XCTFail("ASCII digits required") } catch NoveoAuthenticationError.invalidCode {}
        let calls = await client.verificationCalls; XCTAssertEqual(calls, 0)
    }
    func testOfflineRestoreKeepsSavedCredentials() async throws {
        let storage = MemorySessions();let session = NoveoSession(userId: "user", token: "keep")
        try storage.save(session, accountSlot: "one")
        let coordinator = NoveoAuthenticationCoordinator(accountSlot: "one", storage: storage, client: ScriptedAuthentication(failure: URLError(.notConnectedToInternet)))
        do { try await coordinator.restore(); XCTFail("should fail offline") } catch {}
        XCTAssertEqual(try storage.load(accountSlot: "one"), session)
        let state = await coordinator.state;XCTAssertEqual(state, .offline)
    }
    func testLogoutRemovesOnlySelectedAccount() async throws {
        let storage = MemorySessions();let session = NoveoSession(userId: "user", token: "token")
        try storage.save(session, accountSlot: "one");try storage.save(session, accountSlot: "two")
        let coordinator = NoveoAuthenticationCoordinator(accountSlot: "one", storage: storage, client: ScriptedAuthentication())
        try await coordinator.logout()
        XCTAssertNil(try storage.load(accountSlot: "one"));XCTAssertEqual(try storage.load(accountSlot: "two"), session)
    }
    func testCancelledLoginCannotRestoreCredentials() async throws {
        let storage = MemorySessions();let client = ScriptedAuthentication();await client.delayNext()
        let coordinator = NoveoAuthenticationCoordinator(accountSlot: "one", storage: storage, client: client)
        let pending = Task { try await self.login(coordinator) }
        while !(await client.started) { await Task.yield() }
        await coordinator.cancel()
        await client.finish(.authenticated(NoveoSession(userId: "old", token: "old")))
        do { try await pending.value;XCTFail("superseded request") } catch NoveoAuthenticationError.superseded {}
        XCTAssertNil(try storage.load(accountSlot: "one"))
    }
    func testResumeCannotReplaceAnotherAccount() async throws {
        let storage = MemorySessions();let old = NoveoSession(userId: "one", token: "old");try storage.save(old, accountSlot: "slot")
        let client = ScriptedAuthentication([.authenticated(NoveoSession(userId: "two", token: "new"))])
        let coordinator = NoveoAuthenticationCoordinator(accountSlot: "slot", storage: storage, client: client)
        do { try await coordinator.restore();XCTFail("account mismatch") } catch NoveoAuthenticationError.accountMismatch {}
        XCTAssertEqual(try storage.load(accountSlot: "slot"), old)
    }
}
