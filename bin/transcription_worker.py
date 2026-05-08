"""
Background Transcription Worker
===============================

Drains ~/.whisper_log/queue/*.todo, runs whisper-cli for the requested model,
optionally applies dictionary + Copilot corrections, and reports back via
transcription_log.update_stage().

Single-instance: protected by ~/.whisper_log/worker.lock (PID file).

Run manually:
    python3 bin/transcription_worker.py          # process queue then exit
    python3 bin/transcription_worker.py --watch  # poll forever
"""

from __future__ import annotations

import fcntl
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

# Ensure sibling modules importable
sys.path.insert(0, str(Path(__file__).resolve().parent))
from transcription_log import (  # noqa: E402
    LOG_DIR, QUEUE_DIR, WORKER_LOCK, STAGES, STAGE_IDS, _worker_lock_path,
    update_stage, _refresh_status_and_html, trace,
)

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

WHISPER_CLI = "/opt/homebrew/bin/whisper-cli"
MODEL_DIR = Path(os.path.expanduser("~/whisper-models"))
MODEL_FILES = {
    "base.en":   MODEL_DIR / "ggml-base.en.bin",
    "medium.en": MODEL_DIR / "ggml-medium.en.bin",
    "large-v3":  MODEL_DIR / "ggml-large-v3.bin",
}
WHISPER_LANGUAGE = os.environ.get("WHISPER_LANGUAGE", "en")
PER_STAGE_TIMEOUT_S = 600
RUNNING_STALE_S = 600        # consider .running > 10 min as crashed
ABANDONED_AFTER_S = 24 * 3600  # mark old .todo as error after 24h

CORRECTIONS_TSV = Path(__file__).resolve().parent.parent / "transcription_corrections.tsv"
COPILOT_AUTH = Path(os.path.expanduser("~/.config/careless-whisper/auth.json"))

STAGES_BY_ID = {s["id"]: s for s in STAGES}


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

def _redact(s: str) -> str:
    """Redact bearer tokens, copilot tokens, and JSON token fields from log
    strings (F-16 residual, QC cycle 2). Mirrors the helper in
    extract_project_from_screenshot.py so worker.log cannot leak credentials
    when curl bodies or auth errors surface here."""
    if not s:
        return s
    import re as _re
    s = _re.sub(r'("(?:access_|copilot_|session_)?token"\s*:\s*")[^"]+(")', r'\1<redacted>\2', s)
    s = _re.sub(r'(Bearer\s+)[A-Za-z0-9_\-\.]+', r'\1<redacted>', s)
    s = _re.sub(r'\bghu_[A-Za-z0-9]+', '<redacted-ghu>', s)
    return s


def log(msg: str) -> None:
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{ts}] {_redact(msg)}", flush=True)


# ---------------------------------------------------------------------------
# Lock — fcntl.flock on long-lived fd. Eliminates the entire stale-lock /
# PID-recycle / TOCTOU class of bugs (F-02 + F-03, QC cycle 1) by letting the
# kernel manage release: when the process dies for any reason, the OS releases
# the advisory lock automatically. No PID-check, no stale-detection, no
# 2-attempt retry, no race window.
#
# The fd MUST be kept alive for the lifetime of the lock, so we stash it in a
# module-global. Closing the fd (or process exit) releases the lock.
# ---------------------------------------------------------------------------

_LOCK_FD: int | None = None


