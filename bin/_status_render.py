"""Render ~/.whisper_log/status.json (cheap, called on every record change)."""

from __future__ import annotations

import json
import os
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

# Import STAGES so the cell counter stays in sync with the canonical list
sys.path.insert(0, str(Path(__file__).resolve().parent))
from transcription_log import STAGES  # noqa: E402


def render_status(path: Path, records_sorted: list[dict[str, Any]]) -> None:
    pending = sum(
        1
        for rec in records_sorted
        for st in rec["stages"].values()
        if st.get("status") == "pending"
    )
    running = sum(
        1
        for rec in records_sorted
        for st in rec["stages"].values()
        if st.get("status") == "running"
    )
    total_cells = len(records_sorted) * len(STAGES) if records_sorted else 0
    done_cells = total_cells - pending - running

    payload = {
        "pending_count": pending,
        "running_count": running,
        "done_count": done_cells,
        "total_records": len(records_sorted),
        "last_updated": time.time(),
        "last_updated_human": time.strftime("%Y-%m-%d %H:%M:%S"),
    }

    fd, tmp = tempfile.mkstemp(prefix=path.name + ".", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(payload, f, indent=2)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
