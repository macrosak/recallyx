import Foundation

public enum StepType: String, Codable, Equatable {
    case script
    case ai
}

/// What happens to an action's result once the pipeline finishes.
///   • `paste`  — set the clipboard and synth-⌘V into the source app (default).
///   • `copy`   — set the clipboard only; don't paste (keeps the current
///                selection / target field intact).
///   • `show`   — display the result in the panel (selectable + a Copy button);
///                don't touch the clipboard until the user copies.
///   • `append` — add the result silently to the top of history; no clipboard
///                change, no paste.
public enum OutputMode: String, Codable, Equatable, CaseIterable {
    case paste
    case copy
    case show
    case append

    public var label: String {
        switch self {
        case .paste: return "Paste"
        case .copy: return "Copy"
        case .show: return "Show"
        case .append: return "Append"
        }
    }
}

/// One stage of an action pipeline. A `.script` step pipes text through a bash
/// filter; an `.ai` step runs it through OpenAI with `prompt` (and an optional
/// per-step model override). Generalizes AI Replace's fixed pre/AI/post stages.
public struct Step: Codable, Identifiable, Equatable {
    public var id: UUID
    public var type: StepType
    public var enabled: Bool
    public var script: String
    public var prompt: String
    public var model: String?

    public init(
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
public struct Action: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    /// SF Symbol name.
    public var icon: String
    public var steps: [Step]
    /// What to do with the result once the pipeline finishes. Defaults to
    /// `.paste` (today's behavior); a decode of a pre-feature action (no
    /// `output` key) also lands on `.paste`.
    public var output: OutputMode

    public init(id: UUID = UUID(), name: String, icon: String, steps: [Step], output: OutputMode = .paste) {
        self.id = id
        self.name = name
        self.icon = icon
        self.steps = steps
        self.output = output
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, icon, steps, output
    }

    // Custom decode so a saved action from before this feature (no `output`
    // key) decodes cleanly to `.paste` — a synthesized decoder would reject the
    // missing key. An unknown/future value also falls back to `.paste`. `encode`
    // stays synthesized (all fields are non-optional + Codable).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        icon = try c.decode(String.self, forKey: .icon)
        steps = try c.decode([Step].self, forKey: .steps)
        output = (try? c.decodeIfPresent(OutputMode.self, forKey: .output)) ?? .paste
    }

    /// A SCRIPT/AI tag for the action menu — AI if any AI step is present.
    public var kindTag: String {
        steps.contains { $0.type == .ai } ? "AI" : "SCRIPT"
    }

    public static func defaults() -> [Action] {
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
            // Dev-oriented, zero-config, offline script transforms (no API key).
            // All use system python3 (the proven runtime already used by
            // "Pretty-print JSON"): text in on stdin, result out on stdout.
            Action(name: "URL decode", icon: "link", steps: [
                Step(type: .script, script: "python3 -c 'import sys,urllib.parse;sys.stdout.write(urllib.parse.unquote(sys.stdin.read()))'"),
            ]),
            Action(name: "URL encode", icon: "link.badge.plus", steps: [
                Step(type: .script, script: "python3 -c 'import sys,urllib.parse;sys.stdout.write(urllib.parse.quote(sys.stdin.read()))'"),
            ]),
            Action(name: "Base64 decode", icon: "arrow.down.doc", steps: [
                Step(type: .script, script: "python3 -c 'import sys,base64;d=sys.stdin.read().strip();d+=\"=\"*(-len(d)%4);sys.stdout.buffer.write(base64.b64decode(d))'"),
            ]),
            Action(name: "Base64 encode", icon: "arrow.up.doc", steps: [
                Step(type: .script, script: "python3 -c 'import sys,base64;sys.stdout.write(base64.b64encode(sys.stdin.buffer.read()).decode())'"),
            ]),
            Action(name: "Decode JWT", icon: "key", steps: [
                Step(type: .script, script: """
                python3 -c '
                import sys,base64,json
                p=sys.stdin.read().strip().split(".")
                def d(s):
                    s+="="*(-len(s)%4)
                    return json.loads(base64.urlsafe_b64decode(s))
                print(json.dumps({"header":d(p[0]),"payload":d(p[1])},indent=2))'
                """),
            ]),
            Action(name: "Minify JSON", icon: "arrow.down.right.and.arrow.up.left", steps: [
                Step(type: .script, script: "python3 -c 'import sys,json;json.dump(json.load(sys.stdin),sys.stdout,separators=(\",\",\":\"))'"),
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

    /// Appends any `defaults()` action whose `name` isn't already present in
    /// `existing`, minting a fresh UUID for each appended copy. Append-only,
    /// idempotent, matched by name, preserving `existing`'s order (missing
    /// built-ins are appended in `defaults()` order).
    ///
    /// `defaults()` mints random UUIDs each call, so name is the only stable
    /// identity to diff on. This is how existing installs (which already have a
    /// saved `actions` array, so the decode-time `defaults()` fallback never
    /// fires) pick up newly shipped built-ins, and it doubles as "recover a
    /// default I deleted by accident" — without resurrecting one twice.
    public static func appendingMissingBuiltins(into existing: [Action]) -> [Action] {
        let existingNames = Set(existing.map(\.name))
        let missing = defaults().filter { !existingNames.contains($0.name) }
        return existing + missing.map {
            Action(name: $0.name, icon: $0.icon, steps: $0.steps, output: $0.output)
        }
    }
}

/// What `AppDelegate.runAction` should do with an action's result, decided from
/// the action's `output` mode. An empty / whitespace-only result skips
/// regardless of mode (pasting/copying "" would clobber the user's selection or
/// clipboard). Pure + testable — the delegate switches on the outcome and does
/// the AppKit side-effects (paste / clipboard / panel / store.add).
public enum ActionOutcome: Equatable {
    case skipEmpty
    case paste(String)
    case copy(String)
    case show(String)
    case append(String)

    public static func plan(output: OutputMode, result: String) -> ActionOutcome {
        guard !ActionRunner.isEmptyResult(result) else { return .skipEmpty }
        switch output {
        case .paste: return .paste(result)
        case .copy: return .copy(result)
        case .show: return .show(result)
        case .append: return .append(result)
        }
    }
}
