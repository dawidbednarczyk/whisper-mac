#!/bin/bash
#
# System-wide speech-to-text using Whisper
# Usage: whisper.sh start | whisper.sh stop
#

# Configuration
AUDIO_FILE="/tmp/whisper_recording.wav"
TEXT_FILE="/tmp/whisper_output.txt"
PID_FILE="/tmp/whisper_recording.pid"
DEVICE_CONF="/tmp/whisper_device.conf"

# ── Debug logging (JSON lines to /tmp/whisper_debug.log) ─────────────────────
WHISPER_DEBUG_LOG="${WHISPER_DEBUG_LOG:-/tmp/whisper_debug.log}"
WHISPER_DEBUG_DIR="${WHISPER_DEBUG_DIR:-/tmp/whisper_debug}"
mkdir -p "${WHISPER_DEBUG_DIR}" 2>/dev/null || true
WHISPER_BATCH_SID="${WHISPER_BATCH_SID:-$(date +%s)_$$}"
WHISPER_BATCH_LOG="${WHISPER_DEBUG_DIR}/batch_$(date -u +%Y%m%dT%H%M%S)_${WHISPER_BATCH_SID}.log"

_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

dlog() {
    local event="$1"; shift
    local ts
    ts="$(python3 -c "import time,datetime; t=time.time(); print(datetime.datetime.utcfromtimestamp(t).strftime('%Y-%m-%dT%H:%M:%S.')+f'{int((t%1)*1000):03d}Z')" 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%S.000Z)"
    local payload="{\"ts\":\"${ts}\",\"sid\":\"${WHISPER_BATCH_SID}\",\"kind\":\"batch\",\"mod\":\"whisper.sh(workspace)\",\"event\":\"$(_json_escape "$event")\",\"action\":\"$(_json_escape "${ACTION:-}")\""
    local kv k v
    for kv in "$@"; do
        k="${kv%%=*}"; v="${kv#*=}"
        if [ "${v:0:1}" = "@" ] && [ -f "${v:1}" ]; then
            local c; c="$(cat "${v:1}" 2>/dev/null || printf '')"
            payload="${payload},\"${k}\":\"$(_json_escape "$c")\""
        else
            payload="${payload},\"${k}\":\"$(_json_escape "$v")\""
        fi
    done
    payload="${payload}}"
    printf '%s\n' "$payload" >> "$WHISPER_DEBUG_LOG" 2>/dev/null || true
    printf '%s\n' "$payload" >> "$WHISPER_BATCH_LOG" 2>/dev/null || true
}
# ─────────────────────────────────────────────────────────────────────────────

# Target microphone name patterns (case-insensitive grep, priority order)
PRIMARY_MIC="TIE.*Condenser"
SECONDARY_MIC="Usb.*Audio"

# Model selection - uncomment the one you want to use:
MODEL="$HOME/whisper-models/ggml-medium.en.bin"      # Fast, excellent for English, fewer hallucinations
#MODEL="$HOME/whisper-models/ggml-large-v3.bin"      # Slower, multilingual, can hallucinate

# Function to find mic index by name pattern
find_mic_by_pattern() {
    /opt/homebrew/bin/ffmpeg -f avfoundation -list_devices true -i "" 2>&1 | \
        grep -i "$1" | \
        grep -o '\[[0-9]*\]' | \
        tr -d '[]' | \
        head -1
}

# Function to find best mic (primary → secondary → fallback)
find_usb_mic() {
    INDEX=$(find_mic_by_pattern "$PRIMARY_MIC")
    if [ -z "$INDEX" ]; then
        INDEX=$(find_mic_by_pattern "$SECONDARY_MIC")
    fi
    echo "$INDEX"
}

# Function to get device index from config (fast, no detection)
get_device_index() {
    if [ -f "$DEVICE_CONF" ]; then
        cat "$DEVICE_CONF"
    else
        # First run - detect and save
        INDEX=$(find_usb_mic)
        if [ -n "$INDEX" ]; then
            echo "$INDEX" > "$DEVICE_CONF"
            echo "$INDEX"
        else
            echo "2"  # Fallback to MacBook Pro Microphone
        fi
    fi
}

# Function to verify and fix device index (runs AFTER pasting)
verify_and_fix_device() {
    CURRENT_INDEX=$(cat "$DEVICE_CONF" 2>/dev/null || echo "")
    CORRECT_INDEX=$(find_usb_mic)

    if [ -n "$CORRECT_INDEX" ] && [ "$CORRECT_INDEX" != "$CURRENT_INDEX" ]; then
        echo "$CORRECT_INDEX" > "$DEVICE_CONF"
        osascript -e "display notification \"Mic index updated: $CURRENT_INDEX → $CORRECT_INDEX\" with title \"🎤 Whisper Config\""
    fi
}

ACTION="$1"
dlog "script_invoked" "argc=$#" "pid=$$"

if [ "$ACTION" = "start" ]; then
    # Get device index from config FIRST (no detection delay)
    DEVICE_INDEX=$(get_device_index)
    dlog "start_recording" "device=${DEVICE_INDEX}" "model=${MODEL}"

    # Clean up any leftover files (quick, non-blocking)
    pkill -f "ffmpeg.*whisper_recording" 2>/dev/null
    rm -f "$AUDIO_FILE" "$TEXT_FILE" "$PID_FILE"

    # START RECORDING IMMEDIATELY - this is time-critical!
    nohup /opt/homebrew/bin/ffmpeg -f avfoundation -i ":${DEVICE_INDEX}" -t 300 -ar 16000 -ac 1 -y "$AUDIO_FILE" > /tmp/ffmpeg.log 2>&1 &
    FFMPEG_PID=$!

    # Save PID right away
    echo "$FFMPEG_PID" > "$PID_FILE"
    dlog "ffmpeg_launched" "pid=${FFMPEG_PID}"

    # Show notification ASYNC (don't block recording)
    osascript -e 'display notification "Recording... Press ⌃⌘Q to stop" with title "🎤 Whisper" sound name "Blow"' &

    echo "Started ffmpeg with PID: $FFMPEG_PID (device: $DEVICE_INDEX)"

    # No sleep needed - ffmpeg is already capturing

