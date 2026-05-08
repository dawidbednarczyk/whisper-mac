"""Render ~/.whisper_log/transcriptions.html — newest first, grouped by project, auto-refresh."""

from __future__ import annotations

import hashlib
import html
import json
import os
import re
import tempfile
import time
from collections import OrderedDict
from pathlib import Path
from typing import Any

UNSORTED_LABEL = "Unsorted"
MAX_PILLS = 4


CSS = """
:root {
  color-scheme: dark;
  --bg: #0c0e12;
  --panel: #131720;
  --panel-2: #181d28;
  --border: #232a38;
  --text: #e6e9ef;
  --muted: #8b94a7;
  --accent: #4aa0ff;
  --accent-2: #5eead4;
  --pending: #f5b461;
  --running: #d199ff;
  --done: #5eead4;
  --error: #ff7a90;
  --quick: #7dd3fc;
}
* { box-sizing: border-box; }
body {
  margin: 0; padding: 24px;
  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
  background: var(--bg); color: var(--text); font-size: 14px; line-height: 1.45;
}
header {
  display: flex; justify-content: space-between; align-items: center;
  margin-bottom: 20px; padding-bottom: 16px; border-bottom: 1px solid var(--border);
}
h1 { margin: 0; font-size: 20px; font-weight: 600; }
.muted { color: var(--muted); font-size: 12px; }
.summary { display: flex; gap: 14px; align-items: center; }
.pill {
  padding: 4px 10px; border-radius: 999px; font-size: 11px; font-weight: 600;
  background: var(--panel-2); border: 1px solid var(--border);
}
.pill.pending { color: var(--pending); border-color: rgba(245,180,97,0.3); }
.pill.done    { color: var(--done);    border-color: rgba(94,234,212,0.3); }
.pill.running { color: var(--running); border-color: rgba(209,153,255,0.3); }

.record {
  background: var(--panel); border: 1px solid var(--border); border-radius: 12px;
  padding: 16px; margin-bottom: 14px;
}
.record-header {
  display: flex; justify-content: space-between; align-items: baseline; gap: 16px;
  margin-bottom: 12px; flex-wrap: wrap;
}
.record-title { font-weight: 600; font-size: 15px; }
.record-meta  { color: var(--muted); font-size: 11.5px; font-family: ui-monospace, monospace; }
.wav-path {
  display: inline-block; padding: 3px 8px; border-radius: 6px;
  background: var(--panel-2); color: var(--muted); font-family: ui-monospace, monospace;
  font-size: 11px; word-break: break-all; margin-top: 4px;
}
.wav-path a { color: var(--accent); text-decoration: none; }
.wav-path a:hover { text-decoration: underline; }

.stages {
  display: grid; grid-template-columns: repeat(2, 1fr); gap: 10px;
}
@media (min-width: 1100px) {
  .stages { grid-template-columns: repeat(3, 1fr); }
}
.stage {
  background: var(--panel-2); border: 1px solid var(--border); border-radius: 8px;
  padding: 10px 12px; display: flex; flex-direction: column; gap: 8px;
  min-height: 120px;
}
.stage-head {
  display: flex; justify-content: space-between; align-items: center; gap: 8px;
}
.stage-label { font-weight: 600; font-size: 12px; color: var(--text); }
.stage-meta  { font-size: 10.5px; color: var(--muted); font-family: ui-monospace, monospace; }
/* F-S1-01: secondary timing line (started: HH:MM:SS) under main meta */
.stage-meta-wrap { text-align: right; }
.stage-meta-sub  { font-size: 10px; color: var(--muted); opacity: 0.7; font-family: ui-monospace, monospace; margin-top: 2px; }
.stage-text {
  font-size: 13px; line-height: 1.5; color: var(--text);
  white-space: pre-wrap; word-break: break-word; flex: 1;
  background: var(--bg); border: 1px solid var(--border); border-radius: 6px;
  padding: 8px 10px; max-height: 180px; overflow-y: auto;
}
.stage-text.pending, .stage-text.running { color: var(--muted); font-style: italic; }
.stage-text.error { color: var(--error); }
.degraded-badge {
  display: inline-block; margin-left: 6px; padding: 1px 6px;
  background: #fff3cd; color: #856404; border: 1px solid #ffe69c;
  border-radius: 4px; font-size: 11px; font-weight: 500;
}
/* Plan 6 (2026-04-23): softer info-style badge for the case where Copilot
   failed but dictionary correction succeeded — the long pane still has
   useful improved text, so we don't want to alarm the user. */
.degraded-badge.info {
  background: #e7f3ff; color: #0a4d8c; border-color: #b6dcff;
}
.record-summary {
  font-size: 12px; color: var(--muted); margin-top: 4px;
  font-variant-numeric: tabular-nums;
}
/* Plan 5 H1 (2026-04-23): expand-toggle for long stage text (>2000 chars). */
.long-cell { margin: 0; }
.long-cell summary {
  cursor: pointer; font-weight: 500; color: var(--accent);
  padding: 2px 0; user-select: none; list-style: none;
}
.long-cell summary::-webkit-details-marker { display: none; }
.long-cell[open] summary { margin-bottom: 6px; border-bottom: 1px solid var(--border); padding-bottom: 4px; }
.long-cell pre {
  margin: 0; white-space: pre-wrap; word-break: break-word;
  font-family: inherit; font-size: inherit; line-height: inherit;
}
.stage-actions { display: flex; gap: 6px; align-items: center; justify-content: flex-end; }
.copy-btn {
  background: var(--panel); color: var(--accent); border: 1px solid var(--border);
  padding: 4px 10px; border-radius: 6px; font-size: 11px; cursor: pointer;
  font-weight: 600; transition: all 0.15s;
}
.copy-btn:hover:not(:disabled) { background: var(--accent); color: var(--bg); border-color: var(--accent); }
.copy-btn:disabled { opacity: 0.35; cursor: not-allowed; }
.copy-btn.copied { background: var(--done); color: var(--bg); border-color: var(--done); }

.status-dot {
  display: inline-block; width: 7px; height: 7px; border-radius: 50%;
  margin-right: 4px; vertical-align: middle;
}
.status-dot.pending { background: var(--pending); }
.status-dot.running { background: var(--running); animation: pulse 1.2s infinite; }
.status-dot.done    { background: var(--done); }
.status-dot.error   { background: var(--error); }
/* Fixed 2026-04-24 (F-S1-04): status-dot colour modifier for degraded records.
   info  = text is still useful (dict-corrected even though Copilot failed)  → blue
   warn  = no useful improvement happened (auth fail, self-ref, content fail) → amber
   These override the .done class on degraded successful runs. */
.status-dot.degraded-info { background: var(--accent); }
.status-dot.degraded-warn { background: var(--pending); animation: pulse 2s infinite; }
.quick-tag { color: var(--quick); font-size: 10px; font-weight: 600; margin-left: 4px; }

@keyframes pulse { 0%,100% { opacity: 1; } 50% { opacity: 0.35; } }

/* ── Project groups ──────────────────────────────────────────────────── */
.project-group {
  --project-accent: var(--muted);
  position: relative;
  margin: 14px 0 22px;
  border: 1px solid var(--border);
  border-radius: 12px;
  background: var(--panel);
  overflow: hidden;
}
.project-group::before {
  /* 4px colored left rail, full height */
  content: "";
  position: absolute;
  left: 0; top: 0; bottom: 0;
  width: 4px;
  background: var(--project-accent);
  opacity: 0.9;
}
.project-group > summary {
  list-style: none;
  cursor: pointer;
  display: grid;
  grid-template-columns: 14px minmax(0, 1fr) auto auto;
  align-items: center;
  column-gap: 14px;
  padding: 14px 18px 14px 22px;
  background: var(--panel-2);
  border-bottom: 1px solid transparent;
  user-select: none;
  transition: background 0.15s, border-color 0.15s;
}
.project-group[open] > summary { border-bottom-color: var(--border); }
.project-group > summary::-webkit-details-marker { display: none; }
.pg-disclosure {
  display: inline-block;
  font-size: 10px;
  color: var(--project-accent);
  transition: transform 0.18s ease;
  width: 12px;
  text-align: center;
  opacity: 0.85;
}
.project-group[open] > summary .pg-disclosure { transform: rotate(90deg); }
.project-group > summary:hover { background: var(--panel); }
.pg-titlewrap { min-width: 0; }
.pg-title {
  margin: 0; font-size: 1.25rem; font-weight: 600;
  color: var(--text); letter-spacing: -0.1px;
  line-height: 1.2;
  overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
}
.project-group[data-fallback] .pg-title { color: var(--muted); font-weight: 500; }
.pg-count {
  color: var(--muted); font-weight: 500; font-size: 0.95em;
  margin-left: 6px; font-variant-numeric: tabular-nums;
}
.pg-meta {
  margin-top: 3px;
  font-size: 11.5px; color: var(--muted);
  font-variant-numeric: tabular-nums;
}
.pg-apps {
  display: flex; gap: 6px; flex-wrap: wrap;
  justify-content: flex-end;
  max-width: 360px;
}
.pg-app-pill {
  display: inline-flex; align-items: center;
  font-size: 10.5px; font-weight: 600;
  color: var(--text);
  background: rgba(255,255,255,0.04);
  border: 1px solid var(--border);
  border-color: color-mix(in srgb, var(--project-accent) 25%, var(--border));
  padding: 2px 8px; border-radius: 999px;
  letter-spacing: 0.1px;
  white-space: nowrap;
}
.pg-app-pill--more {
  color: var(--muted);
  background: var(--bg);
  border-color: var(--border);
}
.project-group[data-fallback] .pg-app-pill {
  border-color: var(--border);
}
.pg-actions {
  display: flex; gap: 6px;
  opacity: 0;
  transform: translateX(4px);
  transition: opacity 0.15s ease, transform 0.15s ease;
  pointer-events: none;
}
.project-group > summary:hover .pg-actions,
.project-group:focus-within > summary .pg-actions {
  opacity: 1;
  transform: translateX(0);
  pointer-events: auto;
}
.pg-action-btn {
  background: transparent;
  color: var(--muted);
  border: 1px solid var(--border);
  padding: 3px 9px;
  border-radius: 6px;
  font-size: 10.5px;
  font-weight: 600;
  cursor: pointer;
  transition: all 0.12s;
  letter-spacing: 0.2px;
}
.pg-action-btn:hover {
  color: var(--text);
  border-color: color-mix(in srgb, var(--project-accent) 50%, var(--border));
  background: color-mix(in srgb, var(--project-accent) 10%, transparent);
}
.pg-action-btn.active {
  color: var(--project-accent);
  border-color: var(--project-accent);
}

/* Body */
.pg-body { padding: 4px 0; }
.project-group .record { margin: 12px 18px; }
.project-group .record:first-child { margin-top: 16px; }
.project-group .record:last-child { margin-bottom: 16px; }

/* Sub-groups inside Unsorted */
.pg-subgroup {
  margin: 10px 18px 4px;
  padding-top: 6px;
  border-top: 1px dashed var(--border);
}
.pg-subgroup:first-child { border-top: none; padding-top: 0; }
.pg-subhead {
  display: flex; align-items: center; gap: 10px;
  font-size: 11px; font-weight: 600; letter-spacing: 0.6px;
  color: var(--muted); text-transform: uppercase;
  padding: 6px 0 4px;
}
.pg-subhead .pg-app-pill { text-transform: none; letter-spacing: 0.1px; }
.pg-subhead .pg-subcount { color: var(--muted); font-weight: 500; opacity: 0.8; }
.pg-subgroup .record { margin: 10px 0; }

/* Per-record app tag (small, right of timestamp) */
.record-app-tag {
  display: inline-block;
  margin-left: 8px;
  font-size: 10.5px; font-weight: 500;
  color: var(--muted);
  background: rgba(255,255,255,0.03);
  border: 1px solid var(--border);
  padding: 1px 7px; border-radius: 999px;
  vertical-align: middle;
}

/* Filtered state: single project visible */
body.pg-filtered .project-group { display: none; }
body.pg-filtered .project-group.pg-filter-match { display: block; }
.pg-filter-banner {
  display: none;
  margin: 0 0 14px;
  padding: 8px 14px;
  background: var(--panel-2);
  border: 1px solid var(--border);
  border-radius: 8px;
  font-size: 12px;
  color: var(--muted);
  align-items: center;
  gap: 10px;
}
body.pg-filtered .pg-filter-banner { display: flex; }
.pg-filter-banner button {
  background: transparent; color: var(--accent);
  border: 1px solid var(--border);
  padding: 2px 8px; border-radius: 6px;
  font-size: 11px; font-weight: 600; cursor: pointer;
}
.pg-filter-banner button:hover { background: var(--panel); }

.empty { text-align: center; padding: 60px; color: var(--muted); }
.empty code { background: var(--panel-2); padding: 2px 6px; border-radius: 4px; }
"""

