import CoreData
import Foundation
import Testing
@testable import RecallyxCore

// MARK: - Argument parsing

@Suite("CLICommand.parse")
struct CLICommandParseTests {
    private func ok(_ args: [String]) -> CLICommand? {
        if case .success(let c) = CLICommand.parse(args) { return c }
        return nil
    }
    private func err(_ args: [String]) -> CLIParseError? {
        if case .failure(let e) = CLICommand.parse(args) { return e }
        return nil
    }

    @Test func noArgsIsHelp() {
        #expect(ok([]) == .help)
    }

    @Test func helpFlags() {
        #expect(ok(["--help"]) == .help)
        #expect(ok(["-h"]) == .help)
        #expect(ok(["help"]) == .help)
    }

    @Test func searchWithDefaultLimit() {
        #expect(ok(["search", "foo"]) == .search(query: "foo", limit: 10))
    }

    @Test func searchJoinsMultiWordQuery() {
        #expect(ok(["search", "api", "key"]) == .search(query: "api key", limit: 10))
    }

    @Test func searchWithLimitFlag() {
        #expect(ok(["search", "foo", "-n", "3"]) == .search(query: "foo", limit: 3))
        #expect(ok(["search", "-n", "5", "foo"]) == .search(query: "foo", limit: 5))
        #expect(ok(["search", "foo", "--limit", "2"]) == .search(query: "foo", limit: 2))
    }

    @Test func searchMissingQueryFails() {
        #expect(err(["search"]) == .missingQuery)
        #expect(err(["search", "-n", "5"]) == .missingQuery)
    }

    @Test func searchBadNumberFails() {
        #expect(err(["search", "foo", "-n", "abc"]) == .invalidNumber("abc"))
    }

    @Test func searchMissingLimitValueFails() {
        #expect(err(["search", "foo", "-n"]) == .missingValue(flag: "-n"))
    }

    @Test func recentDefaultAndLimit() {
        #expect(ok(["recent"]) == .recent(limit: 10))
        #expect(ok(["recent", "-n", "4"]) == .recent(limit: 4))
    }

    @Test func recentRejectsStrayArg() {
        #expect(err(["recent", "foo"]) == .unexpectedArgument("foo"))
    }

    @Test func getDefaultsToIndexOne() {
        #expect(ok(["get"]) == .get(.index(1)))
    }

    @Test func getWithIndex() {
        #expect(ok(["get", "3"]) == .get(.index(3)))
    }

    @Test func getWithID() {
        let uuid = UUID()
        #expect(ok(["get", "--id", uuid.uuidString]) == .get(.id(uuid)))
    }

    @Test func getBadIDFails() {
        #expect(err(["get", "--id", "not-a-uuid"]) == .invalidUUID("not-a-uuid"))
    }

    @Test func getNonNumericFails() {
        #expect(err(["get", "xyz"]) == .invalidNumber("xyz"))
    }

    @Test func runNeedsName() {
        #expect(err(["run"]) == .missingActionName)
        #expect(ok(["run", "Fix", "grammar"]) == .run(actionName: "Fix grammar"))
    }

    @Test func listActionsAndCopy() {
        #expect(ok(["list-actions"]) == .listActions)
        #expect(ok(["copy"]) == .copy)
        #expect(err(["copy", "extra"]) == .unexpectedArgument("extra"))
    }

    @Test func unknownCommand() {
        #expect(err(["frobnicate"]) == .unknownCommand("frobnicate"))
    }

    @Test func negativeLimitClampsToZero() {
        #expect(ok(["recent", "-n", "-5"]) == .recent(limit: 0))
    }
}

// MARK: - Output formatting

@Suite("CLIFormat")
struct CLIFormatTests {
    @Test func snippetCollapsesWhitespaceAndTrims() {
        #expect(CLIFormat.snippet("  hello\n\tworld  ") == "hello world")
    }

    @Test func snippetTruncatesWithEllipsis() {
        let long = String(repeating: "a", count: 200)
        let s = CLIFormat.snippet(long, width: 10)
        #expect(s.count == 10)
        #expect(s.hasSuffix("…"))
    }

