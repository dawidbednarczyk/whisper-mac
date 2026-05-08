#!/usr/bin/env bash
# sync_hammerspoon.sh — sync ~/.hammerspoon/ <-> repo hammerspoon/ mirror
# Usage:
#   sync_hammerspoon.sh push   # repo -> ~/.hammerspoon/  (then restart Hammerspoon)
#   sync_hammerspoon.sh pull   # ~/.hammerspoon/ -> repo  (commit afterward)
#   sync_hammerspoon.sh diff   # show drift between the two
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)/hammerspoon"
LIVE_DIR="$HOME/.hammerspoon"
FILES=(init.lua whisper_streaming.lua whisper_mouse.lua whisper_overlay.lua whisper_debug.lua)

cmd="${1:-}"
case "$cmd" in
  push)
    for f in "${FILES[@]}"; do
      [ -f "$REPO_DIR/$f" ] || { echo "missing repo file: $f" >&2; continue; }
      cp -v "$REPO_DIR/$f" "$LIVE_DIR/$f"
    done
    echo
    echo "Now restart Hammerspoon:  pkill -x Hammerspoon && open -a Hammerspoon"
    ;;
  pull)
    for f in "${FILES[@]}"; do
      [ -f "$LIVE_DIR/$f" ] || { echo "missing live file: $f" >&2; continue; }
      cp -v "$LIVE_DIR/$f" "$REPO_DIR/$f"
    done
    echo
    echo "Now commit:  git -C $(dirname "$REPO_DIR") add hammerspoon/ && git commit -m 'sync hammerspoon'"
    ;;
  diff)
    rc=0
    for f in "${FILES[@]}"; do
      if ! diff -q "$REPO_DIR/$f" "$LIVE_DIR/$f" >/dev/null 2>&1; then
        echo "DRIFT: $f"
        diff -u "$REPO_DIR/$f" "$LIVE_DIR/$f" | head -40
        echo "---"
        rc=1
      fi
    done
    [ $rc -eq 0 ] && echo "in sync"
    exit $rc
    ;;
  *)
    echo "usage: $0 {push|pull|diff}" >&2
    exit 2
    ;;
esac
