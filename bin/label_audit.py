#!/usr/bin/env python3
"""label_audit.py — Vision-first project labeler with closed-vocab classification.

Reads ~/.whisper_log/records.json, classifies each record's screenshot using
claude-opus-4.7 against the closed vocabulary of ~/Documents/claude_projects/
folder names, falls back to transcript-based classification when the screenshot
is uninformative, and renders a verification HTML for human review.

Tasks A1-A9 of rpi/project-recognition-overhaul/plan.md.

DRY-RUN by default. NEVER mutates records.json directly. Writes:
  - <output>.html        (verification UI)
  - <output>.json        (machine-readable derivations)

Usage:
  python3 bin/label_audit.py --output ~/.whisper_log/labels_audit_v1
  python3 bin/label_audit.py --limit 5    # smoke test on first 5 records
  python3 bin/label_audit.py --basenames 20260424114918.wav  # specific records
"""
from __future__ import annotations

import argparse
import base64
import io
import json
import os
import re
import subprocess
import sys
import time
from collections import Counter
from pathlib import Path
from typing import Iterable

# --- Config ---------------------------------------------------------------

HOME = Path.home()
RECORDS_JSON = HOME / ".whisper_log" / "records.json"
PROJECTS_ROOT = HOME / "Documents" / "claude_projects"
LOG_PATH = HOME / ".whisper_log" / "label_audit.log"

VISION_MODEL = os.getenv("WHISPER_LABEL_MODEL", "claude-opus-4.7")
TEXT_MODEL = os.getenv("WHISPER_TEXT_MODEL", "claude-opus-4.7")
VISION_FALLBACKS = ["claude-opus-4.6", "claude-sonnet-4.6", "gpt-5.4", "gpt-4o"]

VISION_CONF_THRESHOLD = 0.6   # below → fall through to transcript
TRANSCRIPT_CONF_THRESHOLD = 0.6


# --- Logging --------------------------------------------------------------

def log(msg: str) -> None:
    line = f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}"
    try:
        LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass
    print(line, file=sys.stderr)


def _redact(s: str) -> str:
    if not s:
        return s
    s = re.sub(r'("(?:access_|copilot_|session_)?token"\s*:\s*")[^"]+(")', r'\1<redacted>\2', s)
    s = re.sub(r'(Bearer\s+)[A-Za-z0-9_\-\.]+', r'\1<redacted>', s)
    s = re.sub(r'\bghu_[A-Za-z0-9]+', '<redacted-ghu>', s)
    return s


# --- Task A2: Known projects ---------------------------------------------

_MASTER_SENTINEL = "master"  # reserved label for bare ~/Documents/claude_projects cwd


def load_known_projects() -> list[str]:
    """Return sorted list of folder names under ~/Documents/claude_projects/,
    plus the reserved `master` sentinel.

    The `master` entry is NOT a real folder. It labels recordings whose
    editor/terminal CWD is exactly the parent directory itself
    (`~/Documents/claude_projects` with no subfolder), which corresponds to
    the orchestrator/master shell where the user manages many projects.
    See: rpi/master-project-override/research.md.
    """
    if not PROJECTS_ROOT.exists():
        return [_MASTER_SENTINEL]
    try:
        folders = sorted(
            p.name for p in PROJECTS_ROOT.iterdir()
            if p.is_dir() and not p.name.startswith(".")
        )
    except OSError:
        folders = []
    # Insert sentinel in sorted position so vocab stays alphabetically ordered.
    if _MASTER_SENTINEL not in folders:
        folders = sorted(folders + [_MASTER_SENTINEL])
    return folders


# --- Task A3: Records ----------------------------------------------------

def load_records() -> dict[str, dict]:
    with open(RECORDS_JSON, "r", encoding="utf-8") as f:
        return json.load(f)


# --- Task A4: Screenshot path --------------------------------------------

def get_screenshot_path(record: dict) -> Path | None:
    p = record.get("screenshot_path") or ""
    if not p:
        return None
    path = Path(p)
    if not path.exists():
        return None
    try:
        if path.stat().st_size < 10 * 1024:  # < 10 KB → probably blank/black
            return None
    except OSError:
        return None
    return path


# --- Task A5: Transcript snippet -----------------------------------------

def get_transcript_snippet(record: dict, max_chars: int = 400) -> str:
    stages = record.get("stages") or {}
    for stage in ("large_corr", "base_raw"):
        s = stages.get(stage) or {}
        txt = (s.get("text") or "").strip()
        if txt:
            return txt[:max_chars]
    return ""


# --- Copilot auth (reused from extract_project_from_screenshot.py) -------

COPILOT_EXCHANGE_URL = "https://api.github.com/copilot_internal/v2/token"
COPILOT_TOKEN_CACHE = HOME / ".whisper_log" / "copilot_session.json"
COPILOT_AUTH = HOME / ".config" / "careless-whisper" / "auth.json"


