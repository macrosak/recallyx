import Foundation
import Testing
@testable import Recallyx
@testable import RecallyxCore

/// Per-AI-step reasoning effort: the `Step.effort` model (tolerant decode),
/// threading through `ActionRunner`, and the pure per-provider request bodies.
/// Hermetic — no network.
@MainActor
@Suite("Reasoning effort")
struct ReasoningEffortTests {

    private func json(_ body: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private let png = Data([0x89, 0x50, 0x4E, 0x47])

    // MARK: - Model

    @Test func defaultEffortIsNil() {
        #expect(Step(type: .ai).effort == nil)
    }

    @Test func legacyStepWithoutEffortKeyDecodesToNil() throws {
        let legacy = """
        {"id":"\(UUID().uuidString)","type":"ai","enabled":true,"script":"","prompt":"p","model":"gpt-4o"}
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(Step.self, from: legacy)
        #expect(s.effort == nil)
        #expect(s.model == "gpt-4o")
        #expect(s.prompt == "p")
    }

    @Test func unknownEffortValueDecodesToNil() throws {
        let future = """
        {"id":"\(UUID().uuidString)","type":"ai","enabled":true,"script":"","prompt":"p","effort":"ultra"}
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(Step.self, from: future)
        #expect(s.effort == nil)
    }

    @Test func effortRoundTrips() throws {
        for level in Effort.allCases {
            let step = Step(type: .ai, prompt: "p", effort: level)
            let back = try JSONDecoder().decode(Step.self, from: JSONEncoder().encode(step))
            #expect(back == step)
        }
    }

    @Test func nilEffortIsOmittedFromEncoding() throws {
        let data = try JSONEncoder().encode(Step(type: .ai, prompt: "p"))
        #expect(!String(decoding: data, as: UTF8.self).contains("effort"))
    }

    @Test func actionWithEffortStepsRoundTrips() throws {
        let a = Action(name: "A", icon: "x", steps: [Step(type: .ai, prompt: "p", effort: .high), Step(type: .script, script: "cat")])
        let back = try JSONDecoder().decode(Action.self, from: JSONEncoder().encode(a))
        #expect(back == a)
    }

    // MARK: - Runner threading

    @Test func runnerPassesEachStepsEffort() async throws {
        var seen: [Effort?] = []
        let runner = ActionRunner(
            defaultModel: { "m" },
            runScript: { _, input in input },
            runAIWithEffort: { _, _, input, _, effort in
                seen.append(effort)
                return input + "+"
            }
        )
        let action = Action(name: "A", icon: "x", steps: [
            Step(type: .ai, prompt: "a", effort: .low),
            Step(type: .ai, prompt: "b"),
            Step(type: .ai, prompt: "c", effort: .high),
        ])
        _ = try await runner.run(action, on: "t")
        #expect(seen == [.low, nil, .high])
    }

    @Test func runnerPassesEffortOnImagePath() async throws {
        var seen: [Effort?] = []
        let runner = ActionRunner(
            defaultModel: { "m" },
            runAIWithEffort: { _, _, _, _, effort in
                seen.append(effort)
                return "text"
            }
        )
        let action = Action(name: "A", icon: "x", steps: [Step(type: .ai, prompt: "ocr", effort: .medium)])
        _ = try await runner.run(action, onImageData: png)
        #expect(seen == [.medium])
    }

    @Test func legacyFourArgSeamStillWorks() async throws {
        let runner = ActionRunner(
            defaultModel: { "m" },
            runAI: { prompt, _, input, _ in "\(input)|\(prompt)" }
        )
        let action = Action(name: "A", icon: "x", steps: [Step(type: .ai, prompt: "p", effort: .high)])
        #expect(try await runner.run(action, on: "t") == "t|p")
    }

    // MARK: - OpenAI

    @Test func openAIBodyWithoutEffortIsUnchanged() throws {
        let expected: [String: Any] = [
            "model": "gpt-6-sol",
            "messages": [["role": "user", "content": "hi"]],
            "max_completion_tokens": 4096,
        ]
        #expect(try json(OpenAIClient.requestBody(model: "gpt-6-sol", fullPrompt: "hi")) == json(expected))
    }

    @Test func openAIVisionBodyWithoutEffortIsUnchanged() throws {
        let body = OpenAIClient.requestBody(model: "gpt-5", fullPrompt: "hi", imageData: png)
        #expect(body["reasoning_effort"] == nil)
        #expect(body["max_completion_tokens"] as? Int == 4096)
    }

    @Test func openAIReasoningModelGetsReasoningEffort() throws {
        let body = OpenAIClient.requestBody(model: "gpt-6-sol", fullPrompt: "hi", effort: .high)
        #expect(body["reasoning_effort"] as? String == "high")
        #expect(body["max_completion_tokens"] as? Int == AIClientDefaults.maxOutputTokensWithReasoning)
    }

    @Test func openAINonReasoningModelIgnoresEffort() throws {
        let plain = try json(OpenAIClient.requestBody(model: "gpt-4o-mini", fullPrompt: "hi"))
        #expect(try json(OpenAIClient.requestBody(model: "gpt-4o-mini", fullPrompt: "hi", effort: .low)) == plain)
    }

    @Test func openAICustomEndpointNeverGetsEffort() throws {
        let plain = try json(OpenAIClient.requestBody(model: "gpt-5", fullPrompt: "hi"))
        let custom = try json(OpenAIClient.requestBody(model: "gpt-5", fullPrompt: "hi", effort: .high, isCustomEndpoint: true))
        #expect(custom == plain)
    }

    @Test func openAIReasoningModelGate() {
        for m in ["gpt-5", "gpt-5-mini", "gpt-5.1", "GPT-6-luna", "gpt-6-sol", "o1", "o1-mini", "o3", "o3-mini", "o4-mini", "gpt-10"] {
            #expect(OpenAIClient.supportsReasoningEffort(model: m), "\(m)")
        }
        for m in ["gpt-4o", "gpt-4o-mini", "gpt-4.1", "gpt-4.5-preview", "gpt-5-chat-latest", "o10", "omni", "llama3", "gpt-"] {
            #expect(!OpenAIClient.supportsReasoningEffort(model: m), "\(m)")
        }
    }

    // MARK: - Anthropic

    @Test func anthropicBodyWithoutEffortIsUnchanged() throws {
        let expected: [String: Any] = [
            "model": "claude-opus-5-5",
            "max_tokens": 4096,
            "messages": [["role": "user", "content": "hi"]],
        ]
        #expect(try json(AnthropicClient.requestBody(model: "claude-opus-5-5", fullPrompt: "hi")) == json(expected))
    }

    @Test func anthropicCurrentModelUsesAdaptiveThinkingAndEffort() throws {
        let body = AnthropicClient.requestBody(model: "claude-sonnet-5", fullPrompt: "hi", effort: .medium)
        #expect((body["thinking"] as? [String: Any])?["type"] as? String == "adaptive")
        #expect((body["thinking"] as? [String: Any])?["budget_tokens"] == nil)
        #expect((body["output_config"] as? [String: Any])?["effort"] as? String == "medium")
        #expect(body["max_tokens"] as? Int == AIClientDefaults.maxOutputTokensWithReasoning)
    }

    @Test func anthropicLegacyModelUsesThinkingBudget() throws {
        for (effort, budget) in [(Effort.low, 1024), (.medium, 4096), (.high, 16000)] {
            let body = AnthropicClient.requestBody(model: "claude-haiku-4-5", fullPrompt: "hi", effort: effort)
            let thinking = body["thinking"] as? [String: Any]
            #expect(thinking?["type"] as? String == "enabled")
            #expect(thinking?["budget_tokens"] as? Int == budget)
            #expect(body["output_config"] == nil)
            let maxTokens = body["max_tokens"] as? Int ?? 0
            #expect(maxTokens == budget + AIClientDefaults.maxOutputTokens)
            #expect(maxTokens > budget)
        }
    }

    @Test func anthropicLegacyGate() {
        for m in ["claude-haiku-4-5", "claude-haiku-4-5-20251001", "claude-sonnet-4-5", "claude-opus-4-1", "claude-3-7-sonnet-latest"] {
            #expect(AnthropicClient.usesLegacyThinkingBudget(model: m), "\(m)")
        }
        for m in ["claude-sonnet-5", "claude-opus-5-5", "claude-fable-5-1", "claude-sonnet-4-6", "claude-opus-4-8", "claude-haiku-5-5"] {
            #expect(!AnthropicClient.usesLegacyThinkingBudget(model: m), "\(m)")
        }
    }

    @Test func anthropicVisionBodyKeepsImageWithEffort() throws {
        let body = AnthropicClient.requestBody(model: "claude-opus-5-5", fullPrompt: "hi", imageData: png, effort: .low)
        let messages = body["messages"] as? [[String: Any]]
        let content = messages?.first?["content"] as? [[String: Any]]
        #expect(content?.first?["type"] as? String == "image")
        #expect((body["output_config"] as? [String: Any])?["effort"] as? String == "low")
    }

    @Test func anthropicResultSkipsThinkingBlocks() {
        let response = """
        {"content":[
          {"type":"thinking","thinking":"secret reasoning","signature":"x"},
          {"type":"redacted_thinking","data":"zzz"},
          {"type":"text","text":"  answer  "}
        ],"stop_reason":"end_turn"}
        """.data(using: .utf8)!
        #expect(AnthropicClient.resultText(fromResponseData: response) == "answer")
    }

    @Test func anthropicResultNilWhenOnlyThinking() {
        let response = """
        {"content":[{"type":"thinking","thinking":"hmm","signature":"x"}],"stop_reason":"max_tokens"}
        """.data(using: .utf8)!
        #expect(AnthropicClient.resultText(fromResponseData: response) == nil)
    }

    // MARK: - Gemini

    @Test func geminiBodyWithoutEffortIsUnchanged() throws {
        let expected: [String: Any] = [
            "contents": [["parts": [["text": "hi"]]]],
            "generationConfig": ["maxOutputTokens": 4096],
        ]
        #expect(try json(GeminiClient.requestBody(fullPrompt: "hi")) == json(expected))
    }

    @Test func geminiEffortSetsThinkingLevel() throws {
        for level in Effort.allCases {
            let body = GeminiClient.requestBody(fullPrompt: "hi", effort: level)
            let config = body["generationConfig"] as? [String: Any]
            #expect((config?["thinkingConfig"] as? [String: Any])?["thinkingLevel"] as? String == level.rawValue)
            #expect((config?["thinkingConfig"] as? [String: Any])?["includeThoughts"] == nil)
            #expect(config?["maxOutputTokens"] as? Int == AIClientDefaults.maxOutputTokensWithReasoning)
        }
    }

    @Test func geminiResultSkipsThoughtParts() {
        let response = """
        {"candidates":[{"content":{"parts":[
          {"text":"thinking about it","thought":true},
          {"text":" answer "}
        ]},"finishReason":"STOP"}]}
        """.data(using: .utf8)!
        #expect(GeminiClient.resultText(fromResponseData: response) == "answer")
    }

    @Test func geminiResultPlainResponseUnchanged() {
        let response = """
        {"candidates":[{"content":{"parts":[{"text":"ok"}]}}]}
        """.data(using: .utf8)!
        #expect(GeminiClient.resultText(fromResponseData: response) == "ok")
    }

    // MARK: - Timeouts

    @Test func timeoutOnlyRaisedWithEffort() {
        #expect(AIClientDefaults.timeout(for: nil) == 30)
        #expect(AIClientDefaults.timeout(for: .low) == AIClientDefaults.reasoningRequestTimeout)
    }
}
