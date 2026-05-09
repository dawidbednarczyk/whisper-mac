# Logi Options+ — Internals & AI Agent Notes

This document is for **future AI agents and contributors** debugging or
automating Logi Options+ integration. Regular users should follow the
device-specific setup guide (e.g. [`docs/m750-setup.md`](../m750-setup.md))
and stop reading here.

---

## Why this doc exists

Multiple AI sessions have independently tried to "just script the button
mapping" for Logitech mice and run into the same dead ends:

- There is no CLI.
- The settings file is a SQLite blob, not a JSON file you can edit.
- The bundled defaults JSON is read-only and not user-writable.
- The blob is empty until the user clicks through the GUI at least once.

This doc captures the findings so the next agent doesn't burn context
re-discovering them.

---

## Where settings live

```
~/Library/Application Support/LogiOptionsPlus/
├── settings.db                 ← user-specific, SQLite, contains JSON blob
├── settings.db-wal
├── settings.db-shm
├── permissions.json
├── macros.db                   ← macro definitions (separate from button bindings)
└── flow/devices/               ← device-specific multi-host flow config
```

```
/Library/Application Support/Logitech.localized/LogiOptionsPlus/
└── logioptionsplus_agent.app/Contents/Resources/data/
    ├── defaults/defaults_control_osx.json    ← READ-ONLY shipped defaults
    ├── defaults/defaults_slot_osx.json
    └── ...
```

### `settings.db` schema

```sql
CREATE TABLE data(
    _id INTEGER PRIMARY KEY,
    _date_created datetime DEFAULT current_timestamp,
    file BLOB NOT NULL                      -- JSON, UTF-8 text, ~60 KB typical
);
CREATE TABLE snapshots(
    _id INTEGER PRIMARY KEY,
    _date_created datetime DEFAULT current_timestamp,
    uuid TEXT NOT NULL,
    label TEXT NOT NULL,
    file BLOB NOT NULL
);
```

To extract the JSON for inspection:

```bash
sqlite3 ~/Library/Application\ Support/LogiOptionsPlus/settings.db \
    "SELECT writefile('/tmp/logi_settings.json', file) FROM data WHERE _id=1;"
python3 -m json.tool /tmp/logi_settings.json | less
```

### Relevant top-level JSON keys

| Key | Purpose |
|---|---|
| `ever_connected_devices.devices[]` | Connected device inventory. Each entry has `serialNumber`, `slotPrefix` (e.g. `signature-m750-2b02c`), `deviceModel`, `connectionType`. |
| `analytics_seen_devices_v2` | Device model IDs (e.g. `2b02c-2`). |
| `known_device_unitids` | Logitech-internal unit IDs. |
| `dfu/<serial>/...` | Firmware update state per device. |

### Where button bindings ARE NOT

Per-button keystroke assignments do **not** exist as top-level JSON keys
until the user opens the GUI and saves at least one mapping. Even then,
they live in nested device-specific subtrees that vary by mouse model and
Logi Options+ version. There is no documented schema; the JSON is an
implementation detail of the Electron app.

---

## What you cannot do

- ❌ **Set button bindings via CLI.** No `logi-options-plus assign` command.
  No AppleScript dictionary on the app bundle.
- ❌ **Roundtrip settings.db across machines.** Device serial numbers and
  internal UUIDs are baked into the blob.
- ❌ **Write to `defaults_control_osx.json`.** It's in `/Library`,
  read-only, and overwritten on app updates.
- ❌ **Inject bindings by editing the SQLite blob.** Without a documented
  schema and signature/integrity checks, edits silently corrupt the
  user's profile.
- ❌ **Map a button before the user pairs the device once via the GUI.**
  Settings are device-keyed.

---

## What you CAN do

- ✅ **Detect installation:** `[ -d /Applications/logioptionsplus.app ]`.
- ✅ **Detect running:** `pgrep -f logioptionsplus_agent`.
- ✅ **Launch the GUI:** `open -a logioptionsplus`.
- ✅ **Install via Homebrew:** `brew install --cask logi-options-plus`.
- ✅ **Read the device inventory** from `settings.db` (see SQL above) to
  confirm a specific device is paired.
- ✅ **Read the bundled defaults** to discover supported control IDs per
  device for documentation purposes.
- ✅ **Tell the user precisely which buttons to map and to what keystrokes**
  — this is the only path. See [`docs/m750-setup.md`](../m750-setup.md)
  for the recommended user-facing instructions.

---

## Conflicts with native eventtaps

When Logi Options+ has Input Monitoring permission and is running, it
intercepts **all** extra mouse button events globally before any
third-party eventtap (e.g. Hammerspoon's `hs.eventtap`) can see them.

This is documented user behavior on Apple StackExchange
(<https://apple.stackexchange.com/q/418485>) and confirmed in this repo.
The two paths in [`docs/mouse-decision-guide.md`](../mouse-decision-guide.md)
are mutually exclusive for this reason.

If you need both eventtap behavior and Logi Options+ for the same mouse,
the only working pattern is: map every extra button in Logi Options+ to a
distinct keystroke, then let Hammerspoon `hs.hotkey.bind` to those
keystrokes. Do not rely on `hs.eventtap` seeing physical button presses.

---

## Useful one-liners for AI agents

```bash
# Is Logi Options+ installed and running?
[ -d /Applications/logioptionsplus.app ] && pgrep -fl logioptionsplus_agent

# What devices does the user have paired?
sqlite3 ~/Library/Application\ Support/LogiOptionsPlus/settings.db \
    "SELECT writefile('/tmp/lop.json', file) FROM data WHERE _id=1;" \
  && python3 -c "import json; d=json.load(open('/tmp/lop.json')); \
       [print(x['deviceModel'], x.get('slotPrefix'), x['serialNumber']) \
        for x in d['ever_connected_devices']['devices']]"

# Has the user ever opened Logi Options+ for a specific device?
# (Heuristic: look for slotPrefix in the blob beyond the inventory section.)
grep -c "signature-m750-2b02c" /tmp/lop.json
```

---

## When to recommend the Logi Options+ path vs the eventtap path

| Situation | Recommend |
|---|---|
| Mouse model has buttons not exposed to macOS without vendor driver (M750 gesture button is the canonical example) | Logi Options+ |
| User already has Logi Options+ installed for other devices | Logi Options+ |
| User wants per-app button behavior, OSD feedback, or DPI control | Logi Options+ |
| User refuses any third-party background apps | Native eventtap |
| Mouse is non-Logitech | Native eventtap |
| Setup is for a CI / headless / fleet scenario | Native eventtap (Logi Options+ requires GUI interaction) |
