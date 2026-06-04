import Foundation
import Testing
@testable import Recallyx

@MainActor
@Suite("ActionRunner")
struct ActionRunnerTests {
    /// Runner with stubbed script/AI so tests stay hermetic. The script stub
    /// appends "|<script>" so we can assert threading order; the AI stub appends
    /// "|ai(<prompt>)".
    private func makeRunner(
        runScript: ((String, String) async throws -> String)? = nil,
        runAI: ((String, String?, String) async throws -> String)? = nil
    ) -> ActionRunner {
        ActionRunner(
            defaultModel: { "test-model" },
            runScript: runScript ?? { script, input in "\(input)|\(script)" },
            runAI: runAI ?? { prompt, _, input in "\(input)|ai(\(prompt))" }
        )
    }

    @Test func threadsStepsInOrder() async throws {
        let runner = makeRunner()
        let action = Action(name: "A", icon: "x", steps: [
            Step(type: .script, script: "one"),
            Step(type: .script, script: "two"),
        ])
        let out = try await runner.run(action, on: "seed")
        #expect(out == "seed|one|two")
    }

    @Test func mixesScriptAndAI() async throws {
        let runner = makeRunner()
        let action = Action(name: "A", icon: "x", steps: [
            Step(type: .script, script: "trim"),
            Step(type: .ai, prompt: "fix"),
        ])
        let out = try await runner.run(action, on: "seed")
        #expect(out == "seed|trim|ai(fix)")
    }

    @Test func disabledStep_isSkipped() async throws {
        let runner = makeRunner()
        let action = Action(name: "A", icon: "x", steps: [
            Step(type: .script, script: "one"),
            Step(type: .script, enabled: false, script: "skip"),
            Step(type: .script, script: "three"),
        ])
        let out = try await runner.run(action, on: "seed")
        #expect(out == "seed|one|three")
    }

    @Test func throwingStep_abortsBeforeLater() async throws {
        struct Boom: Error {}
        var ranSecond = false
        let runner = makeRunner(runScript: { script, _ in
            if script == "boom" { throw Boom() }
            ranSecond = true
            return "ok"
        })
        let action = Action(name: "A", icon: "x", steps: [
            Step(type: .script, script: "boom"),
            Step(type: .script, script: "after"),
        ])
        await #expect(throws: Boom.self) {
            try await runner.run(action, on: "seed")
        }
        #expect(ranSecond == false)
    }

    @Test func emptyPipeline_returnsInputUnchanged() async throws {
        let runner = makeRunner()
        let out = try await runner.run(Action(name: "A", icon: "x", steps: []), on: "seed")
        #expect(out == "seed")
    }

    @Test func emptyScriptOrPrompt_isSkipped() async throws {
        let runner = makeRunner()
        let action = Action(name: "A", icon: "x", steps: [
            Step(type: .script, script: ""),
            Step(type: .ai, prompt: ""),
        ])
        let out = try await runner.run(action, on: "seed")
        #expect(out == "seed")
    }
}