def _resolve_copilot_token() -> str | None:
    if not COPILOT_AUTH.exists():
        log(f"no Copilot auth file at {COPILOT_AUTH}")
        return None
    try:
        data = json.loads(COPILOT_AUTH.read_text())
    except (OSError, json.JSONDecodeError) as e:
        log(f"cannot read Copilot auth: {e}")
        return None
    for k in ("access_token", "copilot_token", "token"):
        v = data.get(k)
        if v and isinstance(v, str) and v.strip():
            return v.strip()
    log("no token field in Copilot auth file")
    return None


def _exchange_copilot_session(gh_token: str) -> tuple[str, str] | None:
    now = int(time.time())
    if COPILOT_TOKEN_CACHE.exists():
        try:
            cached = json.loads(COPILOT_TOKEN_CACHE.read_text())
            if (
                isinstance(cached, dict)
                and cached.get("token")
                and cached.get("api_endpoint")
                and int(cached.get("expires_at", 0)) - 300 > now
            ):
                return cached["token"], cached["api_endpoint"]
        except (OSError, json.JSONDecodeError, ValueError):
            pass
    try:
        proc = subprocess.run(
            [
                "curl", "-sS", "--max-time", "15",
                "-H", f"Authorization: token {gh_token}",
                "-H", "Editor-Version: vscode/1.85.0",
                "-H", "Editor-Plugin-Version: copilot-chat/0.12.0",
                "-H", "User-Agent: GithubCopilot/1.155.0",
                COPILOT_EXCHANGE_URL,
            ],
            capture_output=True, text=True, timeout=20,
        )
    except Exception as e:
        log(_redact(f"copilot session exchange failed: {e}"))
        return None
    if proc.returncode != 0:
        log(_redact(f"copilot session exchange rc={proc.returncode}: {proc.stderr[:200]}"))
        return None
    try:
        data = json.loads(proc.stdout)
        session_token = data["token"]
        api_endpoint = data["endpoints"]["api"]
        expires_at = int(data.get("expires_at", now + 1500))
    except (json.JSONDecodeError, KeyError, ValueError) as e:
        log(_redact(f"copilot session exchange bad response: {e}"))
        return None
    try:
        COPILOT_TOKEN_CACHE.parent.mkdir(parents=True, exist_ok=True)
        COPILOT_TOKEN_CACHE.write_text(json.dumps({
            "token": session_token,
            "api_endpoint": api_endpoint,
            "expires_at": expires_at,
        }))
        os.chmod(COPILOT_TOKEN_CACHE, 0o600)
    except OSError:
        pass
    return session_token, api_endpoint


def _get_copilot_chat_url() -> str | None:
    gh = _resolve_copilot_token()
    if not gh:
        return None
    sess = _exchange_copilot_session(gh)
    if not sess:
        return None
    token, endpoint = sess
    # Cache token globally for this run
    global _SESSION_TOKEN
    _SESSION_TOKEN = token
    return endpoint.rstrip("/") + "/chat/completions"


_SESSION_TOKEN: str | None = None


# --- Task A9: Closed-vocab system prompt ---------------------------------

def closed_vocab_prompt_vision(known: list[str]) -> str:
    """System prompt for vision: forced-choice from known projects."""
    vocab = "\n".join(f"  - {p}" for p in known)
    return f"""You are classifying a screenshot to determine which software project the user was working on at the moment of capture.

CONTEXT: The user records short voice transcriptions while working. Each recording is paired with a screenshot of their screen. Your job is to identify which PROJECT FOLDER they were working in, based on visual evidence in the screenshot.

VOCABULARY: You MUST choose exactly ONE name from the list below, OR return "none" if no project is identifiable. Do not invent names.

SPECIAL LABEL — `master`:
Use `master` ONLY when the editor/terminal CWD is exactly `~/Documents/claude_projects`
(the parent directory itself, with NO subfolder after it). This indicates an orchestrator/
master shell session where the user manages many projects. Examples that map to `master`:
  - OpenCode statusline shows `~/Documents/claude_projects` (path ends here, no `/something`)
  - Terminal title says "MASTER" with a CWD of `~/Documents/claude_projects`
  - Tab labelled `MASTER ⌘1` paired with the bare parent path
Do NOT use `master` if a subfolder is visible (`~/Documents/claude_projects/whisper`,
`/Users/.../claude_projects/second_brain`, etc.) — pick the actual subfolder instead.

PRIMARY EVIDENCE (in order of reliability):
  1. Editor/terminal CWD shown in statusline, breadcrumb, or path bar
     (e.g. "~/Documents/claude_projects/<project>:main" in OpenCode statusline)
  2. iTerm2 / Terminal tab title showing the project name
  3. Cursor / VS Code window title
  4. Visible file path in any open editor
  5. Browser tab title showing a project-named GitHub repo

DO NOT use:
  - Spoken content (you cannot hear the recording)
  - Random terminal output / stderr text (e.g. "fopenReadStream")
  - Webex/Slack panel names (e.g. "Forward message to a person or space")
  - Generic words ("Editor", "Terminal", "main")
  - Function names from code (e.g. "NSAttributedString")

OUTPUT (strict JSON, no prose):
{{
  "project": "<exact name from vocabulary OR 'none'>",
  "signal_source": "<one of: cwd_statusline | tab_title | window_title | file_path | browser_tab | none>",
  "confidence": <float 0.0-1.0>,
  "reasoning": "<one sentence explaining what you saw>"
}}

VOCABULARY (choose one):
{vocab}
"""


