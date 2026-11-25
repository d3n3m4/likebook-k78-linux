--[[
K78-BOARD — Tableau Blanc Infini 85 Hz Waterfall -> Export SVG Vectoriel (Obsidian / Inkscape / PC)
Pour Likebook Ares Note K78W Pure Linux.

Ergonomie naturelle :
  • Stylet Wacom EMR : dessine (4096 niveaux de pression + inclinaison calligraphique + flèches/boîtes/gomme)
  • Doigt (tactile)  : glisser = déplacer le tableau infini (zéro trace parasite du doigt !)
  • Export SVG       : génère un fichier SVG vectoriel propre recadré dans /data/sketches/
]]--

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local RenderText = require("ui/rendertext")
local UIManager = require("ui/uimanager")
local time = require("ui/time")

local Screen = Device.screen

local BLACK      = Blitbuffer.COLOR_BLACK
local WHITE      = Blitbuffer.COLOR_WHITE
local GRAY_DARK  = Blitbuffer.Color8(0x40)
local GRAY_MID   = Blitbuffer.Color8(0x88)
local GRAY_LIGHT = Blitbuffer.Color8(0xC8)
local GRAY_BG    = Blitbuffer.Color8(0xEE)

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function inBox(x, y, b)
    return x >= b.x and x <= (b.x + b.w) and y >= b.y and y <= (b.y + b.h)
end

local function drawTextCentered(bb, face, text, rx, ry, rw, rh, color)
    local metrics = RenderText:sizeUtf8Text(0, rw - 6, face, text, true, false)
    local tx = rx + math.max(3, math.floor((rw - metrics.x) / 2))
    local ty = ry + math.floor((rh + face.size * 0.72) / 2)
    RenderText:renderUtf8Text(bb, tx, ty, face, text, true, false, color or BLACK)
end

local function drawDisk(bb, cx, cy, r, col, clip)
    local ir = math.max(1, math.floor(r + 0.5))
    local x1 = math.floor(cx - ir)
    local y1 = math.floor(cy - ir)
    local sz = ir * 2
    if clip then
        if x1 + sz < clip.x or x1 > clip.x + clip.w or y1 + sz < clip.y or y1 > clip.y + clip.h then
            return
        end
        if x1 < clip.x then sz = sz - (clip.x - x1); x1 = clip.x end
        if y1 < clip.y then y1 = clip.y end
        if x1 + sz > clip.x + clip.w then sz = clip.x + clip.w - x1 end
    end
    local h = ir * 2
    if clip and y1 + h > clip.y + clip.h then h = clip.y + clip.h - y1 end
    if sz > 0 and h > 0 then
        bb:paintRect(x1, y1, sz, h, col)
    end
end

local function drawSegment(bb, x0, y0, x1, y1, r, col, clip)
    local dx, dy = x1 - x0, y1 - y0
    local dist = math.sqrt(dx * dx + dy * dy)
    local step = math.max(1.2, r * 0.55)
    local n = math.max(1, math.ceil(dist / step))
    for i = 0, n do
        local t = i / n
        drawDisk(bb, x0 + dx * t, y0 + dy * t, r, col, clip)
    end
end

local function distPointSegSq(px, py, x1, y1, x2, y2)
    local dx, dy = x2 - x1, y2 - y1
    local l2 = dx * dx + dy * dy
    if l2 < 1e-4 then
        local ex, ey = px - x1, py - y1
        return ex * ex + ey * ey
    end
    local t = clamp(((px - x1) * dx + (py - y1) * dy) / l2, 0, 1)
    local nx, ny = x1 + t * dx, y1 + t * dy
    local ex, ey = px - nx, py - ny
    return ex * ex + ey * ey
end

local K78Board = InputContainer:extend{
    name = "k78_board",
    covers_fullscreen = true,
}

