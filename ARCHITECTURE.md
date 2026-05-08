# Architecture

Two independent recording pipelines share a common log and dashboard.

## Pipeline A — Batch mode

For dictating longer chunks where quality matters more than latency.

```
Ctrl+Cmd+W
   │
   ▼
hammerspoon/init.lua → whisperStartFast()
   │  hs.task.new(ffmpeg, ...)
   ▼
ffmpeg  -f avfoundation -i :<device>
        -ar 16000 -ac 1
        $TMPDIR/whisper_segments/segment_001.wav
   │
   │   (recording continues until user presses Ctrl+Cmd+Q)
   │
Ctrl+Cmd+Q
   │
   ▼
upstream/Careless-Whisper/whisper.sh stop
   │
   ├─ concat segments → whisper_recording.wav
   ├─ whisper-cli ggml-medium.en.bin → whisper_output.txt
   ├─ apply transcription_corrections.tsv
   ├─ (optional) Copilot API post-processing
   ├─ pbcopy → clipboard
   ├─ AppleScript Cmd+V auto-paste
   └─ bin/whisper_log_hook.sh → bin/transcription_log.py append
```

Key files:
- `hammerspoon/init.lua` — fast-path ffmpeg starter (saves ~300–500 ms vs.
  shelling into bash, so the first words aren't clipped).
- `upstream/Careless-Whisper/whisper.sh` — stop, transcribe, paste, log.
- `upstream/Careless-Whisper/whisper_hotkeys.lua` — menubar UI + alternative
  `Shift+Cmd+R` toggle hotkey.

## Pipeline B — Streaming mode

For real-time dictation into chat / Slack / Webex where you want to see
words appear as you speak.

```
Mouse Forward button (Logi Options+ → Ctrl+Shift+Cmd+9)
   │
   ▼
hammerspoon/whisper_mouse.lua  →  hammerspoon/whisper_streaming.lua start()
   │
   ▼
/opt/homebrew/bin/whisper-stream
   -m ggml-base.en.bin
   -t 8 --step 500 --length 5000
   │
   │  stdout: rolling transcript with VAD-detected segments
   │
   ▼
whisper_streaming.lua post-processor:
   ├─ apply transcription_corrections.tsv (dictionary)
   ├─ deduplicate against last emitted segment
   ├─ hs.eventtap.keyStrokes() into focused app
   └─ append to ~/.whisper_log/records.json (streaming bucket)
   │
Mouse Back button (Logi Options+ → Ctrl+Shift+Cmd+0)
   │
   ▼
whisper_streaming.lua stop()
```

Key files:
- `hammerspoon/whisper_streaming.lua` — owns the whisper-stream process,
  parses output, applies dictionary, types into focused app.
- `hammerspoon/whisper_mouse.lua` — registers mouse-button hotkeys.
- `hammerspoon/whisper_overlay.lua` — on-screen dot showing recording state.

## Shared log

Both pipelines append to `~/.whisper_log/records.json` (one JSON object per
line, append-only). Schema:

```json
{
  "ts": "2026-05-08T10:23:45+02:00",
  "mode": "batch",          // or "streaming"
  "duration_sec": 12.4,
  "text": "the transcribed text...",
  "model": "ggml-medium.en",
  "device": "MacBook Pro Microphone",
  "post_process": "off"     // or "clean", "messenger", ...
}
```

Helpers:
- `bin/transcription_log.py` — append, query, export. Run with `--help`.
- `bin/_html_render.py` — render the log as the dashboard in `index.html`.
- `bin/_status_render.py` — render the live status snippet.
- `bin/backfill.py` — reconstruct the log from old `whisper.sh` history.

## HTML dashboard

`index.html` plus the other top-level `.html` files share `nav.js` and
`styles.css`. They are static — no server. The dashboard reads
`~/.whisper_log/records.json` via a small `<script type="module">` block
that the render scripts emit.

`bin/_status_render.py` writes a compact status JSON that
`index.html` polls to show:

- Whether a recording is currently active (mode + elapsed time)
- Last 5 transcripts with copy buttons
- Per-day word counts and totals

## Hammerspoon entry point

`hammerspoon/init.lua` is the user-editable example config. It:

1. Loads upstream `whisper_hotkeys.lua` for the menubar + `Shift+Cmd+R`.
2. Defines fast-path `whisperStartFast()` and binds it to `Ctrl+Cmd+W`.
3. Wires `Ctrl+Cmd+Q` to `whisper.sh stop`.
4. Sets up the mic self-healing function (priority list of device names).
5. Loads `whisper_mouse.lua` via `dofile` (for reliable eventtap timing).
6. Pre-warms whisper Metal kernels 2 s after Hammerspoon loads.

The `WHISPER_REPO` constant at the top of `init.lua` should point at
wherever you cloned this repo. Default is `~/whisper-mac`.

## Why two pipelines?

- **Batch** uses `medium.en`, runs whisper-cli once on the full WAV, and
  produces the highest-quality output. Latency = recording length + ~2 s.
- **Streaming** uses `base.en` (10x smaller), runs whisper-stream
  continuously with overlapping windows, and types as you speak. Quality
  is lower but text appears in real time, which matters for chat.

You can use both — start in batch mode for thoughtful dictation, switch
to streaming for live conversation typing.
