# Upstream Provenance — Careless-Whisper

This directory (`upstream/Careless-Whisper/`) is a flat snapshot of
[Bjorn Pleger's Careless-Whisper](https://github.com/bpleger/Careless-Whisper).
The original `.git/` was removed so the files live as plain content inside
this repo and don't create a nested-repo situation.

## Why vendored

Hammerspoon `init.lua` `dofile`'s several Lua files (`whisper_hotkeys.lua`)
and the shell pipeline (`whisper.sh`) from Bjorn's project. Vendoring keeps
this repo self-contained — no separate clone step, no version drift, no
broken paths if upstream moves.

## Source

| Field         | Value                                              |
| ------------- | -------------------------------------------------- |
| Upstream repo | https://github.com/bpleger/Careless-Whisper       |
| Snapshot date | 2026-04-28                                         |
| Branch        | `main`                                             |

If you want full git history, clone Bjorn's repo separately:

```bash
git clone https://github.com/bpleger/Careless-Whisper.git ~/Careless-Whisper-upstream
```

## What is used live

- `whisper.sh` — batch-mode shell pipeline invoked by Hammerspoon's
  `Ctrl+Cmd+Q` (stop & transcribe) handler.
- `whisper-stt.conf` — runtime config consumed by `whisper.sh`.
- `transcription_corrections.tsv` — example dictionary (extend with your
  own misheard→correct pairs).
- `install.sh` / `uninstall.sh` — Bjorn's installer / uninstaller for
  whisper-cli + models on a fresh Mac. (You can also use
  `bin/install_models.sh` for a slimmer model-only install.)
- `whisper_hotkeys.lua` — `dofile`'d by `hammerspoon/init.lua` for the
  menubar UI and `Shift+Cmd+R` toggle.
- `README.md`, `index.html` — Bjorn's original docs.

## Modifications from upstream

A small number of edits were made to make this snapshot portable:

- `whisper-stt.conf` — `WHISPER_MODEL_PATH` rewritten to use `${HOME}`
  instead of a hardcoded user path.
- `whisper_streaming.lua` — comment rephrased for generality.
- `README.md` — clone URL updated to point at upstream.

The original `.gitignore` is preserved as `.gitignore.bjorn-original`.

## Runtime artifacts

The transcription log (`~/.whisper_log/records.json`, HTML dashboards,
WAV captures) lives in `$HOME`, NOT in this repo. The Python helpers in
`bin/` write there.

## License

Bjorn's code is redistributed under his original license terms. See his
upstream repository for the canonical license file.
