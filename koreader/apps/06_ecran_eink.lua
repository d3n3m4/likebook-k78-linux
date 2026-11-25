--[[
K78-SCREEN — Mode Mini-Cintiq / 2e Écran E-Ink 85 Hz pour Linux (KDE Plasma / Wayland)
Reçoit un flux vidéo temps réel K78S sur TCP 19781 (USB RNDIS <1ms ou Wi-Fi),
décode via libk78stream.so (PackBits RLE + Delta-XOR + LUT 64-bit) directement dans
/dev/ebc en 85 Hz A2-Waterfall ou HQ 16-Gris, avec retour stylet Wacom 4096 simultané !

Lancé en 1 tap depuis ⊞ Apps Custom (/data/apps/06_ecran_eink.lua).
Appuie sur le bouton Retour (en bas de la liseuse) ou 2 doigts pour ouvrir/fermer la barre HUD.
]]--

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local RenderText = require("ui/rendertext")
local UIManager = require("ui/uimanager")
local bit = require("bit")
local ebc = require("ffi/ebc_h")
local ffi = require("ffi")
local socket = require("socket")
local time = require("ui/time")

local Screen = Device.screen

ffi.cdef[[
int  k78_packbits_decode(void *dst, size_t dst_cap, const void *src, size_t src_len, int xor_mode);
void k78_apply_raw(void *dst, const void *src, size_t n, int xor_mode);
void k78_unpack_1bit_to_bb8(void *bb_dst, const void *bits, int width, int y1, int y2);
void k78_unpack_4bit_to_bb8(void *bb_dst, const void *nibs, int width, int y1, int y2);
]]

local ok_lib, k78s = pcall(ffi.load, "libs/libk78stream.so")
if not ok_lib then k78s = nil end

local PORT = 19781
local EBC_W = 1872
local EBC_H = 1404
local ROW_BYTES_1B = EBC_W / 8   -- 234
local ROW_BYTES_4B = EBC_W / 2   -- 936

local BLACK      = Blitbuffer.COLOR_BLACK
local WHITE      = Blitbuffer.COLOR_WHITE
local GRAY_DARK  = Blitbuffer.Color8(0x40)
local GRAY_MID   = Blitbuffer.Color8(0x90)
local GRAY_BG    = Blitbuffer.Color8(0xEE)

local MODE_LABELS = { [0] = "85Hz Bayer", [1] = "85Hz Texte", [2] = "HQ 16-Gris" }
local ORIENT_LABELS = { [2] = "Paysage (USB-G)", [1] = "Paysage (USB-D)", [0] = "Portrait" }

local function inBox(x, y, b)
    return x >= b.x and x <= (b.x + b.w) and y >= b.y and y <= (b.y + b.h)
end

local function u16le(s, i)
    local a, b = s:byte(i, i + 1)
    return a + b * 256
end

