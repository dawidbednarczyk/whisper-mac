#!/usr/bin/env bash
#
# System-wide speech-to-text using whisper.cpp
# Usage: whisper.sh start|stop|toggle|restart-recording|list-devices|list-models|download-model|auth|status
#

set -uo pipefail

WHISPER_VERSION="1.0.0"

# Ensure UTF-8 text handling when launched from minimal environments (e.g. Hammerspoon).
export LANG="${LANG:-en_US.UTF-8}"
export LC_CTYPE="${LC_CTYPE:-en_US.UTF-8}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/whisper-stt.conf"

# shellcheck source=/dev/null
if [ -f "${CONFIG_FILE}" ]; then
    . "${CONFIG_FILE}"
fi

ACTION="${1:-}"

WHISPER_TMPDIR="${TMPDIR:-/tmp}"

# ── Debug logging (mirrors whisper_debug.lua format: JSON lines) ─────────────
# Writes to /tmp/whisper_debug.log and /tmp/whisper_debug/batch_<stamp>.log
# so both Hammerspoon-driven and CLI-driven events land in the same place.
WHISPER_DEBUG_LOG="${WHISPER_DEBUG_LOG:-/tmp/whisper_debug.log}"
WHISPER_DEBUG_DIR="${WHISPER_DEBUG_DIR:-/tmp/whisper_debug}"
mkdir -p "${WHISPER_DEBUG_DIR}" 2>/dev/null || true
WHISPER_BATCH_SID="${WHISPER_BATCH_SID:-$(date +%s)_$$}"
WHISPER_BATCH_LOG="${WHISPER_DEBUG_DIR}/batch_$(date -u +%Y%m%dT%H%M%S)_${WHISPER_BATCH_SID}.log"

# _json_escape <string> — escape for JSON string literal (no surrounding quotes)
_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# dlog <event> [key=value ...] — emit one JSON-line event
# Values are escaped; bare 'k=v' pairs are interpreted as strings.
# Use k=@file to embed the contents of a file (escaped).
dlog() {
    local event="$1"; shift
    local ts
    ts="$(python3 -c "import time,datetime; t=time.time(); print(datetime.datetime.utcfromtimestamp(t).strftime('%Y-%m-%dT%H:%M:%S.')+f'{int((t%1)*1000):03d}Z')" 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%S.000Z)"
    local payload="{\"ts\":\"${ts}\",\"sid\":\"${WHISPER_BATCH_SID}\",\"kind\":\"batch\",\"mod\":\"whisper.sh\",\"event\":\"$(_json_escape "$event")\",\"action\":\"$(_json_escape "${ACTION:-}")\""
    local kv k v
    for kv in "$@"; do
        k="${kv%%=*}"
        v="${kv#*=}"
        if [ "${v:0:1}" = "@" ] && [ -f "${v:1}" ]; then
            local c
            c="$(cat "${v:1}" 2>/dev/null || printf '')"
            payload="${payload},\"${k}\":\"$(_json_escape "$c")\""
        else
            payload="${payload},\"${k}\":\"$(_json_escape "$v")\""
        fi
    done
    payload="${payload}}"
    printf '%s\n' "$payload" >> "$WHISPER_DEBUG_LOG" 2>/dev/null || true
    printf '%s\n' "$payload" >> "$WHISPER_BATCH_LOG" 2>/dev/null || true
}

dlog "script_invoked" "argc=$#" "pid=$$" "whisper_auto_paste=${WHISPER_AUTO_PASTE}"
# ─────────────────────────────────────────────────────────────────────────────

AUDIO_FILE="${WHISPER_AUDIO_FILE:-${WHISPER_TMPDIR}/whisper_recording.wav}"
TEXT_FILE="${WHISPER_TEXT_FILE:-${WHISPER_TMPDIR}/whisper_output.txt}"
PID_FILE="${WHISPER_PID_FILE:-${WHISPER_TMPDIR}/whisper_recording.pid}"
LOG_FILE="${WHISPER_FFMPEG_LOG:-${WHISPER_TMPDIR}/ffmpeg.log}"
ERROR_LOG_FILE="${WHISPER_ERROR_LOG:-${WHISPER_TMPDIR}/whisper-error.log}"

MODEL="${WHISPER_MODEL_PATH:-${SCRIPT_DIR}/models/ggml-medium.bin}"
WHISPER_LANGUAGE="${WHISPER_LANGUAGE:-auto}"
export WHISPER_LANGUAGE  # F1: propagate to background worker via hook → Popen env
WHISPER_TRANSLATE="${WHISPER_TRANSLATE:-0}"
WHISPER_AUTO_PASTE="${WHISPER_AUTO_PASTE:-1}"
MAX_SECONDS="${WHISPER_MAX_SECONDS:-7200}"
WHISPER_HISTORY_FILE="${WHISPER_HISTORY_FILE:-${SCRIPT_DIR}/history.txt}"
TRANSCRIBING_FILE="${WHISPER_TRANSCRIBING_FILE:-${WHISPER_TMPDIR}/whisper_transcribing}"
POSTPROCESSING_FILE="${WHISPER_TMPDIR}/whisper_postprocessing"
WHISPER_HISTORY_MAX="${WHISPER_HISTORY_MAX:-10}"

WHISPER_ARCHIVE_DIR="${WHISPER_ARCHIVE_DIR:-${SCRIPT_DIR}/recordings}"

SEGMENTS_DIR="${WHISPER_TMPDIR}/whisper_segments"
SEGMENT_INDEX_FILE="${WHISPER_TMPDIR}/whisper_segment_index"

WHISPER_NOTIFICATIONS="${WHISPER_NOTIFICATIONS:-1}"
WHISPER_SOUNDS="${WHISPER_SOUNDS:-1}"
WHISPER_HOTKEY_TOGGLE="${WHISPER_HOTKEY_TOGGLE:-shift,cmd,r}"

# Audio input:
# - WHISPER_AUDIO_DEVICE=default follows macOS-selected input
# - WHISPER_AUDIO_DEVICE=<n> uses AVFoundation index
WHISPER_AUDIO_DEVICE="${WHISPER_AUDIO_DEVICE:-${WHISPER_AUDIO_DEVICE_INDEX:-default}}"

