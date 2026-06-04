# Recallyx

A macOS menu-bar **clipboard history manager**. It watches the system clipboard, keeps a searchable history of text and images on disk, and gives you a fast floating panel to find and paste anything you've copied. A second layer adds **actions** — reorderable pipelines of script/AI steps that transform a clip before pasting.

Successor to [AI Replace](../ai-replace) — same proven menu-bar / hotkey / paste / OpenAI machinery, generalized into a clipboard manager.

- **⌘⇧V** → history panel: fuzzy-search your clipboard, ↑/↓ to select, ↵ pastes the selected clip into wherever you were, ⇥ opens its action menu, esc closes.
- **⌃⇧V** → grab the current selection, push it to history, and open its actions — the AI-Replace replacement (select text anywhere, transform it, paste in place).

The panel is a frosted floating window matching the [design reference](docs.local/design-reference/): a search field on top, your history list on the left (with source-app icons and relative timestamps), and a detail view on the right. It follows the system light/dark appearance.

### Actions

Press **⇥** on a clip to open its action menu. Built-in actions are Paste, Copy, Delete (and for images Copy file path / Reveal in Finder). Below those you'll find your saved **actions** and a **Custom…** entry:

- A **saved action** runs the clip's text through a pipeline of script (`bash` filter) and AI (OpenAI) steps and pastes the result.
- **Custom…** lets you type a one-off instruction that runs once and is then discarded.
- **⇥ again** on a saved action lets you **edit its steps for just this run** (⇥ paginates the steps, ⌘↵ runs) without changing the saved action.

Build and edit actions in **Settings → Actions**. AI steps need an OpenAI API key (Settings → General).

> Privacy: a single **Capture sensitive data** toggle (Settings → General), **off by default**, makes Recallyx honor `org.nspasteboard.*` hints so password-manager and transient clips are skipped.

## Requirements

- macOS 13 (Ventura) or newer.
- Apple Command Line Tools (`xcode-select --install`). Xcode itself is **not** required.

## Setup on a fresh machine

### 1. Create a stable code-signing identity (one-time, per machine)

```bash
./scripts/create-signing-identity.sh
```

This generates a self-signed `Recallyx Dev` certificate in your login keychain. The script prints **one more command** to trust it for code signing (it modifies keychain trust, so you run it yourself):

```bash
security add-trusted-cert -p codeSign -k ~/Library/Keychains/login.keychain-db scripts/.signing-cert.pem
```

Verify:

```bash
security find-identity -p codesigning -v   # → "Recallyx Dev"
```

### 2. Build and install

```bash
./scripts/bundle.sh        # SPM release build → Recallyx.app (signed with Recallyx Dev)
./scripts/install.sh       # copy to ~/Applications, kill any running instance, launch
```

`bundle.sh` falls back to ad-hoc signing with a warning if the identity is missing — fine for a quick test, but you'll re-grant Accessibility on every rebuild.

### 3. Get past Gatekeeper (first launch only)

The self-signed cert isn't trusted by Apple, so the first launch is blocked. **Right-click `Recallyx.app` in Finder → Open → confirm.** Subsequent launches are silent.

### 4. Grant Accessibility permission (for ⌃⇧V)

The clipboard history (⌘⇧V) works without any permission. **⌃⇧V** (grab selection + paste results) needs Accessibility:

1. On first ⌃⇧V the app shows an alert with **Open Settings**. Click it.
2. In **System Settings → Privacy & Security → Accessibility**, toggle **Recallyx** on.
3. **Quit and relaunch** — TCC reads the grant only at process start.

### Why a stable signing identity

