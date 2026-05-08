# RPI Handoff — whisper-mac public rebuild

**Audience:** Any AI agent (Cursor, Claude Code, OpenCode, ChatGPT, etc.) cloning this repo to continue the rebuild.
**Status:** Phase 0 (sanitization) complete. Phases I → III still TODO.
**Created:** 2026-05-08

This document is the entry point. Read it fully before changing any code.

---

## Goal

Make `github.com/dawidbednarczyk/whisper-mac` install and run cleanly on **any** macOS machine via a single `git clone + ./install.sh`. Full feature parity:

- Batch mode (push-to-talk hotkey → record → transcribe → paste at cursor)
- Streaming mode (live transcription overlay via `whisper_streaming.lua`)
- Overlay UI (`whisper_overlay.lua`) — must work in **both** batch and streaming
- 6-stage transcription log + browser-based history preview
- Mouse side/middle button bindings (`whisper_mouse.lua`)
- User correction dictionary (`transcription_corrections.tsv`)
- GitHub Copilot AI post-processing
- Auto-detect `whisper-cli` location (Apple Silicon `/opt/homebrew/` vs Intel `/usr/local/`)

---

## What's already done (Phase 0)

This commit:

1. **Sanitized 62 hardcoded path leaks** in 10 files. All `~/Documents/claude_projects/...` references replaced with `${WHISPER_HOME:-$HOME/whisper-mac}/...` (shell) or `(os.getenv("WHISPER_HOME") or (os.getenv("HOME") .. "/whisper-mac"))` (lua).
2. **Removed out-of-scope files** from `bin/`: `label_audit.py`, `extract_project_from_screenshot.py`, `test_labeler.py`, `relabel_unsorted.py`, `backfill.py`. These are author-internal audit tooling, not user-facing.
3. **Confirmed clean** — no remaining matches for `claude_projects`, internal usernames, internal Cisco GHE URLs, hardcoded `/Users/` paths, or internal email domains in any tracked file.

The repo now **looks** clean. It is **not yet verified to install end-to-end on a fresh machine.** That's the next phase.

---

## What's still TODO (Phases I–III)

### Phase I — Research

Three parallel investigations needed. If your AI tool supports subagents (OpenCode `@explorer`, Claude Code Task, Cursor Composer multi-file), dispatch them in parallel. Otherwise serialize.

**Agent A — Remaining-leak audit + portability**

Find every:
- Hardcoded absolute path (`/opt/homebrew/`, `/usr/local/`, `/Users/...`)
- Hardcoded model path
- Apple-Silicon-only assumption
- Reference to a specific upstream that may not be reachable from a public clone (the `upstream/Careless-Whisper/` provenance — see Phase II)

Group findings: **HARD LEAK** (ship blocker) / **PORTABILITY** (Intel Mac, alternate brew prefix) / **PROVENANCE** (upstream attribution) / **DUPLICATE** (root vs `upstream/`) / **SAFE**.

Cite `file:line` for every claim. Do NOT modify files.

**Agent B — Install + dependencies + 3 known gaps**

Map:
- External dependencies (`whisper.cpp`, Hammerspoon, `ffmpeg`, `sox`, `jq`, `python3`, GitHub Copilot auth, model files)
- Current install steps (there is no top-level `install.sh` yet — only `upstream/Careless-Whisper/install.sh` which itself has issues)
- What needs to symlink into `~/.hammerspoon/`
- Hotkey bindings declared in `whisper-stt.conf`
- Post-install verification (how do we prove install succeeded?)

Then root-cause the **3 known gaps** reported by previous testers:

1. **Overlay window only fires in batch, not streaming** on fresh installs. Compare `hammerspoon/whisper_overlay.lua` (344 lines, screen-aware) vs `upstream/Careless-Whisper/whisper_overlay.lua` (308 lines) and figure out why streaming doesn't trigger it.
2. **Mouse side/middle buttons not working** — docs missing config. Check `whisper_mouse.lua` for the binding API and document required `~/.hammerspoon/` setup.
3. **Web-preview server (transcription history HTML) not reachable** on fresh installs. The render lives in `bin/_html_render.py` (998 lines) writing to `~/.whisper_log/transcriptions.html`. Find what's supposed to serve it and why a fresh install can't reach it.

**Agent C — Runtime architecture**

Build a component map:

```
trigger (hotkey or mouse) → whisper.sh → whisper-cli → corrections.tsv → Copilot → paste → log hook → worker → web preview
```

For batch AND streaming flows separately. Document the 6-stage log state machine (`bin/transcription_log.py` + `bin/transcription_worker.py`):

- Storage: `~/.whisper_log/` → `records.json`, `status.json`, `transcriptions.html`, `queue/<basename>__<stage>.{todo,running}`, `worker.lock`, `worker.log`
- Models: `base.en`, `medium.en`, `large-v3` → `~/whisper-models/ggml-*.bin`
- Timeouts: `PER_STAGE_TIMEOUT_S=600`, `RUNNING_STALE_S=600`, `ABANDONED_AFTER_S=86400`

**Critical decision Agent C must make:** there are TWO copies of `whisper_streaming.lua`, `whisper_mouse.lua`, `whisper_overlay.lua`, and `whisper.sh` (root or `hammerspoon/` vs `upstream/Careless-Whisper/`). Which is canonical? Recommend collapsing to one. Hint: the `hammerspoon/` versions are larger and appear more recent.

