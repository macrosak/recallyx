#!/usr/bin/env bash
# Record the README screenshots from a live, staged instance — straight into docs/.
#
#   ./scripts/screenshots.sh [history|actions|all]   (default: all)
#
#     history → docs/recallyx-history-dark.png   (panel, bump() row selected)
#     actions → docs/recallyx-action-menu-dark.png (action menu, Fix grammar highlighted)
#
# What it does: builds the app, generates a demo history (6 staged clips) in a
# temp RECALLYX_DATA_DIR, swaps UserDefaults actions for the 4 demo ones (your
# real settings are backed up and restored on exit), launches a debug instance,
# drives the panel via scripts/debug.sh, and region-captures the panel + a 48pt
# wallpaper margin at 2x.
#
# Before running:
#   - Clear the desktop on the display where the MOUSE is (panel opens there);
#     don't click or type while it runs (~15 s — a click dismisses the panel).
#   - System appearance should be Dark (files are named -dark).
#   - The calling terminal needs Screen Recording permission.
# Demo source apps (Chrome, IntelliJ IDEA, Preview, Notes, Terminal, Telegram)
# show generic icons where not installed — edit STAGE_HISTORY below to taste.
set -euo pipefail
cd "$(dirname "$0")/.."

SCENARIO="${1:-all}"
case "$SCENARIO" in history|actions|all) ;; *)
    echo "usage: $0 [history|actions|all]" >&2; exit 1;;
esac

if [[ "$(defaults read -g AppleInterfaceStyle 2>/dev/null || true)" != "Dark" ]]; then
    echo "warning: system appearance is not Dark — screenshots are named -dark" >&2
fi

./scripts/bundle.sh

STAGE=$(mktemp -d /tmp/rx-screenshots.XXXXXX)
DOMAIN=io.github.macrosak.recallyx
BACKUP="$STAGE/defaults-backup.plist"
defaults export "$DOMAIN" "$BACKUP"

cleanup() {
    killall Recallyx 2>/dev/null || true
    sleep 0.3
    # Exact restore: delete first so staged keys can't survive a merge-import.
    defaults delete "$DOMAIN" 2>/dev/null || true
    defaults import "$DOMAIN" "$BACKUP"
    if [[ -d ~/Applications/Recallyx.app ]]; then open ~/Applications/Recallyx.app; fi
    rm -rf "$STAGE"
}
trap cleanup EXIT

# STAGE_HISTORY: demo history.json + staged settings (demo actions only; the
# rest of your settings — shortcuts, model, caps — pass through untouched).
STAGE="$STAGE" BACKUP="$BACKUP" python3 <<'EOF'
import json, time, uuid, hashlib, plistlib, shutil, os

REF = 978307200.0  # Date encodes as seconds since 2001-01-01
now = time.time() - REF
stage = os.environ["STAGE"]
os.makedirs(stage + "/images", exist_ok=True)

img_id = str(uuid.uuid4()).upper()
shutil.copyfile("docs/recallyx-social.png", f"{stage}/images/{img_id}.png")
img_bytes = open(f"{stage}/images/{img_id}.png", "rb").read()

code = '''func bump(_ id: UUID) {
    guard let i = items.firstIndex(where: { $0.id == id })
        else { return }
    var item = items.remove(at: i)
    item.lastUsedAt = .now
    items.insert(item, at: 0)
    scheduleSave()
}'''

def text_item(text, app_name, bundle_id, app_path, age_sec):
    t = now - age_sec
    return {
        "id": str(uuid.uuid4()).upper(), "kind": "text", "text": text,
        "preview": text.strip()[:280], "byteSize": len(text.encode()),
        "sourceAppBundleID": bundle_id, "sourceAppName": app_name,
        "sourceAppPath": app_path, "createdAt": t, "lastUsedAt": t,
        "contentHash": hashlib.sha256(text.encode()).hexdigest(),
    }

