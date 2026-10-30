import Foundation

/// Keep protocol integers exact. In particular, document IDs must never pass through Double.
public enum NoveoValue: Codable, Equatable, Sendable {
    case string(String), integer(Int64), decimal(Double), bool(Bool), object([String: NoveoValue]), array([NoveoValue]), null
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let decoded = try? value.decode(Bool.self) { self = .bool(decoded) }
        else if let decoded = try? value.decode(Int64.self) { self = .integer(decoded) }
        else if let decoded = try? value.decode(String.self) { self = .string(decoded) }
        else if let decoded = try? value.decode([String: NoveoValue].self) { self = .object(decoded) }
        else if let decoded = try? value.decode([NoveoValue].self) { self = .array(decoded) }
        else { self = .decimal(try value.decode(Double.self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case let .string(v): try value.encode(v)
        case let .integer(v): try value.encode(v)
        case let .decimal(v): try value.encode(v)
        case let .bool(v): try value.encode(v)
        case let .object(v): try value.encode(v)
        case let .array(v): try value.encode(v)
        case .null: try value.encodeNil()
        }
    }
    public var string: String? { if case let .string(value) = self { return value }; return nil }
    public var object: [String: NoveoValue]? { if case let .object(value) = self { return value }; return nil }
}

public struct NoveoFrame: Codable, Equatable, Sendable {
    public var fields: [String: NoveoValue]
    public var type: String { self.fields["type"]?.string ?? "" }
    public init(_ fields: [String: NoveoValue]) { self.fields = fields }
    public init(from decoder: Decoder) throws { self.fields = try decoder.singleValueContainer().decode([String: NoveoValue].self) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(self.fields) }

    public static func login(username: String, password: String, version: String, device: String, osVersion: String) -> Self {
        Self(["type": .string("login_with_password"), "username": .string(username), "password": .string(password),
              "languageCode": .string(Locale.current.languageCode ?? "en"),
              "clientInfo": .object(["clientName": .string("Noveo for iOS"), "clientVersion": .string(version),
                  "platform": .string("iOS"), "deviceModel": .string(device), "osVersion": .string(osVersion)])])
    }
    public static func reconnect(_ session: NoveoSession) -> Self {
        Self(["type": .string("reconnect"), "userId": .string(session.userId), "token": .string(session.token)])
    }
    public static func message(chatId: String, text: String, topicId: String? = nil, replyToId: String? = nil, temporaryId: String = UUID().uuidString) -> Self {
        var fields: [String: NoveoValue] = ["type": .string("message"), "chatId": .string(chatId),
            "content": .string(text), "clientTempId": .string(temporaryId), "replyToId": replyToId.map(NoveoValue.string) ?? .null]
        if let topicId { fields["topicId"] = .string(topicId) }
        return Self(fields)
    }
}

public struct NoveoSession: Codable, Equatable, Sendable {
    public let userId: String
    public let token: String
    public init(userId: String, token: String) { self.userId = userId; self.token = token }
    public static func authenticated(_ frame: NoveoFrame, fallback: Self? = nil) throws -> Self {
        guard frame.type == "login_success", let userId = frame.fields["user"]?.object?["userId"]?.string,
              let token = frame.fields["token"]?.string ?? fallback?.token, !userId.isEmpty, !token.isEmpty,
              fallback == nil || fallback?.userId == userId else { throw NoveoTransportError.invalidAuthentication }
        return Self(userId: userId, token: token)
    }
}
public enum NoveoTransportError: Error { case invalidAuthentication, disconnected, invalidResponse }
public enum NoveoMembership { case free, silver, premium
    public var maximumUploadBytes: Int64 { switch self { case .free: return 50 * 1_048_576; case .silver: return 100 * 1_048_576; case .premium: return 500 * 1_048_576 } }
}
