import Foundation

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, macOS 26.0, *)
public struct AppleIntelligenceLLMProvider: LLMProvider {
    public init() {}

    public func generate<T: Decodable & Sendable>(prompt: String, schema: T.Type) async throws -> T {
        let instructions = """
            You are a helpful project planning AI assistant.
            Generate JSON adhering strictly to the requested schema. Return only valid JSON without explanatory markdown formatting.
            """
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: prompt)
        let content = response.content

        if let direct = content as? T {
            return direct
        }

        let cleaned = cleanJSONString(content)
        guard let data = cleaned.data(using: .utf8) else {
            throw LLMProviderError.generalError("Failed to convert LLM output to UTF-8 data")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    public func chatResponse(messages: [ChatMessage]) async throws -> String {
        let systemPrompt = messages.first { $0.role == "system" }?.content
            ?? "You are a helpful project planning assistant."
        guard let userPrompt = messages.last(where: { $0.role == "user" })?.content else {
            throw LLMProviderError.generalError("No user prompt found in messages.")
        }
        let session = LanguageModelSession(instructions: systemPrompt)
        let response = try await session.respond(to: userPrompt)
        return response.content
    }

    private func cleanJSONString(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```json") {
            trimmed = String(trimmed.dropFirst(7))
        } else if trimmed.hasPrefix("```") {
            trimmed = String(trimmed.dropFirst(3))
        }
        if trimmed.hasSuffix("```") {
            trimmed = String(trimmed.dropLast(3))
        }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#else
public struct AppleIntelligenceLLMProvider: LLMProvider {
    public init() {}
    public func generate<T: Decodable & Sendable>(prompt: String, schema: T.Type) async throws -> T {
        throw LLMProviderError.generalError("FoundationModels not available.")
    }
    public func chatResponse(messages: [ChatMessage]) async throws -> String {
        throw LLMProviderError.generalError("FoundationModels not available.")
    }
}
#endif
