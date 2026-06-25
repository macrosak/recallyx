#!/usr/bin/env bash
# Drive a debug instance of Recallyx for manual UI testing (humans and agents).
# Commands travel over DistributedNotificationCenter to DebugHooks.swift, which
# is only active in RECALLYX_DEBUG=1 launches. Bundle first: ./scripts/bundle.sh
#
#   ./scripts/debug.sh launch [DATA_DIR]  kill running instances, launch with hooks
#                                         (DATA_DIR isolates history via RECALLYX_DATA_DIR)
#   ./scripts/debug.sh cmd <name> [arg]   send a raw command:
#                                           show-panel | show-actions | hide-panel
#                                           open-settings [general|providers|actions]
#                                           query <text> | text <text>
#                                           key up|down|return|cmd-return|tab|esc
#   ./scripts/debug.sh state              print panel state as JSON
#   ./scripts/debug.sh shot [PATH]        screenshot the panel window (real pixels;
#                                         needs Screen Recording for the calling app)
#   ./scripts/debug.sh snap [PATH]        app-side render via cacheDisplay (no TCC,
#                                         but vibrancy loses the behind-window blur)
#   ./scripts/debug.sh quit               kill the debug instance
set -euo pipefail
cd "$(dirname "$0")/.."

post() {
    swift - "$@" <<'EOF'
import Foundation
let args = CommandLine.arguments
var info: [String: String] = ["cmd": args[1]]
if args.count > 2 { info["arg"] = args[2] }
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("io.github.macrosak.recallyx.debug"),
    object: nil, userInfo: info, deliverImmediately: true)
EOF
}

# Wait for the app to write $1, then print it.
reply() {
    for _ in $(seq 1 30); do
        [[ -s "$1" ]] && { cat "$1"; return 0; }
        sleep 0.1
    done
    echo "no reply at $1 — is a RECALLYX_DEBUG=1 instance running? (./scripts/debug.sh launch)" >&2
    return 1
}

case "${1:-}" in
launch)
    killall Recallyx 2>/dev/null && sleep 0.5 || true
    declare -a envs=(RECALLYX_DEBUG=1)
    if [[ -n "${2:-}" ]]; then
        mkdir -p "$2"
        envs+=(RECALLYX_DATA_DIR="$2")
    fi
    env "${envs[@]}" ./Recallyx.app/Contents/MacOS/Recallyx >>/tmp/recallyx-debug.log 2>&1 &
    disown
    echo "launched pid=$! (stderr log: /tmp/recallyx-debug.log)"
    ;;
cmd)
    shift
    post "$@"
    ;;
state)
    out=/tmp/recallyx-state.json
    rm -f "$out"
    post state "$out"
    reply "$out"
    ;;
shot)
    out="${2:-/tmp/recallyx-shot.png}"
    id=$(swift - <<'EOF'
import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
// Skip the ~24px status-item window; any real window (panel/settings) qualifies.
for w in list where (w["kCGWindowOwnerName"] as? String) == "Recallyx" {
    let bounds = w["kCGWindowBounds"] as! [String: Int]
    if bounds["Height"]! > 100 {
        print(w["kCGWindowNumber"] as! Int)
        break
    }
}
EOF
)
    if [[ -z "$id" ]]; then
        echo "no Recallyx window on screen — open one first (./scripts/debug.sh cmd show-panel)" >&2
        exit 1
    fi
    screencapture -x -o -l "$id" "$out"
    echo "$out"
    ;;
snap)
    out="${2:-/tmp/recallyx-snap.png}"
    rm -f "$out"
    post snapshot "$out"
    reply "$out" >/dev/null
    echo "$out"
    ;;
quit)
    killall Recallyx 2>/dev/null || true
    ;;
*)
    sed -n '2,18p' "$0"
    exit 1
    ;;
esac