JS = """
(function() {
  let pollTimer = null;
  let lastUpdated = null;

  // Plan 5 H2 (2026-04-23): preserve scroll position and <details> open state
  // across auto-refresh reloads. Without this, expanding a long-cell and then
  // hitting a refresh closes it again — frustrating during live debugging.
  const SS_KEY_SCROLL = 'whisper.scrollY';
  const SS_KEY_DETAILS = 'whisper.detailsOpen';

  function snapshotState() {
    try {
      sessionStorage.setItem(SS_KEY_SCROLL, String(window.scrollY || 0));
      const opened = [];
      document.querySelectorAll('details.long-cell[open]').forEach((el, idx) => {
        // Use parent .stage[data-stage] + record basename as a stable key.
        const stage = el.closest('.stage');
        const record = el.closest('.record');
        if (stage && record) {
          opened.push((record.dataset.basename || '') + '::' + (stage.dataset.stage || ''));
        }
      });
      sessionStorage.setItem(SS_KEY_DETAILS, JSON.stringify(opened));
    } catch (e) { /* silent — sessionStorage may be disabled */ }
  }

  function restoreState() {
    try {
      const opened = JSON.parse(sessionStorage.getItem(SS_KEY_DETAILS) || '[]');
      opened.forEach(key => {
        const [basename, stageId] = key.split('::');
        const sel = `.record[data-basename="${CSS.escape(basename)}"] .stage[data-stage="${CSS.escape(stageId)}"] details.long-cell`;
        const el = document.querySelector(sel);
        if (el) el.open = true;
      });
      const y = parseInt(sessionStorage.getItem(SS_KEY_SCROLL) || '0', 10);
      if (y > 0) window.scrollTo(0, y);
    } catch (e) { /* silent */ }
  }

  document.addEventListener('DOMContentLoaded', restoreState);
  // Snapshot continuously so even tab-close + reopen restores cleanly.
  window.addEventListener('scroll', () => {
    try { sessionStorage.setItem(SS_KEY_SCROLL, String(window.scrollY || 0)); } catch (e) {}
  }, { passive: true });
  document.addEventListener('toggle', (e) => {
    if (e.target && e.target.classList && e.target.classList.contains('long-cell')) {
      snapshotState();
    }
  }, true);

  async function check() {
    try {
      const res = await fetch('status.json?t=' + Date.now(), { cache: 'no-store' });
      if (!res.ok) return;
      const status = await res.json();
      document.getElementById('pending-count').textContent = status.pending_count;
      document.getElementById('running-count').textContent = status.running_count;
      document.getElementById('done-count').textContent = status.done_count;
      document.getElementById('last-updated').textContent = status.last_updated_human;
      if (lastUpdated !== null && status.last_updated > lastUpdated) {
        // Records changed: snapshot scroll + open-details, then reload.
        snapshotState();
        location.reload();
        return;
      }
      lastUpdated = status.last_updated;
      if (status.pending_count === 0 && status.running_count === 0) {
        if (pollTimer) { clearInterval(pollTimer); pollTimer = null; }
        document.getElementById('autorefresh-status').textContent = 'all done — auto-refresh stopped';
      }
    } catch (e) { /* silent */ }
  }

  function copyText(btn) {
    const text = btn.getAttribute('data-text');
    if (!text) return;
    navigator.clipboard.writeText(text).then(() => {
      const original = btn.textContent;
      btn.textContent = 'copied';
      btn.classList.add('copied');
      setTimeout(() => { btn.textContent = original; btn.classList.remove('copied'); }, 1200);
    });
  }
  window._copyText = copyText;

  function copyGroup(btn) {
    const slug = btn.getAttribute('data-slug');
    if (!slug) return;
    const group = document.querySelector('.project-group[data-slug="' + CSS.escape(slug) + '"]');
    if (!group) return;
    const parts = [];
    group.querySelectorAll('.record').forEach(rec => {
      const ts = (rec.querySelector('.record-title') || {}).textContent || '';
      // Prefer last (best) stage with text; fall back to first done stage.
      const stages = rec.querySelectorAll('.stage');
      let chosen = '';
      const order = ['large_corr','base_raw'];
      const byId = {};
      stages.forEach(s => { byId[s.getAttribute('data-stage')] = s; });
      for (const sid of order) {
        const s = byId[sid];
        if (!s) continue;
        const cb = s.querySelector('.copy-btn[data-text]');
        const t = cb && cb.getAttribute('data-text');
        if (t) { chosen = t; break; }
      }
      if (chosen) parts.push('[' + ts.trim() + ']\\n' + chosen);
    });
    if (!parts.length) return;
    navigator.clipboard.writeText(parts.join('\\n\\n')).then(() => {
      const original = btn.textContent;
      btn.textContent = 'copied';
      setTimeout(() => { btn.textContent = original; }, 1200);
    });
  }
  window._copyGroup = copyGroup;

  function applyFilter() {
    const m = (location.hash || '').match(/^#project=(.+)$/);
    const slug = m ? decodeURIComponent(m[1]) : '';
    document.body.classList.toggle('pg-filtered', !!slug);
    const banner = document.getElementById('pg-filter-banner');
    if (banner) {
      const label = document.getElementById('pg-filter-label');
      document.querySelectorAll('.project-group').forEach(g => {
        const match = g.getAttribute('data-slug') === slug;
        g.classList.toggle('pg-filter-match', match);
        if (match && label) label.textContent = g.getAttribute('data-name') || slug;
      });
      document.querySelectorAll('.pg-action-btn[data-action="filter"]').forEach(b => {
        b.classList.toggle('active', b.getAttribute('data-slug') === slug);
      });
    }
  }
  window._clearFilter = function() { history.replaceState(null, '', location.pathname + location.search); applyFilter(); };

  function onSummaryClick(e) {
    // Clicking the title (when filter active) clears filter; clicking action buttons
    // shouldn't toggle the <details>.
    const t = e.target;
    if (t.closest('.pg-action-btn')) {
      e.preventDefault();
      const btn = t.closest('.pg-action-btn');
      const action = btn.getAttribute('data-action');
      const slug = btn.getAttribute('data-slug');
      if (action === 'filter') {
        if (location.hash === '#project=' + slug) {
          _clearFilter();
        } else {
          location.hash = '#project=' + slug;
        }
      } else if (action === 'copy') {
        copyGroup(btn);
      }
      return;
    }
    if (t.closest('.pg-title') && document.body.classList.contains('pg-filtered')) {
      e.preventDefault();
      _clearFilter();
    }
  }

  document.addEventListener('DOMContentLoaded', () => {
    check();
    pollTimer = setInterval(check, 1000);
    document.querySelectorAll('.project-group > summary').forEach(s => {
      s.addEventListener('click', onSummaryClick);
    });
    applyFilter();
    window.addEventListener('hashchange', applyFilter);
  });
})();
"""