macOS TCC stores an app's *designated requirement* (a signature fingerprint) when you grant Accessibility, and re-validates on every access. Ad-hoc signing produces a fresh hash on every rebuild, so the grant breaks each time. A stable self-signed cert keeps the grant across rebuilds. This is [Apple's own recommendation](https://developer.apple.com/forums/thread/730043).

## Dev loop

```bash
./scripts/bundle.sh && ./scripts/install.sh   # rebuild + relaunch (install.sh killalls first)
swift build                                   # compile the library only
./scripts/test.sh                             # unit tests (swift-testing via Command Line Tools)
```

Stream logs (os.Logger, subsystem `io.github.macrosak.recallyx`):

```bash
log stream --predicate 'subsystem == "io.github.macrosak.recallyx"' --level debug
```

Or run the binary directly for the stderr mirror:

```bash
./Recallyx.app/Contents/MacOS/Recallyx
```

Lifecycle: `applicationDidFinishLaunching` → `InstallEventHandler` → `RegisterEventHotKey ⌘⇧V/⌃⇧V ok` → `clipboard watcher started` → `clipboard captured …` / `history add` → `hotkey fired` → `history panel shown` → `paste` / `action run → step → paste`.

## Manual test checklist

- Copy text in any app → it appears at the top of ⌘⇧V history.
- Copy a screenshot → it appears as an image clip with a thumbnail + dimensions.
- Re-copy something already in history → it bumps to the top (no duplicate).
- Copy from a password manager (with Capture sensitive data **off**) → skipped.
- ⌘⇧V → type to search → ↵ pastes into the previously focused app.
- ⇥ on a clip → Paste / Copy / Delete; Delete keeps the panel open.
- ⇥ → run a saved script action (e.g. Remove extra whitespace) → result pasted.
- With an API key set: run an AI action; try **Custom…**; try **⇥ edit-before-run**.
- ⌃⇧V with text selected → panel opens on that clip's actions; pick one → pasted in place.
- Lower the retention cap in Settings → oldest clips (and their image files) are evicted.

## Troubleshooting

- **Hotkey logs `RegisterEventHotKey … failed status=-9878`** — `eventHotKeyExistsErr`; another app grabbed ⌘⇧V / ⌃⇧V globally (Alfred / Raycast / etc.). Quit it or change the combo in `HotkeyManager.swift`.
- **"Accessibility permission missing" after granting it** — TCC is holding a stale requirement (usually from an earlier ad-hoc build). Reset and re-grant:
  ```bash
  tccutil reset Accessibility io.github.macrosak.recallyx
  killall Recallyx && ./scripts/install.sh
  ```
- **App blocked by Gatekeeper every launch** — repeat the right-click → Open once after replacing the bundle.

## Project layout

```
recallyx/
├── Package.swift                  # SPM manifest, zero external deps
├── Sources/Recallyx/
│   ├── RecallyxApp.swift          # @main, MenuBarExtra + NSApplicationDelegate (all launch wiring)
│   ├── AppState.swift             # menu-bar status
│   ├── HistoryItem.swift          # record + CapturedClip + ContentHash
│   ├── HistoryStore.swift         # on-disk index + images, dedupe/evict/atomic-save
│   ├── ClipboardWatcher.swift     # changeCount poll → classify → store
│   ├── PrivacyFilter.swift        # nspasteboard hints + empty-text skip
│   ├── AppIconProvider.swift      # source-app icons
│   ├── HotkeyManager.swift        # Carbon ⌘⇧V / ⌃⇧V
│   ├── HistoryPanel*.swift        # panel, controller, view model, views
│   ├── ActionMenu.swift           # Tab action menu + ad-hoc AI columns
│   ├── FuzzyMatcher.swift         # subsequence ranking
│   ├── Paster.swift               # clipboard + synth ⌘V
│   ├── AccessibilityClient.swift  # ⌃⇧V selection capture
│   ├── Action.swift / ActionRunner.swift   # step pipelines
│   ├── ScriptRunner.swift / OpenAIClient.swift / KeychainStore.swift / Notifier.swift
│   ├── Settings*.swift            # store + window + General/Actions tabs + chrome
│   ├── RXTheme.swift / SharedPanelViews.swift / Icon*.swift
│   └── Resources/                 # Info.plist, AppIcon.icns, icon.png
├── Tests/RecallyxTests/           # swift-testing suites
├── scripts/                       # bundle / install / make-icon / create-signing-identity / test
└── docs.local/                    # design doc + design-reference (panels + JSX tokens)
```

## Notes

- The OpenAI API key is stored in the macOS Keychain (Settings → General).
- Model: configurable; default `gpt-4o-mini`, per-AI-step override available.
- The app icon is generated from the brand mark by `scripts/gen-icon.swift` (a blue→indigo squircle with the white stacked-clips logo); rebuild the source PNG with `swift scripts/gen-icon.swift Sources/Recallyx/Resources/icon.png` then `./scripts/make-icon.sh`.
```
