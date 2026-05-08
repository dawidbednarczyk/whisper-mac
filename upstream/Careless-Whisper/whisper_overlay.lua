-- whisper_overlay.lua
-- Hammerspoon module for displaying live transcription overlay
-- Provides a floating semi-transparent panel at bottom-center of screen

local M = {}

-- Module state
local webview = nil
local isCreated = false
local isShown = false

-- Debug log helper (delegates to centralized whisper_debug logger)
local _debug = require("whisper_debug")
local function dbg(msg)
    _debug.event("overlay", "log", { msg = tostring(msg) })
end
local function ev(event_name, data)
    _debug.event("overlay", event_name, data)
end

-- HTML content for the overlay
local HTML_CONTENT = [[
<!DOCTYPE html>
<html><head><style>
* { margin: 0; padding: 0; box-sizing: border-box; }
body {
    padding: 16px 24px;
    background: rgba(20, 20, 20, 0.95);
    font-family: -apple-system, 'SF Pro Text', 'Helvetica Neue', sans-serif;
    font-size: 20px;
    line-height: 1.6;
    color: #ffffff;
    overflow-y: auto;
    overflow-x: hidden;
    -webkit-font-smoothing: antialiased;
    height: 100%;
}
#text-container { word-wrap: break-word; white-space: pre-wrap; }
.confirmed { color: #ffffff; }
.corrected { color: #4ade80; transition: color 2s ease; }
.corrected.fade { color: #ffffff; }
.partial { color: #9ca3af; }
.cursor { color: #9ca3af; animation: blink 1s step-end infinite; }
@keyframes blink { 0%, 100% { opacity: 1; } 50% { opacity: 0; } }
.mode-badge {
    position: fixed; top: 8px; right: 16px;
    font-size: 11px; color: #ef4444; text-transform: uppercase; letter-spacing: 1px;
    font-weight: 600;
    transition: color 0.3s ease;
}
.mode-badge.processing { color: #f59e0b; }
.mode-badge.warming { color: #fbbf24; animation: badge-pulse 1s ease-in-out infinite; }
@keyframes badge-pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.4; } }
</style></head>
<body>
<div class="mode-badge warming">⏳ WARMING UP — WAIT FOR ●</div>
<div id="text-container">
    <span id="confirmed" class="confirmed"></span>
    <span id="partial" class="partial"></span>
    <span id="cursor" class="cursor">▌</span>
</div>
<script>
function updateText(confirmed, partial) {
    document.getElementById('confirmed').textContent = confirmed;
    document.getElementById('partial').textContent = partial;
    window.scrollTo(0, document.body.scrollHeight);
}
function flashCorrection(oldText, newText) {
    var el = document.getElementById('confirmed');
    var content = el.textContent;
    var idx = content.lastIndexOf(oldText);
    if (idx === -1) return;
    var before = content.substring(0, idx);
    var after = content.substring(idx + oldText.length);
    el.innerHTML = escapeHtml(before) + '<span class="corrected">' + escapeHtml(newText) + '</span>' + escapeHtml(after);
    setTimeout(function() {
        var c = document.querySelectorAll('.corrected');
        c.forEach(function(e) { e.classList.add('fade'); });
    }, 100);
    setTimeout(function() {
        // Rebuild as plain text
        el.textContent = before + newText + after;
    }, 2500);
}
function escapeHtml(s) {
    var d = document.createElement('div');
    d.appendChild(document.createTextNode(s));
    return d.innerHTML;
}
function clear() {
    document.getElementById('confirmed').textContent = '';
    document.getElementById('partial').textContent = '';
}
function setMode(mode) {
    var badge = document.querySelector('.mode-badge');
    badge.classList.remove('processing', 'warming');
    if (mode === 'processing') {
        badge.textContent = '\u23F3 PROCESSING';
        badge.classList.add('processing');
    } else if (mode === 'warming') {
        badge.textContent = '\u23F3 WARMING UP \u2014 WAIT FOR \u25CF';
        badge.classList.add('warming');
    } else {
        badge.textContent = '\u25CF STREAMING';
    }
}
</script>
</body></html>
]]

-- Escape string for safe JavaScript injection
-- Handles backslashes, quotes, newlines, carriage returns
local function escapeJS(str)
    if not str then return "" end
    str = string.gsub(str, "\\", "\\\\")  -- Escape backslashes first
    str = string.gsub(str, "'", "\\'")    -- Escape single quotes
    str = string.gsub(str, "\n", "\\n")   -- Escape newlines
    str = string.gsub(str, "\r", "\\r")   -- Escape carriage returns
    return str
end

-- Create and show the overlay window
function M.create()
    if isCreated and webview then
        ev("create_already_exists", {})
        webview:show()
        isShown = true
        return true
    end
    ev("create_start", {})

    -- Get primary screen dimensions
    local screen = hs.screen.primaryScreen()
    if not screen then
        hs.showError("Could not get primary screen")
        return false
    end
    
    local screenFrame = screen:frame()

    -- Calculate overlay position: top-center, 80% width, 120px height, 80px from top.
    -- Top placement avoids covering AI chat input areas (Cursor / OpenCode / Claude Code prompt
    -- at bottom of window). 80px gap keeps the overlay clear of IDE/browser tab bars which
    -- typically occupy the first ~60-80px of a maximized app window.
    local overlayWidth = screenFrame.w * 0.8
    local overlayHeight = 120
    local overlayX = screenFrame.x + (screenFrame.w - overlayWidth) / 2
    local overlayY = screenFrame.y + 80
    
    local overlayFrame = {
        x = overlayX,
        y = overlayY,
        w = overlayWidth,
        h = overlayHeight
    }
    
    -- Create webview with appropriate options
    local prefs = {}
    prefs["developerExtrasEnabled"] = false  -- Disable dev tools for production
    
    webview = hs.webview.new(overlayFrame, prefs)
    
    if not webview then
        hs.showError("Failed to create webview")
        return false
    end
    
    -- Configure webview behavior
    webview:windowStyle({"borderless"})  -- No window chrome
    webview:allowTextEntry(false)        -- Click-through behavior
    webview:allowGestures(false)         -- No gesture navigation
    webview:level(hs.drawing.windowLevels.floating)  -- Stay on top
    webview:alpha(0.92)                  -- Semi-transparent
    webview:behavior(hs.drawing.windowBehaviors.canJoinAllSpaces +  -- Show on all spaces
                     hs.drawing.windowBehaviors.stationary)          -- Don't move with Mission Control
    
    -- Load HTML content
    webview:html(HTML_CONTENT)

    -- Show the window
    webview:show()

    isCreated = true
    isShown = true
    ev("create_done", {
        w = overlayFrame.w, h = overlayFrame.h,
        x = overlayFrame.x, y = overlayFrame.y,
        screen_w = screenFrame.w, screen_h = screenFrame.h,
    })
    return true
end

-- Update the displayed text
-- @param confirmed string: The confirmed/finalized text (white)
-- @param partial string: The in-progress text (gray)
function M.update(confirmed, partial)
    if not webview then
        hs.printf("whisper_overlay: Cannot update - overlay not created")
        return false
    end
    
    confirmed = confirmed or ""
    partial = partial or ""
    
    -- Escape strings for JavaScript
    local confirmedEscaped = escapeJS(confirmed)
    local partialEscaped = escapeJS(partial)
    
    -- Call JavaScript function to update display
    local js = string.format("updateText('%s', '%s');", confirmedEscaped, partialEscaped)
    webview:evaluateJavaScript(js)
    
    return true
end

-- Flash a correction animation
-- Shows oldText briefly, then animates to newText with green flash
-- @param oldText string: The original text that was corrected
-- @param newText string: The corrected text
function M.flashCorrection(oldText, newText)
    if not webview then
        hs.printf("whisper_overlay: Cannot flash correction - overlay not created")
        return false
    end
    
    oldText = oldText or ""
    newText = newText or ""
    
    -- Escape strings for JavaScript
    local oldTextEscaped = escapeJS(oldText)
    local newTextEscaped = escapeJS(newText)
    
    -- Call JavaScript function to animate correction
    local js = string.format("flashCorrection('%s', '%s');", oldTextEscaped, newTextEscaped)
    webview:evaluateJavaScript(js)
    
    return true
end

-- Clear all text from the overlay
function M.clear()
    if not webview then
        return false
    end
    
    webview:evaluateJavaScript("clear();")
    return true
end

-- Destroy the overlay and clean up
function M.destroy()
    ev("destroy", {
        had_webview = webview ~= nil,
        was_created = isCreated,
        was_shown   = isShown,
    })
    if webview then
        pcall(function() webview:hide() end)
        pcall(function() webview:delete() end)
        webview = nil
    end
    isCreated = false
    isShown = false
end

-- Set overlay mode badge ('streaming' or 'processing')
function M.setMode(mode)
    if not webview then return false end
    local jsMode
    if mode == "processing" then
        jsMode = "processing"
    elseif mode == "warming" then
        jsMode = "warming"
    else
        jsMode = "streaming"
    end
    ev("set_mode", { mode = jsMode })
    webview:evaluateJavaScript(string.format("setMode('%s');", jsMode))
    return true
end

-- Check if overlay is currently visible (window exists AND is shown)
function M.isVisible()
    return webview ~= nil and isShown
end

-- Check if overlay exists (regardless of visibility)
function M.exists()
    return webview ~= nil
end

-- Hide the overlay without destroying it
function M.hide()
    if webview then
        webview:hide()
        isShown = false
    end
end

-- Show the overlay (if it was previously hidden)
function M.show()
    if webview then
        webview:show()
        isShown = true
    end
end

return M