function K78Board:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.font_btn = Font:getFace("smallinfofont", 15)
    self.font_sm  = Font:getFace("smallinfofont", 15)

    self.tool = "pen"       -- "pen" | "calli" | "hi" | "arrow" | "rect" | "erase"
    self.width_idx = 2      -- 1=Fin(2), 2=Moyen(4), 3=Épais(8)
    self.widths = { 2.0, 4.2, 8.5 }
    self.width_names = { "Fin", "Moyen", "Épais" }
    self.grid_mode = 1      -- 0=Vide, 1=Points, 2=Carreaux

    -- Infinite camera (world coordinates at canvas center)
    self.cam_x = 0.0
    self.cam_y = 0.0
    self.zoom = 1.0

    self.strokes = {}       -- list of { tool, color_hex, base_w, pts = { {x,y,r}, ... } }
    self.redo_stack = {}
    self.active_stroke = nil
    self.shape_start = nil
    self.shape_cur = nil

    self.status_msg = "Stylet = dessiner (4096 niveaux)  •  Doigt = déplacer le tableau infini"
    self._pan_last = nil
    self._btn_down = false
    self._last_btn_t = nil
    self.closed = false

    os.execute("mkdir -p /data/sketches")
    self:computeLayout()

    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
        Pan = { GestureRange:new{ ges = "pan", range = self.dimen } },
        PanRelease = { GestureRange:new{ ges = "pan_release", range = self.dimen } },
    }
    self.key_events = {
        Close = { { "Back" }, doc = "Quitter Tableau Blanc" },
    }

    self._prev_stylus_cb = Device.input.stylus_callback
    Device.input:registerStylusCallback(function(inp, slot)
        return self:onStylusSlot(slot)
    end)
end

function K78Board:computeLayout()
    local W, H = self.dimen.w, self.dimen.h
    local pad = 8
    local r1_h = 68
    local r2_h = 64
    self.row1_y = pad
    self.row1_h = r1_h
    self.row2_y = self.row1_y + r1_h + 6
    self.row2_h = r2_h
    self.status_y = self.row2_y + r2_h + 4
    local cy = self.status_y + 30
    self.canvas = { x = 0, y = cy, w = W, h = H - cy }
    self:rebuildButtons()
end

