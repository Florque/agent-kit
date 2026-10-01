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
    var summarizationOutput: SummarizationOutput?
    var generateCallCount: Int = 0
    var shouldFailGenerate: Bool = false
    var lastPrompt: String?
    
    func generate<T: Decodable & Sendable>(prompt: String, schema: T.Type) async throws -> T {
        generateCallCount += 1
        lastPrompt = prompt
        if shouldFailGenerate {
            throw LLMProviderError.generalError("Simulated LLM failure")
        }
        if schema == ClarificationAnswer<MockIntent>.self {
            let answer = clarificationAnswer ?? ClarificationAnswer(selectedIntent: .action, confidence: 0.95)
            return answer as! T
        }
        if schema == SummarizationOutput.self {
            let output = summarizationOutput ?? SummarizationOutput(
                summary: "Mocked conversation summary",
                extractedValues: ["goal": "Build mobile app", "deadline": "2026-12-01"]
            )
            return output as! T
        }
        throw LLMProviderError.generalError("Schema not mocked")
    }
    
    func chatResponse(messages: [ChatMessage]) async throws -> String {
        chatReply
    }
}

// MARK: - Mock Event Listener
final class MockEventListener<Intent: AgentIntent>: AgentEventListener, @unchecked Sendable {
    var summarizationEvents: [ConversationSummary] = []
    var allEvents: [AgentHarnessEvent<Intent>] = []
    
