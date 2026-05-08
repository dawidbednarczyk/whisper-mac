#!/bin/bash
# bin/backup_records.sh — daily snapshot of ~/.whisper_log/records.json into backup/.
#
# Idempotent: skips if today's snapshot already exists.
# Atomic: writes to .tmp then mv (no half-written files).
# Optional: --commit also `git add + git commit` the snapshot (no push).
#
# Designed to run via launchd (~/Library/LaunchAgents/com.whisper-mac.backup-records.plist — see docs/launchd.md)
# but safe to run manually any time.
#
# See: docs/recovery.md, backup/README.md, rpi/disaster-recovery-from-scratch/

set -euo pipefail

SOURCE="${HOME}/.whisper_log/records.json"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BACKUP_DIR="${REPO_ROOT}/backup"
TODAY="$(date +%Y-%m-%d)"
SNAPSHOT="${BACKUP_DIR}/records.json.snapshot.${TODAY}.json"
COMMIT=0

for arg in "$@"; do
    case "$arg" in
        --commit) COMMIT=1 ;;
        --help|-h)
            echo "Usage: $0 [--commit]"
            echo ""
            echo "Snapshots ~/.whisper_log/records.json into backup/ as records.json.snapshot.YYYY-MM-DD.json."
            echo "  --commit   Also git add + git commit the snapshot (no push)."
            exit 0
            ;;
        *)
            echo "ERROR: unknown arg: $arg" >&2
            exit 2
            ;;
    esac
done

if [ ! -f "$SOURCE" ]; then
    echo "ERROR: source not found: $SOURCE" >&2
    exit 1
fi

mkdir -p "$BACKUP_DIR"

if [ -f "$SNAPSHOT" ]; then
    # Idempotent: skip if today's snapshot already exists AND content is identical.
    # If content differs (records.json grew during the day), overwrite.
    if cmp -s "$SOURCE" "$SNAPSHOT"; then
        echo "Snapshot for ${TODAY} already exists and is identical — skipping."
        exit 0
    fi
fi

# Atomic write
TMP="${SNAPSHOT}.tmp.$$"
trap 'rm -f "$TMP"' EXIT
cp "$SOURCE" "$TMP"
mv "$TMP" "$SNAPSHOT"
SIZE=$(wc -c < "$SNAPSHOT" | tr -d ' ')
echo "Snapshot saved: ${SNAPSHOT} (${SIZE} bytes)"

if [ "$COMMIT" = 1 ]; then
    cd "$REPO_ROOT"
    if git status --porcelain "$SNAPSHOT" | grep -q .; then
        git add "$SNAPSHOT"
        git commit -m "backup: records.json snapshot ${TODAY}" >/dev/null
        echo "Committed: $(cd "$REPO_ROOT" && git log -1 --oneline)"
    else
        echo "Snapshot already in git — no commit needed."
    fi
fi
