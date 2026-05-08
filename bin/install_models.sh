#!/bin/bash
# bin/install_models.sh — download whisper models to ~/whisper-models/ and verify SHA-256.
#
# Models live at ~/whisper-models/ (not <repo>/models/) because the runtime config
# (whisper-stt.conf, hammerspoon/whisper_streaming.lua) reads from there.
#
# Idempotent: skips files that already exist AND match the expected hash.
# Re-runs SHA verification on every invocation so you can catch bit-rot.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODELS_DIR="${HOME}/whisper-models"
SHA_FILE="${REPO_ROOT}/models.sha256"
HF_BASE="https://huggingface.co/ggerganov/whisper.cpp/resolve/main"

if [ ! -f "$SHA_FILE" ]; then
    echo "ERROR: ${SHA_FILE} not found" >&2
    exit 1
fi

mkdir -p "$MODELS_DIR"

# Read the sha256 file: each line is "<sha>  <filename>"
download_count=0
verify_ok=0
verify_fail=0

while IFS= read -r line; do
    # Skip blanks / comments
    case "$line" in
        ""|"#"*) continue ;;
    esac
    expected_sha="${line%% *}"
    fname="${line##* }"
    target="${MODELS_DIR}/${fname}"

    if [ -f "$target" ]; then
        actual_sha=$(shasum -a 256 "$target" | awk '{print $1}')
        if [ "$actual_sha" = "$expected_sha" ]; then
            echo "  OK     ${fname}  (already present, sha verified)"
            verify_ok=$((verify_ok + 1))
            continue
        else
            echo "  STALE  ${fname}  (sha mismatch — redownloading)"
            rm -f "$target"
        fi
    fi

    echo "  GET    ${fname}  (downloading from HuggingFace...)"
    if ! curl -L --fail --progress-bar "${HF_BASE}/${fname}" -o "${target}.tmp"; then
        echo "  ERROR  ${fname}  (download failed)" >&2
        rm -f "${target}.tmp"
        verify_fail=$((verify_fail + 1))
        continue
    fi
    mv "${target}.tmp" "$target"
    download_count=$((download_count + 1))

    # Verify after download
    actual_sha=$(shasum -a 256 "$target" | awk '{print $1}')
    if [ "$actual_sha" = "$expected_sha" ]; then
        echo "  OK     ${fname}  (downloaded + sha verified)"
        verify_ok=$((verify_ok + 1))
    else
        echo "  FAIL   ${fname}  (sha mismatch after download — expected ${expected_sha}, got ${actual_sha})" >&2
        verify_fail=$((verify_fail + 1))
    fi
done < "$SHA_FILE"

echo ""
echo "Summary: ${verify_ok} OK, ${verify_fail} failed, ${download_count} downloaded."

if [ "$verify_fail" -gt 0 ]; then
    exit 1
fi
exit 0
