# MPKMiniMapper

A REAPER Lua script that turns the **Akai MPK Mini MK3** into an intelligent, multi-bank MIDI controller surface — one script, no external dependencies, launched from a toolbar button.

---

## Requirements

- REAPER 6.0 or later
- Akai MPK Mini MK3
- Windows (install.bat targets Windows paths)

---

## Installation

### Automatic (recommended)

1. Double-click **install.bat**.  
   It copies `MPKMiniMapper.lua` to  
   `C:\Users\<you>\AppData\Roaming\REAPER\Scripts\`.

### Manual

1. Copy `Scripts\MPKMiniMapper.lua` to your REAPER Scripts folder:  
   `C:\Users\<you>\AppData\Roaming\REAPER\Scripts\`

### Load the script in REAPER

1. Open REAPER → **Actions** → **Show Action List**.
2. Click **New Action** → **Load ReaScript…**
3. Navigate to the Scripts folder and select `MPKMiniMapper.lua`.
4. The action will appear as `Script: MPKMiniMapper.lua`.

### Add a toolbar button

1. Right-click any REAPER toolbar → **Customize toolbar…**
2. Find `Script: MPKMiniMapper.lua` in the action list and drag it onto the toolbar.
3. Press the toolbar button to launch the script (and open the window).

---

## MPK Mini MK3 Hardware Setup

The script expects **Bank A** to be configured in **Prog Select mode**:

1. On the MPK Mini MK3, hold **PROG CHANGE** and press **PAD BANK A** to enter Prog Select mode.
2. Pads will now send **Program Change messages 1–8** on MIDI channel 1.
3. Knobs should already send **CC 70–77** by default — the script verifies this on first use via MIDI Learn if needed.

Bank B is completely free; you can configure it however you like outside of this script.

---

## Basic Usage

Press the toolbar button to open the floating window. The script runs silently in the background even when the window is closed — bank switching and knob control continue working.

Press the button again to re-open the window. The window remembers which mode it was in when last closed.

---

## Three Window Modes

### Mini (smallest footprint)

Shows only what you need at a glance:

- Current bank name and color
- Selected track name
- All 8 knob labels (K1–K8) with inactive knobs dimmed
- **Dashboard** and **Setup** navigation buttons

### Dashboard (at-a-glance control)

Adds interactivity without getting in the way:

- 8 colored bank indicator dots — filled if a matching plugin is on the track, empty if not
- Hover over any knob label to reveal a subtle **↺ Reset** button
- **Scrub Sensitivity** slider for the playhead scrub knob (K5)
- **Mini** and **Setup** navigation buttons

### Setup (full configuration)

Complete control surface editor:

- **MIDI Learn panel** — visual MPK Mini layout; touch any knob on hardware to highlight it; assign CC numbers
- **Parameter Assignment panel** — dropdown of all plugin parameters; min/max range; reset button
- **Pad Mapping panel** — keyboard note picker and friendly pad labels (shared between Bank 1 and Bank 8)
- **Plugin Library** — scrollable list of every plugin the script has seen; click a row to cycle its confirmed category
- **Preset panel** — save and load `MPKMiniMapper_config.json` alongside your project

---

## Bank System

All banks follow the **currently selected track** in REAPER. Switching tracks updates every bank instantly. Change banks by pressing **Pads 1–8** on the hardware (Bank A, Prog Select mode).

| Pad | Bank                  | Color      |
|-----|-----------------------|------------|
| 1   | Follow Selected Track | Blue       |
| 2   | Reverb                | Purple     |
| 3   | Delay                 | Teal       |
| 4   | Pan                   | Orange     |
| 5   | EQ                    | Green      |
| 6   | Distortion            | Red        |
| 7   | Modulation            | Yellow     |
| 8   | Drums                 | White      |

### Bank 1 — Follow Selected Track

| Knob | Parameter         | Notes                                 |
|------|-------------------|---------------------------------------|
| K1   | Track Volume      | Resets to 0 dB                        |
| K2   | Track Pan         | Resets to center                      |
| K3   | Track Pitch       | –12 to +12 semitones; resets to 0     |
| K4   | High Pass Freq    | Delegates to first EQ plugin on track |
| K5   | Playhead Scrub    | Relative mode; no reset button        |
| K6   | Reverb Wet        | First reverb plugin on track          |
| K7   | Delay Wet         | First delay plugin on track           |
| K8   | Low Pass Freq     | Delegates to first EQ plugin on track |

K6 and K7 go silently inactive when no matching plugin is on the track.

### Banks 2–7 — Plugin Category Banks

Each bank scans the selected track's FX chain for the first plugin of that type (Reverb, Delay, Pan, EQ, Distortion, Modulation). Knobs 1–8 are fully assignable via dropdown in Setup mode.

**First time a new plugin is encountered:**
1. The script scans all exposed parameters.
2. It pre-selects the most likely parameters based on built-in keyword lists.
3. You confirm or reassign each knob in Setup mode — changes are never auto-applied.
4. The mapping is saved permanently; you will not be prompted again unless you edit it.

### Bank 8 — Drums

- **Pads** are remapped to any MIDI note via the Setup pad mapping panel.
- **Knobs** target individual drum part volumes (Kick, Snare, Hi-Hat, etc.) — matched by keyword.
- Drum pad profiles are **shared between Bank 1 and Bank 8** — configure once, works in both.

---

## Plugin Detection

When the script first sees a plugin it has not seen before:

1. It checks the plugin name against a built-in lookup table (common plugins listed for each category).
2. If no name match, it analyses the plugin's parameter names for category keywords.
3. The best guess is shown in the Plugin Library as **Unconfirmed**.
4. Open **Setup → Plugin Library** and click a row to cycle its confirmed category.

Once confirmed, the plugin is permanently remembered in your project config.

---

## First Session Setup Guide

1. Open a REAPER project.
2. Press the MPKMiniMapper toolbar button.
3. Switch to **Setup** mode.
4. In the **MIDI Learn** section, touch each knob on the hardware to auto-assign its CC number.
5. Add some plugins to a track. Select the track — the script scans automatically.
6. Check the **Plugin Library** at the bottom; click any Unconfirmed entry to set its category.
7. With Bank 2 (Reverb) active, select a knob in the hardware layout to open its **Parameter Assignment** panel; choose the parameter from the dropdown.
8. When everything looks right, click **Save** in the Preset panel.

The config file is saved next to your `.RPP` project file so your setup travels with the project.

---

## Presets and Config File

- **File:** `MPKMiniMapper_config.json`
- **Location:** Same folder as the current REAPER project `.RPP` file
- **Auto-loaded** when REAPER opens a project
- **Save / Load** buttons in Setup → Preset panel

The config stores: CC assignments, active bank, all plugin profiles, the plugin library, drum pad maps, scrub sensitivity, and last-used window mode.

---

## Reset Behavior Summary

| Context         | What resets              | Default           |
|-----------------|--------------------------|-------------------|
| K1 (Bank 1)     | REAPER track volume      | 0 dB              |
| K2 (Bank 1)     | REAPER track pan         | Center            |
| K3 (Bank 1)     | REAPER track pitch       | 0 semitones       |
| K4 / K8 (Bank 1)| EQ high/low-pass freq    | Min / Max freq    |
| K5 (Bank 1)     | No reset button          | —                 |
| K6–K7 (Bank 1)  | Plugin exposed default   | Plugin default    |
| Banks 2–7       | Plugin exposed default   | Plugin default    |
| Bank 8 knobs    | Plugin exposed default   | Plugin default    |
| Bank 8 pads     | No reset button          | —                 |

In Dashboard mode, hover any active knob label to reveal a reset button.  
In Setup mode, an explicit reset button appears in the Parameter Assignment panel.
