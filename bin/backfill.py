"""
backfill.py
===========

Scan ``$WHISPER_HOME/upstream/Careless-Whisper/recordings/*.wav``, sort
newest-first by mtime, take the top N, and enqueue all 6 transcription
stages for each WAV that isn't already in the log.

``WHISPER_HOME`` is resolved in this order:

1. ``$WHISPER_HOME`` environment variable (explicit override)
2. The repo root inferred from this file's location
   (``Path(__file__).resolve().parent.parent``)
3. ``~/whisper-mac`` (default install location)

Usage:
    python3 bin/backfill.py            # default: 20 newest
    python3 bin/backfill.py 50         # 50 newest
    python3 bin/backfill.py --all      # everything

    # Maintenance flag — strip legacy ``[copilot empty response]`` /
    # ``[no copilot token]`` suffixes that earlier worker versions appended
    # to stage text. Migrates them into the structured ``degraded_note`` field.
    python3 bin/backfill.py --strip-degraded-suffix

Idempotent: re-running skips WAVs already in records.json.
"""

from __future__ import annotations

import json
import os
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from transcription_log import (  # noqa: E402
    add_quick_record, get_record, _refresh_status_and_html,
    RECORDS_PATH, _RecordsLock, _load_records, _atomic_write_json,
)


def _resolve_whisper_home() -> Path:
    """Resolve the whisper-mac install root.

    Order: ``$WHISPER_HOME`` env var → repo root inferred from this file →
    ``~/whisper-mac`` default.
    """
    env = os.environ.get("WHISPER_HOME", "").strip()
    if env:
        return Path(os.path.expanduser(env))
    repo_root = Path(__file__).resolve().parent.parent
    if (repo_root / "upstream" / "Careless-Whisper").is_dir():
        return repo_root
    return Path.home() / "whisper-mac"


WHISPER_HOME = _resolve_whisper_home()
DEFAULT_RECORDINGS_DIR = WHISPER_HOME / "upstream" / "Careless-Whisper" / "recordings"


# Legacy suffix patterns that the OLD worker appended to stage text.
# Now superseded by the structured ``degraded_note`` field, but existing
# records may still carry the in-text version.
_LEGACY_SUFFIX_RE = re.compile(
    r"\n*\[(no copilot token|copilot empty response|copilot bad response|"
    r"copilot exec failed[^\]]*|curl rc=\d+)\]\s*$"
)


def _strip_degraded_suffix() -> int:
    """Walk records.json, strip legacy ``[note]`` suffixes from stage text,
    and move the note into the structured ``degraded_note`` field. Returns
    count of stages migrated."""
    migrated = 0
    with _RecordsLock():
        records = _load_records()
        for basename, rec in records.items():
            for sid, stage in rec.get("stages", {}).items():
                text = stage.get("text") or ""
                if not text:
                    continue
                m = _LEGACY_SUFFIX_RE.search(text)
                if not m:
                    continue
                note = m.group(1)
                stripped = _LEGACY_SUFFIX_RE.sub("", text).rstrip()
                stage["text"] = stripped
                # Only set degraded_note if not already present (don't clobber)
                if not stage.get("degraded_note"):
                    stage["degraded_note"] = note
                migrated += 1
        _atomic_write_json(RECORDS_PATH, records)
    return migrated


def main() -> int:
    args = sys.argv[1:]

    if "--strip-degraded-suffix" in args:
        n = _strip_degraded_suffix()
        _refresh_status_and_html()
        print(f"Stripped legacy degraded suffixes from {n} stage(s).")
        print(f"Open: file://{Path.home()}/.whisper_log/transcriptions.html")
        return 0

    take_all = "--all" in args
    args = [a for a in args if a != "--all"]

    if take_all:
        n = None
    elif args:
        try:
            n = int(args[0])
        except ValueError:
            print(f"usage: {sys.argv[0]} [N | --all | --strip-degraded-suffix]", file=sys.stderr)
            return 2
    else:
        n = 20

    rec_dir = DEFAULT_RECORDINGS_DIR
    if not rec_dir.exists():
        print(f"recordings directory not found: {rec_dir}", file=sys.stderr)
        print(f"  (resolved WHISPER_HOME={WHISPER_HOME})", file=sys.stderr)
        print(f"  set $WHISPER_HOME to override, or run from the repo root.", file=sys.stderr)
        return 1

    wavs = sorted(rec_dir.glob("*.wav"), key=lambda p: p.stat().st_mtime, reverse=True)
    if n is not None:
        wavs = wavs[:n]
    print(f"Considering {len(wavs)} WAV file(s).")

    added = 0
    skipped = 0
    for wav in wavs:
        if get_record(wav.name) is not None:
            skipped += 1
            continue
        # For backfill, t0 = WAV mtime (recording time). Quick text empty.
        add_quick_record(
            t0_epoch=wav.stat().st_mtime,
            wav_path=str(wav),
            quick_model_id="",
            quick_text="",
            quick_duration_ms=0,
        )
        added += 1
        if added % 10 == 0:
            print(f"  enqueued {added}…")

    _refresh_status_and_html()
    print(f"Done. added={added} skipped={skipped} (already in log)")
    print()
    print(f"Open: file://{Path.home()}/.whisper_log/transcriptions.html")
    print("Worker will process in the background. Page auto-refreshes every 5 s.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