# Post-processing mode: off | clean | message | email | prompt | prompt-pro
WHISPER_POST_PROCESS="${WHISPER_POST_PROCESS:-off}"
# Copilot model for post-processing (via /chat/completions).
# Verified working: claude-opus-4.5, claude-opus-4.6, claude-sonnet-4.6,
#   claude-sonnet-4.5, claude-sonnet-4, claude-haiku-4.5, gpt-5.2,
#   gpt-5-mini, gpt-4.1, gpt-4o, gpt-4o-mini, gemini-3-pro-preview,
#   gemini-3-flash-preview
WHISPER_COPILOT_MODEL="${WHISPER_COPILOT_MODEL:-claude-sonnet-4.6}"

# Allow callers to force-disable auto-paste (survives conf sourcing).
# Used by whisper_streaming.lua to retranscribe without pasting (it handles paste itself).
[ "${WHISPER_FORCE_NO_PASTE:-}" = "1" ] && WHISPER_AUTO_PASTE=0

find_bin() {
    local name="$1"
    local brew_path="/opt/homebrew/bin/${name}"
    local usr_local_path="/usr/local/bin/${name}"

    if [ -x "${brew_path}" ]; then
        printf '%s\n' "${brew_path}"
    elif [ -x "${usr_local_path}" ]; then
        printf '%s\n' "${usr_local_path}"
    elif command -v "${name}" >/dev/null 2>&1; then
        command -v "${name}"
    else
        printf '%s\n' ""
    fi
}

FFMPEG_BIN="$(find_bin ffmpeg)"
# Defer whisper-cli lookup until needed (transcription only, not recording start)
WHISPER_BIN=""
resolve_whisper_bin() {
    if [ -z "${WHISPER_BIN}" ]; then
        WHISPER_BIN="$(find_bin whisper-cli)"
    fi
    printf '%s' "${WHISPER_BIN}"
}

# ── Copilot API for post-processing ──────────────────────────────────────────

COPILOT_API_URL="https://api.githubcopilot.com/chat/completions"
COPILOT_CLIENT_ID="Iv1.b507a08c87ecfe98"
WHISPER_AUTH_DIR="${HOME}/.config/careless-whisper"
WHISPER_AUTH_FILE="${WHISPER_AUTH_DIR}/auth.json"
COPILOT_API_HEADERS=(
    -H "Content-Type: application/json"
    -H "Editor-Version: vscode/1.120.0"
    -H "Editor-Plugin-Version: copilot-chat/0.35.0"
    -H "Copilot-Integration-Id: vscode-chat"
)

copilot_device_flow() {
    local device_response
    device_response="$(curl -s -X POST "https://github.com/login/device/code" \
        -H "Accept: application/json" \
        -d "client_id=${COPILOT_CLIENT_ID}&scope=copilot" 2>/dev/null)"

    if [ -z "${device_response}" ]; then
        printf 'ERROR: Could not reach github.com\n' >&2
        return 1
    fi

    local device_code user_code verification_uri interval
    device_code="$(python3 -c "import json,sys; print(json.load(sys.stdin)['device_code'])" <<< "${device_response}" 2>/dev/null)"
    user_code="$(python3 -c "import json,sys; print(json.load(sys.stdin)['user_code'])" <<< "${device_response}" 2>/dev/null)"
    verification_uri="$(python3 -c "import json,sys; print(json.load(sys.stdin)['verification_uri'])" <<< "${device_response}" 2>/dev/null)"
    interval="$(python3 -c "import json,sys; print(json.load(sys.stdin).get('interval', 5))" <<< "${device_response}" 2>/dev/null)"

    if [ -z "${device_code}" ] || [ -z "${user_code}" ]; then
        printf 'ERROR: Unexpected response from GitHub\n' >&2
        return 1
    fi

    # Output code for the caller (Lua reads this)
    printf 'USER_CODE=%s\n' "${user_code}"
    printf 'VERIFICATION_URI=%s\n' "${verification_uri}"

    # Copy to clipboard
    printf '%s' "${user_code}" | pbcopy 2>/dev/null

    # Poll for token
    local max_attempts=60
    local attempt=0
    while [ "${attempt}" -lt "${max_attempts}" ]; do
        sleep "${interval}"
        attempt=$((attempt + 1))

        local token_response
        token_response="$(curl -s -X POST "https://github.com/login/oauth/access_token" \
            -H "Accept: application/json" \
            -d "client_id=${COPILOT_CLIENT_ID}&device_code=${device_code}&grant_type=urn:ietf:params:oauth:grant-type:device_code" 2>/dev/null)"

        local error access_token
        error="$(python3 -c "import json,sys; print(json.load(sys.stdin).get('error', ''))" <<< "${token_response}" 2>/dev/null)"

        if [ "${error}" = "authorization_pending" ]; then
            continue
        elif [ "${error}" = "slow_down" ]; then
            interval=$((interval + 5))
            continue
        elif [ -z "${error}" ]; then
            access_token="$(python3 -c "import json,sys; print(json.load(sys.stdin).get('access_token', ''))" <<< "${token_response}" 2>/dev/null)"
            if [ -n "${access_token}" ] && [ "${#access_token}" -gt 10 ]; then
                mkdir -p "${WHISPER_AUTH_DIR}"
                python3 -c "
import json, sys
with open(sys.argv[1], 'w') as f:
    json.dump({'access_token': sys.argv[2]}, f)
" "${WHISPER_AUTH_FILE}" "${access_token}"
                chmod 600 "${WHISPER_AUTH_FILE}"
                printf 'AUTH_OK\n'
                return 0
            fi
        else
            printf 'ERROR: %s\n' "${error}" >&2
            return 1
        fi
    done

    printf 'ERROR: Timed out\n' >&2
    return 1
}

resolve_copilot_token() {
    if [ -n "${GITHUB_COPILOT_TOKEN:-}" ]; then
        printf '%s' "${GITHUB_COPILOT_TOKEN}"
        return 0
    fi

    # Check careless-whisper auth file (from install.sh device flow)
    local auth_file="${HOME}/.config/careless-whisper/auth.json"
    if [ -f "${auth_file}" ]; then
        local token
        token="$(python3 -c "
import json, sys
data = json.load(open(sys.argv[1]))
print(data.get('access_token', ''))
" "${auth_file}" 2>/dev/null || true)"
        if [ -n "${token}" ] && [ "${#token}" -gt 10 ]; then
            printf '%s' "${token}"
            return 0
        fi
    fi

    return 1
}

post_process_prompt() {
    local mode="$1"
    case "${mode}" in
        clean)
            cat <<'PROMPT'
