# Logitech Signature M750 — Mouse Button Setup

This guide is specific to the **Logitech Signature M750**. If you have a
different mouse, start at [`docs/mouse-decision-guide.md`](mouse-decision-guide.md).

---

## ⚠️ Logi Options+ Is REQUIRED for the M750

The button **below the scroll wheel** (Logitech calls it the "gesture button")
on the M750 emits **zero macOS events** unless Logi Options+ is running and
has explicitly mapped that button. This is a hardware/firmware limitation
of the M750, not a software bug. The native Hammerspoon eventtap path
([`docs/mouse-button-mapping.md`](mouse-button-mapping.md)) cannot capture
this button on this mouse.

If you skip Logi Options+, you can still use Forward and Back side buttons
via the eventtap, but you lose the gesture button → paste-improved hotkey.

---

## Step 1 — Install Logi Options+

```bash
brew install --cask logi-options-plus
open -a "logioptionsplus"
```

Or download manually from
<https://www.logitech.com/en-us/software/logi-options-plus.html>.

Pair the M750 over Bluetooth or via the Bolt USB receiver. The M750 should
appear in the Logi Options+ device list with model identifier
`signature-m750-2b02c`.

---

## Step 2 — Grant macOS Permissions

System Settings → Privacy & Security:

- **Accessibility** → Hammerspoon ON (required for hotkey delivery)
- **Input Monitoring** → Hammerspoon ON (required for hotkey reception)
- **Input Monitoring** → `logioptionsplus_agent` ON (required for
  Logi Options+ to see button presses)
- **Accessibility** → `logioptionsplus_agent` ON (required for
  Logi Options+ to send synthetic keystrokes)

Logi Options+ will prompt for these the first time you try to assign a
keystroke. Grant them all and restart Logi Options+ if prompted.

See [`docs/macos-permissions.md`](macos-permissions.md) for the full
permissions matrix including microphone, screen recording, and automation.

---

## Step 3 — Map the Three Buttons

In Logi Options+:

1. Click your **M750** in the device list. You should see a top-down photo
   of the mouse with clickable button labels.
2. For each button below, click the button label, choose **Keystroke
   Assignment** (sometimes labeled "Custom" → "Keystroke"), then press the
   listed key combination on your keyboard.

| Button | Keystroke to assign | Hammerspoon action |
|---|---|---|
| **Top side button** (Forward) | `^Ctrl + ⌘Cmd + ⇧Shift + 9` | Start streaming |
| **Bottom side button** (Back) | `^Ctrl + ⌘Cmd + ⇧Shift + 0` | Stop streaming |
| **Gesture button** (below scroll wheel) | `^Ctrl + ⌘Cmd + ⇧Shift + 8` | Paste latest improved transcription |

Leave the **scroll wheel click** ("Middle button" in the Logi Options+ UI)
on its default — it is a different physical button from the gesture button
and you almost certainly want to keep it as standard middle-click.

Click **Save** / **Apply** in Logi Options+. Settings are stored in
`~/Library/Application Support/LogiOptionsPlus/settings.db` and persist
across reboots, but only on this Mac (no portable export — see
[`docs/internals/logi-options-plus.md`](internals/logi-options-plus.md)).

---

## Step 4 — Disable the Native Eventtap (Avoid Conflict)

Because Logi Options+ now intercepts all extra mouse buttons, the
`whisper_mouse_eventtap.lua` module would be a no-op anyway, but it should
be explicitly disabled to keep Hammerspoon's logs clean.

Open `~/.hammerspoon/init.lua` (or your local copy in this repo's
`hammerspoon/init.lua`) and ensure `whisper_mouse_eventtap` is NOT loaded,
or that you do NOT call its `start()` function. Then reload Hammerspoon:

```bash
hs -c 'hs.reload()'
```

---

## Step 5 — Verify

1. Open any text editor (TextEdit, VS Code, Terminal).
2. Press the **Forward** side button. Hammerspoon menubar should show the
   recording indicator (e.g. `◉ 0:00`) and an overlay window should appear
   with live transcription.
3. Speak a short sentence.
4. Press the **Back** side button. Streaming should stop and the
   transcription should paste into the focused app.
5. Wait a few seconds for the post-processing pipeline to finish (medium /
   large model + corrections).
6. Press the **Gesture** button (below the scroll wheel). The improved
   (post-processed) transcription should overwrite/append the previous
   paste.

If any step fails, see the troubleshooting section below.

---

## Troubleshooting

### Forward / Back works, but Gesture button does nothing

- Confirm Logi Options+ is running (`pgrep -fl logioptionsplus`).
- Re-open Logi Options+, click the Gesture button in the on-screen mouse
  diagram, and confirm it shows "Keystroke Assignment: ^⌘⇧8". If it shows
  "Default" or "Gesture", the mapping was not saved.
- Confirm `logioptionsplus_agent` has Input Monitoring permission (System
  Settings → Privacy & Security → Input Monitoring).

### Gesture button works, but Forward / Back are now broken

You probably still have the eventtap module loaded and it is racing with
Logi Options+. Disable the eventtap (Step 4) or map Forward/Back in
Logi Options+ as well (which is the recommended path on M750).

### Logi Options+ shows "Connect a device" with M750 paired and on

- Toggle Bluetooth off/on.
- Restart Logi Options+: `pkill -f logioptionsplus && open -a logioptionsplus`.
- If using the Bolt receiver, replug it.

### Mappings disappear after macOS update

Re-grant the Input Monitoring + Accessibility permissions for
`logioptionsplus_agent` — macOS sometimes silently revokes them across
major updates.

---

## Related Docs

- [`docs/mouse-decision-guide.md`](mouse-decision-guide.md) — chooser for other mice
- [`docs/macos-permissions.md`](macos-permissions.md) — full permissions matrix
- [`docs/internals/logi-options-plus.md`](internals/logi-options-plus.md) — DB schema + AI agent notes
- [`hammerspoon/whisper_mouse.lua`](../hammerspoon/whisper_mouse.lua) — hotkey handlers