# Ages land on "just now / 2 min / 4 min / 12 min / 20 min / 38 min" at capture
# time (~10 s after seeding; the row formatter floors to minutes).
items = [
    text_item("https://github.com/macrosak/recallyx/pull/7",
              "Google Chrome", "com.google.Chrome", "/Applications/Google Chrome.app", 3),
    text_item(code,
              "IntelliJ IDEA", "com.jetbrains.intellij", "/Applications/IntelliJ IDEA.app", 122),
    {
        "id": img_id, "kind": "image", "imageFilename": f"{img_id}.png",
        "preview": "Image · 2560 × 1280", "byteSize": len(img_bytes),
        "sourceAppBundleID": "com.apple.Preview", "sourceAppName": "Preview",
        "sourceAppPath": "/System/Applications/Preview.app",
        "createdAt": now - 242, "lastUsedAt": now - 242,
        "contentHash": hashlib.sha256(img_bytes).hexdigest(),
        "imageDimensions": "2560 × 1280",
    },
    text_item("Retention caps history at 1000 items by default — older clips are evicted oldest-first.",
              "Notes", "com.apple.Notes", "/System/Applications/Notes.app", 712),
    text_item("log stream --predicate 'subsystem == \"io.github.macrosak.recallyx\"' --level debug",
              "Terminal", "com.apple.Terminal", "/System/Applications/Utilities/Terminal.app", 1192),
    text_item("Locked: single \"Capture sensitive data\" toggle — concealed pasteboard types from password managers are skipped by default.",
              "Telegram", "ru.keepcoder.Telegram", "/Applications/Telegram.app", 2272),
]
with open(f"{stage}/history.json", "w") as f:
    json.dump(items, f)

def action(name, icon, step):
    step["id"] = str(uuid.uuid4()).upper()
    return {"id": str(uuid.uuid4()).upper(), "name": name, "icon": icon, "steps": [step]}

with open(os.environ["BACKUP"], "rb") as f:
    plist = plistlib.load(f)
settings = json.loads(plist.get("settings.v1", b"{}"))
settings["actions"] = [
    action("Fix grammar (EN)", "sparkles", {
        "type": "ai", "enabled": True, "script": "",
        "prompt": "Fix grammar and obvious typos in the following English text. Do not change anything else; return only the corrected text:\n\n{{TEXT}}"}),
    action("Remove extra whitespace", "scroll", {
        "type": "script", "enabled": True, "prompt": "",
        "script": "sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'"}),
    action("Pretty-print JSON", "scroll", {
        "type": "script", "enabled": True, "prompt": "", "script": "python3 -m json.tool"}),
    action("Summarize to 3 bullets", "sparkles", {
        "type": "ai", "enabled": True, "script": "",
        "prompt": "Summarize the following text as exactly three concise bullet points. Return only the bullets:\n\n{{TEXT}}"}),
]
# settings.v1 is stored as <data>, not <string> — the app reads it as Data.
plist["settings.v1"] = json.dumps(settings).encode()
with open(f"{stage}/defaults-staged.plist", "wb") as f:
    plistlib.dump(plist, f)
EOF

killall Recallyx 2>/dev/null || true
sleep 0.4
defaults import "$DOMAIN" "$STAGE/defaults-staged.plist"
./scripts/debug.sh launch "$STAGE"
sleep 1.5

./scripts/debug.sh cmd show-panel
sleep 0.8
./scripts/debug.sh cmd key down   # cursor onto the bump() row
sleep 0.4

# Panel window bounds + 48pt margin so the wallpaper frames the shot.
bounds=$(swift - <<'EOF'
import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in list where (w["kCGWindowOwnerName"] as? String) == "Recallyx" {
    let b = w["kCGWindowBounds"] as! [String: Int]
    if b["Height"]! > 100 {
        print("\(b["X"]! - 48),\(b["Y"]! - 48),\(b["Width"]! + 96),\(b["Height"]! + 96)")
        break
    }
}
EOF
)
[[ -n "$bounds" ]] || { echo "panel window not found on screen" >&2; exit 1; }

if [[ "$SCENARIO" == history || "$SCENARIO" == all ]]; then
    screencapture -x -R "$bounds" docs/recallyx-history-dark.png
    echo "docs/recallyx-history-dark.png"
fi

if [[ "$SCENARIO" == actions || "$SCENARIO" == all ]]; then
    ./scripts/debug.sh cmd key tab
    sleep 0.5
    for _ in 1 2 3 4; do  # Paste → Copy → Delete → Custom… → Fix grammar (EN)
        ./scripts/debug.sh cmd key down
        sleep 0.1
    done
    sleep 0.4
    screencapture -x -R "$bounds" docs/recallyx-action-menu-dark.png
    echo "docs/recallyx-action-menu-dark.png"
fi

./scripts/debug.sh cmd hide-panel
