# AgentKit

A modular, type-safe **LangGraph-inspired Agent Orchestration Harness** for Swift and iOS.

`AgentKit` provides the core primitives required to construct stateful, multi-agent systems in native Swift. It decouples graph workflow coordination, routing decisions, clarification handling, and observability from application-specific domain models.

---

## Key Features

- **LangGraph-Style State Graphs (`StateGraph<State>`)**:
  - Strongly typed, Sendable state representation.
  - Support for direct edges (`addEdge`), dynamic conditional edges (`addConditionalEdge`), and compilation to an executable `CompiledGraph`.
  - Infinite cycle detection with configurable `maxSteps` limits.
  - Special `StateGraphConstants.start` and `StateGraphConstants.end` terminal targets.

- **Shared State Architecture (`AgentState<Snapshot, Intent>`)**:
  - Unified state across all graph nodes containing conversation history (`[ChatMessage]`), contextual snapshots (`Snapshot`), routing decisions, and clarification state.

- **Hybrid Routing Engine (`AgentRouter`)**:
  - Layered routing: deterministic heuristics evaluate first for instant, zero-cost routing, while ambiguous requests fall back to structured LLM classification.
  - Built-in confidence thresholding (`clarificationThreshold: Double = 0.78`).

- **First-Class Clarification Lifecycle (`PendingClarification`, `ClarificationHandler`)**:
  - Ambiguous requests create a `PendingClarification` object with constrained options.
  - **Router Short-Circuit**: Answers to clarifying questions are routed directly to the clarification resolver rather than being re-evaluated as top-level requests.
  - Resolves via fast numerical selection, exact keyword heuristics, or constrained LLM matching.

- **Decoupled Specialist Agent Registry (`AgentRegistry`)**:
  - Conforms agents to the `SpecialistAgent` protocol.
  - Automatically compiles registered agents into dedicated graph execution nodes with configurable fallbacks.

- **Observability & Lifecycle Events (`AgentEventListener`)**:
  - Emits fine-grained events (`routingStarted`, `routingCompleted`, `clarificationRequested`, `clarificationResolved`, `specialistCompleted`, `errorEncountered`).
  - Structured `RoutingEvent` payloads ready for session telemetry and logging.

- **LLM Provider Agnostic (`LLMProvider`)**:
  - Common async interface for structured generation and chat responses.
  - Built-in `AppleIntelligenceLLMProvider` targeting on-device Apple Intelligence via `FoundationModels` (iOS 18+ / 26+).

---

## Architecture Overview

```text
               User Message
                    │
                    ▼
          ┌───────────────────┐
          │  Pending Clarif?  │──── Yes ───► ClarificationHandler
          └─────────┬─────────┘                      │
                    │ No                             │
                    ▼                                ▼
          ┌───────────────────┐               Clear State
          │   Hybrid Router   │                      │
          └─────────┬─────────┘                      │
                    │                                │
     ┌──────────────┴──────────────┐                 │
     ▼                             ▼                 │
Confidence >= 0.78          Confidence < 0.78        │
     │                             │                 │
     ▼                             ▼                 │
Specialist Agent           Ask Clarification         │
     │                             │                 │
     └─────────────────────────────┼─────────────────┘
                                   │
                                   ▼
                              AgentResult
```

---

## Requirements

- **iOS 18.0+** / **macOS 15.0+**
- **Swift 6.0+**
- Xcode 16.0+

---

## Installation

Add `AgentKit` to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Florque/agent-kit.git", from: "1.0.0")
]
```

Or add it directly in Xcode via **File > Add Package Dependencies...**.

---

## Quickstart

### 1. Define Intents and Snapshots

Define your application-specific intents and optional domain snapshot:

```swift
import AgentKit

public enum MyIntent: String, AgentIntent {
    case setup = "setup"
    case review = "review"
    case chat = "chat"
    case unclear = "unclear"

    public var displayName: String {
        switch self {
        case .setup: return "Project Setup"
        case .review: return "Progress Review"
        case .chat: return "General Chat"
        case .unclear: return "Clarification Needed"
        }
    }
}

public struct MySnapshot: Snapshot {
    public var title: String
    public var taskCount: Int

    public var isEmpty: Bool {
        title.isEmpty && taskCount == 0
    }
}
```

### 2. Implement a Specialist Agent

```swift
import AgentKit

final class SetupAgent: SpecialistAgent {
    let intent: MyIntent = .setup

    func run(state: AgentState<MySnapshot, MyIntent>) async throws -> AgentState<MySnapshot, MyIntent> {
        var nextState = state
        nextState.outputText = "Let's configure your project goals and timeline."
        nextState.canGenerate = true
        return nextState
    }
}
```

### 3. Assemble and Run the Harness

```swift
import AgentKit

// 1. Setup Router and Registry
let router = SimpleAgentRouter<MySnapshot, MyIntent>(
    routeHandler: { state in
        let text = state.lastUserMessage?.lowercased() ?? ""
        if text.contains("setup") {
            return RoutingDecision(intent: .setup, confidence: 0.95)
        }
        return RoutingDecision(intent: .unclear, confidence: 0.5)
    },
    clarificationFactory: { decision, state in
        PendingClarification(
            question: "Would you like to set up a project or chat?",
            options: [.setup, .chat],
            originalMessage: state.lastUserMessage ?? ""
        )
    }
)

let registry = AgentRegistry<MySnapshot, MyIntent>()
registry.register(SetupAgent())

let clarificationHandler = ConstrainedClarificationHandler<MyIntent>(llmProvider: myLLM)
let clarificationAgent = DefaultClarificationAgent<MySnapshot, MyIntent>(llmProvider: myLLM)

// 2. Instantiate Harness
let harness = AgentHarness(
    router: router,
    clarificationHandler: clarificationHandler,
    registry: registry,
    clarificationAgent: clarificationAgent
)

// 3. Process Turns
var state = AgentState<MySnapshot, MyIntent>()
let (result, nextState) = try await harness.handle(message: "I need to setup a new project", state: state)

print("Agent Response: \(result.text)")
print("Routing Decision: \(result.intent?.displayName ?? "none")")
```

---

## Custom State Graphs

You can also use the standalone `StateGraph` engine directly to orchestrate arbitrary stateful workflows:

```swift
import AgentKit

struct PipelineState: Sendable {
    var count: Int = 0
}

let graph = StateGraph<PipelineState>()

graph.addNode("increment") { state in
    var s = state
    s.count += 1
    return s
}

graph.addNode("finalize") { state in
    var s = state
    s.count *= 2
    return s
}

graph.setEntryPoint("increment")
graph.addConditionalEdge(from: "increment") { state in
    state.count >= 1 ? "finalize" : "increment"
}
graph.addEdge(from: "finalize", to: StateGraphConstants.end)

let compiled = try graph.compile()
let finalState = try await compiled.invoke(state: PipelineState())
// finalState.count == 2
```

---

## Testing

Run unit tests via Xcode or the command line:

```bash
swift test
```

---

## License

This project is licensed under the MIT License.
