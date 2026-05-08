"""
Transcription Log Manager
=========================

Single-writer JSON store for transcription records. Each record represents one
WAV file and holds 6 stage results (model x correction-mode combinations).

Public API
----------
- add_quick_record(t0_epoch, wav_path, quick_model_id, quick_text, quick_duration_ms)
    Called by the production hook right after the synchronous paste. Creates a
    new record (or updates existing), pre-fills the stage that matches the
    quick model with the provided text+duration, marks the other 5 stages as
    "pending", enqueues background jobs, and spawns the worker if not running.

- update_stage(wav_basename, stage_id, text, duration_ms_from_t0, error=None)
    Called by the background worker as each stage completes.

- get_pending_count()
    Returns the number of "pending" cells across all records (drives auto-refresh).

Storage layout (~/.whisper_log/)
--------------------------------
  records.json            -- one big JSON object keyed by wav_basename
  status.json             -- {pending_count, last_updated, total_records}
  transcriptions.html     -- rendered page (newest-first)
  queue/<basename>__<stage>.todo  -- pending background jobs
  queue/<basename>__<stage>.running -- in-flight (renamed by worker)
  worker.lock             -- PID file (single worker)
  worker.log              -- worker output
"""

from __future__ import annotations

import fcntl
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

LOG_DIR = Path(os.path.expanduser("~/.whisper_log"))
RECORDS_PATH = LOG_DIR / "records.json"
STATUS_PATH = LOG_DIR / "status.json"
HTML_PATH = LOG_DIR / "transcriptions.html"
QUEUE_DIR = LOG_DIR / "queue"
WORKER_LOCK = LOG_DIR / "worker.lock"  # legacy single-worker lock (kept for backward compat in worker)


def _worker_lock_path(stage_id: str) -> "Path":
    """Per-stage lock file. One worker process per stage runs concurrently."""
    return LOG_DIR / f"worker-{stage_id}.lock"
WORKER_LOG = LOG_DIR / "worker.log"
TRACE_LOG = LOG_DIR / "trace.jsonl"
TRACE_LOG_MAX_BYTES = 10 * 1024 * 1024  # 10 MB — rotate when exceeded
TRACE_LOG_KEEP_N = 3  # rotated files: trace.jsonl.1 … trace.jsonl.3

REPO_BIN_DIR = Path(__file__).resolve().parent
WORKER_SCRIPT = REPO_BIN_DIR / "transcription_worker.py"


# ---------------------------------------------------------------------------
# Stage-completion notification (sound + macOS Notification Center)
# ---------------------------------------------------------------------------
# Fire-and-forget: a short Tink chime + banner when base_raw finishes,
# a softer Glass chime + banner when large_corr finishes. Errors are silent
# (we never want a notification side-effect to break stage persistence).
#
# Disable by setting WHISPER_NOTIFY_DISABLED=1 in the environment.

_STAGE_NOTIFY = {
    "base_raw":   {"sound": "/System/Library/Sounds/Tink.aiff",
                   "title": "Whisper",
                   "body":  "Quick transcription ready"},
    "large_corr": {"sound": "/System/Library/Sounds/Glass.aiff",
                   "title": "Whisper",
                   "body":  "Improved transcription ready"},
}


def _emit_stage_done(stage_id: str, status: str) -> None:
    """Play a chime + post a macOS notification when a stage flips to 'done'.

    Best-effort, fire-and-forget. Never raises. Skips on error or when disabled.
    """
    if status != "done":
        return
    if os.environ.get("WHISPER_NOTIFY_DISABLED"):
        return
    cfg = _STAGE_NOTIFY.get(stage_id)
    if not cfg:
        return
    try:
        # Play the chime (non-blocking).
        subprocess.Popen(
            ["/usr/bin/afplay", cfg["sound"]],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL,
            close_fds=True,
        )
    except Exception:
        pass
    try:
        # Post a banner via osascript. No sound on the notification itself —
        # afplay above owns the audio so the two stages sound distinct.
        applescript = (
            f'display notification "{cfg["body"]}" with title "{cfg["title"]}"'
        )
        subprocess.Popen(
            ["/usr/bin/osascript", "-e", applescript],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL,
            close_fds=True,
        )
    except Exception:
        pass


