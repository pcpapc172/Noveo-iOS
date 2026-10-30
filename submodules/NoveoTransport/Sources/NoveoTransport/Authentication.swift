import Foundation

public enum NoveoAuthenticationOutcome: Equatable, Sendable {
    case authenticated(NoveoSession), codeRequired, incorrectCode
}
public enum NoveoAuthenticationError: Error { case superseded, invalidCode, accountMismatch, rejected }
public protocol NoveoAuthenticating: Sendable {
    func beginAuthentication(_ firstFrame: NoveoFrame, resuming session: NoveoSession?) async throws -> NoveoAuthenticationOutcome
    func verifyCode(_ code: String) async throws -> NoveoAuthenticationOutcome
    func disconnect() async
}

/// UI-independent auth state for a single local account. Passwords are never retained or persisted.
public actor NoveoAuthenticationCoordinator {
    public enum State: Equatable, Sendable { case signedOut, connecting, codeRequired(incorrect: Bool), authenticated(userId: String), offline }
    public private(set) var state: State = .signedOut
    public nonisolated let states: AsyncStream<State>
    private let continuation: AsyncStream<State>.Continuation
    private let accountSlot: String
    private let storage: any NoveoSessionStorage
    private let client: any NoveoAuthenticating
    private var generation = UUID()
    private var expectedUserId: String?

    public init(accountSlot: String, storage: any NoveoSessionStorage, client: any NoveoAuthenticating) {
        precondition(!accountSlot.isEmpty)
        self.accountSlot = accountSlot; self.storage = storage; self.client = client
        var captured: AsyncStream<State>.Continuation!
        self.states = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { captured = $0 }
        self.continuation = captured; captured.yield(.signedOut)
    }
    private func setState(_ state: State) { self.state = state; self.continuation.yield(state) }

    public func login(username: String, password: String, version: String, device: String, osVersion: String) async throws {
        let epoch = UUID(); self.generation = epoch
        self.expectedUserId = try self.storage.load(accountSlot: self.accountSlot)?.userId
        self.setState(.connecting)
        do {
            let result = try await self.client.beginAuthentication(.login(username: username, password: password,
                version: version, device: device, osVersion: osVersion), resuming: nil)
            try self.accept(result, epoch: epoch)
        } catch {
            if epoch == self.generation { self.setState(.signedOut); await self.client.disconnect() }
            throw error
        }
    }
    /// A transport failure keeps credentials so reconnecting does not log the user out.
    public func restore() async throws {
        let epoch = UUID(); self.generation = epoch
        guard let session = try self.storage.load(accountSlot: self.accountSlot) else { self.setState(.signedOut); return }
        self.expectedUserId = session.userId; self.setState(.connecting)
        do {
            let result = try await self.client.beginAuthentication(.reconnect(session), resuming: session)
            try self.accept(result, epoch: epoch)
        } catch {
            if epoch == self.generation { self.setState(.offline); await self.client.disconnect() }
            throw error
        }
    }
    public func submitCode(_ code: String) async throws {
        guard case .codeRequired = self.state else { throw NoveoAuthenticationError.invalidCode }
        guard code.count == 6, code.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { throw NoveoAuthenticationError.invalidCode }
        let epoch = self.generation; self.setState(.connecting)
        do { try self.accept(try await self.client.verifyCode(code), epoch: epoch) }
        catch {
            if epoch == self.generation { self.setState(.signedOut); await self.client.disconnect() }
            throw error
        }
    }
    private func accept(_ outcome: NoveoAuthenticationOutcome, epoch: UUID) throws {
        guard epoch == self.generation else { throw NoveoAuthenticationError.superseded }
        switch outcome {
        case let .authenticated(session):
            guard self.expectedUserId == nil || self.expectedUserId == session.userId else { throw NoveoAuthenticationError.accountMismatch }
            try self.storage.save(session, accountSlot: self.accountSlot)
            self.setState(.authenticated(userId: session.userId))
        case .codeRequired: self.setState(.codeRequired(incorrect: false))
        case .incorrectCode: self.setState(.codeRequired(incorrect: true))
        }
    }
    public func cancel() async {
        self.generation = UUID(); self.setState(.signedOut)
        await self.client.disconnect()
    }
    public func logout() async throws {
        self.generation = UUID(); self.setState(.signedOut)
        let removal = Result { try self.storage.remove(accountSlot: self.accountSlot) }
        await self.client.disconnect()
        try removal.get()
    }
}
