# Transcription Log

The transcription log is the persistence and visualization layer that
turns every recording made through `whisper-mac` into a row in a
local, browseable dashboard with the full multi-stage pipeline output.

> **TL;DR** — Every recording produces one entry in
> `~/.whisper_log/records.json`, that entry runs through six pipeline
> stages, and `~/.whisper_log/transcriptions.html` renders the result
> as a self-refreshing local webpage you open with `file://`.

---

## 1. Why it exists

A single recording isn't transcribed once — it goes through up to six
variants so you can compare quality vs latency:

| Stage | Model           | Variant   | Typical use                              |
|-------|-----------------|-----------|------------------------------------------|
| 1     | `base.en`       | raw       | Fastest output, raw whisper              |
| 2     | `base.en`       | corrected | TSV dictionary applied                   |
| 3     | `medium.en`     | raw       | Mid-tier accuracy, raw                   |
| 4     | `medium.en`     | corrected | Mid-tier with dictionary corrections     |
| 5     | `large-v3`      | raw       | Best whisper accuracy, raw               |
| 6     | `large-v3`      | corrected | Best + dictionary + Copilot post-process |

"Corrected" stages apply a TSV of misheard→correct pairs (proper names,
product terms, jargon) and — for the large-v3 stage — an optional Copilot
post-process pass for grammar.

The log lets you:

- See which stage a recording is currently at (status badge per stage).
- Compare the same audio across all six outputs side-by-side.
- Backfill historical WAVs that were recorded before the log was wired up.
- Attribute each recording to the project / app you were working on at
  the moment you pressed record (via screenshot OCR — see §5).

---

## 2. Files in `~/.whisper_log/`

The directory is created automatically on first append.

| Path                           | Role                                                 |
|--------------------------------|------------------------------------------------------|
| `records.json`                 | Source of truth: one JSON object per recording       |
| `status.json`                  | Aggregate counts (queued / running / done / failed)  |
| `transcriptions.html`          | Rendered dashboard (open with `file://`)             |
| `queue/<basename>__<stage>.todo` | Pending work item for the worker                   |
| `queue/<basename>__<stage>.running` | Worker has claimed this item                    |
| `worker.lock`                  | Single-worker mutex (advisory `flock`)               |
| `worker.log`                   | Worker stdout/stderr log                             |
| `trace.jsonl`                  | Append-only event trace (debugging)                  |
| `screenshots/<basename>.png`   | Hammerspoon screenshot at button-down                |
| `extract_project.log`          | Project-attribution script log                       |

---

## 3. The flow of one recording

```
   ┌─ Hammerspoon (whisper_streaming.lua, whisper_mouse.lua)
   │     button-down → write t0 sidecar + capture screenshot
   │
   ├─ whisper.sh (upstream Careless-Whisper)
   │     records WAV, runs first-pass transcription
   │
   ├─ bin/whisper_log_hook.sh
   │     bridge: invokes ↓
   │
   ├─ bin/transcription_log.py append
   │     creates record in records.json,
   │     enqueues queue/<basename>__stage{1..6}.todo,
   │     calls _maybe_spawn_workers_for(basename) → Popen()
   │
   ├─ bin/transcription_worker.py  (auto-spawned, no launchd needed)
   │     pulls .todo → renames to .running → runs whisper.cpp
   │     → writes stage output back to records.json
   │     → re-renders transcriptions.html and status.json
   │
   └─ Browser (open transcriptions.html as file://)
         <script type="module"> polls records.json every 5 s
```

Key property: **the worker is auto-spawned by the append call**. No
`launchd` plist, no background daemon to install. The first append after
boot starts the worker; the worker's `flock` on `worker.lock` prevents
duplicates.

---

## 4. Opening the dashboard

```bash
open ~/.whisper_log/transcriptions.html
```

The page loads `records.json` over `file://`, renders a row per recording,
and self-refreshes every 5 seconds while you watch stages complete. Stage
cells go through:

- ⏳ `queued` — `.todo` file exists, worker not yet processing
- ▶️ `running` — `.running` file exists, whisper.cpp is transcribing
- ✅ `done` — text written to `records.json`
- ⚠️ `degraded` — completed but with a `degraded_note` (e.g. Copilot
  unreachable for stage 6)
- ❌ `failed` — worker error, see `worker.log`

