-- Hammerspoon Configuration for whisper-mac
--
-- This is an EXAMPLE init.lua showing how to wire up:
--   1. Optional Cmd+Number / Alt+Number text-snippet hotkeys (customize freely)
--   2. The fast-path ffmpeg recording starter (Ctrl+Cmd+W / Ctrl+Cmd+Q)
--   3. Microphone self-healing (auto-pick best connected mic)
--   4. Mouse side-button bindings for streaming mode
--   5. Clipboard-image-to-file paste helper (Ctrl+Shift+Cmd+V)
--
-- Adjust the WHISPER_REPO path below to wherever you cloned this repo.

require("hs.ipc")  -- Enable `hs` CLI

-- ============================================================
-- 1. Example text-snippet hotkeys (OPTIONAL — delete if unused)
-- ============================================================
-- These are placeholders. Replace with your own snippets, or remove entirely.
hs.hotkey.bind({"cmd"}, "1", function()
    hs.eventtap.keyStrokes("hello world snippet 1")
end)

hs.hotkey.bind({"cmd"}, "2", function()
    hs.eventtap.keyStrokes("hello world snippet 2")
end)

-- Cmd+L: Lock screen
hs.hotkey.bind({"cmd"}, "l", function()
    hs.caffeinate.lockScreen()
end)

-- ============================================================
-- 2. Whisper batch-mode recording (Ctrl+Cmd+W start, Ctrl+Cmd+Q stop)
-- ============================================================
-- Adjust this path to where you cloned whisper-mac:
local WHISPER_REPO = os.getenv("HOME") .. "/whisper-mac"

-- Load Bjorn Pleger's hotkey + menubar layer (provides ⇧⌘R toggle)
pcall(function()
    dofile(WHISPER_REPO .. "/upstream/Careless-Whisper/whisper_hotkeys.lua")
end)

local whisperScript    = WHISPER_REPO .. "/upstream/Careless-Whisper/whisper.sh"
local whisperFfmpeg    = "/opt/homebrew/bin/ffmpeg"
local whisperTmpDir    = (os.getenv("TMPDIR") or "/tmp/")
if not whisperTmpDir:match("/$") then whisperTmpDir = whisperTmpDir .. "/" end

local whisperPidFile   = whisperTmpDir .. "whisper_recording.pid"
local whisperSegDir    = whisperTmpDir .. "whisper_segments"
local whisperSegIndex  = whisperTmpDir .. "whisper_segment_index"
local whisperAudioFile = whisperTmpDir .. "whisper_recording.wav"
local whisperTextFile  = whisperTmpDir .. "whisper_output.txt"
local whisperRecTask   = nil

local whisperConfFile = WHISPER_REPO .. "/upstream/Careless-Whisper/whisper-stt.conf"
local function whisperReadConf(key, default)
    local f = io.open(whisperConfFile, "r")
    if not f then return default end
    for line in f:lines() do
        local val = line:match("^" .. key .. "=\"?([^\"]+)\"?$")
        if val then f:close(); return val end
    end
    f:close()
    return default
end

local function whisperIsRecording()
    if whisperRecTask and whisperRecTask:isRunning() then return true end
    local f = io.open(whisperPidFile, "r")
    if not f then return false end
    local pid = f:read("*l")
    f:close()
    if not pid or pid == "" then return false end
    local ok = os.execute("kill -0 " .. pid .. " 2>/dev/null")
    return ok == true or ok == 0
end

function whisperStartFast()
    if whisperIsRecording() then return end

    os.remove(whisperAudioFile)
    os.remove(whisperTextFile)
    os.remove(whisperPidFile)
    os.execute("rm -rf '" .. whisperSegDir .. "'")
    os.execute("mkdir -p '" .. whisperSegDir .. "'")
    local si = io.open(whisperSegIndex, "w")
    if si then si:write("1\n"); si:close() end

    local segFile = whisperSegDir .. "/segment_001.wav"

    whisperRecTask = hs.task.new(whisperFfmpeg, function(_, _, _)
        whisperRecTask = nil
    end, function(_, _, _)
        return true
    end, {
        "-f", "avfoundation",
        "-i", ":" .. whisperReadConf("WHISPER_AUDIO_DEVICE", "default"),
        "-t", "7200",
        "-ar", "16000",
        "-ac", "1",
        "-y", segFile
    })

    if whisperRecTask and whisperRecTask:start() then
        local pf = io.open(whisperPidFile, "w")
        if pf then pf:write(tostring(whisperRecTask:pid()) .. "\n"); pf:close() end
        hs.alert.show("Whisper: recording...", 1.5)
    end
end

-- ============================================================
-- 3. Microphone self-healing
-- ============================================================
-- AVFoundation device indices shift when USB mics are plugged/unplugged.
-- This helper finds the highest-priority connected mic by NAME and rewrites
-- the index in whisper-stt.conf. Customize the priority list for your gear.
--
-- NOTE: Built-in MacBook mic is preferred over Bluetooth headsets because
-- many Bluetooth mics (e.g. Sennheiser MB Pro 1) introduce a ~30 s
-- digital-silence prefix at record start while AVFoundation renegotiates
-- HFP/SCO. USB-wired starts instantly and wins when connected.
local whisperPreferredMics = {
    "Usb Audio Device",
    "MacBook Pro Microphone",
}