local function u32le(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    return a + b * 256 + c * 65536 + d * 16777216
end

local function getWifiIP()
    local p = io.popen("ip -4 addr show wlan0 2>/dev/null | sed -n 's/.*inet \\([0-9.]*\\).*/\\1/p' | head -n1")
    if not p then return nil end
    local ip = p:read("*l")
    p:close()
    if ip and #ip > 0 then return ip end
    return nil
end

local function drawTextCentered(bb, face, text, rx, ry, rw, rh, color)
    local metrics = RenderText:sizeUtf8Text(0, rw - 6, face, text, true, false)
    local tx = rx + math.max(3, math.floor((rw - metrics.x) / 2))
    local ty = ry + math.floor((rh + face.size * 0.72) / 2)
    RenderText:renderUtf8Text(bb, tx, ty, face, text, true, false, color or BLACK)
end

local K78Screen = InputContainer:extend{
    name = "k78_screen",
    covers_fullscreen = true,
}

function K78Screen:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.font_btn = Font:getFace("smallinfofont", 16)
    self.font_sm  = Font:getFace("smallinfofont", 16)
    self.font_big = Font:getFace("smallinfofont", 26)

    self.mode = 0          -- 0=85Hz Bayer, 1=85Hz Texte, 2=HQ 16-Gris
    self.auto_hq = false   -- Pur 85Hz Waterfall fluide par défaut (zéro flash périodique!)
    self.invert = false
    self.orient = 2        -- 2=Paysage CW (USB à gauche, natif 1:1), 1=Paysage CCW, 0=Portrait
    self.cintiq_pen = true -- Lance k78_tablet_sender vers l'IP du PC connecté !
    self.hud_open = false
    self.connected = false
    self.peer_ip = nil
    self.wifi_ip = getWifiIP()
    self.closed = false
    self.frames = 0
    self._last_btn_t = nil
    self._btn_down = false
    self._saved_k78_mode = Screen.getK78Mode and Screen:getK78Mode() or "auto"

    -- Persistent packed framebuffer states for XOR deltas
    self.state_1b = ffi.new("uint8_t[?]", EBC_W * EBC_H / 8)
    self.state_4b = ffi.new("uint8_t[?]", EBC_W * EBC_H / 2)

    -- TCP byte stream accumulator
    self.srv = nil
    self.cli = nil
    self.rx_chunks = {}
    self.rx_have = 0
    self.rx_hdr = nil
    self.rx_need = 20

    self:rebuildButtons()
    self:startServer()

    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
        TwoFingerTap = { GestureRange:new{ ges = "two_finger_tap", range = self.dimen } },
    }
    self.key_events = {
        ToggleHUD = { { "Back" }, doc = "Ouvrir HUD / Quitter" },
    }

    -- Swallow Wacom events while streaming (k78_tablet_sender streams raw 120Hz to Linux host!)
    -- and allow tapping HUD buttons with the stylus cleanly.
    self._prev_stylus_cb = Device.input.stylus_callback
    Device.input:registerStylusCallback(function(inp, slot)
        return self:onStylusSlot(slot)
    end)

    self._tick_fn = function()
        if not self.closed then
            self:pollNetwork()
            UIManager:scheduleIn(self.connected and 0.015 or 0.15, self._tick_fn)
        end
    end
    UIManager:scheduleIn(0.05, self._tick_fn)
end

function K78Screen:startServer()
    local s = socket.tcp()
    s:setoption("reuseaddr", true)
    local ok = s:bind("0.0.0.0", PORT)
    if ok then
        s:listen(2)
        s:settimeout(0)
        self.srv = s
    else
        pcall(s.close, s)
        self.srv = nil
    end
end

function K78Screen:stopPenSender()
    os.execute("killall k78_tablet_sender 2>/dev/null || true")
end

function K78Screen:syncPenSender()
    self:stopPenSender()
    if self.connected and self.cintiq_pen and not self.closed then
        -- Full edge-to-edge active Wacom Cintiq (pad_ymin = 0) over TCP 19782 (zero ufw needed!)
        local cmd = string.format(
            "/usr/local/bin/k78_tablet_sender 1 %d 0 >/dev/null 2>&1 &",
            self.orient
        )
        os.execute(cmd)
    end
end

function K78Screen:sendCmd(ch, val)
    if self.cli then
        pcall(self.cli.send, self.cli, string.char(0x43, ch:byte(1), val or 0, 0))
    end
end

function K78Screen:dropClient()
    if self.cli then
        pcall(self.cli.close, self.cli)
        self.cli = nil
    end
    self.connected = false
    self.peer_ip = nil
    self.rx_chunks = {}
    self.rx_have = 0
    self.rx_hdr = nil
    self.rx_need = 20
    self:stopPenSender()
    if Screen._setWaterfall then Screen:_setWaterfall(false) end
    self:rebuildButtons()
    UIManager:setDirty(self, "full")
end

function K78Screen:rebuildButtons()
    local W = self.dimen.w
    local pad = 10
    local gap = 6
    local r1_h = 74
    local r2_h = 70

    local r1 = {
        { id = "m0",    text = "85Hz Bayer",  active = (self.mode == 0) },
        { id = "m1",    text = "85Hz Texte",  active = (self.mode == 1) },
        { id = "m2",    text = "HQ 16-Gris",  active = (self.mode == 2) },
        { id = "ahq",   text = self.auto_hq and "Auto-HQ: ON" or "Auto-HQ: OFF", active = self.auto_hq },
        { id = "inv",   text = self.invert and "Inversé: ON" or "Inverser", active = self.invert },
        { id = "quit",  text = "✕ QUITTER" },
    }
    local r2 = {
        { id = "ori",   text = "Rot: " .. ORIENT_LABELS[self.orient] },
        { id = "pen",   text = self.cintiq_pen and "Stylet Cintiq: ON" or "Stylet: OFF", active = self.cintiq_pen },
        { id = "flash", text = "⚡ Nettoyer Flash" },
        { id = "usb",   text = "↻ Reset USB" },
        { id = "hide",  text = self.connected and "Masquer HUD" or "Rafraîchir IP" },
    }

    self.hud_h = pad + r1_h + gap + r2_h + pad
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
    layoutRow(r1, pad, r1_h)
    layoutRow(r2, pad + r1_h + gap, r2_h)