def _fmt_duration_ms(ms: int | None) -> str:
    if ms is None:
        return "—"
    if ms < 1000:
        return f"{ms} ms"
    return f"{ms/1000:.1f} s"


def _fmt_t0(epoch: float) -> str:
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(epoch))


def _render_stage(stage_def: dict[str, Any], stage_data: dict[str, Any]) -> str:
    sid = stage_def["id"]
    label = stage_def["label"]
    status = stage_data.get("status", "pending")
    text = stage_data.get("text", "") or ""
    err = stage_data.get("error")
    dur = stage_data.get("duration_ms")
    src = stage_data.get("source", "")
    degraded_note = stage_data.get("degraded_note")
    finished_at = stage_data.get("finished_at")  # epoch seconds (float)

    # Semantic label for the stage-meta timing display:
    #   base_raw   → button-press → paste-ready latency (NOT audio duration;
    #                audio length is shown separately in the record summary
    #                via wav_duration_ms / `🎙 audio:`).
    #   large_corr → wall time the worker took to produce the corrected text.
    #   other      → unlabelled (generic duration).
    # Fixed 2026-04-24 (F-S0-01): label was wrongly "length" which made the
    # per-stage cell appear to show audio length, contradicting the headline
    # `🎙 audio:` figure. The data here is paste-latency, not audio length.
    if sid == "base_raw":
        dur_label = "latency"
    elif sid == "large_corr":
        dur_label = "processed in"
    else:
        dur_label = ""

    quick_badge = '<span class="quick-tag">[quick paste]</span>' if src == "quick_paste" else ""
    # Plan 5 H3 (2026-04-23): degraded amber badge for Q4 (degraded_note).
    # Plan 6 (2026-04-23): two variants — INFO (blue) when text was improved
    # by dictionary even though Copilot failed; WARN (amber) when nothing
    # improved the raw whisper output. Trigger string set in worker.
    if degraded_note:
        # Plan 6 (2026-04-23): two variants.
        # INFO (blue) = text in `text` is still useful (dict-corrected even
        # though Copilot failed). Detected via either:
        #   (a) new structured prefix from worker, or
        #   (b) legacy records: degraded_note matches a known Copilot-class
        #       failure mode AND text is non-empty AND text length is
        #       reasonable (>= 20 chars, the rough length where dict-only
        #       output is still useful — single-word residue gets WARN).
        # WARN (amber) = no usable improvement happened, OR auth failure,
        # OR non-Copilot pipeline issue.
        # Post-oracle-QC tightening: previously any non-empty text with a
        # degraded_note was INFO; this hid genuine failures (e.g. one-word
        # residue, bad-json that left base_raw text). Whitelist only known
        # Copilot output-class failures where dict-corrected raw is the
        # expected fallback.
        new_style = degraded_note.startswith("copilot skipped (dict-corrected only)")
        # Whitelist of Copilot-output-class failure substrings (model-side
        # issues, not auth/transport/content). Auth ("no copilot token",
        # "401", "unauthorized") and content ("self-reference") stay WARN.
        _COPILOT_OUTPUT_FAILURES = (
            "copilot empty response",
            "model_not_supported",
            "model_not_found",
            "copilot bad response shape",
            "copilot bad json",
            "copilot all models failed",
        )
        legacy_useful = (
            not new_style
            and bool(text)
            and len(text) >= 20
            and any(s in degraded_note for s in _COPILOT_OUTPUT_FAILURES)
        )
        is_info = new_style or legacy_useful
        badge_cls = "degraded-badge info" if is_info else "degraded-badge"
        badge_icon = "ℹ" if is_info else "⚠"
        # F-S1-04: also colour the status-dot itself for at-a-glance scan.
        # Only fire on successful (done) runs — pending/running/error keep
        # their own dot colour.
        dot_extra = " degraded-info" if is_info else " degraded-warn"
        if new_style:
            label_short = "dict-corrected (no Copilot polish)"
        elif legacy_useful:
            label_short = "Copilot skipped — text is dict-corrected raw"
        else:
            label_short = degraded_note
        degraded_badge = (
            f'<span class="{badge_cls}" title="{html.escape(degraded_note)}">'
            f'{badge_icon} {html.escape(label_short)}</span>'
        )
    else:
        degraded_badge = ""
        dot_extra = ""

    # Plan 5 H1 (2026-04-23): collapse very long stage text behind an expand
    # toggle so the per-record card stays scannable. Threshold = 2000 chars.
    EXPAND_THRESHOLD = 2000

    def _wrap_text(t: str) -> str:
        if not t:
            return "<em>(empty)</em>"
        if len(t) > EXPAND_THRESHOLD:
            preview = html.escape(t[:200].replace("\n", " "))
            return (
                '<details class="long-cell">'
                f'<summary>📄 {len(t):,} chars · "{preview}…" '
                '(click to expand)</summary>'
                f'<pre>{html.escape(t)}</pre>'
                '</details>'
            )
        return html.escape(t)

    if status == "pending":
        body = '<div class="stage-text pending">queued — waiting for worker…</div>'
    elif status == "running":
        body = '<div class="stage-text running">transcribing…</div>'
    elif status == "error":
        body = f'<div class="stage-text error">{html.escape(err or "error")}</div>'
    else:
        body = f'<div class="stage-text">{_wrap_text(text)}</div>'

    can_copy = status == "done" and bool(text)
    copy_attr = html.escape(text, quote=True) if can_copy else ""
    btn_disabled = "" if can_copy else "disabled"

    # Compose the stage-meta cell. When dur is None, keep the clean `—`
    # fallback from _fmt_duration_ms (no "latency: —" artefact). When no
    # semantic label applies, fall back to the bare duration.
    if dur is None or dur_label == "":
        meta = _fmt_duration_ms(dur)
    else:
        meta = f"{dur_label}: {_fmt_duration_ms(dur)}"

    # F-S1-01 (2026-04-24): Plan 4 S2 — derive `started:` HH:MM:SS from
    # finished_at - duration_ms. Shown as a second meta line below the main
    # one so the existing layout doesn't shift. Only render when both are
    # available AND the stage is `done` (avoid showing "started: 12:34:56"
    # next to a still-running cell, which would mislead).
    started_meta = ""
    if status == "done" and finished_at and dur is not None:
        try:
            started_epoch = float(finished_at) - (float(dur) / 1000.0)
            started_meta = (
                f'<div class="stage-meta-sub">started: '
                f'{time.strftime("%H:%M:%S", time.localtime(started_epoch))}</div>'
            )
        except (TypeError, ValueError):
            pass
    # NOTE: Plan 4 S2 also calls for a `paste:` label. That requires Hammerspoon
    # to write a second sidecar at the moment hs.eventtap.keyStroke fires the
    # paste. Tracked as a Lua-side follow-up; not implementable from Python alone.

    # F-S1-04: only apply the degraded dot modifier on completed runs.
    dot_class = f"{status}{dot_extra}" if status == "done" else status

    return f"""
      <div class="stage" data-stage="{sid}">
        <div class="stage-head">
          <div>
            <span class="status-dot {dot_class}"></span>
            <span class="stage-label">{html.escape(label)}</span>
            {quick_badge}
            {degraded_badge}
          </div>
          <div class="stage-meta-wrap">
            <div class="stage-meta" title="{dur_label}">{meta}</div>
            {started_meta}
          </div>
        </div>
        {body}
        <div class="stage-actions">
          <button class="copy-btn" {btn_disabled} data-text="{copy_attr}" onclick="_copyText(this)">copy</button>
        </div>
      </div>
    """


