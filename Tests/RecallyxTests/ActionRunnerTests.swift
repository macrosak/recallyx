import Foundation
import Testing
@testable import Recallyx
@testable import RecallyxCore

@MainActor
@Suite("ActionRunner")
struct ActionRunnerTests {
    /// Runner with stubbed script/AI so tests stay hermetic. The script stub
    /// appends "|<script>" so we can assert threading order; the AI stub appends
    /// "|ai(<prompt>)".
    private func makeRunner(
        runScript: ((String, String) async throws -> String)? = nil,
        runAI: ((String, String?, String, Data?) async throws -> String)? = nil
    ) -> ActionRunner {
        ActionRunner(
            defaultModel: { "test-model" },
            runScript: runScript ?? { script, input in "\(input)|\(script)" },
            runAI: runAI ?? { prompt, _, input, _ in "\(input)|ai(\(prompt))" }
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

    // MARK: - Image input

    /// The first AI step receives the image (imageData != nil); later steps
    /// thread the resulting text through the shared text loop (imageData == nil).
    @Test func imagePath_firstAIGetsImage_thenThreadsText() async throws {
        var imageStepGotImage = false
        var textStepGotImage = true
        let runner = makeRunner(runAI: { prompt, _, input, imageData in
            if prompt == "ocr" {
                imageStepGotImage = imageData != nil
                return "extracted"
            }
            textStepGotImage = imageData != nil
            return "\(input)|ai(\(prompt))"
        })
        let action = Action(name: "A", icon: "x", steps: [
            Step(type: .ai, prompt: "ocr"),
            Step(type: .script, script: "upper"),
            Step(type: .ai, prompt: "summarize"),
        ])
        let out = try await runner.run(action, onImageData: Data([0x89, 0x50]))
        #expect(imageStepGotImage == true)
        #expect(textStepGotImage == false)
        #expect(out == "extracted|upper|ai(summarize)")
    }

    @Test func imagePath_scriptFirst_throws() async throws {
        let runner = makeRunner()
        let action = Action(name: "A", icon: "x", steps: [
            Step(type: .script, script: "trim"),
            Step(type: .ai, prompt: "fix"),
        ])
        await #expect(throws: ActionError.self) {
            try await runner.run(action, onImageData: Data([0x00]))
        }
    }

    /// A disabled/empty leading script step is skipped; the first *effective*
    /// step (AI) takes the image.
    @Test func imagePath_skipsLeadingDisabledStep() async throws {
        let runner = makeRunner(runAI: { prompt, _, input, imageData in
            imageData != nil ? "img(\(prompt))" : "\(input)|ai(\(prompt))"
        })
        let action = Action(name: "A", icon: "x", steps: [
            Step(type: .script, enabled: false, script: "skip"),
            Step(type: .ai, prompt: "ocr"),
        ])
        let out = try await runner.run(action, onImageData: Data([0x01]))
        #expect(out == "img(ocr)")
    }

    @Test func imagePath_emptyPipeline_returnsEmpty() async throws {
        let runner = makeRunner()
        let out = try await runner.run(Action(name: "A", icon: "x", steps: []), onImageData: Data([0x01]))
        #expect(out == "")
    }

    // MARK: - Empty-result guard (don't paste "" over the user's selection)

    @Test func isEmptyResult_recognizesNothingToPaste() {
        #expect(ActionRunner.isEmptyResult("") == true)
        #expect(ActionRunner.isEmptyResult("   \n\t  ") == true)
        #expect(ActionRunner.isEmptyResult("x") == false)
        #expect(ActionRunner.isEmptyResult("  hi  ") == false)
    }

    /// An all-disabled-step image action returns "" from `run` (existing
    /// behavior) — the empty guard then recognizes that as a no-op so the
    /// caller skips the destructive paste.
    @Test func emptyImageRun_isRecognizedAsNoOp() async throws {
        let runner = makeRunner()
        let action = Action(name: "A", icon: "x", steps: [
            Step(type: .ai, enabled: false, prompt: "ocr"),
        ])
        let out = try await runner.run(action, onImageData: Data([0x01]))
        #expect(out == "")
        #expect(ActionRunner.isEmptyResult(out) == true)
    }
}
