import Foundation

public protocol LLMProvider: Sendable {
    func generate<T: Decodable & Sendable>(prompt: String, schema: T.Type) async throws -> T
    func chatResponse(messages: [ChatMessage]) async throws -> String
}

public enum LLMProviderError: Error, LocalizedError, Equatable {
    case generalError(String)

    public var errorDescription: String? {
        switch self {
        case .generalError(let msg):
            return msg
        }
    }
}
