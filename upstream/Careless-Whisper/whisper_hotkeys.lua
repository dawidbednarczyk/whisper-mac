-- Whisper speech-to-text hotkeys for Hammerspoon
-- Hotkeys are configured in whisper-stt.conf — reload Hammerspoon to apply changes.

local home = os.getenv("HOME")
-- Paths are set automatically by install.sh
local whisper_script = (os.getenv("WHISPER_HOME") or (home .. "/whisper-mac")) .. "/upstream/Careless-Whisper/whisper.sh"
local conf_file      = (os.getenv("WHISPER_HOME") or (home .. "/whisper-mac")) .. "/upstream/Careless-Whisper/whisper-stt.conf"

-- Read a value from whisper-stt.conf
local function read_conf(key, default)
    if not key:match("^[%w_]+$") then return default end
    local handle = io.popen(
        "bash -c '. " .. conf_file .. " 2>/dev/null && printf \"%s\" \"${" .. key .. ":-}\"'"
    )
    if not handle then return default end
    local val = handle:read("*l")
    handle:close()
    return (val and val ~= "") and val or default
end

-- Parse "shift,cmd,r" → mods {"shift","cmd"}, key "r"
local function parse_hotkey(str)
    local parts = {}
    for p in str:gmatch("[^,]+") do
        parts[#parts + 1] = p:match("^%s*(.-)%s*$")
    end
    local key = table.remove(parts)
    return parts, key
end

local toggle_hotkey_conf = read_conf("WHISPER_HOTKEY_TOGGLE", "shift,cmd,r")
local stop_hotkey_conf   = read_conf("WHISPER_HOTKEY_STOP",   "shift,cmd,q")
local toggle_mods, toggle_key = nil, nil
local stop_mods,   stop_key   = nil, nil

if toggle_hotkey_conf ~= "disabled" and toggle_hotkey_conf ~= "" then
    toggle_mods, toggle_key = parse_hotkey(toggle_hotkey_conf)
end

if stop_hotkey_conf ~= "disabled" and stop_hotkey_conf ~= "" then
    stop_mods, stop_key = parse_hotkey(stop_hotkey_conf)
end

local status_item = hs.menubar.new()

local function alert(msg, duration)
    hs.alert.show(msg, duration)
end

local script_dir  = whisper_script:match("(.+)/[^/]+$") or "."
local model_dir   = script_dir .. "/models"
local auth_file   = home .. "/.config/careless-whisper/auth.json"

-- Check if Copilot auth token exists
local function has_copilot_token()
    local f = io.open(auth_file, "r")
    if not f then return false end
    local content = f:read("*a")
    f:close()
    local token = content:match('"access_token"%s*:%s*"([^"]+)"')
    return token and #token > 10
end
local history_file = read_conf("WHISPER_HISTORY_FILE", script_dir .. "/history.txt")

local spinner_frames = {"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}
local pp_spinner_frames = {"◰", "◳", "◲", "◱"}
local spinner_index = 1
local spinner_timer = nil
local recording_start = nil
local recording_display_timer = nil
local current_state = "idle"
local status_poll_running = false

local function format_duration(seconds)
    local m = math.floor(seconds / 60)
    local s = seconds % 60
    return string.format("%d:%02d", m, s)
end

local function start_spinner(frames, tooltip)
    if spinner_timer then return end
    local f = frames or spinner_frames
    local tip = tooltip or "Whisper: transcribing..."
    spinner_timer = hs.timer.doEvery(0.12, function()
        if status_item then
            status_item:setTitle(f[spinner_index])
            status_item:setTooltip(tip)
        end
        spinner_index = (spinner_index % #f) + 1
    end)
end

local function stop_spinner()
    if spinner_timer then
        spinner_timer:stop()
        spinner_timer = nil
    end
    spinner_index = 1
end

function set_indicator(state)
    if not status_item then return end
    current_state = state

    if state == "streaming" then
        stop_spinner()
        if not recording_start then
            recording_start = os.time()
        end
        if not recording_display_timer then
            local elapsed = os.time() - recording_start
            status_item:setTitle("◉ " .. format_duration(elapsed))
            status_item:setTooltip("Whisper: streaming live")
            recording_display_timer = hs.timer.doEvery(1.0, function()
                if recording_start and status_item then
                    local e = os.time() - recording_start
                    status_item:setTitle("◉ " .. format_duration(e))
                end
            end)
        end
    elseif state == "postprocessing" then
        if recording_display_timer then recording_display_timer:stop(); recording_display_timer = nil end
        recording_start = nil
        stop_spinner()
        start_spinner(pp_spinner_frames, "Whisper: post-processing...")
    elseif state == "transcribing" then
        if recording_display_timer then recording_display_timer:stop(); recording_display_timer = nil end
        recording_start = nil
        start_spinner()
    elseif state == "recording" then
        stop_spinner()
        if not recording_start then
            recording_start = os.time()
        end
        -- Dedicated 1-second timer for smooth elapsed counter
        if not recording_display_timer then
            local elapsed = os.time() - recording_start
            status_item:setTitle("● " .. format_duration(elapsed))
            status_item:setTooltip("Whisper: recording")
            recording_display_timer = hs.timer.doEvery(1.0, function()
                if recording_start and status_item then
                    local e = os.time() - recording_start
                    status_item:setTitle("● " .. format_duration(e))
                end
            end)
        end
    else
        stop_spinner()
        if recording_display_timer then recording_display_timer:stop(); recording_display_timer = nil end
        recording_start = nil
        status_item:setTitle("○")
        status_item:setTooltip("Whisper: idle")
    end
end

local function update_indicator()
    if status_poll_running then return end
    status_poll_running = true

    local task = hs.task.new(whisper_script, function(exit_code, std_out, _)
        status_poll_running = false
        if exit_code == 0 and std_out then
            if std_out:match("postprocessing:%s+yes") then
                set_indicator("postprocessing")
            elseif std_out:match("transcribing:%s+yes") then
                set_indicator("transcribing")
            elseif std_out:match("recording:%s+running") then
                set_indicator("recording")
            else
                set_indicator("idle")
            end
        end
        -- On poll failure, keep current state instead of resetting to idle
        return false
    end, {"status"})

    if task then
        task:start()
    else
        status_poll_running = false
    end
end

local whisper_busy = false
local whisper_busy_safety = nil

function run_whisper(action)
    if action == "toggle" and whisper_busy then
        alert("Whisper: transcription in progress…")
        return
    end

    -- Optimistic UI: show spinner immediately when stopping recording
    if current_state == "recording" and (action == "toggle" or action == "stop") then
        set_indicator("transcribing")
    end

    whisper_busy = true
    -- Safety net: auto-reset after 10 min in case the callback never fires
    if whisper_busy_safety then whisper_busy_safety:stop() end
    whisper_busy_safety = hs.timer.doAfter(600, function()
        whisper_busy = false
        whisper_busy_safety = nil
    end)

    local task = hs.task.new(whisper_script, function()
        whisper_busy = false
        if whisper_busy_safety then whisper_busy_safety:stop(); whisper_busy_safety = nil end
        hs.timer.doAfter(0.4, update_indicator)
        -- Post-transcription microphone health check (non-blocking, after paste)
        if action == "stop" and whisperCheckMicrophone then
            hs.timer.doAfter(1.0, whisperCheckMicrophone)
        end
        return false
    end, {action})

    if task then
        task:start()
    else
        whisper_busy = false
        if whisper_busy_safety then whisper_busy_safety:stop(); whisper_busy_safety = nil end
        hs.notify.new({
            title = "Whisper",
            informativeText = "Failed to create task for " .. action
        }):send()
    end
end

local function read_history()
    local entries = {}
    local f = io.open(history_file, "r")
    if not f then return entries end
    for line in f:lines() do
        local ts, text = line:match("^%[(.-)%]%s+(.+)$")
        if ts and text then
            entries[#entries + 1] = { timestamp = ts, text = text }
        end
    end
    f:close()
    return entries
end

local function list_models()
    local models = {}
    local ok, result = pcall(function()
        for name in hs.fs.dir(model_dir) do
            if name:match("%.bin$") then
                models[#models + 1] = name
            end
        end
    end)
    if not ok then return {} end
    table.sort(models)
    return models
end

local function get_active_model()
    local path = read_conf("WHISPER_MODEL_PATH", "")
    if path == "" then return "" end
    return path:match("([^/]+)$") or path
end

local download_in_progress = {}
local download_progress_timer = nil

local function stop_download_progress()
    if download_progress_timer then
        download_progress_timer:stop()
        download_progress_timer = nil
    end
    -- Only restore idle menubar if not recording/transcribing
    if current_state ~= "recording" and current_state ~= "transcribing" then
        if status_item then
            status_item:setTitle("○")
            status_item:setTooltip("Whisper: idle")
        end
    end
end

local function start_download_progress(model_name, part_path)
    stop_download_progress()
    local display = model_name:gsub("^ggml%-", ""):gsub("%.bin$", "")
    download_progress_timer = hs.timer.doEvery(1.5, function()
        local f = io.open(part_path, "r")
        if f then
            local size = f:seek("end")
            f:close()
            if size and status_item then
                local mb = size / (1024 * 1024)
                if mb >= 1024 then
                    status_item:setTitle(string.format("⬇ %.1f GB", mb / 1024))
                else
                    status_item:setTitle(string.format("⬇ %.0f MB", mb))
                end
                status_item:setTooltip("Downloading " .. display .. "…")
            end
        end
    end)
end

local function list_available_models()
    local installed = {}
    local available = {}
    local handle = io.popen(whisper_script .. " list-models 2>/dev/null")
    if not handle then return installed, available end
    for line in handle:lines() do
        local status, name = line:match("^(%w+):(.+)$")
        if status == "installed" then
            installed[#installed + 1] = name
        elseif status == "available" then
            available[#available + 1] = name
        end
    end
    handle:close()
    return installed, available
end

local function download_model(model_name)
    if download_in_progress[model_name] then
        alert("Already downloading " .. model_name)
        return
    end

    download_in_progress[model_name] = true
    local display = model_name:gsub("^ggml%-", ""):gsub("%.bin$", "")
    alert("Downloading " .. display .. "…")

    local part_path = model_dir .. "/" .. model_name .. ".part"
    start_download_progress(model_name, part_path)

    local task = hs.task.new(whisper_script, function(exit_code, std_out, _)
        download_in_progress[model_name] = nil
        stop_download_progress()
        if exit_code == 0 then
            if std_out and std_out:match("already_exists") then
                alert(display .. " already installed")
            else
                alert(display .. " ready ✓")
            end
        else
            alert("Download failed: " .. display)
        end
    end, {"download-model", model_name})

    if task then
        task:start()
    else
        download_in_progress[model_name] = nil
        stop_download_progress()
        alert("Failed to start download")
    end
end

local function update_conf_value(key, value)
    local f = io.open(conf_file, "r")
    if not f then return false end
    local lines = {}
    local replaced = false
    local replacement = key .. '="' .. value .. '"'
    for line in f:lines() do
        if not replaced and line:match("^" .. key .. "=") then
            lines[#lines + 1] = replacement
            replaced = true
        else
            lines[#lines + 1] = line
        end
    end
    f:close()

    if not replaced then
        lines[#lines + 1] = replacement
    end

    local fw = io.open(conf_file, "w")
    if not fw then return false end
    fw:write(table.concat(lines, "\n") .. "\n")
    fw:close()
    return true
end

local function set_active_model(model_name)
    local new_path = model_dir .. "/" .. model_name
    if not update_conf_value("WHISPER_MODEL_PATH", new_path) then
        alert("Cannot update config file")
        return
    end

    -- Pretty name without ggml- prefix and .bin suffix for display
    local display = model_name:gsub("^ggml%-", ""):gsub("%.bin$", "")
    alert("Model → " .. display)
end

local function build_menu()
    local menu = {
        { title = "Toggle Recording",     fn = function() run_whisper("toggle") end },
        { title = "Stop Recording",       fn = function() run_whisper("stop") end },
        { title = "Re-transcribe Last ⌃⇧⌘R", fn = function() run_whisper("retranscribe") end },
        { title = "-" },
    }

    -- Streaming mode controls
    local streaming_ok, streaming = pcall(require, "whisper_streaming")
    if streaming_ok then
        local is_active = streaming.isStreaming()
        menu[#menu + 1] = {
            title = is_active and "⏹ Stop Streaming" or "◉ Start Streaming",
            fn = function()
                if streaming.isStreaming() then
                    streaming.stop()
                else
                    streaming.start()
                end
            end,
        }
    end
    menu[#menu + 1] = { title = "-" }
    menu[#menu + 1] = { title = "Refresh Status", fn = function() update_indicator() end }
    menu[#menu + 1] = { title = "-" }

    -- Notifications & Sounds toggles
    local notif_on = read_conf("WHISPER_NOTIFICATIONS", "1") == "1"
    local sound_on = read_conf("WHISPER_SOUNDS", "1") == "1"
    menu[#menu + 1] = {
        title = (notif_on and "✓ " or "   ") .. "Notifications",
        fn = function()
            local new_val = notif_on and "0" or "1"
            update_conf_value("WHISPER_NOTIFICATIONS", new_val)
            alert("Notifications " .. (notif_on and "off" or "on"))
        end,
    }
    menu[#menu + 1] = {
        title = (sound_on and "✓ " or "   ") .. "Sounds",
        fn = function()
            local new_val = sound_on and "0" or "1"
            update_conf_value("WHISPER_SOUNDS", new_val)
            alert("Sounds " .. (sound_on and "off" or "on"))
        end,
    }
    menu[#menu + 1] = { title = "-" }

    -- Post-processing: only show mode selector if authenticated
    local has_token = has_copilot_token()
    if has_token then
        local pp_mode = read_conf("WHISPER_POST_PROCESS", "off")
        local pp_modes = {
            { id = "off",        label = "Off (raw transcript)" },
            { id = "clean",      label = "Clean (remove fillers)" },
            { id = "message",    label = "Messenger (WebEx/Teams)" },
            { id = "email",      label = "Email (Structures the intent)" },
            { id = "prompt",     label = "Prompt (light cleanup)" },
            { id = "prompt-pro", label = "Prompt Pro (Heavy Prompt-Engineering)" },
        }
        local pp_submenu = {}
        for _, m in ipairs(pp_modes) do
            local is_active = (m.id == pp_mode)
            local captured_id = m.id
            local captured_label = m.label
            pp_submenu[#pp_submenu + 1] = {
                title = (is_active and "✓ " or "   ") .. m.label,
                fn = function()
                    if not is_active then
                        update_conf_value("WHISPER_POST_PROCESS", captured_id)
                        alert("Post-process → " .. captured_label)
                    end
                end,
                disabled = is_active,
            }
        end
        local pp_display = pp_mode == "off" and "Off" or pp_mode:sub(1,1):upper() .. pp_mode:sub(2)
        menu[#menu + 1] = {
            title = "Post-process: " .. pp_display,
            menu = pp_submenu,
        }
    else
        menu[#menu + 1] = {
            title = "Sign in to GitHub Copilot…",
            fn = function()
                alert("Authenticating with GitHub…\nCode copied to clipboard.\nOpening browser…")

                local task = hs.task.new(whisper_script, function(exitCode, stdout, stderr)
                    if exitCode == 0 and stdout and stdout:match("AUTH_OK") then
                        alert("✓ Copilot authenticated!")
                        update_conf_value("WHISPER_POST_PROCESS", "clean")
                    else
                        local err = (stderr or ""):match("ERROR: (.+)")
                        alert(err or "Authentication failed")
                    end
                end, { "auth" })
                task:start()

                -- Give the task a moment to request the code and copy to clipboard, then open browser
                hs.timer.doAfter(2, function()
                    hs.urlevent.openURL("https://github.com/login/device")
                end)
            end,
        }
    end
    menu[#menu + 1] = { title = "-" }

    -- Model selector (submenu)
    local installed, available = list_available_models()
    local active = get_active_model()
    local active_display = active:gsub("^ggml%-", ""):gsub("%.bin$", "")
    if #installed > 0 or #available > 0 then
        local model_submenu = {}
        for _, m in ipairs(installed) do
            local is_active = (m == active)
            local display = m:gsub("^ggml%-", ""):gsub("%.bin$", "")
            local captured_model = m
            model_submenu[#model_submenu + 1] = {
                title = (is_active and "✓ " or "   ") .. display,
                fn = function()
                    if not is_active then
                        set_active_model(captured_model)
                    end
                end,
                disabled = is_active,
                tooltip = m,
            }
        end
        if #available > 0 then
            model_submenu[#model_submenu + 1] = { title = "-" }
            model_submenu[#model_submenu + 1] = { title = "Download…", disabled = true }
            for _, m in ipairs(available) do
                local display = m:gsub("^ggml%-", ""):gsub("%.bin$", "")
                local captured_model = m
                local is_downloading = download_in_progress[m] or false
                model_submenu[#model_submenu + 1] = {
                    title = (is_downloading and "⟳ " or "   ") .. display,
                    fn = function()
                        download_model(captured_model)
                    end,
                    disabled = is_downloading,
                    tooltip = "Download " .. m .. " from Hugging Face",
                }
            end
        end
        menu[#menu + 1] = {
            title = "Model: " .. active_display,
            menu = model_submenu,
        }
        menu[#menu + 1] = { title = "-" }
    end

    -- History
    local history = read_history()
    if #history == 0 then
        menu[#menu + 1] = { title = "No history yet", disabled = true }
    else
        menu[#menu + 1] = { title = "Recent Transcriptions", disabled = true }
        for i = #history, 1, -1 do
            local entry = history[i]
            local preview = entry.text
            if #preview > 60 then
                preview = preview:sub(1, 60) .. "…"
            end
            local captured_text = entry.text
            menu[#menu + 1] = {
                title = preview,
                fn = function()
                    hs.pasteboard.setContents(captured_text)
                    alert("Copied to clipboard")
                end,
                tooltip = entry.timestamp,
            }
        end
    end

    return menu
end

if status_item then
    status_item:setMenu(build_menu)
end

if toggle_mods and toggle_key then
    hs.hotkey.bind(toggle_mods, toggle_key, function() run_whisper("toggle") end)
end

if stop_mods and stop_key then
    hs.hotkey.bind(stop_mods, stop_key, function() run_whisper("stop") end)
end

-- Audio device change watcher: auto-restart recording when input device changes
local restart_in_progress = false
local restart_debounce_timer = nil

hs.audiodevice.watcher.setCallback(function(event)
    if event ~= "dIn" or current_state ~= "recording" or restart_in_progress then
        return
    end
    -- Debounce: macOS may fire multiple events during device handoff
    if restart_debounce_timer then restart_debounce_timer:stop() end
    restart_debounce_timer = hs.timer.doAfter(1.0, function()
        restart_debounce_timer = nil
        if current_state ~= "recording" or restart_in_progress then return end

        restart_in_progress = true
        local new_device = hs.audiodevice.defaultInputDevice()
        local device_name = new_device and new_device:name() or "unknown"
        alert("🎙 Input → " .. device_name)

        local task = hs.task.new(whisper_script, function(exit_code, _, _)
            restart_in_progress = false
            if exit_code ~= 0 then
                alert("Whisper: device restart failed")
            end
            hs.timer.doAfter(0.4, update_indicator)
        end, {"restart-recording"})

        if task then
            task:start()
        else
            restart_in_progress = false
        end
    end)
end)
hs.audiodevice.watcher.start()

hs.timer.doEvery(3.0, update_indicator)
update_indicator()

if toggle_mods and toggle_key then
    alert("Whisper: " .. table.concat(toggle_mods, "+") .. "+" .. toggle_key .. " start/stop")
else
    alert("Whisper loaded")
end
