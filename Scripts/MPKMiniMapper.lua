-- ============================================================
-- MPKMiniMapper v1.2
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
local VERSION     = "1.2"

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

local BANK_TO_CAT = {
  [BANK_REVERB]="Reverb", [BANK_DELAY]="Delay",  [BANK_PAN]="Pan",
  [BANK_EQ]="EQ",         [BANK_DIST]="Distortion", [BANK_MOD]="Modulation",
  [BANK_DRUMS]="Drums",
}

local DEFAULT_KNOB_CCS = {70,71,72,73,74,75,76,77}

-- ============================================================
-- JSFX BRIDGE SOURCE (embedded — written to disk on first run)
-- Communicates via JSFX sliders (TrackFX_GetParam / SetParamNormalized)
-- so no gmem dependency.  26 sliders total:
--   param 0  (slider1)      = write pointer 0-7
--   param 1  (slider2)      = drum-intercept flag (Lua writes, JSFX reads)
--   params 2-25 (sliders 3-26) = 8 event slots × 3 bytes (msg1, msg2, msg3)
-- ============================================================

local JSFX_SRC = [[
desc:MPKMiniMapper_MIDI
// Auto-generated by MPKMiniMapper.lua — do not edit manually.
// Slider ring buffer (params 0-25): regular MIDI events → Lua polling.
// gmem SysEx bridge: TX=[10000]=len,[10001..10120]=bytes
//                    RX=[10200]=len,[10201..10320]=bytes

slider1:0<0,7,1>-WP
slider2:0<0,1,1>-DrumFlag
slider3:0<0,255,1>-E0B1
slider4:0<0,255,1>-E0B2
slider5:0<0,255,1>-E0B3
slider6:0<0,255,1>-E1B1
slider7:0<0,255,1>-E1B2
slider8:0<0,255,1>-E1B3
slider9:0<0,255,1>-E2B1
slider10:0<0,255,1>-E2B2
slider11:0<0,255,1>-E2B3
slider12:0<0,255,1>-E3B1
slider13:0<0,255,1>-E3B2
slider14:0<0,255,1>-E3B3
slider15:0<0,255,1>-E4B1
slider16:0<0,255,1>-E4B2
slider17:0<0,255,1>-E4B3
slider18:0<0,255,1>-E5B1
slider19:0<0,255,1>-E5B2
slider20:0<0,255,1>-E5B3
slider21:0<0,255,1>-E6B1
slider22:0<0,255,1>-E6B2
slider23:0<0,255,1>-E6B3
slider24:0<0,255,1>-E7B1
slider25:0<0,255,1>-E7B2
slider26:0<0,255,1>-E7B3

@block
while(midirecv(offset,msg1,msg2,msg3))(
  wp=slider1;
  wp==0 ? (slider3=msg1;  slider4=msg2;  slider5=msg3)  :
  wp==1 ? (slider6=msg1;  slider7=msg2;  slider8=msg3)  :
  wp==2 ? (slider9=msg1;  slider10=msg2; slider11=msg3) :
  wp==3 ? (slider12=msg1; slider13=msg2; slider14=msg3) :
  wp==4 ? (slider15=msg1; slider16=msg2; slider17=msg3) :
  wp==5 ? (slider18=msg1; slider19=msg2; slider20=msg3) :
  wp==6 ? (slider21=msg1; slider22=msg2; slider23=msg3) :
          (slider24=msg1; slider25=msg2; slider26=msg3);
  wp=(wp+1)%8; slider1=wp;
  (msg1&240)==192 ? 0 :
  ((msg1&240)==144||(msg1&240)==128)&&slider2 ? 0 :
  midisend(offset,msg1,msg2,msg3);
);
]]

-- Dedicated SysEx JSFX: sits at input-chain index 0, before the slider JSFX.
-- Uses midirecv_buf to capture SysEx; forwards regular MIDI downstream via midisend.
-- gmem layout (all addresses decimal):
--   TX: [10000]=length (0=idle), [10001..10120]=bytes  (Lua→device)
--   RX: [10200]=length (0=idle), [10201..10320]=bytes  (device→Lua)
local SYSEX_JSFX_SRC = [[
desc:MPKMiniMapper_SysEx
options:gmem=MPKMiniMapper
slider1:0<0,1,1>-Ready

@init
SBASE=10000; tbuf=2000;

@block
len=midirecv_buf(offset,tbuf,200);
while(len)(
  tbuf[0]==0xF0?(
    gmem[SBASE+200]==0?(
      i=0;while(i<len)(gmem[SBASE+201+i]=tbuf[i];i+=1;);
      gmem[SBASE+200]=len;
    );
  ):len>=3?(
    midisend(offset,tbuf[0],tbuf[1],tbuf[2]);
  );
  len=midirecv_buf(offset,tbuf,200);
);
gmem[SBASE+0]>0?(
  slen=gmem[SBASE+0];
  i=0;while(i<slen)(tbuf[i]=gmem[SBASE+1+i];i+=1;);
  midisend_buf(0,tbuf,slen);
  gmem[SBASE+0]=0;
);
slider1=1;
]]

