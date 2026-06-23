<div align="center">
  <img src="docs/recallyx-social.png" alt="Recallyx" width="760">

  <h1>Recallyx</h1>
  <p><b>A programmable clipboard for macOS — run script &amp; AI pipelines on anything you copy.</b></p>

  <p>
    <img alt="macOS 13+" src="https://img.shields.io/badge/macOS-13%2B-111?logo=apple&logoColor=white">
    <img alt="Swift 5.9" src="https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white">
    <img alt="License MIT" src="https://img.shields.io/badge/license-MIT-0a84ff">
    <img alt="Release" src="https://img.shields.io/github/v/release/macrosak/recallyx">
  </p>
</div>

## What it is

macOS now has a basic built-in clipboard history. Recallyx is the layer on top of it. It keeps a
fast, searchable history of everything you copy — text and images — on disk, and adds an
**actions** layer that the system clipboard can't: small pipelines of **script** (`bash`) and
**AI** steps that transform a clip and paste the result. Clean up some JSON, fix grammar, rewrite
a selection, reshape data — then paste it right where you were. Select text anywhere (even in
Chrome) and transform it in place.

## Why it's different

Recallyx is the free, open-source (MIT), developer-first programmable clipboard for macOS —
script and AI pipelines on anything you copy, with AI that can run entirely on your Mac.

- **Programmable** — chain `bash` and AI steps per clip. Most clipboard managers stop at history
  and snippets; Recallyx lets you build and run real transform pipelines on anything you copy.
- **Multi-provider and local AI** — AI steps run on **OpenAI**, **Anthropic (Claude)**,
  **Google Gemini**, **local Ollama**, or **on-device Apple Intelligence** — pick the provider per
  step. Cloud providers use your own API key; **Ollama and Apple on-device need no key and never
  leave your Mac**, so you can run a fully private, offline setup.
- **Free, open, and native** — MIT-licensed, zero dependencies, a floating ⌘⇧V panel, no Electron.

## The two hotkeys

- **⌘⇧V** — open the history panel. Fuzzy-search your clips, `↑/↓` to select, `↵` pastes the
  selected clip into wherever you were, `⇥` opens its action menu, `esc` closes.
- **⌃⇧V** — grab the current selection, push it to history, and open straight into its
  actions. Select text anywhere — including browsers like Chrome — transform it, paste the
  result in place.

Both are defaults, not fixtures: in **Settings → General → Shortcuts**, click a shortcut to
record a new combo (applied immediately, no relaunch) or **✕** to disable it. The menu-bar
items always show the current bindings.

A few more in the panel:

- **Pin a clip** to keep it at the top of your history — pinned clips are exempt from
  retention-cap eviction, so they stick around no matter how much you copy.
- **⌘1–9** quick-pastes the Nth clip in the history list, or quick-runs the Nth saved action in
  the action menu. Hold **⌘** to reveal the number badges on the rows.

## Screenshots

<p align="center">
  <img src="docs/recallyx-history-dark.png" alt="Recallyx history panel" width="760"><br>
  <em>⌘⇧V — fuzzy-search your clipboard history.</em>
</p>

<p align="center">
  <img src="docs/recallyx-action-menu-dark.png" alt="Recallyx action menu" width="760"><br>
  <em>⇥ — run a script or AI action on the selected clip.</em>
</p>

## Actions

Press **⇥** on a clip to open its action menu. Built-in actions are Paste, Copy, and Delete
(images also get Copy file path / Reveal in Finder). Below those are your saved **actions**
and a **Custom…** entry:

- A **saved action** runs the clip's text through a pipeline of **script** (`bash` filter) and
  **AI** steps and pastes the result. Each AI step picks its own provider — OpenAI, Anthropic,
  Gemini, local Ollama, or on-device Apple Intelligence. Steps are reorderable and individually
  toggled.
- **Custom…** lets you type a one-off instruction that runs once and is then discarded.
- **⇥ again** on a saved action lets you **edit its steps for just this run** (`⇥` paginates
  the steps, `⌘↵` runs) without changing the saved action.

**Image clips get vision actions** too — built-in **Extract text** (OCR) and **Describe image**,
runnable against a cloud provider or a local Ollama vision model (e.g. `llava`).