function K78Board:rebuildButtons()
    local W = self.dimen.w
    local pad = 8
    local gap = 5

    local r1 = {
        { id = "t_pen",   text = "Stylo",      active = (self.tool == "pen") },
        { id = "t_calli", text = "Plume",      active = (self.tool == "calli") },
        { id = "t_hi",    text = "Surlign.",   active = (self.tool == "hi") },
        { id = "t_arrow", text = "Flèche",     active = (self.tool == "arrow") },
        { id = "t_rect",  text = "Boîte",      active = (self.tool == "rect") },
        { id = "t_erase", text = "Gomme",      active = (self.tool == "erase") },
        { id = "width",   text = "Trait: " .. self.width_names[self.width_idx] },
        { id = "quit",    text = "✕ QUITTER" },
    }
    local gnames = { [0] = "Grille: Off", [1] = "Grille: Pts", [2] = "Grille: Quad" }
    local r2 = {
        { id = "undo",   text = "↶ Annuler" },
        { id = "redo",   text = "↷ Refaire" },
        { id = "zout",   text = "Zoom -" },
        { id = "z100",   text = string.format("%d%% (Centrer)", math.floor(self.zoom * 100 + 0.5)) },
        { id = "zin",    text = "Zoom +" },
        { id = "grid",   text = gnames[self.grid_mode] },
        { id = "clear",  text = "Effacer" },
        { id = "svg",    text = "💾 Export SVG" },
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
end

function K78Board:screenToWorld(sx, sy)
    local c = self.canvas
    local cx = c.x + c.w * 0.5
    local cy = c.y + c.h * 0.5
    return self.cam_x + (sx - cx) / self.zoom, self.cam_y + (sy - cy) / self.zoom
end

function K78Board:worldToScreen(wx, wy)
    local c = self.canvas
    local cx = c.x + c.w * 0.5
    local cy = c.y + c.h * 0.5
    return cx + (wx - self.cam_x) * self.zoom, cy + (wy - self.cam_y) * self.zoom
end

function K78Board:hitButton(x, y)
    for _, b in ipairs(self.buttons) do
        if inBox(x, y, b) then return b.id end
    end
    return nil
end

function K78Board:exportSVG()
    if #self.strokes == 0 then
        self.status_msg = "Rien à exporter : dessine d'abord un croquis !"
        UIManager:setDirty(self, "ui")
        return
    end

    local minx, miny = 1e9, 1e9
    local maxx, maxy = -1e9, -1e9
    for _, st in ipairs(self.strokes) do
        for _, p in ipairs(st.pts) do
            local pad = (p[3] or st.base_w) + 6
            if p[1] - pad < minx then minx = p[1] - pad end
            if p[2] - pad < miny then miny = p[2] - pad end
            if p[1] + pad > maxx then maxx = p[1] + pad end
            if p[2] + pad > maxy then maxy = p[2] + pad end
        end
    end

    local margin = 28
    minx = minx - margin; miny = miny - margin
    maxx = maxx + margin; maxy = maxy + margin
    local vw = math.max(100, maxx - minx)
    local vh = math.max(100, maxy - miny)

    local fname = os.date("/data/sketches/croquis_%Y%m%d_%H%M%S.svg")
    local f = io.open(fname, "w")
    if not f then
        self.status_msg = "Erreur écriture " .. fname
        UIManager:setDirty(self, "ui")
        return
    end

    f:write('<?xml version="1.0" encoding="UTF-8"?>\n')
    f:write(string.format(
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="%.1f %.1f %.1f %.1f" width="%.0f" height="%.0f">\n',
        minx, miny, vw, vh, vw, vh
    ))
    f:write(string.format('  <rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" fill="#ffffff"/>\n', minx, miny, vw, vh))

    for _, st in ipairs(self.strokes) do
        local col = st.color_hex or "#000000"
        local op = (st.tool == "hi") and ' opacity="0.35"' or ""
        if st.tool == "rect" and #st.pts >= 2 then
            local a, b = st.pts[1], st.pts[2]
            local rx, ry = math.min(a[1], b[1]), math.min(a[2], b[2])
            local rw, rh = math.abs(b[1] - a[1]), math.abs(b[2] - a[2])
            f:write(string.format(
                '  <rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" fill="none" stroke="%s" stroke-width="%.1f" stroke-linejoin="round"/>\n',
                rx, ry, rw, rh, col, st.base_w * 2
            ))
        elseif st.tool == "arrow" and #st.pts >= 2 then
            local a, b = st.pts[1], st.pts[2]
            local ang = math.atan2(b[2] - a[2], b[1] - a[1])
            local hl = math.max(16, st.base_w * 5)
            local h1x = b[1] - hl * math.cos(ang - 0.45)
            local h1y = b[2] - hl * math.sin(ang - 0.45)
            local h2x = b[1] - hl * math.cos(ang + 0.45)
            local h2y = b[2] - hl * math.sin(ang + 0.45)
            f:write(string.format(
                '  <path d="M%.1f %.1f L%.1f %.1f M%.1f %.1f L%.1f %.1f L%.1f %.1f" fill="none" stroke="%s" stroke-width="%.1f" stroke-linecap="round" stroke-linejoin="round"/>\n',
                a[1], a[2], b[1], b[2], h1x, h1y, b[1], b[2], h2x, h2y, col, st.base_w * 2
            ))
        elseif #st.pts == 1 then
            local p = st.pts[1]
            f:write(string.format('  <circle cx="%.1f" cy="%.1f" r="%.1f" fill="%s"%s/>\n',
                p[1], p[2], p[3] or st.base_w, col, op))
        elseif #st.pts >= 2 then
            -- Use variable-width smooth segments when pressure varies significantly, else compact polyline
            if st.tool == "pen" or st.tool == "calli" then
                local rsum = 0
                for _, p in ipairs(st.pts) do rsum = rsum + (p[3] or st.base_w) end
                local ravg = rsum / #st.pts
                local parts = {}
                for i, p in ipairs(st.pts) do
                    parts[i] = string.format("%.1f,%.1f", p[1], p[2])
                end
                f:write(string.format(
                    '  <polyline points="%s" fill="none" stroke="%s" stroke-width="%.1f" stroke-linecap="round" stroke-linejoin="round"%s/>\n',
                    table.concat(parts, " "), col, ravg * 2, op
                ))
            else
                local parts = {}
                for i, p in ipairs(st.pts) do
                    parts[i] = string.format("%.1f,%.1f", p[1], p[2])
                end
                f:write(string.format(
                    '  <polyline points="%s" fill="none" stroke="%s" stroke-width="%.1f" stroke-linecap="round" stroke-linejoin="round"%s/>\n',
                    table.concat(parts, " "), col, st.base_w * 2, op
                ))
            end
        end
    end

    f:write("</svg>\n")
    f:close()
    self.status_msg = "Exporté : " .. fname .. string.format(" (%d traits)", #self.strokes)
    UIManager:setDirty(self, "ui")
end

function K78Board:handleButton(id)
    local now = time.now()
    if self._last_btn_t and time.to_ms(now - self._last_btn_t) < 160 then return end
    self._last_btn_t = now

    if id == "t_pen"   then self.tool = "pen"
    elseif id == "t_calli" then self.tool = "calli"
    elseif id == "t_hi"    then self.tool = "hi"
    elseif id == "t_arrow" then self.tool = "arrow"
    elseif id == "t_rect"  then self.tool = "rect"
    elseif id == "t_erase" then self.tool = "erase"
    elseif id == "width"   then self.width_idx = (self.width_idx % #self.widths) + 1
    elseif id == "grid"    then self.grid_mode = (self.grid_mode + 1) % 3
    elseif id == "undo"    then
        if #self.strokes > 0 then
            table.insert(self.redo_stack, table.remove(self.strokes))
        end
    elseif id == "redo"    then
        if #self.redo_stack > 0 then
            table.insert(self.strokes, table.remove(self.redo_stack))
        end
    elseif id == "zout"    then self.zoom = clamp(self.zoom * 0.78, 0.25, 4.0)
    elseif id == "zin"     then self.zoom = clamp(self.zoom * 1.28, 0.25, 4.0)
    elseif id == "z100"    then self.zoom = 1.0; self.cam_x = 0; self.cam_y = 0
    elseif id == "clear"   then
        self.strokes = {}
        self.redo_stack = {}
        self.status_msg = "Tableau effacé"
    elseif id == "svg"     then
        self:exportSVG()
        return
    elseif id == "quit"    then
        self:onClose()
        return
    end

    self:rebuildButtons()
    UIManager:setDirty(self, "ui")
end

function K78Board:eraseAtWorld(wx, wy)
    local rad = (24.0 / self.zoom)
    local r2 = rad * rad
    local removed = false
    for i = #self.strokes, 1, -1 do
        local st = self.strokes[i]
        local hit = false
        if st.tool == "rect" and #st.pts >= 2 then
            local a, b = st.pts[1], st.pts[2]
            local x1, x2 = math.min(a[1], b[1]), math.max(a[1], b[1])
            local y1, y2 = math.min(a[2], b[2]), math.max(a[2], b[2])
            if distPointSegSq(wx, wy, x1, y1, x2, y1) <= r2
                or distPointSegSq(wx, wy, x2, y1, x2, y2) <= r2
                or distPointSegSq(wx, wy, x2, y2, x1, y2) <= r2
                or distPointSegSq(wx, wy, x1, y2, x1, y1) <= r2 then
                hit = true
            end
        elseif #st.pts == 1 then
            local dx, dy = wx - st.pts[1][1], wy - st.pts[1][2]
            if dx * dx + dy * dy <= r2 then hit = true end
        else
            for j = 1, #st.pts - 1 do
                local a, b = st.pts[j], st.pts[j + 1]
                if distPointSegSq(wx, wy, a[1], a[2], b[1], b[2]) <= r2 then
                    hit = true; break
                end
            end
        end
        if hit then
            table.insert(self.redo_stack, table.remove(self.strokes, i))
            removed = true
        end
    end
    if removed then
        UIManager:setDirty(self, "ui")
    end
end

function K78Board:computeRadius()
    local bw = self.widths[self.width_idx]
    local p = Device.wacom_pressure or 0.5
    if self.tool == "hi" then
        return (bw * 3.5) / self.zoom
    elseif self.tool == "calli" then
        local tilt = math.abs(Device.wacom_tilt_x or 0) + math.abs(Device.wacom_tilt_y or 0)
        return (bw * (0.35 + 1.7 * p + 0.9 * tilt)) / self.zoom
    else
        return (bw * (0.35 + 1.35 * p)) / self.zoom
    end
end

function K78Board:onStylusSlot(slot)
    if self.closed or not slot then return false end
    local x, y = slot.x, slot.y

    -- Lift pen -> commit active stroke / shape!
    if not x or not y or not slot.id or slot.id == -1 then
        self._btn_down = false
        if self.active_stroke then
            table.insert(self.strokes, self.active_stroke)
            self.redo_stack = {}
            self.active_stroke = nil
            if Screen._setWaterfall then Screen:_setWaterfall(false) end
        elseif self.shape_start and self.shape_cur then
            table.insert(self.strokes, {
                tool = self.tool,
                color_hex = "#000000",
                base_w = self.widths[self.width_idx] / self.zoom,
                pts = { self.shape_start, self.shape_cur },
            })
            self.redo_stack = {}
            self.shape_start = nil
            self.shape_cur = nil
            UIManager:setDirty(self, "ui")
        end
        return true
    end

    -- Toolbar button click with stylus
    local bid = self:hitButton(x, y)
    if bid and not self.active_stroke and not self.shape_start then
        if not self._btn_down then
            self._btn_down = true
            self:handleButton(bid)
        end
        return true
    end

    if not inBox(x, y, self.canvas) then return true end

    local wx, wy = self:screenToWorld(x, y)

    if self.tool == "erase" then
        self:eraseAtWorld(wx, wy)
        return true
    end

    if self.tool == "arrow" or self.tool == "rect" then
        if not self.shape_start then
            self.shape_start = { wx, wy, self.widths[self.width_idx] / self.zoom }
            self.shape_cur = { wx, wy, self.widths[self.width_idx] / self.zoom }
        else
            self.shape_cur = { wx, wy, self.widths[self.width_idx] / self.zoom }
            -- Fast preview refresh
            self:paintTo(Screen.bb, 0, 0)
            Screen:refreshA2(self.canvas.x, self.canvas.y, self.canvas.w, self.canvas.h)
        end
        return true
    end

    -- Freehand ink (pen / calli / highlighter) -> direct live 85Hz A2-Waterfall draw!
    local r_world = self:computeRadius()
    local r_scr = math.max(1.0, r_world * self.zoom)
    local col = (self.tool == "hi") and GRAY_LIGHT or BLACK

    if not self.active_stroke then
        self.active_stroke = {
            tool = self.tool,
            color_hex = (self.tool == "hi") and "#999999" or "#000000",
            base_w = self.widths[self.width_idx] / self.zoom,
            pts = { { wx, wy, r_world } },
        }
        drawDisk(Screen.bb, x, y, r_scr, col, self.canvas)
        local m = math.ceil(r_scr) + 4
        Screen:refreshA2(x - m, y - m, m * 2, m * 2)
    else
        local pts = self.active_stroke.pts
        local prev = pts[#pts]
        local px, py = self:worldToScreen(prev[1], prev[2])
        local dx, dy = x - px, y - py
        if dx * dx + dy * dy >= 3.0 then
            table.insert(pts, { wx, wy, r_world })
            drawSegment(Screen.bb, px, py, x, y, r_scr, col, self.canvas)
            local m = math.ceil(r_scr) + 6
            local rx = math.floor(math.min(px, x)) - m
            local ry = math.floor(math.min(py, y)) - m
            local rw = math.ceil(math.abs(dx)) + m * 2
            local rh = math.ceil(math.abs(dy)) + m * 2
            Screen:refreshA2(rx, ry, rw, rh)
        end
    end
    return true
end

function K78Board:onTap(_, ges)
    local bid = self:hitButton(ges.pos.x, ges.pos.y)
    if bid then self:handleButton(bid) end
    return true
end

function K78Board:onPan(_, ges)
    local x, y = ges.pos.x, ges.pos.y
    if not self._pan_last then
        local bid = self:hitButton(x, y)
        if bid then self:handleButton(bid); return true end
        if inBox(x, y, self.canvas) then
            self._pan_last = { x = x, y = y }
        end
        return true
    end
    -- Finger drag pans the infinite whiteboard!
    local dx = x - self._pan_last.x
    local dy = y - self._pan_last.y
    if math.abs(dx) + math.abs(dy) >= 8 then
        self.cam_x = self.cam_x - dx / self.zoom
        self.cam_y = self.cam_y - dy / self.zoom
        self._pan_last = { x = x, y = y }
        self:paintTo(Screen.bb, 0, 0)
        Screen:refreshA2(self.canvas.x, self.canvas.y, self.canvas.w, self.canvas.h)
    end
    return true
end

function K78Board:onPanRelease()
    if self._pan_last then
        self._pan_last = nil
        if Screen._setWaterfall then Screen:_setWaterfall(false) end
        UIManager:setDirty(self, "ui")
    end
    return true
end

function K78Board:drawStroke(bb, st, ox, oy)
    local clip = { x = ox + self.canvas.x, y = oy + self.canvas.y, w = self.canvas.w, h = self.canvas.h }
    local col = (st.tool == "hi") and GRAY_LIGHT or BLACK
    if st.tool == "rect" and #st.pts >= 2 then
        local x1, y1 = self:worldToScreen(st.pts[1][1], st.pts[1][2])
        local x2, y2 = self:worldToScreen(st.pts[2][1], st.pts[2][2])
        x1, y1, x2, y2 = x1 + ox, y1 + oy, x2 + ox, y2 + oy
        local r = math.max(1.2, st.base_w * self.zoom)
        drawSegment(bb, x1, y1, x2, y1, r, col, clip)
        drawSegment(bb, x2, y1, x2, y2, r, col, clip)
        drawSegment(bb, x2, y2, x1, y2, r, col, clip)
        drawSegment(bb, x1, y2, x1, y1, r, col, clip)
    elseif st.tool == "arrow" and #st.pts >= 2 then
        local x1, y1 = self:worldToScreen(st.pts[1][1], st.pts[1][2])
        local x2, y2 = self:worldToScreen(st.pts[2][1], st.pts[2][2])
        x1, y1, x2, y2 = x1 + ox, y1 + oy, x2 + ox, y2 + oy
        local r = math.max(1.2, st.base_w * self.zoom)
        drawSegment(bb, x1, y1, x2, y2, r, col, clip)
        local ang = math.atan2(y2 - y1, x2 - x1)
        local hl = math.max(18, r * 5)
        drawSegment(bb, x2, y2, x2 - hl * math.cos(ang - 0.45), y2 - hl * math.sin(ang - 0.45), r, col, clip)
        drawSegment(bb, x2, y2, x2 - hl * math.cos(ang + 0.45), y2 - hl * math.sin(ang + 0.45), r, col, clip)
    elseif #st.pts == 1 then
        local sx, sy = self:worldToScreen(st.pts[1][1], st.pts[1][2])
        drawDisk(bb, sx + ox, sy + oy, math.max(1.0, (st.pts[1][3] or st.base_w) * self.zoom), col, clip)
    else
        for i = 1, #st.pts - 1 do
            local a, b = st.pts[i], st.pts[i + 1]
            local x1, y1 = self:worldToScreen(a[1], a[2])
            local x2, y2 = self:worldToScreen(b[1], b[2])
            local r = math.max(1.0, ((a[3] or st.base_w) + (b[3] or st.base_w)) * 0.5 * self.zoom)
            drawSegment(bb, x1 + ox, y1 + oy, x2 + ox, y2 + oy, r, col, clip)
        end
    end
end

function K78Board:paintTo(bb, ox, oy)
    local W, H = self.dimen.w, self.dimen.h
    bb:paintRect(ox, oy, W, H, WHITE)

    -- Toolbar
    for _, b in ipairs(self.buttons) do
        local bg = b.active and BLACK or GRAY_BG
        local fg = b.active and WHITE or BLACK
        bb:paintBorder(ox + b.x, oy + b.y, b.w, b.h, 2, BLACK, 4)
        bb:paintRect(ox + b.x + 2, oy + b.y + 2, b.w - 4, b.h - 4, bg)
        drawTextCentered(bb, self.font_btn, b.text, ox + b.x, oy + b.y, b.w, b.h, fg)
    end

    local info = string.format("%s  |  Traits: %d  |  Pos: (%.0f, %.0f)",
        self.status_msg, #self.strokes, self.cam_x, self.cam_y)
    RenderText:renderUtf8Text(bb, ox + 12, oy + self.status_y + 20, self.font_sm, info, true, false, GRAY_DARK)

    local c = self.canvas
    bb:paintRect(ox + c.x, oy + c.y - 2, c.w, 2, BLACK)

    -- Background dot/square grid in world space
    if self.grid_mode > 0 then
        local step = 50.0
        local spx = step * self.zoom
        if spx >= 16 then
            local wx0, wy0 = self:screenToWorld(c.x, c.y)
            local wx1, wy1 = self:screenToWorld(c.x + c.w, c.y + c.h)
            local gx0 = math.floor(wx0 / step) * step
            local gy0 = math.floor(wy0 / step) * step
            if self.grid_mode == 1 then
                local gy = gy0
                while gy <= wy1 do
                    local gx = gx0
                    while gx <= wx1 do
                        local sx, sy = self:worldToScreen(gx, gy)
                        if sx >= c.x and sx < c.x + c.w - 3 and sy >= c.y and sy < c.y + c.h - 3 then
                            bb:paintRect(ox + math.floor(sx), oy + math.floor(sy), 3, 3, GRAY_MID)
                        end
                        gx = gx + step
                    end
                    gy = gy + step
                end
            else
                local gx = gx0
                while gx <= wx1 do
                    local sx = math.floor((self:worldToScreen(gx, wy0)))
                    if sx >= c.x and sx < c.x + c.w then
                        bb:paintRect(ox + sx, oy + c.y, 1, c.h, GRAY_LIGHT)
                    end
                    gx = gx + step
                end
                local gy = gy0
                while gy <= wy1 do
                    local _, sy = self:worldToScreen(wx0, gy)
                    sy = math.floor(sy)
                    if sy >= c.y and sy < c.y + c.h then
                        bb:paintRect(ox + c.x, oy + sy, c.w, 1, GRAY_LIGHT)
                    end
                    gy = gy + step
                end
            end
        end
    end

    -- Draw all strokes
    for _, st in ipairs(self.strokes) do
        self:drawStroke(bb, st, ox, oy)
    end
    -- Preview active arrow/rect
    if self.shape_start and self.shape_cur then
        self:drawStroke(bb, {
            tool = self.tool,
            base_w = self.widths[self.width_idx] / self.zoom,
            pts = { self.shape_start, self.shape_cur },
        }, ox, oy)
    end
end

function K78Board:onClose()
    if self.closed then return true end
    self.closed = true
    if Screen._setWaterfall then Screen:_setWaterfall(false) end
    Device.input:registerStylusCallback(self._prev_stylus_cb)
    UIManager:close(self)
    UIManager:setDirty("all", "full")
    return true
end

return function(ui)
    local app = K78Board:new{}
    UIManager:show(app)
    UIManager:setDirty(app, "full")
end
