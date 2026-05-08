# macOS Permissions Checklist for Hammerspoon + ffmpeg

## Overview

The whisper transcription system requires five macOS permissions to function. These permissions must be granted manually via System Settings — there is no scripting or automation for this. Revoked permissions cause features to fail silently (no error messages, just no action).

This checklist documents each permission, what needs it, which feature breaks if not granted, the exact System Settings path, and how to verify it's working.

## Permission Table

| Permission | Required by | Feature that breaks if not granted | System Settings path | Verification |
|------------|-------------|-------------------------------------|---------------------|--------------|
| **Accessibility** | Hammerspoon | All hotkeys fail silently (Ctrl+Cmd+W, Ctrl+Cmd+Q, mouse buttons) | System Settings → Privacy & Security → Accessibility → toggle Hammerspoon ON | Press Ctrl+Cmd+W; if Hammerspoon menubar shows "● 0:00" indicator, granted |
| **Input Monitoring** | Hammerspoon | Keyboard shortcuts don't trigger; mouse button remapping doesn't work | System Settings → Privacy & Security → Input Monitoring → toggle Hammerspoon ON | Press Ctrl+Cmd+W; if recording starts, granted |
| **Microphone** | Hammerspoon, ffmpeg | No audio capture; recordings are silent | System Settings → Privacy & Security → Microphone → toggle Hammerspoon ON | Record with Ctrl+Cmd+W, speak, stop with Ctrl+Cmd+Q; if text appears, granted |
| **Screen Recording** | Hammerspoon | Streaming overlay (hs.webview) doesn't display; no live transcription visible | System Settings → Privacy & Security → Screen Recording → toggle Hammerspoon ON | Press mouse Forward button; if overlay appears with live text, granted |
| **Automation → System Events** | Hammerspoon | Clipboard paste fails; transcribed text doesn't appear in active app | System Settings → Privacy & Security → Automation → Hammerspoon → toggle System Events ON | Record and stop; if text pastes into active app, granted |

## Detailed Permission Descriptions

### 1. Accessibility

**What needs it:** Hammerspoon

**What breaks:** All hotkeys (Ctrl+Cmd+W, Ctrl+Cmd+Q, Ctrl+Shift+Cmd+9/0/8) fail silently. The menubar icon doesn't update. Mouse button remapping doesn't work.

**System Settings path:**
1. Open System Settings
2. Navigate to Privacy & Security
3. Scroll down to Accessibility
4. Toggle Hammerspoon ON

**Verification:**
- Press Ctrl+Cmd+W
- Hammerspoon menubar icon should change from "○" to "● 0:00"
- If nothing happens, Accessibility permission is not granted

### 2. Input Monitoring

**What needs it:** Hammerspoon

**What breaks:** Keyboard shortcuts don't trigger. Mouse button remapping (via Logi Options+ keystroke assignment) doesn't work.

**System Settings path:**
1. Open System Settings
2. Navigate to Privacy & Security
3. Scroll down to Input Monitoring
4. Toggle Hammerspoon ON

**Verification:**
- Press Ctrl+Cmd+W
- If recording starts (menubar shows "● 0:00"), Input Monitoring is granted
- If nothing happens, check this permission

### 3. Microphone

**What needs it:** Hammerspoon (for whisper-stream), ffmpeg (for batch mode)

**What breaks:** No audio capture. Recordings are silent. Transcription returns empty text or hallucinations like "[BLANK_AUDIO]".

**System Settings path:**
1. Open System Settings
2. Navigate to Privacy & Security
3. Scroll down to Microphone
4. Toggle Hammerspoon ON
5. If ffmpeg is listed separately, toggle it ON as well

**Verification:**
- Press Ctrl+Cmd+W (start recording)
- Speak a sentence
- Press Ctrl+Cmd+Q (stop and paste)
- If transcribed text appears in the active app, Microphone is granted
- If you get "[BLANK_AUDIO]" or empty text, Microphone permission is missing

### 4. Screen Recording

**What needs it:** Hammerspoon (for streaming overlay hs.webview)

**What breaks:** Streaming mode overlay doesn't display. You won't see live transcription text during streaming. Batch mode still works.

**System Settings path:**
1. Open System Settings
2. Navigate to Privacy & Security
3. Scroll down to Screen Recording
4. Toggle Hammerspoon ON

**Verification:**
- Press mouse Forward button (or Ctrl+Shift+Cmd+9)
- If a dark overlay appears with live transcription text, Screen Recording is granted
- If no overlay appears, check this permission

### 5. Automation → System Events

**What needs it:** Hammerspoon (for clipboard paste via AppleScript)

**What breaks:** Transcribed text doesn't paste into the active application. Text is transcribed (visible in the overlay or menubar) but doesn't appear in your editor/browser/terminal.

**System Settings path:**
1. Open System Settings
2. Navigate to Privacy & Security
3. Scroll down to Automation
4. Expand Hammerspoon
5. Toggle System Events ON

**Verification:**
- Press Ctrl+Cmd+W, speak, press Ctrl+Cmd+Q
- If text appears in the active application, Automation is granted
- If text doesn't paste (but you see it in the overlay or menubar), Automation permission is missing

## First-Launch Checklist

When launching Hammerspoon for the first time on a fresh Mac:

1. Open Hammerspoon: `open -a Hammerspoon`
2. Attempt a batch recording: press Ctrl+Cmd+W, speak, press Ctrl+Cmd+Q
3. macOS will prompt for permissions as they're needed — accept all prompts
4. After the first recording attempt, verify each permission in System Settings:
   - System Settings → Privacy & Security → Accessibility → Hammerspoon ON
   - System Settings → Privacy & Security → Input Monitoring → Hammerspoon ON
   - System Settings → Privacy & Security → Microphone → Hammerspoon ON
   - System Settings → Privacy & Security → Screen Recording → Hammerspoon ON
   - System Settings → Privacy & Security → Automation → Hammerspoon → System Events ON
5. Reload Hammerspoon: press Cmd+Shift+R in the Hammerspoon menubar, or run:
   ```bash
   killall Hammerspoon; sleep 1; open -a Hammerspoon
   ```
6. Test again: batch mode (Ctrl+Cmd+W) and streaming mode (mouse Forward button)

## Troubleshooting

If a feature stops working after a macOS update or Hammerspoon reinstall:

1. Check all five permissions in System Settings
2. Toggle each permission OFF then ON again (sometimes macOS needs a refresh)
3. Reload Hammerspoon: `killall Hammerspoon; sleep 1; open -a Hammerspoon`
4. Test each mode (batch and streaming)

If permissions are granted but features still don't work:

1. Check Hammerspoon console for errors: Hammerspoon menubar → Console
2. Verify Lua files are synced: `md5 hammerspoon/init.lua ~/.hammerspoon/init.lua` (hashes should match)
3. Run the disaster recovery self-test: `bash bin/disaster_recovery_check.sh`