def _render_record(rec: dict[str, Any], stages: list[dict[str, Any]]) -> str:
    wav_path = rec.get("wav_path", "")
    basename = rec.get("wav_basename", "")
    t0 = rec.get("t0_epoch", 0)
    app_name = (rec.get("app_name") or "").strip()
    screenshot_path = (rec.get("screenshot_path") or "").strip()
    wav_url = "file://" + wav_path
    # Plan 4 S1C / Plan 5 H5 (2026-04-23): record-level summary line.
    # Surfaces audio length so user can compare WAV duration vs processing time.
    wav_dur_ms = rec.get("wav_duration_ms")
    summary_bits: list[str] = []
    if wav_dur_ms:
        summary_bits.append(f'🎙 audio: {_fmt_duration_ms(wav_dur_ms)}')
    # Sum of all done stage durations = total worker wall time (excluding queue waits)
    total_proc_ms = sum(
        (st.get("duration_ms") or 0)
        for st in rec.get("stages", {}).values()
        if st.get("status") == "done" and st.get("source") != "quick_paste"
    )
    if total_proc_ms:
        summary_bits.append(f'⚙ processed: {_fmt_duration_ms(total_proc_ms)}')
    summary_html = (
        f'<div class="record-summary">{" · ".join(summary_bits)}</div>'
        if summary_bits else ""
    )
    stages_html = "\n".join(_render_stage(s, rec["stages"].get(s["id"], {})) for s in stages)
    app_html = f' <span class="record-app-tag">{html.escape(app_name)}</span>' if app_name else ""
    screenshot_html = ""
    if screenshot_path:
        sc_url = "file://" + screenshot_path
        screenshot_html = (
            f' <a class="screenshot-link" href="{html.escape(sc_url, quote=True)}" '
            f'title="Desktop screenshot at recording time" target="_blank">📷</a>'
        )
    return f"""
      <div class="record" data-basename="{html.escape(basename)}">
        <div class="record-header">
          <div>
            <div class="record-title">{_fmt_t0(t0)}{app_html}{screenshot_html}</div>
            <div class="wav-path"><a href="{html.escape(wav_url, quote=True)}">{html.escape(wav_path)}</a></div>
            {summary_html}
          </div>
          <div class="record-meta">{html.escape(basename)}</div>
        </div>
        <div class="stages">
          {stages_html}
        </div>
      </div>
    """


