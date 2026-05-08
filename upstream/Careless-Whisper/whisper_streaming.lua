-- whisper_streaming.lua
-- Real-time speech-to-text streaming engine for Hammerspoon
--
-- This module launches whisper-stream binary, parses its output in real-time,
-- displays confirmed and partial transcriptions in an overlay, detects sentence
-- boundaries, triggers Copilot API corrections, and pastes the final result.

local M = {}

-- ============================================================================
-- CONFIGURATION
-- ============================================================================

local WHISPER_STREAM_BIN = "/opt/homebrew/bin/whisper-stream"
local STREAM_MODEL = os.getenv("HOME") .. "/whisper-models/ggml-base.en.bin"
local FALLBACK_MODEL = os.getenv("HOME") .. "/whisper-models/ggml-medium.en.bin"
local SDL_DEVICE_ID = 1  -- "Usb Audio Device" in SDL2 enumeration
local RECORDINGS_DIR = os.getenv("HOME") .. "/Documents/claude_projects/Careless-Whisper/recordings"

local COPILOT_API_URL = "https://api.githubcopilot.com/chat/completions"
local COPILOT_AUTH_FILE = os.getenv("HOME") .. "/.config/careless-whisper/auth.json"
local COPILOT_MODEL = "claude-sonnet-4.6"

-- Retranscribe-on-stop configuration
local WHISPER_SH = os.getenv("HOME") .. "/Documents/claude_projects/Careless-Whisper/whisper.sh"
local CORRECTIONS_TSV = os.getenv("HOME") .. "/Documents/claude_projects/Careless-Whisper/transcription_corrections.tsv"
local TEXT_FILE = (os.getenv("TMPDIR") or "/tmp") .. "/whisper_output.txt"
local RETRANSCRIBE_TIMEOUT = 30  -- seconds before falling back to live text

-- Post-stop latency tuning
-- STOP_FLUSH_DELAY_S:        wait time between SIGTERM and retranscribe launch (was 0.5)
-- OVERLAY_CLEANUP_DELAY_S:   how long the overlay lingers after paste (was 1.2)
-- INSTANT_PASTE_ON_STOP:     paste live tiny.en text immediately on stop, then silently
--                            replace clipboard with higher-quality retranscribe when done.
--                            User perceives stop as instant; improved text arrives in
--                            clipboard shortly after (press ⌘V again to replace).
-- SKIP_RETRANSCRIBE_UNDER_S: for clips shorter than this, skip the batch re-run entirely
--                            (tiny.en quality is already good for short utterances).
local STOP_FLUSH_DELAY_S         = 0.2
local OVERLAY_CLEANUP_DELAY_S    = 0.4
local INSTANT_PASTE_ON_STOP      = true
local SKIP_RETRANSCRIBE_UNDER_S  = 5

-- LLM-aware wrapper prepended to every pasted transcription
local TRANSCRIPT_PREFIX = "[Voice transcription — retranscribed for accuracy. Technical terms may need verification. If any part is unclear or seems incorrect, ask for clarification before proceeding.]"

-- ============================================================================
-- STATE VARIABLES
-- ============================================================================

local stream_task = nil           -- hs.task for whisper-stream process
local buffer = ""                 -- raw stdout buffer for parsing
local sentences = {}              -- array of {raw=string, corrected=string|nil, status="pending"|"correcting"|"done"}
local current_fragment = ""       -- text accumulating toward next sentence
local current_partial = ""        -- latest partial text from whisper-stream
local target_app = nil            -- app to paste into when done
local copilot_token = nil         -- cached auth token
local pending_corrections = 0     -- count of in-flight corrections
local retranscribe_task = nil     -- hs.task for retranscribe (if running)
local retranscribe_done = false   -- flag to prevent double-paste on timeout
local retranscribe_watchdog = nil -- timer handle for retranscribe timeout
local stop_hotkey = nil           -- hs.hotkey: Enter key stops streaming while active
local overlay_safety_timer = nil  -- last-resort timer that force-destroys overlay
local session_id = 0              -- incremented on each start(); used to label logs
local stop_invoked = false        -- true while user-initiated stop() flow is active
local last_partial_logged = ""    -- debounce partial-text logging (only log on change)
local last_partial_log_ms = 0     -- rate-limit partial logging
local session_started_ms = 0      -- hs.timer ms when stream started (for latency calc)
local first_output_received = false  -- true once whisper-stream produces real (non-hallucination) text

-- ============================================================================
-- DEBUG LOGGING (delegates to whisper_debug.lua)
-- ============================================================================
-- Main event log:    /tmp/whisper_debug.log                (JSON lines)
-- Per-session log:   /tmp/whisper_debug/session_*.log      (full detail)
-- Quality summary:   /tmp/whisper_debug/session_*.summary.json
--
-- Tail live:  tail -f /tmp/whisper_debug.log
-- Pretty:     jq -c . /tmp/whisper_debug.log | tail -n 100

local dbg = require("whisper_debug")

local function log_event(event, data)
    return dbg.event("streaming", event, data)
end

-- Snapshot of runtime state for debugging stuck sessions
local function log_state(tag)
    local overlay_mod = package.loaded["whisper_overlay"]
    local overlay_exists = overlay_mod and overlay_mod.exists and overlay_mod.exists() or false
    local overlay_visible = overlay_mod and overlay_mod.isVisible and overlay_mod.isVisible() or false
    local stream_running = stream_task and stream_task.isRunning and stream_task:isRunning() or false
    local retrans_running = retranscribe_task and retranscribe_task.isRunning and retranscribe_task:isRunning() or false
    log_event("state_snapshot", {
        tag              = tag,
        stream_task      = stream_task ~= nil,
        stream_running   = stream_running,
        retrans_task     = retranscribe_task ~= nil,
        retrans_running  = retrans_running,
        retrans_done     = retranscribe_done,
        overlay_exists   = overlay_exists,
        overlay_visible  = overlay_visible,
        pending_corr     = pending_corrections,
        stop_invoked     = stop_invoked,
    })
