import Foundation

// MARK: - Routing Event for Observability
public struct RoutingEvent<Intent: AgentIntent>: Codable, Sendable {
    public let sessionID: String
    public let messageID: String
    public let intent: Intent
    public let confidence: Double
    public let wasClarification: Bool
    public let finalIntent: Intent?
    public let timestamp: Date
    
    public init(
        sessionID: String,
        messageID: String,
        intent: Intent,
        confidence: Double,
        wasClarification: Bool,
        finalIntent: Intent? = nil,
        timestamp: Date = Date()
    ) {
        self.sessionID = sessionID
        self.messageID = messageID
        self.intent = intent
        self.confidence = confidence
        self.wasClarification = wasClarification
        self.finalIntent = finalIntent
        self.timestamp = timestamp
    }
}

// MARK: - Harness Lifecycle Events
public enum AgentHarnessEvent<Intent: AgentIntent>: Sendable {
    case routingStarted(message: String)
    case routingCompleted(decision: RoutingDecision<Intent>)
    case clarificationRequested(clarification: PendingClarification<Intent>)
    case clarificationResolved(intent: Intent)
    case specialistStarted(intent: Intent)
    case specialistCompleted(intent: Intent, result: AgentResult<Intent>)
    case summarizationCompleted(summary: ConversationSummary)
    case errorEncountered(error: Error)
}

public protocol AgentEventListener<Intent>: AnyObject, Sendable {
    associatedtype Intent: AgentIntent
    func onEvent(_ event: AgentHarnessEvent<Intent>)
}
