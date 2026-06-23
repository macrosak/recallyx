import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

public enum AppleError: LocalizedError {
    case unavailable(String)
    case unsupportedOS

    public var errorDescription: String? {
        switch self {
        case .unavailable(let why): return "Apple Intelligence unavailable: \(why)"
        case .unsupportedOS: return "Apple Intelligence needs macOS 26 or later."
        }
    }
}

/// On-device Apple Intelligence via the FoundationModels framework (macOS 26+).
/// No API key, no network — runs on the device's built-in model. Models are
/// addressed `apple:<id>` so `AIProvider` routes by prefix; the suffix is
/// ignored (the OS picks the on-device model). Text-only (v1); vision is
/// rejected upstream by `AIProvider.supportsVision == false`.
///
/// Compiles on every SDK: the FoundationModels path is `#if canImport`-guarded
/// and runtime `#available`-gated (the app targets macOS 13+), with a throwing
/// `#else` stub so toolchains without the framework still build.
public struct AppleClient {
    public init() {}
    /// Whether the on-device model can actually run right now: macOS 26+ with
    /// FoundationModels and `SystemLanguageModel.default.availability == .available`
    /// (AI enabled and the model downloaded). `false` everywhere the framework
    /// can't import or the OS is older. Used by the Settings model pickers to
    /// show the Apple group only when the Mac can use it.
    public static var isAvailable: Bool {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { return false }
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
        #else
        return false
        #endif
    }

    /// `model` is the `apple:` model id (suffix ignored — the OS picks the
    /// on-device model).
    public func complete(model: String, promptTemplate: String, text: String) async throws -> String {
        let fullPrompt = applyPromptTemplate(promptTemplate, text: text)
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { throw AppleError.unsupportedOS }
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(let reason):
            // Map the reason to a friendly hint (model not downloaded / AI off / device).
            throw AppleError.unavailable(String(describing: reason))
        @unknown default:
            throw AppleError.unavailable("unknown")
        }
        let session = LanguageModelSession()
        let response = try await session.respond(to: fullPrompt)
        let out = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else { throw AppleError.unavailable("empty response") }
        return out
        #else
        throw AppleError.unsupportedOS
        #endif
    }
}