def _rotate_trace_if_needed() -> None:
    """Rotate trace.jsonl when it exceeds TRACE_LOG_MAX_BYTES. Best-effort;
    any error is swallowed so rotation never breaks the caller."""
    try:
        if not TRACE_LOG.exists():
            return
        if TRACE_LOG.stat().st_size < TRACE_LOG_MAX_BYTES:
            return
        # Shift .N-1 → .N, .1 → .2, current → .1
        for i in range(TRACE_LOG_KEEP_N, 0, -1):
            src = TRACE_LOG.with_suffix(f".jsonl.{i-1}") if i > 1 else TRACE_LOG
            dst = TRACE_LOG.with_suffix(f".jsonl.{i}")
            if src.exists():
                if dst.exists():
                    dst.unlink()
                src.rename(dst)
    except Exception:
        pass


def trace(event: str, **fields: Any) -> None:
    """Append a JSONL event to ~/.whisper_log/trace.jsonl.

    Non-blocking: any error is swallowed so tracing never breaks the pipeline.
    Fields are JSON-serialized; non-serializable values become repr().

    Concurrency: uses fcntl.flock(LOCK_EX) around the write so concurrent
    per-stage workers + screenshot extractor produce well-formed JSONL (a
    single write() can exceed PIPE_BUF for large payloads, so O_APPEND
    atomicity alone is insufficient).
    """
    try:
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        _rotate_trace_if_needed()
        payload: dict[str, Any] = {
            "ts": time.time(),
            "iso": time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime()),
            "pid": os.getpid(),
            "event": event,
        }
        for k, v in fields.items():
            try:
                json.dumps(v)
                payload[k] = v
            except (TypeError, ValueError):
                payload[k] = repr(v)
        line = json.dumps(payload, ensure_ascii=False) + "\n"
        with open(TRACE_LOG, "a", encoding="utf-8") as f:
            try:
                import fcntl as _fcntl
                _fcntl.flock(f.fileno(), _fcntl.LOCK_EX)
                try:
                    f.write(line)
                finally:
                    _fcntl.flock(f.fileno(), _fcntl.LOCK_UN)
            except (ImportError, OSError):
                # Fallback: best-effort write; O_APPEND still atomic for small lines.
                f.write(line)
    except Exception:
        pass

# ---------------------------------------------------------------------------
# Stages (canonical order, used everywhere)
#
# Trimmed from 6 → 2 in v3:
#   - base.en (raw): instant first impression (~7s latency, no LLM)
#   - large-v3 (corrected): final quality (dictionary + Copilot LLM correction)
# medium.en remains as the *paste-time* fast retranscribe model (lua-only),
# but its output is not logged as a stage — by the time large_corr lands the user
# has the polished version anyway.
# ---------------------------------------------------------------------------

STAGES = [
    {"id": "base_raw",       "model": "base.en",   "corrected": False, "label": "base.en (raw, fastest)"},
    {"id": "large_corr",     "model": "large-v3",  "corrected": True,  "label": "large-v3 (corrected, best)"},
]
STAGE_IDS = [s["id"] for s in STAGES]


def _model_to_stage_ids(model_filename: str) -> list[str]:
    """
    Map a quick-mode model filename (e.g. 'ggml-medium.en.bin') to the stage IDs
    whose model matches. Used to mark the synchronous quick-paste result so the
    worker doesn't redo it.
    """
    fn = model_filename.lower()
    if "base.en" in fn:
        return ["base_raw"]
    # medium.en/large quick paste only matches the corrected stages now;
    # we don't pre-fill those because corrections happen post-paste in batch
    # mode (different code path) — leave the worker to fill them.
    return []


# ---------------------------------------------------------------------------
# Atomic JSON I/O with file locking
# ---------------------------------------------------------------------------

def _ensure_dirs() -> None:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    QUEUE_DIR.mkdir(parents=True, exist_ok=True)


def _load_records() -> dict[str, Any]:
    if not RECORDS_PATH.exists():
        return {}
    try:
        with open(RECORDS_PATH, "r", encoding="utf-8") as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError):
        # Corrupt or unreadable: back it up and start fresh
        backup = RECORDS_PATH.with_suffix(".json.corrupt." + str(int(time.time())))
        try:
            RECORDS_PATH.rename(backup)
        except OSError:
            pass
        return {}


