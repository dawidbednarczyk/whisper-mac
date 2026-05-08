#!/usr/bin/env bash
#
# Uninstall Whisper speech-to-text.
# Removes Hammerspoon integration, temp files and optionally Homebrew packages.
# Does NOT delete the repo directory itself — do that manually if desired.
#
# Usage: ./uninstall.sh
#

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

HAMMERSPOON_INIT="${HOME}/.hammerspoon/init.lua"

echo "==> Whisper STT uninstall"
echo "    Root: ${ROOT_DIR}"
echo

# ── Remove Hammerspoon integration ──────────────────────────────────────────

if [ -f "${HAMMERSPOON_INIT}" ]; then
    if grep -q "whisper_hotkeys.lua" "${HAMMERSPOON_INIT}"; then
        # Remove the comment + pcall block that loads whisper_hotkeys.lua
        sed -i '' '/-- Whisper speech-to-text/,/^end)/d' "${HAMMERSPOON_INIT}" 2>/dev/null || true
        # Remove any remaining standalone whisper references
        sed -i '' '/whisper_hotkeys\.lua/d' "${HAMMERSPOON_INIT}" 2>/dev/null || true
        echo "==> Removed Whisper from ${HAMMERSPOON_INIT}"
    else
        echo "==> ${HAMMERSPOON_INIT} does not reference Whisper, skipping"
    fi
else
    echo "==> No ${HAMMERSPOON_INIT} found, skipping"
fi
echo

# ── Remove temp / runtime files ─────────────────────────────────────────────

echo "==> Cleaning runtime files..."
for tmpdir in "${TMPDIR:-}" /tmp; do
    [ -z "${tmpdir}" ] && continue
    rm -f "${tmpdir}/whisper_recording.wav" \
          "${tmpdir}/whisper_recording.pid" \
          "${tmpdir}/whisper_output.txt" \
          "${tmpdir}/whisper_transcribing" \
          "${tmpdir}/whisper_postprocessing" \
          "${tmpdir}/whisper_segment_index" \
          "${tmpdir}/whisper_debug.log" \
          "${tmpdir}/ffmpeg.log" \
          "${tmpdir}/whisper-error.log"
    rm -rf "${tmpdir}/whisper_segments"
done

# Remove auth token
if [ -f "${HOME}/.config/careless-whisper/auth.json" ]; then
    read -rp "    Remove Copilot auth token (~/.config/careless-whisper/auth.json)? [y/N]: " REMOVE_AUTH
    if [[ "${REMOVE_AUTH}" =~ ^[Yy]$ ]]; then
        rm -f "${HOME}/.config/careless-whisper/auth.json"
        rmdir "${HOME}/.config/careless-whisper" 2>/dev/null || true
        echo "    Removed auth token"
    else
        echo "    Kept auth token"
    fi
fi
echo "    Done"
echo

# ── Optionally remove Homebrew packages ──────────────────────────────────────

if command -v brew >/dev/null 2>&1; then
    echo "==> Optional: remove Homebrew packages installed for Whisper"
    echo "    These may be used by other tools — only remove if you're sure."
    echo

    for pkg in whisper-cpp ffmpeg; do
        if brew list "${pkg}" >/dev/null 2>&1; then
            read -rp "    Uninstall ${pkg}? [y/N]: " REMOVE
            if [[ "${REMOVE}" =~ ^[Yy]$ ]]; then
                brew uninstall "${pkg}"
                echo "    Removed ${pkg}"
            else
                echo "    Kept ${pkg}"
            fi
        fi
    done

    if [ -d "/Applications/Hammerspoon.app" ] || [ -d "${HOME}/Applications/Hammerspoon.app" ]; then
        read -rp "    Uninstall Hammerspoon? [y/N]: " REMOVE_HS
        if [[ "${REMOVE_HS}" =~ ^[Yy]$ ]]; then
            brew uninstall --cask hammerspoon 2>/dev/null || true
            echo "    Removed Hammerspoon"
        else
            echo "    Kept Hammerspoon"
        fi
    fi
fi
echo

# ── Summary ──────────────────────────────────────────────────────────────────

echo "==> Uninstall complete."
echo
echo "    The repo directory was NOT deleted: ${ROOT_DIR}"
echo "    To remove it:  rm -rf \"${ROOT_DIR}\""
echo
echo "    If Hammerspoon is still running, reload its config to"
echo "    clear the Whisper menubar icon."
