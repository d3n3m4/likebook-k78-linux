# Hardware Map & Rockchip RK3368 `/dev/ebc` Driver Specification

Technical reference for the **Boyue Likebook Ares Note K78 / K78W** running Pure Linux on top of the stock Rockchip Linux 4.4.103 (`aarch64`) kernel.

---

## 1. Hardware Summary

| Subsystem | Component / Interface | Notes |
|---|---|---|
| SoC | **Rockchip RK3368** (8× Cortex-A53, 2 clusters) | 2 GiB RAM, USB OTG (`dwc_otg` configfs RNDIS) |
| Display | 7.8" E-Ink Carta, **1872 × 1404** native landscape (`226 DPI`) | Physical portrait via 90° rotation (`1404 × 1872`), `/dev/ebc` |
| Stylus | **Wacom EMR** (`/dev/input/event0`) | 4096 pressure levels, hover distance (`0..255`), X/Y tilt, eraser; raw axis `11864 × 15818` |
| Capacitive Touch | Cypress `cyttsp5` (`/dev/input/event1`) | Multi-touch, raw axis `1403 × 1871` |
| Buttons | Power / Back / Keys (`/dev/input/event2`, `/dev/input/event4`) | Back capacitive key + side power key |
| Dual Frontlight | Cold + Warm PWM backlight | `/sys/class/backlight/rk28_bl/brightness` and `rk28_bl_warm/brightness` (`0..255`) |
| Battery | Sysfs power supply | `/sys/class/power_supply/battery/{capacity,status}` |
| Audio | **Wolfson WM8904** ALSA DAC (`48 kHz` stereo) | Driven directly by `k78_upic_engine` via raw ALSA ioctls (`-nostdlib`) |
| Wi-Fi / BT | AP6236 (`bcm43436b0`) / AP6255 | Firmware loaded from `/lib/firmware` (user-supplied from stock system) |
| Recovery / Loader | Rockchip MaskROM / Loader (`2207:330a`) | Hold pinhole reset (left of USB-C) while plugging USB |

---

## 2. Rockchip `/dev/ebc` Framebuffer Interface (`rk_epd`)

Verified directly against stock kernel `4.4.103` `ebc_io_ctl()` disassembly (see `koreader/ffi/ebc_h.lua`):

- **Pixel buffer format**: `1872 × 1404` landscape, **1 byte per pixel**, containing **5-bit even grayscale** (`0x00..0x1e`, step 2: `(gray8 >> 3) & 0x1e`), where `0x00` = black and `0x1e` (30) = white (kernel LUT is `32 × 32 = 1024` bytes/frame).
- **NEON acceleration**: `src/k78_ebc_neon.c` (`libk78ebc.so`) converts a full 8-bit KOReader framebuffer to 5-bit even EBC format in **~2 ms** (vs. ~26 ms in LuaJIT).

### `struct ebc_buf_info` (56 bytes / `0x38`)

```c
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
```

### Verified IOCTLs

| Constant | Number | Behavior |
|---|---:|---|
| `EBC_GET_BUFFER` | `0x7000` | Acquire next free EBC buffer slot |
| `EBC_SEND_BUFFER` | `0x7001` | Submit buffer + dirty window + `epd_mode` |
| `EBC_GET_BUFFER_INFO` | `0x7003` | Query panel geometry & rotation |
| `EBC_GET_CHIP_ID` | `0x7004` | Query EBC controller chip ID |
| `EBC_WAKEUP` | `0x7005` | Wake EBC controller |
| `EBC_DISABLE_A2_FORCE` | `0x7006` | Clears hardware waterfall flag (`[x24+0x1c4] = 0`) and wakes `ebc_thread` |
| `EBC_GET_STATUS` | `0x7007` | Query EBC refresh status |
| `EBC_ENABLE_A2_FORCE` | `0x7008` | Sets hardware waterfall flag (`[x24+0x1c4] = 1`) — **85 Hz A2-Waterfall pipeline** |

### Safe vs. Deadlocking `epd_mode` Values

Verified in both `epd_task` (jump table 1) and `ebc_thread` (jump table 2):

- **Safe active modes**:
  - `1` (`EPD_FULL`): GC16 full flashing refresh
  - `2` (`EPD_A2`): fast B&W A2 refresh (auto-enters via mode 6)
  - `3` (`EPD_PART`): GC16 partial diff (auto-accelerates pure B&W regions)
  - `5` (`EPD_RESET`): full panel reset / INIT clear
  - `6` (`EPD_A2_ENTER`): enter A2 mode
  - `15` (`EPD_FULL_GL16`): low-flash 16-level grayscale refresh
- **WARNING — Kernel deadlock modes**: modes **`4, 7, 10, 11, 12`** are no-ops in `epd_task` jump table 1 and **deadlock `ebc_thread`** until reboot. Never submit them to `EBC_SEND_BUFFER`.

---

## 3. Refresh Modes in `framebuffer_ebc.lua`

`koreader/ffi/framebuffer_ebc.lua` exposes three runtime modes (switchable from the `k78tools.koplugin` quick bar):

1. **`auto`**: GC16 for reading/UI, `EPD_A2` for fast taps, automatic hardware **85 Hz A2-Waterfall** (`0x7008`) during continuous stylus drawing or scrolling, returning cleanly to GC16 (`0x7006`) on pen lift.
2. **`waterfall`**: Keeps 85 Hz A2-Waterfall active continuously for minimal latency in drawing, streaming, and rapid PDF navigation.
3. **`hq`**: Pure 16-level GC16 for maximum image/manga fidelity.
