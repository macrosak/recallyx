import AppKit
import Foundation
import RecallyxCore

// The `recallyx` command-line tool: clipboard history + action pipelines as
// shell filters. It reads the SAME history the Recallyx.app menu-bar app writes,
// but strictly READ-ONLY (a `PersistenceController(readOnly:)` store) so it can
// never mutate or corrupt the live database. `copy` is the one write path and it
// writes only the system pasteboard — the running app's watcher captures it into
// history naturally; the CLI never touches the store on that path.

// MARK: - Clean output

// The shared `Log` mirrors every line to stderr, Core Data logs its own internal
// chatter there too, and `FileLog` persists to the user's diagnostic log. None of
// that belongs in a user-facing CLI. We keep a dup of the REAL stderr for our own
// messages, then blackhole fd 2 so library/framework noise vanishes while the
// CLI's own diagnostics (via `printErr`) and stdout stay clean.
let realStderrFD: Int32 = dup(STDERR_FILENO)

func silenceFrameworkNoise() {
    FileLog.shared.enabled = false   // don't write the app's on-disk diagnostic log
    let devnull = open("/dev/null", O_WRONLY)
    if devnull >= 0 {
        dup2(devnull, STDERR_FILENO)
        close(devnull)
    }
}

// MARK: - Small I/O helpers

func printErr(_ s: String) {
    let data = Data((s + "\n").utf8)
    data.withUnsafeBytes { buf in
        if let base = buf.baseAddress { _ = write(realStderrFD, base, buf.count) }
    }
}

/// Read all of stdin as UTF-8 text.
func readStdin() -> String {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    return String(data: data, encoding: .utf8) ?? ""
}

/// The store directory, honoring `RECALLYX_DATA_DIR` exactly like the app.
func baseURL() -> URL {
    if let dir = ProcessInfo.processInfo.environment["RECALLYX_DATA_DIR"], !dir.isEmpty {
        return URL(fileURLWithPath: dir, isDirectory: true)
    }
    return HistoryReader.defaultBaseURL()
}

/// The persisted app settings (actions/providers) read from the app's
/// UserDefaults domain. A separate binary's `.standard` domain is its OWN, so we
/// address the app's bundle-id suite explicitly. Missing → defaults.
func loadSettings() -> CLISettings {
    let suite = UserDefaults(suiteName: KeychainStore.recallyxService)
    guard let data = suite?.data(forKey: CLISettings.storageKey) else {
        return CLISettings()
    }
    return CLISettings.decode(from: data)
}

// MARK: - Commands

func runList(items: [HistoryItem], limit: Int) {
    if items.isEmpty {
        printErr("No clips in history.")
        return
    }
    let now = Date()
    for (offset, item) in items.prefix(limit).enumerated() {
        print(CLIFormat.row(index: offset + 1, item: item, now: now))
    }
}

func runSearch(query: String, limit: Int) {
    let items = HistoryReader(baseURL: baseURL()).items()
    let ranked = FuzzyMatcher.rank(items, query: query)
    if ranked.isEmpty {
        printErr("No clips match '\(query)'.")
        exit(1)
    }
    runList(items: ranked, limit: limit)
}

func runRecent(limit: Int) {
    let items = HistoryReader(baseURL: baseURL()).items()
    runList(items: items, limit: limit)
}

func runGet(_ target: GetTarget) {
    let reader = HistoryReader(baseURL: baseURL())
    let items = reader.items()
    let item: HistoryItem?
    switch target {
    case .index(let n):
        item = (n >= 1 && n <= items.count) ? items[n - 1] : nil
    case .id(let uuid):
        item = items.first { $0.id == uuid }
    }
    guard let clip = item else {
        printErr("No such clip.")
        exit(1)
    }
    guard clip.kind == .text, let text = clip.text else {
        printErr("Clip is an image — `get` only prints text clips.")
        exit(1)
    }
    // Raw text, no trailing newline decoration beyond the stored content.
    FileHandle.standardOutput.write(Data(text.utf8))
}

func runListActions() {
    let settings = loadSettings()
    if settings.actions.isEmpty {
        printErr("No saved actions.")
        return
    }
    let width = settings.actions.map { $0.name.count }.max() ?? 0
    for action in settings.actions {
        print(CLIFormat.actionLine(name: action.name, kindTag: action.kindTag, width: width))
    }
}

/// `run "<name>"`: thread stdin through the named action's pipeline, print the
/// result. Script steps run fully (macOS). AI steps read the app's Keychain key;
/// if that read fails (a separate-binary ACL denial is likely, or no key set)
/// the runner throws `.missingApiKey` and we print a clear pointer to the app.
@MainActor
func runAction(named name: String) async {
    let settings = loadSettings()
    guard let action = settings.action(named: name) else {
        printErr("No action named '\(name)'. Try `recallyx list-actions`.")
        exit(1)
    }
    let input = readStdin()
    let runner = ActionRunner(
        defaultModel: { settings.defaultModel },
        ollamaBaseURL: { settings.ollamaBaseURL },
        customEndpoint: { settings.customEndpoint(for: $0) }
    )
    do {
        let result = try await runner.run(action, on: input)
        FileHandle.standardOutput.write(Data(result.utf8))
    } catch let error as ActionError {
        switch error {
        case .missingApiKey, .customEndpointUnavailable:
            printErr("AI steps need the Recallyx app's Keychain access — run this action from the app, or re-enter the key in the app's Providers settings.")
        default:
            printErr(error.errorDescription ?? "Action failed.")
        }
        exit(1)
    } catch {
        printErr("Action failed: \(error.localizedDescription)")
        exit(1)
    }
}

func runCopy() {
    let text = readStdin()
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}

// MARK: - Dispatch

silenceFrameworkNoise()

let argv = Array(CommandLine.arguments.dropFirst())
switch CLICommand.parse(argv) {
case .failure(let error):
    printErr(error.message)
    printErr("")
    printErr("Run `recallyx --help` for usage.")
    exit(2)
case .success(let command):
    switch command {
    case .help:
        print(CLICommand.usage)
    case .search(let query, let limit):
        runSearch(query: query, limit: limit)
    case .recent(let limit):
        runRecent(limit: limit)
    case .get(let target):
        runGet(target)
    case .listActions:
        runListActions()
    case .copy:
        runCopy()
    case .run(let name):
        // ActionRunner is @MainActor + async. Top-level `await` runs it to
        // completion (the actor hop is handled by the await) without blocking a
        // thread the actor needs — a semaphore + main-thread wait would deadlock.
        await runAction(named: name)
    }
}
