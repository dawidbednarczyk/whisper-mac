#!/usr/bin/env bash
#
# Install whisper speech-to-text for the current macOS user.
# Run from the repo root to set up Hammerspoon, pick a model and configure hotkeys.
# Safe to re-run — updates config and patches in place.
#
# Usage: ./install.sh
#

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELATIVE_PATH="${ROOT_DIR#${HOME}/}"

if [[ "${RELATIVE_PATH}" == /* ]]; then
    echo "ERROR: Repo must be inside \$HOME (${HOME})."
    echo "       Current location: ${ROOT_DIR}"
    exit 1
fi

HAMMERSPOON_DIR="${HOME}/.hammerspoon"
HAMMERSPOON_INIT="${HAMMERSPOON_DIR}/init.lua"
MODEL_DIR="${ROOT_DIR}/models"
CONFIG_FILE="${ROOT_DIR}/whisper-stt.conf"
WHISPER_SCRIPT="${ROOT_DIR}/whisper.sh"

echo "==> Whisper STT install"
echo "    Root: ${ROOT_DIR}"
echo

# ── Dependency checks & auto-install ─────────────────────────────────────────

install_brew_pkg() {
    local cmd="$1"
    local pkg="$2"

    if command -v "${cmd}" >/dev/null 2>&1; then
        return 0
    fi

    if ! command -v brew >/dev/null 2>&1; then
        echo "ERROR: ${cmd} not found and Homebrew is not installed."
        echo "       Install Homebrew first: https://brew.sh"
        exit 1
    fi

    echo "==> ${cmd} not found — installing ${pkg} via Homebrew..."
    brew install "${pkg}"

    if ! command -v "${cmd}" >/dev/null 2>&1; then
        echo "ERROR: ${cmd} still not found after brew install ${pkg}"
        exit 1
    fi
}

if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 not found. Install Xcode Command Line Tools:"
    echo "       xcode-select --install"
    exit 1
fi

install_brew_pkg ffmpeg ffmpeg
install_brew_pkg whisper-cli whisper-cpp

if [ ! -d "/Applications/Hammerspoon.app" ] && [ ! -d "${HOME}/Applications/Hammerspoon.app" ]; then
    echo "WARN:  Hammerspoon not found."
    echo "       Install with: brew install --cask hammerspoon"
    read -rp "       Install now? [Y/n]: " HS_INSTALL
    HS_INSTALL="${HS_INSTALL:-Y}"
    if [[ "${HS_INSTALL}" =~ ^[Yy]$ ]]; then
        brew install --cask hammerspoon
    fi
fi

echo "    ffmpeg:      $(command -v ffmpeg)"
echo "    whisper-cli: $(command -v whisper-cli)"
echo

# ── Permissions ──────────────────────────────────────────────────────────────

chmod +x "${WHISPER_SCRIPT}"

# ── Patch whisper_hotkeys.lua with correct paths ──────────────────────────────

sed -i '' "s|local whisper_script = .*|local whisper_script = home .. \"/${RELATIVE_PATH}/whisper.sh\"|" "${ROOT_DIR}/whisper_hotkeys.lua"
sed -i '' "s|local conf_file      = .*|local conf_file      = home .. \"/${RELATIVE_PATH}/whisper-stt.conf\"|" "${ROOT_DIR}/whisper_hotkeys.lua"
echo "==> Patched whisper_hotkeys.lua"
echo

# ── Model selection ───────────────────────────────────────────────────────────

mkdir -p "${MODEL_DIR}"

EXISTING_MODELS=()
while IFS= read -r f; do
    EXISTING_MODELS+=("$(basename "${f}")")
done < <(ls "${MODEL_DIR}"/*.bin 2>/dev/null || true)

SELECTED_MODEL=""

if [ "${#EXISTING_MODELS[@]}" -eq 0 ]; then
    echo "==> No models found. Choose one to download:"
    echo
    echo "    1) ggml-large-v3-turbo  (~800 MB, recommended)"
    echo "       Fastest large model. Best speed/quality ratio."
    echo "       Multilingual, auto-detect. Ideal for daily use."
    echo
    echo "    2) ggml-large-v3        (~1.5 GB, highest quality)"
    echo "       Most accurate model. Slower transcription."
    echo "       Best for long recordings or noisy environments."
    echo
    echo "    3) ggml-medium          (~1.5 GB, multilingual)"
    echo "       Good balance. Supports all languages."
    echo "       Smaller than large-v3 in accuracy, similar size."
    echo
    echo "    4) Skip — I'll add a model manually"
    echo
    read -rp "    Choice [1]: " MODEL_CHOICE
    MODEL_CHOICE="${MODEL_CHOICE:-1}"

    case "${MODEL_CHOICE}" in
        1) MODEL_NAME="ggml-large-v3-turbo" ;;
        2) MODEL_NAME="ggml-large-v3"       ;;
        3) MODEL_NAME="ggml-medium"         ;;
        4) MODEL_NAME=""                    ;;
        *) MODEL_NAME="ggml-large-v3-turbo" ; echo "    Invalid choice, defaulting to ggml-large-v3-turbo" ;;
    esac

    if [ -n "${MODEL_NAME}" ]; then
        MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${MODEL_NAME}.bin"
        SELECTED_MODEL="${MODEL_DIR}/${MODEL_NAME}.bin"
        echo "==> Downloading ${MODEL_NAME}.bin..."
        curl -L --fail --progress-bar --output "${SELECTED_MODEL}.part" "${MODEL_URL}"
        mv "${SELECTED_MODEL}.part" "${SELECTED_MODEL}"
        echo "    Downloaded: ${SELECTED_MODEL}"
    fi
else
    echo "==> Models found — choose active model:"
    for i in "${!EXISTING_MODELS[@]}"; do
        echo "    $((i+1))) ${EXISTING_MODELS[$i]}"
    done
    echo
    read -rp "    Choice [1]: " MODEL_CHOICE
    MODEL_CHOICE="${MODEL_CHOICE:-1}"

    if [[ "${MODEL_CHOICE}" =~ ^[0-9]+$ ]] \
        && [ "${MODEL_CHOICE}" -ge 1 ] \
        && [ "${MODEL_CHOICE}" -le "${#EXISTING_MODELS[@]}" ]; then
        SELECTED_MODEL="${MODEL_DIR}/${EXISTING_MODELS[$((MODEL_CHOICE-1))]}"
    else
        SELECTED_MODEL="${MODEL_DIR}/${EXISTING_MODELS[0]}"
        echo "    Invalid choice, using ${EXISTING_MODELS[0]}"
    fi
fi
echo

# ── Hotkey configuration ──────────────────────────────────────────────────────

echo "==> Hotkey configuration"
echo "    Format: modifier,modifier,key  (e.g. shift,cmd,r)"
echo "    Available modifiers: ctrl  cmd  alt  shift"
echo
read -rp "    Toggle (start/stop) [shift,cmd,r]: " HOTKEY_TOGGLE
read -rp "    Stop immediately    [shift,cmd,q]: " HOTKEY_STOP
HOTKEY_TOGGLE="${HOTKEY_TOGGLE:-shift,cmd,r}"
HOTKEY_STOP="${HOTKEY_STOP:-shift,cmd,q}"
echo

# ── Config file ──────────────────────────────────────────────────────────────

if [ ! -f "${CONFIG_FILE}" ]; then
    cat > "${CONFIG_FILE}" <<EOFCONF
# Whisper speech-to-text configuration
# To change hotkeys: edit WHISPER_HOTKEY_* and reload Hammerspoon.
# To change model:   edit WHISPER_MODEL_PATH and restart.
#
WHISPER_AUDIO_DEVICE=default
WHISPER_LANGUAGE=auto
WHISPER_MODEL_PATH="${SELECTED_MODEL}"
WHISPER_AUTO_PASTE=1
WHISPER_MAX_SECONDS=7200
WHISPER_HOTKEY_TOGGLE="${HOTKEY_TOGGLE}"
WHISPER_HOTKEY_STOP="${HOTKEY_STOP}"
WHISPER_NOTIFICATIONS=1
WHISPER_SOUNDS=1
WHISPER_POST_PROCESS=off
# Optional fixed device index: WHISPER_AUDIO_DEVICE_INDEX=1
# Optional translate to English: WHISPER_TRANSLATE=1
# Optional history size: WHISPER_HISTORY_MAX=10
EOFCONF
    echo "==> Created config: ${CONFIG_FILE}"
else
    # Update model path
    if [ -n "${SELECTED_MODEL}" ]; then
        sed -i '' "s|^WHISPER_MODEL_PATH=.*|WHISPER_MODEL_PATH=\"${SELECTED_MODEL}\"|" "${CONFIG_FILE}"
    fi
    # Update hotkeys — append if not present yet
    if grep -q "^WHISPER_HOTKEY_TOGGLE=" "${CONFIG_FILE}"; then
        sed -i '' "s|^WHISPER_HOTKEY_TOGGLE=.*|WHISPER_HOTKEY_TOGGLE=\"${HOTKEY_TOGGLE}\"|" "${CONFIG_FILE}"
        sed -i '' "s|^WHISPER_HOTKEY_STOP=.*|WHISPER_HOTKEY_STOP=\"${HOTKEY_STOP}\"|" "${CONFIG_FILE}"
    else
        printf '\nWHISPER_HOTKEY_TOGGLE="%s"\nWHISPER_HOTKEY_STOP="%s"\n' \
            "${HOTKEY_TOGGLE}" "${HOTKEY_STOP}" >> "${CONFIG_FILE}"
    fi
    echo "==> Updated config: ${CONFIG_FILE}"
fi
echo

# ── Hammerspoon init.lua ──────────────────────────────────────────────────────

mkdir -p "${HAMMERSPOON_DIR}"

DOFILE_LINE="dofile(os.getenv(\"HOME\") .. \"/${RELATIVE_PATH}/whisper_hotkeys.lua\")"

if [ ! -f "${HAMMERSPOON_INIT}" ]; then
    cat > "${HAMMERSPOON_INIT}" <<LUAEOF
-- Hammerspoon configuration
pcall(function()
    ${DOFILE_LINE}
end)
LUAEOF
    echo "==> Created ${HAMMERSPOON_INIT}"
else
    if grep -q "whisper_hotkeys.lua" "${HAMMERSPOON_INIT}"; then
        echo "==> init.lua already loads whisper_hotkeys.lua, skipping"
    else
        cat >> "${HAMMERSPOON_INIT}" <<LUAEOF

-- Whisper speech-to-text
pcall(function()
    ${DOFILE_LINE}
end)
LUAEOF
        echo "==> Updated ${HAMMERSPOON_INIT}"
    fi
fi
echo

# ── Copilot API token (for AI post-processing) ───────────────────────────────

WHISPER_AUTH_DIR="${HOME}/.config/careless-whisper"
WHISPER_AUTH_FILE="${WHISPER_AUTH_DIR}/auth.json"
COPILOT_CLIENT_ID="Iv1.b507a08c87ecfe98"

copilot_token_exists() {
    # Check our own auth file
    if [ -f "${WHISPER_AUTH_FILE}" ]; then
        local tok
        tok="$(python3 -c "
import json, sys
data = json.load(open(sys.argv[1]))
print(data.get('access_token', ''))
" "${WHISPER_AUTH_FILE}" 2>/dev/null || true)"
        if [ -n "${tok}" ] && [ "${#tok}" -gt 10 ]; then
            printf '%s' "careless-whisper auth (${WHISPER_AUTH_FILE})"
            return 0
        fi
    fi

    # Check environment variables
    if [ -n "${GITHUB_COPILOT_TOKEN:-}" ]; then
        printf '%s' "GITHUB_COPILOT_TOKEN env var"
        return 0
    fi

    return 1
}

copilot_device_flow() {
    echo "==> Authenticating with GitHub for Copilot API access..."
    echo "    This uses the GitHub Device Flow (same as VS Code / copilot.vim)."
    echo

    # Step 1: Request device code
    local device_response
    device_response="$(curl -s -X POST "https://github.com/login/device/code" \
        -H "Accept: application/json" \
        -d "client_id=${COPILOT_CLIENT_ID}&scope=copilot" 2>/dev/null)"

    if [ -z "${device_response}" ]; then
        echo "    ERROR: Could not reach github.com. Check your network."
        return 1
    fi

    local device_code user_code verification_uri interval
    device_code="$(python3 -c "import json,sys; print(json.load(sys.stdin)['device_code'])" <<< "${device_response}" 2>/dev/null)"
    user_code="$(python3 -c "import json,sys; print(json.load(sys.stdin)['user_code'])" <<< "${device_response}" 2>/dev/null)"
    verification_uri="$(python3 -c "import json,sys; print(json.load(sys.stdin)['verification_uri'])" <<< "${device_response}" 2>/dev/null)"
    interval="$(python3 -c "import json,sys; print(json.load(sys.stdin).get('interval', 5))" <<< "${device_response}" 2>/dev/null)"

    if [ -z "${device_code}" ] || [ -z "${user_code}" ]; then
        echo "    ERROR: Unexpected response from GitHub."
        echo "    ${device_response}"
        return 1
    fi

    # Step 2: Show code, let user copy, then open browser
    echo
    echo "    ┌─────────────────────────────────────────┐"
    echo "    │                                         │"
    echo "    │   Your code:  ${user_code}                 │"
    echo "    │                                         │"
    echo "    └─────────────────────────────────────────┘"
    echo
    echo "    Copy this code, then paste it on the GitHub page."
    echo
    # Copy to clipboard automatically on macOS
    printf '%s' "${user_code}" | pbcopy 2>/dev/null && \
        echo "    (Copied to clipboard automatically)" && echo
    read -rp "    Press Enter to open ${verification_uri} ..."
    open "${verification_uri}" 2>/dev/null || true
    echo
    echo "    Waiting for authorization..."

    # Step 3: Poll for token
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
                # Step 4: Store token
                mkdir -p "${WHISPER_AUTH_DIR}"
                python3 -c "
import json, sys
with open(sys.argv[1], 'w') as f:
    json.dump({'access_token': sys.argv[2]}, f)
" "${WHISPER_AUTH_FILE}" "${access_token}"
                chmod 600 "${WHISPER_AUTH_FILE}"
                echo
                echo "    Authenticated successfully."
                echo "    Token stored in ${WHISPER_AUTH_FILE}"
                return 0
            fi
        else
            echo
            echo "    ERROR: ${error}"
            return 1
        fi
    done

    echo
    echo "    Timed out waiting for authorization."
    return 1
}

# Check if we already have a working token
COPILOT_TOKEN_SOURCE=""
if COPILOT_TOKEN_SOURCE="$(copilot_token_exists)"; then
    echo "==> Copilot API token found via ${COPILOT_TOKEN_SOURCE}"
    echo "    AI post-processing modes available (select via menubar)."
else
    echo "==> Copilot API token not found."
    echo "    AI post-processing requires a GitHub Copilot subscription."
    echo
    read -rp "    Authenticate with GitHub now? [Y/n]: " DO_AUTH
    DO_AUTH="${DO_AUTH:-Y}"
    if [[ "${DO_AUTH}" =~ ^[Yy]$ ]]; then
        copilot_device_flow || true
    else
        echo "    Skipped. You can authenticate later by re-running ./install.sh"
        echo "    Or set GITHUB_COPILOT_TOKEN in your shell profile."
    fi
fi
echo

# ── Summary ───────────────────────────────────────────────────────────────────

echo "==> Install complete."
echo
echo "    Model:  $(basename "${SELECTED_MODEL:-none selected}")"
echo "    Toggle: ${HOTKEY_TOGGLE}"
echo "    Stop:   ${HOTKEY_STOP}"
echo
echo "Next steps:"
echo "  1) Open Hammerspoon and grant Accessibility permission."
echo "  2) Reload Hammerspoon config (menubar icon → Reload Config)."
echo "  3) Press ${HOTKEY_TOGGLE} to start recording."
echo "  4) Press ${HOTKEY_TOGGLE} again to stop + transcribe + paste."
echo "  5) Emergency stop: ${HOTKEY_STOP}."
echo "  6) Click the menubar icon (○) to switch models or browse history."
echo
echo "To change hotkeys: edit ${CONFIG_FILE} and reload Hammerspoon."
echo "To change model:   use the menubar dropdown or edit WHISPER_MODEL_PATH in ${CONFIG_FILE}."

# ── Launch Hammerspoon ────────────────────────────────────────────────────────

if [ -d "/Applications/Hammerspoon.app" ] || [ -d "${HOME}/Applications/Hammerspoon.app" ]; then
    echo
    echo "==> Opening Hammerspoon..."
    open -a Hammerspoon
    # Attempt to reload config if Hammerspoon was already running
    sleep 1
    if command -v hs >/dev/null 2>&1; then
        hs -c 'hs.reload()' 2>/dev/null && echo "    Reloaded Hammerspoon config." || true
    fi
    echo "    If this is a fresh install, grant Accessibility permission when prompted."
fi