def _atomic_write_json(path: Path, data: Any) -> None:
    tmp_fd, tmp_path = tempfile.mkstemp(prefix=path.name + ".", dir=str(path.parent))
    try:
        with os.fdopen(tmp_fd, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
        os.replace(tmp_path, path)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


class _RecordsLock:
    """File-lock context manager so concurrent writers serialize."""

    def __init__(self) -> None:
        _ensure_dirs()
        self._lock_path = LOG_DIR / "records.lock"
        self._fh = None

    def __enter__(self) -> "_RecordsLock":
        self._fh = open(self._lock_path, "w")
        fcntl.flock(self._fh.fileno(), fcntl.LOCK_EX)
        return self

    def __exit__(self, *_exc) -> None:
        if self._fh is not None:
            try:
                fcntl.flock(self._fh.fileno(), fcntl.LOCK_UN)
            finally:
                self._fh.close()
            self._fh = None


# ---------------------------------------------------------------------------
# Record schema
# ---------------------------------------------------------------------------

def _new_stage_dict() -> dict[str, Any]:
    return {"status": "pending", "text": "", "duration_ms": None, "error": None, "finished_at": None, "degraded_note": None}


def _new_record(t0_epoch: float, wav_path: str, app_name: str = "", project_hint: str = "",
                wav_duration_ms: int | None = None, button_pressed_at_ns: int | None = None) -> dict[str, Any]:
    return {
        "wav_path": wav_path,
        "wav_basename": Path(wav_path).name,
        "t0_epoch": t0_epoch,
        "created_at": time.time(),
        "app_name": app_name or "",
        "project_hint": project_hint or "",
        # Plan 4 S1B/S3 (2026-04-23): per-record timing context.
        # wav_duration_ms = audio length (from ffprobe in whisper_log_hook.sh).
        # button_pressed_at_ns = epoch ns at button-down (sidecar file from
        # ~/.hammerspoon/whisper_mouse.lua, read by whisper_log_hook.sh).
        # NOT monotonic — wall-clock comparable to created_at.
        "wav_duration_ms": wav_duration_ms,
        "button_pressed_at_ns": button_pressed_at_ns,
        "stages": {sid: _new_stage_dict() for sid in STAGE_IDS},
    }


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def add_quick_record(
    t0_epoch: float,
    wav_path: str,
    quick_model_id: str,
    quick_text: str,
    quick_duration_ms: int,
    app_name: str = "",
    project_hint: str = "",
    wav_duration_ms: int | None = None,
    button_pressed_at_ns: int | None = None,
) -> str:
    """
    Register a new transcription event (or update an existing one).

    quick_model_id: filename like "ggml-medium.en.bin" (or "" for backfill).
    quick_text:     the synchronous paste text (or "" for backfill).
    quick_duration_ms: ms from button-click to paste (or 0 for backfill).
    app_name:       frontmost app at trigger time (e.g. "Cursor", "iTerm2").
    project_hint:   project folder / URL / session.path captured at trigger time.
    wav_duration_ms:      Plan 4 S1B — audio length in ms (ffprobe).
    button_pressed_at_ns: Plan 4 S3 — epoch ns at button-down event (wall clock,
                          NOT monotonic). Sourced from sidecar file written by
                          Hammerspoon at the forward (recording-start) press.

    Returns the wav_basename used as record key.
    """
    _ensure_dirs()
    wav_path_str = str(wav_path)
    basename = Path(wav_path_str).name

    with _RecordsLock():
        records = _load_records()
        if basename not in records:
            records[basename] = _new_record(
                t0_epoch, wav_path_str, app_name, project_hint,
                wav_duration_ms=wav_duration_ms,
                button_pressed_at_ns=button_pressed_at_ns,
            )
        else:
            # Backfill context onto an existing record if it didn't have it before
            rec = records[basename]
            if app_name and not rec.get("app_name"):
                rec["app_name"] = app_name
            if project_hint and not rec.get("project_hint"):
                rec["project_hint"] = project_hint
            if wav_duration_ms and not rec.get("wav_duration_ms"):
                rec["wav_duration_ms"] = wav_duration_ms
            if button_pressed_at_ns and not rec.get("button_pressed_at_ns"):
                rec["button_pressed_at_ns"] = button_pressed_at_ns

        rec = records[basename]
        # Pre-fill the matching stage (raw only — quick path doesn't run corrections)
        if quick_text and quick_model_id:
            for sid in _model_to_stage_ids(quick_model_id):
                rec["stages"][sid] = {
                    "status": "done",
                    "text": quick_text,
                    "duration_ms": int(quick_duration_ms),
                    "error": None,
                    "finished_at": time.time(),
                    "source": "quick_paste",
                }

        _atomic_write_json(RECORDS_PATH, records)

    # Enqueue all pending stages
    _enqueue_pending_for(basename)
    _refresh_status_and_html()
    _maybe_spawn_workers_for(basename)
    # Notify for each stage we just marked "done" via the quick-paste prefill.
    if quick_text and quick_model_id:
        for sid in _model_to_stage_ids(quick_model_id):
            _emit_stage_done(sid, "done")
    trace("add_quick_record",
          basename=basename, quick_model_id=quick_model_id,
          quick_duration_ms=int(quick_duration_ms), has_quick_text=bool(quick_text),
          app_name=app_name, project_hint=project_hint)
    return basename


def update_stage(
    wav_basename: str,
    stage_id: str,
    text: str,
    duration_ms_from_t0: int,
    error: str | None = None,
    degraded_note: str | None = None,
) -> None:
    """Called by the background worker when a stage completes."""
    if stage_id not in STAGE_IDS:
        raise ValueError(f"Unknown stage_id: {stage_id}")

    with _RecordsLock():
        records = _load_records()
        if wav_basename not in records:
            return  # Record was deleted; ignore late update
        rec = records[wav_basename]
        rec["stages"][stage_id] = {
            "status": "error" if error else "done",
            "text": text,
            "duration_ms": int(duration_ms_from_t0) if duration_ms_from_t0 is not None else None,
            "error": error,
            "finished_at": time.time(),
            "source": "worker",
            "degraded_note": degraded_note,
        }
        _atomic_write_json(RECORDS_PATH, records)

    _refresh_status_and_html()
    _emit_stage_done(stage_id, "error" if error else "done")
    trace("update_stage",
          basename=wav_basename, stage_id=stage_id,
          status=("error" if error else "done"),
          duration_ms=int(duration_ms_from_t0) if duration_ms_from_t0 is not None else None,
          error=error, text_len=len(text or ""), degraded_note=degraded_note)


def get_pending_count() -> int:
    records = _load_records()
    return sum(
        1
        for rec in records.values()
        for st in rec["stages"].values()
        if st.get("status") == "pending"
    )


def update_project_hint(wav_basename: str, project: str) -> bool:
    """
    Set/update the project_hint on a record. Won't overwrite an existing
    non-empty hint with an empty/UNKNOWN value.

    Used by extract_project_from_screenshot.py after vision/regex extraction.
    Returns True on write, False on no-op.
    """
    if not wav_basename or not project:
        return False
    project = project.strip()
    if not project or project.upper() == "UNKNOWN":
        return False

    with _RecordsLock():
        records = _load_records()
        if wav_basename not in records:
            return False
        rec = records[wav_basename]
        existing = (rec.get("project_hint") or "").strip()
        if existing and existing.lower() == project.lower():
            return False  # no change
        rec["project_hint"] = project
        _atomic_write_json(RECORDS_PATH, records)
    _refresh_status_and_html()
    return True


def update_screenshot_path(wav_basename: str, screenshot_path: str) -> bool:
    """
    Attach the desktop screenshot path to a record so the HTML can render
    a link to it next to the WAV link.
    """
    if not wav_basename or not screenshot_path:
        return False
    with _RecordsLock():
        records = _load_records()
        if wav_basename not in records:
            return False
        rec = records[wav_basename]
        if rec.get("screenshot_path") == screenshot_path:
            return False
        rec["screenshot_path"] = screenshot_path
        _atomic_write_json(RECORDS_PATH, records)
    _refresh_status_and_html()
    return True


def get_record(wav_basename: str) -> dict[str, Any] | None:
    return _load_records().get(wav_basename)


def all_records_sorted() -> list[dict[str, Any]]:
    records = _load_records()
    return sorted(records.values(), key=lambda r: r.get("t0_epoch", 0), reverse=True)


# ---------------------------------------------------------------------------
# Queue management
# ---------------------------------------------------------------------------

def _enqueue_pending_for(basename: str) -> None:
    rec = get_record(basename)
    if rec is None:
        return
    for sid in STAGE_IDS:
        st = rec["stages"][sid]
        if st["status"] == "pending":
            todo = QUEUE_DIR / f"{basename}__{sid}.todo"
            if not todo.exists() and not (QUEUE_DIR / f"{basename}__{sid}.running").exists():
                todo.write_text(json.dumps({
                    "wav_path": rec["wav_path"],
                    "wav_basename": basename,
                    "stage_id": sid,
                    "t0_epoch": rec["t0_epoch"],
                    "enqueued_at": time.time(),
                }))


# ---------------------------------------------------------------------------
# Worker spawning
# ---------------------------------------------------------------------------

def _worker_alive(stage_id: str) -> bool:
    """Is a worker for this specific stage currently running?"""
    lock = _worker_lock_path(stage_id)
    if not lock.exists():
        return False
    try:
        pid = int(lock.read_text().strip())
        os.kill(pid, 0)
        return True
    except (ValueError, OSError, ProcessLookupError):
        return False


def _maybe_spawn_workers_for(basename: str) -> None:
    """Spawn one worker process per pending stage for this basename, in parallel.

    Per-stage workers (vs single global worker) eliminate sequential head-of-line
    blocking — base_raw and large_corr now START at the same moment, instead of
    large_corr waiting for base_raw to finish.

    Each child gets its own log fd to avoid interleaved writes (POSIX guarantees
    atomic writes only ≤PIPE_BUF; whisper output can exceed that).
    """
    if not WORKER_SCRIPT.exists():
        return
    rec = get_record(basename)
    if rec is None:
        return
    spawned: list[str] = []
    skipped: dict[str, str] = {}
    for sid in STAGE_IDS:
        st = rec["stages"].get(sid, {})
        if st.get("status") != "pending":
            skipped[sid] = f"not pending ({st.get('status')})"
            continue
        if _worker_alive(sid):
            skipped[sid] = "worker_alive"
            continue
        # close_fds=False so the child inherits log_fh; parent closes its copy.
        log_fh = open(WORKER_LOG, "ab")
        try:
            proc = subprocess.Popen(
                [sys.executable, str(WORKER_SCRIPT), "--stage", sid],
                stdout=log_fh,
                stderr=log_fh,
                stdin=subprocess.DEVNULL,
                start_new_session=True,
                close_fds=False,
            )
            spawned.append(f"{sid}:pid{proc.pid}")
        finally:
            log_fh.close()
    trace("maybe_spawn_workers", basename=basename, spawned=spawned, skipped=skipped)


# Backward-compat alias for any external caller (none known internally).
_maybe_spawn_worker = lambda: None  # noqa: E731 — intentional no-op shim


# ---------------------------------------------------------------------------
# HTML + status refresh
# ---------------------------------------------------------------------------

def _refresh_status_and_html() -> None:
    """Imported lazily to keep this module importable when worker runs alone."""
    try:
        from _html_render import render_html
        from _status_render import render_status
    except ImportError:
        # When called from a different cwd, add bin/ to path
        sys.path.insert(0, str(REPO_BIN_DIR))
        from _html_render import render_html  # type: ignore[no-redef]
        from _status_render import render_status  # type: ignore[no-redef]

    records_sorted = all_records_sorted()
    render_status(STATUS_PATH, records_sorted)
    render_html(HTML_PATH, records_sorted, STAGES)


# ---------------------------------------------------------------------------
# CLI used by whisper_log_hook.sh
# ---------------------------------------------------------------------------

def _cli_add_quick() -> int:
    """
    Args (legacy 5):  <t0_epoch> <wav_path> <quick_model_id> <quick_duration_ms> <text_file>
    Args (v2 7):      ... <app_name> <project_hint>

    Reads the quick-paste text from text_file (avoids quoting issues with newlines).
    """
    n = len(sys.argv)
    if n not in (7, 9):
        print(
            f"usage: {sys.argv[0]} add-quick <t0> <wav> <model> <dur_ms> <text_file> "
            f"[<app_name> <project_hint>]",
            file=sys.stderr,
        )
        return 2
    t0 = sys.argv[2]
    wav = sys.argv[3]
    model = sys.argv[4]
    dur_ms = sys.argv[5]
    text_file = sys.argv[6]
    app_name = sys.argv[7] if n >= 8 else ""
    project_hint = sys.argv[8] if n >= 9 else ""
    try:
        text = Path(text_file).read_text(encoding="utf-8") if text_file and Path(text_file).exists() else ""
    except OSError:
        text = ""
    try:
        # Plan 4 S1B/S3 (2026-04-23): pull WAV duration + button-press timestamp
        # from env vars (set by whisper_log_hook.sh / Hammerspoon). These are
        # optional — silently ignored if missing or malformed.
        wav_dur_ms = None
        btn_ns = None
        try:
            v = os.environ.get("WHISPER_WAV_DURATION_MS", "").strip()
            if v:
                wav_dur_ms = int(float(v))
        except (TypeError, ValueError):
            pass
        try:
            v = os.environ.get("WHISPER_BUTTON_PRESSED_AT_NS", "").strip()
            if v:
                btn_ns = int(float(v))
        except (TypeError, ValueError):
            pass
        add_quick_record(
            float(t0), wav, model, text.strip(), int(dur_ms),
            app_name=app_name, project_hint=project_hint,
            wav_duration_ms=wav_dur_ms,
            button_pressed_at_ns=btn_ns,
        )
    except Exception as e:
        # Never propagate failure back to whisper.sh
        print(f"transcription_log: add-quick failed: {e}", file=sys.stderr)
        return 0
    return 0


def _cli_refresh() -> int:
    _refresh_status_and_html()
    return 0


def _cli_update_stage_text() -> int:
    """
    Args: <wav_path> <stage_id> <duration_ms> <text_file>

    Used by Hammerspoon's instant-retranscribe success path to push the improved
    transcript text into a specific stage (e.g. "medium_corr") without going
    through the worker. Page sees the better text immediately.
    """
    n = len(sys.argv)
    if n != 6:
        print(
            f"usage: {sys.argv[0]} update-stage <wav_path> <stage_id> <dur_ms> <text_file>",
            file=sys.stderr,
        )
        return 2
    wav_path = sys.argv[2]
    stage_id = sys.argv[3]
    dur_ms = sys.argv[4]
    text_file = sys.argv[5]
    basename = Path(wav_path).name
    try:
        text = Path(text_file).read_text(encoding="utf-8") if text_file and Path(text_file).exists() else ""
    except OSError:
        text = ""
    try:
        update_stage(basename, stage_id, text=text.strip(), duration_ms_from_t0=int(dur_ms), error=None)
    except Exception as e:
        # Never propagate failure back to the caller (lua/shell)
        print(f"transcription_log: update-stage failed: {e}", file=sys.stderr)
        return 0
    return 0


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "add-quick":
        sys.exit(_cli_add_quick())
    if len(sys.argv) >= 2 and sys.argv[1] == "refresh":
        sys.exit(_cli_refresh())
    if len(sys.argv) >= 2 and sys.argv[1] == "update-stage":
        sys.exit(_cli_update_stage_text())
    if len(sys.argv) >= 2 and sys.argv[1] == "set-screenshot":
        # usage: set-screenshot <wav_basename> <screenshot_path>
        if len(sys.argv) != 4:
            print("usage: transcription_log.py set-screenshot <basename> <path>", file=sys.stderr)
            sys.exit(2)
        try:
            update_screenshot_path(sys.argv[2], sys.argv[3])
        except Exception as e:
            print(f"set-screenshot failed: {e}", file=sys.stderr)
        sys.exit(0)
    if len(sys.argv) >= 2 and sys.argv[1] == "set-project":
        # usage: set-project <wav_basename> <project>
        if len(sys.argv) != 4:
            print("usage: transcription_log.py set-project <basename> <project>", file=sys.stderr)
            sys.exit(2)
        try:
            update_project_hint(sys.argv[2], sys.argv[3])
        except Exception as e:
            print(f"set-project failed: {e}", file=sys.stderr)
        sys.exit(0)
    print("usage: transcription_log.py {add-quick|refresh|update-stage|set-screenshot|set-project} ...", file=sys.stderr)
    sys.exit(2)
