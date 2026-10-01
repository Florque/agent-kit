import Foundation

// MARK: - Summarization Output Schema for LLM
public struct SummarizationOutput: Codable, Sendable, Equatable {
    public let summary: String
    public let extractedValues: [String: String]
    
    public init(summary: String, extractedValues: [String: String] = [:]) {
        self.summary = summary
        self.extractedValues = extractedValues
    }
}

// MARK: - Summarization Agent Protocol
public protocol SummarizationAgentProtocol: AnyObject, Sendable {
    var maxCharacters: Int { get }
    func summarize(
        messages: [ChatMessage],
        existingSummary: ConversationSummary
    ) async throws -> ConversationSummary
}

// MARK: - Summarization Agent Implementation
public final class SummarizationAgent: SummarizationAgentProtocol, @unchecked Sendable {
    public static let defaultMaxCharacters = 800
    
    public let llmProvider: LLMProvider
    public let maxCharacters: Int
    
    public init(
        llmProvider: LLMProvider,
        maxCharacters: Int = defaultMaxCharacters
    ) {
        self.llmProvider = llmProvider
        self.maxCharacters = max(50, maxCharacters)
    }
    
    public func summarize(
        messages: [ChatMessage],
        existingSummary: ConversationSummary
    ) async throws -> ConversationSummary {
        guard !messages.isEmpty else {
            return existingSummary
        }
        
        let prompt = makePrompt(messages: messages, existingSummary: existingSummary)
        
        let output: SummarizationOutput
        do {
            output = try await llmProvider.generate(prompt: prompt, schema: SummarizationOutput.self)
        } catch {
            // Fallback: If structured schema generation is not supported or fails, try chatResponse
            if let chatFallback = try? await fallbackChatSummarize(messages: messages, existingSummary: existingSummary) {
                output = chatFallback
            } else {
                throw error
            }
        }
        
        // Enforce length limit strictly
        var constrainedSummary = output.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if constrainedSummary.count > maxCharacters {
            let endIndex = constrainedSummary.index(constrainedSummary.startIndex, offsetBy: maxCharacters)
            constrainedSummary = String(constrainedSummary[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        // Merge extracted values: preserve existing precise values and merge newly extracted values
        var mergedValues = existingSummary.extractedValues
        for (key, value) in output.extractedValues {
            let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedKey.isEmpty && !trimmedValue.isEmpty {
                mergedValues[trimmedKey] = trimmedValue
            }
        }
        
        let allMessageIDs = messages.map(\.id)
        
        return ConversationSummary(
            ids: allMessageIDs,
            text: constrainedSummary,
            extractedValues: mergedValues
        )
    }
    
    private func makePrompt(messages: [ChatMessage], existingSummary: ConversationSummary) -> String {
        var contextSection = ""
        if !existingSummary.text.isEmpty {
            contextSection += """
            PRIOR CONVERSATION SUMMARY:
            "\(existingSummary.text)"
            
            """
        }
        
        if !existingSummary.extractedValues.isEmpty {
            let valuesString = existingSummary.extractedValues
                .sorted(by: { $0.key < $1.key })
                .map { "- \($0.key): \($0.value)" }
                .joined(separator: "\n")
            contextSection += """
            EXISTING PRECISE EXTRACTED VALUES (MUST PRESERVE UNLESS SUPERSEDED):
            \(valuesString)
            
            """
        }
        
        let conversationText = messages.map { "\($0.role.uppercased()): \($0.content)" }.joined(separator: "\n")
        
        return """
        System: You are an expert conversation summarization and factual extraction agent.
        Your goal is to maintain a high-density, compact conversation summary and extract precise factual key-value pairs so critical details (dates, numbers, metrics, budgets, constraints, milestones, titles) are never lost during compaction.
        
        \(contextSection)CONVERSATION MESSAGES:
        \(conversationText)
        
        REQUIREMENTS:
        1. "summary": Provide a concise narrative summary capturing the goals, decisions, progress, and current state. The summary MUST NOT exceed \(maxCharacters) characters.
        2. "extractedValues": Extract or retain all precise factual values (dates, numbers, metrics, budgets, deadlines, key names, constraints, targets). Return them as a key-value dictionary with semantic string keys (e.g., "deadline", "target_users", "budget", "tech_stack"). Never lose or omit critical quantitative or factual constraints!
        
        Return a JSON object conforming to:
        {
          "summary": "<concise summary up to \(maxCharacters) characters>",
          "extractedValues": {
            "key1": "value1",
            "key2": "value2"
          }
        }
        """
    }
    
    private func fallbackChatSummarize(messages: [ChatMessage], existingSummary: ConversationSummary) async throws -> SummarizationOutput {
        let systemPrompt = "You are a concise conversation summarizer. Summarize the conversation in under \(maxCharacters) characters. Include key facts."
        var chatMessages: [ChatMessage] = [
            ChatMessage(role: "system", content: systemPrompt)
        ]
        if !existingSummary.text.isEmpty {
            chatMessages.append(ChatMessage(role: "assistant", content: "Previous summary: \(existingSummary.text)"))
        }
        chatMessages.append(contentsOf: messages)
        let reply = try await llmProvider.chatResponse(messages: chatMessages)
        return SummarizationOutput(summary: reply, extractedValues: [:])
    }
}
