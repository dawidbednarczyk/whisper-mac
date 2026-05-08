#!/bin/bash
# bin/disaster_recovery_check.sh — assert the system is restorable end-to-end.
#
# Runs all readiness checks for a bare-metal restore and exits 0 (green) or
# non-zero (red) with line-per-check output.
#
# Designed to run weekly via launchd, or manually after major changes.
# See docs/recovery.md and rpi/disaster-recovery-from-scratch/.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
WARN=0

ok()    { echo "  [OK]   $1";   PASS=$((PASS + 1)); }
fail()  { echo "  [FAIL] $1" >&2; FAIL=$((FAIL + 1)); }
warn()  { echo "  [WARN] $1" >&2; WARN=$((WARN + 1)); }

echo "=== Disaster-recovery readiness check ==="
echo "Repo: ${REPO_ROOT}"
echo ""

# --- 1. Runtime data ---
echo "[1/8] Runtime data"
if [ -s "${HOME}/.whisper_log/records.json" ]; then
    sz=$(wc -c < "${HOME}/.whisper_log/records.json" | tr -d ' ')
    ok "records.json exists and non-empty (${sz} bytes)"
else
    fail "~/.whisper_log/records.json missing or empty"
fi

# --- 2. Backup recency ---
echo ""
echo "[2/8] Backup recency"
LATEST_BACKUP=$(ls -t "${REPO_ROOT}/backup/"records.json.snapshot.*.json 2>/dev/null | head -1 || true)
if [ -z "$LATEST_BACKUP" ]; then
    fail "no records.json snapshot in backup/"
else
    AGE_DAYS=$(( ($(date +%s) - $(stat -f %m "$LATEST_BACKUP")) / 86400 ))
    if [ "$AGE_DAYS" -le 7 ]; then
        ok "latest snapshot $(basename "$LATEST_BACKUP") is ${AGE_DAYS}d old (<= 7d threshold)"
    else
        warn "latest snapshot $(basename "$LATEST_BACKUP") is ${AGE_DAYS}d old (> 7d — backup automation may be down)"
    fi
fi

# --- 3. Whisper models ---
echo ""
echo "[3/8] Whisper models (sha-verified against models.sha256)"
if [ -f "${REPO_ROOT}/models.sha256" ]; then
    while IFS= read -r line; do
        case "$line" in ""|"#"*) continue ;; esac
        expected="${line%% *}"
        fname="${line##* }"
        target="${HOME}/whisper-models/${fname}"
        if [ ! -f "$target" ]; then
            fail "model missing: ${target}"
        else
            actual=$(shasum -a 256 "$target" | awk '{print $1}')
            if [ "$actual" = "$expected" ]; then
                ok "${fname} sha verified"
            else
                fail "${fname} sha mismatch (expected ${expected:0:12}…, got ${actual:0:12}…)"
            fi
        fi
    done < "${REPO_ROOT}/models.sha256"
else
    fail "models.sha256 not in repo"
fi

# --- 4. Hammerspoon sync ---
echo ""
echo "[4/8] Hammerspoon Lua files (canonical vs live ~/.hammerspoon/)"
for f in "${REPO_ROOT}/hammerspoon/"*.lua; do
    name=$(basename "$f")
    live="${HOME}/.hammerspoon/${name}"
    if [ ! -f "$live" ]; then
        fail "${name}: live copy missing in ~/.hammerspoon/"
        continue
    fi
    h1=$(md5 -q "$f" 2>/dev/null)
    h2=$(md5 -q "$live" 2>/dev/null)
    if [ "$h1" = "$h2" ]; then
        ok "${name}: in sync"
    else
        fail "${name}: DRIFT (run bin/sync_hammerspoon.sh push)"
    fi
done

# --- 5. Copilot OAuth ---
echo ""
echo "[5/8] Copilot OAuth token"
AUTH="${HOME}/.config/careless-whisper/auth.json"
if [ ! -f "$AUTH" ]; then
    fail "${AUTH} missing — run: bash upstream/Careless-Whisper/whisper.sh auth"
