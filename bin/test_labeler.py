#!/usr/bin/env python3
"""test_labeler.py — Regression test for vision-first project labeler.

Pins 4 representative records that exercise different signal paths:
  1. high-confidence cwd_statusline       → 'whisper'
  2. medium-confidence cwd_statusline     → 'opencode-config'
  3. transcript fallback (no good vision) → 'opencode-config'
  4. non-whisper project (cross-folder)   → 'NN_Checkpoint_FW_Analysis'

Pinned 2026-04-24 against `bin/label_audit.label_record()` after the
project-recognition-overhaul. Re-run after any extractor or prompt change.
Fails non-zero on any regression.

(The original 5th pin — an "uncertain" record — was deleted from records.json
on 2026-04-24 17:19 along with the other 2 broken-transcription records the
user wanted purged. Uncertain handling is still exercised at runtime; if a
new uncertain record appears, add it back as PIN #5.)

Usage:
    python3 bin/test_labeler.py            # run all 4
    python3 bin/test_labeler.py --quick    # vision pins only (skip transcript)

Exit codes:
    0 = all pass
    1 = at least one regression
    2 = harness/setup error (no records, no Copilot auth, etc.)
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "bin"))

import label_audit  # noqa: E402

PINS = [
    ("20260423153722.wav", "whisper",                 "vision",     0.85),
    ("20260423205729.wav", "opencode-config",         "vision",     0.60),
    ("20260423210017.wav", "opencode-config",         "transcript", 0.80),
    ("20260423154845.wav", "NN_Checkpoint_FW_Analysis","vision",     0.85),
]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--quick", action="store_true", help="skip transcript + uncertain pins")
    args = ap.parse_args()

    records_path = Path.home() / ".whisper_log" / "records.json"
    if not records_path.exists():
        print(f"FAIL setup: records.json missing at {records_path}", file=sys.stderr)
        return 2
    records = json.loads(records_path.read_text())

    known = label_audit.load_known_projects()
    if not known:
        print("FAIL setup: no known projects under ~/Documents/claude_projects/", file=sys.stderr)
        return 2

    chat_url = label_audit._get_copilot_chat_url()
    if not chat_url:
        print("FAIL setup: cannot get Copilot chat URL (auth?)", file=sys.stderr)
        return 2

    pins = PINS
    if args.quick:
        pins = [p for p in PINS if p[2] == "vision" and p[1]]

    fails = []
    t_start = time.time()
    for basename, expected_proj, expected_src, min_conf in pins:
        if basename not in records:
            print(f"SKIP {basename}: not in records.json")
            continue
        record = records[basename]
        result = label_audit.label_record(basename, record, known, chat_url)
        got_proj = result.get("derived_project")
        got_src = result.get("source", "")
        got_conf = float(result.get("confidence") or 0)

        # Tolerant assertions: project must match exactly; source family must
        # contain the expected token (vision/transcript/uncertain); confidence
        # must meet floor.
        ok = True
        reasons = []
        if got_proj != expected_proj:
            ok = False
            reasons.append(f"project: expected {expected_proj!r} got {got_proj!r}")
        if expected_src not in got_src:
            ok = False
            reasons.append(f"source: expected substr {expected_src!r} got {got_src!r}")
        if expected_proj and got_conf < min_conf:
            ok = False
            reasons.append(f"confidence: expected >={min_conf} got {got_conf:.2f}")

        status = "PASS" if ok else "FAIL"
        print(f"{status} {basename}: derived={got_proj!r} src={got_src!r} conf={got_conf:.2f}")
        if not ok:
            for r in reasons:
                print(f"    {r}")
            fails.append(basename)

    elapsed = time.time() - t_start
    print(f"\n--- {len(pins) - len(fails)}/{len(pins)} pass in {elapsed:.1f}s ---")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