end

function K78Screen:hitButton(x, y)
    if self.connected and not self.hud_open then return nil end
    for _, b in ipairs(self.buttons) do
        if inBox(x, y, b) then return b.id end
    end
    return nil
end

function K78Screen:handleButton(id)
    local now = time.now()
    if self._last_btn_t and time.to_ms(now - self._last_btn_t) < 160 then return end
    self._last_btn_t = now

    if id == "m0" then
        self.mode = 0; self:sendCmd("M", 0)
    elseif id == "m1" then
        self.mode = 1; self:sendCmd("M", 1)
    elseif id == "m2" then
        self.mode = 2; self:sendCmd("M", 2)
    elseif id == "ahq" then
        self.auto_hq = not self.auto_hq; self:sendCmd("A", self.auto_hq and 1 or 0)
    elseif id == "inv" then
        self.invert = not self.invert; self:sendCmd("I", self.invert and 1 or 0)
    elseif id == "ori" then
        self.orient = (self.orient == 2) and 1 or ((self.orient == 1) and 0 or 2)
        self:sendCmd("O", self.orient)
        self:syncPenSender()
    elseif id == "pen" then
        self.cintiq_pen = not self.cintiq_pen
        self:syncPenSender()
    elseif id == "flash" then
        if Screen.cleanFlash then Screen:cleanFlash() end
        self:sendCmd("F", 1)
        if self.connected then self.hud_open = false end
        return
    elseif id == "usb" then
        os.execute("/usr/local/bin/k78-usb-reset >/tmp/k78-usb-reset.log 2>&1 &")
    elseif id == "hide" then
        if self.connected then
            self.hud_open = false
            self:sendCmd("F", 0)
            return
        else
            self.wifi_ip = getWifiIP()
        end
    elseif id == "quit" then
        self:onClose()
        return
    end

    self:rebuildButtons()
    UIManager:setDirty(self, "ui")
end

function K78Screen:onToggleHUD()
    if not self.connected then
        return self:onClose()
    end
    if self.hud_open then
        self.hud_open = false
        self:sendCmd("F", 0)
    else
        self.hud_open = true
        self:rebuildButtons()
        UIManager:setDirty(self, "ui")
    end
    return true
end

function K78Screen:onTwoFingerTap()
    return self:onToggleHUD()
end

function K78Screen:inMenuCorner(x, y)
    -- Easy 1-tap [☰] corner pill in top-left (works in both Portrait & Landscape!)
    return x <= 110 and y <= 90
end

function K78Screen:onTap(_, ges)
    local x, y = ges.pos.x, ges.pos.y
    if self.connected and not self.hud_open then
        if self:inMenuCorner(x, y) then
            self:onToggleHUD()
        end
        return true
    end
    local bid = self:hitButton(x, y)
    if bid then self:handleButton(bid) end
    return true
end

function K78Screen:onStylusSlot(slot)
    if self.closed or not slot then return false end
    local x, y = slot.x, slot.y
    if not x or not y or not slot.id or slot.id == -1 then
        self._btn_down = false
        return true
    end
    if self.connected and not self.hud_open then
        if self:inMenuCorner(x, y) and not self._btn_down then
            self._btn_down = true
            self:onToggleHUD()
        end
        return true
    end
    local bid = self:hitButton(x, y)
    if bid then
        if not self._btn_down then
            self._btn_down = true
            self:handleButton(bid)
        end
        return true
    end
    return true
end

function K78Screen:readBytes(want)
    while self.rx_have < want do
        local rem = want - self.rx_have
        local chunk, err, partial = self.cli:receive(rem)
        local got = chunk or partial
        if got and #got > 0 then
            table.insert(self.rx_chunks, got)
            self.rx_have = self.rx_have + #got
        end
        if err == "closed" then
            self:dropClient()
            return nil
        elseif err == "timeout" then
            return nil
        end
    end
    local all = table.concat(self.rx_chunks)
    self.rx_chunks = {}
    self.rx_have = 0
    if #all > want then
        local tail = all:sub(want + 1)
        self.rx_chunks = { tail }
        self.rx_have = #tail
        return all:sub(1, want)
    end
    return all
end

