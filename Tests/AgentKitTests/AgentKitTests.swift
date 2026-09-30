import Testing
import Foundation
@testable import AgentKit

// MARK: - Test Snapshot & Intent
struct MockSnapshot: Snapshot {
    var title: String = "Test Project"
    var isEmpty: Bool { title.isEmpty }
}

enum MockIntent: String, AgentIntent {
    case greet = "greet"
    case action = "action"
    case unclear = "unclear"
    
    var displayName: String {
        switch self {
        case .greet: return "Greeting"
        case .action: return "Perform Action"
        case .unclear: return "Unclear Intent"
        }
    }
}

// MARK: - Mock LLM Provider
final class MockAgentKitLLM: LLMProvider, @unchecked Sendable {
    var chatReply: String = "Mocked chat response"
    var clarificationAnswer: ClarificationAnswer<MockIntent>?
    
    func generate<T: Decodable & Sendable>(prompt: String, schema: T.Type) async throws -> T {
        if schema == ClarificationAnswer<MockIntent>.self {
            let answer = clarificationAnswer ?? ClarificationAnswer(selectedIntent: .action, confidence: 0.95)
            return answer as! T
        }
        throw LLMProviderError.generalError("Schema not mocked")
    }
    
    func chatResponse(messages: [ChatMessage]) async throws -> String {
        chatReply
    }
}

// MARK: - Mock Specialist Agents
final class GreetAgent: SpecialistAgent, @unchecked Sendable {
    typealias ProjectSnapshot = MockSnapshot
    typealias Intent = MockIntent
    let intent: MockIntent = .greet
    
    func run(state: State) async throws -> State {
        var next = state
        next.outputText = "Hello there!"
        return next
    }
}

final class ActionAgent: SpecialistAgent, @unchecked Sendable {
    typealias ProjectSnapshot = MockSnapshot
    typealias Intent = MockIntent
    let intent: MockIntent = .action
    
    func run(state: State) async throws -> State {
        var next = state
        next.outputText = "Action executed."
        next.canGenerate = true
        return next
    }
}

// MARK: - Test Suite
@Suite("AgentKit Framework Tests")
struct AgentKitTests {
    
    struct SimpleState: Sendable {
        var count: Int = 0
        var trace: [String] = []
    }
    
    @Test("StateGraph executes nodes and conditional edges")
    func testStateGraph() async throws {
        let graph = StateGraph<SimpleState>()
        
        graph.addNode("A") { state in
            var s = state
            s.count += 5
            s.trace.append("A")
            return s
        }
        graph.addNode("B") { state in
            var s = state
            s.count += 10
            s.trace.append("B")
            return s
        }
        graph.addNode("C") { state in
            var s = state
            s.count += 20
            s.trace.append("C")
            return s
        }
        
        graph.setEntryPoint("A")
        graph.addConditionalEdge(from: "A") { state in
            state.count > 0 ? "C" : "B"
        }
        graph.addEdge(from: "B", to: StateGraphConstants.end)
        graph.addEdge(from: "C", to: StateGraphConstants.end)
        
        let compiled = try graph.compile()
        let result = try await compiled.invoke(state: SimpleState())
        
        #expect(result.count == 25)
        #expect(result.trace == ["A", "C"])
    }
    
    @Test("StateGraph detects max steps loop")
    func testStateGraphMaxSteps() async throws {
        let graph = StateGraph<SimpleState>()
        graph.addNode("N1") { $0 }
        graph.addNode("N2") { $0 }
        graph.setEntryPoint("N1")
        graph.addEdge(from: "N1", to: "N2")
        graph.addEdge(from: "N2", to: "N1")
        
        let compiled = try graph.compile()
        await #expect(throws: GraphError.self) {
            try await compiled.invoke(state: SimpleState(), maxSteps: 4)
        }
    }
    
    @Test("Clarification handler direct heuristic matching")
    func testClarificationDirectMatch() async throws {
        let mockLLM = MockAgentKitLLM()
        let handler = ConstrainedClarificationHandler<MockIntent>(llmProvider: mockLLM)
        
        let pending = PendingClarification<MockIntent>(
            question: "Choose option",
            options: [.greet, .action],
            originalMessage: "What to do"
        )
        
        // Match by index "1"
        let res1 = try await handler.resolve(pending: pending, answer: "1")
        #expect(res1 == .greet)
        
        // Match by index "2"
        let res2 = try await handler.resolve(pending: pending, answer: "2")
        #expect(res2 == .action)
        
        // Match by displayName keyword
        let res3 = try await handler.resolve(pending: pending, answer: "Greeting please")
        #expect(res3 == .greet)
    }
    
    @Test("AgentHarness execution flow with router and specialists")
    func testAgentHarnessExecution() async throws {
        let mockLLM = MockAgentKitLLM()
        let router = SimpleAgentRouter<MockSnapshot, MockIntent>(
            routeHandler: { state in
                let msg = state.lastUserMessage?.lowercased() ?? ""
                if msg.contains("hello") {
                    return RoutingDecision(intent: .greet, confidence: 0.95)
                } else if msg.contains("action") {
                    return RoutingDecision(intent: .action, confidence: 0.95)
                } else {
                    return RoutingDecision(intent: .unclear, confidence: 0.5)
                }
            },
            clarificationFactory: { decision, state in
                PendingClarification(
                    question: "Did you mean greet or action?",
                    options: [.greet, .action],
                    originalMessage: state.lastUserMessage ?? ""
                )
            }
        )
        
        let handler = ConstrainedClarificationHandler<MockIntent>(llmProvider: mockLLM)
        let registry = AgentRegistry<MockSnapshot, MockIntent>()
        let greetAgent = GreetAgent()
        let actionAgent = ActionAgent()
        registry.register(greetAgent)
        registry.register(actionAgent)
        
        let clarificationAgent = DefaultClarificationAgent<MockSnapshot, MockIntent>(llmProvider: mockLLM)
        
        let harness = AgentHarness<MockSnapshot, MockIntent>(
            router: router,
            clarificationHandler: handler,
            registry: registry,
            clarificationAgent: clarificationAgent
        )
        
        // 1. Normal Greeting
        let (result1, state1) = try await harness.handle(message: "hello there", state: AgentState())
        #expect(result1.text == "Hello there!")
        #expect(state1.routing?.intent == .greet)
        #expect(result1.canGenerate == false)
        
        // 2. Ambiguous request triggers clarification
        let (result2, state2) = try await harness.handle(message: "something random", state: state1)
        #expect(state2.pendingClarification != nil)
        #expect(state2.routing?.intent == .unclear)
        #expect(result2.text.contains("Did you mean greet or action?"))
        
        // 3. User responds to clarification with "action"
        mockLLM.clarificationAnswer = ClarificationAnswer(selectedIntent: .action, confidence: 0.95)
        let (result3, state3) = try await harness.handle(message: "action please", state: state2)
        #expect(state3.pendingClarification == nil)
        #expect(state3.routing?.intent == .action)
        #expect(result3.text == "Action executed.")
        #expect(result3.canGenerate == true)
    }
}
