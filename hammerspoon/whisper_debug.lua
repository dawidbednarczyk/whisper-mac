-- whisper_debug.lua
-- Centralized debug logging for the Whisper streaming / batch / retranscribe pipeline.
--
-- Three outputs:
--   1) /tmp/whisper_debug.log                         — rolling JSON-lines event log (always on)
--   2) /tmp/whisper_debug/session_<ISO>_s<id>.log     — per-session detail log (one per streaming/batch session)
--   3) /tmp/whisper_debug/session_<ISO>_s<id>.summary.json — quality summary written at endSession()
--
-- Event shape (one JSON object per line):
--   { "ts":"2026-04-17T11:38:46.123", "t_ms":1743501526123, "sid":1, "mod":"streaming",
--     "event":"sentence_confirmed", "text":"...", "latency_ms":234, ... }
--
-- All values are optional except ts, mod, event. Free-form key/value pairs are preserved.
--
-- Privacy note: voice transcription text is written verbatim to /tmp — this is intentional
-- for post-hoc troubleshooting. Clear /tmp/whisper_debug*.log when that's undesirable.

local M = {}

-- ---------------------------------------------------------------------------
-- Paths
-- ---------------------------------------------------------------------------
local MAIN_LOG      = "/tmp/whisper_debug.log"
local SESSION_DIR   = "/tmp/whisper_debug"
os.execute("mkdir -p '" .. SESSION_DIR .. "'")

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
local current_session = nil   -- table: { id, kind, started_at, session_log_path, summary_path, counters, meta }
local session_counter = 0

-- ---------------------------------------------------------------------------
-- Time helpers (millisecond precision)
-- ---------------------------------------------------------------------------
local function now_s()
    -- Hammerspoon provides fractional seconds via hs.timer.secondsSinceEpoch()
    if hs and hs.timer and hs.timer.secondsSinceEpoch then
        return hs.timer.secondsSinceEpoch()
    end
    return os.time()
end

local function iso_ts(t)
    t = t or now_s()
    local secs = math.floor(t)
    local ms   = math.floor((t - secs) * 1000 + 0.5)
    return os.date("!%Y-%m-%dT%H:%M:%S", secs) .. string.format(".%03dZ", ms)
end

local function t_ms(t)
    return math.floor((t or now_s()) * 1000 + 0.5)
end

M.now_s = now_s
M.iso_ts = iso_ts
M.t_ms = t_ms

