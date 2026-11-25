--[[
K78-UPIC v2 — Synthétiseur graphique temps réel façon Iannis Xenakis (UPIC + GENDYN)
pour Likebook Ares Note K78W (WM8904 48kHz, Stylet Wacom EMR 4096 niveaux + Survol Theremin, Waterfall 85Hz).

Fonctionnalités :
  - Pression stylet 4096 niveaux -> épaisseur visuelle du trait (2..11 px) + intensité dynamique (amp)
  - Mode SURVOL (Theremin sans contact) -> joue au-dessus de l'écran sans toucher (hauteur = intensité, Y = note, X = panoramique)
  - Dessin d'onde libre + Sinus / Orgue / GENDYN stochastique + Écho spatial + Export WAV 48kHz
]]--

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local RenderText = require("ui/rendertext")
local UIManager = require("ui/uimanager")
local ffi = require("ffi")
local lfs = require("libs/libkoreader-lfs")
local time = require("ui/time")

local C = ffi.C
local Screen = Device.screen
require("ffi/posix_h")

pcall(ffi.cdef, [[
struct upic_arc {
    int32_t active;
    int32_t wave_bank;
    int32_t t_start;
    int32_t t_end;
    float   pan;
    float   gain;
    float   pitch[256];
    float   amp[256];
};
struct upic_shm {
    uint32_t magic;
    int32_t  quit;
    int32_t  playing;
    int32_t  loop;
    float    duration_sec;
    float    playhead;
    float    seek_req;
    int32_t  volume;
    float    reverb_mix;
    int32_t  gendyn_chaos;
    int32_t  live_on;
    int32_t  live_wave;
    float    live_pitch;
    float    live_amp;
    float    live_morph;
    float    live_filter;
    float    live_pan;
    int32_t  export_req;
    char     export_path[128];
    float    custom_wt[256];
    float    custom_wt_b[256];
    struct upic_arc arcs[48];
};
]])

local UPIC_MAGIC    = 0x43495055
local UPIC_WT_SIZE  = 256
local UPIC_MAX_ARCS = 48
local UPIC_COLS     = 256
local SHM_SIZE      = 102400
local SHM_PATH      = "/tmp/k78_upic.shm"
local MUSIC_DIR     = "/data/music"

local BLACK      = Blitbuffer.COLOR_BLACK
local WHITE      = Blitbuffer.COLOR_WHITE
local GRAY_DARK  = Blitbuffer.Color8(0x40)
local GRAY_MID   = Blitbuffer.Color8(0x90)
local GRAY_LIGHT = Blitbuffer.Color8(0xD8)
local GRAY_BG    = Blitbuffer.Color8(0xF0)

local WAVE_NAMES  = { [0] = "PERSO", [1] = "SINUS", [2] = "ORGUE", [3] = "GENDYN" }
local DURATIONS   = { 4, 8, 16, 32 }
local ECHO_LEVELS = { 0.0, 0.35, 0.65 }
local SCALES = {
    { id = "libre",  label = "LIBRE",  semis = nil },
    { id = "penta",  label = "PENTA",  semis = { 0, 2, 4, 7, 9 } },
    { id = "chrom",  label = "CHROM",  semis = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 } },
    { id = "crible", label = "CRIBLE", semis = { 0, 1, 3, 5, 6, 9 } },
}

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function drawThickLine(bb, x0, y0, x1, y1, thick, color, stipple)
    local dx = x1 - x0
    local dy = y1 - y0
    local steps = math.max(1, math.ceil(math.max(math.abs(dx), math.abs(dy)) / math.max(1, thick * 0.45)))
    local half = math.floor(thick / 2)
    for s = 0, steps do
        if not stipple or (s % 2 == 0) then
            local t = s / steps
            local x = math.floor(x0 + dx * t + 0.5) - half
            local y = math.floor(y0 + dy * t + 0.5) - half
            bb:paintRect(x, y, thick, thick, color)
        end
    end
end

local function drawTextCentered(bb, face, text, rx, ry, rw, rh, color)
    local metrics = RenderText:sizeUtf8Text(0, rw - 6, face, text, true, false)
    local tx = rx + math.max(3, math.floor((rw - metrics.x) / 2))
    local ty = ry + math.floor((rh + face.size * 0.72) / 2)
    RenderText:renderUtf8Text(bb, tx, ty, face, text, true, false, color or BLACK)
end

local K78UPIC = InputContainer:extend{
    name = "k78_upic",
    covers_fullscreen = true,
}