def closed_vocab_prompt_transcript(known: list[str]) -> str:
    vocab = "\n".join(f"  - {p}" for p in known)
    return f"""You are classifying a short voice transcription to determine which software project the user was talking about.

VOCABULARY: You MUST choose exactly ONE name from the list below, OR return "none" if no project is mentioned or implied with high confidence. Do not invent names.

SPECIAL LABEL — `master`:
Use `master` ONLY when the user explicitly refers to working at the orchestrator/parent
level (e.g. "in my master shell", "from the claude_projects root", "as the master
manager"). Do NOT use `master` for generic transcripts that happen to mention multiple
projects — return "none" instead.

ACCEPT signals:
  - User explicitly names a project ("the whisper project", "for opencode-config")
  - User mentions a file path that contains a project name
  - User mentions a project-specific feature with no ambiguity ("the streaming inline copilot")

REJECT signals:
  - Generic technical talk ("the function", "the bug")
  - Casual filler ("let me think", "it works now")
  - Cross-project ambiguity (transcription mentions 2+ projects equally) → return "none"

OUTPUT (strict JSON, no prose):
{{
  "project": "<exact name from vocabulary OR 'none'>",
  "confidence": <float 0.0-1.0>,
  "reasoning": "<one sentence explaining what phrase triggered it>"
}}

VOCABULARY (choose one):
{vocab}
"""


# --- Task A6: Vision label -----------------------------------------------

def _prepare_image_b64(image_path: Path) -> str | None:
    try:
        from PIL import Image
        img = Image.open(image_path)
        if img.width > 1920:
            ratio = 1920 / img.width
            img = img.resize((1920, int(img.height * ratio)), Image.LANCZOS)
        buf = io.BytesIO()
        img.convert("RGB").save(buf, format="JPEG", quality=90)
        return base64.b64encode(buf.getvalue()).decode("ascii")
    except Exception as e:
        log(f"image prep failed for {image_path.name}: {e}")
        return None