You are a transcript cleaner. Your job is to take raw speech-to-text output and clean it up.

Rules:
- Remove filler words (um, uh, äh, also, halt, quasi, sozusagen, basically, like, you know, irgendwie, eigentlich, eben, ja, naja, ne)
- Remove conversation markers that carry no content (e.g. "Okay", "Alles klar", "Genau", "So", "Ja", "Right", "Sure") — especially at sentence beginnings and endings
- Remove stutters and word-level repetitions ("ich habe ich habe" → "ich habe")
- Fix broken sentence structure from natural speech jumps
- Fix punctuation where whisper got it wrong (missing periods, misplaced commas)
- Remove incomplete sentence fragments at the very beginning or end of the transcript (caused by recording start/stop cutting mid-sentence)
- Keep the original meaning, tone, and style — do NOT rewrite or formalize
- Keep the original language (German stays German, English stays English)

Whisper hallucinations:
- whisper.cpp sometimes hallucinates phantom text from silence or noise. Remove obvious hallucinations like "Vielen Dank für's Zuschauen", "Untertitel von...", "Thank you for watching", "Bis zum nächsten Mal", or any text that clearly does not match spoken content
- Also remove repetitive looping phrases that whisper generates when audio is unclear

Spelling hints in speech:
- The speaker sometimes spells out letters to clarify a technical term (e.g. "ISE I-S-E", "MAP, also M-A-B")
- The spelled letters ALWAYS override the preceding word. Combine the letters into the correct term: M-A-B → MAB, I-S-E → ISE
- The spoken word before the spelling may be WRONG (speech-to-text error). Always trust the spelled version.
- REMOVE the spelled-out letters and any bridging words ("also", "ist", "meaning") from the output

- Preserve technical terms, names, and numbers using corrected spellings
- Output ONLY the cleaned text, nothing else — no explanations, no quotes
PROMPT
            ;;
        message)
            cat <<'PROMPT'
You are a business message optimizer. Take raw speech-to-text output and turn it into a clean, concise message suitable for Slack, Teams, or WebEx chat.

Rules:
- Make it clear, concise, and well-structured
- Use short paragraphs or bullet points where appropriate
- Do NOT insert empty lines (paragraph breaks) between sections. On messaging platforms, people write in compact blocks. Use a single line break at most to separate a closing question or call-to-action, but never double newlines.
- Keep the original language (German stays German, English stays English)
- Keep a professional but approachable tone
- NEVER use AI-typical punctuation or phrasing: no semicolons (;), no em dashes (—), no en dashes (–), no colons for emphasis. Use commas, periods. Use normal dashes (-) only when it's connecting two words together. Write like a normal person typing, not like a language model.

Spelling hints in speech:
- The speaker sometimes spells out letters to clarify a technical term (e.g. "ISE I-S-E", "MAP, also M-A-B")
- The spelled letters ALWAYS override the preceding word. Combine the letters into the correct term: M-A-B → MAB, I-S-E → ISE
- The spoken word before the spelling may be WRONG (speech-to-text error). Always trust the spelled version.
- REMOVE the spelled-out letters and any bridging words ("also", "ist", "meaning") from the output

- Preserve technical terms, names, and numbers using corrected spellings
- Output ONLY the message text, nothing else — no explanations, no quotes
PROMPT
            ;;
        email)
            cat <<'PROMPT'
You are a professional email writer. Take raw speech-to-text output and rewrite it as a polished professional email body.

Rules:
- Extract the INTENT and KEY INFORMATION from the rambling speech — do not just clean up the wording
- Rewrite into clear, professional prose — this should read like a well-written email, not like someone talking
- Write like a real person: warm, direct, and natural. Avoid stiff or formulaic phrasing that sounds AI-generated. Vary sentence length. Use the kind of language a competent professional would actually write.
- Add an appropriate greeting (e.g. "Hallo Frank,") based on names mentioned
- Do NOT add a sign-off, closing, or signature (no "Viele Grüße", "Best regards", etc.) — the user's email client appends a signature automatically
- Structure with short, clear paragraphs
- Keep the original language (German stays German, English stays English)
- Use a professional, polite, but not overly formal tone
- NEVER use AI-typical punctuation or phrasing: no semicolons (;), no em dashes (—), no en dashes (–), no colons for emphasis. Use commas, periods. Use normal dashes (-) only when it's connecting two words together. Write like a normal person typing, not like a language model.

Spelling hints in speech:
- The speaker sometimes spells out letters to clarify a technical term (e.g. "ISE I-S-E", "MAP, also M-A-B")
- The spelled letters ALWAYS override the preceding word. Combine the letters into the correct term: M-A-B → MAB, I-S-E → ISE
- The spoken word before the spelling may be WRONG (speech-to-text error). Always trust the spelled version.
- REMOVE the spelled-out letters and any bridging words ("also", "ist", "meaning") from the output
- The relevant word is typically within 5-10 words before the spelling

- Preserve technical terms, product names, and numbers using the corrected spellings
- Do NOT invent a subject line — only the email body
- Output ONLY the email text, nothing else — no explanations, no quotes
PROMPT
            ;;
        prompt)
            cat <<'PROMPT'
You are a prompt reformulator. The user dictated a prompt for an AI assistant using speech-to-text. Your job is to clean up and restructure the spoken input so it works well as a prompt, while keeping the original intent fully intact.

Rules:
- Keep the user's intent, meaning, and level of detail exactly as spoken
- Restructure rambling speech into clear, direct instructions
- Fix grammar, remove filler words, and clean up speech artifacts
- Use clear, natural language — do NOT add prompt engineering patterns (no "You are a...", no "Act as...", no role definitions, no constraints the user didn't mention)
- If the user mentioned specific requirements, keep them all — do not drop or summarize away details
- Keep the original language (German stays German, English stays English)
- Do NOT add anything the user didn't say — no extra context, no assumptions, no embellishments
- You MAY use any formatting that helps AI models parse the prompt effectively (markdown headers, em dashes, bullet points, etc.) — the output is for AI consumption, not human reading

Spelling hints in speech:
- The speaker sometimes spells out letters to clarify a technical term (e.g. "ISE I-S-E", "MAP, also M-A-B")
- The spelled letters ALWAYS override the preceding word. Combine the letters into the correct term: M-A-B → MAB, I-S-E → ISE
- The spoken word before the spelling may be WRONG (speech-to-text error). Always trust the spelled version.
- REMOVE the spelled-out letters and any bridging words ("also", "ist", "meaning") from the output

- Output ONLY the cleaned prompt, nothing else — no explanations, no quotes, no meta-commentary
PROMPT
            ;;
        prompt-pro)
            cat <<'PROMPT'
