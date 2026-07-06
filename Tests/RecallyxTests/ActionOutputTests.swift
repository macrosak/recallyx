import Foundation
import Testing
@testable import Recallyx
@testable import RecallyxCore

/// Per-action output options: the `Action.output` model (backward-compatible
/// decode + round-trip) and the pure `ActionOutcome.plan` run-path decision.
@Suite("Action output options")
struct ActionOutputTests {

    // MARK: - Model decode / round-trip

    @Test func defaultOutputIsPaste() {
        let a = Action(name: "X", icon: "star", steps: [Step(type: .ai)])
        #expect(a.output == .paste)
    }

    @Test func decodeLegacyActionWithoutOutputKeyDefaultsToPaste() throws {
        // A saved action from before this feature has no `output` key.
        let legacy = """
        {"id":"\(UUID().uuidString)","name":"Old","icon":"star","steps":[]}
        """.data(using: .utf8)!
        let a = try JSONDecoder().decode(Action.self, from: legacy)
        #expect(a.output == .paste)
    }

    @Test func decodeUnknownOutputValueFallsBackToPaste() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"Old","icon":"star","steps":[],"output":"teleport"}
        """.data(using: .utf8)!
        let a = try JSONDecoder().decode(Action.self, from: json)
        #expect(a.output == .paste)
    }

    @Test func roundTripPreservesOutput() throws {
        for mode in OutputMode.allCases {
            let a = Action(name: "X", icon: "star", steps: [Step(type: .ai)], output: mode)
            let data = try JSONEncoder().encode(a)
            let back = try JSONDecoder().decode(Action.self, from: data)
            #expect(back.output == mode)
            #expect(back == a)
        }
    }

    @Test func appendingMissingBuiltinsPreservesOutput() {
        // A default that opted into a non-paste output survives the merge copy.
        let existing = [Action(name: "Mine", icon: "star", steps: [], output: .show)]
        let merged = Action.appendingMissingBuiltins(into: existing)
        #expect(merged.first?.output == .show)
    }

    // MARK: - Run-path decision (ActionOutcome.plan)

    @Test func planRoutesEachModeToItsOutcome() {
        #expect(ActionOutcome.plan(output: .paste, result: "r") == .paste("r"))
        #expect(ActionOutcome.plan(output: .copy, result: "r") == .copy("r"))
        #expect(ActionOutcome.plan(output: .show, result: "r") == .show("r"))
        #expect(ActionOutcome.plan(output: .append, result: "r") == .append("r"))
    }

    @Test func planSkipsEmptyResultRegardlessOfMode() {
        for mode in OutputMode.allCases {
            #expect(ActionOutcome.plan(output: mode, result: "") == .skipEmpty)
            #expect(ActionOutcome.plan(output: mode, result: "   \n\t") == .skipEmpty)
        }
    }
}
