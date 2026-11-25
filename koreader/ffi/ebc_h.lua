--[[
ffi/ebc_h.lua — Rockchip RK3368 (Linux 4.4.103 rk_epd) /dev/ebc FFI definitions
for Boyue Likebook Ares Note K78W.

Verified directly against kernel 4.4.103 ebc_io_ctl() disassembly:
  - sizeof(struct ebc_buf_info) == 56 bytes (0x38)
  - pixel buffer is 1 byte/pixel containing 5-bit grayscale in 0..30 (even: (v >> 3) & 0x1e)
    where 0x00 = black and 0x1e (30) = white (kernel LUT is 32x32 = 1024 bytes/frame)
]]--

local ffi = require("ffi")

ffi.cdef[[
struct ebc_buf_info {
    int offset;       // +0x00
    int epd_mode;     // +0x04
    int height;       // +0x08 (1404)
    int width;        // +0x0c (1872)
    int vir_height;   // +0x10 (1404)
    int vir_width;    // +0x14 (1872)
    int fb_width;     // +0x18 (1872)
    int fb_height;    // +0x1c (1404)
    int color_panel;  // +0x20 (0 = monochrome grayscale)
    int win_x1;       // +0x24
    int win_y1;       // +0x28
    int win_x2;       // +0x2c
    int win_y2;       // +0x30
    int rotate;       // +0x34 (90)
};
]]

return {
    -- IOCTL numbers verified in ebc_io_ctl()
    EBC_GET_BUFFER        = 0x7000,
    EBC_SEND_BUFFER       = 0x7001,
    EBC_GET_BUFFER_INFO   = 0x7003,
    EBC_GET_CHIP_ID       = 0x7004,
    EBC_WAKEUP            = 0x7005,
    EBC_DISABLE_A2_FORCE  = 0x7006,  -- clears waterfall flag [x24+0x1c4]=0 and wakes ebc_thread
    EBC_GET_STATUS        = 0x7007,
    EBC_ENABLE_A2_FORCE   = 0x7008,  -- sets waterfall flag [x24+0x1c4]=1 (85Hz A2-Waterfall pipeline)

    -- RK3368 rk_epd modes verified in BOTH epd_task (JT1) and ebc_thread (JT2):
    -- Safe active modes: 1 (FULL), 2 (A2), 3 (PART), 5 (RESET), 6 (A2_ENTER), 15 (FULL_GL16).
    -- WARNING: modes 4, 7, 10, 11, 12 are NOPs in epd_task JT1 and deadlock ebc_thread!
    EPD_AUTO              = 0,
    EPD_FULL              = 1,   -- WF_TYPE_GC16 full flashing refresh
    EPD_A2                = 2,   -- WF_TYPE_A2 fast B&W (auto-enters via mode 6)
    EPD_PART              = 3,   -- WF_TYPE_GC16 partial diff (auto-accels pure B&W to mode 6)
    EPD_RESET             = 5,   -- WF_TYPE_RESET (INIT full clear)
    EPD_A2_ENTER          = 6,   -- WF_TYPE_A2_IN
    EPD_POWER_OFF         = 8,   -- blocking frame wait
    EPD_OVERLAY           = 9,
    EPD_FULL_GL16         = 15,  -- WF_TYPE_GL16 full low-flash grayscale
    EPD_AUTO_FULL         = 17,  -- waterfall auto
    EPD_A2_WATERFALL      = 19,
    EPD_FORCE_FULL        = 21,
}