def _project_hint(rec: dict[str, Any]) -> str:
    """Return cleaned project hint or '' if missing/UNKNOWN."""
    proj = (rec.get("project_hint") or "").strip()
    if not proj or proj.upper() == "UNKNOWN":
        return ""
    return proj


def _slug(name: str) -> str:
    s = re.sub(r"[^a-zA-Z0-9]+", "-", name.strip().lower()).strip("-")
    return s or "unsorted"


def _accent_hsl(name: str) -> str:
    """Stable HSL accent from project name. hue = hash(name) % 360, sat 55%, light 60%."""
    h = hashlib.md5(name.encode("utf-8")).digest()
    hue = int.from_bytes(h[:2], "big") % 360
    return f"hsl({hue}, 55%, 60%)"


def _fmt_relative(epoch: float, now: float | None = None) -> str:
    if not epoch:
        return "—"
    now = now if now is not None else time.time()
    delta = max(0, int(now - epoch))
    if delta < 60:
        return "just now"
    if delta < 3600:
        m = delta // 60
        return f"{m}m ago"
    if delta < 86400:
        h = delta // 3600
        return f"{h}h ago"
    d = delta // 86400
    if d < 30:
        return f"{d}d ago"
    return time.strftime("%Y-%m-%d", time.localtime(epoch))