def acquire_lock(lock_path: Path) -> bool:
    """Atomically acquire an exclusive advisory lock on `lock_path`.
    Returns True on success, False if another worker holds it.
    The lock is auto-released by the kernel when this process exits.
    """
    global _LOCK_FD
    try:
        # O_CREAT | O_RDWR — file persists between runs, contents are advisory
        # (we still write our PID for human debugging).
        fd = os.open(str(lock_path), os.O_CREAT | os.O_RDWR, 0o644)
    except OSError as e:
        log(f"open({lock_path.name}) failed: {e}")
        return False
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        # Another worker holds the lock — read its PID for the log message.
        try:
            os.lseek(fd, 0, os.SEEK_SET)
            held_by = os.read(fd, 32).decode("utf-8", "replace").strip() or "?"
        except OSError:
            held_by = "?"
        log(f"another worker already running ({lock_path.name} pid={held_by}); exiting.")
        os.close(fd)
        return False
    except OSError as e:
        log(f"flock({lock_path.name}) failed: {e}")
        os.close(fd)
        return False
    # Truncate + write our PID for debugging.
    try:
        os.ftruncate(fd, 0)
        os.write(fd, str(os.getpid()).encode())
        os.fsync(fd)
    except OSError:
        pass
    _LOCK_FD = fd
    return True


def release_lock(lock_path: Path) -> None:
    """Explicit release. Safe to call even if not held — process exit also
    releases via kernel. We do NOT unlink the lockfile because another worker
    may have already opened the same path; unlinking would orphan its lock."""
    global _LOCK_FD
    if _LOCK_FD is None:
        return
    try:
        fcntl.flock(_LOCK_FD, fcntl.LOCK_UN)
    except OSError:
        pass
    try:
        os.close(_LOCK_FD)
    except OSError:
        pass
    _LOCK_FD = None


# ---------------------------------------------------------------------------
# Crash recovery
# ---------------------------------------------------------------------------

def reclaim_stale_running() -> None:
    now = time.time()
    for f in QUEUE_DIR.glob("*.running"):
        try:
            age = now - f.stat().st_mtime
            if age > RUNNING_STALE_S:
                target = f.with_suffix(".todo")
                f.rename(target)
                log(f"reclaimed stale running -> todo: {target.name}")
        except OSError:
            pass


def mark_abandoned() -> None:
    now = time.time()
    for f in sorted(QUEUE_DIR.glob("*.todo")):
        try:
            age = now - f.stat().st_mtime
            if age > ABANDONED_AFTER_S:
                try:
                    payload = json.loads(f.read_text())
                except (OSError, json.JSONDecodeError):
                    f.unlink(missing_ok=True)
                    continue
                update_stage(
                    payload["wav_basename"],
                    payload["stage_id"],
                    text="",
                    duration_ms_from_t0=None,
                    error=f"abandoned after {ABANDONED_AFTER_S//3600}h in queue",
                )
                f.unlink(missing_ok=True)
                log(f"marked abandoned: {f.name}")
        except OSError:
            pass


# Bug #4 fix (rpi/transcription-pipeline-consistency): auto_backfill() removed.
# It was dead code (undefined references, never called from main()). The hook
# script (whisper_log_hook.sh) is the source of truth for new recordings.

# ---------------------------------------------------------------------------
# Whisper invocation
# ---------------------------------------------------------------------------