Recallyx ships with a **developer action pack** of built-in script transforms: URL encode/decode,
Base64 encode/decode, Decode JWT, pretty-print/minify JSON, slugify, extract URLs, and remove
whitespace. They run offline with no key.

Build and edit actions in **Settings → Actions**. Missing some of the built-ins (deleted one, or
installed before they shipped)? **Restore built-in actions** re-adds the defaults you don't have.

Cloud AI steps (OpenAI / Anthropic / Gemini) need that provider's own API key in
**Settings → General** (stored in the macOS Keychain). **Ollama** and **Apple on-device** need no
key.

> **Privacy:** your history stays local, on disk — never the cloud. With Ollama or Apple
> on-device AI, nothing your clips touch ever needs to leave your Mac. The **Capture sensitive
> data** toggle (Settings → General) is **off by default**, so Recallyx honors
> `org.nspasteboard.*` hints and skips password-manager and transient clips. There's also an
> optional, **off-by-default local usage journal** (Settings → General) — it never records clip
> contents and is never sent anywhere.

## Install

Requirements: **macOS 13 (Ventura) or newer** · **Apple Silicon (arm64)**.

Grab the latest DMG from the [**Releases** page](https://github.com/macrosak/recallyx/releases/latest),
open it, and drag **Recallyx.app** onto **Applications**.

Builds are currently **ad-hoc signed** (not yet notarized), so Gatekeeper blocks the first
launch with *"Apple could not verify Recallyx is free of malware."* Clear the quarantine
flag once, then open the app normally:

```bash
xattr -dr com.apple.quarantine /Applications/Recallyx.app
```

(On macOS 15 Sequoia and later, the old right-click → Open override no longer appears for
un-notarized apps, so the `xattr` command is the reliable way in.)

## Building from source

Needs Apple **Command Line Tools** (`xcode-select --install`) — Xcode itself is not required.

```bash
# one-time, per machine: a stable code-signing identity
./scripts/create-signing-identity.sh        # prints one `security add-trusted-cert …` to run yourself

# build + install (install.sh kills any running instance, then relaunches)
./scripts/bundle.sh && ./scripts/install.sh

# unit tests
./scripts/test.sh
```

The stable signing identity matters because ad-hoc signing produces a fresh signature on
every rebuild, which makes macOS drop the Accessibility grant each time; a self-signed
`Recallyx Dev` cert keeps the grant across rebuilds
([Apple's recommendation](https://developer.apple.com/forums/thread/730043)).

### Optional: an Xcode project

The release path above (`bundle.sh`) needs only the Command Line Tools. If you'd rather
build/run from Xcode, there's an optional [XcodeGen](https://github.com/yonaskolb/XcodeGen)
spec (`project.yml`) that generates an Xcode project for the macOS app. The generated
`Recallyx.xcodeproj` and your local signing settings are gitignored.

```bash
brew install xcodegen
cp Local.xcconfig.example Local.xcconfig   # then set DEVELOPMENT_TEAM to your own team id
xcodegen generate                          # writes Recallyx.xcodeproj
open Recallyx.xcodeproj
```

A blank team builds unsigned, which is fine for a compile check:

```bash
xcodebuild -project Recallyx.xcodeproj -scheme Recallyx build CODE_SIGNING_ALLOWED=NO
```

The clipboard history (⌘⇧V) works with no special permission. **⌃⇧V** (grab selection +
paste results) needs Accessibility: on first use the app shows an **Open Settings** alert →
toggle **Recallyx** on under **Privacy & Security → Accessibility** → **quit and relaunch**
(macOS reads the grant only at process start).

## Troubleshooting

- **A hotkey doesn't fire** — another app may have grabbed the combo globally
  (Alfred / Raycast / etc.); the status menu shows an error when that happens at launch.
  Rebind it in **Settings → General → Shortcuts**, or quit the other app.
- **"Accessibility permission missing" after granting it** — macOS is holding a stale
  requirement (usually from an earlier ad-hoc build). Reset and re-grant:
  ```bash
  tccutil reset Accessibility io.github.macrosak.recallyx
  killall Recallyx && ./scripts/install.sh
  ```
- **App blocked by Gatekeeper after replacing the bundle** — re-run the `xattr` command above
  on the new `Recallyx.app`.

## License

MIT — see [LICENSE](LICENSE).
