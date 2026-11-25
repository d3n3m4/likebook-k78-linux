--[[
K78-TABLET — Tablette Graphique Wacom 4096 + Inclinaison + Survol + Trackpad + ExpressKeys
pour piloter un PC Linux (KDE Plasma / GNOME Wayland) depuis le Likebook Ares Note K78W via USB (<1ms) ou Wi-Fi !

Lancé en 1 tap depuis ⊞ Apps Custom (/data/apps/05_tablette_pc.lua).
Requiert k78-tablet-host.service côté PC Linux (UDP 19780).
]]--

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local RenderText = require("ui/rendertext")
local UIManager = require("ui/uimanager")
local socket = require("socket")
local time = require("ui/time")

local Screen = Device.screen

local PORT = 19780
local LOCAL_BRIDGE_PORT = 19783
local DEFAULT_WIFI_IP = "192.168.1.100"

local BLACK      = Blitbuffer.COLOR_BLACK
local WHITE      = Blitbuffer.COLOR_WHITE
local GRAY_DARK  = Blitbuffer.Color8(0x40)
local GRAY_MID   = Blitbuffer.Color8(0x90)
local GRAY_LIGHT = Blitbuffer.Color8(0xD8)
local GRAY_BG    = Blitbuffer.Color8(0xF0)

-- Linux input-event-codes.h keycodes (for ExpressKeys)
local MOD_CTRL  = 0x01
local MOD_SHIFT = 0x02
local MOD_ALT   = 0x04
local MOD_META  = 0x08

local K_MINUS     = 74  -- KEY_KPMINUS (universel AZERTY/QWERTY pour Ctrl+-)
local K_EQUAL     = 78  -- KEY_KPPLUS  (universel AZERTY/QWERTY pour Ctrl++)
local K_E         = 18
local K_Y         = 21
local K_Z         = 17  -- KEY_W physique = 'Z' sur clavier français AZERTY (XKBLAYOUT=fr)
local K_C         = 46
local K_V         = 47
local K_B         = 48
local K_SPACE     = 57
local K_LEFT      = 105
local K_RIGHT     = 106
local K_META      = 125
local K_PLAYPAUSE = 164

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function inBox(x, y, b)
    return x >= b.x and x <= (b.x + b.w) and y >= b.y and y <= (b.y + b.h)
end

local function pack_u16(v)
    v = v % 65536
    return string.char(v % 256, math.floor(v / 256))
end

local function pack_i16(v)
    if v < 0 then v = 65536 + v end
    return pack_u16(clamp(math.floor(v + 0.5), 0, 65535))
end

local function detectUsbHostIP()
    local f = io.open("/tmp/dnsmasq.leases", "r")
    if f then
        local last_ip = nil
        for line in f:lines() do
            local ip = line:match("^%d+%s+%S+%s+(%d+%.%d+%.%d+%.%d+)")
            if ip then last_ip = ip end
        end
        f:close()
        if last_ip then return last_ip end
    end
    return "192.168.7.10"
end

local function drawTextCentered(bb, face, text, rx, ry, rw, rh, color)
    local metrics = RenderText:sizeUtf8Text(0, rw - 6, face, text, true, false)
    local tx = rx + math.max(3, math.floor((rw - metrics.x) / 2))
    local ty = ry + math.floor((rh + face.size * 0.72) / 2)
    RenderText:renderUtf8Text(bb, tx, ty, face, text, true, false, color or BLACK)
end

local K78Tablet = InputContainer:extend{
    name = "k78_tablet",
    covers_fullscreen = true,
}