---

## 5. Project attribution

When Hammerspoon captures a recording, it also takes a screenshot of
your active screen (not the audio — just one PNG) and saves it to
`~/.whisper_log/screenshots/<basename>.png`. After the recording
finishes, `bin/extract_project_from_screenshot.py` runs:

1. OCR the screenshot (Tesseract).
2. Look for cwd-style indicators in terminal panes / status lines
   (`~/projects/foo:main`, OpenCode statusline, IDE title bars).
3. Apply STOP-words to filter out container folders (`Documents`,
   `Users`, `projects`, `ai_projects`, etc.) and the current `$USER`.
4. Optionally consult an LLM if heuristics are inconclusive.
5. Write `project` and `project_source` fields back into the record.

The dashboard shows the inferred project as a column so you can filter
"only show me recordings made while working on Project X".

If the screenshot doesn't contain enough signal (browser-only screen,
locked Mac, etc.) the field stays empty — non-fatal.

---

## 6. Backfilling

If you have WAVs that were recorded before the log existed (or before
`whisper-mac` was installed), enqueue them with:

```bash
python3 bin/backfill.py            # 20 newest WAVs
python3 bin/backfill.py 50         # 50 newest
python3 bin/backfill.py --all      # everything
```

Defaults look in `$WHISPER_HOME/upstream/Careless-Whisper/recordings/`.
Set `WHISPER_HOME` to override; otherwise the script auto-detects the
repo root from its own location, then falls back to `~/whisper-mac`.

`backfill.py` is idempotent — re-running skips WAVs already in the log.

The maintenance flag `--strip-degraded-suffix` migrates legacy in-text
notes (e.g. `[copilot empty response]` appended to stage text by old
worker versions) into the structured `degraded_note` field.

---

## 7. Schema (`records.json`)

```jsonc
{
  "20260509-143022_my-recording": {
    "t0_epoch": 1715268622.531,
    "wav_path": "/Users/<you>/whisper-mac/upstream/.../my-recording.wav",
    "duration_ms": 4280,
    "project": "whisper-mac",
    "project_source": "screenshot:cwd_match",
    "stages": {
      "base.en_raw":      { "status": "done",     "text": "...", "duration_ms": 410 },
      "base.en_corr":     { "status": "done",     "text": "...", "duration_ms": 415 },
      "medium.en_raw":    { "status": "done",     "text": "...", "duration_ms": 1820 },
      "medium.en_corr":   { "status": "done",     "text": "...", "duration_ms": 1830 },
      "large-v3_raw":     { "status": "running" },
      "large-v3_corr":    { "status": "queued" }
    },
    "screenshot_path": "/Users/<you>/.whisper_log/screenshots/20260509-143022_my-recording.png"
  }
}
```

Top-level keys are recording basenames (timestamp + slug). Each record
has `stages` keyed by `<model>_<variant>`.

---

## 8. Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Page is blank / empty rows | `records.json` empty (no recordings yet) | Trigger one recording with Ctrl+Cmd+W → Ctrl+Cmd+Q |
| Stages stuck at ⏳ queued | Worker not running | Check `~/.whisper_log/worker.log`; remove stale `worker.lock` if no `whisper-cli` process exists; trigger another recording or run `python3 bin/backfill.py 1` to re-spawn |
| Page won't open / `file://` blocked | Some browsers refuse `file://` JS modules | Use Safari, or `python3 -m http.server` from `~/.whisper_log/` and open `http://localhost:8000/transcriptions.html` |
| Project column always empty | OCR found no match, or `extract_project_from_screenshot.py` failed | See `~/.whisper_log/extract_project.log`; verify Tesseract is installed (`brew install tesseract`) |
| Stage 6 shows `degraded_note: "no copilot token"` | Optional Copilot auth missing | Configure auth.json (see installation Step 8) — this is expected if you skipped that step |
| Dictionary corrections not applied | `transcription_corrections.tsv` missing or unreadable | Ensure the TSV exists in the path your `whisper.sh` configuration points to; format is one `wrong\tright` pair per line |

---

## 9. See also

- `ARCHITECTURE.md` — high-level pipeline and module map
- `installation.html` — Step 10 has a smoke-test for the log
- `recovery.md` — recovering the log after a wipe / fresh system
- `bin/transcription_log.py --help` — CLI surface
