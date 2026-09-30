import Foundation

// MARK: - Clarification Answer Schema
public struct ClarificationAnswer<Intent: AgentIntent>: Codable, Sendable {
    public let selectedIntent: Intent
    public let confidence: Double
    
    public init(selectedIntent: Intent, confidence: Double) {
        self.selectedIntent = selectedIntent
        self.confidence = confidence
    }
}

// MARK: - Clarification Resolution Error
public enum ClarificationResolutionError: Error, LocalizedError, Equatable {
    case ambiguous
    case unresolvable(String)
    
    public var errorDescription: String? {
        switch self {
        case .ambiguous:
            return "Clarification answer was ambiguous or did not match available options."
        case .unresolvable(let reason):
            return "Clarification could not be resolved: \(reason)"
        }
    }
}

// MARK: - Clarification Handler Protocol
public protocol ClarificationHandler<Intent>: AnyObject, Sendable {
    associatedtype Intent: AgentIntent
    func resolve(pending: PendingClarification<Intent>, answer: String) async throws -> Intent
}

// MARK: - Constrained Clarification Handler Implementation
public final class ConstrainedClarificationHandler<Intent: AgentIntent>: ClarificationHandler {
    public let llmProvider: LLMProvider
    public let resolutionThreshold: Double
    
    public init(llmProvider: LLMProvider, resolutionThreshold: Double = 0.85) {
        self.llmProvider = llmProvider
        self.resolutionThreshold = resolutionThreshold
    }
    
    public func resolve(pending: PendingClarification<Intent>, answer: String) async throws -> Intent {
        let trimmedAnswer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 1. Fast deterministic heuristic matching against options
        if let directMatch = resolveDirectMatch(answer: trimmedAnswer, options: pending.options) {
            return directMatch
        }
        
        // 2. Constrained LLM interpretation
        let prompt = """
        System: You are an intent disambiguation specialist.
        The user was previously asked a clarifying question to choose between a constrained list of options.
        
        CLARIFICATION QUESTION:
        "\(pending.question)"
        
        AVAILABLE OPTIONS:
        \(pending.options.map { "- \($0.displayName)" }.joined(separator: "\n"))
        
        USER REPLY:
        "\(trimmedAnswer)"
        
        Determine which ONE of the available options the user's answer corresponds to, and assign a confidence score between 0.0 and 1.0.
        
        Return a JSON object conforming to:
        {
          "selectedIntent": "<exact match from available options>",
          "confidence": 0.0 to 1.0
        }
        """
        
        let result = try await llmProvider.generate(prompt: prompt, schema: ClarificationAnswer<Intent>.self)
        
        guard pending.options.contains(result.selectedIntent) && result.confidence >= resolutionThreshold else {
            throw ClarificationResolutionError.ambiguous
        }
        
        return result.selectedIntent
    }
    
    private func resolveDirectMatch(answer: String, options: [Intent]) -> Intent? {
        let lower = answer.lowercased()
        
        // Match index numbers: "1", "2", ...
        if let index = Int(lower), index >= 1, index <= options.count {
            return options[index - 1]
        }
        
        // Match exact displayName or raw value if RawRepresentable
        for opt in options {
            if lower == opt.displayName.lowercased() {
                return opt
            }
            if let rawStr = (opt as? any RawRepresentable)?.rawValue as? String,
               lower == rawStr.lowercased() {
                return opt
            }
        }
        
        // Partial match with meaningful keywords (> 2 chars)
        let words = lower.components(separatedBy: .whitespacesAndNewlines).filter { $0.count > 2 }
        for opt in options {
            let optNameLower = opt.displayName.lowercased()
            for w in words {
                if optNameLower.contains(w) {
                    return opt
                }
            }
            if let rawStr = (opt as? any RawRepresentable)?.rawValue as? String {
                let rawLower = rawStr.lowercased()
                for w in words {
                    if rawLower.contains(w) {
                        return opt
                    }
                }
            }
        }
        
        return nil
    }
}