function whisperCheckMicrophone()
    hs.alert.show("Checking Microphone...", 1)
    hs.task.new("/bin/bash", function(_, stdout, _)
        if not stdout or stdout == "" then return end
        local inAudio, devices = false, {}
        for line in stdout:gmatch("[^\r\n]+") do
            if line:match("audio devices") then inAudio = true
            elseif line:match("video devices") then inAudio = false
            elseif inAudio then
                local idx, name = line:match("%[(%d+)%]%s+(.+)")
                if idx and name then
                    devices[#devices + 1] = { index = tonumber(idx), name = name }
                end
            end
        end
        local bestDevice = nil
        for _, preferred in ipairs(whisperPreferredMics) do
            for _, dev in ipairs(devices) do
                if dev.name == preferred then bestDevice = dev; break end
            end
            if bestDevice then break end
        end
        if not bestDevice then return end
        local currentIdx = whisperReadConf("WHISPER_AUDIO_DEVICE", "0")
        if tostring(bestDevice.index) == currentIdx then return end
        local f = io.open(whisperConfFile, "r")
        if not f then return end
        local content = f:read("*a"); f:close()
        content = content:gsub("WHISPER_AUDIO_DEVICE=%d+",
            "WHISPER_AUDIO_DEVICE=" .. bestDevice.index)
        local fw = io.open(whisperConfFile, "w")
        if fw then
            fw:write(content); fw:close()
            hs.alert.show("🎙 Mic switched → " .. bestDevice.name
                .. " (#" .. bestDevice.index .. ")", 2.5)
        end
    end, {"-c",
        '/opt/homebrew/bin/ffmpeg -f avfoundation -list_devices true -i "" 2>&1'
    }):start()
end

-- Hotkeys: start recording / stop+transcribe / re-transcribe last
hs.hotkey.bind({"ctrl", "cmd"}, "w", whisperStartFast)
hs.hotkey.bind({"ctrl", "cmd"}, "q", function()
    hs.task.new(whisperScript, nil, {"stop"}):start()
end)
hs.hotkey.bind({"ctrl", "shift", "cmd"}, "r", function()
    hs.alert.show("Whisper: re-transcribing...", 1.5)
    hs.task.new(whisperScript, nil, {"retranscribe"}):start()
end)

-- ============================================================
-- 4. Clipboard-image-to-file paste (Ctrl+Shift+Cmd+V)
-- ============================================================
-- If clipboard has an image: save to ~/Downloads/screenshots/clipboard_<ts>.png
--   and type the file path (so AI agents can read it as an attachment).
-- If clipboard has text: type clipboard text directly.
hs.hotkey.bind({"ctrl", "shift", "cmd"}, "v", function()
    local image = hs.pasteboard.readImage()
    if image then
        local timestamp = os.date("%Y%m%d_%H%M%S")
        local screenshotDir = os.getenv("HOME") .. "/Downloads/screenshots"
        hs.fs.mkdir(screenshotDir)
        local filepath = screenshotDir .. "/clipboard_" .. timestamp .. ".png"
        image:saveToFile(filepath, "PNG")

        -- Many AI agent proxies cap inline images at ~5 MB BASE64 (≈3.7 MB raw).
        -- Retina screenshots (e.g. 6848x2656) routinely exceed this. Downscale.
        local MAX_RAW_BYTES = 3500000
        local attr = hs.fs.attributes(filepath)
        if attr and attr.size > MAX_RAW_BYTES then
            local size = image:size()
            local scale = math.sqrt(MAX_RAW_BYTES / attr.size) * 0.95
            local attempt, maxAttempts = 0, 4
            while attr and attr.size > MAX_RAW_BYTES and attempt < maxAttempts do
                attempt = attempt + 1
                local newW = math.floor(size.w * scale)
                local newH = math.floor(size.h * scale)
                local resized = image:setSize({w = newW, h = newH})
                resized:saveToFile(filepath, "PNG")
                attr = hs.fs.attributes(filepath)
                if attr and attr.size > MAX_RAW_BYTES then
                    image = resized
                    size = {w = newW, h = newH}
                    scale = math.sqrt(MAX_RAW_BYTES / attr.size) * 0.95
                end
            end
        end

        local f = io.open(filepath, "r")
        if f then
            f:close()
            local text = "check this screenshot here is path " .. filepath
            hs.timer.doAfter(0.2, function()
                hs.eventtap.keyStrokes(text)
                hs.timer.doAfter(0.3, function()
                    hs.alert.show("Image saved & path pasted", 1.5)
                end)
            end)
        else
            hs.alert.show("Failed to save clipboard image", 2)
        end
    else
        local clipText = hs.pasteboard.getContents()
        if clipText then
            hs.timer.doAfter(0.2, function()
                hs.eventtap.keyStrokes(clipText)
            end)
        end
    end
end)

-- ============================================================
-- 5. Accessibility self-check
-- ============================================================
if not hs.accessibilityState() then
    hs.alert.show("⚠️ Accessibility permission missing!\n"
        .. "System Settings → Privacy & Security → Accessibility → enable Hammerspoon", 10)
else
    hs.alert.show("Hammerspoon Config Loaded")
end

-- ============================================================
-- 6. Mouse side buttons for streaming Whisper
-- ============================================================
-- Loaded via dofile to ensure eventtap registers reliably after full init.
dofile(os.getenv("HOME") .. "/.hammerspoon/whisper_mouse.lua")

-- Pre-warm whisper Metal kernels so the FIRST recording doesn't pay
-- shader JIT cost. Delayed 2 s so Hammerspoon finishes loading first.
hs.timer.doAfter(2.0, function()
    local ok, whisper_streaming = pcall(require, "whisper_streaming")
    if ok and whisper_streaming and whisper_streaming.preWarm then
        pcall(function() whisper_streaming.preWarm() end)
    end
end)
