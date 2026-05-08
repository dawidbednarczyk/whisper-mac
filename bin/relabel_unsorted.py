#!/usr/bin/env python3
"""Re-run vision-first labeling on records with empty `project_hint`.

Targets only records where `project_hint` is "" or "(unsorted)". Dry-run by
default — pass --apply to write changes (with automatic timestamped backup).

Usage:
    python3 bin/relabel_unsorted.py             # dry-run, prints proposed labels
    python3 bin/relabel_unsorted.py --apply     # backup + write
    python3 bin/relabel_unsorted.py --basename 20260430102551.wav  # single record

See: rpi/master-project-override/plan.md
"""
from __future__ import annotations

import argparse
import json
import shutil
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import label_audit  # noqa: E402
from transcription_log import RECORDS_PATH, update_project_hint  # noqa: E402


def find_unsorted(records: dict, target_basename: str | None = None) -> list[str]:
    if target_basename:
        return [target_basename] if target_basename in records else []
    return [
        k for k, r in records.items()
        if not (r.get("project_hint") or "").strip()
        or r.get("project_hint") == "(unsorted)"
    ]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true", help="Write changes (default: dry-run).")
    ap.add_argument("--basename", help="Re-label a single record by basename.")
    args = ap.parse_args()

    records = json.loads(RECORDS_PATH.read_text())
    targets = find_unsorted(records, args.basename)
    if not targets:
        print("No unsorted records found.")
        return 0

    known = label_audit.load_known_projects()
    if not known:
        print("ERROR: load_known_projects() returned empty list.", file=sys.stderr)
        return 1
    chat_url = label_audit._get_copilot_chat_url()
    if not chat_url:
        print("ERROR: cannot get Copilot chat URL (auth missing/expired).", file=sys.stderr)
        return 1

    print(f"Found {len(targets)} unsorted record(s). Vocabulary size: {len(known)} (incl. 'master').")
    print(f"Mode: {'APPLY' if args.apply else 'DRY-RUN'}\n")

    proposals: list[tuple[str, str | None, float, str]] = []
    for basename in targets:
        record = records[basename]
        result = label_audit.label_record(basename, record, known, chat_url)
        proj = result.get("derived_project")
        conf = float(result.get("confidence") or 0.0)
        source = result.get("source", "?")
        reasoning = (result.get("reasoning") or "")[:120]
        proposals.append((basename, proj, conf, source))
        marker = "→" if proj else "✗"
        print(f"  {marker} {basename}  hint={proj!r:40} conf={conf:.2f} src={source}")
        print(f"      reasoning: {reasoning}")

    if not args.apply:
        print("\nDry-run only. Re-run with --apply to write changes.")
        return 0

    # Backup before write.
    ts = time.strftime("%Y%m%d-%H%M%S")
    backup = RECORDS_PATH.with_suffix(f".json.bak.master-override-{ts}")
    shutil.copy2(RECORDS_PATH, backup)
    print(f"\nBackup: {backup}")

    written = 0
    for basename, proj, conf, source in proposals:
        if not proj:
            print(f"  - {basename}: skipped (no derived project)")
            continue
        ok = update_project_hint(basename, proj)
        status = "✓" if ok else "✗"
        print(f"  {status} {basename}: hint={proj!r}  via={source}")
        if ok:
            written += 1
    print(f"\nWrote {written}/{len(proposals)} project hints.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
