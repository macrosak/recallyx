# CLAUDE.md

For AI agents. Keep terse and scannable; link to README/source for detail.

## What this is
macOS menu-bar **clipboard history manager**. Watches the system clipboard, stores text + image history to disk, and a **⌘⇧V** floating panel (fuzzy search · list · detail) finds and pastes past clips. Phase 2 adds an **actions** layer: per-item pipelines of typed steps (`script` / `ai`) that transform the text and paste the result, plus **⌃⇧V** to transform the current selection in place.

Successor to **AI Replace** (`../ai-replace`). Bundle ID `io.github.macrosak.recallyx`. Built in commit-sized slices; see [design doc](docs.local/2026-06-04-recallyx-design.md).

- **⌘⇧V** → history panel: search clipboard, ↵ pastes the selected clip, ⇥ opens its action menu.
- **⌃⇧V** (Phase 2) → grab the current selection, push to history, open the panel on its action menu (the AI-Replace replacement).

## Build
- `./scripts/bundle.sh` → `Recallyx.app` (uses `Recallyx Dev` identity if present, else ad-hoc).
- `./scripts/install.sh` — killalls running, copies to `~/Applications`, launches.
- macOS 13+, Command Line Tools only (no Xcode). SPM, zero deps.
- `swift build` / `swift test` for the library + unit tests.

## Source layout
- `RecallyxApp.swift` — `@main` + `NSApplicationDelegate`. **All launch wiring lives in `applicationDidFinishLaunching`** (see Lessons — MenuBarExtra content is lazy).
- `AppState.swift` — `@MainActor ObservableObject` (status / lastError / historyCount).
- `StatusItemView.swift` — menu-bar dropdown.
- `Log.swift` — `os.Logger` (subsystem `io.github.macrosak.recallyx`) mirrored to stderr.
- `HistoryItem.swift` — `HistoryItem` (stored record), `CapturedClip` (raw capture from the watcher), `ContentHash` (SHA-256 dedupe keys via CryptoKit).
- `HistoryStore.swift` — `@MainActor ObservableObject` owning the on-disk history. `add` (dedupe-bump or insert) / `bump` / `delete` / `clear`. Cap eviction, atomic save (temp + `replaceItemAt`), debounced writes, reseed-on-corrupt, orphan reconciliation.

(Components still to come per commit: `ClipboardWatcher`, `AppIconProvider`, history panel, action menu, settings, `ActionRunner`/`Paster`, `ScriptRunner`/`OpenAIClient`.)

## Storage
`~/Library/Application Support/Recallyx/` — `history.json` (the index) + `images/<uuid>.png` (image payloads). Only small settings/actions go in UserDefaults; history is on disk because images make it megabytes-large. Ordering is `max(createdAt, lastUsedAt)` descending (a bump refreshes `lastUsedAt`).

## Logs
```
log stream --predicate 'subsystem == "io.github.macrosak.recallyx"' --level debug
```
Or run the binary directly: `./Recallyx.app/Contents/MacOS/Recallyx` (stderr mirror).

## Lessons carried over from AI Replace — don't relitigate
- **MenuBarExtra content is lazy.** Use `NSApplicationDelegate.applicationDidFinishLaunching` for launch wiring, never the content's `.task`.
- **Ad-hoc signing invalidates TCC every rebuild.** Stable identity via `scripts/create-signing-identity.sh` → grant survives rebuilds.
- **TCC stale entries survive System Settings toggles.** Fix: `tccutil reset Accessibility io.github.macrosak.recallyx`.
- **`open` doesn't relaunch a running app** — it foregrounds. `install.sh` does `killall` first.
- **Carbon `RegisterEventHotKey`** returns `eventHotKeyExistsErr=-9878` if the combo is taken globally.
- **Chromium/Electron silently drop `kAXSelectedText` writes** — re-read to verify, fall back to synthesized ⌘V at `.cghidEventTap`. (Phase 2 paste path.)
- **OpenSSL 3 PBES2 p12 is rejected by macOS Security** — `create-signing-identity.sh` uses `/usr/bin/openssl` (LibreSSL).

## Don't
- Add Xcode-only deps (no `#Preview` macros — Command Line Tools only).
- Move launch wiring onto MenuBarExtra content's `.task`.
- Run `tccutil reset` or `security add-trusted-cert` without explicit user confirmation.

## Maintaining this file
Update when behavior changes; delete stale entries. Extend it in each commit that changes the lifecycle, adds a screen, or teaches a new lesson.
