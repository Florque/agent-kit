import Foundation

// MARK: - Router Output Schema for LLM
public struct RouterOutput<Intent: AgentIntent>: Codable, Sendable {
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

// MARK: - Router Configuration
public struct RouterConfiguration: Sendable {
    public var clarificationThreshold: Double
    
    public init(clarificationThreshold: Double = 0.78) {
        self.clarificationThreshold = clarificationThreshold
    }
}

// MARK: - Agent Router Protocol
public protocol AgentRouter<ProjectSnapshot, Intent>: AnyObject, Sendable {
    associatedtype ProjectSnapshot: Snapshot
    associatedtype Intent: AgentIntent
    typealias State = AgentState<ProjectSnapshot, Intent>
    
    var configuration: RouterConfiguration { get }
    func route(state: State) async throws -> RoutingDecision<Intent>
    func makeClarification(decision: RoutingDecision<Intent>, state: State) -> PendingClarification<Intent>
}

// MARK: - Simple/Closure-based Agent Router
public final class SimpleAgentRouter<ProjectSnapshot: Snapshot, Intent: AgentIntent>: AgentRouter {
    public let configuration: RouterConfiguration
    private let routeHandler: @Sendable (AgentState<ProjectSnapshot, Intent>) async throws -> RoutingDecision<Intent>
    private let clarificationFactory: @Sendable (RoutingDecision<Intent>, AgentState<ProjectSnapshot, Intent>) -> PendingClarification<Intent>
    
    public init(
        configuration: RouterConfiguration = RouterConfiguration(),
        routeHandler: @escaping @Sendable (AgentState<ProjectSnapshot, Intent>) async throws -> RoutingDecision<Intent>,
        clarificationFactory: @escaping @Sendable (RoutingDecision<Intent>, AgentState<ProjectSnapshot, Intent>) -> PendingClarification<Intent>
    ) {
        self.configuration = configuration
        self.routeHandler = routeHandler
        self.clarificationFactory = clarificationFactory
    }
    
    public func route(state: AgentState<ProjectSnapshot, Intent>) async throws -> RoutingDecision<Intent> {
        try await routeHandler(state)
    }
    
    public func makeClarification(decision: RoutingDecision<Intent>, state: AgentState<ProjectSnapshot, Intent>) -> PendingClarification<Intent> {
        clarificationFactory(decision, state)
    }
}
