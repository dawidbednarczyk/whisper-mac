-- Whisper mouse side-button bindings via Logi Options+ keyboard shortcuts
--
-- Logi Options+ maps MX Anywhere 3S side buttons to keyboard shortcuts:
--   Forward button → Ctrl+Shift+Cmd+9 (start streaming)
--   Back button    → Ctrl+Shift+Cmd+0 (stop streaming ONLY — no paste)
--   Middle button  → Ctrl+Shift+Cmd+8 (paste improved transcription, strict)
--
-- F-MiddleOnlyStrict (2026-04-24):
--   * Back button NEVER pastes. Idle press shows alert pointing user at middle.
--   * Middle button pastes ONLY when stages.large_corr.status == "done".
--     base_raw paste path removed entirely. While large_corr is pending, alert
--     "⏳ Improved transcription in progress…" — no clipboard write, no paste.
--   * Removes the previous F-Back-NoRec quick-paste behavior (base_raw was
--     misleading downstream agents).
--
-- Phase 2: Mouse buttons use STREAMING mode (live overlay + corrections)
-- Keyboard shortcuts (Ctrl+Cmd+W/Q) remain for BATCH mode.
--
-- All press events are emitted through whisper_debug (JSON lines in
-- /tmp/whisper_debug.log) so we can diagnose "button did nothing" reports.

local dbg = require("whisper_debug")

-- F4: removed dead WHISPER_SCRIPT local (unused after middle-button rewrite).

-- Paths for middle-button "paste improved transcription" flow.
local RECORDINGS_DIR = (os.getenv("WHISPER_HOME") or (os.getenv("HOME") .. "/whisper-mac")) .. "/upstream/Careless-Whisper/recordings"
local RECORDS_JSON = os.getenv("HOME") .. "/.whisper_log/records.json"

local function mev(event_name, data)
    dbg.event("mouse", event_name, data)
end

-- QC-01 fix v2 (2026-04-23, post-oracle review):
-- v1 used `launchctl setenv` which does NOT propagate to already-running
-- Hammerspoon's `hs.task.new` children (Hammerspoon's env is frozen at
-- launch). Verified live: `ps -E -p $(pgrep Hammerspoon)` showed zero
-- WHISPER_* vars after the launchctl writes.
--
-- v2 design: write a SIDECAR FILE at button-down time. The whisper_log_hook.sh
-- reads + deletes it on each invocation. This:
--   * Actually crosses the process boundary (file is global state)
--   * Is per-button (forward = recording-start) so no race between overlapping
--     recordings (QC-C from oracle review)
--   * Has no shell-injection surface (QC-F)
--   * Is verifiable: file existence proves the stamp ran
--
-- We only stamp on the FORWARD button (recording start). Back/middle are not
-- recording-start events; the schema field `button_pressed_at_ns` represents
-- "when the user pressed the button to begin THIS recording".
local PRESS_SIDECAR = "/tmp/whisper_button_press_forward.json"

local function stamp_button_press(button_name)
    local epoch_s = hs.timer.secondsSinceEpoch()
    local epoch_ns = string.format("%.0f", epoch_s * 1e9)
    if button_name == "forward" then
        -- Write atomically: open, write JSON, close. Hook script reads + deletes.
        local fh = io.open(PRESS_SIDECAR, "w")
        if fh then
            fh:write(string.format(
                '{"button":"%s","epoch_ns":%s,"epoch_s":%.6f}\n',
                button_name, epoch_ns, epoch_s))
            fh:close()
            mev("button_press_sidecar_written", {
                button = button_name,
                path = PRESS_SIDECAR,
                epoch_ns = epoch_ns,
            })
        else
            mev("button_press_sidecar_error", {
                button = button_name,
                path = PRESS_SIDECAR,
            })
        end
    else
        -- back/middle: just log the press, don't write the recording-start sidecar
        mev("button_press_logged", {
            button = button_name,
            epoch_ns = epoch_ns,
        })
    end
end

