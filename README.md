# whisper-mac

Local speech-to-text on macOS, optimized for daily heavy use. Two recording
pipelines (batch + low-latency streaming), global hotkeys via Hammerspoon,
mouse side-button bindings, browser-friendly status pages, and a
transcription log with rolling history.

Built on top of [Bjorn Pleger's Careless-Whisper](https://github.com/bpleger/Careless-Whisper)
(see `upstream/Careless-Whisper/`), with significant additions for streaming,
mouse triggers, log dashboards, and Hammerspoon integration.

> **Privacy note.** Everything runs locally. Audio never leaves the machine.
> The optional AI post-processing in upstream Careless-Whisper uses the
> GitHub Copilot API and is opt-in.

---

## Features

- **Batch mode** — `Ctrl+Cmd+W` to start, `Ctrl+Cmd+Q` to stop & transcribe.
  Uses `whisper-cli` with the `medium.en` GGML model.
- **Streaming mode** — mouse side buttons (Forward / Back) trigger
  low-latency live transcription with `whisper-stream` + `base.en`.
- **Mouse mapping** — Logi Options+ remaps mouse buttons to
  `Ctrl+Shift+Cmd+9` and `Ctrl+Shift+Cmd+0`, picked up by Hammerspoon.
- **Self-healing microphone** — Hammerspoon detects the best connected mic
  by name and rewrites the AVFoundation index in `whisper-stt.conf` when
  USB devices are plugged/unplugged.
- **Transcription log** — `~/.whisper_log/records.json` accumulates every
  recording. HTML pages render this as a browsable dashboard.
- **Dictionary corrections** — apply a TSV of misheard→correct pairs to
  every transcript (great for proper names, product terms, jargon).
- **Clipboard image paste** — `Ctrl+Shift+Cmd+V` saves clipboard images to
  `~/Downloads/screenshots/` and types the file path (handy for AI tools).

---

## Hotkeys & Mouse

| Trigger                   | Action                                                |
| ------------------------- | ----------------------------------------------------- |
| `Ctrl+Cmd+W`              | Start batch recording (fast path: direct ffmpeg)      |
| `Ctrl+Cmd+Q`              | Stop & transcribe                                     |
| `Ctrl+Shift+Cmd+R`        | Re-transcribe last recording                          |
| `Shift+Cmd+R`             | Toggle (upstream Careless-Whisper hotkey)             |
| `Shift+Cmd+Q`             | Emergency stop (upstream)                             |
| `Ctrl+Shift+Cmd+9` / `0`  | Streaming start / stop (mapped from mouse via Logi)   |
| `Ctrl+Shift+Cmd+V`        | Paste clipboard image as file path                    |
| `Cmd+L`                   | Lock screen                                           |

See [`docs/mouse-mapping.md`](docs/mouse-mapping.md) for the Logi Options+
configuration that turns mouse Forward/Back into the streaming hotkeys.

---

## Repository Layout

```
whisper-mac/
├── README.md                       # This file
├── ARCHITECTURE.md                 # How the pieces fit together
├── .gitignore
├── whisper.sh                      # Top-level batch wrapper
├── models.sha256                   # Checksums for GGML models
├── requirements.txt                # Python deps for log/render scripts
├── nav.js                          # Shared nav bar for HTML pages
├── styles.css                      # Shared styles
├── index.html                      # Status dashboard
├── installation.html               # Install guide (browser)
├── controls.html                   # Hotkey reference (browser)
├── streaming.html                  # Streaming mode docs (browser)
├── architecture.html               # Architecture diagram (browser)
├── troubleshooting.html            # FAQ (browser)
│
├── bin/                            # Python + shell helpers
│   ├── transcription_log.py        # Main log writer & query tool
│   ├── transcription_worker.py     # Background transcription worker
│   ├── _html_render.py             # Renders log → HTML dashboard
│   ├── _status_render.py           # Renders live status snippet
│   ├── backfill.py                 # Backfill log from old recordings
│   ├── install_models.sh           # Download GGML models
│   ├── sync_hammerspoon.sh         # Copy Lua files into ~/.hammerspoon/
│   ├── whisper_log_hook.sh         # Hook called by whisper.sh after each run
│   └── whisper_debug_tail.sh       # Tail debug log live
│
├── hammerspoon/                    # Lua glue for Hammerspoon
│   ├── README.md
│   ├── init.lua                    # Example config (customize freely)
│   ├── whisper_streaming.lua       # Streaming pipeline (whisper-stream)
│   ├── whisper_mouse.lua           # Mouse side-button bindings
│   ├── whisper_overlay.lua         # On-screen overlay during recording
│   └── whisper_debug.lua           # Debug helpers
│
├── docs/
│   ├── mouse-mapping.md            # Logi Options+ setup
│   └── macos-permissions.md        # Accessibility / Mic / Input Monitoring
│
└── upstream/
    └── Careless-Whisper/           # Vendored Bjorn Pleger upstream
        ├── README.md
        ├── install.sh / uninstall.sh
        ├── whisper.sh              # Upstream batch script
        ├── whisper_hotkeys.lua     # Upstream hotkeys + menubar
        ├── whisper_streaming.lua   # Upstream streaming
        ├── whisper-stt.conf        # Example config
        ├── transcription_corrections.tsv  # Example dictionary
        └── UPSTREAM_PROVENANCE.md  # Attribution & changes
```

---

## Installation

### 1. Prerequisites

```bash
# Homebrew packages
brew install ffmpeg whisper-cpp
brew install --cask hammerspoon

# Python (for log/render scripts)
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

You also need to grant macOS permissions — see
[`docs/macos-permissions.md`](docs/macos-permissions.md):

- **Accessibility**: Hammerspoon, Terminal/iTerm
- **Microphone**: Hammerspoon, ffmpeg (via Terminal)
- **Input Monitoring**: Hammerspoon (for mouse eventtap)

### 2. Clone

```bash
git clone https://github.com/dawidbednarczyk/whisper-mac.git ~/whisper-mac
cd ~/whisper-mac
```

### 3. Download models

```bash
./bin/install_models.sh
```

This pulls `ggml-medium.en.bin` (batch) and `ggml-base.en.bin` (streaming)
into `~/whisper-models/`. Sizes ≈ 1.5 GB and 150 MB respectively.

Verify with:

```bash
shasum -a 256 -c models.sha256
```

### 4. Wire up Hammerspoon

```bash
./bin/sync_hammerspoon.sh
```

This copies the `hammerspoon/*.lua` files into `~/.hammerspoon/`. Open
Hammerspoon, click the menubar icon, choose **Reload Config**.

The example `init.lua` references `~/whisper-mac` as the install path.
Adjust the `WHISPER_REPO` constant at the top if you cloned elsewhere.

### 5. Configure mouse (optional but recommended)

Install [Logi Options+](https://www.logitech.com/software/logi-options-plus.html)
and follow [`docs/mouse-mapping.md`](docs/mouse-mapping.md) to remap the
Forward/Back side buttons to `Ctrl+Shift+Cmd+9` and `Ctrl+Shift+Cmd+0`.

### 6. First run

Press `Ctrl+Cmd+W`, speak for a few seconds, press `Ctrl+Cmd+Q`. The
transcript should be auto-pasted into the focused app, and a new entry
should appear in `~/.whisper_log/records.json`.

Open `index.html` in a browser to see the status dashboard.

---

## Configuration

Two config surfaces:

1. **`upstream/Careless-Whisper/whisper-stt.conf`** — model path, language,
   audio device index, max recording length, post-processing mode. See
   the upstream README for the full table.
2. **`hammerspoon/init.lua`** — hotkey bindings, mic priority list,
   `WHISPER_REPO` path. Edit and reload Hammerspoon.

Dictionary corrections live in
`upstream/Careless-Whisper/transcription_corrections.tsv`. Format is
`<misheard><TAB><correct>` per line. Applied automatically on every
transcript.

---

## Models

| Model               | Size    | Pipeline   | Notes                          |
| ------------------- | ------- | ---------- | ------------------------------ |
| `ggml-medium.en`    | ~1.5 GB | Batch      | High quality, English-only     |
| `ggml-base.en`      | ~150 MB | Streaming  | Low latency, English-only      |

Multilingual variants (`ggml-medium.bin`, etc.) work too — set
`WHISPER_LANGUAGE` in the conf file. Download from
[Hugging Face](https://huggingface.co/ggerganov/whisper.cpp).

---

## Troubleshooting

See [`troubleshooting.html`](troubleshooting.html) (open in a browser) for
the full FAQ. Highlights:

- **Hotkey does nothing** → reload Hammerspoon config, check Accessibility.
- **Mouse buttons do nothing** → check Input Monitoring permission for
  Hammerspoon, verify Logi Options+ is running.
- **No audio** → run `./whisper.sh list-devices`, update
  `WHISPER_AUDIO_DEVICE` in the conf file (or rely on self-healing).
- **Slow first recording** → expected; Metal kernels JIT on first use.
  Subsequent recordings are instant.

---

## Architecture

See [`ARCHITECTURE.md`](ARCHITECTURE.md) for a detailed walkthrough of how
batch mode, streaming mode, the log, and the HTML dashboard fit together.

---

## License

This repo is MIT licensed. The upstream Careless-Whisper code is
redistributed under its own license — see
`upstream/Careless-Whisper/UPSTREAM_PROVENANCE.md`.