function K78UPIC:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.font_btn = Font:getFace("smallinfofont", 16)
    self.font_sm  = Font:getFace("smallinfofont", 15)
    self.font_lbl = Font:getFace("smallinfofont", 14)

    self.cur_wave = 0
    self.dur_idx = 2          -- 8s
    self.echo_idx = 2         -- 35%
    self.scale_idx = 1        -- Libre
    self.hover_mode = false   -- Mode SURVOL (Theremin sans contact)
    self.arc_order = {}
    self.drawing = nil
    self.prev_playhead_x = nil
    self._last_btn_t = nil
    self._hover_last_t = nil
    self._hover_active = false
    self.closed = false

    if not self:connectEngine() then
        UIManager:show(InfoMessage:new{
            text = "Impossible de démarrer /usr/local/bin/k78_upic_engine.",
        })
        return
    end

    self:computeLayout()

    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
        Pan = { GestureRange:new{ ges = "pan", range = self.dimen } },
        PanRelease = { GestureRange:new{ ges = "pan_release", range = self.dimen } },
    }
    self.key_events = {
        Close = { { "Back" }, doc = "Quitter K78-UPIC" },
    }

    -- Hook raw Wacom EMR stylus (pressure + hover + reliable button taps!)
    self._prev_stylus_cb = Device.input.stylus_callback
    Device.input:registerStylusCallback(function(inp, slot)
        return self:onStylusSlot(slot)
    end)

    self._tick_cb = function()
        if self.closed then return end
        self:onPlayheadTick()
        if not self.closed and self.shm and self.shm.playing == 1 then
            UIManager:scheduleIn(0.08, self._tick_cb)
        else
            self._tick_armed = false
        end
    end

    -- Hover silence watchdog: if pen leaves tablet silently, stop Theremin voice cleanly
    self._hover_wd = function()
        if self.closed then return end
        if self._hover_active and not self.drawing then
            local now = time.now()
            if (not Device.wacom_in_range) or (self._hover_last_t and time.to_ms(now - self._hover_last_t) > 220) then
                self._hover_active = false
                if self.shm then self.shm.live_on = 0 end
                self._hover_wd_armed = false
                return
            end
            UIManager:scheduleIn(0.12, self._hover_wd)
        else
            self._hover_wd_armed = false
        end
    end

    self:loadWavePreset("sine")
end

function K78UPIC:connectEngine()
    os.execute("killall k78_upic_engine 2>/dev/null || true")
    os.execute("rm -f " .. SHM_PATH)
    os.execute("/usr/local/bin/k78_upic_engine >/tmp/upic_engine.log 2>&1 &")

    for _ = 1, 30 do
        local fd = C.open(SHM_PATH, 2)
        if fd >= 0 then
            local addr = C.mmap(nil, SHM_SIZE, 3, 1, fd, 0)
            if addr ~= ffi.cast("void*", -1) then
                local shm = ffi.cast("struct upic_shm*", addr)
                if shm.magic == UPIC_MAGIC then
                    self.shm_fd = fd
                    self.shm_addr = addr
                    self.shm = shm
                    return true
                end
                C.munmap(addr, SHM_SIZE)
            end
            C.close(fd)
        end
        C.usleep(50000)
    end
    return false
end

function K78UPIC:computeLayout()
    local W, H = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = W, h = H }
    local pad = 10
    local r1_h = 74
    local r2_h = 68
    local wave_hdr_h = 46
    local wave_h = math.floor(H * 0.125)
    if wave_h < 150 then wave_h = 150 end

    self.row1_y = pad
    self.row1_h = r1_h
    self.row2_y = self.row1_y + r1_h + 6
    self.row2_h = r2_h

    self.wave_hdr_y = self.row2_y + r2_h + 10
    self.wave_hdr_h = wave_hdr_h
    self.wave_box = {
        x = pad,
        y = self.wave_hdr_y + wave_hdr_h,
        w = W - 2 * pad,
        h = wave_h,
    }

    local score_y = self.wave_box.y + self.wave_box.h + 14
    self.score_box = {
        x = pad + 58,
        y = score_y,
        w = W - 2 * pad - 58,
        h = H - score_y - 36,
    }

    self:rebuildButtons()
end