-- Plan 1 (Bug B fix, 2026-04-23): read newest RECORD from records.json
-- (last entry, not newest WAV on disk) and return best-available stage text
-- with priority large_corr > base_raw. Eliminates wav-vs-record race and
-- "previous recording" pastes during in-flight processing.
--
-- Returns (text, source) on success, or (nil, reason) if nothing usable.
-- The middle-button handler uses (text == nil) to show N/A and NEVER falls
-- back to a previous recording or the clipboard.
local function read_newest_record_best_stage()
    local fh = io.open(RECORDS_JSON, "r")
    if not fh then return nil, "no records.json" end
    local raw = fh:read("*a")
    fh:close()
    if not raw or raw == "" then return nil, "empty records.json" end
    local ok, decoded = pcall(hs.json.decode, raw)
    if not ok or type(decoded) ~= "table" then
        return nil, "records.json unparseable"
    end
    -- records.json ACTUAL shape (per transcription_log.py _load_records):
    --     { [basename] = { wav_path=..., t0_epoch=..., stages={...}, ... }, ... }
    -- The top-level table IS the records map. There is no `records`/`order`
    -- wrapper. Pick newest by t0_epoch (preferred) or by basename string sort
    -- (basenames are timestamp-prefixed e.g. 20260423213645.wav so sort works).
    local records = decoded
    local newest_basename, newest_t0
    local _key_count = 0
    for k, v in pairs(records) do
        _key_count = _key_count + 1
        if type(v) == "table" then
            local t0 = tonumber(v.t0_epoch) or tonumber(v.created_at) or 0
            if not newest_t0 or t0 > newest_t0
               or (t0 == newest_t0 and k > (newest_basename or "")) then
                newest_t0 = t0
                newest_basename = k
            end
        end
    end
    mev("middle_scan_records", {
        key_count       = _key_count,
        newest_basename = newest_basename,
        newest_t0       = newest_t0,
        raw_chars       = #raw,
    })
    if not newest_basename then return nil, "no records (scanned " .. _key_count .. " keys)" end
    local rec = records[newest_basename]
    if type(rec) ~= "table" or type(rec.stages) ~= "table" then
        return nil, "no stages"
    end
    -- Priority: large_corr > base_raw
    local lc = rec.stages.large_corr
    if type(lc) == "table" and lc.status == "done"
       and type(lc.text) == "string" and #lc.text > 0 then
        return lc.text, "large_corr"
    end
    local br = rec.stages.base_raw
    if type(br) == "table" and br.status == "done"
       and type(br.text) == "string" and #br.text > 0 then
        return br.text, "base_raw"
    end
    return nil, "no stage ready yet"
end

-- F-MiddleOnlyStrict (2026-04-24): replaces the prior _quick variant. Returns
-- a structured state for the middle button:
--   ("done",    text,         created_at_epoch)
--   ("pending", elapsed_s,    created_at_epoch)
--   ("error",   error_msg,    created_at_epoch)
--   ("none",    reason,       nil)
-- NEVER returns base_raw text. The user has decided base_raw is misleading.
local function read_newest_record_large_corr_strict()
    local fh = io.open(RECORDS_JSON, "r")
    if not fh then return "none", "no records.json", nil end
    local raw = fh:read("*a")
    fh:close()
    if not raw or raw == "" then return "none", "empty records.json", nil end
    local ok, decoded = pcall(hs.json.decode, raw)
    if not ok or type(decoded) ~= "table" then
        return "none", "records.json unparseable", nil
    end
    local records = decoded
    local newest_basename, newest_t0
    for k, v in pairs(records) do
        if type(v) == "table" then
            local t0 = tonumber(v.t0_epoch) or tonumber(v.created_at) or 0
            if not newest_t0 or t0 > newest_t0
               or (t0 == newest_t0 and k > (newest_basename or "")) then
                newest_t0 = t0
                newest_basename = k
            end
        end
    end
    if not newest_basename then return "none", "no records yet", nil end
    local rec = records[newest_basename]
    if type(rec) ~= "table" or type(rec.stages) ~= "table" then
        return "none", "no stages", nil
    end
    local created = tonumber(rec.created_at) or tonumber(rec.t0_epoch) or 0
    local lc = rec.stages.large_corr
    if type(lc) ~= "table" then
        return "none", "no large_corr stage", created
    end
    if lc.status == "done" and type(lc.text) == "string" and #lc.text > 0 then
        return "done", lc.text, created
    end
    if lc.status == "error" then
        return "error", tostring(lc.error or "unknown error"), created
    end
    -- "pending" or any other intermediate state → in progress
    local elapsed = (created > 0) and math.floor(os.time() - created) or 0
    return "pending", elapsed, created
end

-- Forward side button → Start streaming transcription
hs.hotkey.bind({"ctrl", "shift", "cmd"}, "9", function()
    stamp_button_press("forward")
    mev("button_pressed", { button = "forward", hotkey = "ctrl+shift+cmd+9", action = "start" })
    local streaming = require("whisper_streaming")
    streaming.logState("mouse-start-pressed")

    if streaming.isStreaming() then
        mev("start_blocked_already_streaming", {})
        hs.alert.show("Whisper: already streaming — press BACK to stop", 2)
        return
    end

    -- Proactive cleanup of any stuck overlay / orphan tasks from a prior session
    streaming.panicCleanupIfStuck()

    mev("start_dispatch", {})
    streaming.start()
end)

