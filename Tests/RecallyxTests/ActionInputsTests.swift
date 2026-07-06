import Foundation
import Testing
@testable import RecallyxCore

@Suite("ActionInputs")
struct ActionInputsTests {
    private func action(_ steps: [Step]) -> Action {
        Action(name: "T", icon: "x", steps: steps)
    }

    // MARK: - placeholders

    @Test func none() {
        let a = action([Step(type: .ai, prompt: "Summarize {{TEXT}}")])
        #expect(ActionInputs.placeholders(in: a).isEmpty)
    }

    @Test func one_withLabel() {
        let a = action([Step(type: .ai, prompt: "Translate to {{INPUT:Target language}}: {{TEXT}}")])
        let p = ActionInputs.placeholders(in: a)
        #expect(p == [ActionInputs.Placeholder(label: "Target language", firstStepIndex: 0)])
    }

    @Test func bareInput_defaultsToInput() {
        let a = action([Step(type: .ai, prompt: "Answer using {{INPUT}} on {{TEXT}}")])
        #expect(ActionInputs.placeholders(in: a).map(\.label) == ["Input"])
    }

    @Test func emptyLabel_defaultsToInput() {
        let a = action([Step(type: .ai, prompt: "{{INPUT:}} {{TEXT}}")])
        #expect(ActionInputs.placeholders(in: a).map(\.label) == ["Input"])
    }

    @Test func multiple_distinct_inOrder() {
        let a = action([
            Step(type: .ai, prompt: "{{INPUT:First}} then {{INPUT:Second}}"),
            Step(type: .script, script: "echo {{INPUT:Third}}"),
        ])
        #expect(ActionInputs.placeholders(in: a).map(\.label) == ["First", "Second", "Third"])
    }

    @Test func sameLabelTwice_dedupesAcrossSteps() {
        let a = action([
            Step(type: .ai, prompt: "{{INPUT:Lang}} A {{INPUT:Lang}}"),
            Step(type: .ai, prompt: "again {{INPUT:Lang}}"),
        ])
        let p = ActionInputs.placeholders(in: a)
        #expect(p == [ActionInputs.Placeholder(label: "Lang", firstStepIndex: 0)])
    }

    @Test func labelWithColons() {
        let a = action([Step(type: .ai, prompt: "{{INPUT:Ratio a:b:c}}")])
        #expect(ActionInputs.placeholders(in: a).map(\.label) == ["Ratio a:b:c"])
    }

    @Test func labelWhitespaceTrimmed() {
        let a = action([Step(type: .ai, prompt: "{{INPUT:  Target  }}")])
        #expect(ActionInputs.placeholders(in: a).map(\.label) == ["Target"])
    }

    // MARK: - apply

    @Test func apply_substitutesAndLeavesTextIntact() {
        let a = action([Step(type: .ai, prompt: "Translate to {{INPUT:Target language}}:\n\n{{TEXT}}")])
        let out = ActionInputs.apply(values: ["Target language": "German"], to: a)
        #expect(out.steps[0].prompt == "Translate to German:\n\n{{TEXT}}")
    }

    @Test func apply_replacesEveryOccurrence() {
        let a = action([Step(type: .ai, prompt: "{{INPUT:X}} and {{INPUT:X}}")])
        let out = ActionInputs.apply(values: ["X": "yo"], to: a)
        #expect(out.steps[0].prompt == "yo and yo")
    }

    @Test func apply_bareInput() {
        let a = action([Step(type: .script, script: "grep {{INPUT}}")])
        let out = ActionInputs.apply(values: ["Input": "needle"], to: a)
        #expect(out.steps[0].script == "grep needle")
    }

    @Test func apply_missingValueLeavesTokenUntouched() {
        let a = action([Step(type: .ai, prompt: "{{INPUT:X}} {{INPUT:Y}}")])
        let out = ActionInputs.apply(values: ["X": "a"], to: a)
        #expect(out.steps[0].prompt == "a {{INPUT:Y}}")
    }

    @Test func apply_doesNotMutateOriginal() {
        let a = action([Step(type: .ai, prompt: "{{INPUT:X}}")])
        _ = ActionInputs.apply(values: ["X": "z"], to: a)
        #expect(a.steps[0].prompt == "{{INPUT:X}}")
    }

    @Test func apply_valueWithSpecialChars() {
        let a = action([Step(type: .ai, prompt: "say {{INPUT:msg}}"),])
        let out = ActionInputs.apply(values: ["msg": "$10 & 5% \\o/"], to: a)
        #expect(out.steps[0].prompt == "say $10 & 5% \\o/")
    }
}