def _app_pills(records: list[dict[str, Any]]) -> str:
    """Dedup app_names preserving recency order; cap at MAX_PILLS, add +N overflow."""
    counts: "OrderedDict[str, int]" = OrderedDict()
    for r in records:
        a = (r.get("app_name") or "").strip()
        if not a:
            continue
        counts[a] = counts.get(a, 0) + 1
    if not counts:
        return ""
    apps = list(counts.items())
    visible = apps[:MAX_PILLS]
    overflow = apps[MAX_PILLS:]
    tooltip = " · ".join(f"{a}: {c}" for a, c in apps)
    pills = "".join(
        f'<span class="pg-app-pill" title="{html.escape(tooltip, quote=True)}">{html.escape(a)}</span>'
        for a, _ in visible
    )
    if overflow:
        more_n = len(overflow)
        more_tip = " · ".join(f"{a}: {c}" for a, c in overflow)
        pills += (
            f'<span class="pg-app-pill pg-app-pill--more" '
            f'title="{html.escape(more_tip, quote=True)}">+{more_n}</span>'
        )
    return f'<div class="pg-apps">{pills}</div>'


def _group_records(
    records_sorted: list[dict[str, Any]],
) -> "OrderedDict[str, list[dict[str, Any]]]":
    """Group by project_hint (PRIMARY). Records with no usable hint go to a single
    'Unsorted' bucket; sub-grouping by app happens later in render.

    Returns an OrderedDict keyed by group name, sorted by newest record desc.
    The Unsorted bucket is always rendered last regardless of recency.
    """
    buckets: "OrderedDict[str, list[dict[str, Any]]]" = OrderedDict()
    for rec in records_sorted:
        proj = _project_hint(rec)
        key = proj if proj else UNSORTED_LABEL
        buckets.setdefault(key, []).append(rec)

    def sort_key(item: tuple[str, list[dict[str, Any]]]) -> tuple[int, float]:
        name, recs = item
        # Push Unsorted to the end (group_rank = 1), real projects first (0).
        rank = 1 if name == UNSORTED_LABEL else 0
        newest = recs[0].get("t0_epoch", 0) if recs else 0
        return (rank, -newest)

    return OrderedDict(sorted(buckets.items(), key=sort_key))