    @Test func snippetShortPassesThrough() {
        #expect(CLIFormat.snippet("short", width: 100) == "short")
    }

    @Test func rowContainsIndexKindTimeAppAndBody() {
        let now = Date()
        let item = HistoryItem(
            id: UUID(), kind: .text, text: "the body text", preview: "the body text",
            byteSize: 13, sourceAppName: "Safari",
            createdAt: now.addingTimeInterval(-120), lastUsedAt: now.addingTimeInterval(-120),
            contentHash: "h"
        )
        let row = CLIFormat.row(index: 1, item: item, now: now)
        #expect(row.contains("1"))
        #expect(row.contains("text"))
        #expect(row.contains("min ago"))
        #expect(row.contains("Safari"))
        #expect(row.contains("the body text"))
    }

    @Test func bodyTextPrefersOCRThenPreviewForImages() {
        let base = Date()
        let imageWithOCR = HistoryItem(
            id: UUID(), kind: .image, preview: "Image · 100 × 100", byteSize: 1,
            createdAt: base, lastUsedAt: base, contentHash: "h", ocrText: "scanned words"
        )
        #expect(CLIFormat.bodyText(for: imageWithOCR) == "scanned words")

        let imageNoOCR = HistoryItem(
            id: UUID(), kind: .image, preview: "Image · 100 × 100", byteSize: 1,
            createdAt: base, lastUsedAt: base, contentHash: "h2"
        )
        #expect(CLIFormat.bodyText(for: imageNoOCR) == "Image · 100 × 100")
    }

    @Test func actionLinePadsName() {
        let line = CLIFormat.actionLine(name: "Foo", kindTag: "AI", width: 6)
        #expect(line == "Foo     AI")
    }
}

// MARK: - Settings decode

@Suite("CLISettings")
struct CLISettingsTests {
    @Test func decodesActionsFromBlob() throws {
        // A minimal settings blob carrying just an `actions` array.
        let action = Action(name: "My Action", icon: "x", steps: [Step(type: .script, script: "cat")])
        let json = try JSONEncoder().encode(["actions": [action]])
        let settings = CLISettings.decode(from: json)
        #expect(settings.actions.map(\.name) == ["My Action"])
    }

    @Test func missingActionsFallsBackToDefaults() {
        let settings = CLISettings.decode(from: Data("{}".utf8))
        #expect(!settings.actions.isEmpty)
        #expect(settings.actions.contains { $0.name == "Pretty-print JSON" })
    }

    @Test func garbageBlobYieldsDefaults() {
        let settings = CLISettings.decode(from: Data("not json".utf8))
        #expect(!settings.actions.isEmpty)
    }

    @Test func actionLookupIsCaseInsensitive() {
        let settings = CLISettings(actions: [
            Action(name: "Pretty-print JSON", icon: "x", steps: []),
        ])
        #expect(settings.action(named: "pretty-print json") != nil)
        #expect(settings.action(named: "nope") == nil)
    }

    @Test func customEndpointResolvesEnabledProviderOnly() {
        let id = UUID()
        let enabled = ProviderConfig(
            id: id, type: .openAICompatible, enabled: true,
            baseURL: "https://api.example.com/v1", keychainAccount: "custom-x"
        )
        let disabled = ProviderConfig(
            id: UUID(), type: .openAICompatible, enabled: false,
            baseURL: "https://off.example.com/v1"
        )
        let settings = CLISettings(providers: [enabled, disabled])
        let resolved = settings.customEndpoint(for: id.uuidString)
        #expect(resolved?.baseURL == "https://api.example.com/v1")
        #expect(resolved?.keychainAccount == "custom-x")
        #expect(settings.customEndpoint(for: disabled.id.uuidString) == nil)
        #expect(settings.customEndpoint(for: UUID().uuidString) == nil)
    }
}

// MARK: - Read-only store description