function K78UPIC:rebuildButtons()
    local W = self.dimen.w
    local pad = 10
    local gap = 6
    local shm = self.shm
    local playing = shm and shm.playing == 1
    local looping = shm and shm.loop == 1
    local vol = shm and shm.volume or 78

    local r1_specs = {
        { id = "play",  text = playing and "■ STOP" or "▶ PLAY", active = playing },
        { id = "loop",  text = looping and "↺ BOUCLE" or "→ 1 FOIS", active = looping },
        { id = "hover", text = self.hover_mode and "SURVOL ON" or "SURVOL", active = self.hover_mode },
        { id = "dur",   text = string.format("DUR %ds", DURATIONS[self.dur_idx]) },
        { id = "wave",  text = WAVE_NAMES[self.cur_wave] },
        { id = "echo",  text = string.format("ÉCHO %d%%", math.floor(ECHO_LEVELS[self.echo_idx] * 100 + 0.5)) },
        { id = "scale", text = SCALES[self.scale_idx].label },
    }
    local r2_specs = {
        { id = "vol_dn", text = "VOL -" },
        { id = "vol_up", text = string.format("VOL+ %d%%", vol) },
        { id = "undo",   text = "ANNULER" },
        { id = "cloud",  text = "NUAGE" },
        { id = "clear",  text = "EFFACER" },
        { id = "wav",    text = "WAV" },
        { id = "quit",   text = "✕ QUITTER" },
    }

    self.buttons = {}
    local function layoutRow(specs, y, h)
        local n = #specs
        local bw = math.floor((W - 2 * pad - (n - 1) * gap) / n)
        for i, s in ipairs(specs) do
            local bx = pad + (i - 1) * (bw + gap)
            local w = (i == n) and (W - pad - bx) or bw
            table.insert(self.buttons, {
                id = s.id, text = s.text, active = s.active,
                x = bx, y = y, w = w, h = h,
            })
        end
    end
    layoutRow(r1_specs, self.row1_y, self.row1_h)
    layoutRow(r2_specs, self.row2_y, self.row2_h)

    local presets = {
        { id = "wp_sine",  text = "Sinus" },
        { id = "wp_saw",   text = "Scie" },
        { id = "wp_sq",    text = "Carré" },
        { id = "wp_chaos", text = "Chaos" },
    }
    local pw = 108
    local px0 = W - pad - (#presets * (pw + 6) - 6)
    for i, p in ipairs(presets) do
        table.insert(self.buttons, {
            id = p.id, text = p.text, small = true,
            x = px0 + (i - 1) * (pw + 6), y = self.wave_hdr_y + 2,
            w = pw, h = self.wave_hdr_h - 6,
        })
    end
end

function K78UPIC:loadWavePreset(kind)
    if not self.shm then return end
    local wt = self.shm.custom_wt
    local seed = 0x1337BEEF
    for i = 0, UPIC_WT_SIZE - 1 do
        local ph = i / UPIC_WT_SIZE
        local v
        if kind == "sine" then
            v = math.sin(ph * 2 * math.pi) * 0.9
        elseif kind == "saw" then
            v = 0
            for h = 1, 8 do v = v + math.sin(ph * h * 2 * math.pi) / h end
            v = v * 0.55
        elseif kind == "square" then
            v = 0
            for h = 1, 9, 2 do v = v + math.sin(ph * h * 2 * math.pi) / h end
            v = v * 0.72
        else
            seed = (seed * 1664525 + 1013904223) % 4294967296
            local r = (seed / 2147483648.0) - 1.0
            v = 0.55 * math.sin(ph * 2 * math.pi + 1.5 * math.sin(ph * 6 * math.pi)) + 0.35 * r
        end
        wt[i] = clamp(v, -0.98, 0.98)
    end
end

function K78UPIC:quantizePitch(y_norm)
    local sc = SCALES[self.scale_idx]
    if not sc or not sc.semis then return clamp(y_norm, 0, 1) end
    local semi = clamp(y_norm, 0, 1) * 60.0
    local oct = math.floor(semi / 12.0)
    local rem = semi - oct * 12.0
    local best, best_d = sc.semis[1], 99
    for _, s in ipairs(sc.semis) do
        local d = math.abs(rem - s)
        if d < best_d then best, best_d = s, d end
    end
    return clamp((oct * 12.0 + best) / 60.0, 0, 1)
end

function K78UPIC:allocArcSlot()
    if not self.shm then return nil end
    for i = 0, UPIC_MAX_ARCS - 1 do
        if self.shm.arcs[i].active == 0 then return i end
    end
    if #self.arc_order > 0 then
        local idx = table.remove(self.arc_order, 1)
        self.shm.arcs[idx].active = 0
        return idx
    end
    return 0
end

function K78UPIC:generateXenakisCloud()
    if not self.shm then return end
    for i = 0, UPIC_MAX_ARCS - 1 do self.shm.arcs[i].active = 0 end
    self.arc_order = {}
    local n_arcs = 9
    for k = 1, n_arcs do
        local idx = self:allocArcSlot()
        if not idx then break end
        local arc = self.shm.arcs[idx]
        local t0 = math.floor(math.random() * 140)
        local span = 45 + math.floor(math.random() * 110)
        local t1 = math.min(UPIC_COLS - 1, t0 + span)
        local y0 = 0.12 + math.random() * 0.74
        local y1 = 0.12 + math.random() * 0.74
        local curve = (math.random() - 0.5) * 0.35
        local wb = (k % 3 == 0) and 3 or ((k % 3 == 1) and self.cur_wave or 2)
        arc.wave_bank = wb
        arc.t_start = t0
        arc.t_end = t1
        arc.pan = ((k - 1) / (n_arcs - 1)) * 1.6 - 0.8
        arc.gain = 0.72
        for c = t0, t1 do
            local u = (t1 > t0) and ((c - t0) / (t1 - t0)) or 0
            local y = y0 + (y1 - y0) * u + curve * 4 * u * (1 - u)
            arc.pitch[c] = self:quantizePitch(clamp(y, 0.05, 0.95))
            arc.amp[c] = 0.25 + 0.75 * math.sin(u * math.pi)
        end
        arc.active = 1
        table.insert(self.arc_order, idx)
    end
    self.shm.seek_req = 0.0
    self.shm.playing = 1
    self:armPlayheadTick()
    self:rebuildButtons()
    UIManager:setDirty(self, "ui")
end

function K78UPIC:armPlayheadTick()
    if not self._tick_armed and not self.closed then
        self._tick_armed = true
        UIManager:scheduleIn(0.08, self._tick_cb)
    end
end

function K78UPIC:onPlayheadTick()
    if not self.shm or self.closed then return end
    local sb = self.score_box
    local ph = clamp(self.shm.playhead, 0, 1)
    local nx = sb.x + math.floor(ph * (sb.w - 1))
    local ox = self.prev_playhead_x
    if ox == nx and self.shm.playing == 1 then return end
    self.prev_playhead_x = nx
    if ox then
        UIManager:setDirty(self, "fast", Geom:new{ x = math.max(sb.x, ox - 3), y = sb.y, w = 7, h = sb.h })
    end
    UIManager:setDirty(self, "fast", Geom:new{ x = math.max(sb.x, nx - 3), y = sb.y, w = 7, h = sb.h })
    if self.shm.playing == 0 then
        self:rebuildButtons()
        UIManager:setDirty(self, "ui", Geom:new{ x = 0, y = self.row1_y, w = self.dimen.w, h = self.row1_h + 4 })
    end
end

function K78UPIC:handleButton(id)
    local now = time.now()
    if self._last_btn_t and time.to_ms(now - self._last_btn_t) < 160 then return end
    self._last_btn_t = now

    local shm = self.shm
    if not shm then return end
    if id == "play" then
        if shm.playing == 1 then
            shm.playing = 0
        else
            shm.playing = 1
            self:armPlayheadTick()
        end
        self:rebuildButtons()
        UIManager:setDirty(self, "ui", Geom:new{ x = 0, y = self.row1_y, w = self.dimen.w, h = self.row1_h + 4 })
    elseif id == "loop" then
        shm.loop = (shm.loop == 1) and 0 or 1
        self:rebuildButtons()
        UIManager:setDirty(self, "ui", Geom:new{ x = 0, y = self.row1_y, w = self.dimen.w, h = self.row1_h + 4 })
    elseif id == "hover" then
        self.hover_mode = not self.hover_mode
        if not self.hover_mode then
            self._hover_active = false
            shm.live_on = 0
        end
        self:rebuildButtons()
        UIManager:setDirty(self, "ui", Geom:new{ x = 0, y = self.row1_y, w = self.dimen.w, h = self.row1_h + 4 })
    elseif id == "dur" then
        self.dur_idx = (self.dur_idx % #DURATIONS) + 1
        shm.duration_sec = DURATIONS[self.dur_idx]
        self:rebuildButtons()
        UIManager:setDirty(self, "ui")
    elseif id == "wave" then
        self.cur_wave = (self.cur_wave + 1) % 4
        self:rebuildButtons()
        UIManager:setDirty(self, "ui", Geom:new{ x = 0, y = self.row1_y, w = self.dimen.w, h = self.row1_h + 4 })
    elseif id == "echo" then
        self.echo_idx = (self.echo_idx % #ECHO_LEVELS) + 1
        shm.reverb_mix = ECHO_LEVELS[self.echo_idx]
        self:rebuildButtons()
        UIManager:setDirty(self, "ui", Geom:new{ x = 0, y = self.row1_y, w = self.dimen.w, h = self.row1_h + 4 })
    elseif id == "scale" then
        self.scale_idx = (self.scale_idx % #SCALES) + 1
        self:rebuildButtons()
        UIManager:setDirty(self, "ui", Geom:new{ x = 0, y = self.row1_y, w = self.dimen.w, h = self.row1_h + 4 })
    elseif id == "vol_dn" then
        shm.volume = clamp(shm.volume - 10, 0, 100)
        self:rebuildButtons()
        UIManager:setDirty(self, "ui", Geom:new{ x = 0, y = self.row2_y, w = self.dimen.w, h = self.row2_h + 4 })
    elseif id == "vol_up" then
        shm.volume = clamp(shm.volume + 10, 0, 100)
        self:rebuildButtons()
        UIManager:setDirty(self, "ui", Geom:new{ x = 0, y = self.row2_y, w = self.dimen.w, h = self.row2_h + 4 })
    elseif id == "undo" then
        if #self.arc_order > 0 then
            local idx = table.remove(self.arc_order)
            shm.arcs[idx].active = 0
            UIManager:setDirty(self, "ui", Geom:new{
                x = self.score_box.x, y = self.score_box.y, w = self.score_box.w, h = self.score_box.h,
            })
        end
    elseif id == "cloud" then
        self:generateXenakisCloud()
    elseif id == "clear" then
        for i = 0, UPIC_MAX_ARCS - 1 do shm.arcs[i].active = 0 end
        self.arc_order = {}
        UIManager:setDirty(self, "ui", Geom:new{
            x = self.score_box.x, y = self.score_box.y, w = self.score_box.w, h = self.score_box.h,
        })
    elseif id == "wav" then
        self:doExportWav()
    elseif id == "quit" then
        self:onClose()
    elseif id == "wp_sine" then
        self:loadWavePreset("sine"); self.cur_wave = 0; self:rebuildButtons(); UIManager:setDirty(self, "ui")
    elseif id == "wp_saw" then
        self:loadWavePreset("saw"); self.cur_wave = 0; self:rebuildButtons(); UIManager:setDirty(self, "ui")
    elseif id == "wp_sq" then
        self:loadWavePreset("square"); self.cur_wave = 0; self:rebuildButtons(); UIManager:setDirty(self, "ui")
    elseif id == "wp_chaos" then
        self:loadWavePreset("chaos"); self.cur_wave = 0; self:rebuildButtons(); UIManager:setDirty(self, "ui")
    end
end

function K78UPIC:doExportWav()
    if not self.shm then return end
    if lfs.attributes(MUSIC_DIR, "mode") ~= "directory" then pcall(lfs.mkdir, MUSIC_DIR) end
    local fname = MUSIC_DIR .. "/upic_" .. os.date("%Y%m%d_%H%M%S") .. ".wav"
    ffi.fill(self.shm.export_path, 128, 0)
    ffi.copy(self.shm.export_path, fname, math.min(127, #fname))
    self.shm.export_req = 1
    for _ = 1, 80 do
        if self.shm.export_req == 2 or self.shm.export_req < 0 then break end
        C.usleep(25000)
    end
    local ok = (self.shm.export_req == 2)
    self.shm.export_req = 0
    if ok then
        local sz = lfs.attributes(fname, "size") or 0
        UIManager:show(InfoMessage:new{
            text = string.format("Export WAV réussi !\n%s\n(%.0f Ko, 48 kHz stéréo)", fname, sz / 1024),
            timeout = 3,
        })
    else
        UIManager:show(InfoMessage:new{ text = "Erreur lors de l'export WAV.", timeout = 2 })
    end
end

local function inBox(x, y, b)
    return x >= b.x and x <= (b.x + b.w) and y >= b.y and y <= (b.y + b.h)
end

function K78UPIC:hitButton(x, y)
    for _, b in ipairs(self.buttons) do
        if inBox(x, y, b) then return b.id end
    end
    return nil
end

-- Convert stylus pressure (0..1) into expressive amplitude + stroke thickness (2..11 px)
local function pressureToAmp(is_stylus)
    if not is_stylus then return 0.78 end
    local p = Device.wacom_pressure or 0.0
    if p <= 0.01 then return 0.45 end
    return clamp(0.16 + 0.84 * (p ^ 0.65), 0.16, 1.0)
end

local function ampToThick(amp, wave_bank)
    local base = math.floor(2 + amp * 9 + 0.5)
    if wave_bank == 1 then base = math.max(2, base - 2) end
    return clamp(base, 2, 12)
end

function K78UPIC:beginDraw(x, y, is_stylus)
    if not self.shm then return false end
    if inBox(x, y, self.wave_box) then
        self.cur_wave = 0
        self.drawing = { kind = "wave", last_idx = nil, last_v = nil, is_stylus = is_stylus }
        self:updateWaveDraw(x, y, is_stylus)
        return true
    elseif inBox(x, y, self.score_box) then
        local idx = self:allocArcSlot()
        if not idx then return false end
        local arc = self.shm.arcs[idx]
        arc.active = 0
        arc.wave_bank = self.cur_wave
        arc.t_start = UPIC_COLS - 1
        arc.t_end = 0
        arc.pan = (math.random() - 0.5) * 1.2
        arc.gain = 0.85
        self.drawing = {
            kind = "score",
            arc_idx = idx,
            is_stylus = is_stylus,
            last_col = nil,
            last_p = nil,
            last_amp = nil,
            last_sx = nil,
            last_sy = nil,
        }
        self:updateScoreDraw(x, y, is_stylus)
        return true
    end
    return false
end

function K78UPIC:updateWaveDraw(x, y, is_stylus)
    local d = self.drawing
    local wb = self.wave_box
    local shm = self.shm
    local u = clamp((x - wb.x) / wb.w, 0, 1)
    local idx = math.floor(u * (UPIC_WT_SIZE - 1) + 0.5)
    local v = clamp(1.0 - 2.0 * ((y - wb.y) / wb.h), -0.98, 0.98)

    if d.last_idx then
        local i0, i1 = d.last_idx, idx
        local v0, v1 = d.last_v, v
        if i0 > i1 then i0, i1, v0, v1 = i1, i0, v1, v0 end
        for k = i0, i1 do
            local frac = (i1 > i0) and ((k - i0) / (i1 - i0)) or 0
            shm.custom_wt[k] = v0 + (v1 - v0) * frac
        end
    else
        shm.custom_wt[idx] = v
    end
    d.last_idx, d.last_v = idx, v

    shm.live_wave = 0
    shm.live_morph = 0.0
    shm.live_filter = 1.0
    shm.live_pan = 0.0
    shm.live_pitch = 0.40 -- 220 Hz
    shm.live_amp = pressureToAmp(is_stylus)
    shm.live_on = 1

    UIManager:setDirty(self, "fast", Geom:new{ x = wb.x, y = wb.y, w = wb.w, h = wb.h })
end

function K78UPIC:updateScoreDraw(x, y, is_stylus)
    local d = self.drawing
    local sb = self.score_box
    local shm = self.shm
    local arc = shm.arcs[d.arc_idx]

    local u = clamp((x - sb.x) / sb.w, 0, 1)
    local col = math.floor(u * (UPIC_COLS - 1) + 0.5)
    local raw_p = clamp(1.0 - (y - sb.y) / sb.h, 0, 1)
    local p = self:quantizePitch(raw_p)
    local amp = pressureToAmp(is_stylus)
    local sy = sb.y + math.floor((1.0 - p) * sb.h + 0.5)
    local sx = sb.x + math.floor(u * sb.w + 0.5)

    if d.last_col then
        local c0, c1 = d.last_col, col
        local p0, p1 = d.last_p, p
        local a0, a1 = d.last_amp or amp, amp
        if c0 > c1 then c0, c1, p0, p1, a0, a1 = c1, c0, p1, p0, a1, a0 end
        for c = c0, c1 do
            local frac = (c1 > c0) and ((c - c0) / (c1 - c0)) or 0
            arc.pitch[c] = p0 + (p1 - p0) * frac
            arc.amp[c] = a0 + (a1 - a0) * frac
        end
        if c0 < arc.t_start then arc.t_start = c0 end
        if c1 > arc.t_end then arc.t_end = c1 end
    else
        arc.pitch[col] = p
        arc.amp[col] = amp
        arc.t_start = col
        arc.t_end = col
    end

    -- Hear pitch + pressure loudness + brightness LIVE!
    shm.live_wave = arc.wave_bank
    shm.live_morph = 0.0
    shm.live_pitch = p
    shm.live_amp = amp
    shm.live_filter = clamp(0.28 + 0.72 * amp, 0.28, 1.0)
    shm.live_pan = (u * 2.0 - 1.0) * 0.7
    shm.live_on = 1

    -- Draw pressure-weighted stroke directly onto framebuffer (instant Waterfall ink!)
    local thick = ampToThick(amp, arc.wave_bank)
    local stip = (arc.wave_bank == 3)
    local px0 = d.last_sx or sx
    local py0 = d.last_sy or sy
    drawThickLine(Screen.bb, px0, py0, sx, sy, thick, BLACK, stip)
    local pad = thick + 4
    local rx = math.max(sb.x, math.min(px0, sx) - pad)
    local ry = math.max(sb.y, math.min(py0, sy) - pad)
    local rw = math.abs(sx - px0) + 2 * pad
    local rh = math.abs(sy - py0) + 2 * pad
    Screen:refreshFast(rx, ry, rw, rh)

    d.last_col, d.last_p, d.last_amp, d.last_sx, d.last_sy = col, p, amp, sx, sy
end

function K78UPIC:endDraw()
    local d = self.drawing
    self.drawing = nil
    if self.shm then self.shm.live_on = 0 end
    if not d then return end

    if d.kind == "score" and self.shm then
        local arc = self.shm.arcs[d.arc_idx]
        if arc.t_end >= arc.t_start then
            if arc.t_end - arc.t_start < 3 then
                local p = arc.pitch[arc.t_start]
                local a = arc.amp[arc.t_start]
                local c1 = math.min(UPIC_COLS - 1, arc.t_start + 3)
                for c = arc.t_start, c1 do arc.pitch[c] = p; arc.amp[c] = a end
                arc.t_end = c1
            end
            arc.active = 1
            table.insert(self.arc_order, d.arc_idx)
        end
        UIManager:setDirty(self, "ui", Geom:new{
            x = self.score_box.x, y = self.score_box.y, w = self.score_box.w, h = self.score_box.h,
        })
    elseif d.kind == "wave" then
        self:rebuildButtons()
        UIManager:setDirty(self, "ui", Geom:new{
            x = self.wave_box.x, y = self.wave_box.y, w = self.wave_box.w, h = self.wave_box.h,
        })
    end
end

-- Contactless Hover Theremin sound (while SURVOL mode is ON and pen hovers over score!)
function K78UPIC:updateHoverTheremin(x, y)
    if not self.shm then return end
    if not self.hover_mode or not Device.wacom_in_range or not inBox(x, y, self.score_box) then
        if self._hover_active then
            self._hover_active = false
            self.shm.live_on = 0
        end
        return
    end
    local sb = self.score_box
    local u = clamp((x - sb.x) / sb.w, 0, 1)
    local raw_p = clamp(1.0 - (y - sb.y) / sb.h, 0, 1)
    local p = self:quantizePitch(raw_p)
    -- Closer to glass (smaller ABS_DISTANCE) = louder + brighter!
    local dist = Device.wacom_distance or 50
    local prox = clamp(1.0 - (dist / 120.0), 0.12, 1.0)
    self.shm.live_wave = self.cur_wave
    self.shm.live_morph = 0.0
    self.shm.live_pitch = p
    self.shm.live_amp = prox
    self.shm.live_filter = clamp(0.20 + 0.80 * prox, 0.20, 1.0)
    self.shm.live_pan = (u * 2.0 - 1.0) * 0.85
    self.shm.live_on = 1
    self._hover_active = true
    self._hover_last_t = time.now()
    if not self._hover_wd_armed then
        self._hover_wd_armed = true
        UIManager:scheduleIn(0.15, self._hover_wd)
    end
end

-- Raw Wacom EMR stylus callback (handles pressure drawing, hover Theremin, AND 100% reliable button taps!)
function K78UPIC:onStylusSlot(slot)
    if self.closed or not slot then return false end
    local x, y = slot.x, slot.y
    if not x or not y then
        if (not slot.id or slot.id == -1) then
            if self.drawing then self:endDraw() end
            if self._hover_active and not Device.wacom_in_range then
                self._hover_active = false
                if self.shm then self.shm.live_on = 0 end
            end
            self._btn_down = false
            return true
        end
        return false
    end

    local rot = Screen:getTouchRotation()
    local W, H = Screen:getWidth(), Screen:getHeight()
    if rot == 1 then x, y = y, H - x
    elseif rot == 2 then x, y = W - x, H - y
    elseif rot == 3 then x, y = W - y, x end

    -- Pen lift (slot.id == -1) or hover (slot.id == nil)
    if not slot.id or slot.id == -1 then
        self._btn_down = false
        if self.drawing then
            self:endDraw()
            return true
        end
        -- Contactless Hover Theremin!
        if self.hover_mode and slot.id == nil and Device.wacom_in_range then
            self:updateHoverTheremin(x, y)
            return true
        elseif self._hover_active then
            self._hover_active = false
            if self.shm then self.shm.live_on = 0 end
        end
        return false
    end

    -- Pen is TOUCHING the screen (slot.id >= 0)
    self._hover_active = false
    if self.drawing then
        if self.drawing.kind == "wave" then
            self:updateWaveDraw(x, y, true)
        else
            self:updateScoreDraw(x, y, true)
        end
        return true
    end

    -- Direct stylus button click (never swallowed as tiny Pan!)
    local bid = self:hitButton(x, y)
    if bid then
        if not self._btn_down then
            self._btn_down = true
            self:handleButton(bid)
        end
        return true
    end

    if inBox(x, y, self.wave_box) or inBox(x, y, self.score_box) then
        return self:beginDraw(x, y, true)
    end
    return true
end

function K78UPIC:onTap(_, ges)
    local x, y = ges.pos.x, ges.pos.y
    local bid = self:hitButton(x, y)
    if bid then
        self:handleButton(bid)
        return true
    end
    if inBox(x, y, self.score_box) or inBox(x, y, self.wave_box) then
        if self:beginDraw(x, y, false) then self:endDraw() end
    end
    return true
end

function K78UPIC:onPan(_, ges)
    local x, y = ges.pos.x, ges.pos.y
    if not self.drawing then
        local bid = self:hitButton(x, y)
        if bid then
            self:handleButton(bid)
            return true
        end
        if not self:beginDraw(x, y, false) then return true end
    else
        if self.drawing.kind == "wave" then
            self:updateWaveDraw(x, y, false)
        else
            self:updateScoreDraw(x, y, false)
        end
    end
    return true
end

function K78UPIC:onPanRelease()
    if self.drawing then self:endDraw() end
    return true
end

function K78UPIC:paintTo(bb, ox, oy)
    local W, H = self.dimen.w, self.dimen.h
    bb:paintRect(ox, oy, W, H, WHITE)

    for _, b in ipairs(self.buttons) do
        local bg = b.active and BLACK or GRAY_BG
        local fg = b.active and WHITE or BLACK
        bb:paintBorder(ox + b.x, oy + b.y, b.w, b.h, 2, BLACK, 4)
        bb:paintRect(ox + b.x + 2, oy + b.y + 2, b.w - 4, b.h - 4, bg)
        drawTextCentered(bb, b.small and self.font_sm or self.font_btn, b.text,
            ox + b.x, oy + b.y, b.w, b.h, fg)
    end

    RenderText:renderUtf8Text(bb, ox + 14, oy + self.wave_hdr_y + 30, self.font_sm,
        self.hover_mode and "ONDE PERSO  |  Mode SURVOL actif : approche le stylet sans toucher !"
        or "ONDE PERSO (dessine une période)  |  Pression = épaisseur & volume",
        true, false, BLACK)
    local wb = self.wave_box
    bb:paintRect(ox + wb.x, oy + wb.y, wb.w, wb.h, WHITE)
    bb:paintBorder(ox + wb.x, oy + wb.y, wb.w, wb.h, 2, BLACK, 0)
    local mid_y = oy + wb.y + math.floor(wb.h / 2)
    bb:paintRect(ox + wb.x + 2, mid_y, wb.w - 4, 1, GRAY_MID)
    if self.shm then
        local wt = self.shm.custom_wt
        local px0, py0
        for i = 0, UPIC_WT_SIZE - 1 do
            local sx = ox + wb.x + 2 + math.floor(i * (wb.w - 4) / (UPIC_WT_SIZE - 1))
            local sy = oy + wb.y + math.floor((1.0 - wt[i]) * 0.5 * (wb.h - 8)) + 4
            if px0 then drawThickLine(bb, px0, py0, sx, sy, 3, BLACK, false) end
            px0, py0 = sx, sy
        end
    end

    local sb = self.score_box
    bb:paintRect(ox + sb.x, oy + sb.y, sb.w, sb.h, WHITE)
    bb:paintBorder(ox + sb.x, oy + sb.y, sb.w, sb.h, 2, BLACK, 0)

    local oct_labels = {
        { y = 1.0, lbl = "A6" }, { y = 0.8, lbl = "A5" }, { y = 0.6, lbl = "A4" },
        { y = 0.4, lbl = "A3" }, { y = 0.2, lbl = "A2" }, { y = 0.0, lbl = "A1" },
    }
    for _, o in ipairs(oct_labels) do
        local gy = oy + sb.y + math.floor((1.0 - o.y) * (sb.h - 1))
        if o.y > 0 and o.y < 1 then bb:paintRect(ox + sb.x + 2, gy, sb.w - 4, 1, GRAY_LIGHT) end
        RenderText:renderUtf8Text(bb, ox + 10, gy + 5, self.font_lbl, o.lbl, true, false, GRAY_DARK)
    end

    local dur = DURATIONS[self.dur_idx]
    for d = 0, 4 do
        local gx = ox + sb.x + math.floor(d * (sb.w - 1) / 4)
        if d > 0 and d < 4 then bb:paintRect(gx, oy + sb.y + 2, 1, sb.h - 4, GRAY_LIGHT) end
        local ts = string.format("%gs", dur * d / 4)
        RenderText:renderUtf8Text(bb, math.min(ox + W - 45, gx - 8), oy + sb.y + sb.h + 24,
            self.font_lbl, ts, true, false, GRAY_DARK)
    end

    -- Render all arcs with true pressure-weighted thickness!
    if self.shm then
        for i = 0, UPIC_MAX_ARCS - 1 do
            local arc = self.shm.arcs[i]
            if arc.active == 1 and arc.t_end >= arc.t_start then
                local stip = (arc.wave_bank == 3)
                local px0, py0
                for c = arc.t_start, arc.t_end do
                    local sx = ox + sb.x + math.floor(c * (sb.w - 1) / (UPIC_COLS - 1))
                    local sy = oy + sb.y + math.floor((1.0 - clamp(arc.pitch[c], 0, 1)) * (sb.h - 1))
                    local thick = ampToThick(clamp(arc.amp[c], 0.1, 1.0), arc.wave_bank)
                    if px0 then drawThickLine(bb, px0, py0, sx, sy, thick, BLACK, stip) end
                    px0, py0 = sx, sy
                end
            end
        end

        local ph = clamp(self.shm.playhead, 0, 1)
        if self.shm.playing == 1 or ph > 0.001 then
            local px = ox + sb.x + math.floor(ph * (sb.w - 1))
            bb:paintRect(px - 1, oy + sb.y + 2, 3, sb.h - 4, GRAY_DARK)
        end
    end
end

function K78UPIC:onClose()
    if self.closed then return true end
    self.closed = true
    UIManager:unschedule(self._tick_cb)
    UIManager:unschedule(self._hover_wd)
    Device.input:registerStylusCallback(self._prev_stylus_cb)
    if self.shm then
        self.shm.live_on = 0
        self.shm.playing = 0
        self.shm.quit = 1
        C.munmap(self.shm_addr, SHM_SIZE)
        C.close(self.shm_fd)
        self.shm = nil
    end
    UIManager:close(self)
    UIManager:setDirty("all", "full")
    return true
end

return function(ui)
    local app = K78UPIC:new{}
    if app.shm then
        UIManager:show(app)
        UIManager:setDirty(app, "full")
    end
end
