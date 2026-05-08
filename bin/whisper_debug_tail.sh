#!/usr/bin/env bash
#
# whisper_debug_tail.sh — filtered live view of /tmp/whisper_debug.log
#
# Usage:
#   whisper_debug_tail.sh                      # all events, pretty
#   whisper_debug_tail.sh --mod streaming      # only one module
#   whisper_debug_tail.sh --event button_*     # event glob (case-insensitive substring)
#   whisper_debug_tail.sh --session            # only the current/latest session
#   whisper_debug_tail.sh --raw                # don't pretty-print (raw JSON lines)
#   whisper_debug_tail.sh --summary            # show last session.summary.json then exit
#   whisper_debug_tail.sh --replay             # read from start instead of tail -F
#
# Combine flags freely, e.g.
#   whisper_debug_tail.sh --mod streaming --event sentence_confirmed
#

set -uo pipefail

LOG="${WHISPER_DEBUG_LOG:-/tmp/whisper_debug.log}"
DIR="${WHISPER_DEBUG_DIR:-/tmp/whisper_debug}"

MOD_FILTER=""
EVENT_FILTER=""
RAW=0
REPLAY=0
SESSION_ONLY=0
DO_SUMMARY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --mod)        MOD_FILTER="$2"; shift 2 ;;
        --event)      EVENT_FILTER="$2"; shift 2 ;;
        --raw)        RAW=1; shift ;;
        --replay)     REPLAY=1; shift ;;
        --session)    SESSION_ONLY=1; shift ;;
        --summary)    DO_SUMMARY=1; shift ;;
        -h|--help)
            sed -n '2,20p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
done

if [ "$DO_SUMMARY" = "1" ]; then
    latest="$(ls -t "$DIR"/*.summary.json 2>/dev/null | head -1)"
    if [ -z "$latest" ]; then
        echo "no summary files in $DIR" >&2
        exit 1
    fi
    echo "# $latest"
    python3 -m json.tool "$latest"
    exit 0
fi

if [ ! -f "$LOG" ]; then
    echo "log not found: $LOG (run a recording first)" >&2
    exit 1
fi

# Determine session id filter if requested
SID=""
if [ "$SESSION_ONLY" = "1" ]; then
    SID="$(tac "$LOG" 2>/dev/null | awk -F'"sid":' '/"sid":/ {print $2; exit}' | awk -F'"' '{print $2}')"
    if [ -z "$SID" ]; then
        SID="$(awk -F'"sid":' '/"sid":/ {last=$2} END{print last}' "$LOG" | awk -F'"' '{print $2}')"
    fi
    [ -z "$SID" ] && { echo "could not find current session id in log" >&2; exit 1; }
    echo "# filtering session sid=$SID"
fi

# Python filter/pretty-printer (code passed via -c so stdin is free for the log)
PY_FILTER='
import json, sys
mod_f, ev_f, sid_f, raw_s = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
raw = raw_s == "1"
mod_f_l = mod_f.lower()
ev_f_l = ev_f.lower()
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        e = json.loads(line)
    except Exception:
        continue
    if mod_f and mod_f_l not in str(e.get("mod", "")).lower():
        continue
    if ev_f and ev_f_l not in str(e.get("event", "")).lower():
        continue
    if sid_f and str(e.get("sid", "")) != sid_f:
        continue
    if raw:
        print(line, flush=True); continue
    ts = e.pop("ts", "")
    mod = e.pop("mod", "?")
    event = e.pop("event", "?")
    sid = e.pop("sid", "")
    e.pop("t_ms", None); e.pop("kind", None)
    extras = []
    for k, v in e.items():
        if isinstance(v, str) and len(v) > 200:
            v = v[:200] + "..."
        extras.append(f"{k}={v}")
    print(f"{ts}  sid={sid:<14}  [{mod:<12}] {event:<28} " + " ".join(extras), flush=True)
'

filter() {
    python3 -c "$PY_FILTER" "$MOD_FILTER" "$EVENT_FILTER" "$SID" "$RAW"
}

if [ "$REPLAY" = "1" ]; then
    cat "$LOG" | filter
else
    # Show the tail of existing entries, then follow
    tail -n 100 -F "$LOG" | filter
fi
