#!/bin/bash
#
# whisper_log_hook.sh
# -------------------
# Bridge from Careless-Whisper/whisper.sh and Hammerspoon → transcription_log.py.
# Always exits 0 — must NEVER block or fail the paste path.
#
# Two modes:
#
# Mode A — initial quick-paste (default, base_raw stage):
#   $1 t0_epoch          (e.g. 1730000000)
#   $2 wav_path          (full path to archived WAV)
#   $3 quick_model_id    (filename, e.g. ggml-base.en.bin)
#   $4 quick_duration_ms (button-click → paste-ready, in ms)
#   $5 text_file         (path to file containing the quick-paste text)
#   $6 app_name          (optional, e.g. "Cursor"; default "")
#   $7 project_hint      (optional, e.g. project folder; default "")
#
# Mode B — stage update (improved retranscribe text, e.g. medium_corr):
#   When $8 is non-empty, it is treated as a stage_id and the call dispatches
#   to `transcription_log.py update-stage` instead of `add-quick`. In Mode B:
#   $1 t0_epoch          (ignored, for arg-shape symmetry)
#   $2 wav_path
#   $3 model_id          (ignored — stage_id determines the slot)
#   $4 duration_ms
#   $5 text_file
#   $6, $7               (ignored)
#   $8 stage_id          (e.g. "medium_corr", "large_corr")
#
# Plan 4 S1B / S3 (2026-04-23):
#   Mode A also captures WAV duration via ffprobe and passes through the
#   button-press monotonic timestamp via env vars (set by Hammerspoon's
#   whisper_streaming.lua before invoking whisper.sh). Both are optional —
#   missing ffprobe / missing env var must NOT break the paste path.

set +e

REPO_BIN_DIR="$(cd "$(dirname "$0")" && pwd)"
PY="${PYTHON3:-/usr/bin/python3}"
[ -x /opt/homebrew/bin/python3 ] && PY=/opt/homebrew/bin/python3

if [ -n "${8:-}" ]; then
    # Mode B — stage update
    "${PY}" "${REPO_BIN_DIR}/transcription_log.py" update-stage \
        "${2:-/dev/null}" "${8}" "${4:-0}" "${5:-/dev/null}" \
        >> "${HOME}/.whisper_log/hook.log" 2>&1 || true
else
    # Mode A — initial quick-paste
    # Plan 4 S1B: ffprobe WAV duration → ms (best-effort; silent fail OK)
    WAV_DURATION_MS=""
    WAV_PATH="${2:-}"
    if [ -n "${WAV_PATH}" ] && [ -f "${WAV_PATH}" ]; then
        FFPROBE=""
        if [ -x /opt/homebrew/bin/ffprobe ]; then
            FFPROBE=/opt/homebrew/bin/ffprobe
        elif command -v ffprobe >/dev/null 2>&1; then
            FFPROBE="$(command -v ffprobe)"
        fi
        if [ -n "${FFPROBE}" ]; then
            DUR_S="$("${FFPROBE}" -v error -show_entries format=duration \
                -of default=noprint_wrappers=1:nokey=1 "${WAV_PATH}" 2>/dev/null)"
            if [ -n "${DUR_S}" ]; then
                # Convert seconds (float) → ms (int) using awk to avoid bash float issues.
                WAV_DURATION_MS="$(awk -v d="${DUR_S}" 'BEGIN { printf("%d", d * 1000 + 0.5) }')"
            fi
        fi
    fi

    WHISPER_WAV_DURATION_MS="${WAV_DURATION_MS}" \
    WHISPER_BUTTON_PRESSED_AT_NS="${WHISPER_BUTTON_PRESSED_AT_NS:-$(
        # QC-01 v2 (2026-04-23): read forward-button sidecar written by
        # ~/.hammerspoon/whisper_mouse.lua at button-down. launchctl setenv
        # does NOT propagate to already-running Hammerspoon's hs.task.new
        # children, so env-var passthrough was non-functional. Sidecar file
        # is the reliable cross-process carrier. Best-effort: silent fail OK.
        # F-S1-03/F-S2-02 (2026-04-24): switched from sed regex to python3
        # JSON parse. Previous regex was coupled to compact serialisation
        # (no whitespace after colon, integer not string). If Lua ever switched
        # to dkjson or pretty-printed for debugging, the regex returned empty
        # → button-press timestamp silently lost. python3 json.load handles
        # any valid JSON variant. ~30 ms cost, irrelevant on a path that
        # already takes 100s of ms for whisper-cli.
        SIDECAR=/tmp/whisper_button_press_forward.json
        if [ -f "${SIDECAR}" ]; then
            EPOCH_NS="$("${PY}" -c "
import json, sys
try:
    with open('${SIDECAR}') as f:
        d = json.load(f)
    v = d.get('epoch_ns')
    if isinstance(v, (int, float)):
        print(int(v))
    elif isinstance(v, str) and v.strip().lstrip('-').isdigit():
        print(int(v.strip()))
except Exception:
    pass
" 2>/dev/null)"
            # Delete sidecar so it can't be read twice (one stamp per recording)
            rm -f "${SIDECAR}"
            echo "${EPOCH_NS}"
        fi
    )}" \
        "${PY}" "${REPO_BIN_DIR}/transcription_log.py" add-quick \
        "${1:-0}" "${2:-/dev/null}" "${3:-}" "${4:-0}" "${5:-/dev/null}" \
        "${6:-}" "${7:-}" \
        >> "${HOME}/.whisper_log/hook.log" 2>&1 || true
fi

exit 0