function K78Tablet:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.font_btn = Font:getFace("smallinfofont", 16)
    self.font_sm  = Font:getFace("smallinfofont", 15)
    self.font_big = Font:getFace("smallinfofont", 22)

    self.mode = "wacom"      -- "wacom" | "trackpad"
    self.landscape = true    -- true = Intuos Pro landscape (turn 90° CCW, ExpressKeys on left!)
    self.use_wifi = false
    self.usb_ip = detectUsbHostIP()
    self.wifi_ip = DEFAULT_WIFI_IP
    self.target_ip = self.usb_ip
    self.connected = false
    self.space_held = false
    self._last_btn_t = nil
    self._tp_last = nil
    self._tp_scroll_acc = 0
    self.closed = false

    self.udp = socket.udp()
    self.udp:setsockname("0.0.0.0", 0)
    self.udp:settimeout(0.15)

    self:computeLayout()

    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
        Pan = { GestureRange:new{ ges = "pan", range = self.dimen } },
        PanRelease = { GestureRange:new{ ges = "pan_release", range = self.dimen } },
        TwoFingerTap = { GestureRange:new{ ges = "two_finger_tap", range = self.dimen } },
    }
    self.key_events = {
        Close = { { "Back" }, doc = "Quitter Tablette PC" },
    }

    -- Swallow Wacom events in active pad (k78_tablet_sender streams raw 120Hz directly!)
    -- and handle ExpressKey clicks reliably with Wacom pen!
    self._prev_stylus_cb = Device.input.stylus_callback
    Device.input:registerStylusCallback(function(inp, slot)
        return self:onStylusSlot(slot)
    end)

    self:startBridge()
    self:pingHost()

    -- Auto-check connection every 1s so "● CONNECTÉ" appears automatically!
    self._poll_fn = function()
        if not self.closed then
            local was = self.connected
            self:pingHost()
            if self.connected ~= was then
                self:rebuildButtons()
                UIManager:setDirty(self, "ui")
            end
            UIManager:scheduleIn(self.connected and 2.5 or 0.9, self._poll_fn)
        end
    end
    UIManager:scheduleIn(0.6, self._poll_fn)
end

function K78Tablet:computeLayout()
    local W, H = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = W, h = H }
    local pad = 10
    local r1_h = 74
    local r2_h = 70
    local r3_h = 70

    self.row1_y = pad
    self.row1_h = r1_h
    self.row2_y = self.row1_y + r1_h + 6
    self.row2_h = r2_h
    self.row3_y = self.row2_y + r2_h + 6
    self.row3_h = r3_h

    local status_y = self.row3_y + r3_h + 8
    self.status_y = status_y
    local pad_y = status_y + 38
    self.pad_box = { x = pad, y = pad_y, w = W - 2 * pad, h = H - pad_y - pad }
    self.scroll_w = 130
    self.pad_ymin_permille = math.floor((pad_y * 1000) / H)

    self:rebuildButtons()
end