You are an expert prompt engineer. The user dictated a rough idea or request using speech-to-text. Your job is to transform it into a well-structured, effective prompt following prompt engineering best practices.

Rules:
- Extract the core INTENT and REQUIREMENTS from the spoken input
- Rewrite into a professional, well-structured prompt that will get the best results from an LLM
- Apply prompt engineering best practices:
  - Add an appropriate role/persona ("You are a senior [relevant role] with deep expertise in [domain]...")
  - Define clear objectives and expected output format
  - Add relevant constraints (conciseness, tone, scope) that fit the request
  - Structure with clear sections if the task is complex
- Do NOT invent requirements the user didn't mention — enhance the structure and framing, not the scope
- Keep the original language (German stays German, English stays English)
- Use any formatting that helps AI models parse the prompt effectively (markdown headers, em dashes, bullet points, etc.) — the output is for AI consumption
- Match the complexity of the enhanced prompt to the complexity of the request — a simple question gets a concise enhanced prompt, not a 500-word framework

Spelling hints in speech:
- The speaker sometimes spells out letters to clarify a technical term (e.g. "ISE I-S-E", "MAP, also M-A-B")
- The spelled letters ALWAYS override the preceding word. Combine the letters into the correct term: M-A-B → MAB, I-S-E → ISE
- The spoken word before the spelling may be WRONG (speech-to-text error). Always trust the spelled version.
- REMOVE the spelled-out letters and any bridging words ("also", "ist", "meaning") from the output

- Output ONLY the enhanced prompt, nothing else — no explanations, no quotes, no meta-commentary
PROMPT
            ;;
        *)
            printf 'Unknown post-processing mode: %s\n' "${mode}" >&2
            return 1
            ;;
    esac
}

post_process_text() {
    local mode="${WHISPER_POST_PROCESS}"

    if [ "${mode}" = "off" ] || [ -z "${mode}" ]; then
        return 0
    fi

    local raw_text
    raw_text="$(cat "${TEXT_FILE}" 2>/dev/null || true)"
    if [ -z "${raw_text}" ]; then
        return 0
    fi

    local token
    if ! token="$(resolve_copilot_token)"; then
        notify "Whisper" "Post-processing skipped — no Copilot token" ""
        return 0
    fi

    local system_prompt
    system_prompt="$(post_process_prompt "${mode}")"

    # Build JSON payload — use python3 for safe escaping
    local payload
    payload="$(python3 -c "
import json, sys
print(json.dumps({
    'model': sys.argv[3],
    'messages': [
        {'role': 'system', 'content': sys.argv[1]},
        {'role': 'user', 'content': sys.argv[2]}
    ],
    'max_tokens': 4096,
    'temperature': 0.2
}))
" "${system_prompt}" "${raw_text}" "${WHISPER_COPILOT_MODEL}" 2>/dev/null)"

    if [ -z "${payload}" ]; then
        notify "Whisper" "Post-processing failed — payload error" "Basso"
        return 1
    fi

    local response http_code
    local max_retries=3
    local attempt=0

    while [ "${attempt}" -lt "${max_retries}" ]; do
        attempt=$((attempt + 1))

        response="$(curl -s --max-time 120 -w '\n%{http_code}' \
            -H "Authorization: Bearer ${token}" \
            "${COPILOT_API_HEADERS[@]}" \
            -d "${payload}" \
            "${COPILOT_API_URL}" 2>/dev/null)"

        http_code="$(tail -n1 <<< "${response}")"
        response="$(sed '$ d' <<< "${response}")"

        # Success
        if [ "${http_code}" = "200" ] && [ -n "${response}" ]; then
            break
        fi

        # Token expired or revoked — no point retrying
        if [ "${http_code}" = "401" ]; then
            rm -f "${WHISPER_AUTH_FILE}"
            notify "Whisper" "Copilot token expired — sign in again via menubar" "Basso"
            return 1
        fi

        # Rate limit (403) or empty response or other transient error — retry
        if [ "${attempt}" -lt "${max_retries}" ]; then
            sleep $((3 * attempt))
        fi
    done

    if [ -z "${response}" ]; then
        notify "Whisper" "Post-processing failed — no API response after ${max_retries} attempts" "Basso"
        return 1
    fi

    # Persistent 403 after retries — likely token issue, not just rate limit
    if [ "${http_code}" = "403" ]; then
        rm -f "${WHISPER_AUTH_FILE}"
        notify "Whisper" "Copilot token expired — sign in again via menubar" "Basso"
        return 1
    fi

    local processed
    processed="$(python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
choices = data.get('choices', [])
if choices:
    print(choices[0].get('message', {}).get('content', ''))
" <<< "${response}" 2>/dev/null)"

    if [ -n "${processed}" ]; then
        printf '%s' "${processed}" > "${TEXT_FILE}"
    else
        notify "Whisper" "Post-processing failed — using raw transcript" "Basso"
    fi
}

notify() {
    [ "${WHISPER_NOTIFICATIONS}" = "0" ] && return 0

    local title="$1"
    local message="$2"
    local sound="${3:-}"
    local escaped

    [ "${WHISPER_SOUNDS}" = "0" ] && sound=""

    escaped="$(printf '%s' "${message}" | sed 's/\\/\\\\/g; s/"/\\"/g')"

    if [ -n "${sound}" ]; then
        osascript -e "display notification \"${escaped}\" with title \"${title}\" sound name \"${sound}\"" >/dev/null 2>&1 || true
    else
        osascript -e "display notification \"${escaped}\" with title \"${title}\"" >/dev/null 2>&1 || true
    fi
}

paste_clipboard() {
    osascript -e 'tell application "System Events" to keystroke "v" using command down' >/dev/null 2>&1 || true
}

copy_to_clipboard() {
    local source_file="$1"

    # Primary path: force UTF-8 interpretation via AppleScript read.
    if osascript -e "set the clipboard to (read POSIX file \"${source_file}\" as «class utf8»)" >/dev/null 2>&1; then
        return 0
    fi

    # Fallback path in case AppleScript clipboard write fails.
    pbcopy < "${source_file}" 2>/dev/null
}

