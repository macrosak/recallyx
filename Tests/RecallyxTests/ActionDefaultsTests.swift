import Foundation
import Testing
@testable import Recallyx
@testable import RecallyxCore

/// Covers the dev-action pack in `Action.defaults()` and the append-only,
/// name-matched `appendingMissingBuiltins` merge that lets existing installs
/// pick up newly shipped built-ins. Script bodies are verified manually (see
/// the design note), not by shelling out — the suite stays hermetic.
@Suite("Action defaults")
struct ActionDefaultsTests {
    private let devActionNames = [
        "URL decode", "URL encode", "Base64 decode",
        "Base64 encode", "Decode JWT", "Minify JSON",
    ]

    @Test func defaultsContainSixDevScriptActions() {
        let defaults = Action.defaults()
        for name in devActionNames {
            guard let action = defaults.first(where: { $0.name == name }) else {
                Issue.record("missing default dev action: \(name)")
                continue
            }
            #expect(action.steps.count == 1)
            let step = action.steps[0]
            #expect(step.type == .script)
            #expect(step.enabled)
            #expect(!step.script.isEmpty)
            #expect(action.kindTag == "SCRIPT")
        }
    }

    @Test func devActionsSitBetweenScriptActionsAndImageActions() {
        let names = Action.defaults().map(\.name)
        // After the last existing script action ("Extract URLs") and before the
        // first image AI action ("Extract text").
        let extractURLs = names.firstIndex(of: "Extract URLs")!
        let extractText = names.firstIndex(of: "Extract text")!
        for name in devActionNames {
            let i = names.firstIndex(of: name)!
            #expect(i > extractURLs)
            #expect(i < extractText)
        }
    }

    @Test func appendingIntoEmptyEqualsDefaultsByName() {
        let merged = Action.appendingMissingBuiltins(into: [])
        #expect(merged.count == Action.defaults().count)
        #expect(merged.map(\.name) == Action.defaults().map(\.name))
    }

    @Test func appendingIsIdempotentWhenAllPresent() {
        let full = Action.defaults()
        let merged = Action.appendingMissingBuiltins(into: full)
        #expect(merged.count == full.count)
        #expect(merged.map(\.name) == full.map(\.name))
    }

    @Test func appendingReAddsOneRemovedDefaultAndKeepsUserActionsInPlace() {
        let userA = Action(name: "My custom A", icon: "star", steps: [Step(type: .script, script: "cat")])
        let userB = Action(name: "My custom B", icon: "star", steps: [Step(type: .ai, prompt: "hi")])
        // Start from defaults minus one, with user actions interleaved.
        var existing = Action.defaults()
        existing.removeAll { $0.name == "Minify JSON" }
        existing.insert(userA, at: 0)
        existing.append(userB)

        let merged = Action.appendingMissingBuiltins(into: existing)

        // The removed default is re-appended exactly once.
        #expect(merged.filter { $0.name == "Minify JSON" }.count == 1)
        // Only one action added overall.
        #expect(merged.count == existing.count + 1)
        // The newly appended default lands at the end (append-only).
        #expect(merged.last?.name == "Minify JSON")
        // User actions are untouched and keep their original positions.
        #expect(merged.first?.id == userA.id)
        #expect(merged.first?.name == "My custom A")
        let bIndex = merged.firstIndex { $0.id == userB.id }
        #expect(bIndex != nil)
        #expect(merged[bIndex!].name == "My custom B")
    }

    @Test func appendingDoesNotDuplicateUserActionSharingABuiltinName() {
        // A user action that happens to share a built-in's name blocks the
        // built-in from being appended (match is by name).
        let shadow = Action(name: "Minify JSON", icon: "star", steps: [Step(type: .script, script: "cat")])
        let merged = Action.appendingMissingBuiltins(into: [shadow])
        #expect(merged.filter { $0.name == "Minify JSON" }.count == 1)
        #expect(merged.first?.id == shadow.id)
        // Every other default still got appended.
        #expect(merged.count == Action.defaults().count)
    }
}
