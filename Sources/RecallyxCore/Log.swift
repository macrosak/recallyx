import Foundation
import os

public enum Log {
    private static let logger = os.Logger(
        subsystem: "io.github.macrosak.recallyx",
        category: "main"
    )

    public static func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
        write("[recallyx] \(message)")
    }

    public static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        write("[recallyx] \(message)")
    }

    public static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        write("[recallyx] ERROR: \(message)")
    }

    /// Truncate long strings for log output. Clipboard contents and OpenAI
    /// responses can be arbitrarily long and noisy; logs only need a peek.
    public static func snippet(_ string: String, max: Int = 120) -> String {
        let normalized = string
            .replacingOccurrences(of: "\n", with: "⏎")
            .replacingOccurrences(of: "\r", with: "")
        if normalized.count <= max { return normalized }
        let end = normalized.index(normalized.startIndex, offsetBy: max)
        return "\(normalized[..<end])… (+\(normalized.count - max) chars)"
    }

    private static func write(_ line: String) {
        FileHandle.standardError.write(Data("\(line)\n".utf8))
        // Persist to a rotating on-disk file too — info-level os_log is not kept
        // on disk, so this is what's available when a user reports a bug. The
        // sink is content-free: it writes exactly these (length/category/count)
        // strings, never clip text.
        FileLog.shared.write(line)
    }
}