def _call_vision(model: str, chat_url: str, prompt: str, b64: str) -> dict | None:
    payload = {
        "model": model,
        "messages": [{
            "role": "user",
            "content": [
                {"type": "text", "text": prompt},
                {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{b64}"}},
            ],
        }],
        "max_tokens": 300,
        "temperature": 0.0,
    }
    try:
        proc = subprocess.run(
            [
                "curl", "-sS", "--max-time", "60",
                "-H", f"Authorization: Bearer {_SESSION_TOKEN}",
                "-H", "Content-Type: application/json",
                "-H", "Editor-Version: vscode/1.85.0",
                "-H", "Copilot-Integration-Id: vscode-chat",
                "-H", "Copilot-Vision-Request: true",
                "-d", json.dumps(payload),
                chat_url,
            ],
            capture_output=True, text=True, timeout=70,
        )
    except Exception as e:
        log(_redact(f"vision call ({model}) failed: {e}"))
        return None
    if proc.returncode != 0:
        log(_redact(f"vision call ({model}) rc={proc.returncode}: {proc.stderr[:200]}"))
        return None
    try:
        data = json.loads(proc.stdout)
        if "error" in data:
            log(f"vision API ({model}) error: {data['error'].get('code','?')} — {data['error'].get('message','')[:120]}")
            return None
        out = data["choices"][0]["message"]["content"].strip()
    except (json.JSONDecodeError, KeyError, IndexError) as e:
        log(_redact(f"vision ({model}) bad response: {e} body={proc.stdout[:200]}"))
        return None
    raw = out.strip()
    if raw.startswith("```"):
        raw = re.sub(r"^```(?:json)?\s*", "", raw)
        raw = re.sub(r"\s*```$", "", raw)
    try:
        parsed = json.loads(raw)
        return parsed if isinstance(parsed, dict) else None
    except json.JSONDecodeError:
        log(f"vision ({model}) non-JSON output: {raw[:200]!r}")
        return None


def vision_label_screenshot(image_path: Path, known: list[str], chat_url: str) -> dict:
    """Returns dict: {project, source, confidence, reasoning, model_used}.
    project=None means model said 'none' or low-confidence."""
    b64 = _prepare_image_b64(image_path)
    if not b64:
        return {"project": None, "source": "vision_error", "confidence": 0.0,
                "reasoning": "image prep failed", "model_used": None}
    prompt = closed_vocab_prompt_vision(known)
    chain = [VISION_MODEL] + [m for m in VISION_FALLBACKS if m != VISION_MODEL]
    for model in chain:
        result = _call_vision(model, chat_url, prompt, b64)
        if result is None:
            continue
        proj = (result.get("project") or "").strip()
        try:
            conf = float(result.get("confidence", 0.0))
        except (TypeError, ValueError):
            conf = 0.0
        signal = (result.get("signal_source") or "none").strip()
        reasoning = (result.get("reasoning") or "")[:200]
        if proj.lower() in ("none", "", "unknown"):
            return {"project": None, "source": f"vision({model})", "confidence": conf,
                    "reasoning": f"model returned none: {reasoning}", "model_used": model}
        if proj not in known:
            log(f"vision ({model}) returned non-vocab '{proj}' — rejecting")
            return {"project": None, "source": f"vision({model})", "confidence": conf,
                    "reasoning": f"non-vocab '{proj}': {reasoning}", "model_used": model}
        return {"project": proj, "source": f"vision({model}/{signal})", "confidence": conf,
                "reasoning": reasoning, "model_used": model}
    return {"project": None, "source": "vision_chain_failed", "confidence": 0.0,
            "reasoning": "all vision models failed", "model_used": None}


# --- Task A7: Transcript label -------------------------------------------

def _call_text(model: str, chat_url: str, prompt: str, user_text: str) -> dict | None:
    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": prompt},
            {"role": "user", "content": user_text},
        ],
        "max_tokens": 200,
        "temperature": 0.0,
    }
    try:
        proc = subprocess.run(
            [
                "curl", "-sS", "--max-time", "30",
                "-H", f"Authorization: Bearer {_SESSION_TOKEN}",
                "-H", "Content-Type: application/json",
                "-H", "Editor-Version: vscode/1.85.0",
                "-H", "Copilot-Integration-Id: vscode-chat",
                "-d", json.dumps(payload),
                chat_url,
            ],
            capture_output=True, text=True, timeout=40,
        )
    except Exception as e:
        log(_redact(f"text call ({model}) failed: {e}"))
        return None
    if proc.returncode != 0:
        return None
    try:
        data = json.loads(proc.stdout)
        if "error" in data:
            return None
        out = data["choices"][0]["message"]["content"].strip()
    except (json.JSONDecodeError, KeyError, IndexError):
        return None
    if out.startswith("```"):
        out = re.sub(r"^```(?:json)?\s*", "", out)
        out = re.sub(r"\s*```$", "", out)
    try:
        parsed = json.loads(out)
        return parsed if isinstance(parsed, dict) else None
    except json.JSONDecodeError:
        return None


def transcript_label(transcript: str, known: list[str], chat_url: str) -> dict:
    if not transcript or len(transcript.strip()) < 20:
        return {"project": None, "source": "transcript_too_short", "confidence": 0.0,
                "reasoning": "transcript < 20 chars", "model_used": None}
    prompt = closed_vocab_prompt_transcript(known)
    chain = [TEXT_MODEL] + [m for m in VISION_FALLBACKS if m != TEXT_MODEL]
    for model in chain:
        result = _call_text(model, chat_url, prompt, transcript)
        if result is None:
            continue
        proj = (result.get("project") or "").strip()
        try:
            conf = float(result.get("confidence", 0.0))
        except (TypeError, ValueError):
            conf = 0.0
        reasoning = (result.get("reasoning") or "")[:200]
        if proj.lower() in ("none", "", "unknown"):
            return {"project": None, "source": f"transcript({model})", "confidence": conf,
                    "reasoning": f"model returned none: {reasoning}", "model_used": model}
        if proj not in known:
            return {"project": None, "source": f"transcript({model})", "confidence": conf,
                    "reasoning": f"non-vocab '{proj}': {reasoning}", "model_used": model}
        return {"project": proj, "source": f"transcript({model})", "confidence": conf,
                "reasoning": reasoning, "model_used": model}
    return {"project": None, "source": "transcript_chain_failed", "confidence": 0.0,
            "reasoning": "all text models failed", "model_used": None}


# --- Task A8: Orchestrator ------------------------------------------------