def run_whisper(model_key: str, wav_path: str) -> tuple[str, str | None]:
    """
    Returns (text, error). On success error is None; on failure text is "".
    """
    model_path = MODEL_FILES.get(model_key)
    if model_path is None or not model_path.exists():
        return "", f"model file missing: {model_path}"
    if not Path(wav_path).exists():
        return "", f"wav missing: {wav_path}"
    if not Path(WHISPER_CLI).exists():
        return "", f"whisper-cli missing at {WHISPER_CLI}"

    # Anti-hallucination / decoder-fallback flags. whisper.cpp defaults have
    # NO fallback when log-prob or compression-ratio thresholds indicate a
    # degenerate (looping/repeating) segment. The smaller base.en model is
    # particularly prone to "word for word for word..." style loops on noisy
    # short audio (observed on 20260423160701.wav). These flags cause the
    # decoder to retry with higher temperature on bad segments and prevent
    # cross-segment context from reinforcing loops.
    #
    # Bug T2 fix (2026-04-23): Whisper hallucinates "Thank you." on leading
    # silence (YouTube-caption training-data prior). Counter-measures:
    #   --suppress-nst         : suppress non-speech tokens like "[Music]"
    #   --max-context 0        : zero cross-segment context (no prompt bleed)
    # Note: dropped --no-speech-thold 0.6 (was too permissive; F-06 QC cycle 1)
    # in favor of relying on --logprob-thold + --entropy-thold to catch
    # silent / degenerate segments without forcing aggressive truncation of
    # legitimate short utterances (which the user records often via hotkey).
    # Thread count: whisper.cpp scales well up to ~8 threads on Apple Silicon
    # (performance cores). Two stages run in parallel (base_raw + large_corr),
    # so each gets half the available cores to avoid contention.
    try:
        total_cores = os.cpu_count() or 8
    except Exception:
        total_cores = 8
    threads = max(2, min(8, total_cores // 2))

    cmd = [
        WHISPER_CLI,
        "-m", str(model_path),
        "--no-prints",
        "-l", WHISPER_LANGUAGE,
        "--temperature-inc", "0.2",
        "--entropy-thold", "2.4",
        "--logprob-thold", "-0.5",
        "--suppress-nst",
        "--max-context", "0",
        "--threads", str(threads),
        wav_path,
    ]
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=PER_STAGE_TIMEOUT_S,
        )
    except subprocess.TimeoutExpired:
        return "", f"timeout after {PER_STAGE_TIMEOUT_S}s"
    except OSError as e:
        return "", f"exec failed: {e}"

    if proc.returncode != 0:
        return "", (proc.stderr or "whisper-cli failed").strip()[:500]

    # Strip [HH:MM:SS.mmm --> HH:MM:SS.mmm] timestamps that whisper-cli prepends
    raw = proc.stdout
    cleaned = re.sub(r"^\[[^\]]+\]\s*", "", raw, flags=re.MULTILINE)
    cleaned = " ".join(cleaned.split())
    cleaned = _strip_leading_hallucinations(cleaned)
    return cleaned.strip(), None


# Bug T2 fix (2026-04-23): YouTube-caption training-data hallucinations.
# Whisper emits these high-prior tokens on leading silence even with
# --suppress-nst. Defense-in-depth: strip them in post-processing.
_HALLUCINATION_PREFIXES = (
    "Thank you.", "Thank you!", "Thanks for watching.", "Thanks for watching!",
    "Thanks for watching, and I'll see you in the next video.",
    "Please subscribe.", "Thanks!", "Thank you so much.",
    "[Music]", "[music]", "(music)", "[ Music ]",
    "you", "You.", "you.",  # whisper's other silence-token
)


def _strip_leading_hallucinations(text: str) -> str:
    """Remove well-known whisper hallucinations that appear at the start of
    transcripts when the audio begins with silence or low-volume sound.
    Handles repeated occurrences (e.g. 'Thank you. Thank you. Real text…').

    Uses word-boundary matching for bare-word prefixes (e.g. "you") so that
    legitimate transcripts like "you know this works" are not corrupted.
    """
    if not text:
        return text
    changed = True
    while changed:
        changed = False
        for prefix in _HALLUCINATION_PREFIXES:
            if not text.startswith(prefix):
                continue
            # Bare-word prefix (ends in a letter, e.g. "you"): require the
            # next char to be sentence-terminating punctuation or EOF — not
            # just any word boundary — to avoid stripping legitimate sentence
            # starts like "you know this works".
            if prefix[-1].isalpha():
                tail_char = text[len(prefix):len(prefix)+1]
                if tail_char and tail_char not in ".!?,;:":
                    continue
            rest = text[len(prefix):].lstrip(" .,!?")
            # Only strip if there's real content after — don't nuke the
            # entire transcript if the user genuinely said only "Thank you".
            if rest:
                text = rest
                changed = True
                break
    return text


# Plan 3 Q3 (2026-04-23) + F-S2-04 (2026-04-24): runaway-loop guard.
# Whisper-cli with high beam search loops on noise — observed real cases:
#   * 600× "for work"  (bigram, record 20260423160701.wav)
#   * runs of "you you you …" (unigram)
#   * trigram and 4-gram phrasal loops
# Original implementation only checked trigrams, so the bigram example that
# motivated this guard slipped through. We now try n-grams 1..4 at each
# position and collapse the LONGEST one whose repetition count > threshold.
# Preserves first occurrence + adds an `[…N× repeated…]` marker so the user
# can see what was suppressed.
def _collapse_runaway_loops(text: str, threshold: int = 5) -> str:
    if not text:
        return text
    tokens = text.split()
    if len(tokens) < threshold + 1:
        return text
    out: list[str] = []
    i = 0
    while i < len(tokens):
        collapsed = False
        # Try larger n-grams first so "for work for work…" collapses as a
        # bigram rather than 600× "for". 4-gram catches phrasal loops like
        # whisper occasionally produces from VAD glitches.
        for n in (4, 3, 2, 1):
            if i + n * (threshold + 1) > len(tokens):
                continue
            window = tokens[i:i + n]
            j, repeats = i + n, 1
            while j + n <= len(tokens) and tokens[j:j + n] == window:
                repeats += 1
                j += n
            if repeats > threshold:
                out.extend(window)
                out.append(f"[…{repeats}× repeated…]")
                i = j
                collapsed = True
                break
        if not collapsed:
            out.append(tokens[i])
            i += 1
    return " ".join(out)


# ---------------------------------------------------------------------------
# Corrections (dictionary + Copilot)
# ---------------------------------------------------------------------------

_CORR_CACHE: dict | None = None


def _load_corrections() -> dict:
    global _CORR_CACHE
    if _CORR_CACHE is not None:
        return _CORR_CACHE
    literals: dict[str, str] = {}
    regexes: list[tuple[str, str]] = []
    if CORRECTIONS_TSV.exists():
        try:
            for line in CORRECTIONS_TSV.read_text(encoding="utf-8").splitlines():
                raw = line.strip()
                if not raw or raw.startswith("#") or "\t" not in line:
                    continue
                wrong, right = line.split("\t", 1)
                if wrong.startswith("re:"):
                    regexes.append((wrong[3:], right))
                else:
                    literals[wrong.lower()] = right
        except OSError:
            pass
    _CORR_CACHE = {"literals": literals, "regexes": regexes}
    return _CORR_CACHE


def apply_dictionary(text: str) -> str:
    if not text:
        return text
    corr = _load_corrections()
    literals = corr["literals"]
    if literals:
        sorted_lits = sorted(literals.keys(), key=len, reverse=True)
        pat = re.compile("|".join(re.escape(w) for w in sorted_lits), re.IGNORECASE)
        text = pat.sub(lambda m: literals[m.group().lower()], text)
    for pattern, replacement in corr["regexes"]:
        try:
            text = re.sub(pattern, replacement, text, flags=re.IGNORECASE)
        except re.error:
            continue
    return text


def _resolve_copilot_token() -> str | None:
    """
    Read the auth file and return a Bearer token, or None if unavailable.
    File is JSON; the actual exchange logic lives in whisper.sh and is not
    duplicated here — we just use the cached access token if present.
    """
    if not COPILOT_AUTH.exists():
        return None
    try:
        data = json.loads(COPILOT_AUTH.read_text())
    except (OSError, json.JSONDecodeError):
        return None
    # Try common field names
    for k in ("access_token", "copilot_token", "token"):
        v = data.get(k)
        if v and isinstance(v, str) and v.strip():
            return v.strip()
    return None


COPILOT_URL = "https://api.githubcopilot.com/chat/completions"
# Plan 6 (2026-04-23): claude-sonnet-4.6 returns HTTP 400 model_not_supported.
# vscode normalises any claude-sonnet-4* → claude-sonnet-4.5 before sending; the
# wire identifier is dotted (claude-sonnet-4.5), not dashed. We default to
# gpt-4o-mini (universally available, cheap, strong at copy-edit) and try a
# fallback chain so a single model deprecation doesn't degrade every record.
# Override with WHISPER_COPILOT_MODEL=<single model> to pin one model.
COPILOT_MODEL = os.environ.get("WHISPER_COPILOT_MODEL", "gpt-4o-mini")
COPILOT_FALLBACKS = [
    "gpt-4o-mini",
    "gpt-4o",
    "claude-haiku-4.5",
    "claude-sonnet-4.5",
]
# F-S1-02 (2026-04-24): module-level cache of models that returned
# model_not_supported / model_not_found this process lifetime. Reset on
# worker restart. Avoids paying the deprecation round-trip on every record
# when Copilot drops a model from the supported list.
_DEAD_MODELS: set[str] = set()
COPILOT_SYSTEM = (
    "You are a transcription cleaner. Fix obvious speech-to-text errors, "
    "punctuation, and capitalization. Preserve meaning and tone. Output ONLY "
    "the corrected text — no preamble, no quotes, no explanations."
)


def _copilot_call_one(text: str, token: str, model: str) -> tuple[str, str | None]:
    """Single Copilot HTTP attempt. Returns (improved_text, note).
    note is non-None on any failure (caller may try a fallback model)."""
    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": COPILOT_SYSTEM},
            {"role": "user", "content": text},
        ],
        "max_tokens": 4096,
        "temperature": 0.2,
    }
    headers = [
        "-H", f"Authorization: Bearer {token}",
        "-H", "Content-Type: application/json",
        "-H", "Editor-Version: vscode/1.0",
        "-H", "Copilot-Integration-Id: vscode-chat",
    ]
    try:
        proc = subprocess.run(
            ["curl", "-sS", "--max-time", "120", *headers,
             "-d", json.dumps(payload), COPILOT_URL],
            capture_output=True, text=True, timeout=130,
        )
    except (subprocess.TimeoutExpired, OSError) as e:
        return "", f"copilot exec failed ({model}): {e}"
    if proc.returncode != 0:
        return "", f"curl rc={proc.returncode} ({model})"
    # Detect HTTP error envelope (400 model_not_supported, 401, 429, etc.)
    try:
        data = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return "", f"copilot bad json ({model})"
    if isinstance(data, dict) and "error" in data:
        err_obj = data["error"]
        code = err_obj.get("code") or err_obj.get("type") or "error"
        return "", f"copilot {code} ({model})"
    try:
        choice = data.get("choices", [{}])[0]
        improved = choice.get("message", {}).get("content", "").strip()
    except (IndexError, AttributeError):
        return "", f"copilot bad response shape ({model})"
    if not improved:
        return "", f"copilot empty response ({model})"
    if _looks_like_copilot_self_reference(improved):
        # Self-reference is a content failure, not a transport failure — do not
        # try a fallback model, the prompt itself is being misinterpreted.
        return "", f"copilot self-reference ({model})"
    return improved, None