@Suite("PersistenceController read-only")
struct PersistenceReadOnlyDescriptionTests {
    @Test func readOnlyDescriptionSetsFlagAndDropsSyncAndHistory() {
        let url = URL(fileURLWithPath: "/tmp/x.sqlite")
        let ro = PersistenceController.makeStoreDescription(storeURL: url, readOnly: true)
        #expect(ro.isReadOnly == true)
        // A read-only reader never mirrors (attaching CloudKit options to an
        // unentitled process crashes) — verify options are dropped.
        #expect(ro.cloudKitContainerOptions == nil)

        let rw = PersistenceController.makeStoreDescription(storeURL: url, readOnly: false)
        #expect(rw.isReadOnly == false)
    }
}

// MARK: - HistoryReader round-trip (read-only, real file store)

@MainActor
@Suite("HistoryReader")
struct HistoryReaderTests {
    private func tempBase() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("recallyx-cli-tests-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func readsSeededClipsNewestFirst() throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }

        // Seed via the writable store, then flush to disk.
        let store = HistoryStore(baseURL: base, cap: 1000)
        _ = store.add(CapturedClip.forText("first", sourceAppName: "A")!)
        _ = store.add(CapturedClip.forText("second", sourceAppName: "B")!)
        _ = store.add(CapturedClip.forText("third", sourceAppName: "C")!)
        store.flush()

        // Read via the read-only sibling reader.
        let reader = HistoryReader(baseURL: base)
        let items = reader.items()
        #expect(items.count == 3)
        // Newest-first (last added is on top).
        #expect(items.first?.text == "third")
        #expect(items.last?.text == "first")
    }

    @Test func missingStoreReadsEmptyWithoutCreatingFile() {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let reader = HistoryReader(baseURL: base)
        #expect(reader.items().isEmpty)
        // The read-only reader must never create the store file.
        let storeURL = base.appendingPathComponent("Recallyx.sqlite")
        #expect(FileManager.default.fileExists(atPath: storeURL.path) == false)
    }

    @Test func imageURLResolvesForImageClips() throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = HistoryStore(baseURL: base, cap: 1000)
        let png = Data([0x89, 0x50, 0x4E, 0x47])   // not a real PNG; add() only writes bytes
        let captured = CapturedClip(
            kind: .image, imageData: png, preview: "Image · 1 × 1", byteSize: png.count,
            contentHash: ContentHash.of(bytes: png), imageDimensions: "1 × 1"
        )
        _ = store.add(captured)
        store.flush()

        let reader = HistoryReader(baseURL: base)
        let items = reader.items()
        #expect(items.count == 1)
        let imgURL = try #require(reader.imageURL(for: items[0]))
        #expect(imgURL.pathExtension == "png")
        #expect(FileManager.default.fileExists(atPath: imgURL.path))
    }
}

// MARK: - `run` pipeline with a script step (hermetic `cat`)

@MainActor
@Suite("CLI run pipeline")
struct CLIRunPipelineTests {
    @Test func scriptActionThreadsStdinThrough() async throws {
        // The exact shape the CLI runs: look up a saved action by name, then run
        // it through a production-style ActionRunner. `cat` echoes stdin, so the
        // output equals the input — a hermetic round-trip.
        let settings = CLISettings(actions: [
            Action(name: "Echo", icon: "x", steps: [Step(type: .script, script: "cat")]),
        ])
        let action = try #require(settings.action(named: "echo"))
        let runner = ActionRunner(
            defaultModel: { settings.defaultModel },
            ollamaBaseURL: { settings.ollamaBaseURL },
            customEndpoint: { settings.customEndpoint(for: $0) }
        )
        let out = try await runner.run(action, on: "hello pipeline")
        #expect(out == "hello pipeline")
    }

    @Test func twoScriptStepsCompose() async throws {
        let settings = CLISettings(actions: [
            Action(name: "Upper", icon: "x", steps: [
                Step(type: .script, script: "tr '[:lower:]' '[:upper:]'"),
                Step(type: .script, script: "cat"),
            ]),
        ])
        let action = try #require(settings.action(named: "Upper"))
        let runner = ActionRunner(defaultModel: { "unused" })
        let out = try await runner.run(action, on: "abc")
        #expect(out == "ABC")
    }
}