append_to_history() {
    local text="$1"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

    mkdir -p "$(dirname "${WHISPER_HISTORY_FILE}")"
    printf '[%s] %s\n' "${timestamp}" "${text}" >> "${WHISPER_HISTORY_FILE}"

    # Rolling GC: keep only the last N entries
    local tmp
    tmp="$(tail -n "${WHISPER_HISTORY_MAX}" "${WHISPER_HISTORY_FILE}")"
    printf '%s\n' "${tmp}" > "${WHISPER_HISTORY_FILE}"
}

trim_text_file() {
    if [ -f "${TEXT_FILE}" ]; then
        sed -i '' 's/^[[:space:]]*//;s/[[:space:]]*$//' "${TEXT_FILE}" 2>/dev/null || true
    fi
}

archive_audio() {
    if [ ! -f "${AUDIO_FILE}" ] || [ ! -s "${AUDIO_FILE}" ]; then
        return 0
    fi

    mkdir -p "${WHISPER_ARCHIVE_DIR}"
    local ts
    ts="$(date '+%Y%m%d_%H%M%S')"
    local dest="${WHISPER_ARCHIVE_DIR}/${ts}.wav"
    cp "${AUDIO_FILE}" "${dest}" 2>/dev/null || true
    # Export so the transcription-log hook can reference the archived path.
    WHISPER_LAST_ARCHIVED="${dest}"
    export WHISPER_LAST_ARCHIVED
}

