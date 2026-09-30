import Foundation

// MARK: - Agent Harness Protocol
public protocol AgentHarnessProtocol: AnyObject, Sendable {
    associatedtype ProjectSnapshot: Snapshot
    associatedtype Intent: AgentIntent
    typealias State = AgentState<ProjectSnapshot, Intent>
    
    func handle(message: String, state: State) async throws -> (result: AgentResult<Intent>, nextState: State)
}

// MARK: - Core Agent Harness (LangGraph Powered)
/// Reusable agent harness that orchestrates state, routing, clarification, and specialist graph execution.
public final class AgentHarness<ProjectSnapshot: Snapshot, Intent: AgentIntent>: AgentHarnessProtocol, @unchecked Sendable {
    public typealias State = AgentState<ProjectSnapshot, Intent>
    public typealias Router = any AgentRouter<ProjectSnapshot, Intent>
    public typealias Clarification = any ClarificationHandler<Intent>
    public typealias Registry = AgentRegistry<ProjectSnapshot, Intent>
    public typealias ClarificationAgentType = any SpecialistAgent<ProjectSnapshot, Intent>
    
    public let router: Router
    public let clarificationHandler: Clarification
    public let registry: Registry
    public let clarificationAgent: ClarificationAgentType
    
    private let compiledGraph: CompiledGraph<State>
    public weak var eventListener: (any AgentEventListener<Intent>)?
    
    public init(
        router: Router,
        clarificationHandler: Clarification,
        registry: Registry,
        clarificationAgent: ClarificationAgentType
    ) {
        self.router = router
        self.clarificationHandler = clarificationHandler
        self.registry = registry
        self.clarificationAgent = clarificationAgent
        
        // Build the LangGraph StateGraph
        let graph = StateGraph<State>()
        
        // MARK: - Router Node
        graph.addNode("router") { [weak router, weak clarificationHandler] state in
            guard let router = router, let clarificationHandler = clarificationHandler else { return state }
            var nextState = state
            
            // 1. Router Short-Circuit: Pending clarification takes priority
            if let pending = nextState.pendingClarification {
                let userReply = nextState.lastUserMessage ?? ""
                do {
                    let resolvedIntent = try await clarificationHandler.resolve(pending: pending, answer: userReply)
                    nextState.pendingClarification = nil
                    nextState.routing = RoutingDecision(
                        intent: resolvedIntent,
                        confidence: 1.0,
                        targetEntityID: nil,
                        reason: "Resolved from explicit clarification"
                    )
                } catch {
                    // Ambiguous response -> re-issue clarification
                    nextState.pendingClarification = router.makeClarification(
                        decision: RoutingDecision(intent: .unclear, confidence: 0.5, reason: "Clarification ambiguous"),
                        state: nextState
                    )
                }
                return nextState
            }
            
            // 2. Normal Routing
            let decision = try await router.route(state: nextState)
            nextState.routing = decision
            
            // 3. Ambiguous intent handling
            if decision.intent == .unclear || decision.confidence < router.configuration.clarificationThreshold {
                let clarification = router.makeClarification(decision: decision, state: nextState)
                nextState.pendingClarification = clarification
            }
            
            return nextState
        }
        
        // MARK: - Clarification Specialist Node
        graph.addNode("specialist_clarification") { [weak clarificationAgent] state in
            guard let clarificationAgent = clarificationAgent else { return state }
            return try await clarificationAgent.run(state: state)
        }
        graph.addEdge(from: "specialist_clarification", to: StateGraphConstants.end)
        
        // MARK: - Dynamic Specialist Nodes
        for intent in registry.registeredIntents {
            let nodeId = "specialist_\(intent.hashValue)"
            graph.addNode(nodeId) { [weak registry] state in
                guard let registry = registry else { return state }
                return try await registry.run(intent: intent, state: state)
            }
            graph.addEdge(from: nodeId, to: StateGraphConstants.end)
        }
        
        // Fallback node if intent is unregistered
        graph.addNode("specialist_fallback") { [weak registry] state in
            guard let registry = registry else { return state }
            guard let intent = state.routing?.intent else { return state }
            return try await registry.run(intent: intent, state: state)
        }
        graph.addEdge(from: "specialist_fallback", to: StateGraphConstants.end)
        
        // MARK: - Routing Conditional Edge
        graph.setEntryPoint("router")
        let registeredIntents = Set(registry.registeredIntents)
        graph.addConditionalEdge(from: "router") { state in
            if state.pendingClarification != nil {
                return "specialist_clarification"
            }
            
            guard let intent = state.routing?.intent else {
                return "specialist_fallback"
            }
            
            if intent == .unclear {
                return "specialist_clarification"
            }
            
            if registeredIntents.contains(intent) {
                return "specialist_\(intent.hashValue)"
            }
            
            return "specialist_fallback"
        }
        
        do {
            self.compiledGraph = try graph.compile()
        } catch {
            fatalError("Failed to compile AgentHarness StateGraph: \(error)")
        }
    }
    
    public func handle(message: String, state: State) async throws -> (result: AgentResult<Intent>, nextState: State) {
        var inputState = state
        let userMsg = ChatMessage(role: "user", content: message)
        inputState.messages.append(userMsg)
        eventListener?.onEvent(.routingStarted(message: message))
        
        var outputState = try await compiledGraph.invoke(state: inputState)
        let outputText = outputState.outputText ?? "I've processed your message."
        
        let agentMsg = ChatMessage(role: "agent", content: outputText)
        outputState.messages.append(agentMsg)
        
        let result = AgentResult(
            text: outputText,
            canGenerate: outputState.canGenerate,
            intent: outputState.routing?.intent,
            routingDecision: outputState.routing,
            pendingClarification: outputState.pendingClarification,
            metadata: outputState.metadata
        )
        
        if let intent = outputState.routing?.intent {
            eventListener?.onEvent(.specialistCompleted(intent: intent, result: result))
        }
        
        return (result, outputState)
    }
}