-- Back side button → Stop streaming. Otherwise: NEVER paste anything.
-- F-MiddleOnlyStrict (2026-04-24): The back button is recording control only.
-- Idle press shows an alert pointing the user at the middle button. Stuck
-- overlay still gets cleared (panic recovery preserved).
hs.hotkey.bind({"ctrl", "shift", "cmd"}, "0", function()
    stamp_button_press("back")
    mev("button_pressed", { button = "back", hotkey = "ctrl+shift+cmd+0", action = "stop" })
    local streaming = require("whisper_streaming")
    streaming.logState("mouse-stop-pressed")

    if streaming.isStreaming() then
        -- F-Back-NoAutoPaste (2026-04-24): suppress the cmd+V keystroke after
        -- transcription completes. Clipboard is still set + log hook still fires.
        -- User pastes manually with the MIDDLE button when large_corr is done.
        streaming.suppress_auto_paste = true
        mev("stop_dispatch_streaming", { suppress_auto_paste = true })
        streaming.stop()
    else
        -- Reset the suppress flag so the next recording's stop is unaffected
        -- if the user manually clears it via different means.
        streaming.suppress_auto_paste = false
        local overlay = require("whisper_overlay")
        if overlay.exists() then
            mev("stop_panic_cleanup", {})
            streaming.forceReset("back-button-panic")
            hs.alert.show("Whisper: cleared stuck overlay", 1.5)
        else
            -- No recording in progress, no overlay → back button does NOTHING
            -- but tell the user where to paste from.
            mev("back_disabled_alert", {})
            hs.alert.show(
                "Back = recording control only.\nUse MIDDLE button to paste improved transcription.",
                2.5
            )
        end
    end
end)

-- Middle mouse button → Paste improved transcription, STRICTLY large_corr only.
-- F-MiddleOnlyStrict (2026-04-24):
--   * Pastes ONLY when stages.large_corr.status == "done".
--   * If pending → show "⏳ Improved transcription in progress… (Xs elapsed)".
--   * If error  → show "❌ Improved failed — no fallback" (no base_raw fallback).
--   * NEVER pastes base_raw. NEVER falls back to a previous recording or clipboard.
hs.hotkey.bind({"ctrl", "shift", "cmd"}, "8", function()
    stamp_button_press("middle")
    mev("button_pressed", { button = "middle", hotkey = "ctrl+shift+cmd+8", action = "paste_improved" })
    local streaming = require("whisper_streaming")
    streaming.logState("mouse-paste-improved-pressed")

    if streaming.isStreaming() then
        mev("paste_improved_blocked_streaming", {})
        hs.alert.show("Cannot paste improved while streaming", 2)
        return
    end

    local overlay = require("whisper_overlay")
    if overlay.exists() then
        mev("paste_improved_panic_cleanup", {})
        streaming.forceReset("mid-button-panic")
        -- continue to paste flow anyway (overlay wasn't the primary intent)
    end

    local state, payload, created_at = read_newest_record_large_corr_strict()

    if state == "pending" then
        local elapsed = tonumber(payload) or 0
        mev("paste_improved_blocked_pending", {
            elapsed_s  = elapsed,
            created_at = created_at or 0,
        })
        hs.alert.show(
            "⏳ Improved transcription in progress…\n(" .. elapsed .. "s elapsed)",
            2
        )
        return
    end

    if state == "error" then
        mev("paste_improved_blocked_error", {
            error      = tostring(payload or ""),
            created_at = created_at or 0,
        })
        hs.alert.show(
            "❌ Improved transcription failed — no fallback.\n⌘V from clipboard if needed.",
            3
        )
        return
    end

    if state == "none" then
        mev("paste_improved_not_ready", { reason = tostring(payload or "") })
        hs.alert.show("N/A — " .. tostring(payload or "no transcription yet"), 2.5)
        return
    end

    -- state == "done": payload is the text. Switch to captured target_app first
    -- (best-effort), then paste.
    local text = tostring(payload)
    local target = streaming.getTargetApp and streaming.getTargetApp() or nil
    local target_name = (target and target.name and target:name()) or "<current>"

    mev("paste_improved_dispatch", {
        source     = "large_corr",
        text_len   = #text,
        target_app = target_name,
    })

    hs.pasteboard.setContents(text)
    if target then
        pcall(function() target:activate() end)
        hs.timer.doAfter(0.15, function()
            hs.eventtap.keyStroke({"cmd"}, "v", 0)
        end)
    else
        hs.eventtap.keyStroke({"cmd"}, "v", 0)
    end
    hs.alert.show("✓ pasted improved", 1.2)
    mev("paste_improved_done", {
        source     = "large_corr",
        text_len   = #text,
        target_app = target_name,
    })
end)
