import Foundation

// MARK: - Constants
public enum StateGraphConstants {
    public static let end = "__end__"
    public static let start = "__start__"
}

// MARK: - Graph Node Protocol
public protocol GraphNode<State>: Sendable {
    associatedtype State: Sendable
    var id: String { get }
    func execute(state: State) async throws -> State
}

// MARK: - Any Graph Node (Type Erasure)
public struct AnyGraphNode<State: Sendable>: GraphNode {
    public let id: String
    private let _execute: @Sendable (State) async throws -> State
    
    public init(id: String, execute: @escaping @Sendable (State) async throws -> State) {
        self.id = id
        self._execute = execute
    }
    
    public init<N: GraphNode>(_ node: N) where N.State == State {
        self.id = node.id
        self._execute = { state in
            try await node.execute(state: state)
        }
    }
    
    public func execute(state: State) async throws -> State {
        try await _execute(state)
    }
}

// MARK: - Graph Edge
public enum GraphEdge<State: Sendable>: @unchecked Sendable {
    case direct(to: String)
    case conditional(router: @Sendable (State) async throws -> String)
}

// MARK: - Graph Errors
public enum GraphError: Error, LocalizedError, Equatable {
    case entryPointNotSet
    case nodeNotFound(String)
    case edgeTargetNotFound(String)
    case maxStepsExceeded(Int)
    case executionFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .entryPointNotSet:
            return "StateGraph: Entry point is not set."
        case .nodeNotFound(let id):
            return "StateGraph: Node '\(id)' not found."
        case .edgeTargetNotFound(let id):
            return "StateGraph: Edge target node '\(id)' not found."
        case .maxStepsExceeded(let max):
            return "StateGraph: Maximum step limit of \(max) exceeded."
        case .executionFailed(let reason):
            return "StateGraph: Execution failed: \(reason)"
        }
    }
}

// MARK: - LangGraph-style State Graph
/// A generic, type-safe directed state graph that compiles into an executable graph.
public final class StateGraph<State: Sendable> {
    private var nodes: [String: AnyGraphNode<State>] = [:]
    private var edges: [String: GraphEdge<State>] = [:]
    private var entryPoint: String?
    
    public init() {}
    
    @discardableResult
    public func addNode(_ id: String, execute: @escaping @Sendable (State) async throws -> State) -> Self {
        nodes[id] = AnyGraphNode(id: id, execute: execute)
        return self
    }
    
    @discardableResult
    public func addNode<N: GraphNode>(_ node: N) -> Self where N.State == State {
        nodes[node.id] = AnyGraphNode(node)
        return self
    }
    
    @discardableResult
    public func addEdge(from fromNode: String, to toNode: String) -> Self {
        edges[fromNode] = .direct(to: toNode)
        return self
    }
    
    @discardableResult
    public func addConditionalEdge(from fromNode: String, router: @escaping @Sendable (State) async throws -> String) -> Self {
        edges[fromNode] = .conditional(router: router)
        return self
    }
    
    @discardableResult
    public func setEntryPoint(_ id: String) -> Self {
        self.entryPoint = id
        return self
    }
    
    public func compile() throws -> CompiledGraph<State> {
        guard let entry = entryPoint else {
            throw GraphError.entryPointNotSet
        }
        guard nodes[entry] != nil else {
            throw GraphError.nodeNotFound(entry)
        }
        return CompiledGraph(nodes: nodes, edges: edges, entryPoint: entry)
    }
}

// MARK: - Compiled Graph Execution Engine
public final class CompiledGraph<State: Sendable>: @unchecked Sendable {
    public let nodes: [String: AnyGraphNode<State>]
    public let edges: [String: GraphEdge<State>]
    public let entryPoint: String
    
    public init(
        nodes: [String: AnyGraphNode<State>],
        edges: [String: GraphEdge<State>],
        entryPoint: String
    ) {
        self.nodes = nodes
        self.edges = edges
        self.entryPoint = entryPoint
    }
    
    @discardableResult
    public func invoke(state: State, maxSteps: Int = 30) async throws -> State {
        var currentState = state
        var currentNodeId: String? = entryPoint
        var steps = 0
        
        while let nodeId = currentNodeId, nodeId != StateGraphConstants.end {
            steps += 1
            if steps > maxSteps {
                throw GraphError.maxStepsExceeded(maxSteps)
            }
            
            guard let node = nodes[nodeId] else {
                throw GraphError.nodeNotFound(nodeId)
            }
            
            currentState = try await node.execute(state: currentState)
            
            guard let edge = edges[nodeId] else {
                // Terminal node with no outgoing edge defaults to END
                break
            }
            
            switch edge {
            case .direct(let nextId):
                currentNodeId = nextId
            case .conditional(let router):
                currentNodeId = try await router(currentState)
            }
        }
        
        return currentState
    }
}