Synthesize all three into `docs/research.md`. Score against FAR (Findings, Assumptions, Risks) ≥7/10.

### Phase II — Plan

Write `docs/plan.md`:

- Sanitization map (every remaining replacement, file:line → new value)
- Installer spec (`install.sh` at repo root: detect brew prefix → install deps → download models → write `whisper-stt.conf` → symlink into `~/.hammerspoon/` → start worker → verify)
- Verification harness (steps to prove install succeeded on a fresh Mac in a `/tmp` dir)
- Fix plan for each of the 3 known gaps
- Decision: collapse duplicate lua/sh files, keep which?
- Upstream provenance decision: keep `upstream/Careless-Whisper/` as a vendored copy with a `UPSTREAM_PROVENANCE.md` pointing to the legitimate public upstream, or delete and depend on the published upstream directly?

Score against FACTS (Feasibility, Assumptions, Constraints, Trade-offs, Scope) ≥7/10.

### Phase III — Execute

Stage in a clean dir (`/tmp/whisper-mac-staging/`), apply the plan, build `install.sh` at root, write user-facing docs, push to `main`. Verify with a real fresh `git clone` + `./install.sh` in `/tmp`.

Then run a cyclic quality review (max 4 cycles): re-clone, re-install, fix what breaks, repeat until installation is bulletproof.

---

## Constraints (MUST follow)

- **Install root:** `$WHISPER_HOME` env var, default `~/whisper-mac`, written to `whisper-stt.conf`.
- **No assumed Apple Silicon.** Auto-detect `whisper-cli` via `brew --prefix` or `command -v`.
- **No hardcoded usernames** in any shipped file. Use `$HOME`, `~`, or `${WHISPER_HOME}`.
- **Public excludes** (these must NEVER appear in this repo): user-specific recordings, `records.json` content, internal author project notes, internal status files, any internal-corporate identifiers.
- **Out-of-scope files** (do not re-add): `label_audit.py`, `extract_project_from_screenshot.py`, `test_labeler.py`, `relabel_unsorted.py`, `backfill.py`. These are author-internal audit tooling.

---

## Repo structure (current)

```
whisper-mac/
├── README.md, ARCHITECTURE.md, *.html              # user docs
├── styles.css, nav.js                              # docs styling
├── whisper.sh                                      # 9.2K ROOT shim (small)
├── requirements.txt                                # python deps
├── models.sha256                                   # whisper.cpp model hashes
├── .gitignore
├── bin/                                            # python + bash backend
│   ├── transcription_log.py      (731 lines)       # log writer
│   ├── transcription_worker.py   (736 lines)       # 6-stage worker
│   ├── _html_render.py           (998 lines)       # web preview renderer
│   ├── _status_render.py
│   ├── whisper_log_hook.sh                         # bridge from whisper.sh → log
│   ├── install_models.sh                           # pulls ggml-*.bin from HF
│   ├── backup_records.sh, disaster_recovery_check.sh, whisper_debug_tail.sh, sync_hammerspoon.sh
├── hammerspoon/                                    # production lua (canonical?)
│   ├── init.lua                  (350 lines)       # NOTE: needs minimal-public version
│   ├── whisper_streaming.lua     (1590 lines)
│   ├── whisper_mouse.lua         (340 lines)
│   ├── whisper_overlay.lua       (344 lines)       # screen-aware, multi-monitor
│   ├── whisper_debug.lua         (283 lines)
│   └── README.md
├── upstream/Careless-Whisper/                      # vendored upstream (smaller, older?)
│   ├── install.sh                (414 lines)
│   ├── whisper.sh                (1196 lines)      # the BIG one
│   ├── whisper_streaming.lua     (1200 lines)
│   ├── whisper_hotkeys.lua       (627 lines)
│   ├── whisper_mouse.lua         (87 lines)
│   ├── whisper_overlay.lua       (308 lines)
│   ├── whisper-stt.conf                            # user-editable config
│   └── UPSTREAM_PROVENANCE.md
└── docs/
    ├── recovery.md
    └── HANDOFF_RPI.md                              # ← you are here
```

Total: ~12,000 lines of bash + lua + python. Phase I should map every file's purpose before Phase II touches anything.

---

## Quick start for the next AI

```bash
# Clone
git clone https://github.com/dawidbednarczyk/whisper-mac.git ~/whisper-mac
cd ~/whisper-mac

# Read the docs first (in this order)
cat docs/HANDOFF_RPI.md           # this file
cat README.md
cat ARCHITECTURE.md

# Begin Phase I — leak audit
rg -n 'claude_projects|/Users/[a-z]+|wwwin-github\.cisco|@cisco\.com' .
# (should return zero matches; if not, that's the first thing to fix)

# Identify remaining portability landmines
rg -n '/opt/homebrew/|/usr/local/whisper-cli|hardcoded model path' .

# Then: write docs/research.md, docs/plan.md, then execute
```

When you commit:

- Use the same git author identity already configured on this clone (public Gmail).
- Do NOT push internal repo URLs, internal usernames, or anything that would re-introduce a leak.
- Squash exploratory commits before pushing to `main`.

---

## Why this handoff exists

The author's working tree lives in a private internal repo. This public repo is the publishable subset. Every change to the public repo must be staged, sanitized, and pushed without polluting the private tree. If you are an AI agent without access to the private tree, that is fine — everything you need is in this clone. If you find yourself wanting to reference internal-only paths or repos, stop and ask the human.

Good luck. Score quality, not speed.