def apply_copilot(text: str) -> tuple[str, str | None]:
    """Returns (text_after_copilot, note). note is non-None if Copilot was
    skipped or all fallback models failed. Tries WHISPER_COPILOT_MODEL first
    (or COPILOT_MODEL default), then walks COPILOT_FALLBACKS until one works
    or all model-availability errors are exhausted.

    F-S1-02 (2026-04-24): retry policy tightened. Only retry on explicit
    model-availability errors (model_not_supported / model_not_found / 404).
    Transport errors (curl rc=*) and auth errors (401/403) bail immediately —
    retrying them with a different model just multiplies the failure latency
    (worst case was ~520 s = 4 × 130 s timeout on a single network blip).
    Also caches confirmed-dead models in _DEAD_MODELS so we don't pay the
    deprecation tax on every record once a model is known-bad."""
    if not text:
        return text, None
    token = _resolve_copilot_token()
    if not token:
        return text, "no copilot token"
    # Build attempt list: configured model first, then fallbacks (dedup, preserve order).
    # Skip models we've already confirmed are dead this process lifetime.
    seen: set[str] = set()
    chain: list[str] = []
    for m in [COPILOT_MODEL, *COPILOT_FALLBACKS]:
        if m and m not in seen and m not in _DEAD_MODELS:
            seen.add(m)
            chain.append(m)
    if not chain:
        # All models in the chain are dead this process — degrade gracefully.
        return text, "copilot all models dead in cache"
    last_note: str | None = None
    for model in chain:
        improved, note = _copilot_call_one(text, token, model)
        if improved and note is None:
            return improved, None
        last_note = note
        # Only retry on model-availability failures. Cache confirmed-dead
        # models so subsequent records skip them entirely.
        if note and ("model_not_supported" in note or "model_not_found" in note):
            _DEAD_MODELS.add(model)
            continue
        # Transport (rc=*), auth (401), content (self-reference) → bail.
        # Trying a different model won't fix any of these.
        break
    return text, last_note or "copilot all models failed"


