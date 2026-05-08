# Disaster Recovery — Restore from Scratch on a Fresh Mac

## Part 0 — When to use this doc

Use this runbook when your Mac dies and you need to restore the whisper transcription system on a new machine, when starting on a fresh Mac, or when periodically dry-running recovery to verify readiness. For ongoing readiness checks without a full restore, run `bin/disaster_recovery_check.sh` (see Part 10).

## Part 1 — Prerequisites (10 minutes)

1. Install Xcode Command Line Tools:
   ```bash
   xcode-select --install
   ```
   Accept the license prompt and wait for installation to complete.

2. Install Homebrew (if not already present):
   ```bash
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
   ```
   Follow the post-install instructions to add Homebrew to your PATH.

3. Install and authenticate GitHub CLI:
   ```bash
   brew install gh
   gh auth login
   ```
   Choose "GitHub.com", "HTTPS" protocol, authenticate via browser, and paste the one-time code when prompted.

4. Clone the whisper-mac repository:
   ```bash
   git clone https://github.com/dawidbednarczyk/whisper-mac.git ~/whisper-mac
   cd ~/whisper-mac
   ```

## Part 2 — Install dependencies (15 minutes)

1. Install Homebrew packages:
   ```bash
   brew install whisper-cpp ffmpeg lua@5.4 sdl2
   brew install --cask hammerspoon
   ```

2. Install Logi Options+ (required for streaming mode mouse buttons):
   - Download from: https://www.logitech.com/en-us/software/logi-options-plus.html
   - Install the DMG and launch the app
   - Connect your MX Anywhere 3S mouse
   - See `docs/mouse-mapping.md` for button configuration (Part 8)

3. Install Python dependencies:
   ```bash
   pip3 install --user --break-system-packages -r requirements.txt
   ```
   The `--break-system-packages` flag is required on macOS Python 3.11+ (PEP 668). Alternative: create a venv first (`python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt`). This installs Pillow (required for `bin/extract_project_from_screenshot.py`).

## Part 3 — Download whisper models (10 minutes)

1. Run the automated model installer:
   ```bash
   bash bin/install_models.sh
   ```
   This downloads three models to `~/whisper-models/` and verifies their SHA-256 checksums against `models.sha256`:
   - `ggml-base.en.bin` (141 MB) — streaming mode
   - `ggml-medium.en.bin` (1.5 GB) — batch mode
   - `ggml-large-v3.bin` (3.1 GB) — retranscription comparison

