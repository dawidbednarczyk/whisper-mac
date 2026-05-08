# Hammerspoon configuration (mirror)

This is a **mirror copy** of Hammerspoon Lua files that drive the Whisper hotkey/mouse pipeline. The live, executing copies are in `~/.hammerspoon/`.

## Files
- `init.lua` — main Hammerspoon config (loads modules, defines hotkeys, ffmpeg/whisper paths)
- `whisper_streaming.lua` — streaming transcription pipeline (whisper-stream → corrections → paste)
- `whisper_mouse.lua` — Logi side-button bindings (forward/back/middle)
- `whisper_overlay.lua` — on-screen overlay during recording/transcription
- `whisper_debug.lua` — structured event logger to `/tmp/whisper_debug.log`

## Sync
Use `bin/sync_hammerspoon.sh` to sync between repo and live copies:

```bash
bin/sync_hammerspoon.sh push   # repo → ~/.hammerspoon/  (then restart Hammerspoon)
bin/sync_hammerspoon.sh pull   # ~/.hammerspoon/ → repo  (commit afterward)
bin/sync_hammerspoon.sh diff   # show drift
```

## Workflow
1. Edit live files in `~/.hammerspoon/` for fast iteration (or here, then `push`).
2. Hard-restart Hammerspoon to apply: `pkill -x Hammerspoon && open -a Hammerspoon`
3. When stable, `bin/sync_hammerspoon.sh pull` (if edited live) and commit.

## Tags / changelog
Significant behavior tags are embedded in source as `F-<TAG> (YYYY-MM-DD)`:
- `F-Back-NoRec` — back button when idle pastes latest base_raw text
- `F-Back-NoAutoPaste` — back button on stop suppresses auto-paste; second press pastes
- `F-S0-*` — see `rpi/paste-bugs-and-stats-overhaul/` QC review
