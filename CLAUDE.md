# CLAUDE.md

For AI agents. Keep terse and scannable; link to README/source for detail.

## What this is
macOS menu-bar **clipboard history manager**. Watches the system clipboard, stores text + image history to disk, and a **⌘⇧V** floating panel (fuzzy search · list · detail) finds and pastes past clips. Phase 2 adds an **actions** layer: per-item pipelines of typed steps (`script` / `ai`) that transform the text and paste the result, plus **⌃⇧V** to transform the current selection in place.

Successor to **AI Replace** (`../ai-replace`). Bundle ID `io.github.macrosak.recallyx`. Built in commit-sized slices.

> **`docs.local/`** (gitignored) holds implementation plans, design docs, and design references for your own use. **Never reference it anywhere that gets committed or published** — not in commit messages, PR descriptions, README, or any tracked `.md` file. This note is the only place it's named.

- **⌘⇧V** → history panel: search clipboard, ↵ pastes the selected clip, ⇥ opens its action menu.
- **⌃⇧V** (Phase 2) → grab the current selection, push to history, open the panel on its action menu (the AI-Replace replacement).

## Build
- `./scripts/bundle.sh` → `Recallyx.app` (uses `Recallyx Dev` identity if present, else ad-hoc). Honors `RECALLYX_VERSION` (set by CI) — stamps `CFBundleShortVersionString`/`CFBundleVersion`, stripping any `-suffix` to keep the plist numeric.
- `./scripts/make-dmg.sh` → `Recallyx-<version>-arm64.dmg` (built-in `hdiutil`, drag-to-install layout). Needs `Recallyx.app` built first; honors `RECALLYX_VERSION` for the filename.
- `./scripts/install.sh` — killalls running, copies to `~/Applications`, launches.
- macOS 13+, Command Line Tools only (no Xcode). SPM, zero deps.
- `swift build` for the library. **Run tests via `./scripts/test.sh`, not bare `swift test`.** The suite uses swift-testing (`import Testing`); under CLT that framework + `lib_TestingInterop.dylib` live off the default search path, so plain `swift test` fails with `no such module 'Testing'` (then dlopen errors). The wrapper adds the `-F`/rpath flags. CI has full Xcode, so its plain `swift test` works.

