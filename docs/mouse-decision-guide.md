# Mouse Setup — Which Path Do I Need?

**Read this first** before configuring mouse buttons. There are two
mutually-exclusive approaches in this repo, and picking the wrong one for
your hardware will silently fail.

---

## TL;DR Decision Table

| Your mouse | Recommended path | Why | Setup doc |
|---|---|---|---|
| **Logitech M750** (Signature M750) | **Logi Options+** (required) | The button below the scroll wheel emits **zero macOS events** without Logi Options+ running and explicitly mapped. Hardware limitation. | [`docs/m750-setup.md`](m750-setup.md) |
| **Logitech MX Anywhere 3S** | Logi Options+ (recommended) | Forward/Back/Middle are all natively visible to macOS, but Logi Options+ gives you nicer per-app config and OSD feedback. | [`docs/mouse-mapping.md`](mouse-mapping.md) |
| **Generic 3-button mouse** with Forward + Back side buttons that already register in macOS | **Native Hammerspoon eventtap** | No vendor driver needed; `whisper_mouse_eventtap.lua` synthesizes the hotkeys directly from `otherMouseDown` events. | [`docs/mouse-button-mapping.md`](mouse-button-mapping.md) |
| **No mouse / laptop trackpad** | Keyboard shortcuts only | All mouse actions have keyboard equivalents. | See README §Hotkeys |

---

## The Two Paths Explained

### Path A — Logi Options+ keystroke remapping

Logitech's official driver app intercepts mouse buttons at the driver level
and emits configurable keystrokes. Hammerspoon then listens for those
keystrokes via `hs.hotkey.bind`.

**Pros:** Works with any Logitech mouse, including buttons that don't emit
native macOS events (M750 gesture button). Per-app rules. OSD feedback.

**Cons:** Requires a 250 MB Electron app running in the background.
Configuration is GUI-only — there is no CLI, no JSON file you can copy
between machines. See [`docs/internals/logi-options-plus.md`](internals/logi-options-plus.md)
for the technical details.

### Path B — Native Hammerspoon eventtap

Hammerspoon registers a low-level `otherMouseDown` event tap and synthesizes
`Ctrl+Shift+Cmd+9/0/8` hotkeys directly when buttons 4 / 3 / 2 are pressed.

**Pros:** No vendor driver needed. Config is in version-controlled Lua. Works
with any mouse whose extra buttons emit standard NSEvent button numbers.

**Cons:** Will NOT work for buttons that the mouse firmware doesn't expose to
macOS (notably the M750 gesture button). Conflicts with Logi Options+ — if
both are running, Logi Options+ wins and the eventtap sees nothing.

---

## ⚠️ Do NOT Run Both Paths Simultaneously

If you install Logi Options+ AND enable the eventtap module, Logi Options+
will steal all extra mouse button events globally and the eventtap callbacks
will never fire. Pick one:

- Going with Path A → in `hammerspoon/init.lua`, do NOT load
  `whisper_mouse_eventtap.lua` (or comment out its `M.start()` call).
- Going with Path B → quit Logi Options+ entirely and remove it from Login
  Items.

---

## Common Hotkey Targets (Both Paths)

Regardless of which path delivers the keystroke, the destination is the same
set of `hs.hotkey.bind` handlers in `hammerspoon/whisper_mouse.lua`:

| Hotkey | Action |
|---|---|
| `Ctrl+Shift+Cmd+9` | Start streaming recording |
| `Ctrl+Shift+Cmd+0` | Stop streaming recording |
| `Ctrl+Shift+Cmd+8` | Paste latest improved transcription |

So the per-mouse setup docs all map to these three keystrokes — only the
delivery mechanism differs.

---

## Required macOS Permissions (Both Paths)

See [`docs/macos-permissions.md`](macos-permissions.md) for the full
checklist. The minimum for mouse-triggered hotkeys:

- **Accessibility** → Hammerspoon (always required)
- **Input Monitoring** → Hammerspoon (always required)
- **Input Monitoring** → Logi Options+ helper (Path A only)