    func onEvent(_ event: AgentHarnessEvent<Intent>) {
        allEvents.append(event)
        if case .summarizationCompleted(let summary) = event {
            summarizationEvents.append(summary)
        }
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
    
    // MARK: - ConversationSummary & SummarizationAgent Tests
    
    @Test("ConversationSummary model properties, empty state, and equality")
    func testConversationSummaryModel() {
        let empty = ConversationSummary.empty
        #expect(empty.isEmpty == true)
        #expect(empty.ids.isEmpty)
        #expect(empty.text.isEmpty)
        #expect(empty.extractedValues.isEmpty)
        
        let id1 = UUID()
        let id2 = UUID()
        let summary1 = ConversationSummary(
            ids: [id1, id2],
            text: "User wants to build an iOS app.",
            extractedValues: ["target_platform": "iOS", "deadline": "2026-12-31"]
        )
        
        #expect(summary1.isEmpty == false)
        #expect(summary1.ids == [id1, id2])
        #expect(summary1.text == "User wants to build an iOS app.")
        #expect(summary1.extractedValues["target_platform"] == "iOS")
        #expect(summary1.extractedValues["deadline"] == "2026-12-31")
        
        let summary2 = ConversationSummary(
            ids: [id1, id2],
            text: "User wants to build an iOS app.",
            extractedValues: ["target_platform": "iOS", "deadline": "2026-12-31"]
        )
        #expect(summary1 == summary2)
    }
    
    @Test("SummarizationAgent executes, extracts values and preserves them across turns")
    func testSummarizationAgentExecutionAndValuePreservation() async throws {
        let mockLLM = MockAgentKitLLM()
        let agent = SummarizationAgent(llmProvider: mockLLM, maxCharacters: 500)
        
        // Turn 1
        mockLLM.summarizationOutput = SummarizationOutput(
            summary: "Initial discussion: planning an MVP.",
            extractedValues: ["budget": "$10,000", "deadline": "November"]
        )
        
        let msg1 = ChatMessage(role: "user", content: "We have a budget of $10,000 and deadline in November.")
        let summary1 = try await agent.summarize(messages: [msg1], existingSummary: .empty)
        
        #expect(summary1.text == "Initial discussion: planning an MVP.")
        #expect(summary1.extractedValues["budget"] == "$10,000")
        #expect(summary1.extractedValues["deadline"] == "November")
        #expect(summary1.ids == [msg1.id])
        
        // Turn 2: New message adds a new value (team_size) without mentioning budget or deadline
        mockLLM.summarizationOutput = SummarizationOutput(
            summary: "Discussion expanded: team of 2 engineers.",
            extractedValues: ["team_size": "2"] // LLM only extracted the new fact
        )
        
        let msg2 = ChatMessage(role: "user", content: "We will have 2 engineers working on it.")
        let summary2 = try await agent.summarize(messages: [msg1, msg2], existingSummary: summary1)
        
        #expect(summary2.text == "Discussion expanded: team of 2 engineers.")
        // Crucial test: budget and deadline MUST NOT be erased!
        #expect(summary2.extractedValues["budget"] == "$10,000")
        #expect(summary2.extractedValues["deadline"] == "November")
        #expect(summary2.extractedValues["team_size"] == "2")
        #expect(summary2.ids == [msg1.id, msg2.id])
    }
    
    @Test("SummarizationAgent enforces maxCharacters length constraint")
    func testSummarizationAgentMaxCharactersConstraint() async throws {
        let mockLLM = MockAgentKitLLM()
        let agent = SummarizationAgent(llmProvider: mockLLM, maxCharacters: 60)
        
        // Return summary longer than 60 characters
        mockLLM.summarizationOutput = SummarizationOutput(
            summary: "This is an extremely long summary of the conversation that comfortably exceeds the sixty characters limit configured on the summarization agent.",
            extractedValues: ["key": "val"]
        )
        
        let msg = ChatMessage(role: "user", content: "Plan our product.")
        let summary = try await agent.summarize(messages: [msg], existingSummary: .empty)
        
        #expect(summary.text.count <= 60)
        #expect(summary.extractedValues["key"] == "val")
    }
    
    @Test("SummarizationAgent falls back to chatResponse when generate fails")
    func testSummarizationAgentChatFallback() async throws {
        let mockLLM = MockAgentKitLLM()
        mockLLM.shouldFailGenerate = true
        mockLLM.chatReply = "Fallback chat summary result"
        
        let agent = SummarizationAgent(llmProvider: mockLLM, maxCharacters: 200)
        let msg = ChatMessage(role: "user", content: "Hello fallback")
        let summary = try await agent.summarize(messages: [msg], existingSummary: .empty)
        
        #expect(summary.text == "Fallback chat summary result")
    }
    
    @Test("AgentHarness triggers summarization on every X new user messages")
    func testAgentHarnessSummarizationCadenceTriggering() async throws {
        let mockLLM = MockAgentKitLLM()
        let summarizer = SummarizationAgent(llmProvider: mockLLM)
        let listener = MockEventListener<MockIntent>()
        
        let router = SimpleAgentRouter<MockSnapshot, MockIntent>(
            routeHandler: { _ in RoutingDecision(intent: .greet, confidence: 1.0) },
            clarificationFactory: { _, _ in PendingClarification(question: "", options: [], originalMessage: "") }
        )
        let registry = AgentRegistry<MockSnapshot, MockIntent>()
        registry.register(GreetAgent())
        let handler = ConstrainedClarificationHandler<MockIntent>(llmProvider: mockLLM)
        let clarificationAgent = DefaultClarificationAgent<MockSnapshot, MockIntent>(llmProvider: mockLLM)
        
        // Configure harness with cadence = 2 (trigger every 2 new user messages)
        let harness = AgentHarness<MockSnapshot, MockIntent>(
            router: router,
            clarificationHandler: handler,
            registry: registry,
            clarificationAgent: clarificationAgent,
            summarizationAgent: summarizer,
            summarizationCadence: 2,
            isSummarizationEnabled: true
        )
        harness.eventListener = listener
        
        mockLLM.summarizationOutput = SummarizationOutput(
            summary: "Round 1 Summary",
            extractedValues: ["step": "first"]
        )
        
        // Turn 1: 1st user message -> Cadence is 2, so should NOT trigger summarization yet
        let (_, state1) = try await harness.handle(message: "User message 1", state: AgentState())
        #expect(state1.summarizedConversation.isEmpty == true)
        #expect(listener.summarizationEvents.count == 0)
        
        // Turn 2: 2nd user message -> Reaches cadence of 2, SHOULD trigger summarization!
        let (_, state2) = try await harness.handle(message: "User message 2", state: state1)
        #expect(state2.summarizedConversation.isEmpty == false)
        #expect(state2.summarizedConversation.text == "Round 1 Summary")
        #expect(state2.summarizedConversation.extractedValues["step"] == "first")
        #expect(listener.summarizationEvents.count == 1)
        
        // Turn 3: 3rd user message -> Only 1 new unsummarized user message, should NOT trigger
        mockLLM.summarizationOutput = SummarizationOutput(
            summary: "Round 2 Summary",
            extractedValues: ["step": "second"]
        )
        let (_, state3) = try await harness.handle(message: "User message 3", state: state2)
        #expect(state3.summarizedConversation.text == "Round 1 Summary") // Remains from turn 2
        #expect(listener.summarizationEvents.count == 1)
        
        // Turn 4: 4th user message -> 2 new unsummarized user messages, SHOULD trigger!
        let (_, state4) = try await harness.handle(message: "User message 4", state: state3)
        #expect(state4.summarizedConversation.text == "Round 2 Summary")
        #expect(state4.summarizedConversation.extractedValues["step"] == "second")
        #expect(listener.summarizationEvents.count == 2)
    }
    
    @Test("AgentHarness summarization can be disabled from harness initialization parameters")
    func testAgentHarnessSummarizationCanBeDisabled() async throws {
        let mockLLM = MockAgentKitLLM()
        let summarizer = SummarizationAgent(llmProvider: mockLLM)
        let listener = MockEventListener<MockIntent>()
        
        let router = SimpleAgentRouter<MockSnapshot, MockIntent>(
            routeHandler: { _ in RoutingDecision(intent: .greet, confidence: 1.0) },
            clarificationFactory: { _, _ in PendingClarification(question: "", options: [], originalMessage: "") }
        )
        let registry = AgentRegistry<MockSnapshot, MockIntent>()
        registry.register(GreetAgent())
        let handler = ConstrainedClarificationHandler<MockIntent>(llmProvider: mockLLM)
        let clarificationAgent = DefaultClarificationAgent<MockSnapshot, MockIntent>(llmProvider: mockLLM)
        
        // Explicitly disabled via isSummarizationEnabled: false
        let harnessDisabled = AgentHarness<MockSnapshot, MockIntent>(
            router: router,
            clarificationHandler: handler,
            registry: registry,
            clarificationAgent: clarificationAgent,
            summarizationAgent: summarizer,
            summarizationCadence: 1,
            isSummarizationEnabled: false
        )
        harnessDisabled.eventListener = listener
        
        let (_, state1) = try await harnessDisabled.handle(message: "Message 1", state: AgentState())
        let (_, state2) = try await harnessDisabled.handle(message: "Message 2", state: state1)
        
        #expect(state2.summarizedConversation.isEmpty == true)
        #expect(listener.summarizationEvents.isEmpty)
        
        // Also test convenience initialization with SummarizationConfiguration.disabled
        let harnessDisabledConfig = AgentHarness<MockSnapshot, MockIntent>(
            router: router,
            clarificationHandler: handler,
            registry: registry,
            clarificationAgent: clarificationAgent,
            summarizationAgent: summarizer,
            summarizationConfiguration: .disabled
        )
        let (_, state3) = try await harnessDisabledConfig.handle(message: "Message 3", state: AgentState())
        #expect(state3.summarizedConversation.isEmpty == true)
    }
}
