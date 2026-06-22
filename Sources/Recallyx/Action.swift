import Foundation

enum StepType: String, Codable, Equatable {
    case script
    case ai
}

/// One stage of an action pipeline. A `.script` step pipes text through a bash
/// filter; an `.ai` step runs it through OpenAI with `prompt` (and an optional
/// per-step model override). Generalizes AI Replace's fixed pre/AI/post stages.
struct Step: Codable, Identifiable, Equatable {
    var id: UUID
    var type: StepType
    var enabled: Bool
    var script: String
    var prompt: String
    var model: String?

    init(
        id: UUID = UUID(),
        type: StepType,
        enabled: Bool = true,
        script: String = "",
        prompt: String = "",
        model: String? = nil
    ) {
        self.id = id
        self.type = type
        self.enabled = enabled
        self.script = script
        self.prompt = prompt
        self.model = model
    }
}

/// A named, reorderable pipeline of steps — the successor to AI Replace's
/// `Preset`. Runs against a clip's text; the result is pasted at the cursor.
struct Action: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    /// SF Symbol name.
    var icon: String
    var steps: [Step]

    init(id: UUID = UUID(), name: String, icon: String, steps: [Step]) {
        self.id = id
        self.name = name
        self.icon = icon
        self.steps = steps
    }

    /// A SCRIPT/AI tag for the action menu — AI if any AI step is present.
    var kindTag: String {
        steps.contains { $0.type == .ai } ? "AI" : "SCRIPT"
    }

    static func defaults() -> [Action] {
        [
            Action(name: "Fix grammar (EN)", icon: "textformat.abc", steps: [
                Step(type: .ai, prompt: "Fix grammar and obvious typos in the following English text. Do not change anything else; return only the corrected text:\n\n{{TEXT}}"),
            ]),
            Action(name: "Make concise", icon: "wand.and.stars", steps: [
                Step(type: .ai, prompt: "Rewrite the following text to be as clear and concise as possible without losing meaning. Return only the rewritten text:\n\n{{TEXT}}"),
            ]),
            Action(name: "Summarize", icon: "text.alignleft", steps: [
                Step(type: .ai, prompt: "Summarize the following text in a few short bullet points. Return only the summary:\n\n{{TEXT}}"),
            ]),
            Action(name: "Translate to English", icon: "globe", steps: [
                Step(type: .ai, prompt: "Translate the following text to English. If it is already English, return it unchanged. Return only the translation:\n\n{{TEXT}}"),
            ]),
            Action(name: "Remove extra whitespace", icon: "scroll", steps: [
                Step(type: .script, script: "sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'"),
            ]),
            Action(name: "Pretty-print JSON", icon: "curlybraces", steps: [
                Step(type: .script, script: "python3 -m json.tool"),
            ]),
            Action(name: "Slugify", icon: "tag", steps: [
                Step(type: .script, script: "tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed -E 's/^-+|-+$//g'"),
            ]),
            Action(name: "Extract URLs", icon: "globe.americas", steps: [
                Step(type: .script, script: "grep -oE 'https?://[^[:space:]]+' || true"),
            ]),
            // Image-friendly AI actions: run on image clips (first step AI →
            // receives the image), and harmlessly on text clips too.
            Action(name: "Extract text", icon: "text.viewfinder", steps: [
                Step(type: .ai, prompt: "Extract all text from this image, verbatim. Return only the text, no commentary."),
            ]),
            Action(name: "Describe image", icon: "eye", steps: [
                Step(type: .ai, prompt: "Describe this image concisely. Return only the description."),
            ]),
        ]
    }
}