function K78Screen:applyFrame(hdr, payload)
    if not k78s then return end
    local fmt   = hdr.fmt
    local flags = hdr.flags
    local x1, y1, x2, y2 = hdr.x1, hdr.y1, hdr.x2, hdr.y2

    local do_flash = (bit.band(flags, 1) ~= 0)
    local do_wf    = (bit.band(flags, 2) ~= 0)
    local do_xor   = (bit.band(flags, 4) ~= 0) and 1 or 0

    if fmt == 9 then
        if Screen.cleanFlash then Screen:cleanFlash() end
        return
    end

    if y1 < 0 then y1 = 0 end
    if y2 > EBC_H then y2 = EBC_H end
    if y2 <= y1 then return end

    local src = ffi.cast("const uint8_t*", payload)
    local plen = #payload

    if fmt == 1 or fmt == 3 then
        -- 1-bit monochrome (raw or PackBits RLE)
        local off = y1 * ROW_BYTES_1B
        local cap = (y2 - y1) * ROW_BYTES_1B
        if fmt == 3 then
            k78s.k78_packbits_decode(self.state_1b + off, cap, src, plen, do_xor)
        else
            k78s.k78_apply_raw(self.state_1b + off, src, math.min(plen, cap), do_xor)
        end
        k78s.k78_unpack_1bit_to_bb8(Screen.bb.data, self.state_1b, EBC_W, y1, y2)
    elseif fmt == 2 or fmt == 4 then
        -- 4-bit HQ 16-level grayscale (raw or PackBits RLE)
        local off = y1 * ROW_BYTES_4B
        local cap = (y2 - y1) * ROW_BYTES_4B
        if fmt == 4 then
            k78s.k78_packbits_decode(self.state_4b + off, cap, src, plen, do_xor)
        else
            k78s.k78_apply_raw(self.state_4b + off, src, math.min(plen, cap), do_xor)
        end
        k78s.k78_unpack_4bit_to_bb8(Screen.bb.data, self.state_4b, EBC_W, y1, y2)
    else
        return
    end

    -- Re-draw HUD overlay on top if open, else draw subtle [☰] corner pill
    if self.hud_open then
        self:paintHUD(Screen.bb, 0, 0)
    else
        self:paintMenuPill(Screen.bb, 0, 0)
    end

    -- Convert physical EBC rect (x1,y1)-(x2,y2) -> portrait logical rect for Screen:_send()
    local lx = y1
    local ly = EBC_W - x2
    local lw = y2 - y1
    local lh = x2 - x1

    if do_flash then
        Screen:_setWaterfall(false)
        Screen:_send(ebc.EPD_FULL, 0, 0, 0, 0, false)
    elseif do_wf then
        Screen:_setWaterfall(true)
        Screen:_send(ebc.EPD_A2, lx, ly, lw, lh, true)
    else
        Screen:_setWaterfall(false)
        Screen:_send(ebc.EPD_PART, lx, ly, lw, lh, false)
    end
    self.frames = self.frames + 1
end

function K78Screen:pollNetwork()
    -- Accept new PC connection if idle
    if not self.cli and self.srv then
        local c = self.srv:accept()
        if c then
            c:settimeout(0)
            c:setoption("tcp-nodelay", true)
            self.cli = c
            local ip = c:getpeername()
            self.peer_ip = ip
            self.connected = true
            self.hud_open = false
            self.rx_chunks = {}
            self.rx_have = 0
            self.rx_hdr = nil
            self.rx_need = 20
            -- Push current UI prefs immediately to Linux host
            self:sendCmd("M", self.mode)
            self:sendCmd("A", self.auto_hq and 1 or 0)
            self:sendCmd("I", self.invert and 1 or 0)
            self:sendCmd("O", self.orient)
            self:syncPenSender()
        end
    end

    if not self.cli then return end

    -- Process up to 3 queued frames per tick to keep latency zero
    for _ = 1, 3 do
        if not self.cli then break end
        if not self.rx_hdr then
            local hb = self:readBytes(20)
            if not hb then break end
            if hb:sub(1, 4) ~= "K78S" then
                self:dropClient()
                break
            end
            self.rx_hdr = {
                fmt     = hb:byte(5),
                flags   = hb:byte(6),
                x1      = u16le(hb, 7),
                y1      = u16le(hb, 9),
                x2      = u16le(hb, 11),
                y2      = u16le(hb, 13),
                pay_len = u32le(hb, 15),
            }
            if self.rx_hdr.pay_len > 1400000 then
                self:dropClient()
                break
            end
        end

        local hdr = self.rx_hdr
        if hdr.pay_len == 0 then
            self.rx_hdr = nil
            self:applyFrame(hdr, "")
        else
            local pay = self:readBytes(hdr.pay_len)
            if not pay then break end
            self.rx_hdr = nil
            self:applyFrame(hdr, pay)
        end
    end
