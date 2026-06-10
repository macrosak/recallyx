import Foundation
import Testing
@testable import Recallyx

@Suite("ScriptRunner")
struct ScriptRunnerTests {
    /// Both pipe directions carry > 64K (one pipe-buffer) — a synchronous
    /// stdin write would deadlock against the unread stdout here until the
    /// watchdog fired.
    @Test func roundTripsInputLargerThanPipeBuffer() async throws {
        let input = String(repeating: "x", count: 200_000)
        let out = try await ScriptRunner.run(script: "cat", input: input)
        #expect(out == input)
    }

    /// A script that exits without reading stdin closes the pipe under the
    /// writer — must surface as EPIPE on the write, not SIGPIPE-kill the app.
    @Test func scriptThatIgnoresStdin_doesNotCrashOrStall() async throws {
        let input = String(repeating: "y", count: 200_000)
        let out = try await ScriptRunner.run(script: "echo done", input: input)
        #expect(out == "done")
    }

    @Test func nonZeroExit_throws() async {
        await #expect(throws: ScriptError.self) {
            _ = try await ScriptRunner.run(script: "echo nope >&2; exit 3", input: "")
        }
    }
}