local GMEM_SYSEX_TX     = 10000   -- TX slot: [10000]=len, [10001..10120]=bytes
local GMEM_SYSEX_TX_BUF = 10001
local GMEM_SYSEX_RX     = 10200   -- RX slot: [10200]=len, [10201..10320]=bytes
local GMEM_SYSEX_RX_BUF = 10201
local SYSEX_MAX_LEN     = 115

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
  Instrument = {"Kontakt","Spire","Serum","Vital","Massive","Omnisphere","Sylenth1",
                "Pigments","Phase Plant","HALion","Play","UVI","Surge","Helm"},
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
  Instrument={
    {"Volume","Level","Master","Output"},
    {"Cutoff","Filter Cutoff","Filter Freq"},
    {"Resonance","Filter Res","Reso"},
    {"Attack","Env A","Amp Attack"},
    {"Decay","Env D","Amp Decay"},
    {"Sustain","Env S","Amp Sustain"},
    {"Release","Env R","Amp Release"},
    {"Velocity","Vel Sens","Vel Depth"},
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
  [MODE_MINI]     ={w=387,h=270},
  [MODE_DASHBOARD]={w=640,h=360},
  [MODE_SETUP]    ={w=940,h=740},
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
  jsfx_ready        = false, -- true once JSFX helper is loaded and running
  jsfx_idx          = -1,    -- local input-chain index of the JSFX (for TrackFX_GetParam)
  jsfx_rp           = 0,     -- Lua-side read pointer into the slider ring buffer (0-7)
  jsfx_sysex_idx    = -1,    -- input-chain index of the SysEx JSFX (always 0)
  pad_presets        = {},    -- [1..8] = {bytes={117 bytes}, knob_ccs={8}} or nil
  device_preset_slot = 1,    -- which pad slot is selected in the Device RAM UI (1-8)
  device_read_slot   = 1,    -- which device flash slot to GET when reading (1-4)
  sysex_read_pending = false, -- true while waiting for device response
  recsrc_target     = 0x1000, -- expected I_RECSRC value; re-applied if REAPER resets it

  knob_ccs          = {table.unpack(DEFAULT_KNOB_CCS)},
  scrub_sensitivity = 0.5,
  scrub_relative    = false,  -- true = 2's-complement relative mode (MPK knob must match)

  last_track        = nil,
  last_track_name   = "No track selected",
  last_proj_path    = "",

  knob_labels       = {"","","","","","","",""},
  knob_active       = {false,false,false,false,false,false,false,false},

  last_cc_raw       = {64,64,64,64,64,64,64,64},  -- default to center for scrub
  knob_touched_time = {0,0,0,0,0,0,0,0},          -- time_precise() of last CC for each knob
  pending_mode      = nil,    -- set in button handlers; applied at start of next loop tick

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

  -- Maps original_note -> remapped_note for currently held drum pads.
  -- Ensures note-off always cancels the correct (remapped) pitch even if
  -- the bank changes between note-on and note-off.
  active_notes      = {},

  dbg_last_cc       = 0,   -- last CC number seen (for debug bar)
  dbg_last_val      = 0,   -- last CC value seen
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
    scrub_relative=S.scrub_relative,
    plugin_library=S.plugin_library, plugin_profiles=S.plugin_profiles,
    device_preset_slot=S.device_preset_slot, device_read_slot=S.device_read_slot,
    pad_presets=S.pad_presets,
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
  if data.scrub_relative ~= nil then S.scrub_relative  = data.scrub_relative    end
  if data.plugin_library     then S.plugin_library      = data.plugin_library    end
  if data.plugin_profiles    then S.plugin_profiles     = data.plugin_profiles   end
  if type(data.knob_ccs)=="table" then
    for i=1,8 do if data.knob_ccs[i] then S.knob_ccs[i]=data.knob_ccs[i] end end
  end
  if data.device_preset_slot then S.device_preset_slot = data.device_preset_slot end
  if data.device_read_slot   then S.device_read_slot   = data.device_read_slot   end
  if type(data.pad_presets)=="table" then
    for i=1,8 do
      local p=data.pad_presets[i]
      if type(p)=="table" and type(p.bytes)=="table" and type(p.knob_ccs)=="table" then
        S.pad_presets[i]=p
      end
    end
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
    if S.scrub_relative then
      -- Relative / infinite mode: hardware knob must be set to relative (increment) mode.
      -- CC values are 2's-complement signed increments centred on 64:
      --   1..63  → right (+1..+63),  65..127 → left (-63..-1),  64/0 → no movement.
      local signed = cc_val <= 63 and cc_val or (cc_val - 128)
      if signed ~= 0 then
        local delta = signed * S.scrub_sensitivity * 0.5
        reaper.SetEditCurPos(math.max(0,reaper.GetCursorPosition()+delta),true,true)
      end
    else
      -- Absolute-delta mode: compute increment from previous CC value.
      -- Ignores jumps > 24 steps on first touch (physical knob far from stored position).
      local prev=S.last_cc_raw[5]
      local raw_delta=cc_val-prev
      if math.abs(raw_delta) < 24 then
        local delta=raw_delta*S.scrub_sensitivity*0.5
        reaper.SetEditCurPos(math.max(0,reaper.GetCursorPosition()+delta),true,true)
      end
    end
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

local function find_mpk_mini_output()
  for i=0,reaper.GetNumMIDIOutputs()-1 do
    local _,name=reaper.GetMIDIOutputName(i,"")
    if icontains(name,"mpk mini") or icontains(name,"mpkmini") then return i end
  end
  return -1
end

-- Write the embedded JSFX to %APPDATA%\REAPER\Effects\ (always overwrite so the
-- latest version with the correct options:gmem declaration is always on disk).
local function write_jsfx()
  local path=reaper.GetResourcePath().."\\Effects\\MPKMiniMapper_MIDI.jsfx"
  local f=io.open(path,"w")
  if not f then
    status("Cannot write JSFX to: "..path); return false
  end
  f:write(JSFX_SRC); f:close(); return true
end

local function write_sysex_jsfx()
  local path=reaper.GetResourcePath().."\\Effects\\MPKMiniMapper_SysEx.jsfx"
  local f=io.open(path,"w")
  if not f then status("Cannot write SysEx JSFX to: "..path); return false end
  f:write(SYSEX_JSFX_SRC); f:close(); return true
end

-- Apply MIDI routing, arm, and monitor to a track.
-- Extracted to module scope so it can be re-applied after JSFX setup,
-- which is known to reset I_RECSRC in some REAPER builds.
-- I_RECSRC bit layout per REAPER SDK:
--   bit 12 (0x1000 = 4096) = MIDI record source flag
--   bits 5-9  = (device_index + 1)  where 0 = all devices
--   bits 0-4  = channel (0 = all channels)
local function apply_midi_routing(t)
  local dev=find_mpk_mini()
  local recsrc=0x1000                         -- all MIDI devices, all channels
  if dev>=0 then recsrc=0x1000|((dev+1)<<5) end
  S.recsrc_target=recsrc
  reaper.SetMediaTrackInfo_Value(t,"I_RECSRC",recsrc)
  reaper.SetMediaTrackInfo_Value(t,"I_RECARM",1)
  reaper.SetMediaTrackInfo_Value(t,"I_RECMON",1)
  -- Attempt to route MIDI output back to device (needed for SysEx TX)
  local out=find_mpk_mini_output()
  if out>=0 then
    pcall(function() reaper.SetMediaTrackInfo_Value(t,"I_MIDI_OUTPUT",out) end)
  end
end

-- Find or create the dedicated MIDI input track.
-- Returns true when the track is ready in S.midi_track.
local function ensure_midi_track()
  -- Re-validate existing reference
  if S.midi_track and reaper.ValidatePtr(S.midi_track,"MediaTrack*") then
    apply_midi_routing(S.midi_track); return true
  end
  -- Search for an existing track with our name and reconfigure it
  for i=0,reaper.CountTracks(0)-1 do
    local t=reaper.GetTrack(0,i)
    local _,n=reaper.GetTrackName(t,"")
    if n==MIDI_TRACK_NAME then S.midi_track=t; apply_midi_routing(t); return true end
  end
  -- Create a new track at the end of the track list
  reaper.Undo_BeginBlock()
  local idx=reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(idx,true)
  local t=reaper.GetTrack(0,idx)
  reaper.GetSetMediaTrackInfo_String(t,"P_NAME",MIDI_TRACK_NAME,true)
  reaper.SetMediaTrackInfo_Value(t,"B_MUTE",1)
  reaper.SetMediaTrackInfo_Value(t,"I_HEIGHTOVERRIDE",18)
  apply_midi_routing(t)
  reaper.Undo_EndBlock("MPKMiniMapper: create MIDI input track",-1)
  S.midi_track=t; return true
end

-- Manage BOTH JSFX and enforce order: SysEx=0, Slider=1.
local function ensure_jsfx_on_track()
  if not S.midi_track then return false end
  if not reaper.ValidatePtr(S.midi_track,"MediaTrack*") then return false end

  -- Scan the input FX chain and note positions of both JSFX
  local sx_idx,sb_idx=-1,-1
  local i=0
  while true do
    local ok,name=reaper.TrackFX_GetFXName(S.midi_track,0x1000000|i,"")
    if not ok then break end
    if name:find("MPKMiniMapper_SysEx",1,true) then sx_idx=i end
    if name:find("MPKMiniMapper_MIDI",1,true)  then sb_idx=i end
    i=i+1
  end

  -- Happy path: both present in correct order with correct param count
  if sx_idx==0 and sb_idx==1 then
    local n=reaper.TrackFX_GetNumParams(S.midi_track,0x1000000|1)
    if n>=26 then S.jsfx_sysex_idx=0; S.jsfx_idx=1; return true end
  end

  -- Remove whichever exist (highest index first to avoid shifting)
  local del={}
  if sx_idx>=0 then del[#del+1]=sx_idx end
  if sb_idx>=0 then del[#del+1]=sb_idx end
  table.sort(del,function(a,b) return a>b end)
  for _,idx in ipairs(del) do
    reaper.TrackFX_Delete(S.midi_track,0x1000000|idx)
  end

  -- Re-add in correct order: SysEx first, then Slider
  reaper.TrackFX_AddByName(S.midi_track,"MPKMiniMapper_SysEx",true,-1)
  reaper.TrackFX_AddByName(S.midi_track,"MPKMiniMapper_MIDI",true,-1)

  -- Scan to confirm positions
  sx_idx=-1; sb_idx=-1; i=0
  while true do
    local ok,name=reaper.TrackFX_GetFXName(S.midi_track,0x1000000|i,"")
    if not ok then break end
    if name:find("MPKMiniMapper_SysEx",1,true) then sx_idx=i end
    if name:find("MPKMiniMapper_MIDI",1,true)  then sb_idx=i end
    i=i+1
  end
  if sx_idx<0 or sb_idx<0 then return false end
  S.jsfx_sysex_idx=sx_idx; S.jsfx_idx=sb_idx
  return true
end

-- Full MIDI bridge initialisation called from init()
local function init_midi()
  if not write_jsfx() then return end
  write_sysex_jsfx()  -- write even if it fails; ensure_jsfx_on_track will skip if absent
  if not ensure_midi_track() then
    status("Could not create MIDI input track"); return
  end
  if not ensure_jsfx_on_track() then
    status("Could not add JSFX — verify REAPER Effects folder is writable"); return
  end
  -- Re-apply routing: adding a plugin to the input FX chain resets I_RECSRC in some REAPER builds
  apply_midi_routing(S.midi_track)
  reaper.gmem_attach("MPKMiniMapper")  -- connect Lua to the SysEx JSFX gmem namespace
  S.jsfx_rp=0  -- reset ring buffer read pointer
  S.jsfx_ready=true
  status("MIDI bridge ready — route MPK Mini to '"..MIDI_TRACK_NAME.."' track")
end

-- ============================================================
-- SYSEX — SEND / RECEIVE / PARSE
-- Talks to MPK Mini MK3 onboard RAM via the SysEx JSFX bridge.
-- Protocol: docs/MPK_MINI_MK3_SYSEX_PROTOCOL.md
-- ============================================================

local function send_sysex(bytes)
  if not S.jsfx_ready then return false end
  local n=#bytes
  if n>SYSEX_MAX_LEN then return false end
  if (reaper.gmem_read(GMEM_SYSEX_TX) or 0)~=0 then return false end  -- TX slot busy
  for i=1,n do reaper.gmem_write(GMEM_SYSEX_TX_BUF+(i-1),bytes[i]) end
  reaper.gmem_write(GMEM_SYSEX_TX,n)
  return true
end

-- Requests device flash slot `dev_slot` (1-4); response is stored into pad slot S.device_preset_slot.
local function read_device_preset(dev_slot)
  dev_slot=math.max(1,math.min(4,dev_slot or S.device_read_slot))
  S.sysex_read_pending=true
  local msg={0xF0,0x47,0x00,0x49,0x63,0x00,0x01,dev_slot,0xF7}
  if send_sysex(msg) then
    status("Reading device slot "..dev_slot.." \xe2\x86\x92 pad "..S.device_preset_slot.."…")
  else
    status("Read failed: bridge not ready"); S.sysex_read_pending=false
  end
end

-- Parse the 117-byte device response and update S.knob_ccs.
-- Wire layout (1-based Lua): bytes[1]=F0 [2]=47 [3]=00 [4]=49 [5]=61 [6]=00 [7]=68
--   [8]=preset_num [9..114]=106-byte payload [115]=F7
-- Knob CC at payload offset 84 → bytes[9+84+(k-1)*3] for knob k
local function apply_preset_bytes(bytes)
  local new_ccs={}
  for k=1,8 do
    local idx=9+84+(k-1)*3
    local cc=bytes[idx]
    new_ccs[k]=(cc and cc>=0 and cc<=127) and cc or S.knob_ccs[k]
  end
  -- Store full bytes + parsed CCs into the selected pad slot
  S.pad_presets[S.device_preset_slot]={bytes=bytes, knob_ccs=new_ccs}
  -- If this pad is the active bank, also apply CCs live
  if S.device_preset_slot==S.active_bank then
    S.knob_ccs=new_ccs
    refresh_knob_labels(S.last_track)
  end
  status("Pad "..S.device_preset_slot.." captured — CCs: "..table.concat(new_ccs,","))
end

local function poll_sysex_rx()
  if not S.jsfx_ready then return end
  local len=math.floor(reaper.gmem_read(GMEM_SYSEX_RX) or 0)
  if len==0 then return end
  local bytes={}
  for i=0,len-1 do bytes[i+1]=math.floor(reaper.gmem_read(GMEM_SYSEX_RX_BUF+i) or 0) end
  reaper.gmem_write(GMEM_SYSEX_RX,0)  -- free slot
  if bytes[1]==0xF0 and bytes[2]==0x47 and bytes[5]==0x61 then
    S.sysex_read_pending=false
    apply_preset_bytes(bytes)
  end
end

local function write_device_preset(slot)
  slot=math.max(1,math.min(8,slot or S.device_preset_slot))
  local pad=S.pad_presets[slot]
  if not pad or not pad.bytes then
    status("Capture pad "..slot.." first (click Read)"); return
  end
  local bytes={}
  for i,b in ipairs(pad.bytes) do bytes[i]=b end
  bytes[8]=1  -- always apply to device slot 1 / working RAM
  for k=1,8 do
    local idx=9+84+(k-1)*3
    if idx<=#bytes-1 then bytes[idx]=pad.knob_ccs[k] end
  end
  if send_sysex(bytes) then
    status("Pad "..slot.." preset sent to device RAM")
  else
    status("Send failed: bridge not ready")
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
      -- Auto-push pad preset to device RAM when pad is selected
      if S.pad_presets[bank] then write_device_preset(bank) end
    end
    return
  end

  -- Control Change → knob routing
  if sb==0xB0 then
    local cc=msg2; local val=msg3
    S.dbg_last_cc=cc; S.dbg_last_val=val  -- debug visibility
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
        -- In relative mode K5 never updates last_cc_raw — each CC is a signed increment,
        -- not a new absolute position, so the stored value must stay at 64.
        if not (k==5 and S.scrub_relative) then S.last_cc_raw[k]=val end
        S.knob_touched_time[k]=reaper.time_precise()
        break
      end
    end
    return
  end

  -- Note On → drum pad remapping for Bank 8 AND Bank 1 when drum plugin present.
  -- Record the remapped pitch so the note-off can cancel the correct note even
  -- if the active bank changes while the pad is held.
  if sb==0x90 and msg3>0 then
    local needs_remap=(S.active_bank==BANK_DRUMS) or
        (S.active_bank==BANK_FOLLOW and find_fx(track,"Drums")~=nil)
    if needs_remap then
      local remapped=remap_drum_note(msg2,track)
      S.active_notes[msg2]=remapped
      reaper.StuffMIDIMessage(0,0x90|ch,remapped,msg3)
    else
      S.active_notes[msg2]=nil
      reaper.StuffMIDIMessage(0,msg1,msg2,msg3)
    end
    return
  end

  -- Note Off → cancel the exact pitch that was started on note-on.
  -- Using active_notes prevents stuck notes when the bank changes mid-hold.
  if sb==0x80 or (sb==0x90 and msg3==0) then
    local remapped=S.active_notes[msg2]
    if remapped then
      S.active_notes[msg2]=nil
      reaper.StuffMIDIMessage(0,0x80|ch,remapped,0)
    else
      reaper.StuffMIDIMessage(0,msg1,msg2,msg3)
    end
    return
  end

  -- All other messages pass through unchanged
  reaper.StuffMIDIMessage(0,msg1,msg2,msg3)
end

-- Poll MIDI events from the JSFX slider ring buffer.
-- param 0 = WP (write pointer 0-7, written by JSFX)
-- param 1 = DrumFlag (written by Lua, read by JSFX to intercept notes)
-- params 2-25 = 8 event slots × 3 bytes (msg1, msg2, msg3)
local function poll_midi_slider(track)
  if not S.jsfx_ready then return end
  if not S.midi_track or not reaper.ValidatePtr(S.midi_track,"MediaTrack*") then
    S.jsfx_ready=false; init_midi(); return
  end
  local fx=0x1000000|S.jsfx_idx
  -- Re-apply MIDI routing if REAPER has reset it (can happen after project load or FX changes)
  local cur_recsrc=reaper.GetMediaTrackInfo_Value(S.midi_track,"I_RECSRC")
  if cur_recsrc~=S.recsrc_target then apply_midi_routing(S.midi_track) end
  -- Tell JSFX whether to intercept note-on/off for drum remapping
  local drum_mode=((S.active_bank==BANK_DRUMS) or
    (S.active_bank==BANK_FOLLOW and track and find_fx(track,"Drums")~=nil)) and 1 or 0
  reaper.TrackFX_SetParamNormalized(S.midi_track,fx,1,drum_mode)
  -- Read JSFX write pointer and drain unread events
  local wp_raw=reaper.TrackFX_GetParam(S.midi_track,fx,0)
  local wp=math.floor(wp_raw or 0)
  local rp=S.jsfx_rp
  local iter=0
  while rp~=wp and iter<8 do
    local base=2+rp*3
    local m1=math.floor(reaper.TrackFX_GetParam(S.midi_track,fx,base)   or 0)
    local m2=math.floor(reaper.TrackFX_GetParam(S.midi_track,fx,base+1) or 0)
    local m3=math.floor(reaper.TrackFX_GetParam(S.midi_track,fx,base+2) or 0)
    process_midi_event(m1,m2,m3,track)
    rp=(rp+1)%8; iter=iter+1
  end
  S.jsfx_rp=rp
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
  return hov(x,y,w,h) and gfx.mouse_cap&1==1 and S.prev_mouse_lb==0
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
  gfx.setfont(FONT_SMALL)
  draw_strc(x,y+math.floor((h-gfx.texth)/2),w,lbl,CT,FONT_SMALL)
  return clicked(x,y,w,h)
end

-- Horizontal slider: returns new value if dragged, else val
local function hslider(x,y,w,h,val,col)
  fill_rect(x,y,w,h,CP); stroke_rect(x,y,w,h,CBR)
  fill_rect(x,y,math.floor(val*w),h,col or CA)
  if gfx.mouse_cap&1==1 and hov(x,y-4,w,h+8) then
    return clamp((gfx.mouse_x-x)/w,0,1)
  end
  return val
end

-- Text field widget: click to begin editing, Enter/Esc to finish
local function ti_field(x,y,w,h,id,cur_val,on_done)
  local is_me=TI.active and TI.id==id
  fill_rect(x,y,w,h,is_me and{0.20,0.20,0.30} or CBTN)
  stroke_rect(x,y,w,h,is_me and CA or CBR)
  local blink=math.floor(reaper.time_precise()*2)%2==0
  local txt=is_me and (TI.value..(blink and "|" or "")) or (cur_val~="" and cur_val or "…")
  gfx.setfont(FONT_SMALL)
  draw_str(x+4,y+math.floor((h-gfx.texth)/2),txt,CT,FONT_SMALL)
  if clicked(x,y,w,h) then
    if is_me then TI.active=false else ti_begin(id,cur_val,on_done) end
  end
end

-- ============================================================
-- UI HELPERS — VALUE READOUT & TOOLTIP
-- ============================================================

-- Returns a short human-readable string for the current value of knob k,
-- or nil if no meaningful value is available (inactive, scrub, etc.).
local function get_knob_value_str(k)
  local track=S.last_track; if not track then return nil end
  if not S.knob_active[k] then return nil end
  local bank=S.active_bank
  if bank==BANK_FOLLOW then
    if k==1 then
      local vol=reaper.GetMediaTrackInfo_Value(track,"D_VOL")
      local db=vol>0 and (20*math.log(vol)/math.log(10)) or -math.huge
      return string.format("%.1f dB",math.max(-60,db))
    elseif k==2 then
      local pan=reaper.GetMediaTrackInfo_Value(track,"D_PAN")
      if math.abs(pan)<0.01 then return "Center"
      elseif pan<0 then return string.format("L%.0f%%",math.abs(pan)*100)
      else return string.format("R%.0f%%",pan*100) end
    elseif k==5 then return nil  -- scrub: no static value
    elseif k==6 then
      local fx=find_fx(track,"Reverb"); if not fx then return nil end
      local n=reaper.TrackFX_GetNumParams(track,fx)
      for p=0,n-1 do
        local _,pn=reaper.TrackFX_GetParamName(track,fx,p,"")
        if icontains(pn,"wet") or icontains(pn,"mix") then
          return string.format("%.0f%%",reaper.TrackFX_GetParamNormalized(track,fx,p)*100) end
      end
    elseif k==7 then
      local fx=find_fx(track,"Delay"); if not fx then return nil end
      local n=reaper.TrackFX_GetNumParams(track,fx)
      for p=0,n-1 do
        local _,pn=reaper.TrackFX_GetParamName(track,fx,p,"")
        if icontains(pn,"wet") or icontains(pn,"mix") then
          return string.format("%.0f%%",reaper.TrackFX_GetParamNormalized(track,fx,p)*100) end
      end
    end
    return nil
  elseif bank==BANK_DRUMS then
    local fx,pn=find_fx(track,"Drums"); if not fx then return nil end
    local profile=get_profile(pn,BANK_DRUMS,track,fx)
    local pi=profile.knob_params[k]; if not pi or pi<0 then return nil end
    return string.format("%.0f%%",reaper.TrackFX_GetParamNormalized(track,fx,pi)*100)
  else
    local cat=BANK_TO_CAT[bank]; if not cat then return nil end
    local fx,pn=find_fx(track,cat); if not fx then return nil end
    local profile=get_profile(pn,bank,track,fx)
    local pi=profile.knob_params[k]; if not pi or pi<0 then return nil end
    return string.format("%.0f%%",reaper.TrackFX_GetParamNormalized(track,fx,pi)*100)
  end
end

-- Draws a small floating tooltip box near the mouse cursor.
local function draw_tooltip(txt, mx, my)
  gfx.setfont(FONT_SMALL)
  local tw,_=gfx.measurestr(txt)
  local pad=4; local bw=tw+pad*2; local bh=gfx.texth+pad*2
  local tx=math.min(mx+14,gfx.w-bw-2)
  local ty=math.min(my+14,gfx.h-bh-2)
  fill_rect(tx,ty,bw,bh,{0.12,0.12,0.18})
  stroke_rect(tx,ty,bw,bh,CBR)
  draw_str(tx+pad,ty+pad,txt,CT,FONT_SMALL)
end

-- ============================================================
-- UI — MODE: MINI
-- ============================================================

local function draw_mini()
  fill_rect(0,0,gfx.w,gfx.h,CB)
  local bc=BANK_COLORS[S.active_bank]
  fill_rect(0,0,gfx.w,5,bc)
  -- Mini uses smaller fonts; set them each frame so draw_ui's larger sizes don't bleed in
  gfx.setfont(FONT_BOLD,"Arial",18,string.byte("b"))
  gfx.setfont(FONT_SMALL,"Arial",13,0)

  -- Bank name (accent colour)
  gfx.setfont(FONT_BOLD); set_col(bc); gfx.x,gfx.y=10,9
  gfx.drawstr(BANK_NAMES[S.active_bank] or "")

  -- Track name — shortened visually; full name shown as tooltip on hover
  local tn=S.last_track_name
  draw_str(10,34,tn,CD,FONT_SMALL)
  local show_tip=hov(10,34,gfx.w-20,18)

  -- Status bar — always reserves space; text visible for 3 s after each event
  if S.status_msg~="" and (reaper.time_precise()-S.status_time)<3.0 then
    draw_str(10,55,S.status_msg,{0.55,0.75,0.45},FONT_SMALL)
  end

  -- 2×4 knob grid (circles spaced to clear status bar)
  local kr=12
  local cw=math.floor(gfx.w/4)
  local row_cy={110,185}  -- circle centres, chosen to fit in h=270 with all additions
  local now=reaper.time_precise()
  local GLOW_DUR=2.0
  for k=1,8 do
    local row=k<=4 and 1 or 2; local col=((k-1)%4)+1
    local cx=(col-1)*cw+math.floor(cw/2)
    local cy=row_cy[row]
    local active=S.knob_active[k]
    local age=now-(S.knob_touched_time[k] or 0)
    local glow=active and (age<GLOW_DUR and (1.0-age/GLOW_DUR) or 0) or 0
    -- Filled body: shifts toward bank colour as glow fades in
    if active then
      gfx.set(0.22+bc[1]*0.78*glow, 0.22+bc[2]*0.78*glow, 0.28+bc[3]*0.72*glow)
    else
      set_col(CBTN)
    end
    gfx.circle(cx,cy,kr,1,1)
    -- Ring border: always bank colour for active; brightens with glow
    set_col(active and bc or CBR, active and (0.4+0.6*glow) or 0.4)
    gfx.circle(cx,cy,kr,0,1)
    -- Outer halo at peak of glow
    if glow>0.4 then
      gfx.set(bc[1],bc[2],bc[3],(glow-0.4)/0.6*0.45)
      gfx.circle(cx,cy,kr+4,0,1)
    end
    draw_strc((col-1)*cw,cy-kr-18,cw,"K"..k, active and CT or CD, FONT_SMALL)
    draw_strc((col-1)*cw,cy+kr+5,cw,(S.knob_labels[k] or ""):sub(1,11),
              active and CT or CD, FONT_SMALL)
  end

  -- Scrub sensitivity slider + Rel toggle
  local sx,sy,sw,sh=8,225,130,12
  S.scrub_sensitivity=hslider(sx,sy,sw,sh,S.scrub_sensitivity)
  gfx.setfont(FONT_SMALL); set_col(CD)
  gfx.x,gfx.y=sx+sw+6,sy; gfx.drawstr("Sens")
  local rel_col=S.scrub_relative and {0.30,0.65,1.0} or nil
  if btn(sx+sw+42,sy-3,32,18,"Rel",rel_col) then S.scrub_relative=not S.scrub_relative end

  -- Navigation buttons
  local bw=math.floor((gfx.w-16)/2); local by=gfx.h-46
  if btn(6,by,bw,24,"Dashboard") then S.pending_mode=MODE_DASHBOARD end
  if btn(10+bw,by,bw,24,"Setup")  then S.pending_mode=MODE_SETUP     end

  -- Tooltip drawn last so it sits on top of everything
  if show_tip then draw_tooltip(tn,gfx.mouse_x,gfx.mouse_y) end
end

-- ============================================================
-- UI — MODE: DASHBOARD
-- ============================================================

local function draw_bank_dots(x,y)
  local r=10; local gap=28; local track=S.last_track
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
  local bc=BANK_COLORS[S.active_bank]; fill_rect(0,0,gfx.w,5,bc)

  -- Track name: full string drawn, tooltip appears on hover to handle truncation
  local tn=S.last_track_name
  draw_str(8,9,"Track: "..tn,CT,FONT_BOLD)
  local show_tip=hov(8,9,gfx.w/2,28)

  gfx.setfont(FONT_NORMAL); set_col(bc); gfx.x,gfx.y=8,42
  gfx.drawstr("Bank: "..(BANK_NAMES[S.active_bank] or ""))
  draw_bank_dots(8,84)

  -- Knob circles — 2 rows of 4, styled to match Setup mode
  local kcw=math.floor(gfx.w/4); local kr=18
  local kcy={130,196}  -- circle-center y for each row
  for k=1,8 do
    local row=k<=4 and 1 or 2; local col=((k-1)%4)+1
    local cx_=math.floor((col-1)*kcw+kcw/2); local cy_=kcy[row]
    local active=S.knob_active[k]
    local no_reset=(S.active_bank==BANK_FOLLOW and k==5)
    -- Circle body
    set_col(active and {0.3,0.3,0.38} or CBTN); gfx.circle(cx_,cy_,kr,1,1)
    set_col(CBR); gfx.circle(cx_,cy_,kr,0,1)
    -- "K1" label centred inside the circle
    draw_strc((col-1)*kcw,cy_-6,kcw,"K"..k,CD,FONT_SMALL)
    -- Parameter label below the circle
    draw_strc((col-1)*kcw,cy_+kr+4,kcw,S.knob_labels[k] or "",active and CT or CD,FONT_SMALL)
    -- Hover: value readout + reset button
    if active and hov((col-1)*kcw,cy_-kr,kcw,2*kr+22) then
      local vs=get_knob_value_str(k)
      if vs then draw_strc((col-1)*kcw,cy_+kr+18,kcw,vs,{0.5,0.8,0.55},FONT_SMALL) end
      if not no_reset then
        if btn(cx_+kr-14,cy_-kr-1,18,13,"\xe2\x86\xba",CRST) then reset_knob(k,S.last_track) end
      end
    end
  end

  -- Scrub sensitivity slider + Rel toggle
  local sx,sy,sw,sh=8,232,180,14
  draw_str(sx+sw+8,sy+1,"Scrub Sens",CD,FONT_SMALL)
  S.scrub_sensitivity=hslider(sx,sy,sw,sh,S.scrub_sensitivity)
  local rel_col=S.scrub_relative and {0.30,0.65,1.0} or nil
  if btn(sx+sw+80,sy-1,32,18,"Rel",rel_col) then S.scrub_relative=not S.scrub_relative end

  -- Status bar
  if S.status_msg~="" and (reaper.time_precise()-S.status_time)<3.0 then
    draw_str(8,256,S.status_msg,{0.55,0.75,0.45},FONT_SMALL)
  end

  local bw=math.floor((gfx.w-16)/2); local by=gfx.h-46
  if btn(6,by,bw,24,"Mini")  then S.pending_mode=MODE_MINI  end
  if btn(10+bw,by,bw,24,"Setup") then S.pending_mode=MODE_SETUP end

  if show_tip then draw_tooltip(tn,gfx.mouse_x,gfx.mouse_y) end
end

-- ============================================================
-- UI — MODE: SETUP — hardware layout
-- ============================================================

local HW_PW=66; local HW_PH=54; local HW_KW=66; local HW_KH=64; local HW_G=8

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
      if gfx.mouse_cap&1==1 and S.prev_mouse_lb==0 and dist<=r+4 then
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
  draw_str(x+6,y+8,"K"..k.." — "..(BANK_NAMES[S.active_bank] or ""),CT,FONT_BOLD)

  -- CC + MIDI Learn
  draw_str(x+6,y+38,"CC: "..S.knob_ccs[k],CT,FONT_SMALL)
  local ll=(S.midi_learn_active and S.midi_learn_knob==k) and "Listening…" or "MIDI Learn"
  local lc=(S.midi_learn_active and S.midi_learn_knob==k) and CA or nil
  if btn(x+60,y+34,w-66,20,ll,lc) then
    if S.midi_learn_active and S.midi_learn_knob==k then S.midi_learn_active=false
    else S.midi_learn_active=true; S.midi_learn_knob=k end
  end

  -- Friendly name text field
  draw_str(x+6,y+62,"Name:",CD,FONT_SMALL)
  local profile,_,_=knob_context(k)
  local cur_name=(profile and profile.knob_names and profile.knob_names[k]) or ""
  ti_field(x+58,y+58,w-64,20,"kname_"..k,cur_name,function(v)
    if profile then
      profile.knob_names[k]=v
      refresh_knob_labels(S.last_track)
    end
  end)

  -- Parameter dropdown
  draw_str(x+6,y+86,"Param:",CD,FONT_SMALL)
  local cur_param=current_param_display(k)
  local dd_x,dd_y,dd_w,dd_h=x+6,y+108,w-12,22
  if btn(dd_x,dd_y,dd_w,dd_h,cur_param.." \xe2\x96\xbc") then
    S.dropdown_open=(S.dropdown_open==k) and nil or k; S.dropdown_scroll=0
    if S.dropdown_open then build_param_cache(k) end
  end
  if S.dropdown_open==k then
    local maxr=8; local rh=20; local lh=math.min(maxr,#S.param_cache)*rh
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
  local sy=y+138
  draw_str(x+6,sy,"Min:",CD,FONT_SMALL)
  local rslw=math.floor((w-60)/2)-4
  if profile then
    profile.knob_min[k]=hslider(x+38,sy,rslw,14,profile.knob_min[k] or 0,{0.4,0.5,0.8})
    draw_str(x+42+rslw,sy,"Max:",CD,FONT_SMALL)
    profile.knob_max[k]=hslider(x+70+rslw,sy,rslw,14,profile.knob_max[k] or 1,{0.8,0.5,0.3})
  end

  -- Relative/Absolute toggle
  local sy2=y+162
  if profile then
    local rel=profile.knob_relative[k]
    if btn(x+6,sy2,100,20,rel and "Relative" or "Absolute",rel and CA or nil) then
      profile.knob_relative[k]=not rel
    end
    if rel then draw_str(x+112,sy2+2,"(uses CC delta)",CD,FONT_SMALL) end
  end

  -- Unconfirmed profile warning + Confirm button
  if profile and not profile.confirmed then
    local wy=y+190
    fill_rect(x+6,wy,w-12,20,CWN,0.25)
    draw_str(x+10,wy+2,"Auto-assigned — review & confirm",CWN,FONT_SMALL)
    if btn(x+w-72,wy,66,20,"Confirm",COK) then
      profile.confirmed=true; status("Profile confirmed")
    end
  end

  -- Reset to default button (not for K5 scrub in Bank 1)
  local no_reset=(S.active_bank==BANK_FOLLOW and k==5)
  if not no_reset then
    local ry2=profile and (profile.confirmed and y+190 or y+216) or y+190
    if btn(x+6,ry2,120,22,"Reset to Default",CRST) then
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
  draw_str(x+6,y+8,"Pad "..pad.." — Mapping",CT,FONT_BOLD)
  local track=S.last_track
  if not track then draw_str(x+6,y+38,"No track selected",CD,FONT_SMALL); return end
  local fx,pname=find_fx(track,"Drums")
  if not fx then draw_str(x+6,y+38,"No drum plugin on track",CD,FONT_SMALL); return end
  local profile=get_profile(pname,BANK_DRUMS,track,fx)

  -- Friendly label field (editable text input)
  draw_str(x+6,y+38,"Label:",CD,FONT_SMALL)
  local lbl=profile.drum_pad_labels[pad] or ""
  ti_field(x+62,y+34,w-68,20,"plabel_"..pad,lbl,function(v)
    profile.drum_pad_labels[pad]=v
  end)

  -- Current note display
  local note=profile.drum_pad_notes[pad]
  local note_str=note>=0 and (note_name(note).." (MIDI "..note..")") or "Unassigned"
  draw_str(x+6,y+62,"Target: "..note_str,CT,FONT_SMALL)

  -- Octave navigation for keyboard picker
  local oct=S.pad_picker_octave
  draw_str(x+6,y+88,"Note:",CD,FONT_SMALL)
  if btn(x+58,y+84,24,20,"<") then S.pad_picker_octave=math.max(0,oct-1) end
  draw_strc(x+82,y+86,48,"Oct "..oct,CT,FONT_SMALL)
  if btn(x+130,y+84,24,20,">") then S.pad_picker_octave=math.min(8,oct+1) end

  -- 12-note keyboard row for current octave
  local base=oct*12
  local bw2=math.floor((w-12)/12)
  for i=0,11 do
    local note_i=base+i; local bx=x+6+i*bw2
    local is_cur=(profile.drum_pad_notes[pad]==note_i)
    if btn(bx,y+110,bw2-1,20,note_name(note_i),is_cur and CA or nil) then
      profile.drum_pad_notes[pad]=note_i
      status("Pad "..pad.." → "..note_name(note_i))
    end
  end

  -- Quick label presets for common drum parts
  draw_str(x+6,y+138,"Quick labels:",CD,FONT_SMALL)
  local pw2=math.floor((w-12)/4)
  for i,dp in ipairs(DRUM_PARTS) do
    local col_=((i-1)%4); local row_=math.floor((i-1)/4)
    if btn(x+6+col_*pw2,y+162+row_*24,pw2-2,20,dp.label:sub(1,10)) then
      profile.drum_pad_labels[pad]=dp.label
    end
  end

  -- Profiles note: shared between Bank 1 and Bank 8
  draw_str(x+6,y+h-18,"Profile shared between Bank 1 and Bank 8",CD,FONT_SMALL)
end

-- ============================================================
-- UI — MODE: SETUP — plugin library panel
-- ============================================================

-- All categories list for the library dropdown cycling
local ALL_CATS={"Reverb","Delay","Pan","EQ","Distortion","Modulation","Drums","Instrument","Unknown"}

local function draw_library(x,y,w,h)
  fill_rect(x,y,w,h,CP); stroke_rect(x,y,w,h,CBR)
  draw_str(x+6,y+8,"Plugin Library  (click row to cycle category)",CT,FONT_BOLD)
  local cx={x+4,x+math.floor(w*0.38),x+math.floor(w*0.60),x+math.floor(w*0.82)}
  local hdr_y=y+36
  draw_str(cx[1],hdr_y,"Plugin Name",CD,FONT_SMALL)
  draw_str(cx[2],hdr_y,"Guessed",CD,FONT_SMALL)
  draw_str(cx[3],hdr_y,"Confirmed",CD,FONT_SMALL)
  draw_str(cx[4],hdr_y,"Status",CD,FONT_SMALL)
  local plugins={}
  for name,e in pairs(S.plugin_library) do plugins[#plugins+1]={name=name,e=e} end
  table.sort(plugins,function(a,b) return a.name<b.name end)
  local rh=24; local list_y=y+60; local vis=math.floor((h-60)/rh)
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
  draw_str(x+6,y+8,"Presets",CT,FONT_BOLD)
  draw_str(x+6,y+38,S.preset_name,CD,FONT_SMALL)
  local hw=math.floor(w/2)-8
  if btn(x+6,y+66,hw,24,"Save") then save_config() end
  if btn(x+hw+14,y+66,hw,24,"Load\xe2\x80\xa6") then
    local ok,path=reaper.GetUserFileNameForRead("","Load Config","json")
    if ok then load_config(path) end
  end

  -- ── MPK Mini — Pad Presets ──
  local dy=y+102
  set_col(CBR); gfx.line(x+6,dy,x+w-6,dy,0); dy=dy+10
  draw_str(x+6,dy,"MPK Mini — Pad Presets",CT,FONT_BOLD); dy=dy+22

  -- 8-pad grid (matches hardware: row1=P5-P8 top, row2=P1-P4 bottom).
  -- Filled=captured, dimmed=empty.  Click to select the pad to configure.
  local pw=math.floor((w-16)/4)-3; local ph=22
  local pad_order={5,6,7,8, 1,2,3,4}
  for row=0,1 do
    for col=0,3 do
      local pn=pad_order[row*4+col+1]
      local px=x+6+col*(pw+4); local py=dy+row*(ph+4)
      local has=S.pad_presets[pn]~=nil
      local sel=S.device_preset_slot==pn
      local bc=sel and BANK_COLORS[pn] or (has and {0.20,0.32,0.20} or nil)
      if btn(px,py,pw,ph,"P"..pn,bc) then S.device_preset_slot=pn end
    end
  end
  dy=dy+2*(ph+4)+6

  -- Device flash slot to pull from when reading (1-4)
  draw_str(x+6,dy,"From device slot:",CD,FONT_SMALL)
  local sw3=math.floor((w-16)/4)-3
  for s=1,4 do
    local sx3=x+6+(s-1)*(sw3+4)
    if btn(sx3,dy+14,sw3,16,tostring(s),S.device_read_slot==s and CA or nil) then
      S.device_read_slot=s
    end
  end
  dy=dy+38

  -- Read / Send
  local bw2=math.floor((w-16)/2)
  local rlbl=S.sysex_read_pending and "Reading\xe2\x80\xa6" or
             ("Read \xe2\x86\x92 P"..S.device_preset_slot)
  if btn(x+6,dy,bw2,22,rlbl,S.sysex_read_pending and CA or nil) then
    if not S.sysex_read_pending then read_device_preset(S.device_read_slot) end
  end
  local can_send=S.pad_presets[S.device_preset_slot]~=nil
  if btn(x+10+bw2,dy,bw2,22,"Send P"..S.device_preset_slot,
         can_send and nil or {0.22,0.22,0.27}) then
    if can_send then write_device_preset(S.device_preset_slot) end
  end
  dy=dy+30

  -- Status line for selected pad
  local pad=S.pad_presets[S.device_preset_slot]
  if pad then
    draw_str(x+6,dy,"P"..S.device_preset_slot.." CCs: "..
      table.concat(pad.knob_ccs,","),COK,FONT_SMALL)
  else
    draw_str(x+6,dy,"P"..S.device_preset_slot..": not captured yet",CD,FONT_SMALL)
  end
end

-- ============================================================
-- UI — MODE: SETUP — main layout
-- ============================================================

local function draw_setup()
  fill_rect(0,0,gfx.w,gfx.h,CB)
  local bc=BANK_COLORS[S.active_bank]; fill_rect(0,0,gfx.w,5,bc)
  draw_str(8,9,SCRIPT_NAME.." — Setup",CT,FONT_BOLD)
  draw_str(8,42,"Track: "..S.last_track_name.."   Bank: "..(BANK_NAMES[S.active_bank] or ""),CD,FONT_SMALL)

  local hw_x,hw_y=8,70
  local pads_total_w=4*(HW_PW+HW_G)-HW_G
  draw_pads(hw_x,hw_y)
  draw_knobs(hw_x+pads_total_w+24,hw_y)

  local panel_x=hw_x+pads_total_w+24+4*(HW_KW+HW_G)-HW_G+14
  local panel_w=gfx.w-panel_x-6
  local panel_h=math.max(230,2*(HW_PH+HW_G)+10)

  if S.selected_knob then draw_param_panel(panel_x,hw_y,panel_w,panel_h)
  elseif S.selected_pad then draw_pad_panel(panel_x,hw_y,panel_w,panel_h)
  else
    fill_rect(panel_x,hw_y,panel_w,panel_h,CP)
    stroke_rect(panel_x,hw_y,panel_w,panel_h,CBR)
    draw_strc(panel_x,hw_y+math.floor(panel_h/2)-6,panel_w,"Select a knob or pad",CD,FONT_NORMAL)
  end

  local lib_y=hw_y+panel_h+10; local lib_h=gfx.h-lib_y-52; local pre_w=200
  draw_library(8,lib_y,gfx.w-pre_w-14,lib_h)
  draw_presets(gfx.w-pre_w-6,lib_y,pre_w,lib_h)

  if S.status_msg~="" and (reaper.time_precise()-S.status_time)<4.0 then
    draw_str(8,gfx.h-36,S.status_msg,CD,FONT_SMALL)
  end
  local bw=math.floor((gfx.w-16)/2); local by=gfx.h-46
  if btn(6,by,bw,24,"Mini") then
    S.pending_mode=MODE_MINI
  end
  if btn(10+bw,by,bw,24,"Dashboard") then
    S.pending_mode=MODE_DASHBOARD
  end
end

-- ============================================================
-- UI — MASTER DRAW
-- ============================================================

-- Persistent debug bar drawn above the bottom edge of every mode.
-- Shows live JSFX state so we can see if MIDI is actually flowing.
local function draw_midi_debug_bar()
  local n_params, wp_live = -1, -1
  if S.midi_track and reaper.ValidatePtr(S.midi_track,"MediaTrack*") and S.jsfx_idx>=0 then
    local fx=0x1000000|S.jsfx_idx
    n_params=reaper.TrackFX_GetNumParams(S.midi_track,fx) or -1
    local wp_raw=reaper.TrackFX_GetParam(S.midi_track,fx,0)
    wp_live=math.floor(wp_raw or -1)
  end
  local recsrc_val=-1
  if S.midi_track and reaper.ValidatePtr(S.midi_track,"MediaTrack*") then
    recsrc_val=math.floor(reaper.GetMediaTrackInfo_Value(S.midi_track,"I_RECSRC") or -1)
  end
  local msg=string.format("DBG  ready=%s  idx=%d  params=%d  WP=%d  RP=%d  RECSRC=%d  lastCC=%d val=%d",
    tostring(S.jsfx_ready), S.jsfx_idx, n_params, wp_live, S.jsfx_rp,
    recsrc_val, S.dbg_last_cc, S.dbg_last_val)
  local bh=16
  fill_rect(0,gfx.h-bh,gfx.w,bh,{0.05,0.25,0.05})
  gfx.setfont(FONT_SMALL,"Arial",12,0)
  gfx.set(0.20,1.00,0.20)
  gfx.x=4; gfx.y=gfx.h-bh+2
  gfx.drawstr(msg)
end

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
  gfx.setfont(FONT_BOLD,  "Arial",16,string.byte("b"))
  gfx.setfont(FONT_NORMAL,"Arial",14,0)
  gfx.setfont(FONT_SMALL, "Arial",13,0)
  if S.window_mode==MODE_MINI then draw_mini()
  elseif S.window_mode==MODE_DASHBOARD then draw_dashboard()
  else draw_setup() end
  draw_midi_debug_bar()
  draw_midi_unavailable_banner()
  -- Version number top-right corner (all modes)
  gfx.setfont(FONT_SMALL,"Arial",11,0)
  gfx.set(0.40,0.40,0.40)
  local vs="v"..VERSION
  local vw,_=gfx.measurestr(vs)
  gfx.x=gfx.w-vw-4; gfx.y=3
  gfx.drawstr(vs)
  S.prev_mouse_lb=gfx.mouse_cap&1; S.prev_mouse_wheel=gfx.mouse_wheel
  gfx.update()
end

-- ============================================================
-- MAIN DEFERRED LOOP
-- ============================================================

local function main_loop()
  -- Apply any deferred window resize (set by mode-switch buttons during draw).
  -- gfx.init() alone does not resize an already-open window on Windows; the only
  -- reliable approach is gfx.quit() followed immediately by gfx.init(), which
  -- closes and reopens the window at the new size before the next draw call.
  if S.pending_mode then
    S.window_mode=S.pending_mode
    reaper.SetExtState(SCRIPT_NAME,"window_mode",S.pending_mode,false)
    local d=DIMS[S.pending_mode]
    gfx.quit()
    gfx.init(SCRIPT_NAME,d.w,d.h,0)
    S.pending_mode=nil
  end

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

  poll_midi_slider(track)
  poll_sysex_rx()

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
