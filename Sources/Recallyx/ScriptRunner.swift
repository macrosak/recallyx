import Foundation

enum ScriptError: LocalizedError {
    case launchFailed(String)
    case nonZeroExit(code: Int32, stderr: String)
    case timedOut(seconds: Int)
    case badOutput

    var errorDescription: String? {
        switch self {
        case .launchFailed(let m):
            return "Script failed to launch: \(m)"
        case .nonZeroExit(let code, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "Script exited with code \(code)" : "Script error: \(detail)"
        case .timedOut(let s):
            return "Script timed out after \(s)s"
        case .badOutput:
            return "Script output was not valid UTF-8"
        }
    }
}

/// Runs a user-supplied shell snippet as a text filter: text in on stdin,
/// replacement out on stdout. Copied from AI Replace.
///
/// We invoke the user's login shell (`$SHELL -l`) so it sources their profile
/// (PATH, etc. — a GUI-launched app otherwise gets a bare env), then `exec bash`
/// runs the snippet so the user always writes bash regardless of `$SHELL`. The
/// body is passed via an env var to sidestep shell-quoting. Trailing newlines are
/// stripped like `$(...)`.
struct ScriptRunner {
    static let timeoutSeconds = 30
    private static let envScriptKey = "RECALLYX_SCRIPT"

    static func run(script: String, input: String) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try runBlocking(script: script, input: input)
        }.value
    }

    private static func runBlocking(script: String, input: String) throws -> String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "exec bash -c \"$\(envScriptKey)\""]

        var env = ProcessInfo.processInfo.environment
        env[envScriptKey] = script
        process.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw ScriptError.launchFailed(error.localizedDescription)
        }

        // Watchdog: terminate a hung script after the timeout. The pipe closes
        // on termination, unblocking the reads below.
        let timeoutItem = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(
            deadline: .now() + .seconds(timeoutSeconds),
            execute: timeoutItem
        )

        let inData = input.data(using: .utf8) ?? Data()
        stdinPipe.fileHandleForWriting.write(inData)
        try? stdinPipe.fileHandleForWriting.close()

        // Drain stderr on a background thread so a large stderr can't deadlock
        // against stdout filling its 64K pipe buffer.
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()

        process.waitUntilExit()
        timeoutItem.cancel()

        let timedOut = process.terminationReason == .uncaughtSignal
            && process.terminationStatus == SIGTERM
        if timedOut {
            throw ScriptError.timedOut(seconds: timeoutSeconds)
        }

        guard process.terminationStatus == 0 else {
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            throw ScriptError.nonZeroExit(code: process.terminationStatus, stderr: stderr)
        }

        guard let out = String(data: outData, encoding: .utf8) else {
            throw ScriptError.badOutput
        }
        return stripTrailingNewlines(out)
    }

    private static func stripTrailingNewlines(_ s: String) -> String {
        var end = s.endIndex
        while end > s.startIndex {
            let prev = s.index(before: end)
            if s[prev] == "\n" { end = prev } else { break }
        }
        return String(s[s.startIndex..<end])
    }
}
