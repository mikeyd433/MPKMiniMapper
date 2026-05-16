-- ============================================================
-- MPKMiniMapper v1.1
-- REAPER Lua Script for Akai MPK Mini MK3
--
-- Runs as a deferred background script. Launch via a REAPER
-- toolbar button. The floating window is optional — open it
-- only when needed. Processes MIDI in the background always.
--
-- Hardware assumed:
--   Bank A pads → Program Change 1-8, channel 1
--   Knobs       → CC 70-77 (verify in Setup → MIDI Learn)
--   Bank B      → fully open/custom
--
-- Requires REAPER 6.0+ with Lua scripting enabled.
-- ============================================================

-- ============================================================
-- MINIMAL JSON ENCODER / DECODER
-- No external dependencies.
-- ============================================================

local json = {}

function json.encode(val)
  local t = type(val)
  if t == "nil" then return "null"
  elseif t == "boolean" then return tostring(val)
  elseif t == "number"  then return tostring(val)
  elseif t == "string"  then
    return '"' .. val:gsub('\\','\\\\'):gsub('"','\\"')
                     :gsub('\n','\\n'):gsub('\r','\\r')
                     :gsub('\t','\\t') .. '"'
  elseif t == "table" then
    local n, max_idx = 0, 0
    for k in pairs(val) do
      n = n + 1
      if type(k)=="number" and k==math.floor(k) and k>=1 then
        if k>max_idx then max_idx=k end
      else max_idx=-1 end
    end
    local is_arr = (max_idx==n and n>0) or n==0
    if is_arr then
      local p={}; for i,v in ipairs(val) do p[i]=json.encode(v) end
      return "[" .. table.concat(p,",") .. "]"
    else
      local p={}
      for k,v in pairs(val) do
        if type(k)=="string" or type(k)=="number" then
          p[#p+1]=json.encode(tostring(k))..":"..json.encode(v)
        end
      end
      return "{" .. table.concat(p,",") .. "}"
    end
  end
  return "null"
end

function json.decode(str)
  if not str or str=="" then return nil end
  local pos=1
  local function skip() while pos<=#str and str:sub(pos,pos):match"%s" do pos=pos+1 end end
  local parse_value
  local function parse_str()
    pos=pos+1; local s=""
    while pos<=#str do
      local c=str:sub(pos,pos)
      if c=='"' then pos=pos+1; return s end
      if c=='\\' then
        pos=pos+1; local e=str:sub(pos,pos)
        local esc={['"']='"',['\\']='\\',['/']=''/'',n='\n',r='\r',t='\t',b='\b',f='\f'}
        s=s..(esc[e] or e)
      else s=s..c end
      pos=pos+1
    end
    return s
  end
  local function parse_obj()
    pos=pos+1; local o={}; skip()
    if str:sub(pos,pos)=='}' then pos=pos+1; return o end
    while true do
      skip(); local k=parse_str(); skip(); pos=pos+1
      o[k]=parse_value(); skip()
      local d=str:sub(pos,pos); pos=pos+1
      if d=='}' then break end
    end
    return o
  end
  local function parse_arr()
    pos=pos+1; local a={}; skip()
    if str:sub(pos,pos)==']' then pos=pos+1; return a end
    while true do
      a[#a+1]=parse_value(); skip()
      local d=str:sub(pos,pos); pos=pos+1
      if d==']' then break end
    end
    return a
  end
  parse_value=function()
    skip(); local c=str:sub(pos,pos)
    if c=='"' then return parse_str()
    elseif c=='{' then return parse_obj()
    elseif c=='[' then return parse_arr()
    elseif c=='t' then pos=pos+4; return true
    elseif c=='f' then pos=pos+5; return false
    elseif c=='n' then pos=pos+4; return nil
    else
      local ns=str:match("^%-?%d+%.?%d*[eE]?[+%-]?%d*",pos)
      if ns then pos=pos+#ns; return tonumber(ns) end
    end
  end
  local ok,r=pcall(parse_value); return ok and r or nil
end

-- ============================================================
-- CONSTANTS
-- ============================================================

local SCRIPT_NAME = "MPKMiniMapper"
local VERSION     = "1.1"

local BANK_FOLLOW = 1; local BANK_REVERB = 2; local BANK_DELAY = 3
local BANK_PAN    = 4; local BANK_EQ     = 5; local BANK_DIST  = 6
local BANK_MOD    = 7; local BANK_DRUMS  = 8

local BANK_NAMES = {
  [BANK_FOLLOW]="Follow Selected Track", [BANK_REVERB]="Reverb",
  [BANK_DELAY]="Delay",  [BANK_PAN]="Pan",    [BANK_EQ]="EQ",
  [BANK_DIST]="Distortion", [BANK_MOD]="Modulation", [BANK_DRUMS]="Drums",
}

local BANK_COLORS = {
  [BANK_FOLLOW]={0.20,0.50,1.00}, [BANK_REVERB]={0.70,0.30,0.90},
  [BANK_DELAY]={0.20,0.80,0.80},  [BANK_PAN]={1.00,0.60,0.10},
  [BANK_EQ]={0.30,0.90,0.30},     [BANK_DIST]={0.90,0.20,0.20},
  [BANK_MOD]={1.00,0.90,0.10},    [BANK_DRUMS]={0.90,0.90,0.90},
}

-- MPK Mini MK3 device SysEx enum labels (used in device config editor)
local ARP_MODES  = {"Up","Down","Incl","Excl","Random","Order"}
local ARP_DIVS   = {"1/4","1/4T","1/8","1/8T","1/16","1/16T","1/32","1/32T"}
local ARP_SWINGS = {"0%","25%","33%","50%","66%","75%"}
local JOY_MODES  = {"Pitch","CC","Split"}

local BANK_TO_CAT = {
  [BANK_REVERB]="Reverb", [BANK_DELAY]="Delay",  [BANK_PAN]="Pan",
  [BANK_EQ]="EQ",         [BANK_DIST]="Distortion", [BANK_MOD]="Modulation",
  [BANK_DRUMS]="Drums",
}

local DEFAULT_KNOB_CCS = {70,71,72,73,74,75,76,77}

-- ============================================================
-- JSFX BRIDGE SOURCE (embedded — written to disk on first run)
-- This small JSFX runs in the input FX chain of a dedicated MIDI
-- track and pipes every hardware MIDI event into a gmem ring buffer
-- that the Lua defer loop reads each frame.  Program Change messages
-- (bank switches) and drum notes are intercepted here so they never
-- reach REAPER's normal routing.
-- gmem layout (base 10000, chosen to avoid conflicts):
--   [0] write pointer  [1] read pointer  [2] drum-intercept flag
--   [100..699] ring buffer (200 events × 3 bytes each)
-- ============================================================

local JSFX_SRC = [[
desc:MPKMiniMapper_MIDI
// Auto-generated by MPKMiniMapper.lua — do not edit manually.
// gmem layout (base 10000):
//   [0]       ring write ptr   [1] ring read ptr   [2] drum-intercept flag
//   [100..699] ring buffer (200 events x 3 bytes each)
//   [700]     sysex TX length (0=idle); [701..820] TX bytes (120 max)
//   [900]     sysex RX length (0=idle); [901..1020] RX bytes (120 max)

@init
BASE = 10000;
gmem[BASE+0] = BASE+100;
gmem[BASE+1] = BASE+100;
tbuf = 2000;  // local JSFX memory for temp sysex buffer

@block
// Receive all MIDI and SysEx via midirecv_buf (handles variable-length msgs)
len = midirecv_buf(offset, tbuf, 120);
while(len)(
  tbuf[0] == 0xF0 ? (
    // SysEx from device — store in RX gmem slot if free
    gmem[BASE+900] == 0 ? (
      i = 0;
      while(i < len)(
        gmem[BASE+901+i] = tbuf[i];
        i += 1;
      );
      gmem[BASE+900] = len;
    );
    // do not pass SysEx downstream (it is device config, not performance)
  ) : len >= 3 ? (
    msg1 = tbuf[0]; msg2 = tbuf[1]; msg3 = tbuf[2];
    wp = gmem[BASE+0];
    gmem[wp]=msg1; gmem[wp+1]=msg2; gmem[wp+2]=msg3;
    wp+=3; wp>=BASE+700 ? wp=BASE+100;
    gmem[BASE+0]=wp;
    (msg1&240)==192 ? 0 :
    ((msg1&240)==144||(msg1&240)==128)&&gmem[BASE+2] ? 0 :
    midisend(offset,msg1,msg2,msg3);
  );
  len = midirecv_buf(offset, tbuf, 120);
);

// Send pending SysEx written by Lua into TX gmem slot
gmem[BASE+700] > 0 ? (
  slen = gmem[BASE+700];
  i = 0;
  while(i < slen)(
    tbuf[i] = gmem[BASE+701+i];
    i += 1;
  );
  midisend_buf(0, tbuf, slen);
  gmem[BASE+700] = 0;
);
]]

-- Matching gmem constants used on the Lua side
local GMEM_BASE = 10000
local GMEM_BUF  = GMEM_BASE + 100
local GMEM_BSIZ = 600  -- 200 events × 3 bytes

-- SysEx TX slot: [GMEM_BASE+700] = length, [+701..+820] = bytes (120 max)
-- SysEx RX slot: [GMEM_BASE+900] = length, [+901..+1020] = bytes (120 max)
local GMEM_SYSEX_TX     = GMEM_BASE + 700
local GMEM_SYSEX_TX_BUF = GMEM_BASE + 701
local GMEM_SYSEX_RX     = GMEM_BASE + 900
local GMEM_SYSEX_RX_BUF = GMEM_BASE + 901
local SYSEX_MAX_LEN     = 120

local MIDI_TRACK_NAME = "MPKMiniMapper Input"

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

-- Each slot is a list of synonym keywords tried in order for that knob position.
-- This matches the spec's intent: one slot per knob, multiple alternatives per slot.
local PARAM_PRIORITIES = {
  Reverb={
    {"Wet","Mix"},
    {"Room Size","Room"},
    {"Decay","RT60","Reverb Time","Tail"},
    {"Pre-delay","Predelay","Pre Delay"},
    {"Damping","Damp"},
    {"Diffusion"},
    {"Low Cut","Low Freq","HP Freq","Highpass"},
    {"High Cut","High Freq","LP Freq","Lowpass"},
  },
  Delay={
    {"Wet","Mix"},
    {"Time","BPM"},
    {"Feedback","Regen"},
    {"High Cut","Tone","Treble"},
    {"Low Cut","Bass"},
    {"Mod Rate","Modulation Rate","LFO Rate"},
    {"Mod Depth","Modulation Depth","LFO Depth"},
    {"Dry","Output"},
  },
  Pan={
    {"Width","Stereo Width"},
    {"Pan"},
    {"Stereo Balance","Balance"},
    {"Left Gain","L Gain"},
    {"Right Gain","R Gain"},
    {"Rotation"},
    {"Divergence"},
    {"Mix","Output"},
  },
  EQ={
    {"Low Shelf Gain","Low Gain","Bass Gain"},
    {"High Shelf Gain","High Gain","Treble Gain"},
    {"Low Pass","LP Freq","Lowpass"},
    {"High Pass","HP Freq","Highpass"},
    {"Mid Freq","Peak Freq","Bell Freq"},
    {"Mid Gain","Peak Gain","Bell Gain"},
    {"Mid Q","Peak Q","Q"},
    {"Output","Out Gain","Master Gain"},
  },
  Distortion={
    {"Drive","Amount","Gain"},
    {"Tone"},
    {"Output","Out Level","Volume"},
    {"Wet","Mix"},
    {"Bass"},
    {"Treble","Presence"},
    {"Gate","Noise Gate"},
    {"Bias"},
  },
  Modulation={
    {"Rate","Speed","Frequency"},
    {"Depth","Amount","Intensity"},
    {"Wet","Mix"},
    {"Feedback","Regen"},
    {"Width","Stereo Width","Spread"},
    {"Phase","Phase Offset"},
    {"Waveform","LFO Shape","Wave"},
    {"Dry","Output"},
  },
}

-- Drum part definitions: one per knob in Bank 8 / shared with Bank 1
local DRUM_PARTS = {
  {label="Kick",         kw={"Kick","BD","Bass Drum"}},
  {label="Snare",        kw={"Snare","SD"}},
  {label="Hi-Hat",       kw={"Hi-Hat","HH","Closed Hat","CHH"}},
  {label="Open Hi-Hat",  kw={"Open Hat","OH","OHH"}},
  {label="Crash",        kw={"Crash","CY"}},
  {label="Ride",         kw={"Ride"}},
  {label="Tom",          kw={"Tom","TM"}},
  {label="Overhead/Room",kw={"Overhead","Room","OHD","OH "}},
}

-- Bank 1 fixed knob labels
local BANK1_LABELS = {
  "Track Volume","Track Pan","Track Pitch","High Pass Freq",
  "Playhead Scrub","Reverb Wet","Delay Wet","Low Pass Freq",
}

-- Default MIDI note assignments for MPK Mini MK3 Bank A pads
-- Bottom row = Pads 1-4, Top row = Pads 5-8
local PAD_DEFAULT_NOTES = {36,37,38,39, 40,41,42,43}

local MODE_MINI      = "mini"
local MODE_DASHBOARD = "dashboard"
local MODE_SETUP     = "setup"
local DIMS = {
  [MODE_MINI]     ={w=380,h=168},
  [MODE_DASHBOARD]={w=480,h=290},
  [MODE_SETUP]    ={w=740,h=640},
}

local FONT_BOLD=1; local FONT_NORMAL=2; local FONT_SMALL=3

-- ============================================================
-- STATE
-- ============================================================

local S = {
  active_bank       = BANK_FOLLOW,
  window_mode       = MODE_MINI,
  window_open       = false,
  preset_name       = "Default",

  midi_track        = nil,   -- MediaTrack* used as MIDI bridge
  jsfx_ready        = false, -- true once JSFX helper is loaded and gmem is live

  knob_ccs          = {table.unpack(DEFAULT_KNOB_CCS)},
  scrub_sensitivity = 0.5,

  last_track        = nil,
  last_track_name   = "No track selected",
  last_proj_path    = "",

  knob_labels       = {"","","","","","","",""},
  knob_active       = {false,false,false,false,false,false,false,false},

  last_cc_raw       = {64,64,64,64,64,64,64,64},  -- default to center for scrub
  knob_touched_time = {0,0,0,0,0,0,0,0},          -- time_precise() of last CC per knob

  -- SysEx / device preset
  device_preset_bytes  = nil,   -- raw bytes of last preset read from device (table or nil)
  device_preset_slot   = 1,     -- which slot (1-4) to read/write
  sysex_read_pending   = false, -- waiting for a preset dump response
  device_config_open   = false, -- true = show device config editor instead of plugin library
  device_config_fields = nil,   -- parsed preset fields table (editable in device config editor)

  plugin_library    = {},
  plugin_profiles   = {},

  selected_knob     = nil,
  selected_pad      = nil,
  pad_picker_octave = 3,  -- default octave for keyboard picker (C3=36)
  midi_learn_active = false,
  midi_learn_knob   = nil,

  dropdown_open     = nil,
  dropdown_scroll   = 0,
  lib_scroll        = 0,

  pending_drum_prompt = nil,  -- plugin name needing first-time pad mapping

  status_msg        = "",
  status_time       = 0,

  prev_mouse_lb     = 0,
  prev_mouse_wheel  = 0,

  param_cache       = {},
}

-- ============================================================
-- TEXT INPUT WIDGET
-- Simple single-line text input using gfx.getchar().
-- ============================================================

local TI = { active=false, id=nil, value="", on_done=nil }

local function ti_begin(id, initial, on_done)
  TI.active  = true
  TI.id      = id
  TI.value   = initial or ""
  TI.on_done = on_done
end

local function ti_handle(ch)
  if not TI.active then return false end
  if ch == 13 then  -- Enter: commit
    if TI.on_done then TI.on_done(TI.value) end
    TI.active = false; return true
  elseif ch == 27 then  -- Escape: cancel
    TI.active = false; return true
  elseif ch == 8 then  -- Backspace
    TI.value = TI.value:sub(1,-2); return true
  elseif ch >= 32 and ch <= 126 then
    TI.value = TI.value .. string.char(ch); return true
  end
  return false
end

-- ============================================================
-- UTILITY
-- ============================================================

local function clamp(v,lo,hi) return math.max(lo,math.min(hi,v)) end
local function cc_norm(v) return v/127.0 end
local function note_name(n)
  local names={"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"}
  return names[(n%12)+1]..tostring(math.floor(n/12)-1)
end
local function strip_prefix(s) return s:match("^[^:]+:%s*(.+)$") or s end
local function icontains(h,n) return h:lower():find(n:lower(),1,true)~=nil end

local function status(msg) S.status_msg=msg; S.status_time=reaper.time_precise() end

-- ============================================================
-- MIDI MESSAGE LENGTH TABLE
-- Maps MIDI status byte → total message size (status + data bytes).
-- ============================================================


-- ============================================================
-- CONFIG SAVE / LOAD
-- ============================================================

local function config_path()
  local d = reaper.GetProjectPathEx()
  if not d or d=="" then return nil end
  return d:gsub("[/\\]+$","") .. "\\" .. SCRIPT_NAME .. "_config.json"
end

local function save_config()
  local path = config_path()
  if not path then status("Save failed: no project open"); return end
  local data = {
    version=VERSION, preset_name=S.preset_name,
    active_bank=S.active_bank, window_mode=S.window_mode,
    knob_ccs=S.knob_ccs, scrub_sensitivity=S.scrub_sensitivity,
    plugin_library=S.plugin_library, plugin_profiles=S.plugin_profiles,
  }
  local f=io.open(path,"w")
  if f then f:write(json.encode(data)); f:close(); status("Saved: "..path)
  else status("Save failed: cannot write "..path) end
end

local function load_config(path)
  path = path or config_path()
  if not path then return end
  local f=io.open(path,"r"); if not f then return end
  local content=f:read("*a"); f:close()
  local data=json.decode(content)
  if type(data)~="table" then status("Config: invalid JSON"); return end
  if data.preset_name        then S.preset_name        = data.preset_name       end
  if data.active_bank        then S.active_bank         = data.active_bank       end
  if data.window_mode        then S.window_mode         = data.window_mode       end
  if data.scrub_sensitivity  then S.scrub_sensitivity   = data.scrub_sensitivity end
  if data.plugin_library     then S.plugin_library      = data.plugin_library    end
  if data.plugin_profiles    then S.plugin_profiles     = data.plugin_profiles   end
  if type(data.knob_ccs)=="table" then
    for i=1,8 do if data.knob_ccs[i] then S.knob_ccs[i]=data.knob_ccs[i] end end
  end
  status("Config loaded")
end

-- ============================================================
-- PLUGIN DETECTION
-- ============================================================

local function guess_by_name(name)
  for cat,names in pairs(PLUGIN_NAME_TABLE) do
    for _,n in ipairs(names) do
      if icontains(name,n) then return cat end
    end
  end
end

local function guess_by_params(track,fx_idx)
  local n=reaper.TrackFX_GetNumParams(track,fx_idx)
  local scores={}
  for cat in pairs(PARAM_PRIORITIES) do scores[cat]=0 end
  scores["Drums"]=0
  for p=0,math.min(n-1,40) do
    local _,pn=reaper.TrackFX_GetParamName(track,fx_idx,p,"")
    for cat,slots in pairs(PARAM_PRIORITIES) do
      for _,slot in ipairs(slots) do
        for _,kw in ipairs(slot) do
          if icontains(pn,kw) then scores[cat]=scores[cat]+1 end
        end
      end
    end
    for _,drum in ipairs(DRUM_PARTS) do
      for _,kw in ipairs(drum.kw) do
        if icontains(pn,kw) then scores["Drums"]=scores["Drums"]+1 end
      end
    end
  end
  local best,bs=nil,1
  for cat,score in pairs(scores) do if score>bs then best,bs=cat,score end end
  return best
end

local function lib_entry(name,track,fx_idx)
  if S.plugin_library[name] then return S.plugin_library[name] end
  local g=guess_by_name(name)
  if not g and track and fx_idx then g=guess_by_params(track,fx_idx) end
  g=g or "Unknown"
  local e={guessed=g, confirmed=g, status="Unconfirmed"}
  S.plugin_library[name]=e; return e
end

local function find_fx(track,category)
  if not track then return nil,nil end
  for i=0,reaper.TrackFX_GetCount(track)-1 do
    local _,raw=reaper.TrackFX_GetFXName(track,i,"")
    local name=strip_prefix(raw)
    if lib_entry(name,track,i).confirmed==category then return i,name end
  end
  return nil,nil
end

-- ============================================================
-- PLUGIN PROFILES
-- ============================================================

local function prof_key(name,bank) return name.."|"..tostring(bank) end

-- Fill up to 8 knob slots using synonym-group keyword matching per slot.
-- Each slot in PARAM_PRIORITIES is a table of synonyms tried in order.
local function autofill_params(profile,track,fx_idx,category)
  if not (track and fx_idx) then return end
  local n=reaper.TrackFX_GetNumParams(track,fx_idx)
  local pnames={}
  for p=0,n-1 do
    local _,pn=reaper.TrackFX_GetParamName(track,fx_idx,p,""); pnames[p]=pn
  end
  local used={}

  if category=="Drums" then
    -- Match each drum part's keywords to the best available parameter
    for k=1,8 do
      local drum=DRUM_PARTS[k]
      if drum then
        local found=false
        for _,kw in ipairs(drum.kw) do
          if found then break end
          for p,pn in pairs(pnames) do
            if not used[p] and icontains(pn,kw) then
              profile.knob_params[k]=p; profile.knob_labels[k]=pn
              used[p]=true; found=true; break
            end
          end
        end
      end
    end
    return
  end

  local slots=PARAM_PRIORITIES[category] or {}
  for k=1,8 do
    local slot=slots[k]  -- array of synonyms for this knob slot
    if slot then
      local found=false
      for _,kw in ipairs(slot) do
        if found then break end
        for p,pn in pairs(pnames) do
          if not used[p] and icontains(pn,kw) then
            profile.knob_params[k]=p; profile.knob_labels[k]=pn
            used[p]=true; found=true; break
          end
        end
      end
    end
  end
end

local function get_profile(plugin_name,bank_id,track,fx_idx)
  local key=prof_key(plugin_name,bank_id)
  if S.plugin_profiles[key] then return S.plugin_profiles[key] end

  local profile={
    knob_params     ={-1,-1,-1,-1,-1,-1,-1,-1},
    knob_labels     ={"","","","","","","",""},
    knob_min        ={0,0,0,0,0,0,0,0},   -- normalized lower bound for range
    knob_max        ={1,1,1,1,1,1,1,1},   -- normalized upper bound for range
    knob_relative   ={false,false,false,false,false,false,false,false},
    knob_names      ={"","","","","","","",""},  -- user-editable friendly names
    drum_pad_notes  ={-1,-1,-1,-1,-1,-1,-1,-1},
    drum_pad_labels ={"","","","","","","",""},
    confirmed       =false,
  }

  local cat=BANK_TO_CAT[bank_id]
  if cat then autofill_params(profile,track,fx_idx,cat) end

  -- Flag new drum plugins for the first-time prompt
  if bank_id==BANK_DRUMS and cat=="Drums" then
    S.pending_drum_prompt=plugin_name
  end

  S.plugin_profiles[key]=profile; return profile
end

-- ============================================================
-- BANK 1 — FOLLOW SELECTED TRACK
-- ============================================================

-- Note: K4 (High Pass) and K8 (Low Pass) delegate to the first EQ plugin on
-- the track. REAPER has no native HPF/LPF track property; the spec phrase
-- "REAPER track property" for these two appears to mean "without a separate
-- bank plugin" rather than a built-in API property.

local function bank1_apply(knob,cc_val,track)
  if not track then return end
  local norm=cc_norm(cc_val)
  if knob==1 then
    reaper.SetMediaTrackInfo_Value(track,"D_VOL",norm*2.0)
  elseif knob==2 then
    reaper.SetMediaTrackInfo_Value(track,"D_PAN",norm*2.0-1.0)
  elseif knob==3 then
    reaper.SetMediaTrackInfo_Value(track,"D_PITCH",norm*24.0-12.0)
  elseif knob==4 then
    local fx=find_fx(track,"EQ")
    if fx then
      local n=reaper.TrackFX_GetNumParams(track,fx)
      for p=0,n-1 do
        local _,pn=reaper.TrackFX_GetParamName(track,fx,p,"")
        if icontains(pn,"high pass") or icontains(pn,"hp freq") or icontains(pn,"highpass") then
          reaper.TrackFX_SetParamNormalized(track,fx,p,norm); break
        end
      end
    end
  elseif knob==5 then
    -- Relative playhead scrub using delta from previous CC value.
    -- The MPK Mini sends absolute CC values; we compute incremental delta so
    -- turning the knob moves the cursor rather than jumping to an absolute position.
    local prev=S.last_cc_raw[5]
    local delta=(cc_val-prev)*S.scrub_sensitivity*0.5
    reaper.SetEditCurPos(math.max(0,reaper.GetCursorPosition()+delta),true,true)
  elseif knob==6 then
    local fx=find_fx(track,"Reverb")
    if fx then
      local n=reaper.TrackFX_GetNumParams(track,fx)
      for p=0,n-1 do
        local _,pn=reaper.TrackFX_GetParamName(track,fx,p,"")
        if icontains(pn,"wet") or icontains(pn,"mix") then
          reaper.TrackFX_SetParamNormalized(track,fx,p,norm); break
        end
      end
    end
  elseif knob==7 then
    local fx=find_fx(track,"Delay")
    if fx then
      local n=reaper.TrackFX_GetNumParams(track,fx)
      for p=0,n-1 do
        local _,pn=reaper.TrackFX_GetParamName(track,fx,p,"")
        if icontains(pn,"wet") or icontains(pn,"mix") then
          reaper.TrackFX_SetParamNormalized(track,fx,p,norm); break
        end
      end
    end
  elseif knob==8 then
    local fx=find_fx(track,"EQ")
    if fx then
      local n=reaper.TrackFX_GetNumParams(track,fx)
      for p=0,n-1 do
        local _,pn=reaper.TrackFX_GetParamName(track,fx,p,"")
        if icontains(pn,"low pass") or icontains(pn,"lp freq") or icontains(pn,"lowpass") then
          reaper.TrackFX_SetParamNormalized(track,fx,p,norm); break
        end
      end
    end
  end
end

local function bank1_reset(knob,track)
  if not track then return end
  if knob==1 then reaper.SetMediaTrackInfo_Value(track,"D_VOL",1.0)
  elseif knob==2 then reaper.SetMediaTrackInfo_Value(track,"D_PAN",0.0)
  elseif knob==3 then reaper.SetMediaTrackInfo_Value(track,"D_PITCH",0.0)
  elseif knob==4 then
    local fx=find_fx(track,"EQ")
    if fx then
      local n=reaper.TrackFX_GetNumParams(track,fx)
      for p=0,n-1 do
        local _,pn=reaper.TrackFX_GetParamName(track,fx,p,"")
        if icontains(pn,"high pass") or icontains(pn,"highpass") then
          reaper.TrackFX_SetParamNormalized(track,fx,p,0.0); break  -- min freq
        end
      end
    end
  elseif knob==5 then -- no reset for scrub
  elseif knob==6 then
    local fx=find_fx(track,"Reverb")
    if fx then
      local n=reaper.TrackFX_GetNumParams(track,fx)
      for p=0,n-1 do
        local _,pn=reaper.TrackFX_GetParamName(track,fx,p,"")
        if icontains(pn,"wet") or icontains(pn,"mix") then
          local _,_,_,def=reaper.TrackFX_GetParam(track,fx,p)
          reaper.TrackFX_SetParamNormalized(track,fx,p,def); break
        end
      end
    end
  elseif knob==7 then
    local fx=find_fx(track,"Delay")
    if fx then
      local n=reaper.TrackFX_GetNumParams(track,fx)
      for p=0,n-1 do
        local _,pn=reaper.TrackFX_GetParamName(track,fx,p,"")
        if icontains(pn,"wet") or icontains(pn,"mix") then
          local _,_,_,def=reaper.TrackFX_GetParam(track,fx,p)
          reaper.TrackFX_SetParamNormalized(track,fx,p,def); break
        end
      end
    end
  elseif knob==8 then
    local fx=find_fx(track,"EQ")
    if fx then
      local n=reaper.TrackFX_GetNumParams(track,fx)
      for p=0,n-1 do
        local _,pn=reaper.TrackFX_GetParamName(track,fx,p,"")
        if icontains(pn,"low pass") or icontains(pn,"lowpass") then
          reaper.TrackFX_SetParamNormalized(track,fx,p,1.0); break  -- max freq
        end
      end
    end
  end
end

-- ============================================================
-- BANKS 2-7 — PLUGIN CATEGORY BANKS
-- ============================================================

local function plugin_bank_apply(knob,cc_val,track,bank_id)
  if not track then return end
  local cat=BANK_TO_CAT[bank_id]; if not cat then return end
  local fx,pname=find_fx(track,cat); if not fx then return end
  local profile=get_profile(pname,bank_id,track,fx)
  local param=profile.knob_params[knob]; if param<0 then return end

  local norm=cc_norm(cc_val)
  local lo=profile.knob_min[knob] or 0
  local hi=profile.knob_max[knob] or 1

  if profile.knob_relative[knob] then
    -- Relative mode: use CC delta to increment the current value
    local prev=S.last_cc_raw[knob]
    local cur=reaper.TrackFX_GetParamNormalized(track,fx,param)
    local delta=(cc_val-prev)/127.0*(hi-lo)
    reaper.TrackFX_SetParamNormalized(track,fx,param,clamp(cur+delta,lo,hi))
  else
    reaper.TrackFX_SetParamNormalized(track,fx,param,lo+norm*(hi-lo))
  end
end

local function plugin_bank_reset(knob,track,bank_id)
  if not track then return end
  local cat=BANK_TO_CAT[bank_id]; if not cat then return end
  local fx,pname=find_fx(track,cat); if not fx then return end
  local profile=get_profile(pname,bank_id,track,fx)
  local param=profile.knob_params[knob]; if param<0 then return end
  local _,_,_,def=reaper.TrackFX_GetParam(track,fx,param)
  reaper.TrackFX_SetParamNormalized(track,fx,param,def)
end

-- ============================================================
-- BANK 8 — DRUMS
-- ============================================================

local function drum_bank_apply(knob,cc_val,track)
  if not track then return end
  local fx,pname=find_fx(track,"Drums"); if not fx then return end
  local profile=get_profile(pname,BANK_DRUMS,track,fx)
  local param=profile.knob_params[knob]; if param<0 then return end
  local norm=cc_norm(cc_val)
  local lo=profile.knob_min[knob] or 0
  local hi=profile.knob_max[knob] or 1
  reaper.TrackFX_SetParamNormalized(track,fx,param,lo+norm*(hi-lo))
end

local function drum_bank_reset(knob,track)
  if not track then return end
  local fx,pname=find_fx(track,"Drums"); if not fx then return end
  local profile=get_profile(pname,BANK_DRUMS,track,fx)
  local param=profile.knob_params[knob]; if param<0 then return end
  local _,_,_,def=reaper.TrackFX_GetParam(track,fx,param)
  reaper.TrackFX_SetParamNormalized(track,fx,param,def)
end

-- Remap a drum pad note.  Works for both Bank 1 (when a drum plugin is on the
-- selected track) and Bank 8.  Returns the target note or the original if unmapped.
local function remap_drum_note(note,track)
  if not track then return note end
  local fx,pname=find_fx(track,"Drums"); if not fx then return note end
  local profile=get_profile(pname,BANK_DRUMS,track,fx)
  for pad_idx,src_note in ipairs(PAD_DEFAULT_NOTES) do
    if note==src_note and profile.drum_pad_notes[pad_idx]>=0 then
      return profile.drum_pad_notes[pad_idx]
    end
  end
  return note
end

-- ============================================================
-- UNIFIED RESET
-- ============================================================

local function reset_knob(knob,track)
  if not track then return end
  local bank=S.active_bank
  if bank==BANK_FOLLOW then bank1_reset(knob,track)
  elseif bank==BANK_DRUMS then drum_bank_reset(knob,track)
  else plugin_bank_reset(knob,track,bank) end
end

-- ============================================================
-- KNOB LABEL REFRESH
-- ============================================================

local function refresh_knob_labels(track)
  local bank=S.active_bank
  if bank==BANK_FOLLOW then
    for k=1,8 do S.knob_labels[k]=BANK1_LABELS[k]; S.knob_active[k]=(track~=nil) end
    S.knob_active[5]=true  -- scrub is always global
    if track then
      S.knob_active[6]=(find_fx(track,"Reverb")~=nil)
      S.knob_active[7]=(find_fx(track,"Delay")~=nil)
    end
  elseif bank==BANK_DRUMS then
    for k=1,8 do
      S.knob_labels[k]=DRUM_PARTS[k] and DRUM_PARTS[k].label or ""; S.knob_active[k]=false
    end
    if track then
      local fx,pname=find_fx(track,"Drums")
      if fx then
        local profile=get_profile(pname,BANK_DRUMS,track,fx)
        for k=1,8 do
          local friendly=profile.knob_names[k]
          S.knob_labels[k]=friendly~="" and friendly or
              (profile.knob_labels[k]~="" and profile.knob_labels[k] or
              (DRUM_PARTS[k] and DRUM_PARTS[k].label or ""))
          S.knob_active[k]=(profile.knob_params[k]>=0)
        end
      end
    end
  else
    local cat=BANK_TO_CAT[bank]
    for k=1,8 do S.knob_labels[k]="—"; S.knob_active[k]=false end
    if track and cat then
      local fx,pname=find_fx(track,cat)
      if fx then
        local profile=get_profile(pname,bank,track,fx)
        for k=1,8 do
          local friendly=profile.knob_names[k]
          S.knob_labels[k]=friendly~="" and friendly or
              (profile.knob_labels[k]~="" and profile.knob_labels[k] or "—")
          S.knob_active[k]=(profile.knob_params[k]>=0)
        end
      end
    end
  end
end

-- ============================================================
-- MIDI BRIDGE — JSFX + gmem
-- CreateMIDIInput is C++ only and not available in Lua ReaScript.
-- Instead we write a small JSFX helper to the REAPER Effects folder,
-- place it in the input FX chain of a dedicated MIDI track, and
-- communicate via REAPER's shared gmem memory.
-- ============================================================

-- Find the MPK Mini's MIDI input device index (for auto-configuring the track)
local function find_mpk_mini()
  for i=0,reaper.GetNumMIDIInputs()-1 do
    local _,name=reaper.GetMIDIInputName(i,"")
    if icontains(name,"mpk mini") or icontains(name,"mpkmini") then return i,name end
  end
  return -1,"MPK Mini not found"
end

-- Write the embedded JSFX to %APPDATA%\REAPER\Effects\ (always overwrites so
-- updates to JSFX_SRC are picked up after a REAPER restart or FX reload).
local function write_jsfx()
  local path=reaper.GetResourcePath().."\\Effects\\MPKMiniMapper_MIDI.jsfx"
  local f=io.open(path,"w")
  if not f then
    status("Cannot write JSFX to: "..path); return false
  end
  f:write(JSFX_SRC); f:close(); return true
end

-- Find or create the dedicated MIDI input track.
-- Returns true when the track is ready in S.midi_track.
local function ensure_midi_track()
  -- Re-validate existing reference
  if S.midi_track and reaper.ValidatePtr(S.midi_track,"MediaTrack*") then
    return true
  end
  -- Search for an existing track with our name
  for i=0,reaper.CountTracks(0)-1 do
    local t=reaper.GetTrack(0,i)
    local _,n=reaper.GetTrackName(t,"")
    if n==MIDI_TRACK_NAME then S.midi_track=t; return true end
  end
  -- Create a new track at the end of the track list
  reaper.Undo_BeginBlock()
  local idx=reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(idx,true)
  local t=reaper.GetTrack(0,idx)
  reaper.GetSetMediaTrackInfo_String(t,"P_NAME",MIDI_TRACK_NAME,true)
  -- Set MIDI input: bit 12 (4096) = MIDI flag; bits 5-10 = device+1 (0 = any)
  -- I_RECSRC encoding per REAPER SDK: 4096 | (channel & 0x1F) | ((dev+1) << 5)
  local dev=find_mpk_mini()
  local recsrc=4096  -- default: any MIDI device, all channels
  if dev>=0 then recsrc=4096|((dev+1)<<5) end
  reaper.SetMediaTrackInfo_Value(t,"I_RECSRC",recsrc)
  reaper.SetMediaTrackInfo_Value(t,"I_RECARM",1)       -- arm for input monitoring
  reaper.SetMediaTrackInfo_Value(t,"B_MUTE",1)         -- mute — audio output not wanted
  reaper.SetMediaTrackInfo_Value(t,"I_HEIGHTOVERRIDE",18)  -- minimize height
  reaper.Undo_EndBlock("MPKMiniMapper: create MIDI input track",-1)
  S.midi_track=t; return true
end

-- Add the JSFX to the track's INPUT FX chain if not already there.
-- recFX=true means the input/record FX chain in TrackFX API calls.
local function ensure_jsfx_on_track()
  if not S.midi_track then return false end
  if not reaper.ValidatePtr(S.midi_track,"MediaTrack*") then return false end
  -- TrackFX_GetByName with recFX=true searches the input FX chain
  if reaper.TrackFX_GetByName(S.midi_track,"MPKMiniMapper_MIDI",true)>=0 then
    return true  -- already present
  end
  -- -1 = add new instance; true = input FX chain
  local idx=reaper.TrackFX_AddByName(S.midi_track,"MPKMiniMapper_MIDI",true,-1)
  return idx>=0
end

-- Full MIDI bridge initialisation called from init()
local function init_midi()
  if not write_jsfx() then return end
  if not ensure_midi_track() then
    status("Could not create MIDI input track"); return
  end
  if not ensure_jsfx_on_track() then
    status("Could not add JSFX — verify REAPER Effects folder is writable"); return
  end
  reaper.gmem_attach("MPKMiniMapper")  -- must be called before any gmem_read/write
  S.jsfx_ready=true
  status("MIDI bridge ready — route MPK Mini to '"..MIDI_TRACK_NAME.."' track")
end

-- ============================================================
-- SYSEX — SEND / RECEIVE / PARSE
-- Communicates with the MPK Mini MK3 onboard RAM via the JSFX
-- gmem TX/RX slots.  See docs/MPK_MINI_MK3_SYSEX_PROTOCOL.md.
-- ============================================================

-- Write a SysEx byte table into the JSFX TX gmem slot.
-- Returns false if the bridge is not ready or the slot is busy.
local function send_sysex(bytes)
  if not S.jsfx_ready then return false end
  local n = #bytes
  if n > SYSEX_MAX_LEN then return false end
  if (reaper.gmem_read(GMEM_SYSEX_TX) or 0) ~= 0 then return false end  -- slot busy
  for i = 1, n do
    reaper.gmem_write(GMEM_SYSEX_TX_BUF + (i-1), bytes[i])
  end
  reaper.gmem_write(GMEM_SYSEX_TX, n)  -- arm the JSFX to send
  return true
end

-- Send a GET PRESET request to the device for the given slot (1-4).
-- The JSFX will capture the response and write it into the RX gmem slot.
local function read_device_preset(slot)
  slot = clamp(slot or 1, 1, 4)
  S.device_preset_slot = slot
  S.sysex_read_pending = true
  -- F0 47 00 49 63 00 01 [slot] F7
  local msg = {0xF0, 0x47, 0x00, 0x49, 0x63, 0x00, 0x01, slot, 0xF7}
  if send_sysex(msg) then
    status("Reading preset "..slot.." from device…")
  else
    status("Read failed: MIDI bridge not ready")
    S.sysex_read_pending = false
  end
end

-- ============================================================
-- DEVICE PRESET PARSING / BUILDING
-- SysEx payload byte map (0-indexed offsets from payload start):
--   0-3:  pad_ch, key_ch, octave(0-8), transpose(0-24)
--   4-13: arp_on, arp_mode(0-5), arp_div(0-7), arp_clock(0-1),
--          arp_latch, arp_swing(0-5), arp_taps(2-4), bpm_msb, bpm_lsb, arp_octave(0-3)
--   14-19: joy_x_mode(0-2), joy_x_cc1, joy_x_cc2, joy_y_mode, joy_y_cc1, joy_y_cc2
--   84-107: knob1..8 × {cc, min, max}
-- payload[0] = bytes[9] in 1-based Lua indexing.
-- ============================================================

local function parse_preset_fields(bytes)
  local function p(o) return bytes[9 + o] or 0 end
  local f = {}
  f.pad_ch     = p(0)
  f.key_ch     = p(1)
  f.octave     = p(2)          -- raw 0-8, UI displays as p(2)-4
  f.transpose  = p(3)          -- raw 0-24, UI displays as p(3)-12
  f.arp_on     = p(4) ~= 0
  f.arp_mode   = p(5)
  f.arp_div    = p(6)
  f.arp_clock  = p(7)          -- 0=internal, 1=external
  f.arp_latch  = p(8) ~= 0
  f.arp_swing  = p(9)
  f.arp_taps   = p(10)         -- 2-4
  f.arp_bpm    = p(11)*128 + p(12)
  f.arp_octave = p(13)         -- raw 0-3, UI displays as p(13)+1
  f.joy_x_mode = p(14)
  f.joy_x_cc1  = p(15)
  f.joy_x_cc2  = p(16)
  f.joy_y_mode = p(17)
  f.joy_y_cc1  = p(18)
  f.joy_y_cc2  = p(19)
  f.knob_cc    = {}
  f.knob_min   = {}
  f.knob_max   = {}
  for k = 1, 8 do
    local o = 84 + (k-1)*3
    f.knob_cc[k]  = p(o)
    f.knob_min[k] = p(o+1)
    f.knob_max[k] = p(o+2)
  end
  f.prog_name = ""  -- local label only; SysEx position unconfirmed, not transmitted
  return f
end

-- Build a full SysEx preset byte table from parsed fields.
-- raw_bytes is used as the base so untouched sections (pads) stay intact.
local function build_preset_sysex(fields, slot, raw_bytes)
  local bytes = {}
  for i, b in ipairs(raw_bytes) do bytes[i] = b end
  bytes[8] = clamp(slot or 1, 1, 4)
  local function sp(o, v) bytes[9 + o] = v & 0x7F end
  sp(0,  clamp(fields.pad_ch, 0, 15))
  sp(1,  clamp(fields.key_ch, 0, 15))
  sp(2,  clamp(fields.octave, 0, 8))
  sp(3,  clamp(fields.transpose, 0, 24))
  sp(4,  fields.arp_on and 1 or 0)
  sp(5,  clamp(fields.arp_mode, 0, #ARP_MODES-1))
  sp(6,  clamp(fields.arp_div, 0, #ARP_DIVS-1))
  sp(7,  clamp(fields.arp_clock, 0, 1))
  sp(8,  fields.arp_latch and 1 or 0)
  sp(9,  clamp(fields.arp_swing, 0, #ARP_SWINGS-1))
  sp(10, clamp(fields.arp_taps, 2, 4))
  local bpm = clamp(math.floor(fields.arp_bpm or 120), 20, 240)
  sp(11, math.floor(bpm / 128))
  sp(12, bpm % 128)
  sp(13, clamp(fields.arp_octave, 0, 3))
  sp(14, clamp(fields.joy_x_mode, 0, 2))
  sp(15, clamp(fields.joy_x_cc1, 0, 127))
  sp(16, clamp(fields.joy_x_cc2, 0, 127))
  sp(17, clamp(fields.joy_y_mode, 0, 2))
  sp(18, clamp(fields.joy_y_cc1, 0, 127))
  sp(19, clamp(fields.joy_y_cc2, 0, 127))
  for k = 1, 8 do
    local o = 84 + (k-1)*3
    sp(o,   clamp(fields.knob_cc[k], 0, 127))
    sp(o+1, clamp(fields.knob_min[k], 0, 127))
    sp(o+2, clamp(fields.knob_max[k], 0, 127))
  end
  return bytes
end

-- Parse a raw preset dump byte table and apply knob CC numbers.
-- Wire layout (1-based Lua index):
--   [1]=F0 [2]=47 [3]=00 [4]=49 [5]=61 [6]=00 [7]=68
--   [8]=preset_num  [9..114]=payload (106 bytes)  [115]=F7
-- Knob CC numbers sit at payload offsets 84, 87, 90 … (3 bytes each).
-- payload[0] = bytes[9], so knob k CC = bytes[9 + 84 + (k-1)*3].
local function apply_preset_bytes(bytes)
  S.device_preset_bytes  = bytes
  S.device_config_fields = parse_preset_fields(bytes)
  local new_ccs = {}
  for k = 1, 8 do
    local cc = S.device_config_fields.knob_cc[k]
    new_ccs[k] = (cc >= 0 and cc <= 127) and cc or S.knob_ccs[k]
  end
  S.knob_ccs = new_ccs
  refresh_knob_labels(S.last_track)
  status("Preset "..S.device_preset_slot.." read — knob CCs: "..table.concat(new_ccs,","))
end

-- Poll the JSFX RX gmem slot for an incoming preset dump.
-- Called every defer frame from poll_midi_gmem.
local function poll_sysex_rx()
  if not S.jsfx_ready then return end
  local len = math.floor(reaper.gmem_read(GMEM_SYSEX_RX) or 0)
  if len == 0 then return end
  -- Read the bytes out
  local bytes = {}
  for i = 0, len-1 do
    bytes[i+1] = math.floor(reaper.gmem_read(GMEM_SYSEX_RX_BUF + i) or 0)
  end
  reaper.gmem_write(GMEM_SYSEX_RX, 0)  -- free the slot immediately
  -- Validate: F0 47 00 49 61 … (preset dump response)
  if bytes[1]==0xF0 and bytes[2]==0x47 and bytes[5]==0x61 then
    S.sysex_read_pending = false
    apply_preset_bytes(bytes)
  end
end

-- Build the modified preset blob from the cached raw bytes with updated knob
-- CC numbers, then push it to the device RAM (no persistent flash write).
local function write_device_preset_to_device(slot)
  slot = clamp(slot or S.device_preset_slot, 1, 4)
  if not S.device_preset_bytes then
    status("Read a preset from device first"); return
  end
  local fields = S.device_config_fields or parse_preset_fields(S.device_preset_bytes)
  -- Sync live knob CCs into fields before sending
  for k = 1, 8 do fields.knob_cc[k] = S.knob_ccs[k] end
  local bytes = build_preset_sysex(fields, slot, S.device_preset_bytes)
  if send_sysex(bytes) then
    status("Preset sent to device RAM (slot "..slot..")")
  else
    status("Send failed: MIDI bridge not ready")
  end
end

-- ============================================================
-- MIDI PROCESSING
-- ============================================================

local function build_param_cache(knob)  -- forward declaration resolved below
end

local function process_midi_event(msg1,msg2,msg3,track)
  local sb=msg1&0xF0; local ch=msg1&0x0F

  -- Program Change → bank switch (intercepted, never passed through)
  if sb==0xC0 then
    local bank=msg2+1
    if bank>=1 and bank<=8 then
      S.active_bank=bank
      refresh_knob_labels(track)
      status("Bank: "..(BANK_NAMES[bank] or ""))
    end
    return
  end

  -- Control Change → knob routing
  if sb==0xB0 then
    local cc=msg2; local val=msg3
    -- MIDI Learn: capture CC for the selected knob
    if S.midi_learn_active and S.midi_learn_knob then
      S.knob_ccs[S.midi_learn_knob]=cc
      S.midi_learn_active=false
      status("Learned CC "..cc.." → K"..S.midi_learn_knob); return
    end
    for k=1,8 do
      if S.knob_ccs[k]==cc then
        -- Auto-select the touched knob in Setup mode
        if S.window_mode==MODE_SETUP and S.selected_knob~=k then
          S.selected_knob=k; S.selected_pad=nil; S.dropdown_open=nil
          build_param_cache(k)
        end
        if S.active_bank==BANK_FOLLOW then bank1_apply(k,val,track)
        elseif S.active_bank==BANK_DRUMS then drum_bank_apply(k,val,track)
        else plugin_bank_apply(k,val,track,S.active_bank) end
        S.last_cc_raw[k]=val
        S.knob_touched_time[k]=reaper.time_precise()
        break
      end
    end
    return
  end

  -- Note On → drum pad remapping for Bank 8 AND Bank 1 when drum plugin present
  if sb==0x90 and msg3>0 then
    local needs_remap=(S.active_bank==BANK_DRUMS) or
        (S.active_bank==BANK_FOLLOW and find_fx(track,"Drums")~=nil)
    if needs_remap then
      reaper.StuffMIDIMessage(0,0x90|ch,remap_drum_note(msg2,track),msg3)
    else
      reaper.StuffMIDIMessage(0,msg1,msg2,msg3)
    end
    return
  end

  -- Note Off → same remapping logic
  if sb==0x80 or (sb==0x90 and msg3==0) then
    local needs_remap=(S.active_bank==BANK_DRUMS) or
        (S.active_bank==BANK_FOLLOW and find_fx(track,"Drums")~=nil)
    if needs_remap then
      reaper.StuffMIDIMessage(0,0x80|ch,remap_drum_note(msg2,track),0)
    else
      reaper.StuffMIDIMessage(0,msg1,msg2,msg3)
    end
    return
  end

  -- All other messages pass through unchanged
  reaper.StuffMIDIMessage(0,msg1,msg2,msg3)
end

-- Poll MIDI events from the gmem ring buffer written by the JSFX helper.
-- Sets the drum-intercept flag so JSFX can block note pass-through when needed.
local function poll_midi_gmem(track)
  if not S.jsfx_ready then return end
  -- Tell JSFX whether to block note-on/off (drum remapping mode)
  local drum_mode = ((S.active_bank == BANK_DRUMS) or
    (S.active_bank == BANK_FOLLOW and track and find_fx(track, "Drums") ~= nil)) and 1 or 0
  reaper.gmem_write(GMEM_BASE + 2, drum_mode)
  poll_sysex_rx()
  -- Drain the ring buffer
  local rp = math.floor(reaper.gmem_read(GMEM_BASE + 1) or GMEM_BUF)
  local wp = math.floor(reaper.gmem_read(GMEM_BASE + 0) or GMEM_BUF)
  local iter = 0
  while rp ~= wp and iter < 200 do
    local m1 = math.floor(reaper.gmem_read(rp) or 0)
    local m2 = math.floor(reaper.gmem_read(rp + 1) or 0)
    local m3 = math.floor(reaper.gmem_read(rp + 2) or 0)
    process_midi_event(m1, m2, m3, track)
    rp = rp + 3
    if rp >= GMEM_BUF + GMEM_BSIZ then rp = GMEM_BUF end
    reaper.gmem_write(GMEM_BASE + 1, rp)
    iter = iter + 1
  end
end

-- ============================================================
-- TRACK FOLLOWING
-- ============================================================

local function update_track()
  local track=reaper.GetSelectedTrack(0,0)
  if track~=S.last_track then
    S.last_track=track
    if track then local _,n=reaper.GetTrackName(track,""); S.last_track_name=n
    else S.last_track_name="No track selected" end
    refresh_knob_labels(track)
  end
  return track
end

-- ============================================================
-- PROJECT CHANGE DETECTION
-- ============================================================

local function check_project_change()
  local d=reaper.GetProjectPathEx()
  if d~=S.last_proj_path then
    S.last_proj_path=d
    if d and d~="" then load_config(); refresh_knob_labels(S.last_track) end
  end
end

-- ============================================================
-- PARAM CACHE (for Setup dropdown)
-- ============================================================

build_param_cache = function(knob)
  S.param_cache={}
  local track=S.last_track; if not track then return end
  local bank=S.active_bank
  local fx
  if bank==BANK_FOLLOW then
    if knob==6 then fx=find_fx(track,"Reverb")
    elseif knob==7 then fx=find_fx(track,"Delay")
    else return end
  elseif bank==BANK_DRUMS then
    fx=find_fx(track,"Drums")
  else
    fx=find_fx(track,BANK_TO_CAT[bank])
  end
  if not fx then return end
  local n=reaper.TrackFX_GetNumParams(track,fx)
  for p=0,n-1 do
    local _,pn=reaper.TrackFX_GetParamName(track,fx,p,"")
    S.param_cache[#S.param_cache+1]={idx=p,name=pn}
  end
end

-- Get the profile + fx index for the currently selected knob's context
local function knob_context(knob)
  local track=S.last_track; if not track then return nil,nil,nil end
  local bank=S.active_bank
  local fx,pname
  if bank==BANK_FOLLOW then
    if knob==6 then fx,pname=find_fx(track,"Reverb")
    elseif knob==7 then fx,pname=find_fx(track,"Delay")
    else return nil,nil,nil end
  elseif bank==BANK_DRUMS then
    fx,pname=find_fx(track,"Drums")
  else
    fx,pname=find_fx(track,BANK_TO_CAT[bank])
  end
  if not (fx and pname) then return nil,nil,nil end
  return get_profile(pname,bank,track,fx),fx,track
end

local function assign_param(knob,param_idx,param_name)
  local profile,fx,track=knob_context(knob)
  if not profile then return end
  profile.knob_params[knob]=param_idx
  profile.knob_labels[knob]=param_name
  S.knob_labels[knob]=profile.knob_names[knob]~="" and profile.knob_names[knob] or param_name
  S.knob_active[knob]=true
  S.dropdown_open=nil
  status("K"..knob.." → "..param_name)
end

local function current_param_display(knob)
  local profile,fx,track=knob_context(knob)
  if not profile then return "(no plugin)" end
  if S.active_bank==BANK_FOLLOW and knob~=6 and knob~=7 then return "(fixed)" end
  local p=profile.knob_params[knob]
  if p<0 then return "(none)" end
  local _,lbl=reaper.TrackFX_GetParamName(track,fx,p,"")
  return lbl
end

-- ============================================================
-- UI HELPERS
-- ============================================================

local function set_col(c,a) gfx.set(c[1],c[2],c[3],a or 1.0) end
local function fill_rect(x,y,w,h,c,a) set_col(c,a); gfx.rect(x,y,w,h,1) end
local function stroke_rect(x,y,w,h,c,a) set_col(c,a); gfx.rect(x,y,w,h,0) end
local function draw_str(x,y,txt,c,f)
  gfx.setfont(f or FONT_NORMAL); set_col(c or{.9,.9,.9}); gfx.x,gfx.y=x,y; gfx.drawstr(txt)
end
local function draw_strc(x,y,w,txt,c,f)
  gfx.setfont(f or FONT_NORMAL)
  draw_str(x+math.floor((w-gfx.measurestr(txt))/2),y,txt,c,f)
end
local function hov(x,y,w,h)
  return gfx.mouse_x>=x and gfx.mouse_x<x+w and gfx.mouse_y>=y and gfx.mouse_y<y+h
end
local function clicked(x,y,w,h)
  return hov(x,y,w,h) and gfx.mouse_lb==1 and S.prev_mouse_lb==0
end

-- Colors
local CB={0.11,0.11,0.13}; local CP={0.17,0.17,0.20}; local CBR={0.30,0.30,0.36}
local CT={0.90,0.90,0.90}; local CD={0.45,0.45,0.50}
local CBTN={0.22,0.22,0.27}; local CBTH={0.32,0.32,0.40}
local CA={0.30,0.60,1.00}; local CRST={0.70,0.40,0.10}
local COK={0.30,0.85,0.30}; local CWN={0.90,0.75,0.20}

local function btn(x,y,w,h,lbl,ac)
  local bg=hov(x,y,w,h) and CBTH or (ac or CBTN)
  fill_rect(x,y,w,h,bg); stroke_rect(x,y,w,h,CBR)
  draw_strc(x,y+math.floor((h-11)/2),w,lbl,CT,FONT_SMALL)
  return clicked(x,y,w,h)
end

-- Horizontal slider: returns new value if dragged, else val
local function hslider(x,y,w,h,val,col)
  fill_rect(x,y,w,h,CP); stroke_rect(x,y,w,h,CBR)
  fill_rect(x,y,math.floor(val*w),h,col or CA)
  if gfx.mouse_lb==1 and hov(x,y-4,w,h+8) then
    return clamp((gfx.mouse_x-x)/w,0,1)
  end
  return val
end

-- Stepper: [-] value [+], optional step size; returns updated value
local function num_field(x,y,w,h,val,mn,mx,step)
  step = step or 1
  local bw = math.min(18,math.floor(w*0.22))
  local nv = val
  if btn(x,y,bw,h,"-") then nv=clamp(val-step,mn,mx) end
  if btn(x+w-bw,y,bw,h,"+") then nv=clamp(val+step,mn,mx) end
  fill_rect(x+bw,y,w-bw*2,h,CP); stroke_rect(x+bw,y,w-bw*2,h,CBR)
  draw_strc(x+bw,y+math.floor((h-11)/2),w-bw*2,tostring(nv),CT,FONT_SMALL)
  return nv
end

-- Click-to-cycle enum button; idx is 0-based, vals is a 1-based Lua array
local function cyc_field(x,y,w,h,idx,vals)
  local lbl=(vals[idx+1] or tostring(idx)).." \xe2\x96\xba"
  if btn(x,y,w,h,lbl) then return (idx+1)%#vals end
  return idx
end

-- ON/OFF toggle button; val is boolean
local function tog_field(x,y,w,h,val)
  if btn(x,y,w,h,val and "ON" or "OFF",val and COK or nil) then return not val end
  return val
end

-- Text field widget: click to begin editing, Enter/Esc to finish
local function ti_field(x,y,w,h,id,cur_val,on_done)
  local is_me=TI.active and TI.id==id
  fill_rect(x,y,w,h,is_me and{0.20,0.20,0.30} or CBTN)
  stroke_rect(x,y,w,h,is_me and CA or CBR)
  local blink=math.floor(reaper.time_precise()*2)%2==0
  local txt=is_me and (TI.value..(blink and "|" or "")) or (cur_val~="" and cur_val or "…")
  draw_str(x+4,y+math.floor((h-11)/2),txt,CT,FONT_SMALL)
  if clicked(x,y,w,h) then
    if is_me then TI.active=false else ti_begin(id,cur_val,on_done) end
  end
end

-- ============================================================
-- UI — MODE: MINI
-- ============================================================

local function draw_mini()
  fill_rect(0,0,gfx.w,gfx.h,CB)
  local bc=BANK_COLORS[S.active_bank]
  fill_rect(0,0,gfx.w,3,bc)
  gfx.setfont(FONT_BOLD); set_col(bc); gfx.x,gfx.y=8,7
  gfx.drawstr(BANK_NAMES[S.active_bank] or "")
  draw_str(8,24,S.last_track_name,CD,FONT_SMALL)
  local ry={46,98}; local cw=math.floor(gfx.w/4)
  local now=reaper.time_precise()
  local GLOW_DUR=2.0
  for k=1,8 do
    local row=k<=4 and 1 or 2; local col=((k-1)%4)+1
    local bx=(col-1)*cw; local by=ry[row]
    -- Activity dot: dim when assigned, glows bank-color for GLOW_DUR after touch
    if S.knob_active[k] then
      local age=now-(S.knob_touched_time[k] or 0)
      local glow=age<GLOW_DUR and (1.0-age/GLOW_DUR) or 0
      -- dim base ring
      gfx.set(bc[1]*0.3,bc[2]*0.3,bc[3]*0.3,0.7)
      gfx.circle(bx+6,by+6,3,1,1)
      -- bright glow overlay fades out
      if glow>0 then
        gfx.set(bc[1],bc[2],bc[3],glow)
        gfx.circle(bx+6,by+6,4,1,1)
        -- subtle halo ring at peak
        if glow>0.6 then
          gfx.set(bc[1],bc[2],bc[3],(glow-0.6)/0.4*0.4)
          gfx.circle(bx+6,by+6,6,0,1)
        end
      end
    end
    draw_str(bx+13,by,"K"..k..": "..(S.knob_labels[k] or ""),
             S.knob_active[k] and CT or CD,FONT_SMALL)
  end
  local bw=math.floor((gfx.w-16)/2); local by=gfx.h-26
  if btn(6,by,bw,20,"Dashboard") then
    S.window_mode=MODE_DASHBOARD
    reaper.SetExtState(SCRIPT_NAME,"window_mode",MODE_DASHBOARD,false)
    gfx.init(SCRIPT_NAME,DIMS[MODE_DASHBOARD].w,DIMS[MODE_DASHBOARD].h)
  end
  if btn(10+bw,by,bw,20,"Setup") then
    S.window_mode=MODE_SETUP
    reaper.SetExtState(SCRIPT_NAME,"window_mode",MODE_SETUP,false)
    gfx.init(SCRIPT_NAME,DIMS[MODE_SETUP].w,DIMS[MODE_SETUP].h)
  end
end

-- ============================================================
-- UI — MODE: DASHBOARD
-- ============================================================

local function draw_bank_dots(x,y)
  local r=7; local gap=22; local track=S.last_track
  for b=1,8 do
    local cx=x+(b-1)*gap+r; local col=BANK_COLORS[b]
    local cat=BANK_TO_CAT[b]
    local has=(b==BANK_FOLLOW and track~=nil) or
              (track and cat and find_fx(track,cat)~=nil)
    if has then set_col(col); gfx.circle(cx,y,r,1,1)
    else set_col(col,0.3); gfx.circle(cx,y,r,0,1) end
    if b==S.active_bank then set_col(CT); gfx.circle(cx,y,r+2,0,1) end
  end
end

local function draw_dashboard()
  fill_rect(0,0,gfx.w,gfx.h,CB)
  local bc=BANK_COLORS[S.active_bank]; fill_rect(0,0,gfx.w,3,bc)
  draw_str(8,7,"Track: "..S.last_track_name,CT,FONT_BOLD)
  gfx.setfont(FONT_NORMAL); set_col(bc); gfx.x,gfx.y=8,24
  gfx.drawstr("Bank: "..(BANK_NAMES[S.active_bank] or ""))
  draw_bank_dots(8,53)
  local cw=math.floor(gfx.w/4); local ry={76,128}
  for k=1,8 do
    local row=k<=4 and 1 or 2; local col=((k-1)%4)+1
    local x=(col-1)*cw+6; local y=ry[row]
    local no_reset=(S.active_bank==BANK_FOLLOW and k==5)
    draw_str(x,y,"K"..k..": "..(S.knob_labels[k] or ""),
             S.knob_active[k] and CT or CD,FONT_SMALL)
    if S.knob_active[k] and not no_reset and hov(x,y-2,cw-2,28) then
      -- Spec: "↺" symbol for hover-reveal reset button
      if btn(x+cw-24,y,20,14,"\xe2\x86\xba",CRST) then reset_knob(k,S.last_track) end
    end
  end
  -- Scrub sensitivity slider
  local sx,sy,sw,sh=8,184,200,14
  draw_str(sx+sw+8,sy+1,"Scrub Sensitivity",CD,FONT_SMALL)
  S.scrub_sensitivity=hslider(sx,sy,sw,sh,S.scrub_sensitivity)
  if S.status_msg~="" and (reaper.time_precise()-S.status_time)<3.0 then
    draw_str(8,206,S.status_msg,CD,FONT_SMALL)
  end
  local bw=math.floor((gfx.w-16)/2); local by=gfx.h-26
  if btn(6,by,bw,20,"Mini") then
    S.window_mode=MODE_MINI
    reaper.SetExtState(SCRIPT_NAME,"window_mode",MODE_MINI,false)
    gfx.init(SCRIPT_NAME,DIMS[MODE_MINI].w,DIMS[MODE_MINI].h)
  end
  if btn(10+bw,by,bw,20,"Setup") then
    S.window_mode=MODE_SETUP
    reaper.SetExtState(SCRIPT_NAME,"window_mode",MODE_SETUP,false)
    gfx.init(SCRIPT_NAME,DIMS[MODE_SETUP].w,DIMS[MODE_SETUP].h)
  end
end

-- ============================================================
-- UI — MODE: SETUP — hardware layout
-- ============================================================

local HW_PW=52; local HW_PH=42; local HW_KW=52; local HW_KH=50; local HW_G=6

local function draw_pads(bx,by)
  local track=S.last_track
  for row=1,2 do
    for col=1,4 do
      local pad=row==1 and (col+4) or col
      local x=bx+(col-1)*(HW_PW+HW_G); local y=by+(row-1)*(HW_PH+HW_G)
      local sel=(S.selected_pad==pad); local col_val=BANK_COLORS[pad]
      fill_rect(x,y,HW_PW,HW_PH,col_val,sel and 1.0 or 0.6)
      stroke_rect(x,y,HW_PW,HW_PH,sel and CT or CBR)
      local lbl=(BANK_NAMES[pad] or ""):sub(1,7)
      if S.active_bank==BANK_DRUMS and track then
        local fx,pn=find_fx(track,"Drums")
        if fx then
          local prof=get_profile(pn,BANK_DRUMS,track,fx)
          local pl=prof.drum_pad_labels[pad]
          lbl=(pl~="" and pl or (DRUM_PARTS[pad] and DRUM_PARTS[pad].label or lbl)):sub(1,7)
        end
      end
      draw_strc(x,y+math.floor((HW_PH-11)/2),HW_PW,lbl,{0,0,0},FONT_SMALL)
      if clicked(x,y,HW_PW,HW_PH) then
        S.selected_pad=pad; S.selected_knob=nil; S.dropdown_open=nil
      end
    end
  end
end

local function draw_knobs(bx,by)
  for row=1,2 do
    for col=1,4 do
      local k=(row-1)*4+col
      local x=bx+(col-1)*(HW_KW+HW_G); local y=by+(row-1)*(HW_KH+HW_G)
      local sel=(S.selected_knob==k); local active=S.knob_active[k]
      local cx_=x+math.floor(HW_KW/2); local cy_=y+math.floor(HW_KH/2)-6
      local r=math.min(HW_KW,HW_KH)/2-5
      set_col(active and{0.3,0.3,0.38} or CBTN); gfx.circle(cx_,cy_,r,1,1)
      set_col(sel and CT or CBR); gfx.circle(cx_,cy_,r,0,1)
      if S.midi_learn_active and S.midi_learn_knob==k then
        set_col(CA); gfx.circle(cx_,cy_,r+2,0,1)
      end
      draw_strc(x,y,HW_KW,"K"..k,CD,FONT_SMALL)
      draw_strc(x,cy_+r+2,HW_KW,"CC"..S.knob_ccs[k],CD,FONT_SMALL)
      local dist=math.sqrt((gfx.mouse_x-cx_)^2+(gfx.mouse_y-cy_)^2)
      if gfx.mouse_lb==1 and S.prev_mouse_lb==0 and dist<=r+4 then
        S.selected_knob=k; S.selected_pad=nil; S.dropdown_open=nil; build_param_cache(k)
      end
    end
  end
end

-- ============================================================
-- UI — MODE: SETUP — parameter assignment panel
-- ============================================================

local function draw_param_panel(x,y,w,h)
  local k=S.selected_knob; if not k then return end
  fill_rect(x,y,w,h,CP); stroke_rect(x,y,w,h,CBR)

  -- Title with current bank name
  draw_str(x+6,y+5,"K"..k.." — "..(BANK_NAMES[S.active_bank] or ""),CT,FONT_BOLD)

  -- CC + MIDI Learn
  draw_str(x+6,y+22,"CC: "..S.knob_ccs[k],CT,FONT_SMALL)
  local ll=(S.midi_learn_active and S.midi_learn_knob==k) and "Listening…" or "MIDI Learn"
  local lc=(S.midi_learn_active and S.midi_learn_knob==k) and CA or nil
  if btn(x+52,y+18,82,16,ll,lc) then
    if S.midi_learn_active and S.midi_learn_knob==k then S.midi_learn_active=false
    else S.midi_learn_active=true; S.midi_learn_knob=k end
  end

  -- Friendly name text field
  draw_str(x+6,y+40,"Name:",CD,FONT_SMALL)
  local profile,_,_=knob_context(k)
  local cur_name=(profile and profile.knob_names and profile.knob_names[k]) or ""
  ti_field(x+48,y+37,w-54,16,"kname_"..k,cur_name,function(v)
    if profile then
      profile.knob_names[k]=v
      refresh_knob_labels(S.last_track)
    end
  end)

  -- Parameter dropdown
  draw_str(x+6,y+59,"Param:",CD,FONT_SMALL)
  local cur_param=current_param_display(k)
  local dd_x,dd_y,dd_w,dd_h=x+6,y+72,w-12,18
  if btn(dd_x,dd_y,dd_w,dd_h,cur_param.." \xe2\x96\xbc") then
    S.dropdown_open=(S.dropdown_open==k) and nil or k; S.dropdown_scroll=0
    if S.dropdown_open then build_param_cache(k) end
  end
  if S.dropdown_open==k then
    local maxr=10; local rh=16; local lh=math.min(maxr,#S.param_cache)*rh
    fill_rect(dd_x,dd_y+dd_h,dd_w,lh,CP); stroke_rect(dd_x,dd_y+dd_h,dd_w,lh,CBR)
    local wheel=gfx.mouse_wheel-S.prev_mouse_wheel
    if wheel~=0 and hov(dd_x,dd_y+dd_h,dd_w,lh) then
      S.dropdown_scroll=clamp(S.dropdown_scroll-math.floor(wheel/120),0,math.max(0,#S.param_cache-maxr))
    end
    for i=1,math.min(maxr,#S.param_cache) do
      local item=S.param_cache[i+S.dropdown_scroll]; if not item then break end
      local py=dd_y+dd_h+(i-1)*rh
      if hov(dd_x,py,dd_w,rh) then fill_rect(dd_x,py,dd_w,rh,CBTH) end
      draw_str(dd_x+4,py+2,item.name,CT,FONT_SMALL)
      if clicked(dd_x,py,dd_w,rh) then assign_param(k,item.idx,item.name) end
    end
  end

  -- Min/Max range sliders
  local sy=y+96
  draw_str(x+6,sy,"Min:",CD,FONT_SMALL)
  local rslw=math.floor((w-60)/2)-4
  if profile then
    profile.knob_min[k]=hslider(x+32,sy,rslw,12,profile.knob_min[k] or 0,{0.4,0.5,0.8})
    draw_str(x+36+rslw,sy,"Max:",CD,FONT_SMALL)
    profile.knob_max[k]=hslider(x+62+rslw,sy,rslw,12,profile.knob_max[k] or 1,{0.8,0.5,0.3})
  end

  -- Relative/Absolute toggle
  local sy2=y+114
  if profile then
    local rel=profile.knob_relative[k]
    if btn(x+6,sy2,80,16,rel and "Relative" or "Absolute",rel and CA or nil) then
      profile.knob_relative[k]=not rel
    end
    if rel then draw_str(x+90,sy2+2,"(uses CC delta)",CD,FONT_SMALL) end
  end

  -- Unconfirmed profile warning + Confirm button
  if profile and not profile.confirmed then
    local wy=y+136
    fill_rect(x+6,wy,w-12,16,CWN,0.25)
    draw_str(x+10,wy+2,"Auto-assigned — review & confirm",CWN,FONT_SMALL)
    if btn(x+w-66,wy,60,16,"Confirm",COK) then
      profile.confirmed=true; status("Profile confirmed")
    end
  end

  -- Reset to default button (not for K5 scrub in Bank 1)
  local no_reset=(S.active_bank==BANK_FOLLOW and k==5)
  if not no_reset then
    local ry2=profile and (profile.confirmed and y+136 or y+158) or y+136
    if btn(x+6,ry2,100,18,"Reset to Default",CRST) then
      reset_knob(k,S.last_track)
    end
  end
end

-- ============================================================
-- UI — MODE: SETUP — pad mapping panel
-- ============================================================

local function draw_pad_panel(x,y,w,h)
  local pad=S.selected_pad; if not pad then return end
  fill_rect(x,y,w,h,CP); stroke_rect(x,y,w,h,CBR)
  draw_str(x+6,y+5,"Pad "..pad.." — Mapping",CT,FONT_BOLD)
  local track=S.last_track
  if not track then draw_str(x+6,y+26,"No track selected",CD,FONT_SMALL); return end
  local fx,pname=find_fx(track,"Drums")
  if not fx then draw_str(x+6,y+26,"No drum plugin on track",CD,FONT_SMALL); return end
  local profile=get_profile(pname,BANK_DRUMS,track,fx)

  -- Friendly label field (editable text input)
  draw_str(x+6,y+24,"Label:",CD,FONT_SMALL)
  local lbl=profile.drum_pad_labels[pad] or ""
  ti_field(x+50,y+21,w-56,16,"plabel_"..pad,lbl,function(v)
    profile.drum_pad_labels[pad]=v
  end)

  -- Current note display
  local note=profile.drum_pad_notes[pad]
  local note_str=note>=0 and (note_name(note).." (MIDI "..note..")") or "Unassigned"
  draw_str(x+6,y+42,"Target: "..note_str,CT,FONT_SMALL)

  -- Octave navigation for keyboard picker
  local oct=S.pad_picker_octave
  draw_str(x+6,y+60,"Note:",CD,FONT_SMALL)
  if btn(x+46,y+57,20,16,"<") then S.pad_picker_octave=math.max(0,oct-1) end
  draw_strc(x+66,y+59,40,"Oct "..oct,CT,FONT_SMALL)
  if btn(x+106,y+57,20,16,">") then S.pad_picker_octave=math.min(8,oct+1) end

  -- 12-note keyboard row for current octave
  local base=oct*12
  local bw2=math.floor((w-12)/12)
  for i=0,11 do
    local note_i=base+i; local bx=x+6+i*bw2
    local is_cur=(profile.drum_pad_notes[pad]==note_i)
    if btn(bx,y+78,bw2-1,16,note_name(note_i),is_cur and CA or nil) then
      profile.drum_pad_notes[pad]=note_i
      status("Pad "..pad.." → "..note_name(note_i))
    end
  end

  -- Quick label presets for common drum parts
  draw_str(x+6,y+100,"Quick labels:",CD,FONT_SMALL)
  local pw2=math.floor((w-12)/4)
  for i,dp in ipairs(DRUM_PARTS) do
    local col_=((i-1)%4); local row_=math.floor((i-1)/4)
    if btn(x+6+col_*pw2,y+114+row_*20,pw2-2,16,dp.label:sub(1,10)) then
      profile.drum_pad_labels[pad]=dp.label
    end
  end

  -- Profiles note: shared between Bank 1 and Bank 8
  draw_str(x+6,y+h-14,"Profile shared between Bank 1 and Bank 8",CD,FONT_SMALL)
end

-- ============================================================
-- UI — MODE: SETUP — device config editor
-- Replaces the plugin library panel when S.device_config_open=true.
-- Edits the parsed preset fields in-place; changes take effect on Send.
-- ============================================================

local function draw_device_config(x,y,w,h)
  fill_rect(x,y,w,h,CP); stroke_rect(x,y,w,h,CBR)

  -- Title row + action buttons
  draw_str(x+6,y+5,"MPK Mini Device Config",CT,FONT_BOLD)
  if btn(x+w-56,y+4,52,18,"Close") then S.device_config_open=false end
  local send_ok = S.device_preset_bytes ~= nil
  local send_col = send_ok and nil or {0.25,0.25,0.28}
  if btn(x+w-116,y+4,56,18,"Send",send_col) then
    if send_ok then write_device_preset_to_device(S.device_preset_slot) end
  end

  local f = S.device_config_fields
  if not f then
    draw_strc(x,y+math.floor(h/2),w,"No preset — click Read from Dev in the Presets panel",CD,FONT_NORMAL)
    return
  end

  -- Program name (local label only; SysEx position unconfirmed)
  draw_str(x+6,y+27,"Name:",CD,FONT_SMALL)
  ti_field(x+44,y+24,math.floor(w*0.5),16,"dcfg_name",f.prog_name,function(v) f.prog_name=v end)
  draw_str(x+50+math.floor(w*0.5),y+27,"(local label only)",CD,FONT_SMALL)

  -- Three-column body
  local body_y = y+46
  local col_w  = math.floor((w-8)/3)
  local c1x    = x+4
  local c2x    = x+4+col_w+4
  local c3x    = x+4+(col_w+4)*2
  local lw     = 62   -- label column width
  local fw     = col_w-lw-6  -- control field width
  local RH     = 20   -- row height

  -- Row helper closures
  local function rlbl(cx,cy,lbl) draw_str(cx,cy+3,lbl,CD,FONT_SMALL) end
  local function rnf(cx,cy,lbl,val,mn,mx,step)
    rlbl(cx,cy,lbl)
    return num_field(cx+lw,cy,fw,16,val,mn,mx,step)
  end
  local function rcyc(cx,cy,lbl,idx,vals)
    rlbl(cx,cy,lbl)
    return cyc_field(cx+lw,cy,fw,16,idx,vals)
  end
  local function rtog(cx,cy,lbl,val)
    rlbl(cx,cy,lbl)
    return tog_field(cx+lw,cy,fw,16,val)
  end

  -- ── Column 1: Global ──
  local cy = body_y
  draw_str(c1x,cy,"GLOBAL",CA,FONT_SMALL); cy=cy+RH

  f.pad_ch   = rnf(c1x,cy,"Pad Chan",f.pad_ch,0,15);       cy=cy+RH
  f.key_ch   = rnf(c1x,cy,"Key Chan",f.key_ch,0,15);       cy=cy+RH
  -- Display octave as -4..+4 (raw 0-8) and transpose as -12..+12 (raw 0-24)
  local oct_disp = f.octave - 4
  local new_oct  = rnf(c1x,cy,"Octave",oct_disp,-4,4);     cy=cy+RH
  f.octave = new_oct + 4
  local tr_disp = f.transpose - 12
  local new_tr  = rnf(c1x,cy,"Transpose",tr_disp,-12,12);  cy=cy+RH
  f.transpose = new_tr + 12

  -- ── Column 2: Arpeggiator ──
  local cy2 = body_y
  draw_str(c2x,cy2,"ARPEGGIATOR",CA,FONT_SMALL); cy2=cy2+RH

  f.arp_on    = rtog(c2x,cy2,"On/Off",f.arp_on);                        cy2=cy2+RH
  f.arp_mode  = rcyc(c2x,cy2,"Mode",f.arp_mode,ARP_MODES);              cy2=cy2+RH
  f.arp_div   = rcyc(c2x,cy2,"Division",f.arp_div,ARP_DIVS);            cy2=cy2+RH
  f.arp_clock = rcyc(c2x,cy2,"Clock",f.arp_clock,{"Internal","Ext"});   cy2=cy2+RH
  f.arp_latch = rtog(c2x,cy2,"Latch",f.arp_latch);                      cy2=cy2+RH
  f.arp_swing = rcyc(c2x,cy2,"Swing",f.arp_swing,ARP_SWINGS);           cy2=cy2+RH
  f.arp_taps  = rnf(c2x,cy2,"Taps",f.arp_taps,2,4);                    cy2=cy2+RH
  f.arp_bpm   = rnf(c2x,cy2,"BPM",clamp(math.floor(f.arp_bpm),20,240),20,240,5); cy2=cy2+RH
  -- Arp octave: display 1-4 (raw 0-3)
  local ao_disp = f.arp_octave + 1
  local new_ao  = rnf(c2x,cy2,"Oct Range",ao_disp,1,4); cy2=cy2+RH
  f.arp_octave = new_ao - 1

  -- ── Column 3: Joystick + Knob CCs ──
  local cy3 = body_y
  draw_str(c3x,cy3,"JOYSTICK",CA,FONT_SMALL); cy3=cy3+RH

  f.joy_x_mode = rcyc(c3x,cy3,"X Mode",f.joy_x_mode,JOY_MODES); cy3=cy3+RH
  f.joy_x_cc1  = rnf(c3x,cy3,"X CC1",f.joy_x_cc1,0,127);        cy3=cy3+RH
  f.joy_x_cc2  = rnf(c3x,cy3,"X CC2",f.joy_x_cc2,0,127);        cy3=cy3+RH
  f.joy_y_mode = rcyc(c3x,cy3,"Y Mode",f.joy_y_mode,JOY_MODES); cy3=cy3+RH
  f.joy_y_cc1  = rnf(c3x,cy3,"Y CC1",f.joy_y_cc1,0,127);        cy3=cy3+RH
  f.joy_y_cc2  = rnf(c3x,cy3,"Y CC2",f.joy_y_cc2,0,127);        cy3=cy3+RH

  cy3=cy3+6; set_col(CBR); gfx.line(c3x,cy3,c3x+col_w-6,cy3,0); cy3=cy3+8
  draw_str(c3x,cy3,"KNOB CCs",CA,FONT_SMALL); cy3=cy3+RH

  -- 8 knobs in 2 pairs per row (K1+K5, K2+K6 …) for compact layout
  local hcol = math.floor(col_w/2)
  local kfw  = hcol - 26  -- field width per half-column
  for k = 1, 4 do
    local ky = cy3 + (k-1)*RH
    -- Left half: K1-K4
    draw_str(c3x+2,ky+3,"K"..k,CD,FONT_SMALL)
    f.knob_cc[k]   = num_field(c3x+22,ky,kfw,16,f.knob_cc[k],0,127)
    S.knob_ccs[k]  = f.knob_cc[k]
    -- Right half: K5-K8
    draw_str(c3x+hcol+2,ky+3,"K"..(k+4),CD,FONT_SMALL)
    f.knob_cc[k+4]   = num_field(c3x+hcol+22,ky,kfw,16,f.knob_cc[k+4],0,127)
    S.knob_ccs[k+4]  = f.knob_cc[k+4]
  end
end

-- ============================================================
-- UI — MODE: SETUP — plugin library panel
-- ============================================================

-- All categories list for the library dropdown cycling
local ALL_CATS={"Reverb","Delay","Pan","EQ","Distortion","Modulation","Drums","Unknown"}

local function draw_library(x,y,w,h)
  fill_rect(x,y,w,h,CP); stroke_rect(x,y,w,h,CBR)
  draw_str(x+6,y+5,"Plugin Library  (click row to cycle category)",CT,FONT_BOLD)
  local cx={x+4,x+math.floor(w*0.38),x+math.floor(w*0.60),x+math.floor(w*0.82)}
  local hdr_y=y+20
  draw_str(cx[1],hdr_y,"Plugin Name",CD,FONT_SMALL)
  draw_str(cx[2],hdr_y,"Guessed",CD,FONT_SMALL)
  draw_str(cx[3],hdr_y,"Confirmed",CD,FONT_SMALL)
  draw_str(cx[4],hdr_y,"Status",CD,FONT_SMALL)
  local plugins={}
  for name,e in pairs(S.plugin_library) do plugins[#plugins+1]={name=name,e=e} end
  table.sort(plugins,function(a,b) return a.name<b.name end)
  local rh=16; local list_y=y+34; local vis=math.floor((h-40)/rh)
  local wheel=gfx.mouse_wheel-S.prev_mouse_wheel
  if wheel~=0 and hov(x,y,w,h) then
    S.lib_scroll=clamp(S.lib_scroll-math.floor(wheel/120),0,math.max(0,#plugins-vis))
  end
  for i=1,math.min(vis,#plugins-S.lib_scroll) do
    local p=plugins[i+S.lib_scroll]; local ry=list_y+(i-1)*rh
    if hov(x,ry,w,rh) then fill_rect(x,ry,w,rh,CBTH) end
    draw_str(cx[1],ry+2,p.name:sub(1,26),CT,FONT_SMALL)
    draw_str(cx[2],ry+2,p.e.guessed or "",CD,FONT_SMALL)
    draw_str(cx[3],ry+2,p.e.confirmed or "",CT,FONT_SMALL)
    local sc=p.e.status=="Confirmed" and COK or CWN
    draw_str(cx[4],ry+2,p.e.status or "",sc,FONT_SMALL)
    -- Click cycles through categories
    if clicked(x,ry,w,rh) then
      local cur_idx=1
      for ci,c in ipairs(ALL_CATS) do if c==p.e.confirmed then cur_idx=ci; break end end
      p.e.confirmed=ALL_CATS[(cur_idx%#ALL_CATS)+1]
      p.e.status="Confirmed"
      status("Confirmed: "..p.name.." → "..p.e.confirmed)
      refresh_knob_labels(S.last_track)
    end
  end
end

-- ============================================================
-- UI — MODE: SETUP — preset panel
-- ============================================================

local function draw_presets(x,y,w,h)
  fill_rect(x,y,w,h,CP); stroke_rect(x,y,w,h,CBR)

  -- ── Config presets ──
  draw_str(x+6,y+5,"Presets",CT,FONT_BOLD)
  draw_str(x+6,y+22,S.preset_name,CD,FONT_SMALL)
  local hw=math.floor(w/2)-8
  if btn(x+6,y+40,hw,18,"Save") then save_config() end
  if btn(x+hw+14,y+40,hw,18,"Load\xe2\x80\xa6") then
    local ok,path=reaper.GetUserFileNameForRead("","Load Config","json")
    if ok then load_config(path) end
  end

  -- ── MPK Mini device RAM ──
  local dy=y+66
  -- thin divider
  set_col(CBR); gfx.line(x+6,dy,x+w-6,dy,0); dy=dy+6

  draw_str(x+6,dy,"MPK Mini Device",CT,FONT_BOLD); dy=dy+17

  -- Slot selector 1-4
  draw_str(x+6,dy,"Slot:",CD,FONT_SMALL)
  local sw=math.floor((w-52)/4)
  for s=1,4 do
    local sx=x+34+(s-1)*(sw+2)
    if btn(sx,dy-1,sw,15,tostring(s),S.device_preset_slot==s and CA or nil) then
      S.device_preset_slot=s
    end
  end
  dy=dy+20

  -- Read / Send buttons
  local bw2=math.floor((w-16)/2)
  local read_lbl=S.sysex_read_pending and "Reading…" or "Read from Dev"
  local read_col=S.sysex_read_pending and CA or nil
  if btn(x+6,dy,bw2,18,read_lbl,read_col) then
    if not S.sysex_read_pending then read_device_preset(S.device_preset_slot) end
  end
  local send_ok=S.device_preset_bytes~=nil
  local send_col=send_ok and nil or {0.25,0.25,0.28}
  if btn(x+10+bw2,dy,bw2,18,"Send to Dev",send_col) then
    if send_ok then write_device_preset_to_device(S.device_preset_slot) end
  end
  dy=dy+22

  -- Cache indicator + Edit Config button
  if S.device_preset_bytes then
    draw_str(x+6,dy,"Cached: slot "..S.device_preset_slot,COK,FONT_SMALL)
    dy=dy+18
    if btn(x+6,dy,w-12,18,"Edit Config \xe2\x86\x92",CA) then
      S.device_config_fields = S.device_config_fields or parse_preset_fields(S.device_preset_bytes)
      S.device_config_open   = true
    end
  else
    draw_str(x+6,dy,"No cache — Read first",CD,FONT_SMALL)
  end
end

-- ============================================================
-- UI — MODE: SETUP — main layout
-- ============================================================

local function draw_setup()
  fill_rect(0,0,gfx.w,gfx.h,CB)
  local bc=BANK_COLORS[S.active_bank]; fill_rect(0,0,gfx.w,3,bc)
  draw_str(8,7,SCRIPT_NAME.." — Setup",CT,FONT_BOLD)
  draw_str(8,24,"Track: "..S.last_track_name.."   Bank: "..(BANK_NAMES[S.active_bank] or ""),CD,FONT_SMALL)

  local hw_x,hw_y=8,44
  local pads_total_w=4*(HW_PW+HW_G)-HW_G
  draw_pads(hw_x,hw_y)
  draw_knobs(hw_x+pads_total_w+24,hw_y)

  local panel_x=hw_x+pads_total_w+24+4*(HW_KW+HW_G)-HW_G+14
  local panel_w=gfx.w-panel_x-6
  local panel_h=math.max(180,2*(HW_PH+HW_G)+10)

  if S.selected_knob then draw_param_panel(panel_x,hw_y,panel_w,panel_h)
  elseif S.selected_pad then draw_pad_panel(panel_x,hw_y,panel_w,panel_h)
  else
    fill_rect(panel_x,hw_y,panel_w,panel_h,CP)
    stroke_rect(panel_x,hw_y,panel_w,panel_h,CBR)
    draw_strc(panel_x,hw_y+math.floor(panel_h/2)-6,panel_w,"Select a knob or pad",CD,FONT_NORMAL)
  end

  local lib_y=hw_y+panel_h+10; local lib_h=gfx.h-lib_y-34; local pre_w=160
  if S.device_config_open then
    draw_device_config(8,lib_y,gfx.w-pre_w-14,lib_h)
  else
    draw_library(8,lib_y,gfx.w-pre_w-14,lib_h)
  end
  draw_presets(gfx.w-pre_w-6,lib_y,pre_w,lib_h)

  if S.status_msg~="" and (reaper.time_precise()-S.status_time)<4.0 then
    draw_str(8,gfx.h-30,S.status_msg,CD,FONT_SMALL)
  end
  local bw=math.floor((gfx.w-16)/2); local by=gfx.h-26
  if btn(6,by,bw,20,"Mini") then
    S.window_mode=MODE_MINI
    reaper.SetExtState(SCRIPT_NAME,"window_mode",MODE_MINI,false)
    gfx.init(SCRIPT_NAME,DIMS[MODE_MINI].w,DIMS[MODE_MINI].h)
  end
  if btn(10+bw,by,bw,20,"Dashboard") then
    S.window_mode=MODE_DASHBOARD
    reaper.SetExtState(SCRIPT_NAME,"window_mode",MODE_DASHBOARD,false)
    gfx.init(SCRIPT_NAME,DIMS[MODE_DASHBOARD].w,DIMS[MODE_DASHBOARD].h)
  end
end

-- ============================================================
-- UI — MASTER DRAW
-- ============================================================

-- Warning banner shown when the JSFX bridge is not yet ready.
local function draw_midi_unavailable_banner()
  if S.jsfx_ready then return end
  local bh = 18
  fill_rect(0, gfx.h-bh, gfx.w, bh, {0.55,0.20,0.10})
  draw_strc(0, gfx.h-bh+3, gfx.w,
    "MIDI bridge not ready — check that MPKMiniMapper Input track exists",
    CT, FONT_SMALL)
end

local function draw_ui()
  gfx.setfont(FONT_BOLD,  "Arial",13,string.byte("b"))
  gfx.setfont(FONT_NORMAL,"Arial",12,0)
  gfx.setfont(FONT_SMALL, "Arial",11,0)
  if S.window_mode==MODE_MINI then draw_mini()
  elseif S.window_mode==MODE_DASHBOARD then draw_dashboard()
  else draw_setup() end
  draw_midi_unavailable_banner()
  S.prev_mouse_lb=gfx.mouse_lb; S.prev_mouse_wheel=gfx.mouse_wheel
  gfx.update()
end

-- ============================================================
-- MAIN DEFERRED LOOP
-- ============================================================

local function main_loop()
  local ch=gfx.getchar()

  -- Text input widget consumes keypresses first
  local consumed=ti_handle(ch)

  if not consumed then
    if ch==-1 then S.window_open=false end
    if ch==27 then gfx.quit(); S.window_open=false end
  end
  if S.window_open and gfx.w==0 then S.window_open=false end

  check_project_change()
  local track=update_track()

  -- Show first-time drum plugin prompt
  if S.pending_drum_prompt then
    status("New drum plugin '"..S.pending_drum_prompt.."' — map pads in Setup → Pad panel")
    S.pending_drum_prompt=nil
  end

  poll_midi_gmem(track)

  if S.window_open then draw_ui() end

  reaper.defer(main_loop)
end

-- ============================================================
-- ENTRY POINT
-- ============================================================

local function init()
  -- Restore last window mode from REAPER's extended state (survives script restarts)
  local saved_mode=reaper.GetExtState(SCRIPT_NAME,"window_mode")
  if saved_mode and saved_mode~="" then S.window_mode=saved_mode end

  -- First-launch detection: prompt the user to verify CC assignments
  if reaper.GetExtState(SCRIPT_NAME,"ever_launched")~="1" then
    reaper.SetExtState(SCRIPT_NAME,"ever_launched","1",true)
    status("First launch! Open Setup and use MIDI Learn to verify CC 70-77 assignments.")
  end

  init_midi()

  local proj_dir=reaper.GetProjectPathEx()
  if proj_dir and proj_dir~="" then
    S.last_proj_path=proj_dir; load_config()
  end

  local d=DIMS[S.window_mode] or DIMS[MODE_MINI]
  gfx.init(SCRIPT_NAME,d.w,d.h,0,120,120)
  S.window_open=true
  S.prev_mouse_wheel=gfx.mouse_wheel

  local track=reaper.GetSelectedTrack(0,0)
  S.last_track=track
  if track then local _,n=reaper.GetTrackName(track,""); S.last_track_name=n end
  refresh_knob_labels(track)

  reaper.defer(main_loop)
end

init()
