# Logi MX Anywhere 3S Button Mapping

> **Pick the right doc first.** This page covers the **MX Anywhere 3S**
> (and similar Logitech mice where Forward/Back/Middle are all natively
> visible to macOS). If you have a **Logitech M750**, follow
> [`m750-setup.md`](m750-setup.md) instead — the M750's gesture button has
> different requirements. Unsure? Read the
> [mouse decision guide](mouse-decision-guide.md).

## Overview

Streaming mode is triggered via mouse buttons using Logi Options+ keystroke remapping. Without these mappings, only batch mode (keyboard hotkeys Ctrl+Cmd+W / Ctrl+Cmd+Q) works. Streaming mode requires the Forward, Back, and Middle buttons to be mapped to specific keystroke combinations that Hammerspoon listens for.

## Mapping Table

| Button | Logi Options+ Action | Keystroke | Hammerspoon Hotkey | What it does |
|--------|---------------------|-----------|-------------------|--------------|
| Forward button | Custom keystroke | Ctrl+Shift+Cmd+9 | `hammerspoon/whisper_mouse.lua` | Start streaming recording (live overlay with real-time transcription) |
| Back button | Custom keystroke | Ctrl+Shift+Cmd+0 | `hammerspoon/whisper_mouse.lua` | Stop streaming and paste result into active app |
| Middle button | Custom keystroke | Ctrl+Shift+Cmd+8 | `hammerspoon/whisper_mouse.lua` | Paste latest quick result (from batch or streaming mode) |

## How to Configure on a Fresh Mac

1. **Open Logi Options+ app**
   - If not installed, download from: https://www.logitech.com/en-us/software/logi-options-plus.html
   - Install and launch the app
   - Connect your MX Anywhere 3S mouse (Bluetooth or USB receiver)

2. **Select your device**
   - In Logi Options+, click on your MX Anywhere 3S device
   - You should see a visual representation of the mouse with clickable buttons

3. **Configure Forward button**
   - Click the Forward button (side button near the top)
   - Select "Custom" from the action menu
   - Choose "Keystroke assignment"
   - Press: Ctrl+Shift+Cmd+9 (hold all four keys, then press 9)
   - Click "Save" or "Apply"

4. **Configure Back button**
   - Click the Back button (side button near the bottom)
   - Select "Custom" from the action menu
   - Choose "Keystroke assignment"
   - Press: Ctrl+Shift+Cmd+0 (hold all four keys, then press 0)
   - Click "Save" or "Apply"

5. **Configure Middle button**
   - Click the Middle button (scroll wheel click)
   - Select "Custom" from the action menu
   - Choose "Keystroke assignment"
   - Press: Ctrl+Shift+Cmd+8 (hold all four keys, then press 8)
   - Click "Save" or "Apply"

6. **Test the configuration**
   - Open any text application (TextEdit, VS Code, Terminal, etc.)
   - Press the Forward button
   - Hammerspoon should show a recording indicator in the menubar ("◉ 0:00")
   - Speak a sentence
   - Press the Back button
   - Transcribed text should appear in the active application

## Why No Export?

Logi Options+ stores configuration in a binary SQLite blob at:
```
~/Library/Application Support/Logitech.localized/LogiOptionsPlus/
```

This format does not roundtrip cleanly across machines. Exporting the database and importing it on another Mac often fails due to:
- Device-specific UUIDs embedded in the config
- macOS version differences
- Logi Options+ version mismatches

Therefore, manual reconfiguration (following the steps above) is the documented path. If Logitech adds a proper export/import feature in a future version of Logi Options+, this document will be updated.

## Troubleshooting

### Mouse buttons don't trigger streaming mode

1. **Verify Logi Options+ is running**
   - Check the menubar for the Logi Options+ icon
   - If not running, launch it from Applications

2. **Verify button mappings**
   - Open Logi Options+
   - Click on your MX Anywhere 3S
   - Check each button shows the correct keystroke (Ctrl+Shift+Cmd+9/0/8)

3. **Verify Hammerspoon is listening**
   - Open Hammerspoon Console: Hammerspoon menubar → Console
   - Press the Forward button
   - You should see a log entry like: "Mouse button: start streaming"
   - If no log entry, the keystroke isn't reaching Hammerspoon

4. **Check macOS permissions**
   - System Settings → Privacy & Security → Accessibility → Hammerspoon ON
   - System Settings → Privacy & Security → Input Monitoring → Hammerspoon ON
   - See `docs/macos-permissions.md` for full checklist

5. **Reload Hammerspoon**
   ```bash
   killall Hammerspoon; sleep 1; open -a Hammerspoon
   ```

### Forward button starts recording but Back button doesn't stop

1. **Check the Back button mapping**
   - Open Logi Options+
   - Verify Back button is mapped to Ctrl+Shift+Cmd+0 (zero, not letter O)

2. **Test the keystroke manually**
   - Open any text app
   - Press Ctrl+Shift+Cmd+0 on the keyboard
   - If streaming stops, the mapping is wrong in Logi Options+
   - If streaming doesn't stop, check Hammerspoon console for errors

### Middle button doesn't paste

1. **Verify there's a recent recording**
   - The Middle button pastes the most recent quick result
   - If you haven't recorded anything yet, there's nothing to paste

2. **Check the Middle button mapping**
   - Open Logi Options+
   - Verify Middle button is mapped to Ctrl+Shift+Cmd+8

3. **Check clipboard permissions**
   - System Settings → Privacy & Security → Automation → Hammerspoon → System Events ON
   - See `docs/macos-permissions.md` for details

## Alternative: Keyboard Shortcuts

If you don't have a Logi MX Anywhere 3S or prefer keyboard shortcuts, you can trigger streaming mode with:

- **Start streaming:** Ctrl+Shift+Cmd+9
- **Stop streaming:** Ctrl+Shift+Cmd+0
- **Paste latest:** Ctrl+Shift+Cmd+8

These are the same keystrokes the mouse buttons send, so they work identically.