# Plan 3 Q2 (2026-04-23): Copilot self-reference detector.
# Trigger phrases observed in real records (records.json line 174 etc.) and
# common LLM refusal openings. Match in the FIRST 200 chars only — legitimate
# corrected text won't open with "I don't have" or "Please share".
_COPILOT_SELF_REF_PHRASES = (
    "i don't have any document",
    "i do not have any document",
    "i don't have any text",
    "i do not have any text",
    "please share the text",
    "please provide the text",
    "i'm unable to correct",
    "i am unable to correct",
    "i cannot correct",
    "i can't correct",
    "as an ai",
    "as a language model",
    "i'd be happy to help",
    "i'll be happy to help",
)


def _looks_like_copilot_self_reference(text: str) -> bool:
    if not text:
        return False
    head = text[:200].lower()
    return any(phrase in head for phrase in _COPILOT_SELF_REF_PHRASES)


# ---------------------------------------------------------------------------
# Job processing
# ---------------------------------------------------------------------------

def process_job(todo_path: Path) -> None:
    try:
        payload = json.loads(todo_path.read_text())
    except (OSError, json.JSONDecodeError) as e:
        log(f"bad todo file {todo_path.name}: {e}; deleting")
        todo_path.unlink(missing_ok=True)
        return

    basename = payload["wav_basename"]
    stage_id = payload["stage_id"]
    wav_path = payload["wav_path"]
    # t0 = float(payload["t0_epoch"])  # informational only; duration measured from work_start

    stage_def = STAGES_BY_ID.get(stage_id)
    if stage_def is None:
        log(f"unknown stage_id {stage_id}; skipping")
        todo_path.unlink(missing_ok=True)
        return

    # Mark running
    running_path = todo_path.with_suffix(".running")
    try:
        todo_path.rename(running_path)
    except OSError:
        return  # another worker grabbed it
    log(f"START {basename} :: {stage_def['label']}")
    trace("worker_job_start", basename=basename, stage_id=stage_id,
          model=stage_def.get("model"), corrected=stage_def.get("corrected"))

    # Run — measure actual work time (button-click latency for live recordings is
    # essentially this, since hook queues immediately)
    work_start = time.time()
    text, err = run_whisper(stage_def["model"], wav_path)
    whisper_ms = int((time.time() - work_start) * 1000)
    trace("worker_whisper_done", basename=basename, stage_id=stage_id,
          whisper_ms=whisper_ms, err=err, text_len=len(text or ""))
    # Plan 3 Q3 (2026-04-23): collapse runaway-loop hallucinations on raw
    # whisper output BEFORE dictionary/Copilot, so downstream stages see clean
    # text. Q1 strip is already applied inside run_whisper.
    if err is None and text:
        text = _collapse_runaway_loops(text)
    note = None
    if err is None and stage_def["corrected"]:
        # Snapshot raw whisper text BEFORE dictionary so we can tell whether
        # the dict actually changed anything when Copilot fails downstream.
        # This drives Plan 6 categorization: dict-improved-but-Copilot-failed
        # gets an INFO badge, fully-failed gets the WARNING badge.
        text_pre_dict = text
        dict_start = time.time()
        text = apply_dictionary(text)
        dict_changed = (text != text_pre_dict)
        trace("worker_dict_done", basename=basename, stage_id=stage_id,
              dict_ms=int((time.time() - dict_start) * 1000),
              dict_changed=dict_changed)
        copilot_start = time.time()
        text, note = apply_copilot(text)
        # Plan 3 Q1 (2026-04-23): Copilot may politely re-add "Thank you."
        # prefix it was supposed to remove. Re-strip after Copilot returns.
        if text:
            text = _strip_leading_hallucinations(text)
        trace("worker_copilot_done", basename=basename, stage_id=stage_id,
              copilot_ms=int((time.time() - copilot_start) * 1000), note=note)
        # Plan 6 (2026-04-23): if Copilot failed but dict already improved the
        # text, downgrade the note to an informational marker so HTML can
        # render a softer badge ("dict-corrected only") instead of the
        # alarming "copilot empty response". Text in `text` is still useful.
        if note and dict_changed:
            note = f"copilot skipped (dict-corrected only): {note}"

    # Plan 3 Q4 (2026-04-23): degraded_note is now a structured field, NOT
    # appended to text. Previously "[copilot empty response]" leaked into
    # pasted output and downstream pipelines.
    final_error = err
    degraded_note = note if (final_error is None and note) else None

    duration_ms = int((time.time() - work_start) * 1000)
    update_stage(basename, stage_id, text=text, duration_ms_from_t0=duration_ms,
                 error=final_error, degraded_note=degraded_note)
    log(f"DONE  {basename} :: {stage_def['label']}  ({duration_ms} ms{' ERR' if final_error else ''})")
    trace("worker_job_end", basename=basename, stage_id=stage_id,
          total_ms=duration_ms, err=final_error)
    running_path.unlink(missing_ok=True)


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