latest_archived_audio() {
    if [ ! -d "${WHISPER_ARCHIVE_DIR}" ]; then
        return 1
    fi
    ls -1t "${WHISPER_ARCHIVE_DIR}"/*.wav 2>/dev/null | head -1
}

cleanup_stale_pid_file() {
    [ ! -f "${PID_FILE}" ] && return 0

    local pid
    pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
    if [ -z "${pid}" ] || ! kill -0 "${pid}" 2>/dev/null; then
        rm -f "${PID_FILE}"
    fi
}

cleanup_stale_transcribing_file() {
    [ ! -f "${TRANSCRIBING_FILE}" ] && return 0

    local file_mtime now file_age max_age=600
    file_mtime="$(stat -f '%m' "${TRANSCRIBING_FILE}" 2>/dev/null || echo 0)"
    now="$(date +%s)"
    file_age=$(( now - file_mtime ))

    if [ "${file_age}" -gt "${max_age}" ]; then
        rm -f "${TRANSCRIBING_FILE}"
    fi
}

current_segment_file() {
    local idx
    idx="$(cat "${SEGMENT_INDEX_FILE}" 2>/dev/null || echo 1)"
    printf '%s/segment_%03d.wav\n' "${SEGMENTS_DIR}" "${idx}"
}

next_segment_index() {
    local idx
    idx="$(cat "${SEGMENT_INDEX_FILE}" 2>/dev/null || echo 1)"
    printf '%s\n' "$(( idx + 1 ))" > "${SEGMENT_INDEX_FILE}"
}

concat_segments() {
    local -a valid_segments=()
    for seg in "${SEGMENTS_DIR}"/segment_*.wav; do
        [ -f "${seg}" ] && [ -s "${seg}" ] && valid_segments+=("${seg}")
    done

    if [ "${#valid_segments[@]}" -eq 0 ]; then
        return 1
    elif [ "${#valid_segments[@]}" -eq 1 ]; then
        mv "${valid_segments[0]}" "${AUDIO_FILE}"
    else
        local concat_list="${WHISPER_TMPDIR}/whisper_concat.txt"
        rm -f "${concat_list}"
        for seg in "${valid_segments[@]}"; do
            printf "file '%s'\n" "${seg}" >> "${concat_list}"
        done
        if ! "${FFMPEG_BIN}" -f concat -safe 0 -i "${concat_list}" -c copy -y "${AUDIO_FILE}" >/dev/null 2>&1; then
            rm -f "${concat_list}"
            return 1
        fi
        rm -f "${concat_list}"
    fi
}

recording_running() {
    cleanup_stale_pid_file
    if [ ! -f "${PID_FILE}" ]; then
        return 1
    fi

    local pid
    pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
    [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null
}

resolve_audio_input() {
    printf '%s\n' "${WHISPER_AUDIO_DEVICE}"
}

language_allowed_for_model() {
    local model_basename
    model_basename="$(basename "${MODEL}")"

    if [[ "${model_basename}" == *.en.bin ]]; then
        case "${WHISPER_LANGUAGE}" in
            en|english) return 0 ;;
            *)          return 1 ;;
        esac
    fi

    return 0
}

preflight_check_recording() {
    if [ -z "${FFMPEG_BIN}" ]; then
        notify "Whisper" "ffmpeg not found (install with Homebrew)" "Basso"
        printf 'ffmpeg not found\n' >&2
        exit 1
    fi

    if ! [[ "${MAX_SECONDS}" =~ ^[0-9]+$ ]]; then
        notify "Whisper" "WHISPER_MAX_SECONDS must be a number" "Basso"
        printf 'Invalid WHISPER_MAX_SECONDS: %s\n' "${MAX_SECONDS}" >&2
        exit 1
    fi
}

preflight_check() {
    preflight_check_recording

    resolve_whisper_bin >/dev/null
    if [ -z "${WHISPER_BIN}" ]; then
        notify "Whisper" "whisper-cli not found (install with Homebrew)" "Basso"
        printf 'whisper-cli not found\n' >&2
        exit 1
    fi

    if [ ! -f "${MODEL}" ]; then
        notify "Whisper" "Model missing at ${MODEL}" "Basso"
        printf 'Model missing: %s\n' "${MODEL}" >&2
        exit 1
    fi

    if ! language_allowed_for_model; then
        notify "Whisper" "Model is English-only. Use ggml-medium.bin for auto/de" "Basso"
        printf 'Model %s is English-only, but language is %s\n' "${MODEL}" "${WHISPER_LANGUAGE}" >&2
        exit 1
    fi
}

start_recording() {
    dlog "start_recording" "device=${WHISPER_AUDIO_DEVICE}" "max_seconds=${MAX_SECONDS}"
    preflight_check_recording

    if recording_running; then
        dlog "start_abort" "reason=already_running"
        notify "Whisper" "Recording already in progress" "Basso"
        return 1
    fi

    rm -f "${AUDIO_FILE}" "${TEXT_FILE}" "${PID_FILE}"
    rm -rf "${SEGMENTS_DIR}" "${SEGMENT_INDEX_FILE}"
    mkdir -p "${SEGMENTS_DIR}"
    printf '1\n' > "${SEGMENT_INDEX_FILE}"

    local segment_file
    segment_file="$(current_segment_file)"
    local audio_input
    audio_input="$(resolve_audio_input)"

    # Launch ffmpeg FIRST — every millisecond counts for capturing the first words
    nohup "${FFMPEG_BIN}" \
        -f avfoundation \
        -i ":${audio_input}" \
        -t "${MAX_SECONDS}" \
        -ar 16000 \
        -ac 1 \
        -y "${segment_file}" >"${LOG_FILE}" 2>&1 &

    printf '%s\n' "$!" > "${PID_FILE}"

    # Notification runs in background so it doesn't block the verification sleep
    {
        local hotkey_display
        hotkey_display="$(printf '%s' "${WHISPER_HOTKEY_TOGGLE}" | sed 's/,/+/g' | tr '[:lower:]' '[:upper:]')"
        notify "Whisper" "Recording... press ${hotkey_display} again to stop" "Blow"
    } &

    sleep 0.6

    if ! recording_running; then
        local reason
        reason="$(tail -n 1 "${LOG_FILE}" 2>/dev/null || true)"
        dlog "start_failed" "reason=${reason}"
        notify "Whisper" "Start failed. Check ${LOG_FILE}" "Basso"
        [ -n "${reason}" ] && printf 'ffmpeg start error: %s\n' "${reason}" >&2
        return 1
    fi
    dlog "start_recording_confirmed" "pid=$(cat "${PID_FILE}" 2>/dev/null || echo '?')"
}

stop_recording() {
    dlog "stop_recording"
    local _t_stop=$(date +%s)
    preflight_check

    if ! recording_running; then
        notify "Whisper" "No recording in progress" "Basso"
        return 1
    fi

    local pid
    pid="$(cat "${PID_FILE}" 2>/dev/null || true)"

    if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
        kill -INT "${pid}" 2>/dev/null || true
        for _ in $(seq 1 30); do
            if ! kill -0 "${pid}" 2>/dev/null; then
                break
            fi
            sleep 0.1
        done
        # Force-kill if still running to prevent orphan ffmpeg processes
        kill -0 "${pid}" 2>/dev/null && kill -9 "${pid}" 2>/dev/null || true
    fi

    rm -f "${PID_FILE}"
    touch "${TRANSCRIBING_FILE}"

    sleep 0.3

    if ! concat_segments; then
        rm -f "${TRANSCRIBING_FILE}"
        rm -rf "${SEGMENTS_DIR}" "${SEGMENT_INDEX_FILE}"
        notify "Whisper" "No audio recorded. Check microphone settings." "Basso"
        return 1
    fi

    if [ ! -f "${AUDIO_FILE}" ] || [ ! -s "${AUDIO_FILE}" ]; then
        rm -f "${TRANSCRIBING_FILE}"
        rm -rf "${SEGMENTS_DIR}" "${SEGMENT_INDEX_FILE}"
        notify "Whisper" "No audio recorded. Check microphone settings." "Basso"
        return 1
    fi

    archive_audio
    dlog "audio_archived" "file=${AUDIO_FILE}" "stop_duration_s=$(( $(date +%s) - _t_stop ))"

    notify "Whisper" "Transcribing..." ""

    local -a cmd
    cmd=("${WHISPER_BIN}" -m "${MODEL}" --no-prints -l "${WHISPER_LANGUAGE}")
    if [ "${WHISPER_TRANSLATE}" = "1" ]; then
        cmd+=(-tr)
    fi
    cmd+=("${AUDIO_FILE}")
    local _t_cli=$(date +%s)
    dlog "whisper_cli_start" "model=${MODEL}" "lang=${WHISPER_LANGUAGE}" "translate=${WHISPER_TRANSLATE}"
    if ! "${cmd[@]}" 2>"${ERROR_LOG_FILE}" | sed 's/^\[.*\] //' | tr '\n' ' ' | sed 's/  */ /g' > "${TEXT_FILE}"; then
        rm -f "${TRANSCRIBING_FILE}"
        local err
        err="$(tail -n 1 "${ERROR_LOG_FILE}" 2>/dev/null || true)"
        dlog "whisper_cli_failed" "err=${err}" "duration_s=$(( $(date +%s) - _t_cli ))"
        notify "Whisper" "Transcription failed. Check ${ERROR_LOG_FILE}" "Basso"
        [ -n "${err}" ] && printf 'whisper error: %s\n' "${err}" >&2
        return 1
    fi
    dlog "whisper_cli_done" "duration_s=$(( $(date +%s) - _t_cli ))"
    rm -f "${TRANSCRIBING_FILE}"

    trim_text_file
    dlog "batch_raw_text" "text=@${TEXT_FILE}"

    # Post-process via Copilot API if enabled
    if [ "${WHISPER_POST_PROCESS}" != "off" ] && [ -n "${WHISPER_POST_PROCESS}" ]; then
        touch "${POSTPROCESSING_FILE}"
        notify "Whisper" "Post-processing (${WHISPER_POST_PROCESS})..." ""
        local _t_pp=$(date +%s)
        dlog "postprocess_start" "mode=${WHISPER_POST_PROCESS}" "model=${WHISPER_COPILOT_MODEL}"
        post_process_text
        dlog "postprocess_done" "duration_s=$(( $(date +%s) - _t_pp ))" "text=@${TEXT_FILE}"
        rm -f "${POSTPROCESSING_FILE}"
    fi

    local result preview
    result="$(cat "${TEXT_FILE}" 2>/dev/null || true)"

    if [ -n "${result}" ]; then
        dlog "batch_final" "chars=${#result}" "auto_paste=${WHISPER_AUTO_PASTE}" "text=@${TEXT_FILE}"
        append_to_history "${result}"

        # ── Transcription log hook (non-blocking, fire-and-forget) ─────────────
        # Forwards (t0=button-click, archived_wav, model, duration_ms, text_file)
        # to the local transcription-log manager. Never blocks the paste path.
        if [ -n "${WHISPER_LAST_ARCHIVED:-}" ] && [ -x "${WHISPER_HOME:-$HOME/whisper-mac}/bin/whisper_log_hook.sh" ]; then
            _wlh_now_ms=$(python3 -c "import time;print(int(time.time()*1000))" 2>/dev/null || echo 0)
            _wlh_dur_ms=$(( _wlh_now_ms - _t_stop * 1000 ))
            _wlh_model="$(basename "${MODEL}")"
            (
                "${WHISPER_HOME:-$HOME/whisper-mac}/bin/whisper_log_hook.sh" \
                    "${_t_stop}" \
                    "${WHISPER_LAST_ARCHIVED}" \
                    "${_wlh_model}" \
                    "${_wlh_dur_ms}" \
                    "${TEXT_FILE}" \
                    "" ""
            ) >/dev/null 2>&1 &
        fi
        # ───────────────────────────────────────────────────────────────────────

        if ! copy_to_clipboard "${TEXT_FILE}"; then
            dlog "clipboard_copy_failed"
            notify "Whisper" "Clipboard copy failed" "Basso"
            return 1
        fi

        if [ "${WHISPER_AUTO_PASTE}" = "1" ]; then
            paste_clipboard
            dlog "auto_pasted"
        fi

        if [ "${#result}" -gt 80 ]; then
            preview="${result:0:80}..."
        else
            preview="${result}"
        fi

        notify "Whisper copied" "${preview}" "Glass"
    else
        dlog "batch_empty_result"
        notify "Whisper" "No speech detected" "Basso"
    fi

    check_audio_levels

    dlog "stop_recording_done" "total_s=$(( $(date +%s) - _t_stop ))"
    rm -f "${AUDIO_FILE}"
    rm -rf "${SEGMENTS_DIR}" "${SEGMENT_INDEX_FILE}"
}