def label_record(basename: str, record: dict, known: list[str], chat_url: str) -> dict:
    """Returns dict with: basename, current_hint, derived_project, source,
    confidence, reasoning, screenshot_path, transcript_snippet, vision_result,
    transcript_result."""
    out = {
        "basename": basename,
        "current_hint": record.get("project_hint") or "",
        "screenshot_path": str(get_screenshot_path(record) or ""),
        "transcript_snippet": get_transcript_snippet(record, 400),
        "derived_project": None,
        "source": "uncertain",
        "confidence": 0.0,
        "reasoning": "",
        "vision_result": None,
        "transcript_result": None,
    }
    ss = get_screenshot_path(record)
    if ss:
        v = vision_label_screenshot(ss, known, chat_url)
        out["vision_result"] = v
        if v["project"] and v["confidence"] >= VISION_CONF_THRESHOLD:
            out["derived_project"] = v["project"]
            out["source"] = v["source"]
            out["confidence"] = v["confidence"]
            out["reasoning"] = v["reasoning"]
            return out
    transcript = out["transcript_snippet"]
    if transcript:
        t = transcript_label(transcript, known, chat_url)
        out["transcript_result"] = t
        if t["project"] and t["confidence"] >= TRANSCRIPT_CONF_THRESHOLD:
            out["derived_project"] = t["project"]
            out["source"] = t["source"]
            out["confidence"] = t["confidence"]
            out["reasoning"] = t["reasoning"]
            return out
    # Both failed → uncertain
    if out["vision_result"] and out["transcript_result"]:
        out["reasoning"] = (
            f"vision: {out['vision_result']['reasoning'][:80]} | "
            f"transcript: {out['transcript_result']['reasoning'][:80]}"
        )
    elif out["vision_result"]:
        out["reasoning"] = f"vision uncertain, no transcript: {out['vision_result']['reasoning'][:120]}"
    elif out["transcript_result"]:
        out["reasoning"] = f"no screenshot, transcript uncertain: {out['transcript_result']['reasoning'][:120]}"
    else:
        out["reasoning"] = "no screenshot and no transcript"
    return out


# --- Task B1-B5: HTML renderer (skeleton; will fill in next step) -------

