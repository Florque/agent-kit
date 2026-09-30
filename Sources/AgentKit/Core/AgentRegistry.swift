import Foundation

// MARK: - Specialist Agent Protocol
public protocol SpecialistAgent<ProjectSnapshot, Intent>: AnyObject, Sendable {
    associatedtype ProjectSnapshot: Snapshot
    associatedtype Intent: AgentIntent
    typealias State = AgentState<ProjectSnapshot, Intent>

    var intent: Intent { get }
    func run(state: State) async throws -> State
}

// MARK: - Agent Registry
public final class AgentRegistry<ProjectSnapshot: Snapshot, Intent: AgentIntent>: @unchecked Sendable {
    public typealias Agent = any SpecialistAgent<ProjectSnapshot, Intent>
    private var specialists: [Intent: Agent] = [:]
    private var fallbackAgent: Agent?
    
    public init() {}
    
    @discardableResult
    public func register(_ agent: Agent) -> Self {
        specialists[agent.intent] = agent
        return self
    }
    
    @discardableResult
    public func setFallbackAgent(_ agent: Agent) -> Self {
        self.fallbackAgent = agent
        return self
    }
    
    public func agent(for intent: Intent) -> Agent? {
        specialists[intent]
    }
    
    public var registeredIntents: [Intent] {
        Array(specialists.keys)
    }
    
    public func run(intent: Intent, state: AgentState<ProjectSnapshot, Intent>) async throws -> AgentState<ProjectSnapshot, Intent> {
        if let specialist = specialists[intent] {
            return try await specialist.run(state: state)
        }
        if let fallback = fallbackAgent {
            return try await fallback.run(state: state)
        }
        throw GraphError.executionFailed("No specialist agent registered for intent: \(intent.displayName)")
    }
}