function K78Tablet:rebuildButtons()
    local W = self.dimen.w
    local pad = 10
    local gap = 6

    local r1 = {
        { id = "m_wacom", text = "TABLETTE WACOM", active = (self.mode == "wacom") },
        { id = "m_track", text = "TRACKPAD",       active = (self.mode == "trackpad") },
        { id = "orient",  text = self.landscape and "PAYSAGE" or "PORTRAIT", active = self.landscape },
        { id = "net",     text = self.use_wifi and ("WI-FI " .. self.wifi_ip) or ("USB " .. self.usb_ip) },
        { id = "usb",     text = "↻ USB" },
        { id = "ping",    text = self.connected and "● CONNECTÉ" or "○ TESTER" },
        { id = "quit",    text = "✕ QUITTER" },
    }
    local r2 = {
        { id = "k_undo",  text = "Annuler (Z)" },
        { id = "k_redo",  text = "Refaire (Y)" },
        { id = "k_space", text = self.space_held and "ESPACE [ACTIF]" or "Espace (Pan)", active = self.space_held },
        { id = "k_brush", text = "Brosse (B)" },
        { id = "k_erase", text = "Gomme (E)" },
        { id = "k_zout",  text = "Zoom -" },
        { id = "k_zin",   text = "Zoom +" },
    }
    local r3 = {
        { id = "k_dleft",  text = "← Bureau" },
        { id = "k_dright", text = "Bureau →" },
        { id = "k_meta",   text = "Menu KDE" },
        { id = "k_copy",   text = "Copier" },
        { id = "k_paste",  text = "Coller" },
        { id = "m_rclick", text = "Clic Droit" },
        { id = "k_play",   text = "⏯ Média" },
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
    layoutRow(r1, self.row1_y, self.row1_h)
    layoutRow(r2, self.row2_y, self.row2_h)
    layoutRow(r3, self.row3_y, self.row3_h)
end

function K78Tablet:sendUDP(pkt)
    if not self.udp then return end
    if self.use_wifi then
        pcall(self.udp.sendto, self.udp, pkt, self.wifi_ip, PORT)
    else
        -- USB mode: send via local k78_tablet_sender TCP 19782 bridge (zero ufw needed on PC!)
        pcall(self.udp.sendto, self.udp, pkt, "127.0.0.1", LOCAL_BRIDGE_PORT)
    end
end

function K78Tablet:pingHost()
    self.connected = false
    if not self.udp then return end
    -- Drain any stale reply (bounded + guards against empty string)
    self.udp:settimeout(0)
    for _ = 1, 8 do
        local d = self.udp:receive()
        if not d or #d == 0 then break end
    end
    self.udp:settimeout(0.12)
    self:sendUDP("K\004")
    local reply = self.udp:receive()
    if reply == "KPONG" then
        self.connected = true
    end
end

function K78Tablet:sendKey(mods, keycode, action)
    -- Packet type 3: <BBBHB
    local pkt = string.char(0x4B, 3, mods or 0) .. pack_u16(keycode) .. string.char(action or 2)
    self:sendUDP(pkt)
end

function K78Tablet:sendMouse(dx, dy, wv, wh, bmask)
    -- Packet type 2: <BBhhhhB
    local pkt = string.char(0x4B, 2)
        .. pack_i16(dx or 0) .. pack_i16(dy or 0)
        .. pack_i16(wv or 0) .. pack_i16(wh or 0)
        .. string.char(bmask or 0)
    self:sendUDP(pkt)
end

function K78Tablet:stopSender()
    os.execute("killall k78_tablet_sender 2>/dev/null || true")
end

function K78Tablet:startBridge()
    self:stopSender()
    if not self.closed then
        local cmd = string.format(
            "/usr/local/bin/k78_tablet_sender %d %d %d >/dev/null 2>&1 &",
            (self.mode == "wacom") and 1 or 0,
            self.landscape and 1 or 0,
            self.pad_ymin_permille
        )
        os.execute(cmd)
    end
end

function K78Tablet:syncSender()
    -- Update wacom_en & orient live via local bridge without dropping TCP connection!
    if self.udp then
        local cfg = string.char(0x4B, 5, (self.mode == "wacom") and 1 or 0, self.landscape and 1 or 0)
        pcall(self.udp.sendto, self.udp, cfg, "127.0.0.1", LOCAL_BRIDGE_PORT)
    end
end

function K78Tablet:handleButton(id)
    local now = time.now()
    if self._last_btn_t and time.to_ms(now - self._last_btn_t) < 160 then return end
    self._last_btn_t = now

    if id == "m_wacom" then
        self.mode = "wacom"; self:syncSender()
    elseif id == "m_track" then
        self.mode = "trackpad"; self:syncSender()
    elseif id == "orient" then
        self.landscape = not self.landscape; self:syncSender()
    elseif id == "net" then
        self.use_wifi = not self.use_wifi
        self.usb_ip = detectUsbHostIP()
        self.target_ip = self.use_wifi and self.wifi_ip or self.usb_ip
        self:pingHost()
        self:syncSender()
    elseif id == "usb" then
        os.execute("/usr/local/bin/k78-usb-reset >/tmp/k78-usb-reset.log 2>&1 &")
    elseif id == "ping" then
        self.usb_ip = detectUsbHostIP()
        if not self.use_wifi then self.target_ip = self.usb_ip end
        self:pingHost()
        self:syncSender()
    elseif id == "quit" then
        self:onClose(); return
    -- ExpressKeys
    elseif id == "k_undo"   then self:sendKey(MOD_CTRL, K_Z, 2); return
    elseif id == "k_redo"   then self:sendKey(MOD_CTRL + MOD_SHIFT, K_Z, 2); return
    elseif id == "k_space"  then
        self.space_held = not self.space_held
        self:sendKey(0, K_SPACE, self.space_held and 1 or 0)
    elseif id == "k_brush"  then self:sendKey(0, K_B, 2); return
    elseif id == "k_erase"  then self:sendKey(0, K_E, 2); return
    elseif id == "k_zout"   then self:sendKey(MOD_CTRL, K_MINUS, 2); return
    elseif id == "k_zin"    then self:sendKey(MOD_CTRL, K_EQUAL, 2); return
    elseif id == "k_dleft"  then self:sendKey(MOD_CTRL + MOD_META, K_LEFT, 2); return
    elseif id == "k_dright" then self:sendKey(MOD_CTRL + MOD_META, K_RIGHT, 2); return
    elseif id == "k_meta"   then self:sendKey(0, K_META, 2); return
    elseif id == "k_copy"   then self:sendKey(MOD_CTRL, K_C, 2); return
    elseif id == "k_paste"  then self:sendKey(MOD_CTRL, K_V, 2); return
    elseif id == "k_play"   then self:sendKey(0, K_PLAYPAUSE, 2); return
    elseif id == "m_rclick" then
        self:sendMouse(0, 0, 0, 0, 2)
        self:sendMouse(0, 0, 0, 0, 0)
        return
    end

    self:rebuildButtons()
    UIManager:setDirty(self, "ui")
end

function K78Tablet:hitButton(x, y)
    for _, b in ipairs(self.buttons) do
        if inBox(x, y, b) then return b.id end
    end
    return nil
end

function K78Tablet:onStylusSlot(slot)
    if self.closed or not slot then return false end
    local x, y = slot.x, slot.y
    if not x or not y then
        self._btn_down = false
        self._tp_last = nil
        return true
    end

    -- Lift / hover
    if not slot.id or slot.id == -1 then
        self._btn_down = false
        self._tp_last = nil
        -- In Wacom mode, k78_tablet_sender already streams raw hover directly! Swallow so KOReader ignores.
        return true
    end

    -- Stylus touch on ExpressKey / Mode button!
    local bid = self:hitButton(x, y)
    if bid then
        if not self._btn_down then
            self._btn_down = true
            self:handleButton(bid)
        end
        return true
    end

    -- In Trackpad mode, allow stylus drag to move relative cursor too!
    if self.mode == "trackpad" and inBox(x, y, self.pad_box) then
        self:trackpadMove(x, y)
        return true
    end
    return true
end

function K78Tablet:trackpadMove(x, y)
    local pb = self.pad_box
    local is_scroll = (x >= pb.x + pb.w - self.scroll_w)
    if self._tp_last then
        local dx = x - self._tp_last.x
        local dy = y - self._tp_last.y
        if is_scroll then
            self._tp_scroll_acc = self._tp_scroll_acc + dy
            if math.abs(self._tp_scroll_acc) >= 35 then
                local step = (self._tp_scroll_acc > 0) and -1 or 1
                self._tp_scroll_acc = 0
                self:sendMouse(0, 0, step, 0, 0)
            end
        else
            local mx, my
            if self.landscape then
                -- Rotate 90° CCW to match landscape orientation!
                mx = math.floor(dy * 1.55)
                my = math.floor(-dx * 1.55)
            else
                mx = math.floor(dx * 1.55)
                my = math.floor(dy * 1.55)
            end
            if mx ~= 0 or my ~= 0 then
                self:sendMouse(mx, my, 0, 0, 0)
            end
        end
    end
    self._tp_last = { x = x, y = y }
end

function K78Tablet:onTap(_, ges)
    local x, y = ges.pos.x, ges.pos.y
    local bid = self:hitButton(x, y)
    if bid then self:handleButton(bid); return true end
    if self.mode == "trackpad" and inBox(x, y, self.pad_box) then
        -- Left click on tap!
        self:sendMouse(0, 0, 0, 0, 1)
        self:sendMouse(0, 0, 0, 0, 0)
    end
    return true
end

function K78Tablet:onTwoFingerTap()
    if self.mode == "trackpad" then
        self:sendMouse(0, 0, 0, 0, 2)
        self:sendMouse(0, 0, 0, 0, 0)
    end
    return true
end

function K78Tablet:onPan(_, ges)
    local x, y = ges.pos.x, ges.pos.y
    if not self._tp_last then
        local bid = self:hitButton(x, y)
        if bid then self:handleButton(bid); return true end
    end
    if self.mode == "trackpad" and inBox(x, y, self.pad_box) then
        self:trackpadMove(x, y)
    end
    return true
end

function K78Tablet:onPanRelease()
    self._tp_last = nil
    self._tp_scroll_acc = 0
    return true
end

function K78Tablet:paintTo(bb, ox, oy)
    local W, H = self.dimen.w, self.dimen.h
    bb:paintRect(ox, oy, W, H, WHITE)

    for _, b in ipairs(self.buttons) do
        local bg = b.active and BLACK or GRAY_BG
        local fg = b.active and WHITE or BLACK
        bb:paintBorder(ox + b.x, oy + b.y, b.w, b.h, 2, BLACK, 4)
        bb:paintRect(ox + b.x + 2, oy + b.y + 2, b.w - 4, b.h - 4, bg)
        drawTextCentered(bb, self.font_btn, b.text, ox + b.x, oy + b.y, b.w, b.h, fg)
    end

    local st_txt = string.format(
        "%s  |  Cible : %s:%d  |  %s",
        self.connected and "● PC LINUX CONNECTÉ" or "○ EN ATTENTE DU PC LINUX (vérifie USB/Wi-Fi)",
        self.target_ip, PORT,
        self.mode == "wacom"
            and (self.landscape and "Wacom 4096 + Inclinaison + Survol (tiens en PAYSAGE, boutons à gauche)"
                                or  "Wacom 4096 + Inclinaison + Survol (PORTRAIT)")
            or "Trackpad multipoint (1 doigt = curseur/clic, 2 doigts = clic droit, bord droit = molette)"
    )
    RenderText:renderUtf8Text(bb, ox + 14, oy + self.status_y + 24, self.font_sm, st_txt, true, false, BLACK)

    local pb = self.pad_box
    bb:paintRect(ox + pb.x, oy + pb.y, pb.w, pb.h, WHITE)
    bb:paintBorder(ox + pb.x, oy + pb.y, pb.w, pb.h, 3, BLACK, 0)

    -- Subtle corner crop marks for a clean, distraction-free Wacom Intuos surface
    local cm = 36
    local x1, y1 = ox + pb.x + 18, oy + pb.y + 18
    local x2, y2 = ox + pb.x + pb.w - 18, oy + pb.y + pb.h - 18
    bb:paintRect(x1, y1, cm, 3, GRAY_DARK); bb:paintRect(x1, y1, 3, cm, GRAY_DARK)
    bb:paintRect(x2 - cm, y1, cm, 3, GRAY_DARK); bb:paintRect(x2 - 3, y1, 3, cm, GRAY_DARK)
    bb:paintRect(x1, y2 - 3, cm, 3, GRAY_DARK); bb:paintRect(x1, y2 - cm, 3, cm, GRAY_DARK)
    bb:paintRect(x2 - cm, y2 - 3, cm, 3, GRAY_DARK); bb:paintRect(x2 - 3, y2 - cm, 3, cm, GRAY_DARK)

    if self.mode == "wacom" then
        drawTextCentered(bb, self.font_big,
            self.landscape and "SURFACE WACOM PAYSAGE (4096 niveaux • Inclinaison • Survol)"
                           or  "SURFACE WACOM PORTRAIT (4096 niveaux • Inclinaison • Survol)",
            ox + pb.x, oy + pb.y + math.floor(pb.h / 2) - 40, pb.w, 50, GRAY_MID)
        drawTextCentered(bb, self.font_sm,
            self.landscape and "Tourne ton Likebook à 90° (boutons ExpressKeys à gauche, stylet à droite)"
                           or  "Survole au stylet pour déplacer le curseur • Appuie pour cliquer / dessiner",
            ox + pb.x, oy + pb.y + math.floor(pb.h / 2) + 18, pb.w, 40, GRAY_MID)
    else
        -- Right-edge scroll wheel zone
        local sx = ox + pb.x + pb.w - self.scroll_w
        bb:paintRect(sx, oy + pb.y + 3, 2, pb.h - 6, GRAY_MID)
        bb:paintRect(sx + 2, oy + pb.y + 3, self.scroll_w - 5, pb.h - 6, GRAY_BG)
        drawTextCentered(bb, self.font_sm, "MOLETTE", sx, oy + pb.y + math.floor(pb.h / 2) - 20, self.scroll_w, 40, GRAY_DARK)
        drawTextCentered(bb, self.font_big, "TRACKPAD PC LINUX",
            ox + pb.x, oy + pb.y + math.floor(pb.h / 2) - 35, pb.w - self.scroll_w, 50, GRAY_MID)
        drawTextCentered(bb, self.font_sm, "Glisser = curseur  •  1 tap = clic gauche  •  2 doigts = clic droit",
            ox + pb.x, oy + pb.y + math.floor(pb.h / 2) + 20, pb.w - self.scroll_w, 40, GRAY_MID)
    end
end

function K78Tablet:onClose()
    if self.closed then return true end
    self.closed = true
    self:stopSender()
    if self.space_held then
        self:sendKey(0, K_SPACE, 0)
        self.space_held = false
    end
    Device.input:registerStylusCallback(self._prev_stylus_cb)
    if self.udp then
        pcall(self.udp.close, self.udp)
        self.udp = nil
    end
    UIManager:close(self)
    UIManager:setDirty("all", "full")
    return true
end

return function(ui)
    local app = K78Tablet:new{}
    UIManager:show(app)
    UIManager:setDirty(app, "full")
end