_AUDIT_CSS = """
:root {
  color-scheme: dark;
  --bg: #0c0e12; --panel: #131720; --panel-2: #181d28; --border: #232a38;
  --text: #e6e9ef; --muted: #8b94a7; --accent: #4aa0ff; --accent-2: #5eead4;
  --ok: #5eead4; --warn: #f5b461; --bad: #ff7a90;
}
* { box-sizing: border-box; }
body {
  margin: 0; padding: 0 24px 80px;
  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
  background: var(--bg); color: var(--text); font-size: 14px; line-height: 1.45;
}
header.sticky {
  position: sticky; top: 0; z-index: 50;
  background: rgba(12,14,18,0.96); backdrop-filter: blur(8px);
  padding: 16px 0; margin: 0 -24px 16px; padding-left: 24px; padding-right: 24px;
  border-bottom: 1px solid var(--border);
  display: flex; align-items: center; gap: 18px; flex-wrap: wrap;
}
h1 { margin: 0; font-size: 18px; font-weight: 600; }
.summary-pills { display: flex; gap: 8px; flex-wrap: wrap; }
.pill {
  padding: 4px 10px; border-radius: 999px; font-size: 11.5px; font-weight: 600;
  background: var(--panel-2); border: 1px solid var(--border); color: var(--muted);
  font-variant-numeric: tabular-nums;
}
.pill.ok   { color: var(--ok);   border-color: rgba(94,234,212,0.3); }
.pill.warn { color: var(--warn); border-color: rgba(245,180,97,0.3); }
.pill.bad  { color: var(--bad);  border-color: rgba(255,122,144,0.3); }
.btn {
  background: var(--panel); color: var(--accent); border: 1px solid var(--border);
  padding: 6px 14px; border-radius: 6px; font-size: 12px; font-weight: 600;
  cursor: pointer; transition: all 0.15s;
}
.btn:hover { background: var(--accent); color: var(--bg); border-color: var(--accent); }
.btn.primary { background: var(--accent); color: var(--bg); border-color: var(--accent); }
.btn.primary:hover { background: var(--accent-2); border-color: var(--accent-2); }

.row {
  display: grid; grid-template-columns: 360px 1fr; gap: 16px;
  background: var(--panel); border: 1px solid var(--border); border-radius: 12px;
  padding: 14px; margin-bottom: 14px;
}
.row.agreed { border-color: rgba(94,234,212,0.4); }
.row.changed { border-color: rgba(245,180,97,0.5); }
.row.skipped { opacity: 0.55; }

.shot-cell { position: relative; }
.shot-cell img {
  width: 100%; max-height: 240px; object-fit: contain; object-position: top left;
  background: #000; border-radius: 8px; border: 1px solid var(--border);
  cursor: zoom-in;
}
.shot-cell .no-shot {
  height: 240px; display: flex; align-items: center; justify-content: center;
  background: var(--panel-2); border: 1px dashed var(--border); border-radius: 8px;
  color: var(--muted); font-style: italic;
}
.shot-cell .basename {
  font-family: ui-monospace, monospace; font-size: 10.5px; color: var(--muted);
  margin-top: 6px; word-break: break-all;
}

.info-cell { display: flex; flex-direction: column; gap: 10px; }
.label-grid {
  display: grid; grid-template-columns: 110px 1fr; gap: 6px 12px; align-items: center;
}
.label-grid label { color: var(--muted); font-size: 11.5px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.04em; }
.label-grid .val {
  font-family: ui-monospace, monospace; font-size: 13px;
  background: var(--panel-2); padding: 4px 8px; border-radius: 5px;
  border: 1px solid var(--border); word-break: break-all;
}
.label-grid .val.derived { color: var(--accent-2); font-weight: 600; }
.label-grid .val.current { color: var(--muted); }
.label-grid .val.uncertain { color: var(--warn); font-style: italic; }
.confidence {
  display: inline-block; padding: 2px 8px; border-radius: 4px; font-size: 11px;
  font-weight: 600; font-variant-numeric: tabular-nums;
}
.confidence.high { background: rgba(94,234,212,0.15); color: var(--ok); }
.confidence.med  { background: rgba(245,180,97,0.15); color: var(--warn); }
.confidence.low  { background: rgba(255,122,144,0.15); color: var(--bad); }
.reasoning {
  font-size: 12px; color: var(--muted); font-style: italic;
  background: var(--panel-2); padding: 6px 10px; border-radius: 5px;
  border-left: 2px solid var(--border);
}
.transcript-snippet {
  font-size: 12.5px; color: var(--text); background: var(--bg);
  border: 1px solid var(--border); border-radius: 5px; padding: 8px 10px;
  max-height: 90px; overflow-y: auto; white-space: pre-wrap;
}
.transcript-snippet.empty { color: var(--muted); font-style: italic; }

.controls { display: flex; gap: 10px; align-items: center; flex-wrap: wrap; margin-top: 6px; }
.controls input[type="checkbox"] { width: 16px; height: 16px; cursor: pointer; }
.controls label { cursor: pointer; user-select: none; font-size: 12.5px; }
.controls select, .controls input[type="text"] {
  background: var(--panel-2); color: var(--text); border: 1px solid var(--border);
  border-radius: 6px; padding: 5px 10px; font-size: 12.5px;
  font-family: ui-monospace, monospace; min-width: 240px;
}
.controls select:focus, .controls input:focus { outline: none; border-color: var(--accent); }

dialog.zoom {
  background: var(--bg); color: var(--text); border: 1px solid var(--border);
  border-radius: 12px; padding: 8px; max-width: 95vw; max-height: 95vh;
}
dialog.zoom::backdrop { background: rgba(0,0,0,0.85); }
dialog.zoom img { max-width: 90vw; max-height: 88vh; display: block; }

footer.sticky {
  position: fixed; bottom: 0; left: 0; right: 0;
  background: rgba(12,14,18,0.97); border-top: 1px solid var(--border);
  padding: 12px 24px; z-index: 100;
  display: flex; justify-content: space-between; align-items: center; gap: 14px;
}
"""