elif [ "$ACTION" = "stop" ]; then
    _T_STOP=$(date +%s)
    dlog "stop_recording"
    # Check if recording is in progress
    if [ ! -f "$PID_FILE" ]; then
        dlog "stop_abort" "reason=no_pid_file"
        osascript -e 'display notification "No recording in progress" with title "Whisper" sound name "Basso"'
        exit 1
    fi

    PID=$(cat "$PID_FILE")

    # Stop ffmpeg recording
    if kill -0 "$PID" 2>/dev/null; then
        kill -INT "$PID" 2>/dev/null
        sleep 0.5
    fi
    rm -f "$PID_FILE"

    # Check if audio file exists and has content
    if [ ! -f "$AUDIO_FILE" ] || [ ! -s "$AUDIO_FILE" ]; then
        dlog "stop_abort" "reason=no_audio"
        osascript -e 'display notification "No audio recorded - fixing mic..." with title "Whisper" sound name "Basso"'
        # Recording failed - run auto-repair immediately (not in background)
        verify_and_fix_device
        exit 1
    fi

    # Show notification that transcription is happening
    osascript -e 'display notification "Transcribing..." with title "Whisper"'

    _T_CLI=$(date +%s)
    dlog "whisper_cli_start" "model=${MODEL}"
    # Transcribe using whisper-cli
    /opt/homebrew/bin/whisper-cli -m "$MODEL" --no-prints "$AUDIO_FILE" 2>/dev/null | \
        sed 's/^\[.*\] //' | \
        tr -d '\n' | \
        sed 's/^[[:space:]]*//;s/[[:space:]]*$//' > "$TEXT_FILE"
    dlog "whisper_cli_done" "duration_s=$(( $(date +%s) - _T_CLI ))" "text=@${TEXT_FILE}"

    # Apply user dictionary corrections (longest-first). See transcription_corrections.tsv
    CORRECTIONS_FILE="${WHISPER_CORRECTIONS:-$HOME/Documents/claude_projects/whisper/transcription_corrections.tsv}"
    if [ -f "$CORRECTIONS_FILE" ] && [ -s "$TEXT_FILE" ]; then
        dlog "dictionary_apply_start" "file=${CORRECTIONS_FILE}"
        python3 - "$CORRECTIONS_FILE" "$TEXT_FILE" <<'PY'
import re, sys
from pathlib import Path

path = Path(sys.argv[1])
text_path = Path(sys.argv[2])
text = text_path.read_text(encoding="utf-8")
literals = {}
regexes = []
for line in path.read_text(encoding="utf-8").splitlines():
    raw = line.strip()
    if not raw or raw.startswith("#"):
        continue
    if "\t" not in line:
        continue
    wrong, right = line.split("\t", 1)
    if wrong.startswith("re:"):
        # Regex entry: re:pattern<TAB>replacement
        regexes.append((wrong[3:], right))
    else:
        literals[wrong.lower()] = right
# Phase 1: Single-pass literal replacement (longest-first, case-insensitive).
sorted_lits = sorted(literals.keys(), key=len, reverse=True)
if sorted_lits:
    pat = re.compile("|".join(re.escape(w) for w in sorted_lits), re.IGNORECASE)
    text = pat.sub(lambda m: literals[m.group().lower()], text)
# Phase 2: Regex patterns (applied in file order, after literals).
for pattern, replacement in regexes:
    text = re.sub(pattern, replacement, text, flags=re.IGNORECASE)
text_path.write_text(text, encoding="utf-8")
PY
        dlog "dictionary_apply_done" "text=@${TEXT_FILE}"
    fi

    # Append transcription disclaimer (helps AI understand potential errors)
    if [ -s "$TEXT_FILE" ]; then
        echo " [voice transcribed - names/terms may be misheard, ask if unsure]" >> "$TEXT_FILE"
    fi

    # Copy to clipboard
    pbcopy < "$TEXT_FILE"
    dlog "clipboard_copied" "chars=$(wc -c < "$TEXT_FILE" | tr -d ' ')"

    # Get the transcribed text for notification
    RESULT=$(cat "$TEXT_FILE")

    # Auto-paste to focused window using AppleScript
    osascript <<'APPLESCRIPT'
tell application "System Events"
    keystroke "v" using command down
end tell
APPLESCRIPT
    dlog "auto_pasted"

    # Show notification with result
    if [ -z "$RESULT" ]; then
        dlog "batch_empty_result"
        osascript -e 'display notification "No speech detected" with title "Whisper" sound name "Basso"'
    else
        if [ ${#RESULT} -gt 80 ]; then
            DISPLAY_TEXT="${RESULT:0:80}..."
        else
            DISPLAY_TEXT="$RESULT"
        fi
        osascript -e "display notification \"$DISPLAY_TEXT\" with title \"✅ Copied to clipboard\" sound name \"Glass\""
    fi

    # Clean up audio file
    rm -f "$AUDIO_FILE"

    dlog "stop_recording_done" "total_s=$(( $(date +%s) - _T_STOP ))" "chars=${#RESULT}"
    # POST-PASTE: Verify and fix device index for next time (background, no delay)
    verify_and_fix_device &

else
    dlog "usage_error" "arg=${ACTION:-}"
    echo "Usage: whisper.sh start|stop"
    exit 1
fi