check_audio_levels() {
    [ -z "${FFMPEG_BIN}" ] && return 0

    local latest
    latest="$(latest_archived_audio 2>/dev/null)"
    [ -z "${latest}" ] || [ ! -f "${latest}" ] && return 0

    local vol_info
    vol_info="$("${FFMPEG_BIN}" -i "${latest}" -af volumedetect -f null /dev/null 2>&1)"

    local mean_vol
    mean_vol="$(printf '%s\n' "${vol_info}" | sed -n 's/.*mean_volume: \([-0-9.]*\) dB.*/\1/p')"
    [ -z "${mean_vol}" ] && return 0

    local threshold=-55
    local below
    below="$(python3 -c "print(1 if float('${mean_vol}') < ${threshold} else 0)" 2>/dev/null || echo 0)"

    if [ "${below}" = "1" ]; then
        local device_name="input ${WHISPER_AUDIO_DEVICE}"
        if [[ "${WHISPER_AUDIO_DEVICE}" =~ ^[0-9]+$ ]]; then
            device_name="$("${FFMPEG_BIN}" -f avfoundation -list_devices true -i "" 2>&1 \
                | sed -n '/AVFoundation audio devices/,$ s/.*\] \[\([0-9]*\)\] \(.*\)/\1 \2/p' \
                | sed -n "s/^${WHISPER_AUDIO_DEVICE} //p" 2>/dev/null || true)"
            [ -z "${device_name}" ] && device_name="device ${WHISPER_AUDIO_DEVICE}"
        fi

        notify "Whisper ⚠️" "Mic silent (${mean_vol} dB) — check ${device_name}" "Basso"
    fi
}

toggle_recording() {
    cleanup_stale_transcribing_file

    if [ -f "${TRANSCRIBING_FILE}" ]; then
        notify "Whisper" "Transcription in progress — please wait" "Basso"
        return 0
    fi

    if recording_running; then
        stop_recording
    else
        start_recording
    fi
}

restart_recording() {
    if ! recording_running; then
        return 1
    fi

    local pid
    pid="$(cat "${PID_FILE}" 2>/dev/null || true)"

    if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
        kill -INT "${pid}" 2>/dev/null || true
        for _ in $(seq 1 30); do
            if ! kill -0 "${pid}" 2>/dev/null; then
                break
            fi
            sleep 0.1
        done
        kill -0 "${pid}" 2>/dev/null && kill -9 "${pid}" 2>/dev/null || true
    fi
    rm -f "${PID_FILE}"

    sleep 0.3

    next_segment_index
    local segment_file
    segment_file="$(current_segment_file)"
    local audio_input
    audio_input="$(resolve_audio_input)"

    nohup "${FFMPEG_BIN}" \
        -f avfoundation \
        -i ":${audio_input}" \
        -t "${MAX_SECONDS}" \
        -ar 16000 \
        -ac 1 \
        -y "${segment_file}" >"${LOG_FILE}" 2>&1 &

    printf '%s\n' "$!" > "${PID_FILE}"
    sleep 0.6

    if ! recording_running; then
        notify "Whisper" "Device changed but new input failed" "Basso"
        return 1
    fi

    notify "Whisper" "Audio input changed — recording continues" ""
}

status() {
    if [ -f "${POSTPROCESSING_FILE}" ]; then
        printf 'postprocessing: yes\n'
    elif [ -f "${TRANSCRIBING_FILE}" ]; then
        printf 'transcribing: yes\n'
    elif recording_running; then
        printf 'recording: running\n'
    else
        printf 'recording: stopped\n'
    fi

    printf 'model: %s\n' "${MODEL}"
    printf 'language: %s\n' "${WHISPER_LANGUAGE}"
    printf 'version: %s\n' "${WHISPER_VERSION}"
}

list_devices() {
    if [ -z "${FFMPEG_BIN}" ]; then
        printf 'ffmpeg not found\n' >&2
        exit 1
    fi

    "${FFMPEG_BIN}" -f avfoundation -list_devices true -i "" 2>&1 | sed -n '/AVFoundation audio devices/,+24p'
}

list_available_models() {
    local installed_models
    installed_models="$(ls "${SCRIPT_DIR}/models/"*.bin 2>/dev/null | xargs -I{} basename {} || true)"

    local all_models="ggml-large-v3-turbo.bin
ggml-large-v3.bin
ggml-medium.bin
ggml-small.bin
ggml-base.bin
ggml-tiny.bin"

    while IFS= read -r model; do
        if printf '%s\n' "${installed_models}" | grep -qx "${model}"; then
            printf 'installed:%s\n' "${model}"
        else
            printf 'available:%s\n' "${model}"
        fi
    done <<< "${all_models}"
}

