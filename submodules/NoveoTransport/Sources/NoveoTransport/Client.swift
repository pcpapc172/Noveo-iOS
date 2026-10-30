import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Noveo authenticates in its first WebSocket frame, not via Telegram MTProto or HTTP headers.
public actor NoveoClient {
    public enum State: Equatable, Sendable { case idle, authenticating, ready, offline }
    public enum Event: Sendable { case frame(NoveoFrame), disconnected }
    public nonisolated let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    public private(set) var state: State = .idle
    private let urlSession: URLSession
    private var socket: URLSessionWebSocketTask?
    private var reader: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var generation = UUID()

    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
        var captured: AsyncStream<Event>.Continuation!
        self.events = AsyncStream { captured = $0 }
        self.continuation = captured
    }
    public func disconnect() {
        self.generation = UUID()
        self.deadline?.cancel(); self.reader?.cancel()
        self.socket?.cancel(with: .goingAway, reason: nil)
        self.socket = nil; self.state = .idle
    }
    public func authenticate(_ firstFrame: NoveoFrame, resuming session: NoveoSession? = nil) async throws -> NoveoSession {
        guard firstFrame.type == "login_with_password" || firstFrame.type == "reconnect" else { throw NoveoTransportError.invalidAuthentication }
        self.disconnect()
        let epoch = self.generation
        let connection = self.urlSession.webSocketTask(with: URL(string: "wss://noveo.ir:8443/ws")!)
        self.socket = connection; self.state = .authenticating; connection.resume()
        self.deadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
            await self?.expireAuthentication(epoch)
        }
        do {
            try await self.send(firstFrame, over: connection)
            let frame = try await self.receive(over: connection)
            guard epoch == self.generation else { throw NoveoTransportError.disconnected }
            let authenticated = try NoveoSession.authenticated(frame, fallback: session)
            self.deadline?.cancel(); self.state = .ready
            self.continuation.yield(.frame(frame))
            self.reader = Task { [weak self] in
                guard let self else { return }
                await self.readFrames(connection, epoch: epoch)
            }
            return authenticated
        } catch {
            if epoch == self.generation { self.deadline?.cancel(); connection.cancel(with: .goingAway, reason: nil); self.socket = nil; self.state = .offline }
            throw error
        }
    }
    public func send(_ frame: NoveoFrame) async throws {
        guard self.state == .ready, let socket = self.socket else { throw NoveoTransportError.disconnected }
        try await self.send(frame, over: socket)
    }
    private func send(_ frame: NoveoFrame, over socket: URLSessionWebSocketTask) async throws {
        let data = try JSONEncoder().encode(frame)
        guard let text = String(data: data, encoding: .utf8) else { throw NoveoTransportError.invalidResponse }
        try await socket.send(.string(text))
    }
    private func receive(over socket: URLSessionWebSocketTask) async throws -> NoveoFrame {
        let message = try await socket.receive()
        let data: Data
        switch message { case let .data(value): data = value; case let .string(value): data = Data(value.utf8); @unknown default: throw NoveoTransportError.invalidResponse }
        return try JSONDecoder().decode(NoveoFrame.self, from: data)
    }
    private func readFrames(_ socket: URLSessionWebSocketTask, epoch: UUID) async {
        do {
            while epoch == self.generation && !Task.isCancelled {
                let frame = try await self.receive(over: socket)
                guard epoch == self.generation else { return }
                self.continuation.yield(.frame(frame))
            }
        } catch {
            guard epoch == self.generation else { return }
            self.state = .offline; self.socket = nil; self.continuation.yield(.disconnected)
        }
    }
    private func expireAuthentication(_ epoch: UUID) {
        guard epoch == self.generation, self.state == .authenticating else { return }
        self.socket?.cancel(with: .goingAway, reason: nil)
    }
}