_AUDIT_JS = r"""
// In-memory state: { basename: { agreed: bool, override: str|null, skipped: bool } }
const STATE = {};
const ROWS = window.__AUDIT_ROWS__;
const KNOWN = window.__KNOWN_PROJECTS__;

function init() {
  ROWS.forEach(r => {
    STATE[r.basename] = {
      agreed: false,
      override: null,
      skipped: false,
    };
  });
  refreshSummary();
}

function rowEl(basename) { return document.querySelector(`.row[data-bn="${basename}"]`); }

function onAgreeChange(basename, checked) {
  STATE[basename].agreed = checked;
  STATE[basename].skipped = false;
  const el = rowEl(basename);
  el.classList.toggle('agreed', checked);
  el.classList.remove('skipped');
  if (checked) {
    // clear override when agreeing
    const sel = el.querySelector('.override-sel');
    if (sel) sel.value = '';
    STATE[basename].override = null;
    el.classList.remove('changed');
  }
  refreshSummary();
}

function onOverrideChange(basename, value) {
  const el = rowEl(basename);
  if (value && value !== '__SKIP__') {
    STATE[basename].override = value;
    STATE[basename].agreed = false;
    STATE[basename].skipped = false;
    el.classList.add('changed');
    el.classList.remove('agreed', 'skipped');
    const ag = el.querySelector('.agree-cb');
    if (ag) ag.checked = false;
  } else if (value === '__SKIP__') {
    STATE[basename].override = null;
    STATE[basename].agreed = false;
    STATE[basename].skipped = true;
    el.classList.add('skipped');
    el.classList.remove('agreed', 'changed');
    const ag = el.querySelector('.agree-cb');
    if (ag) ag.checked = false;
  } else {
    STATE[basename].override = null;
    el.classList.remove('changed');
  }
  refreshSummary();
}

function refreshSummary() {
  const total = ROWS.length;
  let agreed = 0, changed = 0, skipped = 0, untouched = 0;
  for (const bn in STATE) {
    const s = STATE[bn];
    if (s.agreed) agreed++;
    else if (s.override) changed++;
    else if (s.skipped) skipped++;
    else untouched++;
  }
  document.getElementById('sum-agreed').textContent = `${agreed} agreed`;
  document.getElementById('sum-changed').textContent = `${changed} changed`;
  document.getElementById('sum-skipped').textContent = `${skipped} skipped`;
  document.getElementById('sum-untouched').textContent = `${untouched} untouched`;
  document.getElementById('sum-total').textContent = `${total} total`;
  const acc = (agreed / total) * 100;
  document.getElementById('sum-acc').textContent = `${acc.toFixed(1)}% agreed-rate`;
}

function exportCorrections() {
  const out = { exported_at: new Date().toISOString(), corrections: [] };
  for (const r of ROWS) {
    const s = STATE[r.basename];
    let final, action;
    if (s.skipped) { final = null; action = 'skip'; }
    else if (s.override) { final = s.override; action = 'override'; }
    else if (s.agreed) { final = r.derived_project; action = 'agree'; }
    else { final = null; action = 'untouched'; }
    out.corrections.push({
      basename: r.basename,
      current_hint: r.current_hint || '',
      derived_project: r.derived_project,
      derived_source: r.source,
      derived_confidence: r.confidence,
      final_label: final,
      action: action,
    });
  }
  const blob = new Blob([JSON.stringify(out, null, 2)], {type: 'application/json'});
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = 'label_corrections.json';
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  URL.revokeObjectURL(url);
}

function agreeAllHighConf() {
  for (const r of ROWS) {
    if (r.derived_project && (r.confidence || 0) >= 0.85) {
      const cb = document.querySelector(`.row[data-bn="${r.basename}"] .agree-cb`);
      if (cb && !cb.checked) {
        cb.checked = true;
        onAgreeChange(r.basename, true);
      }
    }
  }
}

function zoomImg(src) {
  const dlg = document.getElementById('zoom-dlg');
  document.getElementById('zoom-img').src = src;
  dlg.showModal();
}

document.addEventListener('DOMContentLoaded', init);
"""


def _classify_conf(c: float) -> str:
    if c >= 0.85:
        return "high"
    if c >= 0.6:
        return "med"
    return "low"


def _esc(s: str) -> str:
    import html as _html
    return _html.escape(s or "", quote=True)


def _options_html(known: list[str], current: str | None) -> str:
    cur = (current or "").strip()
    parts = ['<option value="">— choose override —</option>']
    parts.append('<option value="__SKIP__">⊘ Skip (set to none/uncertain)</option>')
    for p in known:
        sel = " selected" if p == cur else ""
        parts.append(f'<option value="{_esc(p)}"{sel}>{_esc(p)}</option>')
    return "".join(parts)


def render_audit_html(rows: list[dict], known: list[str], out_path: Path) -> None:
    rows_html = []
    for r in rows:
        bn = r["basename"]
        derived = r.get("derived_project")
        derived_disp = derived or "(uncertain)"
        derived_cls = "uncertain" if derived is None else "derived"
        conf = float(r.get("confidence") or 0)
        conf_cls = _classify_conf(conf)
        source = r.get("source", "")
        reasoning = r.get("reasoning", "")
        current = r.get("current_hint") or ""
        ss_path = r.get("screenshot_path") or ""
        transcript = r.get("transcript_snippet") or ""
        # Use file:// URI for local screenshots so the browser can load them
        if ss_path:
            shot_html = f'<img src="file://{_esc(ss_path)}" alt="screenshot" onclick="zoomImg(this.src)">'
        else:
            shot_html = '<div class="no-shot">no screenshot</div>'
        transcript_html = (
            f'<div class="transcript-snippet">{_esc(transcript)}</div>'
            if transcript
            else '<div class="transcript-snippet empty">(no transcript)</div>'
        )
        rows_html.append(f"""
<div class="row" data-bn="{_esc(bn)}">
  <div class="shot-cell">
    {shot_html}
    <div class="basename">{_esc(bn)}</div>
  </div>
  <div class="info-cell">
    <div class="label-grid">
      <label>Current</label>
      <div class="val current">{_esc(current) or '<span style="opacity:0.5">(empty)</span>'}</div>
      <label>Derived</label>
      <div class="val {derived_cls}">{_esc(derived_disp)} <span class="confidence {conf_cls}">{conf:.2f}</span></div>
      <label>Source</label>
      <div class="val" style="font-size:11.5px;color:var(--muted)">{_esc(source)}</div>
    </div>
    <div class="reasoning">{_esc(reasoning)}</div>
    {transcript_html}
    <div class="controls">
      <input type="checkbox" id="ag-{_esc(bn)}" class="agree-cb"
             onchange="onAgreeChange('{_esc(bn)}', this.checked)"
             {'disabled' if derived is None else ''}>
      <label for="ag-{_esc(bn)}">✓ Agree with derived label</label>
      <span style="color:var(--muted);font-size:11px">— or —</span>
      <select class="override-sel" onchange="onOverrideChange('{_esc(bn)}', this.value)">
        {_options_html(known, None)}
      </select>
    </div>
  </div>
</div>""")

    body = "\n".join(rows_html)
    rows_json = json.dumps(rows)
    known_json = json.dumps(known)

    html = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Whisper Label Audit ({len(rows)} records)</title>
