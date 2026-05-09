# Mouse Button Mapping (Native Hammerspoon eventtap)

> ⚠️ **This path does NOT work for the Logitech M750 gesture button** (the
> button below the scroll wheel). M750 firmware does not expose that button
> to macOS without Logi Options+ running. If you have an M750, use
> [`m750-setup.md`](m750-setup.md) instead. For other mice, see the
> [mouse decision guide](mouse-decision-guide.md) before continuing.
>
> Also: do **not** run this eventtap together with Logi Options+ — Logi
> Options+ intercepts extra mouse buttons globally and this tap will see
> nothing.

Replaces Logi Options+ / vendor drivers (for mice where extra buttons emit
standard NSEvent button numbers). Implemented in
[`whisper_mouse_eventtap.lua`](file:///Users/jwon/whisper-mac/hammerspoon/whisper_mouse_eventtap.lua).

## Default mapping

| Physical button | NSEvent button # | Action | Hotkey synthesized |
|---|---|---|---|
| Side-front (forward) | 4 | Start streaming | Ctrl+Shift+Cmd+9 |
| Side-rear (back) | 3 | Stop streaming  | Ctrl+Shift+Cmd+0 |
| Middle (wheel click) | 2 | Paste improved  | Ctrl+Shift+Cmd+8 |

## Verification done in this session

1. Module loads on Hammerspoon reload — confirmed via `mouse_eventtap_started` event in `/tmp/whisper_debug.log`.
2. Synthesized `otherMouseDown` button=3 → eventtap callback fired → logged `mouse_button_dispatch button=3 label=back→stop` and synthesized Ctrl+Shift+Cmd+0 (verified 2026-05-09).

## Required user action (one-time)

Hammerspoon needs **Input Monitoring** AND **Accessibility** entitlements to receive `otherMouseDown` events from physical hardware:

1. System Settings → Privacy & Security → Input Monitoring → enable **Hammerspoon**.
2. System Settings → Privacy & Security → Accessibility → enable **Hammerspoon** (already on if hotkeys work).
3. After granting, Hammerspoon may prompt to restart — accept.

Synthesized events bypass the Input Monitoring gate (proves the eventtap callback works), but **physical button presses won't reach the tap until Input Monitoring is granted**.

## If buttons feel reversed

Some Logitech/Razer mice swap NSEvent button 3 ↔ 4. Edit `BUTTON_MAP` in [`whisper_mouse_eventtap.lua`](file:///Users/jwon/whisper-mac/hammerspoon/whisper_mouse_eventtap.lua#L14-L18) and swap the `[3]` and `[4]` entries, then run `hs -c 'hs.reload()'`.

To discover what your mouse actually reports, temporarily uncomment-style: add this probe in the eventtap callback (or run as a one-shot):

```lua
hs.eventtap.new({hs.eventtap.event.types.otherMouseDown}, function(ev)
    local btn = ev:getProperty(hs.eventtap.event.properties.mouseEventButtonNumber)
    hs.alert.show("button " .. btn)
    return false
end):start()
```

Press each side button, read the alert, update `BUTTON_MAP` accordingly.

## Related files

- [`hammerspoon/whisper_mouse_eventtap.lua`](file:///Users/jwon/whisper-mac/hammerspoon/whisper_mouse_eventtap.lua) — the eventtap module (autoruns at module load).
- [`hammerspoon/whisper_mouse.lua`](file:///Users/jwon/whisper-mac/hammerspoon/whisper_mouse.lua) — the Ctrl+Shift+Cmd+9/0/8 hotkey bindings the eventtap synthesizes.
- [`hammerspoon/init.lua`](file:///Users/jwon/whisper-mac/hammerspoon/init.lua) — loads both modules.
- [`bin/sync_hammerspoon.sh`](file:///Users/jwon/whisper-mac/bin/sync_hammerspoon.sh) — keeps `~/.hammerspoon/` in sync with the repo copy.
