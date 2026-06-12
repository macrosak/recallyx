# scripts/

Build, packaging, and dev tooling. Everything runs with Command Line Tools only (no Xcode).

## Build & ship

- **`bundle.sh`** — builds `Recallyx.app` in the repo root via `swift build` + a hand-rolled bundle. Signs with the `Recallyx Dev` identity if present, else ad-hoc. Honors `RECALLYX_VERSION` (set by CI) for the Info.plist version.
- **`make-dmg.sh`** — wraps an existing `Recallyx.app` into `Recallyx-<version>-arm64.dmg` (built-in `hdiutil`, drag-to-install layout). Run `bundle.sh` first.
- **`install.sh`** — killalls any running instance, copies the bundle to `~/Applications`, and launches it.
- **`test.sh`** — runs the test suite. Use this instead of bare `swift test`: under CLT the swift-testing framework lives off the default search path, and this wrapper adds the needed `-F`/rpath flags.

## Signing

- **`create-signing-identity.sh`** — creates the self-signed `Recallyx Dev` certificate in the login keychain so signing stays stable across rebuilds and the TCC Accessibility grant survives recompiles (ad-hoc signing invalidates it on every content change). One-time setup. `.signing-cert.pem` is its public-cert artifact.

## App icon

- **`gen-icon.swift`** — renders the 1024×1024 source icon (gradient squircle + stacked-clips brand mark) to a PNG: `swift scripts/gen-icon.swift Sources/Recallyx/Resources/icon.png`.
- **`make-icon.sh`** — turns that source PNG into `AppIcon.icns` via `iconutil`.

## Dev / docs tooling

- **`debug.sh`** — drives a live `RECALLYX_DEBUG=1` instance over distributed notifications: launch with an isolated data dir, open the panel, type queries, send keys, dump state as JSON, screenshot the panel. See the header comment for the command list; agents use this for manual UI testing.
- **`screenshots.sh [history|actions|all]`** — re-records the README screenshots into `docs/`. Builds the app, seeds a demo history + demo actions into a debug instance (your real settings are backed up and restored), drives the panel via `debug.sh`, and region-captures the panel with a wallpaper margin. Needs a clear desktop on the mouse display, Dark appearance, Screen Recording permission, and hands off for ~15 s.
