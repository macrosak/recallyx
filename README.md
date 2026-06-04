# Recallyx

A macOS menu-bar **clipboard history manager**. It watches the system clipboard, keeps a searchable history of text and images on disk, and gives you a fast floating panel to find and paste anything you've copied. A later phase adds AI/script **actions** that transform a clip before pasting.

Successor to [AI Replace](../ai-replace) — same proven menu-bar / hotkey / paste / OpenAI machinery, generalized into a clipboard manager.

- **⌘⇧V** → history panel: fuzzy-search your clipboard, ↵ pastes the selected clip, ⇥ opens its action menu.
- **⌃⇧V** (Phase 2) → grab the current selection, push it to history, and open its actions — the AI-Replace replacement.

> Status: in active construction. Phase 1 (plain clipboard manager, no AI) ships first; Phase 2 layers actions/AI on top. See [`docs.local/2026-06-04-recallyx-design.md`](docs.local/2026-06-04-recallyx-design.md).

## Requirements

- macOS 13 (Ventura) or newer.
- Apple Command Line Tools (`xcode-select --install`). Xcode itself is **not** required.

## Build & run

```bash
./scripts/create-signing-identity.sh   # one-time: stable self-signed cert (see below)
./scripts/bundle.sh                     # SPM release build → Recallyx.app
./scripts/install.sh                    # copy to ~/Applications, kill running, launch
```

`swift build` compiles the library directly without bundling; `./scripts/test.sh` runs the unit tests (a wrapper around `swift test` that points at the Command Line Tools' swift-testing framework).

### Why a signing identity

macOS TCC stores an app's *designated requirement* (a signature fingerprint) when you grant Accessibility, and re-validates on every access. Ad-hoc signing produces a fresh hash on every rebuild, so the grant breaks each time. `scripts/create-signing-identity.sh` creates a stable self-signed `Recallyx Dev` cert; the grant then persists across rebuilds. The script prints the one `security add-trusted-cert …` command you run to trust it (it asks, because it modifies keychain trust).

## Logs

```bash
log stream --predicate 'subsystem == "io.github.macrosak.recallyx"' --level debug
```

Or run the binary directly to see the stderr mirror:

```bash
./Recallyx.app/Contents/MacOS/Recallyx
```

## Project layout

```
recallyx/
├── Package.swift                 # SPM manifest, zero external deps
├── Sources/Recallyx/
│   ├── RecallyxApp.swift         # @main, MenuBarExtra host + NSApplicationDelegate
│   ├── AppState.swift            # ObservableObject backing the menu UI
│   ├── StatusItemView.swift      # menu-bar dropdown
│   ├── Log.swift                 # os.Logger + stderr mirror
│   └── Resources/
│       ├── Info.plist            # LSUIElement, bundle ID, version
│       ├── AppIcon.icns
│       └── icon.png
├── Tests/RecallyxTests/
├── scripts/                      # bundle / install / make-icon / create-signing-identity
└── docs.local/                   # design notes
```