else
    # Normalize to 4-digit octal (e.g. "600" -> "0600")
    RAW_MODE=$(stat -f %Lp "$AUTH" 2>/dev/null || echo "?")
    MODE=$(printf '%04d' "$RAW_MODE" 2>/dev/null || echo "$RAW_MODE")
    if [ "$MODE" = "0600" ]; then
        ok "auth.json present (mode 0600 — secure)"
    elif [ "$MODE" = "0644" ] || [ "$MODE" = "0640" ]; then
        warn "auth.json mode is ${MODE} — should be 0600 (run: chmod 600 \"${AUTH}\")"
    else
        ok "auth.json present (mode ${MODE})"
    fi
fi

# --- 6. Brew packages ---
echo ""
echo "[6/8] Homebrew packages"
if ! command -v brew >/dev/null; then
    fail "brew not installed"
else
    for pkg in whisper-cpp ffmpeg lua sdl2; do
        if brew list "$pkg" >/dev/null 2>&1; then
            ok "brew: $pkg"
        else
            fail "brew package missing: $pkg (run: brew install $pkg)"
        fi
    done
    if [ -d "/Applications/Hammerspoon.app" ]; then
        ok "Hammerspoon.app present"
    else
        fail "Hammerspoon.app missing (run: brew install --cask hammerspoon)"
    fi
fi

# --- 7. Python deps ---
echo ""
echo "[7/8] Python deps"
if python3 -c "import PIL" 2>/dev/null; then
    ok "Pillow importable (PIL)"
else
    fail "Pillow not importable (run: pip3 install -r requirements.txt)"
fi

# --- 8. Mouse hardware ---
echo ""
echo "[8/8] Mouse hardware (Logi Options+)"
if [ -d "/Applications/logioptionsplus.app" ]; then
    ok "Logi Options+ app present"
else
    warn "Logi Options+ not installed — see docs/mouse-mapping.md (streaming mode dead without it)"
fi

# --- Security: leaked password check ---
echo ""
echo "[bonus] Security: no plaintext passwords in code"
# Generic heuristic: scan for common password-looking patterns. Customize
# PASSWORD_PATTERNS for your own deployment (build at runtime so this
# script doesn't trigger its own check).
PASSWORD_PATTERNS="$(printf 'passw0rd\nhunter2\nchangeme')"
LEAK=$(echo "$PASSWORD_PATTERNS" | while read -r pat; do
    [ -n "$pat" ] && grep -rln "$pat" "${REPO_ROOT}/hammerspoon/" "${REPO_ROOT}/bin/" 2>/dev/null | grep -v "$(basename "$0")" || true
done)
if [ -z "$LEAK" ]; then
    ok "no leaked passwords in active code"
else
    fail "PLAINTEXT PASSWORD in: $LEAK"
fi

# --- Keychain check (optional) ---
# If your Hammerspoon config uses a keychain entry for any auto-typed
# secret, set KEYCHAIN_SERVICE below; otherwise this check is skipped.
KEYCHAIN_SERVICE="${WHISPER_MAC_KEYCHAIN_SERVICE:-}"
if [ -n "$KEYCHAIN_SERVICE" ]; then
    if security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$USER" -w >/dev/null 2>&1; then
        ok "keychain entry '$KEYCHAIN_SERVICE' present"
    else
        warn "keychain entry '$KEYCHAIN_SERVICE' missing (run: security add-generic-password -U -s '$KEYCHAIN_SERVICE' -a \"\$USER\" -w '<secret>')"
    fi
fi

# --- Summary ---
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "Status: RED — some checks failed. Run docs/recovery.md to remediate."
    exit 1
elif [ "$WARN" -gt 0 ]; then
    echo ""
    echo "Status: YELLOW — restorable but with warnings."
    exit 0
else
    echo ""
    echo "Status: GREEN — disaster-recovery ready."
    exit 0
fi