<style>{_AUDIT_CSS}</style>
</head>
<body>
<header class="sticky">
  <h1>Label Audit — {len(rows)} records</h1>
  <div class="summary-pills">
    <span class="pill ok"   id="sum-agreed">0 agreed</span>
    <span class="pill warn" id="sum-changed">0 changed</span>
    <span class="pill"      id="sum-skipped">0 skipped</span>
    <span class="pill"      id="sum-untouched">0 untouched</span>
    <span class="pill"      id="sum-total">{len(rows)} total</span>
    <span class="pill"      id="sum-acc">0.0% agreed-rate</span>
  </div>
  <div style="margin-left:auto;display:flex;gap:8px">
    <button class="btn" onclick="agreeAllHighConf()">⚡ Agree all ≥0.85</button>
    <button class="btn primary" onclick="exportCorrections()">⬇ Export corrections.json</button>
  </div>
</header>
<main>
{body}
</main>
<dialog class="zoom" id="zoom-dlg" onclick="this.close()">
  <img id="zoom-img" src="" alt="zoomed screenshot">
</dialog>
<footer class="sticky">
  <div class="muted" style="font-size:12px;color:var(--muted)">
    Tip: ✓ Agree = accept derived. Override dropdown = pick from {len(known)} known projects. Skip = mark uncertain.
  </div>
  <button class="btn primary" onclick="exportCorrections()">⬇ Export corrections.json</button>
</footer>
<script>
window.__AUDIT_ROWS__ = {rows_json};
window.__KNOWN_PROJECTS__ = {known_json};
{_AUDIT_JS}
</script>
</body>
</html>
"""
    out_path.write_text(html, encoding="utf-8")


# --- Main ----------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--output", default=str(HOME / ".whisper_log" / "labels_audit"),
                    help="output base path (no extension); will write .html and .json")
    ap.add_argument("--limit", type=int, default=0, help="process only first N records")
    ap.add_argument("--basenames", nargs="*", help="process only specific basenames")
    args = ap.parse_args()

    known = load_known_projects()
    if not known:
        log("FATAL: no known projects under ~/Documents/claude_projects/")
        return 1
    log(f"loaded {len(known)} known projects")

    records = load_records()
    log(f"loaded {len(records)} records")

    if args.basenames:
        items = [(b, records[b]) for b in args.basenames if b in records]
    else:
        items = sorted(records.items())
    if args.limit:
        items = items[:args.limit]
    log(f"processing {len(items)} records")

    chat_url = _get_copilot_chat_url()
    if not chat_url:
        log("FATAL: cannot get Copilot chat URL")
        return 1

    rows = []
    for i, (basename, record) in enumerate(items, 1):
        log(f"[{i}/{len(items)}] {basename}")
        try:
            row = label_record(basename, record, known, chat_url)
        except Exception as e:
            log(f"label_record({basename}) crashed: {e}")
            row = {"basename": basename, "error": str(e),
                   "current_hint": record.get("project_hint", ""),
                   "derived_project": None, "source": "exception"}
        rows.append(row)
        log(f"  → derived={row.get('derived_project')!r} source={row.get('source')!r} "
            f"conf={row.get('confidence', 0):.2f}")

    out_base = Path(args.output)
    json_path = out_base.with_suffix(".json")
    html_path = out_base.with_suffix(".html")
    json_path.parent.mkdir(parents=True, exist_ok=True)
    json_path.write_text(json.dumps(rows, indent=2), encoding="utf-8")
    log(f"wrote {json_path}")
    render_audit_html(rows, known, html_path)
    log(f"wrote {html_path}")

    # Summary
    src_counts = Counter(r.get("source", "?") for r in rows)
    derived_counts = Counter(r.get("derived_project") or "(uncertain)" for r in rows)
    log("--- SUMMARY ---")
    log(f"sources: {dict(src_counts)}")
    log(f"derived projects: {dict(derived_counts.most_common(15))}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