def _render_group_header(
    name: str,
    recs: list[dict[str, Any]],
    accent: str,
    is_fallback: bool,
    show_apps: bool = True,
) -> str:
    slug = _slug(name)
    count = len(recs)
    newest = max((r.get("t0_epoch", 0) for r in recs), default=0)
    rel = _fmt_relative(newest)
    apps_html = _app_pills(recs) if show_apps else ""
    title_class = "pg-title"
    return f"""
        <summary>
          <span class="pg-disclosure">▶</span>
          <div class="pg-titlewrap">
            <h2 class="{title_class}">{html.escape(name)}<span class="pg-count">({count})</span></h2>
            <div class="pg-meta">last activity {html.escape(rel)}</div>
          </div>
          {apps_html}
          <div class="pg-actions">
            <button class="pg-action-btn" data-action="copy" data-slug="{html.escape(slug, quote=True)}" title="Copy concatenated transcripts">Copy all</button>
            <button class="pg-action-btn" data-action="filter" data-slug="{html.escape(slug, quote=True)}" title="Filter to only this project">Filter</button>
          </div>
        </summary>
    """


def _render_unsorted_body(recs: list[dict[str, Any]], stages: list[dict[str, Any]]) -> str:
    """Sub-group records by app_name within the Unsorted bucket."""
    sub: "OrderedDict[str, list[dict[str, Any]]]" = OrderedDict()
    for r in recs:
        a = (r.get("app_name") or "").strip() or "(no app)"
        sub.setdefault(a, []).append(r)
    sub = OrderedDict(
        sorted(sub.items(), key=lambda kv: kv[1][0].get("t0_epoch", 0), reverse=True)
    )
    parts: list[str] = []
    for app_name, app_recs in sub.items():
        plural = "s" if len(app_recs) != 1 else ""
        body = "\n".join(_render_record(r, stages) for r in app_recs)
        parts.append(f"""
          <div class="pg-subgroup">
            <div class="pg-subhead">
              <span class="pg-app-pill">{html.escape(app_name)}</span>
              <span class="pg-subcount">{len(app_recs)} record{plural}</span>
            </div>
            {body}
          </div>
        """)
    return "<div class=\"pg-body\">" + "\n".join(parts) + "</div>"