end

-- Exposed for external inspection / panic tooling
function M.logState(tag)
    log_state(tag or "external")
end

-- Kept-for-compatibility helper (callers still use log(...) in places)
local function log(msg)
    log_event("log", { msg = tostring(msg) })
end

-- ============================================================================
-- COPILOT AUTHENTICATION
-- ============================================================================

-- Load Copilot access token from auth.json
local function load_copilot_token()
    local f = io.open(COPILOT_AUTH_FILE, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    local token = content:match('"access_token"%s*:%s*"([^"]+)"')
    copilot_token = token
    return token
end

-- ============================================================================
-- DISPLAY ASSEMBLY & OVERLAY UPDATE
-- ============================================================================

-- ============================================================================
-- DICTIONARY CORRECTIONS (TSV)
-- ============================================================================

local corrections_cache = nil

-- Load corrections from TSV file (wrong<TAB>right format, # comments ignored)
local function load_corrections()
    local f = io.open(CORRECTIONS_TSV, "r")
    if not f then return {} end

    local pairs_list = {}
    for line in f:lines() do
        if not line:match("^%s*#") and line:match("%S") then
            local wrong, right = line:match("^([^\t]+)\t(.+)$")
            if wrong and right then
                table.insert(pairs_list, { wrong = wrong, right = right })
            end
        end
    end
    f:close()

    -- Sort longest-first to avoid partial replacements (same logic as Python version)
    table.sort(pairs_list, function(a, b) return #a.wrong > #b.wrong end)
    return pairs_list
end

-- ============================================================================
-- LOOP-COLLAPSE SAFETY NET
-- ============================================================================
-- Mirror of bin/transcription_worker.py:_collapse_runaway_loops (n-grams 1..4,
-- threshold 5). Catches "vent marking by vent marking by..." style runaway
-- loops produced by whisper-stream on small models even after we dropped
-- -kc/-nf in 2026-04-28. Defense in depth: if the cause-fix ever regresses
-- (e.g. someone re-adds -kc), this still keeps the records.json sane.
-- See rpi/whisper-stream-runaway-loop/research.md.

local function collapse_runaway_loops(text, threshold)
    if not text or text == "" then return text, 0 end
    threshold = threshold or 5

    -- Split into words (whitespace-delimited). Keep punctuation attached.
    local words = {}
    for w in text:gmatch("%S+") do words[#words + 1] = w end
    local n = #words
    if n < threshold * 2 then return text, 0 end

    -- For each n-gram size from 1 to 4, scan left-to-right looking for
    -- the longest consecutive run of identical n-grams. When a run of
    -- length >= threshold is found, replace it with first occurrence
    -- plus a [...N× repeated...] marker, then restart scanning.
    local total_loops = 0
    for size = 1, 4 do
        local i = 1
        while i + size * threshold <= #words do
            -- Build candidate n-gram starting at i
            local cand = {}
            for k = 0, size - 1 do cand[k + 1] = words[i + k] end
            -- Count consecutive repetitions (including the first one)
            local reps = 1
            local j = i + size
            while j + size - 1 <= #words do
                local match = true
                for k = 0, size - 1 do
                    if words[j + k] ~= cand[k + 1] then match = false; break end
                end
                if not match then break end
                reps = reps + 1
                j = j + size
            end
            if reps >= threshold then
                -- Keep first occurrence, replace rest with marker
                local marker = "[..." .. (reps - 1) .. "x repeated...]"
                local new_words = {}
                for k = 1, i + size - 1 do new_words[#new_words + 1] = words[k] end
                new_words[#new_words + 1] = marker
                for k = j, #words do new_words[#new_words + 1] = words[k] end
                words = new_words
                total_loops = total_loops + 1
                -- Continue scanning after the marker
                i = i + size + 1
            else
                i = i + 1
            end
        end
    end

    if total_loops == 0 then return text, 0 end
    return table.concat(words, " "), total_loops
end

-- Apply dictionary corrections to text (company/product terms, names, etc.)
local function apply_corrections(text)
    if not corrections_cache then
        corrections_cache = load_corrections()
    end
    if #corrections_cache == 0 then return text end

    for _, pair in ipairs(corrections_cache) do
        local escaped = pair.wrong:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
        text = text:gsub(escaped, pair.right)
    end
    return text
end

-- Invalidate corrections cache (call after editing TSV)
function M.reloadCorrections()
    corrections_cache = nil
end

-- ============================================================================

-- Build confirmed text from completed and corrected sentences
local function build_display_text()
    local parts = {}
    for _, s in ipairs(sentences) do
        table.insert(parts, s.corrected or s.raw)
    end
    if current_fragment ~= "" then
        table.insert(parts, current_fragment)
    end
    return table.concat(parts, " "):match("^%s*(.-)%s*$") or ""
end

-- Update overlay with current confirmed + partial text
local function update_display()
    local overlay = require("whisper_overlay")
    local confirmed = build_display_text()
    overlay.update(confirmed, current_partial)
end

-- ============================================================================
-- COPILOT CORRECTION
-- ============================================================================

-- Send a sentence to Copilot for grammar/spelling correction
local function correct_sentence(index)
    if not copilot_token then
        log_event("copilot_skipped", { index = index, reason = "no_token" })
        return
    end

    sentences[index].status = "correcting"
    pending_corrections = pending_corrections + 1

    local raw = sentences[index].raw
    local req_start = dbg.t_ms()
    sentences[index].req_started_ms = req_start
    log_event("copilot_request", { index = index, raw = raw, chars = #raw })
    dbg.bumpCounter("copilot_requests", 1)

    local body = hs.json.encode({
        model = COPILOT_MODEL,
        messages = {
            {
                role = "system",
                content = "Fix any grammar, spelling, and punctuation errors in this transcribed speech. Keep the meaning identical. Output ONLY the corrected text, nothing else."
            },
            { role = "user", content = raw },
        },
        max_tokens = 1024,
        temperature = 0.1,
    })
    
    local headers = {
        ["Content-Type"] = "application/json",
        ["Authorization"] = "Bearer " .. copilot_token,
        ["Editor-Version"] = "vscode/1.120.0",
        ["Editor-Plugin-Version"] = "copilot-chat/0.35.0",
        ["Copilot-Integration-Id"] = "vscode-chat",
    }
    
    hs.http.asyncPost(COPILOT_API_URL, body, headers, function(status, response, _)
        pending_corrections = pending_corrections - 1
        local latency_ms = dbg.t_ms() - req_start

        if status == 200 and response then
            local ok, data = pcall(hs.json.decode, response)
            if ok and data and data.choices and data.choices[1] then
                local corrected = data.choices[1].message.content
                if corrected and corrected ~= "" then
                    local old_text = sentences[index].raw
                    local changed = corrected ~= old_text
                    sentences[index].corrected = corrected
                    sentences[index].status = "done"
                    update_display()

                    log_event("copilot_response", {
                        index      = index,
                        status     = status,
                        latency_ms = latency_ms,
                        raw        = old_text,
                        corrected  = corrected,
                        changed    = changed,
                        raw_chars  = #old_text,
                        corr_chars = #corrected,
                    })
                    if changed then dbg.bumpCounter("copilot_changed", 1) end

                    if changed then
                        local overlay = require("whisper_overlay")
                        overlay.flashCorrection(old_text, corrected)
                    end
                    return
                end
            end
        end

        -- On any error, keep raw text
        sentences[index].corrected = sentences[index].raw
        sentences[index].status = "done"
        update_display()
        log_event("copilot_error", {
            index      = index,
            status     = status,
            latency_ms = latency_ms,
            raw        = sentences[index].raw,
            response   = response and string.sub(response, 1, 500) or nil,
        })
        dbg.bumpCounter("copilot_errors", 1)
    end)
end

-- ============================================================================
-- STREAM OUTPUT PARSING
-- ============================================================================

-- Common whisper hallucinations to filter out (appears during silence)
local HALLUCINATION_PATTERNS = {
    "^%s*%[BLANK_AUDIO%]%s*$",
    "^%s*%[MUSIC%]%s*$",
    "^%s*%[INAUDIBLE%]%s*$",
    "^%s*%(upbeat music%)%s*$",
    "^%s*%(music%)%s*$",
    "^%s*%(silence%)%s*$",
    "^%s*%(background noise%)%s*$",
    "^%s*%(whooshing%)%s*$",
    "^%s*%(applause%)%s*$",
    "^%s*%(laughter%)%s*$",
    "^%s*%(sighing%)%s*$",
    "^%s*%(buzzing%)%s*$",
    "^%s*Thank you%.?%s*$",           -- Very common whisper hallucination
    "^%s*Thanks for watching%.?%s*$",  -- YouTube-style hallucination
    "^%s*Subs by.-$",                 -- Subtitle credit hallucination
    "^%s*you$",                        -- Single "you" is hallucination
    "^%s*$",                           -- Empty/whitespace-only
}

-- Check if text is a known whisper hallucination (whole-line match for live streaming)
local function is_hallucination(text)
    for _, pattern in ipairs(HALLUCINATION_PATTERNS) do
        if text:match(pattern) then return true end
    end
    -- Filter any text that's entirely in [brackets] or (parentheses)
    if text:match("^%s*%[.+%]%s*$") or text:match("^%s*%(.-%)%s*$") then
        return true
    end
    return false
end

-- Strip hallucination patterns from retranscribed text (inline, not whole-line)
-- Used on retranscribed output where [BLANK_AUDIO] etc. appear mid-text
local INLINE_HALLUCINATION_PATTERNS = {
    "%[BLANK_AUDIO%]",
    "%[MUSIC%]",
    "%[INAUDIBLE%]",
    "%(upbeat music%)",
    "%(music%)",
    "%(silence%)",
    "%(background noise%)",
    "%(whooshing%)",
    "%(applause%)",
    "%(laughter%)",
    "%(sighing%)",
    "%(buzzing%)",
    "Thanks for watching%.?",
    "Subs by[^%.]*%.",
}
local function strip_hallucinations(text)
    for _, pattern in ipairs(INLINE_HALLUCINATION_PATTERNS) do
        text = text:gsub(pattern, "")
    end
    -- Collapse multiple spaces left by removals
    text = text:gsub("  +", " ")
    -- Trim
    text = text:match("^%s*(.-)%s*$")
    return text
end

-- Flip overlay from "warming up" to "streaming" on first real transcription output.
-- Plays a short ready sound so the user knows it's safe to speak.
local function mark_ready(source)
    if first_output_received then return end
    first_output_received = true
    local warmup_ms = dbg.t_ms() - session_started_ms
    log_event("stream_ready", {
        source     = source,
        warmup_ms  = warmup_ms,
    })
    local overlay = require("whisper_overlay")
    pcall(function() overlay.setMode("streaming") end)
    -- Short, non-intrusive audible cue ("Tink" is ~50ms, pleasant).
    pcall(function() hs.sound.getByName("Tink"):play() end)
end

-- Parse whisper-stream stdout in real-time
-- Format: whisper-stream emits ANSI escape codes (\033[2K\r) followed by text
-- Newlines confirm a segment; text between newlines is partial
local function on_stream(task, stdout, stderr)
    if not stdout then return true end
    
    buffer = buffer .. stdout
    
    -- Split on newlines to get confirmed lines
    local confirmed_new = {}
    local last_nl = 0
    for i = 1, #buffer do
        if buffer:sub(i, i) == "\n" then
            table.insert(confirmed_new, buffer:sub(last_nl + 1, i - 1))
            last_nl = i
        end
    end
    buffer = buffer:sub(last_nl + 1)
    
    -- Process confirmed lines
    for _, line in ipairs(confirmed_new) do
        local clean = line:gsub("\27%[[%d;]*[A-Za-z]", "")
        local last_cr = clean:match(".*\r(.*)") or clean
        last_cr = last_cr:match("^%s*(.-)%s*$")

        if last_cr ~= "" then
            if is_hallucination(last_cr) then
                log_event("hallucination_filtered", { text = last_cr, phase = "confirmed" })
                dbg.bumpCounter("hallucinations", 1)
            else
                log_event("confirmed_chunk", { text = last_cr, chars = #last_cr })
                mark_ready("confirmed_chunk")
                current_fragment = current_fragment .. " " .. last_cr

                -- Check for sentence end (., ?, !)
                if last_cr:match("[%.%?!]%s*$") then
                    local sentence = current_fragment:match("^%s*(.-)%s*$")
                    table.insert(sentences, { raw = sentence, corrected = nil, status = "pending" })
                    current_fragment = ""
                    log_event("sentence_confirmed", {
                        index = #sentences, raw = sentence, chars = #sentence,
                        t_rel_ms = dbg.t_ms() - session_started_ms,
                    })
                    dbg.bumpCounter("sentences", 1)
                    correct_sentence(#sentences)
                end
            end
        end
    end

    -- Process partial (current incomplete line in buffer)
    local partial_clean = buffer:gsub("\27%[[%d;]*[A-Za-z]", "")
    local partial_latest = partial_clean:match(".*\r(.*)") or partial_clean
    current_partial = partial_latest:match("^%s*(.-)%s*$") or ""

    if is_hallucination(current_partial) then
        current_partial = ""
    end

    -- Log partials with debounce (only when text changed AND at most every 500ms)
    if current_partial ~= last_partial_logged then
        local now_ms = dbg.t_ms()
        if now_ms - last_partial_log_ms >= 500 then
            last_partial_log_ms = now_ms
            last_partial_logged = current_partial
            if current_partial ~= "" then
                dbg.bumpCounter("partials", 1)
                log_event("partial_update", {
                    text     = current_partial,
                    chars    = #current_partial,
                    t_rel_ms = now_ms - session_started_ms,
                })
                mark_ready("partial_update")
            end
        end
    end

    update_display()
    return true
end

-- ============================================================================
-- PUBLIC API
-- ============================================================================

-- Force-reset all state: terminate tasks, cancel timers, destroy overlay.
-- Used to recover from stuck sessions (e.g. retranscribe hang, orphan whisper-stream).
-- Safe to call at any time.
function M.forceReset(reason)
    log_event("force_reset", { reason = reason or "manual" })
    log_state("forceReset-before")

    if stop_hotkey then pcall(function() stop_hotkey:disable() end) end

    if stream_task then
        pcall(function() stream_task:terminate() end)
        stream_task = nil
    end
    if retranscribe_task then
        pcall(function() retranscribe_task:terminate() end)
        retranscribe_task = nil
    end
    if retranscribe_watchdog then
        pcall(function() retranscribe_watchdog:stop() end)
        retranscribe_watchdog = nil
    end
    if overlay_safety_timer then
        pcall(function() overlay_safety_timer:stop() end)
        overlay_safety_timer = nil
    end

    retranscribe_done = true
    stop_invoked = false
    buffer = ""
    sentences = {}
    current_fragment = ""
    current_partial = ""
    pending_corrections = 0

    local overlay_mod = package.loaded["whisper_overlay"] or require("whisper_overlay")
    pcall(function() overlay_mod.destroy() end)

    if set_indicator then pcall(function() set_indicator("idle") end) end

    -- If a debug session is still open, close it with a "force_reset" marker
    if dbg.currentSessionId() > 0 then
        dbg.setFallbackPath("force_reset")
        dbg.endSession({ ended_by = "force_reset", reason = reason })
    end

    log_state("forceReset-after")
end

-- Panic cleanup — same as forceReset but only runs if something looks stuck.
-- Returns true if it actually cleaned anything up.
function M.panicCleanupIfStuck()
    local overlay_mod = package.loaded["whisper_overlay"] or require("whisper_overlay")
    local overlay_stuck = overlay_mod.exists and overlay_mod.exists() or false
    local stream_orphan = stream_task ~= nil and (not stream_task.isRunning or not stream_task:isRunning())
    local retrans_orphan = retranscribe_task ~= nil and (not retranscribe_task.isRunning or not retranscribe_task:isRunning())

    if overlay_stuck or stream_orphan or retrans_orphan then
        log_event("panic_cleanup", {
            overlay_stuck  = overlay_stuck,
            stream_orphan  = stream_orphan,
            retrans_orphan = retrans_orphan,
        })
        M.forceReset("panic-cleanup")
        hs.alert.show("Whisper: cleaned stuck overlay", 1.5)
        return true
    end
    return false
end

-- Start streaming transcription
function M.start()
    session_id = session_id + 1
    log_event("start_enter", { session_id = session_id })
    log_state("start-enter")

    -- Auto-recover from stale state
    if stream_task then
        local running = false
        pcall(function() running = stream_task:isRunning() end)
        if not running then
            log_event("start_clearing_stale_task", {})
            stream_task = nil
        end
    end

    local overlay_mod = require("whisper_overlay")
    if overlay_mod.exists() or retranscribe_task ~= nil then
        log_event("start_pre_cleanup", {
            overlay_exists = overlay_mod.exists(),
            retrans_task   = retranscribe_task ~= nil,
        })
        M.forceReset("pre-start-cleanup")
    end

    if stream_task then
        log_event("start_already_running", {})
        hs.alert.show("Whisper: already streaming — press stop button", 2)
        return
    end

    -- Save target app for later paste
    target_app = hs.application.frontmostApplication()
    session_started_ms = dbg.t_ms()
    dbg.startSession("streaming", {
        target_app = target_app and target_app:name() or "<nil>",
        sdl_device = SDL_DEVICE_ID,
        stream_bin = WHISPER_STREAM_BIN,
    })
    log_event("start_requested", {
        target_app = target_app and target_app:name() or "<nil>",
    })

    -- Reset state
    buffer = ""
    sentences = {}
    current_fragment = ""
    current_partial = ""
    pending_corrections = 0
    retranscribe_done = false
    stop_invoked = false
    first_output_received = false

    -- Load Copilot token
    load_copilot_token()
    if not copilot_token then
        hs.alert.show("⚠ No Copilot token — corrections disabled", 2)
    end
    
    -- Pick model (prefer base.en for speed)
    local model = STREAM_MODEL
    local f = io.open(model, "r")
    if not f then
        model = FALLBACK_MODEL
    else
        f:close()
    end
    
    -- Create overlay in "warming up" state — tells the user NOT to speak yet.
    -- mark_ready() flips it to streaming on first real partial/confirmed chunk.
    local overlay = require("whisper_overlay")
    local overlay_ok = overlay.create()
    log("start(): overlay.create() returned " .. tostring(overlay_ok))
    pcall(function() overlay.setMode("warming") end)
    pcall(function() overlay.update("", "⏳ warming up — wait for the beep…") end)
    
    -- Build whisper-stream arguments.
    -- NOTE on warm-up: whisper-stream doesn't emit its first transcription until its
    -- rolling audio window is filled. A 5000ms --length gave us a 1.8–3.7s gap between
    -- launch and the first partial, during which the user was talking into silence.
    -- --length 3000 halves the buffer; --step 300 produces partials more often.
    -- The saved WAV is unaffected, so retranscribe quality stays identical.
    -- LOOPFIX 2026-04-28: dropped -kc and -nf. Together they were the cause of
    -- runaway "vent marking by vent marking by..." loops on long-form audio with
    -- the small base.en model. -kc fed each segment's output back as the next
    -- segment's prompt, and -nf disabled the temperature fallback that normally
    -- escapes degenerate outputs. See rpi/whisper-stream-runaway-loop/research.md
    -- and whisper.cpp issues #924, #3635, #3744. -bs 5 enables beam search,
    -- the most decoder-stability we can get without the cli-only thresholds.
    local args = {
        "-m", model,
        "-t", "4",              -- 4 threads
        "--step", "300",        -- Update every 300ms (was 500)
        "--length", "3000",     -- 3s audio window (was 5000) — shorter warm-up
        "--keep", "200",        -- Keep 200ms context
        "-bs", "5",             -- Beam search (more stable than greedy on small model)
        "-l", "en",             -- English
        "-fa",                  -- Fast mode
        "-c", tostring(SDL_DEVICE_ID),  -- SDL audio device
        "-sa",                  -- Save audio to WAV file
    }
    
    -- Ensure recordings directory exists
    hs.fs.mkdir(RECORDINGS_DIR)
    
    -- Launch whisper-stream
    stream_task = hs.task.new(
        WHISPER_STREAM_BIN,
        function(exitCode, stdOut, stdErr)  -- termination callback
            local unexpected = not stop_invoked
            log_event("stream_task_exit", {
                exit_code    = exitCode,
                stderr_len   = stdErr and #stdErr or 0,
                stderr       = stdErr and string.sub(stdErr, 1, 500) or nil,
                unexpected   = unexpected,
                duration_ms  = dbg.t_ms() - session_started_ms,
            })
            stream_task = nil

            if unexpected then
                log_event("stream_unexpected_auto_cleanup", {})
                if stop_hotkey then pcall(function() stop_hotkey:disable() end) end
                local ok, overlay = pcall(require, "whisper_overlay")
                if ok and overlay and overlay.exists and overlay.exists() then
                    hs.timer.doAfter(0.2, function()
                        pcall(function() overlay.destroy() end)
                    end)
                end
                if set_indicator then pcall(function() set_indicator("idle") end) end
                hs.alert.show("Whisper: stream stopped unexpectedly", 2)
                dbg.setFallbackPath("stream_unexpected_exit")
                dbg.endSession({ ended_by = "stream_unexpected", exit_code = exitCode })
            end
        end,
        on_stream,  -- stream callback
        args
    )

    if stream_task then
        stream_task:setWorkingDirectory(RECORDINGS_DIR)
    end

    if stream_task and stream_task:start() then
        log_event("stream_launched", {
            pid        = stream_task:pid(),
            model      = model,
            step_ms    = 300,
            length_ms  = 3000,
            keep_ms    = 200,
            sdl_device = SDL_DEVICE_ID,
        })
        hs.alert.show("Whisper: warming up — wait for the beep…", 1.5)
        if set_indicator then set_indicator("streaming") end

        -- Enable Enter key as alternative stop trigger
        if not stop_hotkey then
            stop_hotkey = hs.hotkey.new({}, "return", function()
                M.stop()
            end)
        end
        stop_hotkey:enable()
    else
        log_event("stream_launch_failed", {})
        hs.alert.show("Failed to start whisper-stream — check /tmp/whisper_debug.log", 3)
        pcall(function() overlay.destroy() end)
        stream_task = nil
        dbg.setFallbackPath("launch_failed")
        dbg.endSession({ error = "launch_failed" })
    end
    log_state("start-exit")
end

-- Stop streaming: retranscribe with higher-quality model, apply corrections, paste
function M.stop()
    log_event("stop_requested", {})
    log_state("stop-enter")

    if not stream_task then
        -- No active stream — several sub-cases:
        --   (a) Retranscribe is still running → user is double-tapping stop in panic
        --       because the first words were missed. DO NOT force-reset: the saved WAV
        --       already contains the full audio and retranscribe will recover it.
        --   (b) Overlay is stuck from a prior session → safe to force-cleanup.
        --   (c) Nothing to do.
        local retrans_running = retranscribe_task ~= nil
        if retrans_running then
            pcall(function() retrans_running = retranscribe_task:isRunning() end)
        end
        if retrans_running then
            log_event("stop_ignored_retrans_running", {
                reason = "double_stop_while_retranscribing",
            })
            hs.alert.show("Still retranscribing — please wait for the improved text…", 2)
            return
        end

        local overlay_mod = require("whisper_overlay")
        if overlay_mod.exists() then
            log_event("stop_panic_cleanup", { reason = "no_stream_task_overlay_exists" })
            M.forceReset("stop-on-no-stream")
        else
            log_event("stop_noop", {})
        end
        return
    end

    -- Mark stop() as user-initiated so the task termination callback doesn't
    -- treat it as an unexpected exit (which would double-clean the overlay).
    stop_invoked = true

    -- Disable Enter hotkey immediately (prevents double-stop)
    if stop_hotkey then stop_hotkey:disable() end

    -- Immediate visual feedback: user knows the button press registered
    local overlay = require("whisper_overlay")
    overlay.setMode("processing")
    hs.alert.show("Processing...", 1.5)

    -- Terminate whisper-stream
    stream_task:terminate()
    stream_task = nil
    hs.printf("Whisper streaming: audio saved to %s/", RECORDINGS_DIR)

    -- Promote any remaining partial (gray) text into the fragment
    if current_partial and current_partial:match("%S") and not is_hallucination(current_partial) then
        current_fragment = current_fragment .. " " .. current_partial
        current_partial = ""
    end

    -- Handle any remaining fragment as a sentence
    if current_fragment:match("%S") then
        local sentence = current_fragment:match("^%s*(.-)%s*$")
        table.insert(sentences, { raw = sentence, corrected = sentence, status = "done" })
        current_fragment = ""
    end

    -- Show live text as confirmed (white) + retranscribe status (gray)
    local overlay = require("whisper_overlay")
    local live_text = build_display_text()
    overlay.update(live_text, "⏳ Retranscribing for quality...")

    if set_indicator then set_indicator("transcribing") end

    -- Log live transcription stats
    local total_sentences = #sentences
    local corrected_count = 0
    for _, s in ipairs(sentences) do
        if s.corrected and s.corrected ~= s.raw then
            corrected_count = corrected_count + 1
        end
    end
    dbg.recordText("live_text_final", live_text)
    log_event("live_transcription_complete", {
        sentences       = total_sentences,
        corrected       = corrected_count,
        chars           = #live_text,
        live_text       = live_text,
        duration_ms     = dbg.t_ms() - session_started_ms,
    })

    -- Helper: paste text, close overlay, reset indicator
    local function paste_and_cleanup(text, source_tag)
        dbg.setFallbackPath(source_tag or "unknown")
        dbg.recordText("final_text", text)
        log_event("paste", {
            source     = source_tag,
            chars      = #(text or ""),
            target_app = target_app and target_app:name() or "<nil>",
            text       = text,
        })
        hs.pasteboard.setContents(text)
        hs.timer.doAfter(0.3, function()
            if target_app then
                target_app:activate()
                hs.timer.doAfter(0.15, function()
                    hs.eventtap.keyStroke({"cmd"}, "v")
                end)
            end
        end)
        hs.timer.doAfter(OVERLAY_CLEANUP_DELAY_S, function()
            log_event("paste_cleanup_destroy_overlay", {})
            pcall(function() overlay.destroy() end)
            if overlay_safety_timer then pcall(function() overlay_safety_timer:stop() end); overlay_safety_timer = nil end
            dbg.endSession({ ended_by = "paste_cleanup" })
        end)
        if set_indicator then set_indicator("idle") end

        -- Last-resort safety: if paste chain fails for any reason, kill overlay after 8s.
        if overlay_safety_timer then pcall(function() overlay_safety_timer:stop() end) end
        overlay_safety_timer = hs.timer.doAfter(8.0, function()
            if overlay.exists and overlay.exists() then
                log_event("paste_safety_fire", { note = "overlay still alive 8s after paste" })
                pcall(function() overlay.destroy() end)
                dbg.endSession({ ended_by = "safety_timer" })
            end
            overlay_safety_timer = nil
        end)
    end

    -- Helper: wrap text with LLM-aware transcription metadata
    local function wrap_transcript(text)
        return TRANSCRIPT_PREFIX .. "\n" .. text
    end

    -- Compute recording duration and the pre-corrected live text once.
    -- LOOPFIX 2026-04-28: collapse_runaway_loops runs FIRST, before dict + hallucination
    -- strip, so a corrupted live_text can't poison records.json. See research.md.
    local live_duration_s = (dbg.t_ms() - session_started_ms) / 1000.0
    local live_collapsed, n_loops = collapse_runaway_loops(live_text, 5)
    if n_loops > 0 then
        log_event("loop_collapsed", {
            n_loops      = n_loops,
            before_chars = #live_text,
            after_chars  = #live_collapsed,
            duration_s   = live_duration_s,
        })
    end
    local live_after_corrections = strip_hallucinations(apply_corrections(live_collapsed))
    local skip_retranscribe = live_duration_s < SKIP_RETRANSCRIBE_UNDER_S
    local use_instant       = INSTANT_PASTE_ON_STOP and (not skip_retranscribe)

    log_event("stop_path_decision", {
        duration_s            = live_duration_s,
        skip_retranscribe     = skip_retranscribe,
        instant_paste         = use_instant,
        skip_threshold_s      = SKIP_RETRANSCRIBE_UNDER_S,
        instant_enabled_flag  = INSTANT_PASTE_ON_STOP,
    })

    -- Short clip: skip the batch re-run entirely and just paste live text.
    if skip_retranscribe then
        overlay.update(live_after_corrections, "⚡ Short clip — using live text")
        paste_and_cleanup(wrap_transcript(live_after_corrections), "skip_retranscribe_short")
        return
    end

    -- Instant-paste mode: paste the live text NOW (user sees stop as instant),
    -- close overlay quickly, then continue with retranscribe in the background;
    -- the callback will silently replace the clipboard with the improved version.
    if use_instant then
        local instant_text = wrap_transcript(live_after_corrections)
        log_event("instant_paste_live", {
            chars      = #instant_text,
            target_app = target_app and target_app:name() or "<nil>",
            text       = instant_text,
        })
        dbg.setFallbackPath("instant_live")
        dbg.recordText("instant_live_text", instant_text)
        hs.pasteboard.setContents(instant_text)
        hs.timer.doAfter(0.3, function()
            if target_app then
                target_app:activate()
                hs.timer.doAfter(0.15, function()
                    hs.eventtap.keyStroke({"cmd"}, "v")
                end)
            end
        end)
        overlay.update(live_after_corrections, "⚡ Pasted live • improving in background...")
        hs.timer.doAfter(OVERLAY_CLEANUP_DELAY_S, function()
            log_event("instant_paste_overlay_close", {})
            pcall(function() overlay.destroy() end)
        end)
        if set_indicator then set_indicator("idle") end
    end

    -- Reset retranscribe state
    retranscribe_done = false

    -- Brief delay to let whisper-stream flush and close its WAV file after SIGTERM
    hs.timer.doAfter(STOP_FLUSH_DELAY_S, function()
        log_event("retranscribe_launch", {
            cmd           = WHISPER_SH .. " retranscribe",
            instant_mode  = use_instant,
            flush_delay_s = STOP_FLUSH_DELAY_S,
        })
        local retrans_start_ms = dbg.t_ms()

        -- Helper: end-of-session cleanup in instant mode (clipboard already replaced)
        local function instant_finish(reason)
            log_event("instant_retranscribe_done", { ended_by = reason })
            if set_indicator then set_indicator("idle") end
            -- Overlay already closed quickly above, but make sure.
            if overlay.exists and overlay.exists() then
                pcall(function() overlay.destroy() end)
            end
            if overlay_safety_timer then pcall(function() overlay_safety_timer:stop() end); overlay_safety_timer = nil end
            dbg.endSession({ ended_by = reason })
        end

        retranscribe_task = hs.task.new(
            "/bin/bash",
            function(exitCode, stdOut, stdErr)
                local latency_ms = dbg.t_ms() - retrans_start_ms
                log_event("retranscribe_exit", {
                    exit_code  = exitCode,
                    latency_ms = latency_ms,
                    done_flag  = retranscribe_done,
                    stderr     = stdErr and string.sub(stdErr, 1, 500) or nil,
                })
                if retranscribe_done then
                    log_event("retranscribe_callback_skipped", { reason = "timeout_already_fired" })
                    return
                end
                retranscribe_done = true
                retranscribe_task = nil
                if retranscribe_watchdog then pcall(function() retranscribe_watchdog:stop() end); retranscribe_watchdog = nil end

                if exitCode == 0 then
                    local f = io.open(TEXT_FILE, "r")
                    if f then
                        local text = f:read("*a")
                        f:close()
                        local raw_text = (text or ""):match("^%s*(.-)%s*$")

                        if raw_text and raw_text ~= "" then
                            local before_hall = raw_text
                            local after_hall  = strip_hallucinations(raw_text)
                            local hall_removed = (#before_hall - #after_hall) > 0
                            local before_dict = after_hall
                            local after_dict  = apply_corrections(after_hall)
                            local dict_changed = before_dict ~= after_dict

                            dbg.recordText("retrans_text", after_dict)
                            log_event("retranscribe_text", {
                                raw                = raw_text,
                                after_hallucinations = after_hall,
                                after_dictionary   = after_dict,
                                chars_raw          = #raw_text,
                                chars_final        = #after_dict,
                                hallucination_stripped = hall_removed,
                                dictionary_applied = dict_changed,
                            })
                            if dict_changed then dbg.bumpCounter("dict_corrections", 1) end

                            local improved = wrap_transcript(after_dict)
                            if use_instant then
                                local prev = wrap_transcript(live_after_corrections)
                                local changed = improved ~= prev
                                dbg.setFallbackPath("retranscribe_background")
                                dbg.recordText("final_text", improved)
                                -- Plan 2 A3 (2026-04-23): CAS-style clipboard
                                -- replace. Only overwrite if the clipboard still
                                -- contains the live-pasted text we put there.
                                -- If user copied something else in between, do
                                -- NOT clobber it; instead alert with a manual
                                -- copy hint.
                                local current_cb = hs.pasteboard.getContents() or ""
                                local cb_owned = (current_cb == prev)
                                log_event("clipboard_replace_improved", {
                                    source       = "retranscribe_background",
                                    chars        = #improved,
                                    text         = improved,
                                    changed      = changed,
                                    prev         = prev,
                                    cb_owned     = cb_owned,
                                    cb_current_chars = #current_cb,
                                })
                                if cb_owned then
                                    hs.pasteboard.setContents(improved)
                                    if changed then
                                        hs.alert.show("✓ Improved transcript in clipboard (⌘V to replace)", 1.8)
                                    else
                                        hs.alert.show("✓ Retranscribe matched live text", 1.0)
                                    end
                                else
                                    -- User clipboard contains something else now.
                                    -- Do not clobber. Surface the improved text via alert.
                                    log_event("clipboard_replace_skipped_user_owned", {
                                        improved_chars = #improved,
                                    })
                                    hs.alert.show("✓ Improved transcript ready (clipboard busy — use middle button to fetch)", 2.5)
                                end
                                instant_finish("instant_paste_retranscribe")
                            else
                                overlay.update(after_dict, "✓ Retranscribed")
                                paste_and_cleanup(improved, "retranscribe")
                            end
                            return
                        else
                            log_event("retranscribe_empty_output", {})
                        end
                    else
                        log_event("retranscribe_read_failed", { path = TEXT_FILE })
                    end
                end

                -- Retranscribe failed or empty
                local fallback = live_after_corrections
                log_event("retranscribe_fallback", {
                    reason       = exitCode == 0 and "empty_output" or ("exit_" .. tostring(exitCode)),
                    fallback     = fallback,
                    chars        = #fallback,
                    instant_mode = use_instant,
                })
                if use_instant then
                    -- Live text already pasted; nothing to change. Just end session.
                    instant_finish("instant_paste_fallback")
                else
                    hs.alert.show("Retranscribe issue — using live text", 2)
                    overlay.update(fallback, "⚠ Using live text")
                    paste_and_cleanup(wrap_transcript(fallback), "fallback_live_text")
                end
            end,
            {"-c", "WHISPER_FORCE_NO_PASTE=1 '" .. WHISPER_SH .. "' retranscribe"}
        )

        if retranscribe_task then
            retranscribe_task:start()
            log_event("retranscribe_started", { pid = retranscribe_task:pid() })

            if retranscribe_watchdog then pcall(function() retranscribe_watchdog:stop() end) end
            retranscribe_watchdog = hs.timer.doAfter(RETRANSCRIBE_TIMEOUT, function()
                retranscribe_watchdog = nil
                if not retranscribe_done then
                    retranscribe_done = true
                    log_event("retranscribe_timeout", { timeout_s = RETRANSCRIBE_TIMEOUT, instant_mode = use_instant })
                    if retranscribe_task and retranscribe_task:isRunning() then
                        pcall(function() retranscribe_task:terminate() end)
                        retranscribe_task = nil
                    end
                    if use_instant then
                        -- Live text already pasted; just close session silently.
                        instant_finish("instant_paste_timeout")
                    else
                        hs.alert.show("Retranscribe timeout — using live text", 2)
                        local fallback = live_after_corrections
                        overlay.update(fallback, "⚠ Timeout")
                        paste_and_cleanup(wrap_transcript(fallback), "fallback_timeout")
                    end
                end
            end)
        else
            log_event("retranscribe_task_create_nil", { instant_mode = use_instant })
            retranscribe_done = true
            if use_instant then
                instant_finish("instant_paste_task_create_nil")
            else
                hs.alert.show("Cannot retranscribe — using live text", 2)
                local fallback = live_after_corrections
                paste_and_cleanup(wrap_transcript(fallback), "fallback_task_create_nil")
            end
        end
    end)
end

-- Check if streaming is active
function M.isStreaming()
    return stream_task ~= nil
end

-- Pre-warm Metal kernels at Hammerspoon load.
-- Whisper.cpp on Apple Silicon JIT-compiles Metal shaders on first invocation,
-- which costs ~0.3–0.8 s of added latency on the FIRST recording each session.
-- Running a one-shot whisper-cli on a 0.5 s silent WAV moves that cost out of
-- the user's first hotkey press into Hammerspoon startup (where it's invisible).
-- Safe to call multiple times; subsequent calls are cheap.
function M.preWarm()
    local WHISPER_CLI = "/opt/homebrew/bin/whisper-cli"
    local tmpdir = os.getenv("TMPDIR") or "/tmp/"
    if not tmpdir:match("/$") then tmpdir = tmpdir .. "/" end
    local silent_wav = tmpdir .. "whisper_prewarm.wav"

    -- Generate 0.5 s of silence if not present (44-byte header + 16000 samples of zeros)
    local f = io.open(silent_wav, "rb")
    if f then f:close() else
        local gen_ok = os.execute(
            "/opt/homebrew/bin/ffmpeg -y -f lavfi -i anullsrc=r=16000:cl=mono -t 0.5 " ..
            "-acodec pcm_s16le '" .. silent_wav .. "' >/dev/null 2>&1"
        )
        if not (gen_ok == true or gen_ok == 0) then
            log_event("prewarm_skipped", { reason = "silent_wav_gen_failed" })
            return
        end
    end

    -- Pick same base.en model used by live streaming so shader specialization matches.
    local model = STREAM_MODEL
    local mf = io.open(model, "r")
    if not mf then
        model = FALLBACK_MODEL
    else
        mf:close()
    end

    local start_ms = dbg.t_ms()
    log_event("prewarm_start", { model = model, wav = silent_wav })

    local task = hs.task.new(WHISPER_CLI, function(exitCode, _, _)
        log_event("prewarm_done", {
            exit_code   = exitCode,
            elapsed_ms  = dbg.t_ms() - start_ms,
            model       = model,
        })
    end, function(_, _, _) return true end, {
        "-m", model,
        "-f", silent_wav,
        "-t", "4",
        "-l", "en",
        "-nt",              -- no timestamps (less stdout)
        "-fa",              -- fast mode (matches streaming)
    })
    if task then pcall(function() task:start() end) end
end

return M
