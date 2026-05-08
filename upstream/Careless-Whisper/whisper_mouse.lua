-- Whisper mouse side-button bindings via Logi Options+ keyboard shortcuts
--
-- Logi Options+ maps MX Anywhere 3S side buttons to keyboard shortcuts:
--   Forward button → Ctrl+Shift+Cmd+9 (start streaming)
--   Back button    → Ctrl+Shift+Cmd+0 (stop streaming / stop batch)
--   Middle button  → Ctrl+Shift+Cmd+8 (retranscribe; also panic-cleans stuck overlay)
--
-- Phase 2: Mouse buttons use STREAMING mode (live overlay + corrections)
-- Keyboard shortcuts (Ctrl+Cmd+W/Q) remain for BATCH mode.
--
-- All press events are emitted through whisper_debug (JSON lines in
-- /tmp/whisper_debug.log) so we can diagnose "button did nothing" reports.

local dbg = require("whisper_debug")

local function mev(event_name, data)
    dbg.event("mouse", event_name, data)
end

-- Forward side button → Start streaming transcription
hs.hotkey.bind({"ctrl", "shift", "cmd"}, "9", function()
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

-- Back side button → Stop streaming or batch
hs.hotkey.bind({"ctrl", "shift", "cmd"}, "0", function()
    mev("button_pressed", { button = "back", hotkey = "ctrl+shift+cmd+0", action = "stop" })
    local streaming = require("whisper_streaming")
    streaming.logState("mouse-stop-pressed")

    if streaming.isStreaming() then
        mev("stop_dispatch_streaming", {})
        streaming.stop()
    else
        local overlay = require("whisper_overlay")
        if overlay.exists() then
            mev("stop_panic_cleanup", {})
            streaming.forceReset("back-button-panic")
            hs.alert.show("Whisper: cleared stuck overlay", 1.5)
        else
            mev("stop_dispatch_batch", {})
            hs.alert.show("Whisper: transcribing...", 1.5)
            if run_whisper then
                run_whisper("stop")
            end
        end
    end
end)

-- Middle mouse button → Re-transcribe last recording (panic button too)
hs.hotkey.bind({"ctrl", "shift", "cmd"}, "8", function()
    mev("button_pressed", { button = "middle", hotkey = "ctrl+shift+cmd+8", action = "retranscribe" })
    local streaming = require("whisper_streaming")
    streaming.logState("mouse-retranscribe-pressed")

    if streaming.isStreaming() then
        mev("retranscribe_blocked_streaming", {})
        hs.alert.show("Cannot retranscribe while streaming", 2)
        return
    end

    local overlay = require("whisper_overlay")
    if overlay.exists() then
        mev("retranscribe_panic_cleanup", {})
        streaming.forceReset("mid-button-panic")
    end

    mev("retranscribe_dispatch", {})
    hs.alert.show("Whisper: re-transcribing...", 1.5)
    if run_whisper then
        run_whisper("retranscribe")
    end
end)