def _render_group(
    name: str,
    recs: list[dict[str, Any]],
    stages: list[dict[str, Any]],
    is_first: bool,
) -> str:
    is_fallback = name == UNSORTED_LABEL
    accent = "var(--muted)" if is_fallback else _accent_hsl(name)
    slug = _slug(name)
    open_attr = " open" if is_first else ""
    fallback_attr = ' data-fallback="1"' if is_fallback else ""
    style = f'style="--project-accent: {accent};"'
    header = _render_group_header(name, recs, accent, is_fallback, show_apps=not is_fallback)

    if is_fallback:
        body = _render_unsorted_body(recs, stages)
    else:
        body = (
            '<div class="pg-body">'
            + "\n".join(_render_record(rec, stages) for rec in recs)
            + "</div>"
        )

    return f"""
      <details class="project-group"{open_attr}{fallback_attr}
               data-slug="{html.escape(slug, quote=True)}"
               data-name="{html.escape(name, quote=True)}"
               {style}>
        {header}
        {body}
      </details>
    """


def render_html(path: Path, records_sorted: list[dict[str, Any]], stages: list[dict[str, Any]]) -> None:
    if not records_sorted:
        body = """
          <div class="empty">
            No transcriptions yet. Record something with <code>⌃⌘W</code> / <code>⌃⌘Q</code>,
            or run <code>python3 bin/backfill.py 20</code> to import recent recordings.
          </div>
        """
    else:
        groups = _group_records(records_sorted)
        body = "\n".join(
            _render_group(name, recs, stages, is_first=(idx == 0))
            for idx, (name, recs) in enumerate(groups.items())
        )

    pending = sum(1 for r in records_sorted for st in r["stages"].values() if st.get("status") == "pending")
    running = sum(1 for r in records_sorted for st in r["stages"].values() if st.get("status") == "running")
    total_cells = len(records_sorted) * len(stages)
    done = total_cells - pending - running

    html_doc = f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Whisper Transcription Log</title>
  <style>{CSS}</style>
</head>
<body>
  <header>
    <div>
      <h1>Whisper Transcription Log</h1>
      <div class="muted">
        Newest first &middot; grouped by project &middot;
        <span id="autorefresh-status">auto-refresh every 1 s while pending</span>
      </div>
    </div>
    <div class="summary">
      <span class="pill">{len(records_sorted)} recordings</span>
      <span class="pill done">done <span id="done-count">{done}</span></span>
      <span class="pill running">running <span id="running-count">{running}</span></span>
      <span class="pill pending">pending <span id="pending-count">{pending}</span></span>
      <span class="muted">updated <span id="last-updated">{time.strftime('%Y-%m-%d %H:%M:%S')}</span></span>
    </div>
  </header>
  <main>
    <div id="pg-filter-banner" class="pg-filter-banner">
      <span>Filtered to project: <strong id="pg-filter-label"></strong></span>
      <button onclick="_clearFilter()">Clear filter</button>
    </div>
    {body}
  </main>
  <script>{JS}</script>
</body>
</html>
"""

    fd, tmp = tempfile.mkstemp(prefix=path.name + ".", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(html_doc)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