def drain_queue(stage_filter: str | None = None) -> int:
    """Drain queued .todo jobs. If stage_filter is set, only handle that stage's
    files (`*__{stage}.todo`); otherwise drain everything (legacy behavior).
    Basenames are timestamps with no underscores, so the `__{stage}` separator
    is unambiguous."""
    glob_pat = f"*__{stage_filter}.todo" if stage_filter else "*.todo"
    processed = 0
    while True:
        todos = sorted(QUEUE_DIR.glob(glob_pat))
        if not todos:
            return processed
        for t in todos:
            if not t.exists():
                continue
            process_job(t)
            processed += 1


def _parse_stage_arg() -> str | None:
    """Tiny manual parser — intentionally avoids argparse to match existing style."""
    if "--stage" not in sys.argv:
        return None
    i = sys.argv.index("--stage")
    if i + 1 >= len(sys.argv):
        return None
    sid = sys.argv[i + 1].strip()
    if sid not in STAGE_IDS:
        log(f"unknown --stage {sid!r}; valid: {STAGE_IDS}")
        return None
    return sid


def main() -> int:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    QUEUE_DIR.mkdir(parents=True, exist_ok=True)

    stage_filter = _parse_stage_arg()
    lock_path = _worker_lock_path(stage_filter) if stage_filter else WORKER_LOCK

    if not acquire_lock(lock_path):
        return 0
    try:
        watch = "--watch" in sys.argv
        log(f"worker started (pid={os.getpid()}, stage={stage_filter or 'ALL'}, watch={watch})")
        try:
            while True:
                reclaim_stale_running()
                mark_abandoned()
                processed = drain_queue(stage_filter)
                if processed > 0:
                    _refresh_status_and_html()
                if not watch:
                    break
                time.sleep(5)
        except KeyboardInterrupt:
            log("interrupted")
        log("worker exiting")
        return 0
    finally:
        release_lock(lock_path)


if __name__ == "__main__":
    sys.exit(main())
