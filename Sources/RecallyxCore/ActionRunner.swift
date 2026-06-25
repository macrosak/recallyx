import Foundation

public enum ActionError: LocalizedError {
    case imageNotSupported
    case scriptFirstOnImage
    case missingApiKey(AIProvider)
    /// A `custom:<id>:<model>` step referenced a provider that's no longer in the
    /// settings list (removed/disabled), so the facade can't resolve its endpoint.
    case customEndpointUnavailable

    public var errorDescription: String? {
        switch self {
        case .imageNotSupported: return "Image actions need an OpenAI or Claude model"
        case .scriptFirstOnImage: return "The first step must be AI to run on an image"
        case .missingApiKey(let provider): return "Set your \(provider.displayName) API key in Settings"
        case .customEndpointUnavailable: return "That custom provider is no longer configured — add it in Settings"
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
public final class ActionRunner {
    private let runScript: (_ script: String, _ input: String) async throws -> String
    private let runAI: (_ prompt: String, _ model: String?, _ input: String, _ imageData: Data?) async throws -> String

    public init(
        defaultModel: @escaping () -> String,
        ollamaBaseURL: @escaping () -> String = { recallyxDefaultOllamaBaseURL },
        customEndpoint: @escaping (_ providerID: String) -> AIClient.CustomEndpoint? = { _ in nil },
        runScript: ((String, String) async throws -> String)? = nil,
        runAI: ((String, String?, String, Data?) async throws -> String)? = nil
    ) {
        self.runScript = runScript ?? { try await ScriptRunner.run(script: $0, input: $1) }
        let aiClient = AIClient(ollamaBaseURL: ollamaBaseURL, customEndpoint: customEndpoint)
        self.runAI = runAI ?? { prompt, model, input, imageData in
            // Route by model id: `ollama:*` → local Ollama, `claude*` →
            // Anthropic, else OpenAI. The facade reads the matching provider's
            // keychain key (cloud only); local needs none. `imageData` (non-nil
            // for image clips) runs a vision request — non-vision providers throw.
            try await aiClient.complete(prompt: prompt, model: model ?? defaultModel(), input: input, imageData: imageData)
        }
    }

    /// True when a run produced nothing worth pasting (empty / whitespace-only).
    /// Pasting such a result would set the clipboard to "" and synth-⌘V over the
    /// user's current selection, silently wiping it — callers use this to skip
    /// the paste and surface a no-op instead. Pure + testable.
    public static func isEmptyResult(_ result: String) -> Bool {
        result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Run `action` over `text` and return the transformed result. Disabled
    /// steps are skipped; an empty pipeline returns the text unchanged.
    public func run(_ action: Action, on text: String) async throws -> String {
        Log.info("action run name=\(action.name) steps=\(action.steps.count) inputLen=\(text.count)")
        return try await thread(action.steps[...], current: text)
    }

    /// Run `action` over an image clip's PNG bytes and return text. The first
    /// enabled step must be `.ai` (it receives the image → text); any later
    /// enabled steps thread through the shared text loop, exactly as
    /// `run(_:on:)` does. A `.script` first enabled step throws (bash can't take
    /// an image); an empty pipeline returns "".
    public func run(_ action: Action, onImageData imageData: Data) async throws -> String {
        Log.info("action run (image) name=\(action.name) steps=\(action.steps.count) imageBytes=\(imageData.count)")
        let steps = action.steps
        guard let firstIdx = steps.firstIndex(where: { $0.enabled && !($0.type == .script && $0.script.isEmpty) && !($0.type == .ai && $0.prompt.isEmpty) }) else {
            return ""
        }
        let first = steps[firstIdx]
        guard first.type == .ai else { throw ActionError.scriptFirstOnImage }

        Log.info("action step \(firstIdx) ai (image) start model=\(first.model ?? "default")")
        var current = try await runAI(first.prompt, first.model, "", imageData)
        Log.info("action step \(firstIdx) ai (image) ok len=\(current.count)")

        current = try await thread(steps[(firstIdx + 1)...], current: current)
        return current
    }

    /// Shared text-threading loop for both entry points. `.script` steps go to
    /// `ScriptRunner`, `.ai` steps to the AI client; disabled / empty steps are
    /// skipped; a throwing step aborts before anything later runs.
    private func thread(_ steps: ArraySlice<Step>, current input: String) async throws -> String {
        var current = input
        for (idx, step) in zip(steps.indices, steps) where step.enabled {
            switch step.type {
            case .script:
                guard !step.script.isEmpty else { continue }
                Log.debug("action step \(idx) script start len=\(current.count)")
                current = try await runScript(step.script, current)
                Log.debug("action step \(idx) script ok len=\(current.count)")

            case .ai:
                guard !step.prompt.isEmpty else { continue }
                Log.info("action step \(idx) ai start model=\(step.model ?? "default") len=\(current.count)")
                current = try await runAI(step.prompt, step.model, current, nil)
                Log.info("action step \(idx) ai ok len=\(current.count)")
            }
        }
        return current
    }
}
