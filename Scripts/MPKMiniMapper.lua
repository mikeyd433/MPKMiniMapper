-- ============================================================
-- MPKMiniMapper v1.0
-- REAPER Lua Script for Akai MPK Mini MK3
--
-- Runs as a deferred background script. Launch via a REAPER
-- toolbar button. The floating window is optional — open it
-- only when needed. Processes MIDI in the background always.
--
-- Hardware assumed:
--   Bank A pads → Program Change 1-8, channel 1
--   Knobs       → CC 70-77 (auto-detected on first launch)
--   Bank B      → fully open/custom
--
-- Requires REAPER 6.0+ with Lua scripting enabled.
-- ============================================================

-- ============================================================
-- MINIMAL JSON ENCODER / DECODER
-- No external dependencies. Handles the subset of JSON used
-- by this script: objects, arrays, strings, numbers, booleans.
-- ============================================================

local json = {}

function json.encode(val)
  local t = type(val)
  if t == "nil" then
    return "null"
  elseif t == "boolean" then
    return tostring(val)
  elseif t == "number" then
    return tostring(val)
  elseif t == "string" then
    return '"' .. val
      :gsub('\\', '\\\\')
      :gsub('"',  '\\"')
      :gsub('\n', '\\n')
      :gsub('\r', '\\r')
      :gsub('\t', '\\t') .. '"'
  elseif t == "table" then
    -- Detect array vs object
    local n = 0
    local max_idx = 0
    for k, _ in pairs(val) do
      n = n + 1
      if type(k) == "number" and k == math.floor(k) and k >= 1 then
        if k > max_idx then max_idx = k end
      else
        max_idx = -1  -- has non-integer key
      end
    end
    local is_array = (max_idx == n and n > 0) or n == 0

    if is_array then
      local parts = {}
      for i, v in ipairs(val) do
        parts[i] = json.encode(v)
      end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      local parts = {}
      for k, v in pairs(val) do
        if type(k) == "string" or type(k) == "number" then
          parts[#parts + 1] = json.encode(tostring(k)) .. ":" .. json.encode(v)
        end
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  end
  return "null"
end

function json.decode(str)
  if not str or str == "" then return nil end
  local pos = 1

  local function skip_ws()
    while pos <= #str and str:sub(pos, pos):match("%s") do pos = pos + 1 end
  end

  local parse_value  -- forward declaration

  local function parse_string()
    pos = pos + 1  -- skip opening "
    local s = ""
    while pos <= #str do
      local c = str:sub(pos, pos)
      if c == '"' then pos = pos + 1; return s end
      if c == '\\' then
        pos = pos + 1
        local e = str:sub(pos, pos)
        local esc = {['"']='"', ['\\']='\\', ['/']=''/'', n='\n', r='\r', t='\t', b='\b', f='\f'}
        s = s .. (esc[e] or e)
      else
        s = s .. c
      end
      pos = pos + 1
    end
    return s
  end

  local function parse_object()
    pos = pos + 1  -- skip {
    local obj = {}
    skip_ws()
    if str:sub(pos, pos) == '}' then pos = pos + 1; return obj end
    while true do
      skip_ws()
      local key = parse_string()
      skip_ws()
      pos = pos + 1  -- skip :
      local val = parse_value()
      obj[key] = val
      skip_ws()
      local ch = str:sub(pos, pos)
      pos = pos + 1
      if ch == '}' then break end
      -- ch == ','  continue
    end
    return obj
  end

  local function parse_array()
    pos = pos + 1  -- skip [
    local arr = {}
    skip_ws()
    if str:sub(pos, pos) == ']' then pos = pos + 1; return arr end
    while true do
      arr[#arr + 1] = parse_value()
      skip_ws()
      local ch = str:sub(pos, pos)
      pos = pos + 1
      if ch == ']' then break end
    end
    return arr
  end

  parse_value = function()
    skip_ws()
    local c = str:sub(pos, pos)
    if c == '"' then
      return parse_string()
    elseif c == '{' then
      return parse_object()
    elseif c == '[' then
      return parse_array()
    elseif c == 't' then
      pos = pos + 4; return true
    elseif c == 'f' then
      pos = pos + 5; return false
    elseif c == 'n' then
      pos = pos + 4; return nil
    else
      local num_str = str:match("^%-?%d+%.?%d*[eE]?[+%-]?%d*", pos)
      if num_str then
        pos = pos + #num_str
        return tonumber(num_str)
      end
    end
    return nil
  end

  local ok, result = pcall(parse_value)
  return ok and result or nil
end

-- ============================================================
-- CONSTANTS
-- ============================================================

local SCRIPT_NAME = "MPKMiniMapper"
local VERSION     = "1.0"

-- Bank IDs — mirror the Program Change values 1-8
local BANK_FOLLOW = 1
local BANK_REVERB = 2
local BANK_DELAY  = 3
local BANK_PAN    = 4
local BANK_EQ     = 5
local BANK_DIST   = 6
local BANK_MOD    = 7
local BANK_DRUMS  = 8

local BANK_NAMES = {
  [BANK_FOLLOW] = "Follow Selected Track",
  [BANK_REVERB] = "Reverb",
  [BANK_DELAY]  = "Delay",
  [BANK_PAN]    = "Pan",
  [BANK_EQ]     = "EQ",
  [BANK_DIST]   = "Distortion",
  [BANK_MOD]    = "Modulation",
  [BANK_DRUMS]  = "Drums",
}

-- Bank accent colors {r,g,b} in 0-1 range
local BANK_COLORS = {
  [BANK_FOLLOW] = {0.20, 0.50, 1.00},
  [BANK_REVERB] = {0.70, 0.30, 0.90},
  [BANK_DELAY]  = {0.20, 0.80, 0.80},
  [BANK_PAN]    = {1.00, 0.60, 0.10},
  [BANK_EQ]     = {0.30, 0.90, 0.30},
  [BANK_DIST]   = {0.90, 0.20, 0.20},
  [BANK_MOD]    = {1.00, 0.90, 0.10},
  [BANK_DRUMS]  = {0.90, 0.90, 0.90},
}

-- Bank → plugin category string (used for FX chain scan)
local BANK_TO_CAT = {
  [BANK_REVERB] = "Reverb",
  [BANK_DELAY]  = "Delay",
  [BANK_PAN]    = "Pan",
  [BANK_EQ]     = "EQ",
  [BANK_DIST]   = "Distortion",
  [BANK_MOD]    = "Modulation",
  [BANK_DRUMS]  = "Drums",
}

-- Default CC numbers for the 8 knobs (MPK Mini MK3 Bank A defaults)
local DEFAULT_KNOB_CCS = {70, 71, 72, 73, 74, 75, 76, 77}

-- Built-in plugin name → category lookup table
local PLUGIN_NAME_TABLE = {
  Reverb     = {"ReaVerb","ValhallaRoom","ValhallaVintageVerb","RC-48","H-Reverb",
                "Abbey Road Plates","ChromaVerb"},
  Delay      = {"ReaDelay","EchoBoy","H-Delay","ValhallaDelay","Carbon Delay","Replika"},
  Pan        = {"Haas","Pangaea","S1 Stereo Imager","Imager","Width"},
  EQ         = {"ReaEQ","FabFilter Pro-Q","SSL 4000E","Neve 1073","API 550"},
  Distortion = {"Decapitator","Saturn 2","RC-20","Trash 2","Devastator"},
  Modulation = {"ReaChorus","MicroShift","Chorus","Flanger","Phaser","UltraChannel"},
  Drums      = {"EZDrummer","Superior Drummer","BFD","Addictive Drums",
                "Steven Slate Drums","MT-Power Drum Kit","Abbey Road Drummer"},
}

-- Priority parameter keywords per category — matched loosely against actual param names
local PARAM_PRIORITIES = {
  Reverb     = {"Wet","Dry","Room Size","Decay","RT60","Pre-delay","Damping",
                "Diffusion","Low Cut","High Cut"},
  Delay      = {"Wet","Dry","Time","BPM","Feedback","High Cut","Low Cut",
                "Modulation Rate","Modulation Depth","Mix"},
  Pan        = {"Width","Pan","Stereo Balance","Left Gain","Right Gain",
                "Rotation","Divergence","Mix"},
  EQ         = {"Low Shelf Gain","High Shelf Gain","Low Pass","High Pass",
                "Mid Freq","Mid Gain","Mid Q","Output Gain"},
  Distortion = {"Drive","Amount","Tone","Output Level","Wet","Dry",
                "Bass","Treble","Gate","Bias"},
  Modulation = {"Rate","Depth","Wet","Dry","Feedback","Stereo Width",
                "Phase","Waveform","Mix"},
}

-- Drum part definitions: label and keywords for auto-matching plugin parameters
local DRUM_PARTS = {
  {label="Kick",          kw={"Kick","BD","Bass Drum"}},
  {label="Snare",         kw={"Snare","SD"}},
  {label="Hi-Hat",        kw={"Hi-Hat","HH","Closed Hat"}},
  {label="Open Hi-Hat",   kw={"Open Hat","OH"}},
  {label="Crash",         kw={"Crash","CY"}},
  {label="Ride",          kw={"Ride"}},
  {label="Tom",           kw={"Tom","TM"}},
  {label="Overhead/Room", kw={"Overhead","Room","OHD"}},
}

-- Bank 1 knob labels (static, track-specific labels added at runtime)
local BANK1_LABELS = {
  "Track Volume", "Track Pan", "Track Pitch", "High Pass Freq",
  "Playhead Scrub", "Reverb Wet", "Delay Wet", "Low Pass Freq",
}

-- Window mode identifiers
local MODE_MINI      = "mini"
local MODE_DASHBOARD = "dashboard"
local MODE_SETUP     = "setup"

-- Window dimensions per mode
local DIMS = {
  [MODE_MINI]      = {w=380, h=165},
  [MODE_DASHBOARD] = {w=480, h=285},
  [MODE_SETUP]     = {w=720, h=530},
}

-- GFX font slots
local FONT_BOLD   = 1
local FONT_NORMAL = 2
local FONT_SMALL  = 3

-- ============================================================
-- STATE
-- ============================================================

local S = {
  -- Core
  active_bank       = BANK_FOLLOW,
  window_mode       = MODE_MINI,
  window_open       = false,
  preset_name       = "Default",

  -- MIDI device
  midi_device       = -1,   -- index of MPK Mini input (-1 = not found)
  midi_input        = nil,  -- reaper.CreateMIDIInput object

  -- Knob configuration
  knob_ccs          = {table.unpack(DEFAULT_KNOB_CCS)},
  scrub_sensitivity = 0.5,

  -- Track state
  last_track        = nil,
  last_track_name   = "No track selected",
  last_proj_path    = "",

  -- Runtime knob display
  knob_labels       = {"","","","","","","",""},
  knob_active       = {false,false,false,false,false,false,false,false},

  -- Last raw CC values (0-127) for relative scrub delta
  last_cc_raw       = {},

  -- Plugin library: plugin_name → {guessed, confirmed, status}
  plugin_library    = {},

  -- Plugin profiles: "name|bank_id" → profile table
  plugin_profiles   = {},

  -- Setup panel state
  selected_knob     = nil,   -- 1-8
  selected_pad      = nil,   -- 1-8
  midi_learn_active = false,
  midi_learn_knob   = nil,

  -- UI dropdown state
  dropdown_open     = nil,
  dropdown_scroll   = 0,

  -- Plugin library list scroll offset
  lib_scroll        = 0,

  -- Status bar
  status_msg        = "",
  status_time       = 0,

  -- Mouse state (previous frame) for click detection
  prev_mouse_lb     = 0,
  prev_mouse_wheel  = 0,

  -- Parameter list cache for the currently selected knob in Setup
  param_cache       = {},    -- {idx, name} entries
}

-- ============================================================
-- UTILITY
-- ============================================================

local function clamp(v, lo, hi)
  return math.max(lo, math.min(hi, v))
end

local function status(msg)
  S.status_msg  = msg
  S.status_time = reaper.time_precise()
end

-- Convert MIDI CC value 0-127 to normalized 0.0-1.0
local function cc_norm(v)
  return v / 127.0
end

-- Convert a MIDI note number to a friendly name (e.g. 60 → "C4")
local function note_name(note)
  local names = {"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"}
  local octave = math.floor(note / 12) - 1
  return names[(note % 12) + 1] .. tostring(octave)
end

-- Strip plugin type prefix ("VST: Foo" → "Foo")
local function strip_prefix(fx_name)
  return fx_name:match("^[^:]+:%s*(.+)$") or fx_name
end

-- Case-insensitive substring search
local function icontains(haystack, needle)
  return haystack:lower():find(needle:lower(), 1, true) ~= nil
end

-- ============================================================
-- CONFIG SAVE / LOAD
-- ============================================================

local function config_path()
  local proj_dir = reaper.GetProjectPathEx()
  if not proj_dir or proj_dir == "" then return nil end
  proj_dir = proj_dir:gsub("[/\\]+$", "")
  return proj_dir .. "\\" .. SCRIPT_NAME .. "_config.json"
end

local function save_config()
  local path = config_path()
  if not path then status("Save failed: no project open"); return end

  local data = {
    version          = VERSION,
    preset_name      = S.preset_name,
    active_bank      = S.active_bank,
    window_mode      = S.window_mode,
    knob_ccs         = S.knob_ccs,
    scrub_sensitivity = S.scrub_sensitivity,
    plugin_library   = S.plugin_library,
    plugin_profiles  = S.plugin_profiles,
  }

  local f = io.open(path, "w")
  if f then
    f:write(json.encode(data))
    f:close()
    status("Saved: " .. path)
  else
    status("Save failed: cannot write to " .. path)
  end
end

local function load_config(path)
  path = path or config_path()
  if not path then return end

  local f = io.open(path, "r")
  if not f then return end
  local content = f:read("*a")
  f:close()

  local data = json.decode(content)
  if type(data) ~= "table" then status("Config: invalid JSON"); return end

  if data.preset_name       then S.preset_name       = data.preset_name       end
  if data.active_bank       then S.active_bank        = data.active_bank       end
  if data.window_mode       then S.window_mode        = data.window_mode       end
  if data.scrub_sensitivity then S.scrub_sensitivity  = data.scrub_sensitivity end
  if data.plugin_library    then S.plugin_library     = data.plugin_library    end
  if data.plugin_profiles   then S.plugin_profiles    = data.plugin_profiles   end
  if type(data.knob_ccs) == "table" then
    for i = 1, 8 do
      if data.knob_ccs[i] then S.knob_ccs[i] = data.knob_ccs[i] end
    end
  end
  status("Config loaded")
end

-- ============================================================
-- PLUGIN DETECTION
-- ============================================================

-- Guess plugin category from its display name using the lookup table
local function guess_by_name(plugin_name)
  for cat, names in pairs(PLUGIN_NAME_TABLE) do
    for _, n in ipairs(names) do
      if icontains(plugin_name, n) then return cat end
    end
  end
  return nil
end

-- Guess category by scanning the first N parameter names for keywords
local function guess_by_params(track, fx_idx)
  local n = reaper.TrackFX_GetNumParams(track, fx_idx)
  local scores = {}
  for cat in pairs(PARAM_PRIORITIES) do scores[cat] = 0 end
  scores["Drums"] = 0

  for p = 0, math.min(n - 1, 40) do
    local _, pname = reaper.TrackFX_GetParamName(track, fx_idx, p, "")

    for cat, kws in pairs(PARAM_PRIORITIES) do
      for _, kw in ipairs(kws) do
        if icontains(pname, kw) then scores[cat] = scores[cat] + 1 end
      end
    end

    for _, drum in ipairs(DRUM_PARTS) do
      for _, kw in ipairs(drum.kw) do
        if icontains(pname, kw) then scores["Drums"] = scores["Drums"] + 1 end
      end
    end
  end

  local best, best_score = nil, 1  -- require at least 2 hits
  for cat, score in pairs(scores) do
    if score > best_score then best, best_score = cat, score end
  end
  return best
end

-- Retrieve (or create) a plugin library entry.
-- New entries are given a guessed category and flagged Unconfirmed.
local function lib_entry(plugin_name, track, fx_idx)
  if S.plugin_library[plugin_name] then
    return S.plugin_library[plugin_name]
  end

  local guessed = guess_by_name(plugin_name)
  if not guessed and track and fx_idx then
    guessed = guess_by_params(track, fx_idx)
  end
  guessed = guessed or "Unknown"

  local entry = {guessed=guessed, confirmed=guessed, status="Unconfirmed"}
  S.plugin_library[plugin_name] = entry
  return entry
end

-- Scan the FX chain of `track` for the first plugin matching `category`.
-- Returns fx_index (0-based), clean_name  — or nil, nil.
local function find_fx(track, category)
  if not track then return nil, nil end
  local count = reaper.TrackFX_GetCount(track)
  for i = 0, count - 1 do
    local _, raw = reaper.TrackFX_GetFXName(track, i, "")
    local name = strip_prefix(raw)
    local entry = lib_entry(name, track, i)
    if entry.confirmed == category then
      return i, name
    end
  end
  return nil, nil
end

-- ============================================================
-- PLUGIN PROFILES
-- ============================================================

-- Build the profile key used in S.plugin_profiles
local function prof_key(plugin_name, bank_id)
  return plugin_name .. "|" .. tostring(bank_id)
end

-- Auto-select parameters for 8 knobs using the priority list for `category`.
-- Fills profile.knob_params and profile.knob_labels without overwriting already-
-- assigned slots.  Call only when creating a new profile.
local function autofill_params(profile, track, fx_idx, category)
  if not (track and fx_idx) then return end
  local n = reaper.TrackFX_GetNumParams(track, fx_idx)

  -- Build name→index map
  local pnames = {}
  for p = 0, n - 1 do
    local _, pname = reaper.TrackFX_GetParamName(track, fx_idx, p, "")
    pnames[p] = pname
  end

  local priorities = PARAM_PRIORITIES[category] or {}
  local used = {}

  -- For drum banks, use keyword-per-drum-part matching
  if category == "Drums" then
    for k = 1, 8 do
      local drum = DRUM_PARTS[k]
      if drum then
        for p, pname in pairs(pnames) do
          if not used[p] then
            for _, kw in ipairs(drum.kw) do
              if icontains(pname, kw) then
                profile.knob_params[k] = p
                profile.knob_labels[k] = pname
                used[p] = true
                break
              end
            end
            if profile.knob_params[k] ~= -1 then break end
          end
        end
      end
    end
    return
  end

  -- For all other categories, match priority keywords in order
  for k = 1, 8 do
    local kw = priorities[k]
    if kw then
      for p, pname in pairs(pnames) do
        if not used[p] and icontains(pname, kw) then
          profile.knob_params[k] = p
          profile.knob_labels[k] = pname
          used[p] = true
          break
        end
      end
    end
  end
end

-- Retrieve (or create) a plugin profile for a given plugin + bank combination.
local function get_profile(plugin_name, bank_id, track, fx_idx)
  local key = prof_key(plugin_name, bank_id)
  if S.plugin_profiles[key] then return S.plugin_profiles[key] end

  local profile = {
    knob_params     = {-1,-1,-1,-1,-1,-1,-1,-1},
    knob_labels     = {"","","","","","","",""},
    drum_pad_notes  = {-1,-1,-1,-1,-1,-1,-1,-1},
    drum_pad_labels = {"","","","","","","",""},
    confirmed       = false,
  }

  local cat = BANK_TO_CAT[bank_id]
  if cat then autofill_params(profile, track, fx_idx, cat) end

  S.plugin_profiles[key] = profile
  return profile
end

-- ============================================================
-- BANK 1 — FOLLOW SELECTED TRACK: knob application & reset
-- ============================================================

local function bank1_apply(knob, cc_val, track)
  if not track then return end
  local norm = cc_norm(cc_val)

  if knob == 1 then
    -- Volume: 0→2.0 maps roughly 0 to +6 dB; center (0 dB) at CC 63-64
    reaper.SetMediaTrackInfo_Value(track, "D_VOL", norm * 2.0)

  elseif knob == 2 then
    -- Pan: -1.0 (full L) to +1.0 (full R)
    reaper.SetMediaTrackInfo_Value(track, "D_PAN", norm * 2.0 - 1.0)

  elseif knob == 3 then
    -- Pitch: -12 to +12 semitones
    reaper.SetMediaTrackInfo_Value(track, "D_PITCH", norm * 24.0 - 12.0)

  elseif knob == 4 then
    -- High Pass Frequency — delegates to first EQ plugin on track
    local fx = find_fx(track, "EQ")
    if fx then
      local n = reaper.TrackFX_GetNumParams(track, fx)
      for p = 0, n - 1 do
        local _, pn = reaper.TrackFX_GetParamName(track, fx, p, "")
        if icontains(pn, "high pass") or icontains(pn, "hp freq") or icontains(pn, "highpass") then
          reaper.TrackFX_SetParamNormalized(track, fx, p, norm)
          break
        end
      end
    end

  elseif knob == 5 then
    -- Playhead scrub — relative mode using delta from previous CC value
    local prev = S.last_cc_raw[5] or 64
    local delta = (cc_val - prev) * S.scrub_sensitivity * 0.5
    local pos   = math.max(0, reaper.GetCursorPosition() + delta)
    reaper.SetEditCurPos(pos, true, false)

  elseif knob == 6 then
    -- Reverb wet/mix on first reverb plugin
    local fx = find_fx(track, "Reverb")
    if fx then
      local n = reaper.TrackFX_GetNumParams(track, fx)
      for p = 0, n - 1 do
        local _, pn = reaper.TrackFX_GetParamName(track, fx, p, "")
        if icontains(pn, "wet") or icontains(pn, "mix") then
          reaper.TrackFX_SetParamNormalized(track, fx, p, norm)
          break
        end
      end
    end

  elseif knob == 7 then
    -- Delay wet/mix on first delay plugin
    local fx = find_fx(track, "Delay")
    if fx then
      local n = reaper.TrackFX_GetNumParams(track, fx)
      for p = 0, n - 1 do
        local _, pn = reaper.TrackFX_GetParamName(track, fx, p, "")
        if icontains(pn, "wet") or icontains(pn, "mix") then
          reaper.TrackFX_SetParamNormalized(track, fx, p, norm)
          break
        end
      end
    end

  elseif knob == 8 then
    -- Low Pass Frequency — delegates to first EQ plugin
    local fx = find_fx(track, "EQ")
    if fx then
      local n = reaper.TrackFX_GetNumParams(track, fx)
      for p = 0, n - 1 do
        local _, pn = reaper.TrackFX_GetParamName(track, fx, p, "")
        if icontains(pn, "low pass") or icontains(pn, "lp freq") or icontains(pn, "lowpass") then
          reaper.TrackFX_SetParamNormalized(track, fx, p, norm)
          break
        end
      end
    end
  end
end

local function bank1_reset(knob, track)
  if not track then return end

  if knob == 1 then
    reaper.SetMediaTrackInfo_Value(track, "D_VOL", 1.0)      -- 0 dB
  elseif knob == 2 then
    reaper.SetMediaTrackInfo_Value(track, "D_PAN", 0.0)      -- center
  elseif knob == 3 then
    reaper.SetMediaTrackInfo_Value(track, "D_PITCH", 0.0)    -- 0 semitones
  elseif knob == 4 then
    local fx = find_fx(track, "EQ")
    if fx then
      local n = reaper.TrackFX_GetNumParams(track, fx)
      for p = 0, n - 1 do
        local _, pn = reaper.TrackFX_GetParamName(track, fx, p, "")
        if icontains(pn, "high pass") then
          reaper.TrackFX_SetParamNormalized(track, fx, p, 0.0)  -- min freq
          break
        end
      end
    end
  elseif knob == 5 then
    -- No reset for scrub (spec)
  elseif knob == 6 then
    local fx = find_fx(track, "Reverb")
    if fx then
      local n = reaper.TrackFX_GetNumParams(track, fx)
      for p = 0, n - 1 do
        local _, pn = reaper.TrackFX_GetParamName(track, fx, p, "")
        if icontains(pn, "wet") then
          local _, _, _, def = reaper.TrackFX_GetParam(track, fx, p)
          reaper.TrackFX_SetParamNormalized(track, fx, p, def)
          break
        end
      end
    end
  elseif knob == 7 then
    local fx = find_fx(track, "Delay")
    if fx then
      local n = reaper.TrackFX_GetNumParams(track, fx)
      for p = 0, n - 1 do
        local _, pn = reaper.TrackFX_GetParamName(track, fx, p, "")
        if icontains(pn, "wet") then
          local _, _, _, def = reaper.TrackFX_GetParam(track, fx, p)
          reaper.TrackFX_SetParamNormalized(track, fx, p, def)
          break
        end
      end
    end
  elseif knob == 8 then
    local fx = find_fx(track, "EQ")
    if fx then
      local n = reaper.TrackFX_GetNumParams(track, fx)
      for p = 0, n - 1 do
        local _, pn = reaper.TrackFX_GetParamName(track, fx, p, "")
        if icontains(pn, "low pass") then
          reaper.TrackFX_SetParamNormalized(track, fx, p, 1.0)  -- max freq
          break
        end
      end
    end
  end
end

-- ============================================================
-- BANKS 2-7 — PLUGIN CATEGORY BANKS: knob application & reset
-- ============================================================

local function plugin_bank_apply(knob, cc_val, track, bank_id)
  if not track then return end
  local cat = BANK_TO_CAT[bank_id]
  if not cat then return end
  local fx, pname = find_fx(track, cat)
  if not fx then return end

  local profile = get_profile(pname, bank_id, track, fx)
  local param   = profile.knob_params[knob]
  if param < 0 then return end

  reaper.TrackFX_SetParamNormalized(track, fx, param, cc_norm(cc_val))
end

local function plugin_bank_reset_knob(knob, track, bank_id)
  if not track then return end
  local cat = BANK_TO_CAT[bank_id]
  if not cat then return end
  local fx, pname = find_fx(track, cat)
  if not fx then return end

  local profile = get_profile(pname, bank_id, track, fx)
  local param   = profile.knob_params[knob]
  if param < 0 then return end

  local _, _, _, def = reaper.TrackFX_GetParam(track, fx, param)
  reaper.TrackFX_SetParamNormalized(track, fx, param, def)
end

-- ============================================================
-- BANK 8 — DRUMS: knob application, pad remapping, reset
-- ============================================================

local function drum_bank_apply(knob, cc_val, track)
  if not track then return end
  local fx, pname = find_fx(track, "Drums")
  if not fx then return end

  local profile = get_profile(pname, BANK_DRUMS, track, fx)
  local param   = profile.knob_params[knob]
  if param < 0 then return end

  reaper.TrackFX_SetParamNormalized(track, fx, param, cc_norm(cc_val))
end

local function drum_bank_reset_knob(knob, track)
  if not track then return end
  local fx, pname = find_fx(track, "Drums")
  if not fx then return end

  local profile = get_profile(pname, BANK_DRUMS, track, fx)
  local param   = profile.knob_params[knob]
  if param < 0 then return end

  local _, _, _, def = reaper.TrackFX_GetParam(track, fx, param)
  reaper.TrackFX_SetParamNormalized(track, fx, param, def)
end

-- MPK Mini MK3 Bank A pads default note assignments (bottom/top rows)
local PAD_DEFAULT_NOTES = {36,37,38,39, 40,41,42,43}  -- Pad 1-4, then 5-8

-- Remap a drum pad MIDI note using the current profile.
-- Returns the target note (possibly unchanged if no mapping set).
local function remap_drum_note(note, track)
  if not track then return note end
  local fx, pname = find_fx(track, "Drums")
  if not fx then return note end

  local profile = get_profile(pname, BANK_DRUMS, track, fx)
  for pad_idx, src_note in ipairs(PAD_DEFAULT_NOTES) do
    if note == src_note and profile.drum_pad_notes[pad_idx] >= 0 then
      return profile.drum_pad_notes[pad_idx]
    end
  end
  return note
end

-- ============================================================
-- KNOB LABEL REFRESH
-- Called whenever the selected track or active bank changes.
-- ============================================================

local function refresh_knob_labels(track)
  local labels = S.knob_labels
  local active = S.knob_active

  if state_active_bank == nil then end  -- forward-compat guard

  local bank = S.active_bank

  if bank == BANK_FOLLOW then
    for k = 1, 8 do
      labels[k] = BANK1_LABELS[k]
      active[k] = (track ~= nil)
    end
    -- Scrub is always available (global control)
    active[5] = true

    if track then
      -- K6/K7 only active if matching plugin exists
      active[6] = (find_fx(track, "Reverb") ~= nil)
      active[7] = (find_fx(track, "Delay")  ~= nil)
    end

  elseif bank == BANK_DRUMS then
    for k = 1, 8 do
      labels[k] = DRUM_PARTS[k] and DRUM_PARTS[k].label or ""
      active[k] = false
    end
    if track then
      local fx, pname = find_fx(track, "Drums")
      if fx then
        local profile = get_profile(pname, BANK_DRUMS, track, fx)
        for k = 1, 8 do
          if profile.knob_labels[k] and profile.knob_labels[k] ~= "" then
            labels[k] = profile.knob_labels[k]
          end
          active[k] = (profile.knob_params[k] >= 0)
        end
      end
    end

  else
    -- Banks 2-7: plugin category banks
    local cat = BANK_TO_CAT[bank]
    for k = 1, 8 do labels[k] = "—"; active[k] = false end
    if track and cat then
      local fx, pname = find_fx(track, cat)
      if fx then
        local profile = get_profile(pname, bank, track, fx)
        for k = 1, 8 do
          labels[k] = profile.knob_labels[k] ~= "" and profile.knob_labels[k] or "—"
          active[k] = (profile.knob_params[k] >= 0)
        end
      end
    end
  end
end

-- ============================================================
-- MIDI DEVICE SETUP
-- ============================================================

local function find_mpk_mini()
  local count = reaper.GetNumMIDIInputs()
  for i = 0, count - 1 do
    local _, name = reaper.GetMIDIInputName(i, "")
    if icontains(name, "mpk mini") or icontains(name, "mpkmini") then
      return i, name
    end
  end
  return -1, "MPK Mini not found"
end

local function open_midi_input()
  if S.midi_input then return end  -- already open

  local dev_idx, dev_name = find_mpk_mini()
  S.midi_device = dev_idx

  if dev_idx < 0 then
    status("MPK Mini not found — check REAPER MIDI preferences")
    return
  end

  local mi = reaper.CreateMIDIInput(dev_idx)
  if mi then
    S.midi_input = mi
    status("Connected: " .. dev_name)
  else
    status("Could not open MIDI input for " .. dev_name)
  end
end

-- ============================================================
-- MIDI PROCESSING
-- Handles Program Change (bank switch), CC (knobs), and Note
-- events (drum pad remapping) from the hardware device.
-- ============================================================

local function process_midi_event(msg1, msg2, msg3, track)
  local status_byte = msg1 & 0xF0
  local channel     = msg1 & 0x0F

  -- Program Change → bank switch (intercepted, not passed through)
  if status_byte == 0xC0 then
    local bank = msg2 + 1  -- hardware sends 0-based prog numbers
    if bank >= 1 and bank <= 8 then
      S.active_bank = bank
      refresh_knob_labels(track)
      status("Bank: " .. BANK_NAMES[bank])
    end
    return

  -- Control Change → knob movement
  elseif status_byte == 0xB0 then
    local cc  = msg2
    local val = msg3

    -- MIDI learn: capture this CC for the selected knob
    if S.midi_learn_active and S.midi_learn_knob then
      S.knob_ccs[S.midi_learn_knob] = cc
      S.midi_learn_active = false
      status("Learned CC " .. cc .. " → K" .. S.midi_learn_knob)
      return
    end

    -- Route to the correct bank handler
    for k = 1, 8 do
      if S.knob_ccs[k] == cc then
        if S.active_bank == BANK_FOLLOW then
          bank1_apply(k, val, track)
        elseif S.active_bank == BANK_DRUMS then
          drum_bank_apply(k, val, track)
        else
          plugin_bank_apply(k, val, track, S.active_bank)
        end
        S.last_cc_raw[k] = val
        break
      end
    end
    return

  -- Note On → drum pad remapping when in Bank 8
  elseif status_byte == 0x90 and msg3 > 0 then
    if S.active_bank == BANK_DRUMS then
      local remapped = remap_drum_note(msg2, track)
      reaper.StuffMIDIMessage(0, 0x90 | channel, remapped, msg3)
    else
      reaper.StuffMIDIMessage(0, msg1, msg2, msg3)
    end
    return

  -- Note Off
  elseif status_byte == 0x80 or (status_byte == 0x90 and msg3 == 0) then
    if S.active_bank == BANK_DRUMS then
      local remapped = remap_drum_note(msg2, track)
      reaper.StuffMIDIMessage(0, 0x80 | channel, remapped, 0)
    else
      reaper.StuffMIDIMessage(0, msg1, msg2, msg3)
    end
    return
  end

  -- All other messages pass through unchanged
  reaper.StuffMIDIMessage(0, msg1, msg2, msg3)
end

-- Poll the open MIDI input and dispatch events.
-- REAPER's midi_input:GetReadBuf() returns a packed binary string.
-- Each event record: 4-byte int32 timestamp, then the raw MIDI bytes.
local function poll_midi(track)
  if not S.midi_input then return end

  local buf = S.midi_input:GetReadBuf()
  if not buf or buf == "" then return end

  local i = 1
  while i + 3 <= #buf do
    -- Skip 4-byte timestamp
    local msg1 = buf:byte(i + 4)
    local msg2 = buf:byte(i + 5) or 0
    local msg3 = buf:byte(i + 6) or 0
    if msg1 then
      process_midi_event(msg1, msg2, msg3, track)
    end
    i = i + 7  -- 4 timestamp + 3 MIDI bytes
  end
end

-- ============================================================
-- TRACK FOLLOWING
-- ============================================================

local function update_track()
  local track = reaper.GetSelectedTrack(0, 0)
  if track ~= S.last_track then
    S.last_track = track
    if track then
      local _, name = reaper.GetTrackName(track, "")
      S.last_track_name = name
    else
      S.last_track_name = "No track selected"
    end
    refresh_knob_labels(track)
  end
  return track
end

-- ============================================================
-- PROJECT CHANGE DETECTION
-- Auto-loads the config when the project changes.
-- ============================================================

local function check_project_change()
  local proj_dir = reaper.GetProjectPathEx()
  if proj_dir ~= S.last_proj_path then
    S.last_proj_path = proj_dir
    if proj_dir and proj_dir ~= "" then
      load_config()
      refresh_knob_labels(S.last_track)
    end
  end
end

-- ============================================================
-- UI HELPERS — GFX LIBRARY
-- ============================================================

local function set_col(col, a)
  gfx.set(col[1], col[2], col[3], a or 1.0)
end

local function fill_rect(x, y, w, h, col, a)
  set_col(col, a)
  gfx.rect(x, y, w, h, 1)
end

local function stroke_rect(x, y, w, h, col, a)
  set_col(col, a)
  gfx.rect(x, y, w, h, 0)
end

local function draw_str(x, y, text, col, font)
  gfx.setfont(font or FONT_NORMAL)
  set_col(col or {0.9,0.9,0.9})
  gfx.x, gfx.y = x, y
  gfx.drawstr(text)
end

local function draw_str_center(x, y, w, text, col, font)
  gfx.setfont(font or FONT_NORMAL)
  local tw = gfx.measurestr(text)
  draw_str(x + math.floor((w - tw) / 2), y, text, col, font)
end

-- Colors
local C_BG      = {0.11, 0.11, 0.13}
local C_PANEL   = {0.17, 0.17, 0.20}
local C_BORDER  = {0.30, 0.30, 0.36}
local C_TEXT    = {0.90, 0.90, 0.90}
local C_DIM     = {0.45, 0.45, 0.50}
local C_BTN     = {0.22, 0.22, 0.27}
local C_BTN_H   = {0.32, 0.32, 0.40}
local C_ACCENT  = {0.30, 0.60, 1.00}
local C_RESET   = {0.70, 0.40, 0.10}
local C_OK      = {0.30, 0.85, 0.30}
local C_WARN    = {0.90, 0.75, 0.20}

-- Returns true if mouse is over the rect
local function hover(x, y, w, h)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  return mx >= x and mx < x+w and my >= y and my < y+h
end

-- Button — returns true on click (mouse-down edge)
local function button(x, y, w, h, label, accent_col)
  local hov = hover(x, y, w, h)
  local bg  = hov and C_BTN_H or (accent_col or C_BTN)
  fill_rect(x, y, w, h, bg)
  stroke_rect(x, y, w, h, C_BORDER)
  draw_str_center(x, y + math.floor((h - 12) / 2), w, label, C_TEXT, FONT_SMALL)
  return hov and gfx.mouse_lb == 1 and S.prev_mouse_lb == 0
end

-- ============================================================
-- BUILD PARAMETER CACHE
-- Populates S.param_cache for the currently selected knob's
-- plugin so the Setup dropdown can show all exposed parameters.
-- ============================================================

local function build_param_cache(knob)
  S.param_cache = {}
  local track = S.last_track
  if not track then return end

  local bank = S.active_bank
  local fx

  if bank == BANK_FOLLOW then
    -- Only K6 (reverb wet) and K7 (delay wet) have reassignable params in Bank 1
    if knob == 6 then fx = find_fx(track, "Reverb")
    elseif knob == 7 then fx = find_fx(track, "Delay")
    else return end
  elseif bank == BANK_DRUMS then
    fx = find_fx(track, "Drums")
  else
    fx = find_fx(track, BANK_TO_CAT[bank])
  end

  if not fx then return end

  local n = reaper.TrackFX_GetNumParams(track, fx)
  for p = 0, n - 1 do
    local _, pname = reaper.TrackFX_GetParamName(track, fx, p, "")
    S.param_cache[#S.param_cache + 1] = {idx=p, name=pname}
  end
end

-- ============================================================
-- RESET HELPER — unified reset for any knob in any bank
-- ============================================================

local function reset_knob(knob, track)
  if not track then return end
  local bank = S.active_bank
  if bank == BANK_FOLLOW then
    bank1_reset(knob, track)
  elseif bank == BANK_DRUMS then
    drum_bank_reset_knob(knob, track)
  else
    plugin_bank_reset_knob(knob, track, bank)
  end
end

-- ============================================================
-- ASSIGN PARAMETER (Setup mode dropdown selection)
-- ============================================================

local function assign_param(knob, param_idx, param_name)
  local track = S.last_track
  if not track then return end

  local bank = S.active_bank
  local fx, pname

  if bank == BANK_FOLLOW then
    if knob == 6 then fx, pname = find_fx(track, "Reverb")
    elseif knob == 7 then fx, pname = find_fx(track, "Delay")
    else return end
  elseif bank == BANK_DRUMS then
    fx, pname = find_fx(track, "Drums")
  else
    fx, pname = find_fx(track, BANK_TO_CAT[bank])
  end

  if not (fx and pname) then return end

  local profile = get_profile(pname, bank, track, fx)
  profile.knob_params[knob] = param_idx
  profile.knob_labels[knob] = param_name
  profile.confirmed = true

  S.knob_labels[knob] = param_name
  S.knob_active[knob] = true
  S.dropdown_open = nil
  status("K" .. knob .. " → " .. param_name)
end

-- Get the currently assigned parameter name for a knob (Setup display)
local function current_param_name(knob)
  local track = S.last_track
  if not track then return "(none)" end

  local bank = S.active_bank
  local fx, pname

  if bank == BANK_FOLLOW then
    if knob == 6 then fx, pname = find_fx(track, "Reverb")
    elseif knob == 7 then fx, pname = find_fx(track, "Delay")
    else return "(fixed)" end
  elseif bank == BANK_DRUMS then
    fx, pname = find_fx(track, "Drums")
  else
    fx, pname = find_fx(track, BANK_TO_CAT[bank])
  end

  if not (fx and pname) then return "(no plugin)" end

  local profile = get_profile(pname, bank, track, fx)
  local p = profile.knob_params[knob]
  if p < 0 then return "(none)" end

  local _, label = reaper.TrackFX_GetParamName(track, fx, p, "")
  return label
end

-- ============================================================
-- UI — MODE: MINI
-- ============================================================

local function draw_mini()
  fill_rect(0, 0, gfx.w, gfx.h, C_BG)

  -- Bank color stripe at top
  local bc = BANK_COLORS[S.active_bank]
  fill_rect(0, 0, gfx.w, 3, bc)

  -- Bank name + track name
  gfx.setfont(FONT_BOLD)
  set_col(bc)
  gfx.x, gfx.y = 8, 7
  gfx.drawstr(BANK_NAMES[S.active_bank] or "")

  draw_str(8, 24, S.last_track_name, C_DIM, FONT_SMALL)

  -- Knob labels in 2×4 grid
  local row_y = {46, 96}
  local cw    = math.floor(gfx.w / 4)
  for k = 1, 8 do
    local row = k <= 4 and 1 or 2
    local col = ((k - 1) % 4) + 1
    local x   = (col - 1) * cw + 6
    local y   = row_y[row]
    local txt = "K" .. k .. ": " .. (S.knob_labels[k] or "")
    draw_str(x, y, txt, S.knob_active[k] and C_TEXT or C_DIM, FONT_SMALL)
  end

  -- Navigation
  local bw  = math.floor((gfx.w - 16) / 2)
  local by  = gfx.h - 26
  if button(6,      by, bw, 20, "Dashboard") then
    S.window_mode = MODE_DASHBOARD
    gfx.init(SCRIPT_NAME, DIMS[MODE_DASHBOARD].w, DIMS[MODE_DASHBOARD].h)
  end
  if button(10+bw,  by, bw, 20, "Setup") then
    S.window_mode = MODE_SETUP
    gfx.init(SCRIPT_NAME, DIMS[MODE_SETUP].w, DIMS[MODE_SETUP].h)
  end
end

-- ============================================================
-- UI — MODE: DASHBOARD
-- ============================================================

local function draw_bank_dots(x, y)
  local r   = 7
  local gap = 22
  local track = S.last_track

  for b = 1, 8 do
    local cx  = x + (b - 1) * gap + r
    local col = BANK_COLORS[b]
    local cat = BANK_TO_CAT[b]

    local has = false
    if b == BANK_FOLLOW then
      has = (track ~= nil)
    elseif track and cat then
      has = (find_fx(track, cat) ~= nil)
    end

    if has then
      set_col(col)
      gfx.circle(cx, y, r, 1, 1)
    else
      set_col(col, 0.3)
      gfx.circle(cx, y, r, 0, 1)
    end

    -- Highlight active bank
    if b == S.active_bank then
      set_col(C_TEXT)
      gfx.circle(cx, y, r + 2, 0, 1)
    end
  end
end

local function draw_dashboard()
  fill_rect(0, 0, gfx.w, gfx.h, C_BG)

  local bc = BANK_COLORS[S.active_bank]
  fill_rect(0, 0, gfx.w, 3, bc)

  -- Track and bank info
  draw_str(8, 7,  "Track: " .. S.last_track_name, C_TEXT, FONT_BOLD)
  gfx.setfont(FONT_NORMAL); set_col(bc)
  gfx.x, gfx.y = 8, 24
  gfx.drawstr("Bank: " .. (BANK_NAMES[S.active_bank] or ""))

  -- Bank dots
  draw_bank_dots(8, 52)

  -- Knob grid with hover-reveal reset buttons
  local cw    = math.floor(gfx.w / 4)
  local row_y = {76, 126}
  local mx, my = gfx.mouse_x, gfx.mouse_y

  for k = 1, 8 do
    local row  = k <= 4 and 1 or 2
    local col  = ((k - 1) % 4) + 1
    local x    = (col - 1) * cw + 6
    local y    = row_y[row]
    local no_reset = (S.active_bank == BANK_FOLLOW and k == 5)
    local txt  = "K" .. k .. ": " .. (S.knob_labels[k] or "")
    local tcol = S.knob_active[k] and C_TEXT or C_DIM

    draw_str(x, y, txt, tcol, FONT_SMALL)

    -- Show ↺ reset button on hover, except K5-scrub in Bank 1
    if S.knob_active[k] and not no_reset then
      local hovered = (mx >= x and mx < x + cw - 2 and my >= y - 2 and my < y + 28)
      if hovered then
        if button(x + cw - 24, y, 20, 14, "R", C_RESET) then
          reset_knob(k, S.last_track)
        end
      end
    end
  end

  -- Scrub sensitivity slider
  local sx, sy, sw, sh = 8, 182, 200, 14
  fill_rect(sx, sy, sw, sh, C_PANEL)
  stroke_rect(sx, sy, sw, sh, C_BORDER)
  fill_rect(sx, sy, math.floor(S.scrub_sensitivity * sw), sh, C_ACCENT)
  draw_str(sx + sw + 8, sy + 1, "Scrub Sensitivity", C_DIM, FONT_SMALL)

  if gfx.mouse_lb == 1 and hover(sx - 2, sy - 4, sw + 4, sh + 8) then
    S.scrub_sensitivity = clamp((gfx.mouse_x - sx) / sw, 0.0, 1.0)
  end

  -- Status message (fades after 3 s)
  if S.status_msg ~= "" and (reaper.time_precise() - S.status_time) < 3.0 then
    draw_str(8, 204, S.status_msg, C_DIM, FONT_SMALL)
  end

  -- Navigation
  local bw = math.floor((gfx.w - 16) / 2)
  local by = gfx.h - 26
  if button(6,     by, bw, 20, "Mini")  then
    S.window_mode = MODE_MINI
    gfx.init(SCRIPT_NAME, DIMS[MODE_MINI].w, DIMS[MODE_MINI].h)
  end
  if button(10+bw, by, bw, 20, "Setup") then
    S.window_mode = MODE_SETUP
    gfx.init(SCRIPT_NAME, DIMS[MODE_SETUP].w, DIMS[MODE_SETUP].h)
  end
end

-- ============================================================
-- UI — MODE: SETUP — hardware layout panel
-- ============================================================

local HW_PAD_W  = 52
local HW_PAD_H  = 42
local HW_KNOB_W = 52
local HW_KNOB_H = 50
local HW_GAP    = 6

-- Draw the 2×4 pad grid.  Returns {pad_idx → {cx,cy,r}} for click tests.
local function draw_pads(bx, by)
  local track = S.last_track

  for row = 1, 2 do
    -- Row 1 (top) = Pads 5-8, Row 2 (bottom) = Pads 1-4
    for col = 1, 4 do
      local pad = row == 1 and (col + 4) or col
      local x   = bx + (col - 1) * (HW_PAD_W + HW_GAP)
      local y   = by + (row - 1) * (HW_PAD_H + HW_GAP)

      local sel = (S.selected_pad == pad)
      local col_val = BANK_COLORS[pad]

      fill_rect(x, y, HW_PAD_W, HW_PAD_H, col_val, sel and 1.0 or 0.6)
      stroke_rect(x, y, HW_PAD_W, HW_PAD_H, sel and C_TEXT or C_BORDER)

      -- Label: bank name (abbreviated) or drum pad label
      local label = (BANK_NAMES[pad] or ""):sub(1, 7)
      if S.active_bank == BANK_DRUMS and track then
        local fx, pn = find_fx(track, "Drums")
        if fx then
          local prof = get_profile(pn, BANK_DRUMS, track, fx)
          if prof.drum_pad_labels[pad] ~= "" then
            label = prof.drum_pad_labels[pad]:sub(1, 7)
          else
            label = DRUM_PARTS[pad] and DRUM_PARTS[pad].label:sub(1, 7) or label
          end
        end
      end
      draw_str_center(x, y + math.floor((HW_PAD_H - 11) / 2), HW_PAD_W, label, {0,0,0}, FONT_SMALL)

      -- Click
      if gfx.mouse_lb == 1 and S.prev_mouse_lb == 0 and hover(x, y, HW_PAD_W, HW_PAD_H) then
        S.selected_pad  = pad
        S.selected_knob = nil
        S.dropdown_open = nil
      end
    end
  end
end

-- Draw the 2×4 knob grid.
local function draw_knobs(bx, by)
  for row = 1, 2 do
    for col = 1, 4 do
      local k  = (row - 1) * 4 + col
      local x  = bx + (col - 1) * (HW_KNOB_W + HW_GAP)
      local y  = by + (row - 1) * (HW_KNOB_H + HW_GAP)

      local sel    = (S.selected_knob == k)
      local active = S.knob_active[k]
      local cx_    = x + math.floor(HW_KNOB_W / 2)
      local cy_    = y + math.floor(HW_KNOB_H / 2) - 6
      local r      = math.min(HW_KNOB_W, HW_KNOB_H) / 2 - 5

      -- Knob circle fill
      local fill = active and {0.3,0.3,0.38} or C_BTN
      set_col(fill)
      gfx.circle(cx_, cy_, r, 1, 1)
      set_col(sel and C_TEXT or C_BORDER)
      gfx.circle(cx_, cy_, r, 0, 1)

      -- MIDI learn blink
      if S.midi_learn_active and S.midi_learn_knob == k then
        set_col(C_ACCENT)
        gfx.circle(cx_, cy_, r + 2, 0, 1)
      end

      -- Labels
      draw_str_center(x, y,           HW_KNOB_W, "K"  .. k, C_DIM,  FONT_SMALL)
      draw_str_center(x, cy_ + r + 2, HW_KNOB_W, "CC" .. S.knob_ccs[k], C_DIM, FONT_SMALL)

      -- Click
      local dist = math.sqrt((gfx.mouse_x - cx_)^2 + (gfx.mouse_y - cy_)^2)
      if gfx.mouse_lb == 1 and S.prev_mouse_lb == 0 and dist <= r + 4 then
        S.selected_knob = k
        S.selected_pad  = nil
        S.dropdown_open = nil
        build_param_cache(k)
      end
    end
  end
end

-- ============================================================
-- UI — MODE: SETUP — parameter assignment panel
-- ============================================================

local function draw_param_panel(x, y, w, h)
  local k = S.selected_knob
  if not k then return end

  fill_rect(x, y, w, h, C_PANEL)
  stroke_rect(x, y, w, h, C_BORDER)

  draw_str(x+6, y+6,  "K" .. k .. " — Parameter Assignment", C_TEXT, FONT_BOLD)

  -- CC and MIDI Learn
  draw_str(x+6, y+26, "CC: " .. S.knob_ccs[k], C_TEXT, FONT_SMALL)
  local learn_label = (S.midi_learn_active and S.midi_learn_knob == k) and "Listening…" or "MIDI Learn"
  local learn_col   = (S.midi_learn_active and S.midi_learn_knob == k) and C_ACCENT or nil
  if button(x+52, y+22, 82, 16, learn_label, learn_col) then
    if S.midi_learn_active and S.midi_learn_knob == k then
      S.midi_learn_active = false
    else
      S.midi_learn_active = true
      S.midi_learn_knob   = k
    end
  end

  -- Current parameter label + dropdown trigger
  draw_str(x+6, y+44, "Param:", C_DIM, FONT_SMALL)
  local cur = current_param_name(k)
  local dd_x, dd_y, dd_w, dd_h = x+6, y+58, w-12, 18
  if button(dd_x, dd_y, dd_w, dd_h, cur .. " ▼") then
    if S.dropdown_open == k then
      S.dropdown_open = nil
    else
      S.dropdown_open   = k
      S.dropdown_scroll = 0
      build_param_cache(k)
    end
  end

  -- Dropdown list (drawn on top of everything else)
  if S.dropdown_open == k then
    local max_rows  = 10
    local row_h     = 16
    local list_h    = math.min(max_rows, #S.param_cache) * row_h
    fill_rect(dd_x, dd_y + dd_h, dd_w, list_h, C_PANEL)
    stroke_rect(dd_x, dd_y + dd_h, dd_w, list_h, C_BORDER)

    -- Mouse-wheel scroll
    local wheel = gfx.mouse_wheel - S.prev_mouse_wheel
    if wheel ~= 0 and hover(dd_x, dd_y+dd_h, dd_w, list_h) then
      S.dropdown_scroll = clamp(S.dropdown_scroll - math.floor(wheel / 120),
                                0, math.max(0, #S.param_cache - max_rows))
    end

    for i = 1, math.min(max_rows, #S.param_cache) do
      local idx  = i + S.dropdown_scroll
      local item = S.param_cache[idx]
      if not item then break end
      local py   = dd_y + dd_h + (i - 1) * row_h
      local hov  = hover(dd_x, py, dd_w, row_h)
      if hov then fill_rect(dd_x, py, dd_w, row_h, C_BTN_H) end
      draw_str(dd_x + 4, py + 2, item.name, C_TEXT, FONT_SMALL)

      if hov and gfx.mouse_lb == 1 and S.prev_mouse_lb == 0 then
        assign_param(k, item.idx, item.name)
      end
    end
  end

  -- Reset button (not for K5 scrub in Bank 1)
  local no_reset = (S.active_bank == BANK_FOLLOW and k == 5)
  if not no_reset then
    if button(x+6, y+84, 100, 18, "Reset to Default", C_RESET) then
      reset_knob(k, S.last_track)
    end
  end
end

-- ============================================================
-- UI — MODE: SETUP — pad mapping panel
-- ============================================================

local function draw_pad_panel(x, y, w, h)
  local pad = S.selected_pad
  if not pad then return end

  fill_rect(x, y, w, h, C_PANEL)
  stroke_rect(x, y, w, h, C_BORDER)

  draw_str(x+6, y+6, "Pad " .. pad .. " — Mapping", C_TEXT, FONT_BOLD)

  local track = S.last_track
  if not track then
    draw_str(x+6, y+28, "No track selected", C_DIM, FONT_SMALL); return
  end

  local fx, pname = find_fx(track, "Drums")
  if not fx then
    draw_str(x+6, y+28, "No drum plugin found on track", C_DIM, FONT_SMALL); return
  end

  local profile = get_profile(pname, BANK_DRUMS, track, fx)

  -- Pad label (display only — editing would require text input widget)
  local lbl = profile.drum_pad_labels[pad]
  lbl = (lbl ~= "") and lbl or (DRUM_PARTS[pad] and DRUM_PARTS[pad].label or "Pad " .. pad)
  draw_str(x+6, y+28, "Label: " .. lbl, C_TEXT, FONT_SMALL)

  -- Target MIDI note
  local note = profile.drum_pad_notes[pad]
  local note_str = note >= 0 and (note_name(note) .. "  (" .. note .. ")") or "Unassigned"
  draw_str(x+6, y+46, "Target note: " .. note_str, C_TEXT, FONT_SMALL)

  -- Note assignment buttons (simplified keyboard row: C3-B3)
  draw_str(x+6, y+64, "Assign note:", C_DIM, FONT_SMALL)
  local notes_row = {36,37,38,39,40,41,42,43,44,45,46,47}
  local btn_w = math.floor((w - 12) / #notes_row)
  for i, n in ipairs(notes_row) do
    local bx = x + 6 + (i-1)*btn_w
    local is_cur = (note == n)
    if button(bx, y+78, btn_w - 1, 16, note_name(n), is_cur and C_ACCENT or nil) then
      profile.drum_pad_notes[pad] = n
      status("Pad " .. pad .. " → " .. note_name(n))
    end
  end

  -- Friendly label quick-set buttons for common drum parts
  draw_str(x+6, y+100, "Label:", C_DIM, FONT_SMALL)
  local part_labels = {}
  for _, dp in ipairs(DRUM_PARTS) do part_labels[#part_labels+1] = dp.label end
  local pl_w = math.floor((w - 12) / 4)
  for i, pl in ipairs(part_labels) do
    local col_ = ((i-1) % 4)
    local row_ = math.floor((i-1) / 4)
    local bx   = x + 6 + col_ * pl_w
    local bby  = y + 114 + row_ * 20
    if button(bx, bby, pl_w - 2, 16, pl:sub(1,10)) then
      profile.drum_pad_labels[pad] = pl
      status("Pad " .. pad .. " label → " .. pl)
    end
  end
end

-- ============================================================
-- UI — MODE: SETUP — plugin library panel
-- ============================================================

local function draw_library(x, y, w, h)
  fill_rect(x, y, w, h, C_PANEL)
  stroke_rect(x, y, w, h, C_BORDER)
  draw_str(x+6, y+5, "Plugin Library", C_TEXT, FONT_BOLD)

  -- Column X positions
  local cx = {x+4, x+math.floor(w*0.38), x+math.floor(w*0.60), x+math.floor(w*0.82)}
  local hdr_y = y + 20
  draw_str(cx[1], hdr_y, "Plugin Name",      C_DIM, FONT_SMALL)
  draw_str(cx[2], hdr_y, "Guessed",          C_DIM, FONT_SMALL)
  draw_str(cx[3], hdr_y, "Confirmed",        C_DIM, FONT_SMALL)
  draw_str(cx[4], hdr_y, "Status",           C_DIM, FONT_SMALL)

  -- Collect and sort plugins
  local plugins = {}
  for name, entry in pairs(S.plugin_library) do
    plugins[#plugins+1] = {name=name, e=entry}
  end
  table.sort(plugins, function(a,b) return a.name < b.name end)

  local row_h    = 16
  local list_y   = y + 34
  local vis_rows = math.floor((h - 40) / row_h)

  -- Scroll
  local wheel = gfx.mouse_wheel - S.prev_mouse_wheel
  if wheel ~= 0 and hover(x, y, w, h) then
    S.lib_scroll = clamp(S.lib_scroll - math.floor(wheel / 120),
                         0, math.max(0, #plugins - vis_rows))
  end

  for i = 1, math.min(vis_rows, #plugins - S.lib_scroll) do
    local p   = plugins[i + S.lib_scroll]
    local ry  = list_y + (i-1) * row_h
    local hov = hover(x, ry, w, row_h)
    if hov then fill_rect(x, ry, w, row_h, C_BTN_H) end

    draw_str(cx[1], ry+2, p.name:sub(1,26),           C_TEXT, FONT_SMALL)
    draw_str(cx[2], ry+2, p.e.guessed   or "",        C_DIM,  FONT_SMALL)
    draw_str(cx[3], ry+2, p.e.confirmed or "",        C_TEXT, FONT_SMALL)

    local sc = p.e.status == "Confirmed" and C_OK or C_WARN
    draw_str(cx[4], ry+2, p.e.status or "", sc, FONT_SMALL)

    -- Click a row to cycle its confirmed category
    if hov and gfx.mouse_lb == 1 and S.prev_mouse_lb == 0 then
      -- Cycle through categories + Unknown
      local cats = {"Reverb","Delay","Pan","EQ","Distortion","Modulation","Drums","Unknown"}
      local cur_idx = 1
      for ci, c in ipairs(cats) do
        if c == p.e.confirmed then cur_idx = ci; break end
      end
      p.e.confirmed = cats[(cur_idx % #cats) + 1]
      p.e.status    = "Confirmed"
      status("Confirmed: " .. p.name .. " → " .. p.e.confirmed)
      refresh_knob_labels(S.last_track)
    end
  end
end

-- ============================================================
-- UI — MODE: SETUP — preset panel
-- ============================================================

local function draw_presets(x, y, w, h)
  fill_rect(x, y, w, h, C_PANEL)
  stroke_rect(x, y, w, h, C_BORDER)
  draw_str(x+6, y+5, "Presets", C_TEXT, FONT_BOLD)
  draw_str(x+6, y+22, S.preset_name, C_DIM, FONT_SMALL)

  if button(x+6, y+40, math.floor(w/2)-8, 18, "Save") then
    save_config()
  end
  if button(x+math.floor(w/2)+2, y+40, math.floor(w/2)-8, 18, "Load…") then
    local ok, path = reaper.GetUserFileNameForRead("", "Load Config", "json")
    if ok then load_config(path) end
  end
end

-- ============================================================
-- UI — MODE: SETUP — main layout
-- ============================================================

local function draw_setup()
  fill_rect(0, 0, gfx.w, gfx.h, C_BG)

  local bc = BANK_COLORS[S.active_bank]
  fill_rect(0, 0, gfx.w, 3, bc)

  draw_str(8,  7, SCRIPT_NAME .. " — Setup", C_TEXT, FONT_BOLD)
  draw_str(8, 24, "Track: " .. S.last_track_name .. "   Bank: " .. (BANK_NAMES[S.active_bank] or ""), C_DIM, FONT_SMALL)

  -- Hardware layout
  local hw_x  = 8
  local hw_y  = 44
  local pads_w = 4 * (HW_PAD_W + HW_GAP) - HW_GAP
  draw_pads(hw_x, hw_y)
  draw_knobs(hw_x + pads_w + 24, hw_y)

  -- Parameter / Pad panel (right side of hardware layout)
  local panel_x = hw_x + pads_w + 24 + 4 * (HW_KNOB_W + HW_GAP) - HW_GAP + 14
  local panel_w = gfx.w - panel_x - 6
  local panel_h = 140

  if S.selected_knob then
    draw_param_panel(panel_x, hw_y, panel_w, panel_h)
  elseif S.selected_pad then
    draw_pad_panel(panel_x, hw_y, panel_w, panel_h)
  else
    fill_rect(panel_x, hw_y, panel_w, panel_h, C_PANEL)
    stroke_rect(panel_x, hw_y, panel_w, panel_h, C_BORDER)
    draw_str_center(panel_x, hw_y + math.floor(panel_h/2) - 6, panel_w,
      "Select a knob or pad", C_DIM, FONT_NORMAL)
  end

  -- Plugin Library + Preset panels (bottom section)
  local lib_y = hw_y + 2 * (HW_PAD_H + HW_GAP) + 14
  local lib_h = gfx.h - lib_y - 34
  local pre_w = 160

  draw_library(8, lib_y, gfx.w - pre_w - 14, lib_h)
  draw_presets(gfx.w - pre_w - 6, lib_y, pre_w, lib_h)

  -- Status bar
  if S.status_msg ~= "" and (reaper.time_precise() - S.status_time) < 4.0 then
    draw_str(8, gfx.h - 30, S.status_msg, C_DIM, FONT_SMALL)
  end

  -- Navigation
  local bw = math.floor((gfx.w - 16) / 2)
  local by = gfx.h - 26
  if button(6,     by, bw, 20, "Mini") then
    S.window_mode = MODE_MINI
    gfx.init(SCRIPT_NAME, DIMS[MODE_MINI].w, DIMS[MODE_MINI].h)
  end
  if button(10+bw, by, bw, 20, "Dashboard") then
    S.window_mode = MODE_DASHBOARD
    gfx.init(SCRIPT_NAME, DIMS[MODE_DASHBOARD].w, DIMS[MODE_DASHBOARD].h)
  end
end

-- ============================================================
-- UI — MASTER DRAW
-- ============================================================

local function draw_ui()
  gfx.setfont(FONT_BOLD,   "Arial", 13, string.byte("b"))
  gfx.setfont(FONT_NORMAL, "Arial", 12, 0)
  gfx.setfont(FONT_SMALL,  "Arial", 11, 0)

  if S.window_mode == MODE_MINI then
    draw_mini()
  elseif S.window_mode == MODE_DASHBOARD then
    draw_dashboard()
  else
    draw_setup()
  end

  -- Capture mouse/wheel state for next frame's click-edge detection
  S.prev_mouse_lb    = gfx.mouse_lb
  S.prev_mouse_wheel = gfx.mouse_wheel

  gfx.update()
end

-- ============================================================
-- MAIN DEFERRED LOOP
-- ============================================================

local function main_loop()
  -- Read window events; -1 means window closed
  local ch = gfx.getchar()
  if ch == -1 then
    -- Window was closed by the user — keep running in background
    S.window_open = false
  elseif ch == 27 then
    -- ESC pressed — close the window (script continues)
    gfx.quit()
    S.window_open = false
  end

  -- Re-open the window if it was re-triggered (toolbar button pressed again)
  -- Detected by gfx.w == 0 when we think we're open
  if S.window_open and gfx.w == 0 then
    S.window_open = false
  end

  -- Detect project change → auto-load config
  check_project_change()

  -- Track following
  local track = update_track()

  -- Poll hardware MIDI
  poll_midi(track)

  -- Render UI
  if S.window_open then
    draw_ui()
  end

  -- Schedule the next iteration
  reaper.defer(main_loop)
end

-- ============================================================
-- ENTRY POINT
-- ============================================================

local function init()
  -- Attempt to open the MPK Mini MIDI input
  open_midi_input()

  -- Load saved config for this project (if any)
  local proj_dir = reaper.GetProjectPathEx()
  if proj_dir and proj_dir ~= "" then
    S.last_proj_path = proj_dir
    load_config()
  end

  -- Open the floating window in the saved mode
  local d = DIMS[S.window_mode] or DIMS[MODE_MINI]
  gfx.init(SCRIPT_NAME, d.w, d.h, 0, 120, 120)
  S.window_open = true

  -- Seed the mouse-wheel baseline so first frame doesn't spuriously scroll
  S.prev_mouse_wheel = gfx.mouse_wheel

  -- Initial knob label population
  local track = reaper.GetSelectedTrack(0, 0)
  S.last_track = track
  if track then
    local _, name = reaper.GetTrackName(track, "")
    S.last_track_name = name
  end
  refresh_knob_labels(track)

  -- Hand off to the deferred loop — this is now running permanently
  reaper.defer(main_loop)
end

init()