end

function K78Screen:paintMenuPill(bb, ox, oy)
    bb:paintRect(ox + 6, oy + 6, 78, 52, WHITE)
    bb:paintBorder(ox + 6, oy + 6, 78, 52, 2, BLACK, 6)
    drawTextCentered(bb, self.font_btn, "☰", ox + 6, oy + 6, 78, 52, BLACK)
end

function K78Screen:paintHUD(bb, ox, oy)
    local W = self.dimen.w
    bb:paintRect(ox, oy, W, self.hud_h, WHITE)
    bb:paintRect(ox, oy + self.hud_h - 3, W, 3, BLACK)
    for _, b in ipairs(self.buttons) do
        local bg = b.active and BLACK or GRAY_BG
        local fg = b.active and WHITE or BLACK
        bb:paintBorder(ox + b.x, oy + b.y, b.w, b.h, 2, BLACK, 4)
        bb:paintRect(ox + b.x + 2, oy + b.y + 2, b.w - 4, b.h - 4, bg)
        drawTextCentered(bb, self.font_btn, b.text, ox + b.x, oy + b.y, b.w, b.h, fg)
    end
end

function K78Screen:paintTo(bb, ox, oy)
    if self.connected then
        if self.hud_open then
            self:paintHUD(bb, ox, oy)
        else
            self:paintMenuPill(bb, ox, oy)
        end
        return
    end

    local W, H = self.dimen.w, self.dimen.h
    bb:paintRect(ox, oy, W, H, WHITE)
    self:paintHUD(bb, ox, oy)

    local cy = math.floor(H * 0.44)
    drawTextCentered(bb, self.font_big, "2e ÉCRAN E-INK 85 Hz  /  MINI-CINTIQ", ox + 40, oy + cy - 90, W - 80, 50, BLACK)
    drawTextCentered(bb, self.font_sm,
        string.format("En écoute sur USB 192.168.7.2:%d%s", PORT,
            self.wifi_ip and ("  •  Wi-Fi " .. self.wifi_ip .. ":" .. PORT) or ""),
        ox + 40, oy + cy - 20, W - 80, 40, GRAY_DARK)

    local box_w = W - 180
    local box_x = ox + 90
    local box_y = oy + cy + 45
    bb:paintBorder(box_x, box_y, box_w, 250, 3, BLACK, 8)
    bb:paintRect(box_x + 3, box_y + 3, box_w - 6, 244, GRAY_BG)
    drawTextCentered(bb, self.font_big, "Sur le PC Linux, lance :", box_x, box_y + 24, box_w, 42, BLACK)
    drawTextCentered(bb, self.font_big, "k78-screen", box_x, box_y + 78, box_w, 48, BLACK)
    drawTextCentered(bb, self.font_sm, "(ou icône « Likebook 2e Écran E-Ink » dans le menu KDE)", box_x, box_y + 138, box_w, 34, GRAY_DARK)
    drawTextCentered(bb, self.font_sm, "Une fois connecté : touche le coin [☰] en haut à gauche (ou 2 doigts) pour le HUD", box_x, box_y + 186, box_w, 34, BLACK)

    if not k78s then
        drawTextCentered(bb, self.font_sm, "⚠ libk78stream.so absent dans /opt/koreader/libs/", ox + 40, oy + H - 80, W - 80, 40, BLACK)
    end
end

function K78Screen:onClose()
    if self.closed then return true end
    self.closed = true
    self:sendCmd("Q", 0)
    self:stopPenSender()
    if self.cli then pcall(self.cli.close, self.cli); self.cli = nil end
    if self.srv then pcall(self.srv.close, self.srv); self.srv = nil end
    Device.input:registerStylusCallback(self._prev_stylus_cb)
    if Screen.setK78Mode then
        Screen:setK78Mode(self._saved_k78_mode or "auto")
    elseif Screen._setWaterfall then
        Screen:_setWaterfall(false)
    end
    UIManager:close(self)
    UIManager:setDirty("all", "full")
    return true
end

return function(ui)
    local app = K78Screen:new{}
    UIManager:show(app)
    UIManager:setDirty(app, "full")
end