## CI / Releases (`.github/workflows/`)
- `pr-checks.yml` — runs `swift test` on PRs to `main` (macos-14).
- `release.yml` — on push to `main`: derive version `0.<N>` (`N = git rev-list HEAD --first-parent --count`, like AI-Replace's eywa scheme but `0.N` not `vN`), `swift test` gate → `bundle.sh` (ad-hoc) → `make-dmg.sh` → `gh release create` with the DMG. **No version-bump commit; the count is the version.** A `gh release view` guard makes re-runs idempotent.
- **Manual `workflow_dispatch`** (any branch via the native ref picker) → **pre-release** tagged `0.<N>-<branch-slug>.<short-sha>`, marked `--prerelease` so it never becomes "Latest".
- Signing is **ad-hoc** (no Apple secrets); notarization is a future drop-in gated on secrets (the seam lives in `bundle.sh`). Repo is public → `macos-14` runners are free.

## Source layout
- `RecallyxApp.swift` — `@main` + `NSApplicationDelegate`. **All launch wiring lives in `applicationDidFinishLaunching`** (see Lessons — MenuBarExtra content is lazy).
- `AppState.swift` — `@MainActor ObservableObject` (status / lastError / historyCount).
- `StatusItemView.swift` — menu-bar dropdown. Includes **Search history** and **Transform selection** items whose key equivalents are derived live from the saved `Shortcut`s (observes `SettingsStore`; disabled hotkey → no key hint, item stays). The equivalents only fire while the menu is open, so they mirror — not double-trigger — the global Carbon hotkeys.
- `MenuBarIconImage.swift` — the menu-bar glyph: the brand mark (stacked clips, same viewBox-24 geometry as `BrandMark`) rendered as a resolution-independent **template** `NSImage` so macOS tints it for light/dark bars. `MenuBarIcon` (in `RecallyxApp.swift`) shows it at idle and swaps in an SF Symbol for working/success/error feedback.
- `Log.swift` — `os.Logger` (subsystem `io.github.macrosak.recallyx`) mirrored to stderr.
- `HistoryItem.swift` — `HistoryItem` (stored record), `CapturedClip` (raw capture from the watcher), `ContentHash` (SHA-256 dedupe keys via CryptoKit).
- `HistoryStore.swift` — `@MainActor ObservableObject` owning the on-disk history. `add` (dedupe-bump or insert) / `bump` / `delete` / `clear`. Cap eviction, atomic save (temp + `replaceItemAt`), debounced writes, reseed-on-corrupt, orphan reconciliation.
- `ClipboardWatcher.swift` — `Timer` polling `changeCount` (~0.3s). Privacy filter → classify image|text → capture frontmost app → `store.add`. `markSelfWrite()` self-write guard (keyed by pasteboard `changeCount`, recorded right after our own write — content hashes can't key this: re-encoded images never hash back to the captured bytes) so a paste-of-existing bumps rather than re-captures (AI/script results are *not* marked → re-enter as fresh top items). Image takes priority over text; TIFF/PNG normalized to PNG.
- `PrivacyFilter.swift` — pure `shouldCapture(types:captureSensitive:)` honoring `org.nspasteboard.{Concealed,Transient,AutoGenerated}Type` hints, + `isSkippableText`. Unit-tested.
- `AppIconProvider.swift` — `@MainActor` source-app icon resolver, memoized by bundle ID via `NSWorkspace.icon(forFile:)` (in-memory only).
- `Shortcut.swift` — `Shortcut` (Carbon keyCode + modifier mask + record-time `keyLabel` — captured via `characters(byApplyingModifiers: [])` so ⇧ never bakes into the label; lowercase stored, uppercased only for display). Derives `glyphs` (⌃⌥⇧⌘ order), `eventModifiers`/`keyEquivalent`/`keyboardShortcut` (nil when disabled), `from(event:)`; `Shortcut.validate` → `noModifier`/`conflict`/`systemReserved` (⌘Q/⌘W/⌘⇥ denylist). Unit-tested.
- `HotkeyManager.swift` — Carbon multi-hotkey, driven by the two `AppSettings` shortcuts (`showHistory` id=1, `transformSelection` id=2). `apply(_:_:)→ApplyResult` re-registers one hotkey live (per-id refs); `suspend()`/`resume(...)` unregister both while the Settings recorder captures keys (Carbon swallows registered combos before local monitors see them). The app delegate is the single mutation point: `applyShortcut` does Carbon-then-settings, so a failed registration never clobbers the live binding; launch failures land in `state.lastError`.
- `HistoryPanel.swift` / `HistoryPanelController.swift` — vibrancy `NSPanel` (760×562, `NSVisualEffectView .hudWindow`) + window controller (positions ~62% up the mouse screen, captures `sourceApp` to paste back into, routes ↑↓↵esc⇥ via a local keyDown monitor while typed chars reach the search field).
- `HistoryPanelViewModel.swift` — query → `FuzzyMatcher.rank` (sync, instant) → filtered list + cursor; then spawns an async `Task` for a full-text substring pass on long clips that didn't sync-match, merging results in recency order without moving the cursor. Cancels the previous task on every keystroke. `ClipTime` relative/clock formatting.
- `LargeTextView.swift` — `NSViewRepresentable` wrapping `NSScrollView + NSTextView(usingTextLayoutManager: true)` (TextKit 2). Viewport-only layout so large clips don't stall the main thread on arrow-down or panel-open. Used in `DetailPaneView` for all text clips.
- `ImagePreviewCache.swift` — `@MainActor` NSCache keyed by filename. `load(filename:url:)` decodes off-thread via `Task.detached` + `CGImageSourceCreateThumbnailAtIndex` capped at 200pt (2× for Retina). Mirrors `AppIconProvider`.
- `HistoryPanelView.swift` — search bar · list rows (app icon, snippet, time) · detail (`LargeTextView` for text / async image preview via `ImagePreviewCache` + provenance footer) · empty state. `RXTheme.swift` carries the design tokens (dark/light), `BrandMark`, `AppIconView`. `SharedPanelViews.swift` = `Keycap`/`HintBar`/`ColumnHeader`.
- `FuzzyMatcher.swift` — subsequence ranking (exact > prefix > substring > scattered). Bounded to `searchPrefixLimit` (16 KB) of text per item in the sync pass — items with matches only in the tail are surfaced by the async deep-search pass in `HistoryPanelViewModel`. Unit-tested.
- `Paster.swift` — paste mechanics extracted from `CorrectionController` (set clipboard → activate source app → synth ⌘V; text + image). Split into `setClipboardText/Image` + `activateAndPaste` so callers can `markSelfWrite()` between the clipboard write and the paste.
- `ActionMenu.swift` — `BuiltinAction` (Paste / Copy / Delete / Copy file path / Reveal in Finder / Open in Preview; entries vary by clip kind — images get Open in Preview / Copy file path / Reveal in Finder) + `ActionRowView` / `ActionMenuColumn`. The vm gains a `.actions` mode: ⇥ opens the menu (columns swap to detail | actions), ↑↓ pick, ↵ run, esc back. Delete removes locally and stays open; other actions perform + dismiss.

- `Settings.swift` — `AppSettings` (retentionCap / captureSensitive / launchAtLogin; custom decoder defaults missing keys) + `SettingsStore` (debounced UserDefaults, `onChange` pushes live changes into the stores). `LaunchAtLogin.swift` wraps `SMAppService`.
- `SettingsView.swift` / `SettingsGeneralView.swift` / `SettingsChrome.swift` / `SettingsWindowController.swift` — solid Settings window (transparent full-size titlebar so the custom header sits behind native traffic lights). `SettingsTheme` = the proposal's `stheme`. General tab: Shortcuts (click-to-record `ShortcutRecorder` — suspends the global hotkeys while capturing, ✕ disables, errors in the row's desc slot like launch-at-login), History (retention cap, Capture sensitive data, Clear), Startup (Launch at login). OpenAI section + Actions tab arrive with the AI layer.

**Phase 1 complete here** — a usable, shippable clipboard manager with no AI.

### Phase 2 — actions / AI
- `Action.swift` — `Action { name, icon, steps: [Step] }`, `Step { type: .script|.ai, enabled, script, prompt, model? }` (generalizes AI Replace's `Preset`). `Action.defaults()` seeds the menu. `kindTag` → SCRIPT/AI.
- `ActionRunner.swift` — `@MainActor`; threads text through enabled steps in order (`.script` → `ScriptRunner`, `.ai` → `OpenAIClient`). Script/AI runners are **injectable** so tests are hermetic. A throwing step aborts before paste. Unit-tested.
- `ScriptRunner.swift` / `OpenAIClient.swift` / `KeychainStore.swift` / `Notifier.swift` — copied from AI Replace (env key `RECALLYX_SCRIPT`, keychain service `io.github.macrosak.recallyx`, `ModelCatalog.default = gpt-4o-mini`).
- Action menu now shows built-ins → `Saved actions` divider → user actions (text clips only, with SCRIPT/AI tags). Running a saved action threads the clip text through `ActionRunner` and pastes the result (which re-enters history as a fresh top item — *not* marked self-copy). Settings General gains the OpenAI section (API key + Show/Test/Save, Default model). `AppSettings` extended with `defaultModel` + `actions`.

- `SettingsActionsView.swift` (+ `IconCatalog`/`IconPickerView`) — the Actions tab: action list (add/delete/select) on the left, a step-pipeline editor on the right (name, icon picker, per-step type segmented Script/AI, enable toggle, body editor, model override, reorder/remove, Add step). Edits write straight into `settingsStore.settings.actions`.
- **Ad-hoc AI in the panel.** The vm gains `.custom` and `.edit` modes. The action menu's **Custom…** entry (text clips) opens a one-off prompt column → ↵ runs a transient single-`ai`-step action. **Edit-before-run**: ⇥ on a highlighted saved action enters `.edit`, showing step 1's body editable; ⇥ paginates steps; ⌘↵ runs the modified *transient copy* (the saved action is untouched). Both go through the same `onRunAction` → `ActionRunner`. `CustomPromptColumn`/`EditStepsColumn` match the design. Focus moves to the editor in custom/edit modes, to the search field in list/actions.
- **The search field retargets by mode.** List mode filters clips ("Search clipboard…" / "N clips"); entering any action state clears it and switches to "Search actions…" / "N actions", filtering the menu (`filteredMenuItems`, order-preserving so the Saved-actions divider still groups). The clip query is stashed on ⇥ and restored on esc; `query`'s `didSet` routes to the active domain via `onQueryChanged`.

- `AccessibilityClient.swift` — trimmed copy of AI Replace's (read-only: selection capture + one-prompt-per-session permission flow; no write-back, since results paste via synth ⌘V). `captureSelection` reads `kAXSelectedText`; `captureSelectionViaCopy` is the Chromium/Gmail fallback — synth ⌘C, poll the pasteboard `changeCount` (~500ms), no bump ⇒ no selection. `handleTransformSelection` tries AX then the fallback, `store.add`s the clip to the top (the watcher's tick dedupe-bumps the copy), and `historyPanel.showOnTopActions()` opens the panel already on that clip's action menu.

**Phase 2 complete** — the full clipboard manager + actions/AI, ⌘⇧V and ⌃⇧V. Recallyx now supersedes AI Replace.

## UI / visual design
Native SwiftUI matched to the proposal export (30 reference panels + the `screens/*.jsx` token source). `RXTheme` is the JSX `RX` palette translated to `Color`. The panel is a frosted floating `NSPanel`; Settings (later) is a solid window. Dark + light both supported via `@Environment(\.colorScheme)`.

## Storage
`~/Library/Application Support/Recallyx/` — `history.json` (the index) + `images/<uuid>.png` (image payloads). Only small settings/actions go in UserDefaults; history is on disk because images make it megabytes-large. Ordering is `max(createdAt, lastUsedAt)` descending (a bump refreshes `lastUsedAt`).

## Logs
```
log stream --predicate 'subsystem == "io.github.macrosak.recallyx"' --level debug
```
Or run the binary directly: `./Recallyx.app/Contents/MacOS/Recallyx` (stderr mirror).

## Manual UI testing (agents)
`./scripts/debug.sh` drives a live instance over distributed notifications — `DebugHooks.swift`, active only in `RECALLYX_DEBUG=1` launches. No TCC needed to drive; screenshots need Screen Recording for the calling terminal (already granted).
- `launch [DATA_DIR]` — killalls running instances (restore the user's app after: `open ~/Applications/Recallyx.app`), launches with hooks; `DATA_DIR` isolates history via `RECALLYX_DATA_DIR` (settings/UserDefaults are **not** isolated). Stderr → `/tmp/recallyx-debug.log`.
- `cmd show-panel|show-actions|hide-panel|open-settings` · `cmd query <text>` · `cmd text <text>` (mode-aware: custom prompt / edit body / search) · `cmd key up|down|return|cmd-return|tab|esc` (goes through the real `handleKeyDown`, so mode routing matches real keypresses).
- `state` — JSON dump (mode/query/cursor/counts). `shot [PATH]` — real-pixel `screencapture` of the panel window. `snap [PATH]` — app-side `cacheDisplay` render (no TCC, vibrancy unblurred).
- Typical loop: `bundle.sh` → `debug.sh launch /tmp/rx-debug` → seed clips via `pbcopy` (sleep ~0.5s between; watcher polls ~0.3s) → `cmd show-panel` → `shot` → Read the PNG.
- Caveats: any user click outside dismisses the panel — show + shot in one tight command when the user is active. ↵/paste actions synth ⌘V into the frontmost app — don't run them unattended. Save/restore the user's clipboard (`pbpaste`/`pbcopy`) around a session.

## Lessons carried over from AI Replace — don't relitigate
- **MenuBarExtra content is lazy.** Use `NSApplicationDelegate.applicationDidFinishLaunching` for launch wiring, never the content's `.task`.
- **Ad-hoc signing invalidates TCC every rebuild.** Stable identity via `scripts/create-signing-identity.sh` → grant survives rebuilds.
- **TCC stale entries survive System Settings toggles.** Fix: `tccutil reset Accessibility io.github.macrosak.recallyx`.
- **`open` doesn't relaunch a running app** — it foregrounds. `install.sh` does `killall` first.
- **Carbon `RegisterEventHotKey`** returns `eventHotKeyExistsErr=-9878` if the combo is taken globally.
- **Chromium/Electron silently drop `kAXSelectedText` writes** — re-read to verify, fall back to synthesized ⌘V at `.cghidEventTap`. (Phase 2 paste path.)
- **Chromium/Gmail don't expose `kAXSelectedText` reads either** (error or empty even with a selection) — fall back to synthesized ⌘C + pasteboard `changeCount` polling. AI Replace dodged this with a separate manual-copy hotkey (⌘⌥V); Recallyx synthesizes the copy itself.
- **OpenSSL 3 PBES2 p12 is rejected by macOS Security** — `create-signing-identity.sh` uses `/usr/bin/openssl` (LibreSSL).

## When the user reports a problem
1. App-side log: the `log stream` predicate above (info-level os_log is **not** persisted to disk — `log show` won't have it; use live `log stream`, or run the binary directly for the stderr mirror).
2. TCC log (⌃⇧V permission): `log show --predicate 'subsystem == "com.apple.TCC" AND eventMessage CONTAINS "recallyx"' --last 5m --info --style compact`. `Failed to match existing code requirement` ⇒ stale TCC entry — `tccutil reset Accessibility io.github.macrosak.recallyx`.
3. Codesign state: `codesign -dvvv Recallyx.app 2>&1 | grep -E "Authority|Signature"`. `Authority=Recallyx Dev` good; `Signature=adhoc` ⇒ TCC re-grant pain.
4. Re-bundle before testing hotkeys/UI: `swift build` updates `.build/`, but the `.app` binary is only refreshed by `scripts/bundle.sh`. Running a stale `.app` is a classic "my change didn't take" trap.

## Don't
- Add Xcode-only deps (no `#Preview` macros — Command Line Tools only).
- Move launch wiring onto MenuBarExtra content's `.task`.
- Run `tccutil reset` or `security add-trusted-cert` without explicit user confirmation.
- Test a code change against a stale `.app` — re-run `bundle.sh` first.

## Maintaining this file
Update when behavior changes; delete stale entries. Extend it in each commit that changes the lifecycle, adds a screen, or teaches a new lesson.
