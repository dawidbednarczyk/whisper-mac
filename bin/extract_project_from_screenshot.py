#!/usr/bin/env python3
"""
Extract a short project identifier from a desktop screenshot, then write it
into the matching Whisper transcription record's project_hint.

Usage:
    extract_project_from_screenshot.py <screenshot_path> <wav_basename>

Strategy (cheapest-first):
    1. Crop top 120px (terminal/IDE tab area), OCR with tesseract.
       Look for `~/.../<project>:` (iTerm tab title style with git branch suffix)
       or `~/.../<project>` (path on its own line, e.g. tmux pane title).
    2. Fall back to vision LLM (gpt-4o-mini via Copilot) on a downscaled image.
    3. Either way, write the result via transcription_log.update_project_hint.

Never crashes the pipeline — any exception → log to stderr, exit 0.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from collections import Counter
from pathlib import Path

# Allow `from transcription_log import ...` regardless of cwd
_BIN_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(_BIN_DIR))

LOG_PATH = Path.home() / ".whisper_log" / "extract_project.log"


def log(msg: str) -> None:
    try:
        LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}\n")
    except OSError:
        pass
    print(msg, file=sys.stderr)


# --- Regex extraction ------------------------------------------------------
#
# Layer 1 — Deterministic, weighted, multi-signal extraction from OCR text.
# This MUST run before the LLM. The LLM hallucinates project names from spoken
# content (e.g. record discussing "screenshot parser" → labeled `screenshot-parser`
# even though the active project per the cwd indicator is `whisper`). Structural
# UI signals (cwd statusline, terminal tab title) are FAR more reliable than
# letting an LLM weigh signals.

# Cwd indicators — strongest signal. Matches:
#   ~/Documents/claude_projects/whisper:main         (OpenCode statusline)
#   ~/Documents/claude_projects/whisper              (bare path)
#   /Users/<you>/projects/example
#   ~/claude_projects/whisper
#
# Tesseract OCR of dark-theme statusline often introduces:
#   - stray spaces inside words ("whi sper", "claude_proiects")
#   - apostrophe in "Documents" → "Document's"
#   - 'i' misread as '|' or '!'
#   - 'j' misread as 'i' (proiects vs projects — accepted via fuzzy alt)
# So the regex tolerates an optional space inside the project component, and
# we glue split words back together post-match.
# Note on the optional internal space: OCR occasionally splits long
# identifiers with a space ("bu-open-Orchestrator" etc). The original
# pattern allowed `(?:\s[\w.\-]+)?` inside the project token to glue them
# back. Problem (cycle-3): that also greedy-slurps trailing noise after a
# legit project, turning `.../Migros_CCC_to_2.3.7.11_upgrade 1.4.10` into
# the candidate `Migros_CCC_to_2.3.7.11_upgrade 1.4.10` — which then
# (correctly) fails the known-folder match. The fix is to constrain the
# optional tail: only allow it when the first token is very short
# (<=4 chars, which can happen with OCR fragmentation) AND the joined
# result lives inside _known_projects(). We do that post-match in
# _normalize_candidate, so the regex itself no longer accepts
# arbitrary space-separated tails.
_CWD_RE = re.compile(
    r"~?/?(?:Users/[\w.\-]+/)?(?:Document'?s/)?claude[_\-]?pro[ij]ects/(?P<project>[\w.\-]+)",
    re.IGNORECASE,
)
# Generic deep path — for projects outside claude_projects (e.g. ~/bin, ~/repos/foo)
_DEEP_PATH_RE = re.compile(
    r"~?/?(?:[\w.\-]+/){2,}(?P<project>[\w.\-]+?)(?=[\s:/\n]|$)"
)
# iTerm2 tab title with cmd-N hint: "whisper ⌘7", "whisper ⌘ 7", "whisper 3€7" (Tesseract mangling)
# Generic glyph + digit (1-9). Tesseract maps ⌘ to: #, %, $, @, 3€, 4€, etc.
_TAB_HINT_RE = re.compile(
    r"\b(?P<project>[a-zA-Z][\w.\-]{2,})\s+(?:[#%$@]|3€|4€|°|\*)\s*(?P<num>\d)\b"
)
# iTerm2 / OpenCode tab with branch suffix: "whisper:main", "whisper: main"
# F-05 (QC cycle 1): tightened to a closed branch-name set. The original open
# alternative `[a-z][\w./\-]+` matched things like "bu-open-\nOrchestrator"
# (an OCR-mangled function name) as a "branch", letting noise become a hint.
_TAB_BRANCH_RE = re.compile(
    r"~?/?(?:[\w.\-]+/)*(?P<project>[\w.\-]+)\s*:\s*"
    r"(?:main|master|develop|HEAD|trunk"
    r"|feat/[\w.\-]+|fix/[\w.\-]+|chore/[\w.\-]+|docs/[\w.\-]+|refactor/[\w.\-]+"
    r"|release/[\w.\-]+|hotfix/[\w.\-]+|bugfix/[\w.\-]+)\b"
)

# Stop words — common path components, UI labels, branches. NEVER projects.
_STOP = {
    # Filesystem containers
    "Users", "Documents", "Desktop", "Downloads", "Library", "Applications",
    "System", "private", "tmp", "var", "opt", "usr", "etc", "home",
    "claude_projects", "claude-projects", "github", "GitHub",
    "src", "bin", "lib", "node_modules", "dist", "build", "target",
    # Git refs
    "main", "master", "develop", "HEAD", "trunk",
    # UI / app chrome words
    "Editor", "Terminal", "Answer", "Search", "Menu", "File", "Edit", "View",
    "Window", "Help", "Tab", "Untitled", "New",
}

# Add the current user's macOS short-name (``$USER``) to the STOP set at
# runtime — the parent ``Users/<name>`` directory often shows up in OCR'd
# paths and must never be treated as a project name. This replaces a
# previously hardcoded literal.
_current_user = os.environ.get("USER", "").strip()
if _current_user:
    _STOP.add(_current_user)

# Stderr / error noise tokens — common identifiers that show up in terminal
# output but are NEVER a real project name. The LLM has been observed to
# pick these up from terminal panes visible in the screenshot.
_STOP_NOISE = {
    # Tesseract / leptonica errors (this very debugging session caused these)
    "fopenReadStream", "Leptonica", "pixRead", "findFileFormat", "fopen",
    # Generic Python / shell error tokens
    "Traceback", "Exception", "Error", "TypeError", "ValueError",
    "AttributeError", "KeyError", "ImportError", "RuntimeError",
    "OSError", "IOError", "JSONDecodeError", "FileNotFoundError",
    "NameError", "SyntaxError", "IndexError", "ZeroDivisionError",
    # macOS / system frameworks that occasionally appear in console
    "NSError", "CFError", "kCFRunLoop",
}
_STOP = _STOP | _STOP_NOISE


def _known_projects() -> set[str]:
    """Return set of folder names under ~/Documents/claude_projects/.
    Used as a soft sanity check on extracted project hints — a hint that
    matches a real folder is much more likely to be correct."""
    base = Path.home() / "Documents" / "claude_projects"
    if not base.exists():
        return set()
    try:
        return {p.name for p in base.iterdir() if p.is_dir() and not p.name.startswith(".")}
    except OSError:
        return set()


def _looks_like_camelcase_identifier(s: str) -> bool:
    """Heuristic: does this look like a function/class name from terminal output
    rather than a project folder name? Real project folders are usually
    short, lowercase, hyphen/underscore separated. Function names are
    typically CamelCase, longer, no separators.
    Examples it should reject: fopenReadStream, NSAttributedString, getUserById
    Examples it should accept: whisper, second-brain, opencode_config, MyProject (short)
    """
    if not s:
        return False
    if "-" in s or "_" in s:
        return False  # has separator -> looks project-ish
    if len(s) <= 8:
        return False  # too short to be a worrisome identifier
    # CamelCase = starts with letter, has at least one uppercase mid-word
    if not s[0].isalpha():
        return False
    has_internal_caps = any(c.isupper() for c in s[1:])
    return has_internal_caps


def _normalize_candidate(s: str) -> str:
    """Glue OCR-introduced spaces back together. 'whi sper' -> 'whisper'.
    Strip trailing colons/slashes left over from path matches.
    Strip embedded newlines (regex can capture across line boundaries when
    OCR injects \\n inside what looks like a single token)."""
    if not s:
        return s
    # Strip control characters incl. embedded newlines and tabs (OCR / regex
    # bleed). Observed: 'bu-open-\nOrchestrator' from an OCR'd terminal pane.
    s = re.sub(r"[\r\n\t]+", "", s)
    # Glue: collapse single internal spaces, but keep words that are clearly two
    # words (e.g. 'second brain' is a real project name with hyphen → 'second-brain').
    # Heuristic: if the candidate is all lowercase + short, glue. If it has caps
    # or is long, keep the hyphenated form.
    s = s.strip().rstrip(":/")
    if " " in s:
        parts = s.split()
        if len(parts) == 2 and all(p.islower() and len(p) <= 4 for p in parts):
            # Likely OCR split: 'whi sper' (3+3) -> 'whisper'
            return "".join(parts)
        # Otherwise treat as multi-word slug -> hyphenate
        return "-".join(parts)
    return s


def _dehyphenate_wraps(text: str) -> str:
    r"""Rejoin line-wrapped tokens produced by OCR on wide terminal windows.

    Tesseract breaks long lines at column boundaries, sometimes splitting a
    hyphenated identifier across two output lines. On ultrawide displays
    (3440px), the OpenCode statusline `~/Documents/claude_projects/opencode-
    config:main` becomes:
        ~/Documents/claude_projects/opencode-
        Orchestrator … medium config:main

    This turns the gold-standard CWD signal (_CWD_RE, score=10) into noise
    the regex cannot match (cycle-3 systemic bug).

    Strategy: when a line ends with `<prefix>-`, and a later non-blank line
    contains a branch-suffix anchor `<token>:(main|master|…)`, emit a
    synthesized fused line `<prefix>-<token>:<branch>` and drop the
    original hyphenated head so downstream matchers see a single clean path.
    We keep the continuation line intact (the branch anchor remains for
    _TAB_BRANCH_RE and we never want to hide signal).

    Conservative guards:
      - Only fuse at hard `-` terminators (hyphenated identifier)
      - Require branch anchor on next line (bounded search: 1 line only)
      - Token must match `[a-zA-Z][\w.]{1,}` — no punctuation leakage
    """
    if not text or "-\n" not in text:
        return text
    lines = text.splitlines()
    _BRANCH_ANCHOR = re.compile(
        r"\b(?P<tok>[a-zA-Z][\w.]{1,})\s*:\s*"
        r"(?P<branch>main|master|develop|HEAD|trunk"
        r"|feat/[\w.\-]+|fix/[\w.\-]+|chore/[\w.\-]+|docs/[\w.\-]+|refactor/[\w.\-]+"
        r"|release/[\w.\-]+|hotfix/[\w.\-]+|bugfix/[\w.\-]+)\b",
        re.IGNORECASE,
    )
    out: list[str] = []
    for i, line in enumerate(lines):
        stripped = line.rstrip()
        if stripped.endswith("-") and i + 1 < len(lines):
            nxt = lines[i + 1]
            bm = _BRANCH_ANCHOR.search(nxt)
            if bm:
                tok = bm.group("tok")
                branch = bm.group("branch")
                # Synthesize a clean, regex-friendly fused line. Emit it
                # BEFORE the original hyphenated line so the CWD regex sees
                # it first. Leave the original lines untouched to avoid
                # hiding any signal that other matchers depend on.
                fused = f"{stripped}{tok}:{branch}"
                out.append(fused)
        out.append(line)
    return "\n".join(out)


def _try_regex(text: str) -> tuple[str, int] | None:
    """Layer-1 deterministic extractor. Weighted voting across structural signals.

    Returns (project, winning_score) or None. Score lets the caller gauge
    provenance confidence — a cwd-match (score=10) is gold standard even if
    the project isn't (yet) in the known-folder set.

    Weights:
      cwd indicator (claude_projects path):  10  (gold — explicit working directory)
      tab branch suffix (`foo:main`):         7  (silver — terminal tab title)
      tab cmd-N hint (`foo ⌘7`):              5  (bronze — iTerm tab list)
      deep generic path:                      3  (last resort)
    """
    if not text:
        return None

    # Cycle-3 fix: rejoin OCR line-wrapped hyphenated paths before matching.
    # On ultrawide (3440px) displays the statusline path frequently wraps at
    # a hyphen, silently defeating _CWD_RE. Run dehyphenation on a copy so
    # the original text is still passed to downstream matchers.
    text = _dehyphenate_wraps(text)

    candidates: Counter[str] = Counter()

    for m in _CWD_RE.finditer(text):
        cand = _normalize_candidate(m.group("project"))
        if cand and cand not in _STOP and len(cand) >= 3:
            candidates[cand] += 10

    for m in _TAB_BRANCH_RE.finditer(text):
        cand = _normalize_candidate(m.group("project"))
        if cand and cand not in _STOP and len(cand) >= 3:
            candidates[cand] += 7

    for m in _TAB_HINT_RE.finditer(text):
        cand = _normalize_candidate(m.group("project"))
        if cand and cand not in _STOP and len(cand) >= 3:
            candidates[cand] += 5

    # Only fall through to generic deep-path if nothing structural matched.
    # Generic path matching is noisy (matches anything that looks like a/b/c).
    if not candidates:
        for line in text.splitlines():
            for m in _DEEP_PATH_RE.finditer(line):
                cand = _normalize_candidate(m.group("project"))
                if cand and cand not in _STOP and len(cand) >= 3:
                    candidates[cand] += 3

    if not candidates:
        return None
    winner, score = candidates.most_common(1)[0]
    # Require minimum confidence: a single weak generic-path match alone is not enough
    if score < 5:
        return None
    return winner, score


def _resolve_tesseract() -> str | None:
    """Find tesseract binary. hs.task.new strips PATH, so check Homebrew dirs explicitly."""
    p = shutil.which("tesseract")
    if p:
        return p
    for cand in ("/opt/homebrew/bin/tesseract", "/usr/local/bin/tesseract"):
        if os.path.isfile(cand) and os.access(cand, os.X_OK):
            return cand
    return None


def _ocr_top_band(screenshot: Path) -> str:
    """OCR via tesseract.

    For Layer-1 deterministic extraction we need BOTH:
      - Top band (terminal tabs, browser tabs, window titles)
      - Bottom band (OpenCode/IDE statusline showing cwd + git branch)
    For full-screen shots we OCR top 220px + bottom 120px (skip the noisy middle).
    For small/pre-cropped images we OCR the whole thing.
    """
    tess = _resolve_tesseract()
    if not tess:
        log("tesseract not found in PATH or /opt/homebrew/bin or /usr/local/bin")
        return ""
    try:
        from PIL import Image
    except ImportError:
        log("PIL not installed — skipping regex path")
        return ""

    try:
        img = Image.open(screenshot)
        w, h = img.size
        crops: list = []
        if h <= 400:
            crops.append(img)
        else:
            crops.append(img.crop((0, 0, w, 220)))           # top — tabs, titles
            crops.append(img.crop((0, max(0, h - 140), w, h)))  # bottom — statusline

        out_parts: list[str] = []
        for crop in crops:
            with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as tmp:
                crop_path = tmp.name
            try:
                crop.save(crop_path)
                proc = subprocess.run(
                    [tess, crop_path, "-", "--psm", "6"],
                    capture_output=True, text=True, timeout=10,
                )
                if proc.stdout:
                    out_parts.append(proc.stdout)
            finally:
                try:
                    os.unlink(crop_path)
                except OSError:
                    pass
        return "\n".join(out_parts)
    except Exception as e:
        log(f"OCR failed: {e}")
        return ""


# --- LLM fallback ----------------------------------------------------------

COPILOT_AUTH = Path.home() / ".config" / "careless-whisper" / "auth.json"
# Cache the exchanged short-lived Copilot session token (`tid=...`) here.
# The raw `ghu_` token in auth.json is a GitHub OAuth token and is rejected
# by the Copilot chat endpoint with HTTP 403. It must first be exchanged
# via api.github.com/copilot_internal/v2/token.
COPILOT_TOKEN_CACHE = Path.home() / ".cache" / "careless-whisper" / "copilot_session.json"
# NOTE: do NOT hardcode the chat endpoint — the exchange response tells us
# which endpoint to use (api.githubcopilot.com vs api.enterprise.githubcopilot.com).
COPILOT_EXCHANGE_URL = "https://api.github.com/copilot_internal/v2/token"
# gpt-4o-mini does NOT accept image content via Copilot ("image media type
# not supported"). gpt-4o does. Default to a vision-capable model.
# F2: WHISPER_VISION_MODEL env knob removed (no writer existed anywhere — dead config).
# Vision needs an image-capable model; gpt-4o-mini does NOT accept Copilot image content.
# F-Vision-Quality (2026-04-24): user prioritizes quality over cost — switched
# from gpt-4o to claude-opus-4.7, the same vision model used in OpenCode
# sessions. Per Copilot /models endpoint, opus-4.7 is the highest-quality
# vision-capable model available on the enterprise endpoint (168k context,
# tool-use, vision). Fallback chain tries other top models if opus is
# unavailable for the user's plan.
COPILOT_MODEL = os.getenv("WHISPER_VISION_MODEL", "claude-opus-4.7")
COPILOT_MODEL_FALLBACKS = [
    "claude-opus-4.6",
    "claude-sonnet-4.6",
    "gpt-5.4",
    "gpt-4o",  # last resort — older but reliable vision support
]

_VISION_PROMPT = (
    "You identify the ACTIVE PROJECT / GIT REPOSITORY the user is currently "
    "working in, based ONLY on STRUCTURAL UI signals in the screenshot.\n"
    "\n"
    "STRUCTURAL SIGNALS (in priority order — only these count):\n"
    "  1. IDE / editor statusline showing the workspace folder + git branch "
    "     (OpenCode, VS Code, Cursor — usually bottom of the window). "
    "     Example: `~/Documents/claude_projects/whisper:main` → `whisper`.\n"
    "  2. Terminal tab title with cwd path or `name:branch` "
    "     (iTerm2, Ghostty, Terminal.app — usually top of terminal window). "
    "     Example: `whisper ⌘7` (active tab) → `whisper`.\n"
    "  3. macOS window title bar showing the project folder name.\n"
    "  4. Browser tab pointing at github.com/<user>/<repo> → `<repo>`.\n"
    "\n"
    "CRITICAL — DO NOT USE THESE AS SIGNALS (they are NOISE):\n"
    "  - The TOPIC the user is talking/typing about.\n"
    "  - File names, function names, variable names visible in code.\n"
    "  - Words appearing in chat messages, terminal output, or document body.\n"
    "  - Document titles in word processors / wikis (e.g. 'IMG macro-config guide').\n"
    "  - Container folder names: claude_projects, claude-projects, github, "
    "    GitHub, src, bin, lib, Documents, Downloads, Desktop, Users, "
    "    Library, Applications, node_modules, dist, build.\n"
    "  - Branch names: main, master, develop, HEAD.\n"
    "  - Generic UI words: Editor, Terminal, Menu, File, Edit, View, Window.\n"
    "\n"
    "Always return the DEEPEST path component of the active workspace. "
    "Example: path `~/Documents/claude_projects/cursor-config` → "
    "return `cursor-config`, NOT `claude_projects`.\n"
    "\n"
    "Output STRICT JSON (no prose, no markdown fence) with these keys:\n"
    "  project        — the project identifier (lowercase, hyphens/underscores ok), "
    "                   max 3 words, or the literal string 'UNKNOWN'.\n"
    "  signal_source  — one of: 'ide_statusline', 'terminal_tab', "
    "                   'window_title', 'browser_url', 'none'.\n"
    "  confidence     — float 0.0-1.0. Use <0.5 if you had to guess from "
    "                   body content (in which case prefer project='UNKNOWN').\n"
    "\n"
    "Example: {\"project\": \"whisper\", \"signal_source\": \"ide_statusline\", \"confidence\": 0.95}\n"
    "Example: {\"project\": \"UNKNOWN\", \"signal_source\": \"none\", \"confidence\": 0.0}"
)


def _resolve_copilot_token() -> str | None:
    """Return the raw GitHub OAuth token (ghu_...) from auth.json."""
    if not COPILOT_AUTH.exists():
        return None
    try:
        data = json.loads(COPILOT_AUTH.read_text())
    except (OSError, json.JSONDecodeError):
        return None
    for k in ("access_token", "copilot_token", "token"):
        v = data.get(k)
        if v and isinstance(v, str) and v.strip():
            return v.strip()
    return None


def _exchange_copilot_session(gh_token: str) -> tuple[str, str] | None:
    """Exchange a `ghu_...` GitHub OAuth token for a short-lived Copilot
    session token + chat endpoint. Returns (session_token, api_endpoint) or None.

    Caches the response in COPILOT_TOKEN_CACHE and reuses it until ~5 min before
    expiry. The chat endpoint is enterprise-specific (Cisco uses
    api.enterprise.githubcopilot.com) and MUST come from this exchange — don't
    hardcode it.
    """
    now = int(time.time())
    # Try cache first
    try:
        if COPILOT_TOKEN_CACHE.exists():
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
        log(_redact(f"copilot token exchange failed: {e}"))
        return None
    if proc.returncode != 0:
        log(_redact(f"copilot token exchange rc={proc.returncode}: {proc.stderr[:200]}"))
        return None
    try:
        data = json.loads(proc.stdout)
        session_token = data["token"]
        api_endpoint = data["endpoints"]["api"]
        expires_at = int(data.get("expires_at", now + 1500))
    except (json.JSONDecodeError, KeyError, ValueError) as e:
        log(_redact(f"copilot token exchange bad response: {e} body={proc.stdout[:200]}"))
        return None

    try:
        COPILOT_TOKEN_CACHE.parent.mkdir(parents=True, exist_ok=True)
        COPILOT_TOKEN_CACHE.write_text(json.dumps({
            "token": session_token,
            "api_endpoint": api_endpoint,
            "expires_at": expires_at,
        }))
        os.chmod(COPILOT_TOKEN_CACHE, 0o600)
    except OSError as e:
        log(f"failed to cache copilot session token: {e}")

    return session_token, api_endpoint


def _try_vision_llm(screenshot: Path) -> str | None:
    gh_token = _resolve_copilot_token()
    if not gh_token:
        log("no copilot token — skipping LLM")
        return None
    session = _exchange_copilot_session(gh_token)
    if not session:
        log("copilot session exchange failed — skipping LLM")
        return None
    session_token, api_endpoint = session
    chat_url = api_endpoint.rstrip("/") + "/chat/completions"

    try:
        from PIL import Image
        import base64, io
        img = Image.open(screenshot)
        # F-Vision-Quality (2026-04-24): user wants quality over cost — keep
        # higher resolution (was 1280, now 1920) and higher JPEG quality (90 vs 70)
        # so claude-opus-4.7 sees the actual UI text clearly. The 5 MB Copilot
        # image limit gives us plenty of headroom at this resolution.
        if img.width > 1920:
            ratio = 1920 / img.width
            img = img.resize((1920, int(img.height * ratio)), Image.LANCZOS)
        buf = io.BytesIO()
        img.convert("RGB").save(buf, format="JPEG", quality=90)
        b64 = base64.b64encode(buf.getvalue()).decode("ascii")
        log(f"image prepared: {len(b64)*3//4} bytes ({img.width}x{img.height})")
    except Exception as e:
        log(f"image prep failed: {e}")
        return None

    # F-Vision-Quality (2026-04-24): walk the model fallback chain. Try the
    # configured top model first (opus-4.7), then fall back to other vision
    # models if it's unavailable for the user's plan.
    chain = [COPILOT_MODEL] + [m for m in COPILOT_MODEL_FALLBACKS if m != COPILOT_MODEL]
    for model in chain:
        result = _call_vision_model(model, chat_url, session_token, b64)
        if result is not None:
            return result
    log("vision LLM: all models in chain failed")
    return None


def _call_vision_model(
    model: str,
    chat_url: str,
    session_token: str,
    b64: str,
) -> str | None:
    """Single vision model call. Returns the validated project string,
    None for any failure (caller will fall through to next model in chain).
    F-Vision-Quality (2026-04-24): split out so the chain logic is clean."""
    payload = {
        "model": model,
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": _VISION_PROMPT},
                    {
                        "type": "image_url",
                        "image_url": {"url": f"data:image/jpeg;base64,{b64}"},
                    },
                ],
            }
        ],
        # F-Vision-Quality: bumped from 80 → 200. Strict-JSON output is small
        # but Claude/GPT5 reasoning models sometimes emit a brief preamble
        # before the JSON if max_tokens is too tight, then we discard the
        # whole response. 200 tokens is still cheap.
        "max_tokens": 200,
        "temperature": 0.0,
    }
    try:
        proc = subprocess.run(
            [
                "curl", "-sS", "--max-time", "45",
                "-H", f"Authorization: Bearer {session_token}",
                "-H", "Content-Type: application/json",
                "-H", "Editor-Version: vscode/1.85.0",
                "-H", "Copilot-Integration-Id: vscode-chat",
                "-H", "Copilot-Vision-Request: true",
                "-d", json.dumps(payload),
                chat_url,
            ],
            capture_output=True, text=True, timeout=50,
        )
    except Exception as e:
        log(_redact(f"vision LLM ({model}) call failed: {e}"))
        return None
    if proc.returncode != 0:
        log(_redact(f"vision LLM ({model}) rc={proc.returncode}: {proc.stderr[:200]}"))
        return None
    try:
        data = json.loads(proc.stdout)
        # Detect model_not_supported / model_not_found early — fall through
        # to next model in chain.
        if "error" in data:
            err_code = data["error"].get("code", "")
            err_msg = data["error"].get("message", "")[:120]
            log(f"vision LLM ({model}) API error: {err_code} — {err_msg}")
            return None
        out = data["choices"][0]["message"]["content"].strip()
    except (json.JSONDecodeError, KeyError, IndexError) as e:
        log(_redact(f"vision LLM ({model}) bad response: {e} body={proc.stdout[:300]}"))
        return None
    if not out:
        return None

    # Parse strict JSON. Tolerate a markdown fence if the model added one.
    raw = out.strip()
    if raw.startswith("```"):
        raw = re.sub(r"^```(?:json)?\s*", "", raw)
        raw = re.sub(r"\s*```$", "", raw)
    try:
        parsed = json.loads(raw)
        project = str(parsed.get("project", "")).strip()
        signal = str(parsed.get("signal_source", "none")).strip()
        try:
            confidence = float(parsed.get("confidence", 0.0))
        except (TypeError, ValueError):
            confidence = 0.0
    except (json.JSONDecodeError, AttributeError):
        # Fall back: treat raw output as the project string (legacy contract)
        project, signal, confidence = raw, "unknown_format", 0.5

    log(f"vision LLM ({model}) raw response: project={project!r} signal={signal} conf={confidence:.2f}")

    if not project or project.upper() == "UNKNOWN":
        log(f"vision LLM ({model}) returned UNKNOWN — accepting as 'no project visible'")
        # Important: UNKNOWN is a legit answer when there really IS no project
        # in view (e.g. Outlook-only screenshot). Return empty sentinel so
        # caller knows we got a definitive answer, not a model failure.
        # However, we still try the next model first because opus is sometimes
        # too conservative; only return None to short-circuit chain on hard errors.
        return None
    if confidence < 0.5:
        log(f"vision LLM ({model}) confidence too low ({confidence:.2f}) — rejecting '{project}'")
        return None
    if signal in ("none", "body_content"):
        log(f"vision LLM ({model}) signal_source={signal!r} — rejecting '{project}'")
        return None
    project = re.sub(r"[^\w\s.\-]", "", project)
    project = " ".join(project.split()[:3]).strip()
    if not project or project in _STOP:
        return None
    return project


# --- Main ------------------------------------------------------------------

def _has_structural_signal(ocr_text: str) -> bool:
    """Negative gate: did OCR find ANY structural UI signal (cwd path, tab title
    with branch, terminal tab hint)? If not, the screenshot has no reliable
    project info and the LLM should NOT be invoked — historical evidence shows
    the LLM grabs random tokens from terminal stderr (e.g. 'fopenReadStream')
    when no structural signal exists, then self-reports high confidence."""
    if not ocr_text:
        return False
    if _CWD_RE.search(ocr_text):
        return True
    if _TAB_BRANCH_RE.search(ocr_text):
        return True
    if _TAB_HINT_RE.search(ocr_text):
        return True
    return False


# F-01 (QC cycle 1): strict shape for project names when no known folder set
# is available (fail-CLOSED, not fail-open). Matches typical folder names:
# starts with lowercase letter, allows lowercase alnum / dot / underscore /
# hyphen, length 2-31 chars total.
_STRICT_PROJECT_SHAPE = re.compile(r"^[a-z][a-z0-9._\-]{1,30}$")


def _validate_llm_project(
    project: str,
    known: set[str],
    source_score: int = 0,
) -> tuple[bool, str]:
    """Extrinsic validation of a project hint candidate (LLM OR regex source).
    Returns (accept, reason).

    Rules (in order):
      1. Empty                                  → reject
      2. In noise blocklist (_STOP_NOISE)       → reject
      3. CamelCase function-shape, NOT in known → reject (LLM hallucination)
      4. known set is empty (fail-closed)       → require strict folder shape
      5. source_score >= 10 (gold CWD match)    → accept if strict shape ok
         even when not in known set (legit new folder created after scan)
      6. known set non-empty                    → require exact match (case-insensitive)
      7. Otherwise                              → accept

    The LLM's self-reported 'confidence' is unreliable (observed: 0.95 for
    'fopenReadStream' — a leptonica error token). This is the ONLY trust
    layer. Applied to BOTH regex and LLM sources (F-04, QC cycle 1).

    Rule 5 (added cycle-2 / F2-05): allow gold-standard `_CWD_RE` matches
    (weight=10, explicit claude_projects path) through even when the project
    folder hasn't been scanned yet (e.g. newly created project). Avoids
    strict known-folder matching silently discarding legit new projects.

    Rule 6 (added after sweep #1): prevents suffix-pollution like
    'Migros_CCC_to_2.3.7.11_upgrade-1.4.10' (real folder exists without the
    '-1.4.10' pip-version tail bleeding in from another screenshot region).
    """
    if not project:
        return False, "empty"
    if project in _STOP_NOISE:
        return False, f"matches noise blocklist ({project!r})"
    # CamelCase function-name-shaped identifier that ISN'T a real folder → reject
    if _looks_like_camelcase_identifier(project) and project not in known:
        return False, f"camelcase identifier not in known projects ({project!r})"
    if not known:
        # F-01: when known set is empty (no claude_projects dir, fresh install,
        # IO error during scan), do NOT silently accept arbitrary strings.
        # Require strict folder-name shape.
        if not _STRICT_PROJECT_SHAPE.match(project):
            return False, f"strict shape rejected (no known folders to compare): {project!r}"
        return True, "ok (strict-shape, no known folders)"
    # F2-05 (revised 2026-04-24): gold-standard CWD match — accept ONLY if the
    # project also exists as a real folder on disk. The previous "accept if
    # strict shape, even when not in known set" rule was a hole: OCR truncation
    # of `whisper` to `whi` (regex `[\w.\-]+` matches greedily on whatever
    # chars OCR produced) passes strict shape and isn't in known set, so it
    # got accepted with score=10. Filesystem check is the only reliable gate
    # against truncation/garbage that happens to look folder-shaped.
    if source_score >= 10 and _STRICT_PROJECT_SHAPE.match(project):
        if project not in known:
            try:
                from pathlib import Path as _P
                fs_path = _P.home() / "Documents" / "claude_projects" / project
                if fs_path.is_dir():
                    return True, f"ok (gold CWD match, fs-verified new folder; score={source_score})"
            except OSError:
                pass
            return False, (
                f"gold CWD match {project!r} but folder doesn't exist on disk "
                f"(likely OCR truncation); score={source_score}"
            )
    # Known non-empty: require exact or case-insensitive match against a real folder.
    if project in known:
        return True, "ok (exact match)"
    lower_known = {n.lower() for n in known}
    if project.lower() in lower_known:
        return True, "ok (case-insensitive match)"
    return False, f"not in known folders ({project!r}); closest={_closest_known(project, known)}"


def _closest_known(project: str, known: set[str]) -> str:
    """Best-effort closest-match for log messages. No fuzzy accept — diagnostic only."""
    if not known:
        return "<none>"
    pl = project.lower()
    prefix_hits = [n for n in known if n.lower().startswith(pl[:6])]
    if prefix_hits:
        return sorted(prefix_hits, key=len)[0]
    return sorted(known, key=len)[0]


# C1 (NEW this turn): session-continuity fallback. When the current screenshot
# has no structural signal, infer the project from the most recent prior record
# (within SESSION_GAP_S) that DOES have a hint. Rationale: the user works
# inside one project context for a coherent session; if they screenshot the
# browser or a non-terminal app, the project is still the same one they were
# just in. Conservative: only inherits within a short window.
SESSION_GAP_S = 600  # 10 minutes


def _session_continuity_hint(basename: str) -> str | None:
    """Look up the immediately-prior record and inherit its project_hint
    if the gap is < SESSION_GAP_S. Returns None if no eligible predecessor.

    Epoch resolution (defensive against DST + clock-skew from hibernation):
      - Prefer the record's stored `t0_epoch` (UTC seconds since epoch,
        wallclock at creation time). This is the ground truth.
      - Fall back to basename parsing via `time.mktime(time.strptime(…))`
        (treats the 14-digit stamp as local time) ONLY when stored epoch
        is absent. Parsing-derived epochs are flagged and given a
        slightly wider tolerance (2× DST drift buffer).
    """
    try:
        from transcription_log import RECORDS_PATH  # type: ignore
        if not RECORDS_PATH.exists():
            return None
        records = json.loads(RECORDS_PATH.read_text())
    except (OSError, json.JSONDecodeError, ImportError):
        return None
    if not isinstance(records, dict):
        return None

    def _resolve_epoch(key: str, rec: dict) -> tuple[float | None, bool]:
        """Return (epoch_seconds, is_parsed_fallback). None if unresolvable."""
        stored = rec.get("t0_epoch")
        if isinstance(stored, (int, float)) and stored > 0:
            return float(stored), False
        mk = re.match(r"^(\d{14})\.wav$", key)
        if not mk:
            return None, False
        try:
            return time.mktime(time.strptime(mk.group(1), "%Y%m%d%H%M%S")), True
        except (ValueError, OverflowError):
            return None, False

    # Resolve THIS record's epoch — prefer stored, fall back to basename
    this_rec = records.get(basename) if isinstance(records.get(basename), dict) else {}
    this_epoch, _ = _resolve_epoch(basename, this_rec)
    if this_epoch is None:
        return None

    best_hint = None
    best_dt = SESSION_GAP_S + 1
    for k, rec in records.items():
        if k == basename:
            continue
        if not isinstance(rec, dict):
            continue
        hint = (rec.get("project_hint") or "").strip()
        if not hint:
            continue
        prev_epoch, prev_parsed = _resolve_epoch(k, rec)
        if prev_epoch is None:
            continue
        dt = this_epoch - prev_epoch
        # DST + clock-skew tolerance: allow small negative dt (up to 2 min)
        # only when both epochs are from stored t0_epoch (trusted UTC).
        # For parsed-fallback epochs, require dt >= 0 (no backward jumps).
        min_dt = -120 if not prev_parsed else 0
        if min_dt <= dt < best_dt:
            best_dt = max(dt, 0)  # collapse minor negative to 0 for ranking
            best_hint = hint
    return best_hint


def _redact(s: str) -> str:
    """Redact bearer tokens, copilot tokens, and JSON token fields from log
    strings (F-16, QC cycle 1). Used before writing curl bodies / responses
    to extract_project.log."""
    if not s:
        return s
    # JSON: "token": "ghu_..." or "access_token": "..."
    s = re.sub(r'("(?:access_|copilot_|session_)?token"\s*:\s*")[^"]+(")', r'\1<redacted>\2', s)
    # Bearer in headers / errors
    s = re.sub(r'(Bearer\s+)[A-Za-z0-9_\-\.]+', r'\1<redacted>', s)
    # GitHub Copilot user-token prefix
    s = re.sub(r'\bghu_[A-Za-z0-9]+', '<redacted-ghu>', s)
    return s


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: extract_project_from_screenshot.py <screenshot> <wav_basename>", file=sys.stderr)
        return 0  # never block pipeline

    screenshot = Path(sys.argv[1])
    basename = sys.argv[2]

    if not screenshot.exists():
        log(f"screenshot missing: {screenshot}")
        return 0

    # F-Recognition-Overhaul (2026-04-24): vision-first cascade replaces the
    # old regex-OCR → LLM → session_continuity flow. Verified at 95.3% accuracy
    # across 64 historical records via bin/label_audit.py + manual review.
    # Old method retained behind WHISPER_LEGACY_EXTRACTOR=1 for rollback.
    if os.environ.get("WHISPER_LEGACY_EXTRACTOR") == "1":
        return _legacy_main(screenshot, basename)

    project = None
    method = None
    confidence = 0.0
    try:
        # Import lazily so this file still works as standalone script.
        sys.path.insert(0, str(Path(__file__).parent))
        import label_audit  # noqa: WPS433

        # Build a synthetic record dict matching what label_audit expects.
        # Pull current transcript snippet if records.json already has it
        # (extractor runs ~1.5s after capture; transcripts may not be ready).
        try:
            from transcription_log import RECORDS_PATH  # type: ignore
            records = json.loads(RECORDS_PATH.read_text())
            record = records.get(basename, {})
        except Exception:
            record = {}
        record["screenshot_path"] = str(screenshot)

        known = label_audit.load_known_projects()
        if not known:
            log("vision-first: no known projects under ~/Documents/claude_projects/")
            return 0

        chat_url = label_audit._get_copilot_chat_url()
        if not chat_url:
            log("vision-first: cannot get Copilot chat URL — falling through")
            return 0

        result = label_audit.label_record(basename, record, known, chat_url)
        project = result.get("derived_project")
        confidence = float(result.get("confidence") or 0.0)
        source = result.get("source", "unknown")
        if project:
            method = source
            log(f"vision-first extracted '{project}' from {screenshot.name} "
                f"[source={source} conf={confidence:.2f}]")
        else:
            log(f"vision-first uncertain for {screenshot.name}: {result.get('reasoning','')}")
    except Exception as e:
        log(f"vision-first cascade failed: {e!r} — leaving project_hint empty")
        return 0

    if not project:
        log(f"no project extracted from {screenshot.name} (basename={basename})")
        return 0

    try:
        from transcription_log import update_project_hint
        ok = update_project_hint(basename, project)
        log(f"update_project_hint({basename}, {project!r}) = {ok} via {method}")
    except Exception as e:
        log(f"failed to write project_hint: {e}")
    return 0


def _legacy_main(screenshot: Path, basename: str) -> int:
    """Pre-2026-04-24 extraction flow: regex-OCR → vision-LLM → session_continuity.
    Kept for rollback via WHISPER_LEGACY_EXTRACTOR=1."""
    project = None
    method = None
    ocr_text = ""

    # 1. Regex on OCR
    try:
        ocr_text = _ocr_top_band(screenshot)
        if ocr_text:
            result = _try_regex(ocr_text)
            if result is not None:
                candidate, score = result
                known = _known_projects()
                accept, reason = _validate_llm_project(candidate, known, source_score=score)
                if accept:
                    project = candidate
                    method = f"regex(score={score})"
                    log(f"regex extracted '{project}' from {screenshot.name} [{reason}]")
                else:
                    log(f"regex result rejected: {reason} (candidate={candidate!r}, score={score})")
    except Exception as e:
        log(f"regex stage exception: {e}")

    # 2. Vision LLM fallback — F-Vision-Always (2026-04-24): user requested
    # full-quality LLM analysis on EVERY image. Old logic gated this behind
    # `_has_structural_signal(ocr_text)` to avoid LLM hallucinations on noise-
    # only screenshots. With claude-opus-4.7 (vs old gpt-4o-mini) and the
    # tightened _validate_llm_project rules below, the LLM is reliable enough
    # to run unconditionally — and tesseract OCR was producing false negatives
    # (missing actually-visible cwd paths because of font rendering on macOS),
    # which silently disabled the vision pass for valid screenshots.
    # Trade-off accepted: occasional bad LLM hint vs. systematically missing
    # the project on screenshots tesseract couldn't read.
    if not project:
        try:
            candidate = _try_vision_llm(screenshot)
            if candidate:
                known = _known_projects()
                accept, reason = _validate_llm_project(candidate, known)
                if accept:
                    project = candidate
                    method = "llm"
                    log(f"LLM extracted '{project}' from {screenshot.name}")
                else:
                    log(f"LLM result rejected: {reason}")
        except Exception as e:
            log(f"LLM stage exception: {e}")

    # 3. Session-continuity fallback — inherit project_hint from a recent
    # prior recording within SESSION_GAP_S. Handles the case where the user
    # screenshots a non-terminal app (browser, slack) but is still working
    # on the same project they were just in.
    if not project:
        try:
            inherited = _session_continuity_hint(basename)
            if inherited:
                # Already validated when written; re-validate defensively.
                known = _known_projects()
                accept, reason = _validate_llm_project(inherited, known)
                if accept:
                    project = inherited
                    method = "session_continuity"
                    log(f"session_continuity inherited '{project}' for {basename}")
                else:
                    log(f"session_continuity rejected '{inherited}': {reason}")
        except Exception as e:
            log(f"session_continuity exception: {e}")

    if not project:
        log(f"no project extracted from {screenshot.name} (basename={basename})")
        return 0

    # Write into record
    try:
        from transcription_log import update_project_hint
        ok = update_project_hint(basename, project)
        log(f"update_project_hint({basename}, {project!r}) = {ok} via {method}")
    except Exception as e:
        log(f"failed to write project_hint: {e}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
