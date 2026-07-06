import Foundation

/// Run-time input placeholders in an action's step bodies. A step's `script` or
/// `prompt` can contain `{{INPUT}}` or `{{INPUT:Label}}`; running the action
/// pauses to ask the user for each distinct label, then substitutes the entered
/// value everywhere that placeholder appears.
///
/// Pure + AppKit-free so it lives in the shared core and is unit-tested. The
/// substitution happens **before** `{{TEXT}}` handling (`applyPromptTemplate`):
/// `apply(values:to:)` returns a transient `Action` with INPUT tokens replaced,
/// leaving `{{TEXT}}` intact for the normal input-threading in `ActionRunner`.
public enum ActionInputs {
    /// A distinct value the user is asked for before the action runs. Labels are
    /// deduped across steps — the same label asked once, substituted everywhere.
    public struct Placeholder: Equatable {
        /// Human label shown in the prompt. `{{INPUT}}` (no label) defaults to
        /// `"Input"`.
        public let label: String
        /// The step index where this label first appears (informational — the
        /// substitution replaces the token wherever it occurs, in any step).
        public let firstStepIndex: Int

        public init(label: String, firstStepIndex: Int) {
            self.label = label
            self.firstStepIndex = firstStepIndex
        }
    }

    /// Default label for a bare `{{INPUT}}` (no `:Label`).
    public static let defaultLabel = "Input"

    /// Matches `{{INPUT}}` or `{{INPUT:Label}}`. The label group `[^}]*` allows
    /// colons (`{{INPUT:Ratio a:b}}` → "Ratio a:b") but stops at the closing `}`.
    private static let pattern = "\\{\\{INPUT(?::([^}]*))?\\}\\}"
    private static let regex = try! NSRegularExpression(pattern: pattern)

    /// The distinct placeholders across all of `action`'s steps, in first-
    /// appearance order (step order, then position within the step). Identical
    /// labels collapse to one entry (one ask, substituted everywhere). An empty
    /// or whitespace label — and a bare `{{INPUT}}` — resolves to `"Input"`.
    public static func placeholders(in action: Action) -> [Placeholder] {
        var result: [Placeholder] = []
        var seen = Set<String>()
        for (stepIndex, step) in action.steps.enumerated() {
            for body in [step.prompt, step.script] {
                for label in labels(in: body) {
                    guard !seen.contains(label) else { continue }
                    seen.insert(label)
                    result.append(Placeholder(label: label, firstStepIndex: stepIndex))
                }
            }
        }
        return result
    }

    /// The resolved labels (in order) for every INPUT token in one body string.
    private static func labels(in body: String) -> [String] {
        let ns = body as NSString
        let matches = regex.matches(in: body, range: NSRange(location: 0, length: ns.length))
        return matches.map { m in
            let labelRange = m.range(at: 1)
            guard labelRange.location != NSNotFound else { return defaultLabel }
            let raw = ns.substring(with: labelRange).trimmingCharacters(in: .whitespaces)
            return raw.isEmpty ? defaultLabel : raw
        }
    }

    /// Returns a transient copy of `action` with every INPUT token replaced by
    /// the user's value for that token's label. A token whose label has no entry
    /// in `values` is left untouched (defensive — the caller collects all
    /// placeholders first). `{{TEXT}}` is never touched here.
    public static func apply(values: [String: String], to action: Action) -> Action {
        var copy = action
        copy.steps = action.steps.map { step in
            var s = step
            s.prompt = substitute(in: step.prompt, values: values)
            s.script = substitute(in: step.script, values: values)
            return s
        }
        return copy
    }

    /// Replace every INPUT token in `body` with its label's value from `values`.
    private static func substitute(in body: String, values: [String: String]) -> String {
        guard body.contains("{{INPUT") else { return body }
        let ns = body as NSString
        let matches = regex.matches(in: body, range: NSRange(location: 0, length: ns.length))
        // Replace right-to-left so earlier ranges stay valid as we mutate.
        var out = body
        for m in matches.reversed() {
            let labelRange = m.range(at: 1)
            let label: String
            if labelRange.location != NSNotFound {
                let raw = ns.substring(with: labelRange).trimmingCharacters(in: .whitespaces)
                label = raw.isEmpty ? defaultLabel : raw
            } else {
                label = defaultLabel
            }
            guard let value = values[label] else { continue }
            let full = m.range(at: 0)
            out = (out as NSString).replacingCharacters(in: full, with: value)
        }
        return out
    }
}