download_model() {
    local model_name="${2:-}"
    if [ -z "${model_name}" ]; then
        printf 'Usage: %s download-model <model-name.bin>\n' "$0" >&2
        exit 1
    fi

    # Validate model name
    if ! printf '%s' "${model_name}" | grep -qE '^ggml-[a-z0-9.-]+\.bin$'; then
        printf 'Invalid model name: %s\n' "${model_name}" >&2
        exit 1
    fi

    local model_path="${SCRIPT_DIR}/models/${model_name}"
    if [ -f "${model_path}" ]; then
        printf 'already_exists\n'
        exit 0
    fi

    mkdir -p "${SCRIPT_DIR}/models"
    local url="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${model_name}"

    notify "Whisper" "Downloading ${model_name}..." ""
    printf 'downloading:%s\n' "${model_name}"

    if curl -L --fail --silent --show-error --output "${model_path}.part" "${url}" 2>&1; then
        mv "${model_path}.part" "${model_path}"
        printf 'done:%s\n' "${model_name}"
        notify "Whisper" "Model ${model_name} downloaded" "Glass"
    else
        rm -f "${model_path}.part"
        printf 'failed:%s\n' "${model_name}" >&2
        notify "Whisper" "Download failed for ${model_name}" "Basso"
        exit 1
    fi
}

retranscribe() {
    dlog "retranscribe_start"
    local _t_start=$(date +%s)
    # Bug #3 fix (rpi/transcription-pipeline-consistency): retranscribe runs ~30-60s
    # after user trigger; auto-pasting at that point hits the wrong window.
    # Force notify-only regardless of WHISPER_AUTO_PASTE env.
    WHISPER_AUTO_PASTE=0
    preflight_check

    if recording_running; then
        dlog "retranscribe_abort" "reason=recording_running"
        notify "Whisper" "Cannot retranscribe while recording" "Basso"
        return 1
    fi

    local archived
    archived="$(latest_archived_audio)"
    if [ -z "${archived}" ] || [ ! -f "${archived}" ]; then
        dlog "retranscribe_abort" "reason=no_archived"
        notify "Whisper" "No archived recordings found" "Basso"
        return 1
    fi

    local basename
    basename="$(basename "${archived}")"
    dlog "retranscribe_source" "file=${basename}" "path=${archived}"
    notify "Whisper" "Re-transcribing ${basename}..." ""

    touch "${TRANSCRIBING_FILE}"

    cp "${archived}" "${AUDIO_FILE}"

    local -a cmd
    cmd=("${WHISPER_BIN}" -m "${MODEL}" --no-prints -l "${WHISPER_LANGUAGE}")
    if [ "${WHISPER_TRANSLATE}" = "1" ]; then
        cmd+=(-tr)
    fi
    cmd+=("${AUDIO_FILE}")
    local _t_cli=$(date +%s)
    dlog "whisper_cli_start" "model=${MODEL}" "lang=${WHISPER_LANGUAGE}" "translate=${WHISPER_TRANSLATE}"
    if ! "${cmd[@]}" 2>"${ERROR_LOG_FILE}" | sed 's/^\[.*\] //' | tr '\n' ' ' | sed 's/  */ /g' > "${TEXT_FILE}"; then
        rm -f "${TRANSCRIBING_FILE}" "${AUDIO_FILE}"
        local err
        err="$(tail -n 1 "${ERROR_LOG_FILE}" 2>/dev/null || true)"
        dlog "whisper_cli_failed" "err=${err}" "duration_s=$(( $(date +%s) - _t_cli ))"
        notify "Whisper" "Re-transcription failed. Check ${ERROR_LOG_FILE}" "Basso"
        [ -n "${err}" ] && printf 'whisper error: %s\n' "${err}" >&2
        return 1
    fi
    dlog "whisper_cli_done" "duration_s=$(( $(date +%s) - _t_cli ))"
    rm -f "${TRANSCRIBING_FILE}"

    trim_text_file
    dlog "retranscribe_raw_text" "text=@${TEXT_FILE}"

    if [ "${WHISPER_POST_PROCESS}" != "off" ] && [ -n "${WHISPER_POST_PROCESS}" ]; then
        touch "${POSTPROCESSING_FILE}"
        dlog "postprocess_start" "mode=${WHISPER_POST_PROCESS}" "model=${WHISPER_COPILOT_MODEL}"
        notify "Whisper" "Post-processing (${WHISPER_POST_PROCESS})..." ""
        local _t_pp=$(date +%s)
        post_process_text
        dlog "postprocess_done" "duration_s=$(( $(date +%s) - _t_pp ))" "text=@${TEXT_FILE}"
        rm -f "${POSTPROCESSING_FILE}"
    fi

    local result preview
    result="$(cat "${TEXT_FILE}" 2>/dev/null || true)"

    if [ -n "${result}" ]; then
        dlog "retranscribe_final" "chars=${#result}" "auto_paste=${WHISPER_AUTO_PASTE}" "text=@${TEXT_FILE}"
        append_to_history "${result}"

        if ! copy_to_clipboard "${TEXT_FILE}"; then
            dlog "clipboard_copy_failed"
            notify "Whisper" "Clipboard copy failed" "Basso"
            rm -f "${AUDIO_FILE}"
            return 1
        fi

        if [ "${WHISPER_AUTO_PASTE}" = "1" ]; then
            paste_clipboard
            dlog "auto_pasted"
        fi

        if [ "${#result}" -gt 80 ]; then
            preview="${result:0:80}..."
        else
            preview="${result}"
        fi

        notify "Whisper re-transcribed" "${preview}" "Glass"
    else
        dlog "retranscribe_empty_result"
        notify "Whisper" "No speech detected on retry" "Basso"
    fi

    dlog "retranscribe_done" "duration_s=$(( $(date +%s) - _t_start ))"
    rm -f "${AUDIO_FILE}"
}

case "${ACTION}" in
    start)
        start_recording
        ;;
    stop)
        stop_recording
        ;;
    toggle)
        toggle_recording
        ;;
    list-devices)
        list_devices
        ;;
    list-models)
        list_available_models
        ;;
    download-model)
        download_model "$@"
        ;;
    restart-recording)
        restart_recording
        ;;
    status)
        status
        ;;
    retranscribe)
        retranscribe
        ;;
    auth)
        copilot_device_flow
        ;;
    *)
        printf 'Usage: %s start|stop|toggle|retranscribe|restart-recording|list-devices|list-models|download-model|auth|status\n' "$0" >&2
        exit 1
        ;;
esac
