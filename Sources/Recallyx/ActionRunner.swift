import Foundation

enum ActionError: LocalizedError {
    case imageNotSupported
    case missingApiKey(AIProvider)

    var errorDescription: String? {
        switch self {
        case .imageNotSupported: return "Actions run on text only (v1)"
        case .missingApiKey(let provider): return "Set your \(provider.displayName) API key in Settings"
        }
    }
}

/// Threads a clip's text through an action's enabled steps in order — the N-step
/// generalization of AI Replace's `CorrectionController`. `.script` steps go to
/// `ScriptRunner`, `.ai` steps to `OpenAIClient`. A throwing step aborts the run
/// before anything is pasted. Runs both persisted actions and transient ad-hoc
/// actions (Custom… / edit-before-run) — it takes an `Action` value and doesn't
/// care where it came from.
///
/// The script/AI runners are injectable so tests stay hermetic (no subprocess /
/// network); production wires the real `ScriptRunner` + `OpenAIClient`.
@MainActor
final class ActionRunner {
    private let runScript: (_ script: String, _ input: String) async throws -> String
    private let runAI: (_ prompt: String, _ model: String?, _ input: String) async throws -> String

    init(
        defaultModel: @escaping () -> String,
        ollamaBaseURL: @escaping () -> String = { AppSettings.defaultOllamaBaseURL },
        runScript: ((String, String) async throws -> String)? = nil,
        runAI: ((String, String?, String) async throws -> String)? = nil
    ) {
        self.runScript = runScript ?? { try await ScriptRunner.run(script: $0, input: $1) }
        let aiClient = AIClient(ollamaBaseURL: ollamaBaseURL)
        self.runAI = runAI ?? { prompt, model, input in
            // Route by model id: `ollama:*` → local Ollama, `claude*` →
            // Anthropic, else OpenAI. The facade reads the matching provider's
            // keychain key (cloud only); local needs none.
            try await aiClient.complete(prompt: prompt, model: model ?? defaultModel(), input: input)
        }
    }

    /// Run `action` over `text` and return the transformed result. Disabled
    /// steps are skipped; an empty pipeline returns the text unchanged.
    func run(_ action: Action, on text: String) async throws -> String {
        Log.info("action run name=\(action.name) steps=\(action.steps.count) inputLen=\(text.count)")
        var current = text

        for (idx, step) in action.steps.enumerated() where step.enabled {
            switch step.type {
            case .script:
                guard !step.script.isEmpty else { continue }
                Log.debug("action step \(idx) script start len=\(current.count)")
                current = try await runScript(step.script, current)
                Log.debug("action step \(idx) script ok len=\(current.count)")

            case .ai:
                guard !step.prompt.isEmpty else { continue }
                Log.info("action step \(idx) ai start model=\(step.model ?? "default") len=\(current.count)")
                current = try await runAI(step.prompt, step.model, current)
                Log.info("action step \(idx) ai ok len=\(current.count)")
            }
        }

        return current
    }
}
