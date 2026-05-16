# MPKMiniMapper Specification

This file is the authoritative reference for the MPKMiniMapper project. When in doubt about intended behavior, this document takes precedence. Read this file in full before writing any code.

Last updated: 2026-05-14

---

## ⚠ MANDATORY FIRST STEP — DO THIS BEFORE ANYTHING ELSE

**Before reading this spec, before touching any file, before writing a single line of code:**

1. Run `git log --oneline --all` from `C:\Users\micha\Dropbox\MPKMiniMapper` to list every commit on every branch.
2. List `C:\Users\micha\Dropbox\MPKMiniMapper\.claude\worktrees\` and check each worktree for uncommitted changes (`git diff --stat HEAD` in each one).
3. The newest `Scripts/MPKMiniMapper.lua` — whether on a branch tip or as uncommitted work in a worktree — is the one true baseline. All edits must be made on top of it.

**Working from any older version will cause regressions. There is no exception to this rule.**

---

## PROJECT OVERVIEW

Build a REAPER Lua script called MPKMiniMapper that simplifies MIDI controller mapping for the Akai MPK Mini MK3. The script runs as a single file with no external dependencies, launched from a REAPER toolbar button. It runs silently in the background handling real-time MIDI processing, with an optional floating window the user opens only when needed.

Also create a README.md explaining installation and usage, and an install.bat that copies files to the correct REAPER folders on Windows.

---

## REPOSITORY STRUCTURE

```
MPKMiniMapper/
├── Scripts/
│   └── MPKMiniMapper.lua
├── docs/
│   └── SPEC.md
├── README.md
└── install.bat
```

---

## HARDWARE — AKAI MPK MINI MK3

Physical layout to mirror exactly in the UI:

```
PAD5  PAD6  PAD7  PAD8      K1  K2  K3  K4
PAD1  PAD2  PAD3  PAD4      K5  K6  K7  K8
```

Hardware configuration:
- Bank A pads set to Prog Select mode
- Pads send Program Change messages 1–8 on MIDI channel 1
- Knobs send CC 70–77 (auto-detected and verified on first launch)
- Bank B completely free — no predefined assignments, open for user customization

---

## BANK SYSTEM

All banks follow the currently selected track in REAPER. Switching tracks updates all banks instantly. The active pad determines which layer of that track the knobs control. Banks are switched via incoming Program Change messages 1–8.

| Physical Pad | Bank                  | Color      |
|--------------|-----------------------|------------|
| Pad 1        | Follow Selected Track | Blue       |
| Pad 2        | Reverb                | Purple     |
| Pad 3        | Delay                 | Teal       |
| Pad 4        | Pan                   | Orange     |
| Pad 5        | EQ                    | Green      |
| Pad 6        | Distortion            | Red        |
| Pad 7        | Modulation            | Yellow     |
| Pad 8        | Drums                 | White      |
| Bank B       | Fully open/custom     | User defined |

---

## BANK 1 — FOLLOW SELECTED TRACK

Knobs control broad mix parameters on the currently selected track. Switching tracks updates all knobs instantly.

| Knob | Position       | Parameter            | Default Value       |
|------|----------------|----------------------|---------------------|
| K1   | Top left       | Track Volume         | 0dB                 |
| K2   | Top second     | Track Pan            | Center              |
| K3   | Top third      | Track Pitch          | 0 semitones         |
| K4   | Top right      | High Pass Frequency  | Minimum frequency   |
| K5   | Bottom left    | Playhead Scrub       | No reset button     |
| K6   | Bottom second  | Reverb Wet           | Plugin default      |
| K7   | Bottom third   | Delay Wet            | Plugin default      |
| K8   | Bottom right   | Low Pass Frequency   | Maximum frequency   |

Notes:
- K1–K4 and K8 target REAPER track properties directly
- K5 scrub is the only global control — unaffected by track selection. Relative mode with adjustable sensitivity slider in the UI
- K6 and K7 scan the selected track FX chain for the first plugin categorized as Reverb/Delay and target its wet/dry parameter. Go silently inactive if no matching plugin exists on the track
- K4 and K8 form a natural filter pair — high pass top right, low pass bottom right

### Drum Pad Mapping in Bank 1

- When a track is selected, script auto-detects any recognized drum plugin on that track
- Pad map switches automatically to that plugin's saved layout
- If no drum plugin found, pads revert to default note assignments
- An unobtrusive dropdown and edit button allow manual override
- Edit button opens an inline mini pad mapping UI — no need to switch to Bank 8
- All drum plugin profiles are shared between Bank 1 and Bank 8 — set up once, works in both places

---

## BANKS 2–7 — PLUGIN CATEGORY BANKS

Each bank targets a specific plugin type on the selected track. Knobs 1–8 are fully assignable via dropdown menus populated from the plugin's full exposed parameter list via `reaper.TrackFX_GetParamName()`.

### First Time a Plugin is Encountered in a Bank

1. Script scans every parameter the plugin exposes
2. Populates 8 dropdown menus — one per knob — with the full parameter list
3. Pre-selects the most likely parameters based on category priority list below
4. User confirms or reassigns each dropdown — never auto-applied
5. Saved permanently to that plugin's profile
6. Never prompted again unless manually edited

### Behavior

- No matching plugin on selected track → all knobs silently inactive
- Multiple matching plugins on track → first one in FX chain used
- Different plugins, same bank → each gets fully independent knob mappings
- All knobs in banks 2–7 reset to plugin exposed default via `reaper.TrackFX_SetParamNormalized()`

### Default Parameter Priority Lists

Matched loosely against actual parameter names so minor naming differences are still caught.

| Bank       | Priority Parameters (in order)                                                                 |
|------------|-----------------------------------------------------------------------------------------------|
| Reverb     | Wet/Dry, Room Size, Decay/RT60, Pre-delay, Damping, Diffusion, Low Cut, High Cut              |
| Delay      | Wet/Dry, Time/BPM Sync, Feedback, High Cut, Low Cut, Modulation Rate, Modulation Depth, Mix   |
| Pan        | Width, Pan, Stereo Balance, Left Gain, Right Gain, Rotation, Divergence, Mix                  |
| EQ         | Low Shelf Gain, High Shelf Gain, Low Pass Freq, High Pass Freq, Mid Freq, Mid Gain, Mid Q, Output Gain |
| Distortion | Drive/Amount, Tone, Output Level, Wet/Dry, Bass, Treble, Gate, Bias                           |
| Modulation | Rate, Depth, Wet/Dry, Feedback, Stereo Width, Phase, Waveform, Mix                            |

---

## BANK 8 — DRUMS

Dedicated drum control surface. Pads and knobs both fully functional and saved per plugin instance. Profiles shared with Bank 1.

### Pad Mapping

- Each of the 8 pads assigned a target MIDI note via keyboard picker in Setup mode
- Friendly label per pad ("Kick", "Snare", "Hi-Hat" etc.)
- Script intercepts pad MIDI output and silently transposes to target note
- Per plugin instance — each drum plugin has its own saved pad map
- First time a drum plugin is seen — all 8 pads start unassigned, user is prompted to map them
- No reset button for pads — pad maps are intentional remappings

### Knob Assignments — Individual Drum Part Volumes

All knobs reset to plugin exposed default via `reaper.TrackFX_SetParamNormalized()`.

| Knob | Position       | Default Target        |
|------|----------------|-----------------------|
| K1   | Top left       | Kick Volume           |
| K2   | Top second     | Snare Volume          |
| K3   | Top third      | Hi-Hat Volume         |
| K4   | Top right      | Open Hi-Hat Volume    |
| K5   | Bottom left    | Crash Volume          |
| K6   | Bottom second  | Ride Volume           |
| K7   | Bottom third   | Tom Volume            |
| K8   | Bottom right   | Overhead/Room Volume  |

### Drum Parameter Keyword Matching

| Drum Part      | Keywords                          |
|----------------|-----------------------------------|
| Kick           | "Kick", "BD", "Bass Drum"         |
| Snare          | "Snare", "SD"                     |
| Hi-Hat         | "Hi-Hat", "HH", "Closed Hat"      |
| Open Hi-Hat    | "Open Hat", "OH"                  |
| Crash          | "Crash", "CY"                     |
| Ride           | "Ride"                            |
| Tom            | "Tom", "TM"                       |
| Overhead/Room  | "Overhead", "Room", "OHD"         |

---

## PLUGIN DETECTION & LIBRARY MANAGER

### Detection Flow for Every New Plugin

1. Name match against built-in lookup table
2. If no name match, analyze parameter names for category keywords
3. Best guess pre-fills the category dropdown (or "Unknown" if no confident guess)
4. Never auto-applied — always requires user confirmation
5. Once confirmed, never prompted again unless manually edited

### Built-in Lookup Table

| Category   | Plugin Names                                                                                  |
|------------|-----------------------------------------------------------------------------------------------|
| Reverb     | ReaVerb, ValhallaRoom, ValhallaVintageVerb, RC-48, H-Reverb, Abbey Road Plates, ChromaVerb   |
| Delay      | ReaDelay, EchoBoy, H-Delay, ValhallaDelay, Carbon Delay, Replika                             |
| Pan        | Haas, Pangaea, S1 Stereo Imager, Imager, Width                                               |
| EQ         | ReaEQ, FabFilter Pro-Q, SSL 4000E, Neve 1073, API 550                                        |
| Distortion | Decapitator, Saturn 2, RC-20, Trash 2, Devastator                                            |
| Modulation | ReaChorus, MicroShift, Chorus, Flanger, Phaser, UltraChannel                                 |
| Drums      | EZDrummer, Superior Drummer, BFD, Addictive Drums, Steven Slate Drums, MT-Power Drum Kit, Abbey Road Drummer |

### Library Manager UI

- Scrollable list of every encountered plugin
- Columns: Plugin Name, Guessed Category, Confirmed Category, Status (Confirmed/Unconfirmed)
- Every entry editable at any time

---

## RESET BEHAVIOR

### Bank 1

| Knob | Reset Target           | Default Value       |
|------|------------------------|---------------------|
| K1   | REAPER track property  | 0dB                 |
| K2   | REAPER track property  | Center              |
| K3   | REAPER track property  | 0 semitones         |
| K4   | REAPER track property  | Minimum frequency   |
| K5   | No reset button        | N/A                 |
| K6   | Plugin exposed default | Plugin default      |
| K7   | Plugin exposed default | Plugin default      |
| K8   | REAPER track property  | Maximum frequency   |

### Banks 2–7

All 8 knobs in every bank reset to plugin exposed default via `reaper.TrackFX_SetParamNormalized()`.

### Bank 8 — Drums

| Control | Reset Target           | Default        |
|---------|------------------------|----------------|
| K1–K8   | Plugin exposed default | Plugin default |
| Pads    | No reset button        | N/A            |

### Reset Button Visibility by Mode

| Mode      | Reset Button Behavior                                                      |
|-----------|----------------------------------------------------------------------------|
| Mini      | No reset buttons                                                           |
| Dashboard | Hover over any knob label reveals subtle ↺ button                         |
| Setup     | Explicit reset button visible in Parameter Assignment Panel for every knob |

---

## FLOATING WINDOW — THREE MODES

The window remembers which mode it was in when last closed and reopens in that state.

---

### Mode 1 — Mini

Smallest footprint. Pure display, no controls. Designed to sit in a corner all session without getting in the way.

Displays:
- Current bank name and color indicator
- Selected track name
- Knob labels in exact hardware layout — 2 rows of 4:

```
K1: [label]    K2: [label]    K3: [label]    K4: [label]
K5: [label]    K6: [label]    K7: [label]    K8: [label]
```

- Inactive knobs shown dimmed
- No pad display

Controls:
- [ Dashboard ] and [ Setup ] navigation buttons only

---

### Mode 2 — Dashboard

Mid-size. At-a-glance status with minimal controls.

Displays:
- Selected track name and active bank name
- 8 colored bank indicator dots — filled if matching plugin present on track, empty if not, colors matching pad bank colors
- Active bank highlighted
- Knob labels in hardware layout — 2 rows of 4
- Hover over any knob label reveals subtle ↺ reset button — clicking resets that parameter to its default value

Controls:
- Scrub sensitivity slider
- [ Mini ] and [ Setup ] navigation buttons

---

### Mode 3 — Setup

Full configuration UI.

#### MIDI Learn Panel

- Visual MPK Mini MK3 layout matching exact physical hardware
- Knobs in 2 rows of 4 (K1–K4 top, K5–K8 bottom)
- Pads in 2 rows of 4 (Pads 5–8 top, Pads 1–4 bottom)
- Auto-select mode — touch a knob on hardware and it highlights in the UI automatically
- Highlighted knob shows CC number, current bank, mapped parameter
- Pads show bank name and assigned color

#### Parameter Assignment Panel

Appears when a knob is selected:
- CC number (auto-detected)
- Friendly name text field
- Parameter dropdown populated from plugin's full exposed parameter list
- Min/max range sliders
- Relative vs absolute toggle
- Explicit reset to default button

#### Pad Mapping Panel

Appears when a pad is selected:
- Keyboard picker for target MIDI note assignment
- Friendly label text field
- Profiles shared across Bank 1 and Bank 8

#### Plugin Library Manager

- Scrollable list of all encountered plugins
- Columns: Plugin Name, Guessed Category, Confirmed Category, Status (Confirmed/Unconfirmed)
- Every entry editable at any time

#### Preset Panel

- Preset name text field
- Save button — writes MPKMiniMapper_config.json next to current project .RPP file
- Load button — file picker filtered to .json files
- Config auto-loads on project open

Navigation:
- [ Mini ] and [ Dashboard ] buttons

---

## CONFIG FILE

- Format: JSON
- Filename: MPKMiniMapper_config.json
- Location: Saved alongside the current REAPER project .RPP file — project-relative so projects are fully portable
- Auto-loaded on project open
- Written by Save button, read on startup and project load

Stores:
- CC numbers for each knob
- Active bank
- All plugin profiles (parameter assignments per plugin per bank)
- Plugin library (name to category mappings and confirmation status)
- Pad maps per drum plugin instance
- Scrub sensitivity setting
- Window mode (Mini/Dashboard/Setup)
- Preset name

---

## TECHNICAL REQUIREMENTS

- REAPER 6.0+
- Pure Lua using REAPER's native reaper API only
- No external dependencies
- Windows file paths throughout
- `reaper.TrackFX_GetParamName()` for parameter enumeration
- `reaper.TrackFX_SetParamNormalized()` for parameter control and reset to default
- `reaper.SetEditCurPos()` for relative playhead scrubbing
- `reaper.GetSelectedTrack()` for selected track following
- Program Change messages intercepted for bank switching without passing through
- MIDI note interception and transposition for drum pad remapping
- Relative mode scrubbing with sensitivity stored in config
- Code well commented throughout

---

## INSTALL.BAT

Copies MPKMiniMapper.lua to:

```
C:\Users\%USERNAME%\AppData\Roaming\REAPER\Scripts\
```

---

## README.MD

Include:
- Installation steps (run install.bat, load ReaScript in REAPER, add toolbar button)
- MPK Mini MK3 hardware setup instructions (Bank A Prog Select mode)
- Basic usage walkthrough covering all three window modes
- Bank system explanation
- First session setup guide
- How presets are saved and loaded