2. Manual fallback (if curl is blocked by firewall):
   ```bash
   mkdir -p ~/whisper-models
   cd ~/whisper-models
   
   # Download each model
   curl -L https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin -o ggml-base.en.bin
   curl -L https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.en.bin -o ggml-medium.en.bin
   curl -L https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin -o ggml-large-v3.bin
   
   # Verify checksums (must run from ~/whisper-models/ — sha file lists bare filenames)
   cd ~/whisper-models
   shasum -a 256 -c ~/whisper-mac/models.sha256
   ```
   All three lines should show "OK". If any show "FAILED", delete that file and re-run `bash bin/install_models.sh` from the repo root (idempotent — only re-downloads what's missing or stale).

**Mid-flight checkpoint**: verify the install before moving on:
```bash
bash bin/disaster_recovery_check.sh 2>&1 | grep "sha verified"
```
Should show three `[OK]` lines for the three model files. If any FAIL, re-run `bash bin/install_models.sh`.

## Part 4 — Sync Hammerspoon Lua to live location (1 minute)

1. Copy canonical Lua modules to Hammerspoon's runtime directory:
   ```bash
   bash bin/sync_hammerspoon.sh push
   ```
   This copies `hammerspoon/*.lua` to `~/.hammerspoon/*.lua`.

2. Why this matters: The canonical source is `hammerspoon/` in this repo. The live runtime location is `~/.hammerspoon/`. Always edit in `hammerspoon/`, then sync. See `ARCHITECTURE.md` for the full explanation of the canonical-vs-live distinction.

**Verify Lua sync**:
```bash
for f in hammerspoon/*.lua; do
  name=$(basename "$f")
  h1=$(md5 -q "$f")
  h2=$(md5 -q ~/.hammerspoon/"$name" 2>/dev/null || echo "MISSING")
  [ "$h1" = "$h2" ] && echo "  OK     $name" || echo "  DRIFT  $name"
done
```
All 5 Lua files should show `OK`. If any show `DRIFT` or `MISSING`, re-run `bash bin/sync_hammerspoon.sh push`.

## Part 5 — Run Bjorn's installer for legacy paths + Copilot Device Flow (5 minutes)

1. Run the upstream installer:
   ```bash
   cd upstream/Careless-Whisper
   bash install.sh
   ```

2. What this does:
   - Re-verifies brew dependencies (whisper-cpp, ffmpeg, hammerspoon)
   - Prompts for hotkey configuration. Accept the upstream defaults (`shift,cmd,r` / `shift,cmd,q`) — they will be **disabled** by `whisper-stt.conf` (line 14-15: `WHISPER_HOTKEY_TOGGLE="disabled"`). The real batch hotkey `Ctrl+Cmd+W` / `Ctrl+Cmd+Q` is bound by `hammerspoon/init.lua:250` after Part 4 sync. (See `ARCHITECTURE.md` for the dual-pipeline rationale.)
   - **When prompted to download a model**: choose option 4 (Skip — I'll add a model manually). Our `medium.en` model is already in `~/whisper-models/` from Part 3. Options 1-3 would download into `upstream/Careless-Whisper/models/` (wrong location) AND overwrite `WHISPER_MODEL_PATH` to that wrong path.
   - Patches `whisper_hotkeys.lua` paths to match your system
   - **CRITICALLY**: Runs Copilot Device Flow OAuth, which writes `~/.config/careless-whisper/auth.json`

3. After Device Flow completes, secure the auth token:
   ```bash
   chmod 600 ~/.config/careless-whisper/auth.json
   ```

4. Verify `WHISPER_MODEL_PATH` in `upstream/Careless-Whisper/whisper-stt.conf` points to YOUR home directory:
   ```bash
   grep WHISPER_MODEL_PATH upstream/Careless-Whisper/whisper-stt.conf
   # Expected: WHISPER_MODEL_PATH="/Users/<YOUR-USERNAME>/whisper-models/ggml-medium.en.bin"
   ```
   If it shows a different username (e.g. `someone-else`), the file ships with a hardcoded path from the original author's machine — fix it:
   ```bash
   sed -i '' "s|/Users/[^/]*/whisper-models|$HOME/whisper-models|" upstream/Careless-Whisper/whisper-stt.conf
   ```
   **Why this matters**: batch mode (`whisper.sh`) reads this path directly to load `whisper-cli`'s model. If the username doesn't match, batch transcription fails silently with "model not found" until you fix the path.

## Part 6 — (Optional) Add a secret to keychain for Hammerspoon auto-typing (1 minute)

This step is **optional** and only needed if you wire your own Hammerspoon hotkey to auto-type a secret (e.g. a VPN PIN, an SSH passphrase, an internal-tool password). Skip if you don't use any such hotkey.

1. Store the secret in macOS Keychain:
   ```bash
   security add-generic-password -U -s "<your-keychain-service>" -a "$USER" -w "<your-secret>"
   ```
   Replace `<your-keychain-service>` with a name of your choice (e.g. `whisper-mac-vpn-pin`) and `<your-secret>` with the actual value. Reference the same service name from your Hammerspoon binding via `hs.execute("security find-generic-password -s '<your-keychain-service>' -a $USER -w", true)`.

2. To make `bin/disaster_recovery_check.sh` verify the entry on each run, export the service name:
   ```bash
   export WHISPER_MAC_KEYCHAIN_SERVICE="<your-keychain-service>"
   ```
   Add this to your shell profile (`~/.zshrc` or `~/.bash_profile`) to persist it.

**Verify keychain entry**:
```bash
security find-generic-password -s "<your-keychain-service>" -a "$USER" -w >/dev/null 2>&1 \
  && echo "OK — keychain entry present" \
  || echo "MISSING — re-run the security add-generic-password command above"
```

## Part 7 — Launch Hammerspoon and grant macOS permissions (5 minutes)

1. Launch Hammerspoon:
   ```bash
   open -a Hammerspoon
   ```

2. Grant the 5 required macOS permissions:
   - **Accessibility** — all hotkeys fail silently without this
   - **Input Monitoring** — keyboard shortcuts won't trigger
   - **Microphone** — no audio capture
   - **Screen Recording** — streaming overlay won't display
   - **Automation → System Events** — clipboard paste fails

3. See `docs/macos-permissions.md` for the full checklist with System Settings paths and verification steps.

4. Quick verification: Press Ctrl+Cmd+W. If Hammerspoon's menubar icon changes to "● 0:00", permissions are granted. If nothing happens, check System Settings.

## Part 8 — Configure Logi Options+ mouse buttons (3 minutes)

1. Open Logi Options+ app and select your MX Anywhere 3S device.

2. Configure three button mappings:

   | Button | Action | Keystroke |
   |--------|--------|-----------|
   | Forward | Custom keystroke | Ctrl+Shift+Cmd+9 |
   | Back | Custom keystroke | Ctrl+Shift+Cmd+0 |
   | Middle | Custom keystroke | Ctrl+Shift+Cmd+8 |

3. For each button:
   - Click the button in Logi Options+
   - Select "Custom" → "Keystroke assignment"
   - Press the modifier+key combo (e.g., Ctrl+Shift+Cmd+9)
   - Save

4. See `docs/mouse-mapping.md` for full step-by-step instructions and what each button does.

## Part 9 — Restore runtime data (varies)

1. Create the runtime data directory:
   ```bash
   mkdir -p ~/.whisper_log/
   ```

   **If you have NO backup**, seed an empty records.json so the rest of the system has a valid starting state:
   ```bash
   [ -f ~/.whisper_log/records.json ] || echo '{}' > ~/.whisper_log/records.json
   ```

2. Restore transcription history (records.json):
   ```bash
   # From git-snapshotted backup (latest committed state, auto-selected)
   LATEST=$(ls -t backup/records.json.snapshot.*.json 2>/dev/null | head -1)
   if [ -n "$LATEST" ]; then
     echo "Restoring from: $LATEST"
     cp "$LATEST" ~/.whisper_log/records.json
   else
     echo "No committed snapshot — use the no-backup seed step above (or bin/backfill.py if WAVs survived)"
   fi
   ```

   If you have a more recent off-repo backup (e.g., from rclone cloud sync), prefer that:
   ```bash
   # From cloud backup (if available)
   rclone copy <your-cloud-remote>:WhisperBackup/records.json ~/.whisper_log/records.json
   ```

3. Restore screenshots and recordings from cloud backup (if available):
   ```bash
   # Restore screenshots (absolute path — CWD-independent)
   rclone copy <your-cloud-remote>:WhisperBackup/screenshots/ ~/.whisper_log/screenshots/

   # Restore recordings
   rclone copy <your-cloud-remote>:WhisperBackup/recordings/ ~/whisper-mac/upstream/Careless-Whisper/recordings/
   ```
   See Part 11 for rclone setup if not already configured.

4. Re-render the HTML log:
   ```bash
   cd ~/whisper-mac
   python3 -c "import sys; sys.path.insert(0,'bin'); from transcription_log import _refresh_status_and_html; _refresh_status_and_html()"
   ```
   This regenerates `~/.whisper_log/transcriptions.html` from the restored `records.json`.

## Part 10 — Smoke tests (3 minutes)

1. Run the disaster recovery self-test:
   ```bash
   bash bin/disaster_recovery_check.sh
   ```
   Should print GREEN summary with all checks passing.

2. Test batch mode:
   - Press Ctrl+Cmd+W (start recording)
   - Speak a sentence
   - Press Ctrl+Cmd+Q (stop and paste)
   - Text should appear in the active application

3. Test streaming mode:
   - Press mouse Forward button (start streaming)
   - Speak a sentence
   - Press mouse Back button (stop and paste)
   - Text should appear in the active application

4. Open the transcription log:
   ```bash
   open ~/.whisper_log/transcriptions.html
   ```
   Should show your test recordings with dual-model comparison.

## Part 11 — Off-machine cloud backup setup (one-time, 15 minutes)

This section closes the gap for heavy data (screenshots + recordings) by setting up automated cloud backup to any cloud storage rclone supports (OneDrive, Box, Dropbox, S3, Google Drive, etc.). This is documented but NOT auto-installed — you run it once per machine.

1. Install rclone:
   ```bash
   brew install rclone
   ```

2. Configure the remote (one-time interactive setup):
   ```bash
   rclone config
   ```
   - Choose "n" for new remote
   - Name it (e.g., `whisper-backup`)
   - Choose your cloud provider from the list (OneDrive, Box, Dropbox, S3, etc.)
   - Follow OAuth prompts in browser
   - Accept defaults for remaining options

3. Test the connection:
   ```bash
   rclone lsd <your-cloud-remote>:
   ```
   Should list your cloud folders.

4. Sync command (run via launchd or cron):
   ```bash
   # Sync screenshots
   rclone sync ~/.whisper_log/screenshots/ <your-cloud-remote>:WhisperBackup/screenshots/ --update --progress

   # Sync recordings
   rclone sync upstream/Careless-Whisper/recordings/ <your-cloud-remote>:WhisperBackup/recordings/ --update --progress
   ```
   The `--update` flag skips files that are newer on the destination.

5. Restore command (used in Part 9):
   ```bash
   # Restore screenshots (absolute path — CWD-independent)
   rclone copy <your-cloud-remote>:WhisperBackup/screenshots/ ~/.whisper_log/screenshots/

   # Restore recordings
   rclone copy <your-cloud-remote>:WhisperBackup/recordings/ ~/whisper-mac/upstream/Careless-Whisper/recordings/
   ```

6. Automation (optional): Create a launchd plist to run the sync daily. See `backup/README.md` for the pattern used by `backup_records.sh`.

## Part 11.5 — When things break: where to look

| Symptom | Log to capture / next step |
|---------|---------------------------|
| Hammerspoon hotkeys silent | Hammerspoon menubar → Console (errors live here) |
| Batch mode produces no text | `tail -200 ~/.whisper_log/hook.log` and `tail -200 /tmp/whisper_debug.log` |
| Worker stages stuck "pending" | `tail -200 ~/.whisper_log/trace.jsonl` |
| Backup launchd job not running | `cat ~/.whisper_log/backup-records.{out,err}.log` and `launchctl list \| grep whisper.backup` |
| Streaming overlay missing | Hammerspoon Console + verify Screen Recording permission (`docs/macos-permissions.md`) |
| `disaster_recovery_check.sh` RED | Re-read the failing line — every check has a remediation hint inline |
| Mouse buttons unresponsive | Verify Logi Options+ profile (`docs/mouse-mapping.md`) and Input Monitoring permission |
| Copilot Device Flow stuck | Re-run `bash upstream/Careless-Whisper/whisper.sh auth` (idempotent) |
| Model SHA mismatch | Delete the file in `~/whisper-models/` and re-run `bash bin/install_models.sh` |

If a step fails and the runbook doesn't cover it, document under `rpi/<problem-name>/research.md` per project convention (see `MASTER_PROJECT.md`).

## Part 12 — Total time + checklist

| Part | Time | Task |
|------|------|------|
| 1 | 10 min | Prerequisites (Xcode CLT, Homebrew, gh auth, git clone) |
| 2 | 15 min | Install dependencies (brew, Logi Options+, pip) |
| 3 | 10 min | Download whisper models (4.6 GB total) |
| 4 | 1 min | Sync Hammerspoon Lua to live location |
| 5 | 5 min | Run Bjorn's installer + Copilot Device Flow |
| 6 | 1 min | (Optional) Add a secret to keychain for Hammerspoon auto-typing |
| 7 | 5 min | Launch Hammerspoon + grant macOS permissions |
| 8 | 3 min | Configure Logi Options+ mouse buttons |
| 9 | varies | Restore runtime data (records.json, screenshots, recordings) |
| 10 | 3 min | Smoke tests (batch, streaming, HTML log) |
| 11 | 15 min | Off-machine cloud backup setup (one-time) |
| **Total** | **60-75 min** | **Without data restore** |
| **Total** | **70-85 min** | **With cloud data restore** |

### Mental checklist

- [ ] Xcode CLT installed
- [ ] Homebrew installed
- [ ] gh CLI authenticated to github.com
- [ ] whisper-mac repo cloned
- [ ] Brew packages installed (whisper-cpp, ffmpeg, lua@5.4, sdl2, hammerspoon)
- [ ] Logi Options+ installed
- [ ] Python Pillow installed
- [ ] Whisper models downloaded and SHA-verified
- [ ] Hammerspoon Lua synced to ~/.hammerspoon/
- [ ] Bjorn's installer run (Copilot Device Flow complete)
- [ ] (Optional) Keychain entry configured for Hammerspoon auto-typing
- [ ] Hammerspoon launched with 5 permissions granted
- [ ] Logi Options+ buttons mapped
- [ ] records.json restored
- [ ] Screenshots and recordings restored (if available)
- [ ] HTML log re-rendered
- [ ] Smoke tests passed (batch + streaming)
- [ ] disaster_recovery_check.sh GREEN
- [ ] rclone configured for cloud backup (optional but recommended)

## Appendix — Recovery if you have a working backup vs not

| Scenario | What you get | What you lose | Backfill options |
|----------|--------------|---------------|------------------|
| **You backed up records.json + cloud screenshots/recordings** | Full restore: all 135 transcription records, all screenshots, all audio | Nothing | n/a |
| **You backed up records.json only** | All transcription records (text + metadata) | Screenshots and recordings | Can re-render HTML from records.json; cannot recover audio |
| **No backup** | Fresh system with no history | Entire transcription history | Can backfill text from WAV files if they survived: `python3 bin/backfill.py --all` (requires WAVs in `upstream/Careless-Whisper/recordings/`) |

If you have no backup and no surviving WAV files, you start from zero. This is why Part 11 (cloud backup) is critical.