-- ---------------------------------------------------------------------------
-- JSON encoding (prefer hs.json; fall back to a tiny encoder if unavailable)
-- ---------------------------------------------------------------------------
local function fallback_json_encode(v)
    local t = type(v)
    if t == "nil" then return "null"
    elseif t == "boolean" then return v and "true" or "false"
    elseif t == "number" then
        if v ~= v then return "null" end                -- NaN
        if v == math.huge or v == -math.huge then return "null" end
        return tostring(v)
    elseif t == "string" then
        local esc = v:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
        esc = esc:gsub('[%z\1-\31]', function(c) return string.format('\\u%04x', c:byte()) end)
        return '"' .. esc .. '"'
    elseif t == "table" then
        -- Detect array vs object
        local is_array = true
        local n = 0
        for k, _ in pairs(v) do
            n = n + 1
            if type(k) ~= "number" or k ~= math.floor(k) or k < 1 then is_array = false end
        end
        if is_array and n == #v then
            local parts = {}
            for i = 1, n do parts[#parts+1] = fallback_json_encode(v[i]) end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            local parts = {}
            for k, val in pairs(v) do
                parts[#parts+1] = fallback_json_encode(tostring(k)) .. ":" .. fallback_json_encode(val)
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    end
    return '"<unserializable:' .. t .. '>"'
end

local function json_encode(v)
    if hs and hs.json and hs.json.encode then
        local ok, s = pcall(hs.json.encode, v)
        if ok and s then return s end
    end
    return fallback_json_encode(v)
end

-- ---------------------------------------------------------------------------
-- Core writers
-- ---------------------------------------------------------------------------
local function append(path, line)
    local f = io.open(path, "a")
    if not f then return end
    f:write(line)
    f:close()
end

-- Build one event record (table) from module, event, and optional data table.
local function build_event(module_name, event_name, data)
    local t = now_s()
    local evt = {
        ts     = iso_ts(t),
        t_ms   = t_ms(t),
        sid    = current_session and current_session.id or 0,
        kind   = current_session and current_session.kind or "none",
        mod    = module_name,
        event  = event_name,
    }
    if type(data) == "table" then
        for k, v in pairs(data) do
            if evt[k] == nil then evt[k] = v end
        end
    elseif data ~= nil then
        evt.detail = tostring(data)
    end
    return evt
end

-- Public: emit an event. Writes to main log always, and to session log if a session is open.
-- @param module_name string   "streaming" | "overlay" | "mouse" | "batch" | ...
-- @param event_name  string   short snake_case event id
-- @param data        table?   optional free-form key/value pairs
function M.event(module_name, event_name, data)
    local evt = build_event(module_name, event_name, data)
    local line = json_encode(evt) .. "\n"
    append(MAIN_LOG, line)
    if current_session and current_session.session_log_path then
        append(current_session.session_log_path, line)
    end
    -- Also mirror to Hammerspoon console at a terse level for live debugging
    if hs and hs.printf then
        hs.printf("[whisper][%s] %s %s", module_name, event_name,
                  data and json_encode(data) or "")
    end
    return evt
end

-- Human-readable helper (kept for code that doesn't want to pass a table)
function M.log(module_name, message)
    return M.event(module_name, "log", { msg = tostring(message) })
end

-- ---------------------------------------------------------------------------
-- Session lifecycle
-- ---------------------------------------------------------------------------
-- Start a session (streaming or batch). Creates a detail log file and returns session id.
-- @param kind string   "streaming" | "batch" | "retranscribe"
-- @param meta table?   initial metadata (model, device, target_app, ...)
function M.startSession(kind, meta)
    session_counter = session_counter + 1
    local t = now_s()
    local stamp = os.date("!%Y%m%dT%H%M%S", math.floor(t))
    local sess = {
        id                = session_counter,
        kind              = kind or "unknown",
        started_at        = t,
        started_iso       = iso_ts(t),
        session_log_path  = string.format("%s/session_%s_s%d.log", SESSION_DIR, stamp, session_counter),
        summary_path      = string.format("%s/session_%s_s%d.summary.json", SESSION_DIR, stamp, session_counter),
        counters = {
            partials           = 0,
            sentences          = 0,
            copilot_requests   = 0,
            copilot_errors     = 0,
            copilot_changed    = 0,
            hallucinations     = 0,
            dict_corrections   = 0,
            fallback_path      = nil,
        },
        meta = meta or {},
        live_text_final   = "",
        retrans_text      = "",
        final_text        = "",
    }
    current_session = sess
    M.event("debug", "session_start", {
        kind               = sess.kind,
        session_log        = sess.session_log_path,
        meta               = sess.meta,
    })
    return sess.id
end

-- Convenience: get the live session counters table (or nil).
function M.counters()
    return current_session and current_session.counters or nil
end

function M.currentSessionId()
    return current_session and current_session.id or 0
end

function M.recordText(field, text)
    if not current_session then return end
    if field == "live_text_final" or field == "retrans_text" or field == "final_text" then
        current_session[field] = text or ""
    end
end

function M.setFallbackPath(tag)
    if not current_session then return end
    current_session.counters.fallback_path = tag
end

function M.bumpCounter(name, delta)
    if not current_session then return end
    local c = current_session.counters
    if c[name] == nil then c[name] = 0 end
    c[name] = c[name] + (delta or 1)
end

-- End the session. Writes quality summary. Returns summary table.
-- @param extra table?   merged into summary
function M.endSession(extra)
    if not current_session then return nil end
    local sess = current_session
    local t = now_s()
    local duration_s = t - sess.started_at
    local live_chars = #(sess.live_text_final or "")
    local retr_chars = #(sess.retrans_text or "")
    local final_chars = #(sess.final_text or "")
    local summary = {
        sid              = sess.id,
        kind             = sess.kind,
        started_at       = sess.started_iso,
        ended_at         = iso_ts(t),
        duration_s       = math.floor(duration_s * 1000 + 0.5) / 1000,
        counters         = sess.counters,
        live_text_final  = sess.live_text_final,
        retrans_text     = sess.retrans_text,
        final_text       = sess.final_text,
        live_text_chars  = live_chars,
        retrans_chars    = retr_chars,
        final_chars      = final_chars,
        meta             = sess.meta,
        session_log      = sess.session_log_path,
    }
    if type(extra) == "table" then
        for k, v in pairs(extra) do summary[k] = v end
    end
    append(sess.summary_path, json_encode(summary) .. "\n")
    M.event("debug", "session_end", {
        duration_s       = summary.duration_s,
        sentences        = sess.counters.sentences,
        copilot_requests = sess.counters.copilot_requests,
        copilot_errors   = sess.counters.copilot_errors,
        hallucinations   = sess.counters.hallucinations,
        dict_corrections = sess.counters.dict_corrections,
        fallback_path    = sess.counters.fallback_path,
        final_chars      = final_chars,
        summary_path     = sess.summary_path,
    })
    current_session = nil
    return summary
end

-- ---------------------------------------------------------------------------
-- Banner on module load (helps humans find "where did today's session start?")
-- ---------------------------------------------------------------------------
append(MAIN_LOG, json_encode(build_event("debug", "module_loaded", {
    host   = os.getenv("HOST") or os.getenv("HOSTNAME") or "?",
    user   = os.getenv("USER") or "?",
    pid    = (hs and hs.processInfo and hs.processInfo.processID) or -1,
})) .. "\n")

return M
