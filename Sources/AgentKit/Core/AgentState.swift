import Foundation

// MARK: - Agent Intent Protocol
public protocol AgentIntent: Codable, CaseIterable, Sendable, Equatable, Hashable {
    var displayName: String { get }
    static var unclear: Self { get }
}

// MARK: - Snapshot Protocol
public protocol Snapshot: Codable, Equatable, Sendable {
    var isEmpty: Bool { get }
}

public extension Snapshot {
    var isEmpty: Bool { false }
}

public struct EmptySnapshot: Snapshot {
    public init() {}
}

// MARK: - Routing Decision
public struct RoutingDecision<Intent: AgentIntent>: Codable, Equatable, Sendable {
    public let intent: Intent
    public let confidence: Double
    public let targetEntityID: String?
    public let reason: String?
    
    public init(
        intent: Intent,
        confidence: Double,
        targetEntityID: String? = nil,
        reason: String? = nil
    ) {
        self.intent = intent
        self.confidence = confidence
        self.targetEntityID = targetEntityID
        self.reason = reason
    }
}

// MARK: - Pending Clarification
public struct PendingClarification<Intent: AgentIntent>: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case chooseIntent = "choose_intent"
        case chooseEntity = "choose_entity"
        case chooseAction = "choose_action"
    }
    
    public let id: String
    public let type: Kind
    public let question: String
    public let options: [Intent]
    public let originalMessage: String
    public let createdAt: Date
    
    public init(
        id: String = UUID().uuidString,
        type: Kind = .chooseIntent,
        question: String,
        options: [Intent],
        originalMessage: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.type = type
        self.question = question
        self.options = options
        self.originalMessage = originalMessage
        self.createdAt = createdAt
    }
}

public struct ConversationSummary: Sendable, Codable, Equatable {
    public let ids: [UUID]
    public let text: String
    public let extractedValues: [String: String]

    public init(
        ids: [UUID] = [],
        text: String = "",
        extractedValues: [String: String] = [:]
    ) {
        self.ids = ids
        self.text = text
        self.extractedValues = extractedValues
    }

    public static let empty = ConversationSummary(ids: [], text: "", extractedValues: [:])

    public var isEmpty: Bool {
        ids.isEmpty && text.isEmpty && extractedValues.isEmpty
    }
}

// Deprecated typealias for backwards compatibility
@available(*, deprecated, renamed: "ConversationSummary")
public typealias ChatMessagesSummary = ConversationSummary

// MARK: - Core Shared AgentState
public struct AgentState<ProjectSnapshot: Snapshot, Intent: AgentIntent>: Codable, Sendable {
    public var messages: [ChatMessage]
    public var summarizedConversation: ConversationSummary
    public var project: ProjectSnapshot?
    public var pendingClarification: PendingClarification<Intent>?
    public var routing: RoutingDecision<Intent>?
    public var metadata: [String: String]
    public var outputText: String?
    public var canGenerate: Bool
    public var error: String?
    
    public init(
        messages: [ChatMessage] = [],
        summarizedConversation: ConversationSummary = .empty,
        project: ProjectSnapshot? = nil,
        pendingClarification: PendingClarification<Intent>? = nil,
        routing: RoutingDecision<Intent>? = nil,
        metadata: [String: String] = [:],
        outputText: String? = nil,
        canGenerate: Bool = false,
        error: String? = nil
    ) {
        self.messages = messages
        self.summarizedConversation = summarizedConversation
        self.project = project
        self.pendingClarification = pendingClarification
        self.routing = routing
        self.metadata = metadata
        self.outputText = outputText
        self.canGenerate = canGenerate
        self.error = error
    }
    
    public var lastUserMessage: String? {
        messages.last(where: { $0.role == "user" })?.content
    }
    
    public var consolidatedUserInput: String {
        messages
            .filter { $0.role == "user" }
            .map { $0.content }
            .joined(separator: "\n\n")
    }
}

// MARK: - Agent Execution Result
public struct AgentResult<Intent: AgentIntent>: Sendable {
    public let text: String
    public let canGenerate: Bool
    public let intent: Intent?
    public let routingDecision: RoutingDecision<Intent>?
    public let pendingClarification: PendingClarification<Intent>?
    public let metadata: [String: String]
    
    public init(
        text: String,
        canGenerate: Bool = false,
        intent: Intent? = nil,
        routingDecision: RoutingDecision<Intent>? = nil,
        pendingClarification: PendingClarification<Intent>? = nil,
        metadata: [String: String] = [:]
    ) {
        self.text = text
        self.canGenerate = canGenerate
        self.intent = intent
        self.routingDecision = routingDecision
        self.pendingClarification = pendingClarification
        self.metadata = metadata
    }
}

// MARK: - Persisted Session
public struct PersistedAgentSession<Intent: AgentIntent>: Codable, Sendable {
    public let sessionID: String
    public var messages: [ChatMessage]
    public var summarizedConversation: ConversationSummary
    public var projectID: String?
    public var pendingClarification: PendingClarification<Intent>?
    public var routing: RoutingDecision<Intent>?
    public var updatedAt: Date
    
    public init(
        sessionID: String = UUID().uuidString,
        messages: [ChatMessage],
        summarizedConversation: ConversationSummary = .empty,
        projectID: String? = nil,
        pendingClarification: PendingClarification<Intent>? = nil,
        routing: RoutingDecision<Intent>? = nil,
        updatedAt: Date = Date()
    ) {
        self.sessionID = sessionID
        self.messages = messages
        self.summarizedConversation = summarizedConversation
        self.projectID = projectID
        self.pendingClarification = pendingClarification
        self.routing = routing
        self.updatedAt = updatedAt
    }
}
