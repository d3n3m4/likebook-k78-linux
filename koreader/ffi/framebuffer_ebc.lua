--[[
ffi/framebuffer_ebc.lua — Native Rockchip RK3368 /dev/ebc framebuffer for Likebook Ares K78W.

Hardware capabilities:
  - 1872x1404 landscape, 1 byte/pixel, 5-bit even grayscale 0x00..0x1e (0x00=black, 0x1e=white).
  - NEON-accelerated converter (libs/libk78ebc.so: ~2 ms full screen vs ~26 ms in LuaJIT).
  - Upright portrait via self.bb:rotate(90) matching K78W physical rotate=90.
  - Three selectable refresh modes (k78_mode):
      "auto"      : GC16 for reading/UI, EPD_A2 for single fast taps, automatic hardware
                    A2-Waterfall 85Hz (ioctl 0x7008/0x7006) during continuous stylus drawing
                    or scrolling, returning cleanly to GC16 as soon as the pen lifts.
      "waterfall" : Keeps hardware A2-Waterfall 85Hz active for ultra-fast PDF/notes.
      "hq"        : Pure 16-level GC16 for maximum image/manga fidelity.
]]--

local ffi = require("ffi")
local bit = require("bit")
local band, rshift = bit.band, bit.rshift
local BB = require("ffi/blitbuffer")
local C = ffi.C
require("ffi/posix_h")
local ebc = require("ffi/ebc_h")
local framebuffer = require("ffi/framebuffer")
local time = require("ui/time")

-- Load freestanding AArch64 NEON blitter if present
ffi.cdef[[
void bb8_to_ebc5(void *dst, const void *src, size_t n);
]]
local ok_neon, k78neon = pcall(ffi.load, "libs/libk78ebc.so")
if not ok_neon then k78neon = nil end

local O_RDWR     = 2
local PROT_READ  = 1
local PROT_WRITE = 2
local MAP_SHARED = 1
local MAP_FAILED = ffi.cast("void*", -1)

local BUF_COUNT = 4
local AUTO_WF_WINDOW_MS = 350

local fb = framebuffer:extend{
    fd = -1,
    native_w = 1872,
    native_h = 1404,
    mmap_addr = nil,
    mmap_len = 0,
    buf_info = nil,
    is_always_portrait = false,
    first_refresh = true,
    k78_mode = "auto",        -- "auto" | "waterfall" | "hq"
    _wf_active = false,
    _last_fast_t = nil,
}

function fb:init()
    self.fd = C.open("/dev/ebc", O_RDWR)
    assert(self.fd >= 0, "framebuffer_ebc: cannot open /dev/ebc")

    self.buf_info = ffi.new("struct ebc_buf_info")
    -- Query geometry via EBC_GET_BUFFER_INFO (0x7003) without checking out a slot
    if C.ioctl(self.fd, ebc.EBC_GET_BUFFER_INFO, self.buf_info) >= 0 then
        if self.buf_info.width > 0 and self.buf_info.height > 0 then
            self.native_w = self.buf_info.width
            self.native_h = self.buf_info.height
        end
    end

    self.mmap_len = BUF_COUNT * self.native_w * self.native_h
    self.mmap_addr = C.mmap(nil, self.mmap_len, PROT_READ + PROT_WRITE, MAP_SHARED, self.fd, 0)
    assert(self.mmap_addr ~= MAP_FAILED, "framebuffer_ebc: mmap failed")

    -- Ensure waterfall flag starts clean
    C.ioctl(self.fd, ebc.EBC_DISABLE_A2_FORCE, nil)
    self._wf_active = false

    if G_reader_settings then
        local saved = G_reader_settings:readSetting("k78_eink_mode")
        if saved == "auto" or saved == "waterfall" or saved == "hq" then
            self.k78_mode = saved
        end
    end

    self.bb = BB.new(self.native_w, self.native_h, BB.TYPE_BB8)
    self.bb:fill(BB.COLOR_WHITE)
    -- K78W physical rotate=90: rotate(+90) (enum 1) renders portrait 1404x1872 upright
    self.bb:rotate(90)

    framebuffer.init(self)
end

function fb:_setWaterfall(enable)
    if self.fd < 0 then return end
    if enable and not self._wf_active then
        C.ioctl(self.fd, ebc.EBC_ENABLE_A2_FORCE, nil)
        self._wf_active = true
    elseif not enable and self._wf_active then
        C.ioctl(self.fd, ebc.EBC_DISABLE_A2_FORCE, nil)
        self._wf_active = false
    end
end

function fb:getK78Mode()
    return self.k78_mode or "auto"
end

function fb:setK78Mode(mode)
    if mode ~= "auto" and mode ~= "waterfall" and mode ~= "hq" then return end
    self.k78_mode = mode
    if G_reader_settings then
        G_reader_settings:saveSetting("k78_eink_mode", mode)
    end
    if mode == "waterfall" then
        self:_setWaterfall(true)
    else
        self:_setWaterfall(false)
    end
end

function fb:cleanFlash()
    local was_wf = self.k78_mode == "waterfall"
    self:_setWaterfall(false)
    self:_send(ebc.EPD_FULL, 0, 0, 0, 0, false)
    if was_wf then
        self:_setWaterfall(true)
    end
