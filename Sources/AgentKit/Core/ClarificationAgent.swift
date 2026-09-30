import Foundation

public final class DefaultClarificationAgent<ProjectSnapshot: Snapshot, Intent: AgentIntent>: SpecialistAgent {
    public let intent: Intent
    public let llmProvider: LLMProvider
    
    public init(intent: Intent = .unclear, llmProvider: LLMProvider) {
        self.intent = intent
        self.llmProvider = llmProvider
    }
    
    public func run(state: AgentState<ProjectSnapshot, Intent>) async throws -> AgentState<ProjectSnapshot, Intent> {
        var nextState = state
        guard let clarification = state.pendingClarification else {
            let defaultQuestion = "I want to make sure I understand what you need most. How can I help?"
            nextState.outputText = defaultQuestion
            return nextState
        }
        
        let optionsList = clarification.options.enumerated().map { "\($0.offset + 1). \($0.element.displayName)" }.joined(separator: "\n")
        let fullQuestion = """
        \(clarification.question)
        
        \(optionsList)
        """
        
        nextState.outputText = fullQuestion
        return nextState
    }
}