end

function fb:prepareSuspend()
    self:_setWaterfall(false)
end

local function blit_bb8_to_ebc5(dst_ptr, src_ptr, num_pixels)
    if k78neon then
        k78neon.bb8_to_ebc5(dst_ptr, src_ptr, num_pixels)
        return
    end
    local dst32 = ffi.cast("uint32_t*", dst_ptr)
    local src32 = ffi.cast("const uint32_t*", src_ptr)
    local n32 = rshift(num_pixels, 2)
    for i = 0, n32 - 1 do
        dst32[i] = band(rshift(src32[i], 3), 0x1e1e1e1e)
    end
end

function fb:_send(epd_mode, x, y, w, h, non_blocking)
    if self.fd < 0 or not self.mmap_addr then return end
    local info = self.buf_info
    local nw, nh = self.native_w, self.native_h

    -- Acquire a free rotating slot; for fast/pen frames never stall the input loop
    local got = false
    local tries = non_blocking and 2 or 8
    local delay_us = non_blocking and 2000 or 15000
    for i = 1, tries do
        if C.ioctl(self.fd, ebc.EBC_GET_BUFFER, info) >= 0 and info.offset >= 0 then
            got = true
            break
        end
        if i < tries then C.usleep(delay_us) end
    end
    if not got then return end

    -- Force first frame after launch to full flashing GC16 to clear boot splash
    if self.first_refresh then
        self.first_refresh = false
        self:_setWaterfall(false)
        epd_mode = ebc.EPD_FULL
        x, y, w, h = nil, nil, nil, nil
    end

    local hwptr = ffi.cast("uint8_t*", self.mmap_addr) + info.offset
    blit_bb8_to_ebc5(hwptr, self.bb.data, nw * nh)

    info.epd_mode = epd_mode
    info.color_panel = 0
    if epd_mode == ebc.EPD_FULL or epd_mode == ebc.EPD_RESET or epd_mode == ebc.EPD_FULL_GL16
        or not x or not y or not w or not h or w <= 0 or h <= 0 then
        info.win_x1, info.win_y1, info.win_x2, info.win_y2 = 0, 0, nw, nh
    else
        local px, py, pw, ph = self.bb:getPhysicalRect(x, y, w, h)
        local x1 = math.max(0, math.floor(px / 4) * 4)
        local y1 = math.max(0, math.floor(py / 4) * 4)
        local x2 = math.min(nw, math.ceil((px + pw) / 4) * 4)
        local y2 = math.min(nh, math.ceil((py + ph) / 4) * 4)
        if x2 <= x1 or y2 <= y1 then
            info.win_x1, info.win_y1, info.win_x2, info.win_y2 = 0, 0, nw, nh
        else
            info.win_x1, info.win_y1, info.win_x2, info.win_y2 = x1, y1, x2, y2
        end
    end

    C.ioctl(self.fd, ebc.EBC_SEND_BUFFER, info)
end

function fb:_sendFull()
    local was_wf = self.k78_mode == "waterfall"
    self:_setWaterfall(false)
    self:_send(ebc.EPD_FULL, 0, 0, 0, 0, false)
    if was_wf then
        self:_setWaterfall(true)
    end
end

function fb:_sendPartial(x, y, w, h)
    if self.k78_mode == "waterfall" then
        self:_setWaterfall(true)
        self:_send(ebc.EPD_A2, x, y, w, h, true)
    else
        self:_setWaterfall(false)
        self:_send(ebc.EPD_PART, x, y, w, h, false)
    end
end

function fb:_sendFast(x, y, w, h)
    if self.k78_mode == "hq" then
        self:_setWaterfall(false)
        self:_send(ebc.EPD_PART, x, y, w, h, false)
        return
    end
    local now = time.now()
    if self.k78_mode == "waterfall" then
        self:_setWaterfall(true)
    elseif self._last_fast_t and time.to_ms(now - self._last_fast_t) <= AUTO_WF_WINDOW_MS then
        -- Continuous stylus drawing or scrolling detected -> engage 85Hz A2-Waterfall!
        self:_setWaterfall(true)
    end
    self._last_fast_t = now
    self:_send(ebc.EPD_A2, x, y, w, h, true)
end

function fb:refreshFullImp(x, y, w, h)         self:_sendFull() end
function fb:refreshFlashPartialImp(x, y, w, h) self:_sendFull() end
function fb:refreshFlashUIImp(x, y, w, h)      self:_sendFull() end
function fb:refreshPartialImp(x, y, w, h)      self:_sendPartial(x, y, w, h) end
function fb:refreshUIImp(x, y, w, h)           self:_sendPartial(x, y, w, h) end
function fb:refreshFastImp(x, y, w, h)         self:_sendFast(x, y, w, h) end
function fb:refreshA2Imp(x, y, w, h)           self:_sendFast(x, y, w, h) end

function fb:close()
    self:_setWaterfall(false)
    if self.mmap_addr and self.mmap_addr ~= MAP_FAILED then
        C.munmap(self.mmap_addr, self.mmap_len)
        self.mmap_addr = nil
        self.mmap_len = 0
    end
    if self.fd and self.fd >= 0 then
        C.close(self.fd)
        self.fd = -1
    end
end

return fb
