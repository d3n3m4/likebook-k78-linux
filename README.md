# Likebook Ares Note K78W — Pure Linux, 85 Hz E-Ink Monitor, Wacom Tablet & Xenakis UPIC Synth

A **Pure Linux** (Alpine ARM64 + native KOReader) environment for the **Boyue Likebook Ares Note K78 / K78W** (`Rockchip RK3368`, 7.8" 1872×1404 E-Ink + 4096-level Wacom EMR stylus + Wolfson WM8904 48 kHz DAC) — **no Android userspace, no Google services**, booted non-destructively from microSD or a persistent Linux rootfs.

Beyond ultra-fast reading and note-taking, it turns the K78W into:
1. An **85 Hz Mini-Cintiq / 2nd E-Ink Linux Monitor** (native Wayland/PipeWire ScreenCast + sub-1.2 ms x86_64 encoder + simultaneous 120 Hz Wacom stylus return over USB RNDIS).
2. A **Native Linux Wacom Graphics Tablet + Trackpad + E-Ink ExpressKeys** (`uinput`, 4096-level pressure, tilt, hover — zero firewall configuration).
3. An **85 Hz Infinite Whiteboard** with palm/finger panning and clean **vector SVG export**.
4. A **Standalone Real-Time Polyphonic Xenakis UPIC / GENDYN Graphic Synthesizer** (`k78_upic_engine.c` in freestanding AArch64 `-nostdlib`), played directly by drawing sound arcs with the Wacom stylus & contactless hover Theremin on E-Ink.
5. A standalone **Boyue `.note` → PDF `/Ink` converter** for stock Android users.

> **Disclaimer**: Independent hardware preservation and interoperability project for user-owned equipment. This repository contains **zero Boyue/Rockchip proprietary firmware binaries, kernel images, Wi-Fi blobs, prebuilt binaries, or SSH keys**. Users extract stock partitions (`boot.img`, `parameter.img`, `wbf.img`, `resource.img`, `recovery.img`, and Wi-Fi firmware) from their own device.

---

## Highlights & Capabilities

| Component | Stack | What It Does |
|---|---|---|
| **Pure Linux OS** | Alpine 3.20 ARM64 + stock Linux 4.4.103 kernel + glibc runtime for KOReader | Boots without Android via non-destructive Rockchip SDCard Boot (`LBA 64`) or Stage-2 `switch_root` with automatic USB RNDIS + Dropbear SSH rescue fallback. |
| **Native `/dev/ebc` Driver** | LuaJIT FFI + AArch64 NEON (`k78_ebc_neon.c`) | Reverse-engineered `rk_epd` ioctls (`0x7000..0x7008`), ~2 ms full-screen 8-bit → 5-bit EBC conversion, hardware **85 Hz A2-Waterfall** mode, dual cold/warm PWM frontlight, real suspend-to-RAM. |
| **K78-SCREEN (85 Hz Monitor)** | Wayland Portal/PipeWire/GStreamer + `k78_enc_x64.c` (< 1.2 ms) + `k78_stream_neon.c` | Bayer 4×4 85 Hz / Crisp Text 85 Hz / Auto-HQ 16-gray + XOR-delta PackBits RLE over TCP `19781` (USB RNDIS `< 1 ms` or Wi-Fi), with live Wacom stylus input back to the host. |
| **K78-TABLET (`uinput`)** | Freestanding AArch64 `k78_tablet_sender.c` (~5 KB) + `k78_tablet_host.py` | Exposes 3 virtual Linux devices: Wacom Tablet (4096 pressure, tilt X/Y, hover, eraser), relative Trackpad, and E-Ink ExpressKeys. Outbound USB TCP `19782` (zero firewall rules) + optional Wi-Fi UDP `19780`. |
| **K78-BOARD** | `07_tableau_blanc.lua` | 85 Hz infinite canvas: Wacom pen draws (pressure + calligraphic tilt, shapes, eraser), finger pans cleanly with zero accidental marks, exports cropped vector SVG. |
| **K78-UPIC** | Freestanding AArch64 `k78_upic_engine.c` (`-nostdlib`, ALSA WM8904 48 kHz) + `03_xenakis_upic.lua` | Real-time graphic synthesizer inspired by Iannis Xenakis's UPIC: draw frequency arcs & waveforms with Wacom 4096-level pressure, contactless hover Theremin, stochastic GENDYN, spatial echo, and 48 kHz WAV export. |
| **Boyue `.note` Converter** | Pure Python + PyMuPDF (`tools/boyue_notes/`) | Decodes Boyue's proprietary LEB128 `.note` format (stock Android, no root) into standard PDF `/Ink` annotations readable by Okular, Zotero, Acrobat, etc. |

---

## Repository Layout

```text
├── Makefile                    # Cross-compiles all 6 freestanding AArch64 targets + x86_64 host encoder
├── src/
│   ├── k78_ebc_banner.c        # Freestanding AArch64 /dev/ebc boot/rescue splash banner
│   ├── k78_ebc_neon.c          # AArch64 NEON 8-bit -> 5-bit even EBC converter (libk78ebc.so)
│   ├── k78_enc_x64.c           # x86_64 <1.2 ms E-Ink Bayer/Text/HQ + XOR-delta PackBits encoder
│   ├── k78_stream_neon.c       # AArch64 freestanding stream decoder (libk78stream.so)
│   ├── k78_tablet_sender.c     # 120 Hz freestanding Wacom/Trackpad/ExpressKeys TCP streamer
│   ├── k78_upic_engine.c       # Freestanding AArch64 polyphonic Xenakis UPIC/GENDYN audio engine
│   └── rk_reboot.c             # Rockchip reboot-reason helper (loader/recovery/poweroff)
├── koreader/
│   ├── ffi/                    # Reverse-engineered /dev/ebc FFI definitions & 85 Hz framebuffer
│   ├── frontend/device/likebook/ # Native KOReader K78W device & dual-frontlight powerd drivers
│   ├── plugins/k78tools.koplugin/ # Quick toolbar: E-Ink mode, frontlight, Wi-Fi, Syncthing, Apps, Sleep
│   └── apps/                   # 03_xenakis_upic, 05_tablette_pc, 06_ecran_eink, 07_tableau_blanc
├── build/
│   ├── build_boot_linux.py     # Stage-1 Alpine initramfs + Rockchip SHA-1 signed boot_linux.img
│   ├── build_boot_linux_stage2.py # Stage-2 switch_root image with automatic USB/SSH rescue fallback
│   ├── build_rootfs.py         # Persistent Alpine + Debian glibc + KOReader + Syncthing rootfs builder
│   ├── write_sd_boot.sh        # Non-destructive Rockchip SDCard Boot writer (LBA 64 magic + verify)
│   └── k78-usb-reset           # Clean dwc_otg USB RNDIS gadget + dnsmasq reset helper
├── host/
│   ├── k78_display_host.py     # Linux Wayland/PipeWire 2nd E-Ink monitor streamer (TCP 19781)
│   ├── k78_tablet_host.py      # Linux uinput Wacom/Trackpad/ExpressKeys receiver (TCP 19782 / UDP 19780)
│   └── k78-tablet-host.service # Example systemd --user service
├── tools/boyue_notes/          # Standalone Boyue stock .note -> PDF /Ink converter
└── docs/
    ├── 01-hardware-and-ebc.md  # RK3368 hardware map, /dev/ebc ioctls, 85 Hz Waterfall & deadlock modes
    ├── 02-sdcard-and-boot.md   # SDCard Boot LBA 64 magic, ANDROID! SHA-1 & 4-byte alignment quirks
    └── 03-boyue-note-format.md # Boyue .note LEB128 format specification
```

---

## Building the Native Binaries

All 6 AArch64 device binaries are **freestanding (`-nostdlib`)** — no ARM64 cross-libc sysroot is required, only `clang`, `lld`, and a host C compiler (`gcc` or `clang`):

```bash
make all       # Builds bin/* (device + host encoder) and koreader/libs/*.so
# Or individually:
make device    # 4 AArch64 static executables + 2 AArch64 NEON shared libraries
make host      # bin/libk78enc_x64.so (x86_64 host display encoder)
```

---

## Building Pure Linux Images (Using Your Own Device Backup)

1. **Back up your device's stock partitions** (via `rkdeveloptool` in Loader/MaskROM mode, USB ID `2207:330a`) into `stock/`:
   - `stock/boot_v311_stock.img`
   - `stock/parameter.img`, `stock/wbf.img`, `stock/resource.img`, `stock/recovery.img`
   - Extract your device's AP6236/AP6255 Wi-Fi firmware files into `blobs/firmware/`.
2. **Download open-source upstream archives** into `dl/`:
   - Alpine 3.20 ARM64 minirootfs + `dropbear`, `dropbear-scp`, `dnsmasq`, `busybox-extras`, and `dl/apks/` (`wpa_supplicant`, `iw`, `e2fsprogs`, `dosfstools`, `curl`, `nano`, etc.)
   - Debian 12 ARM64 `libc6` + `libgcc-s1` `.deb` packages (for native KOReader ARM64)
   - Official KOReader ARM64 (`koreader-remarkable-aarch64-v*.zip`) & Syncthing ARM64 static tarball
   - *(Optional)* [ink-away.koplugin](https://github.com/EmirErtorer/ink-away.koplugin) placed in `plugins/ink-away.koplugin` (or pointed to via `K78_INK_AWAY`)
3. **(Optional) Generate an SSH key** and point `K78_SSH_PUB` to your `.pub` key (default fallback root password is `k78` — change it on first login!).
4. **Build and write a non-destructive microSD**:
   ```bash
   make all
   K78_SSH_PUB=~/.ssh/id_ed25519.pub python3 build/build_boot_linux.py
   K78_SSH_PUB=~/.ssh/id_ed25519.pub python3 build/build_rootfs.py
   K78_SSH_PUB=~/.ssh/id_ed25519.pub python3 build/build_boot_linux_stage2.py

   # Non-destructive microSD boot (eMMC Android stays untouched; verify /dev/sdX carefully!)
   sudo build/write_sd_boot.sh /dev/sdX
   ```
   See [`docs/02-sdcard-and-boot.md`](docs/02-sdcard-and-boot.md) for partition layout, Stage-2 `switch_root` installation, and rescue recovery.

---

## Linux Host Setup (2nd E-Ink Monitor & Wacom Tablet)

### 1. Wacom Tablet / Trackpad / ExpressKeys (`uinput`)

Ensure your user can write to `/dev/uinput` (e.g., `input` or `uinput` udev rule), then run:

```bash
python3 host/k78_tablet_host.py
```

Or install [`host/k78-tablet-host.service`](host/k78-tablet-host.service) under `~/.config/systemd/user/`. Over USB RNDIS (`192.168.7.2`), the host initiates an outbound TCP connection to port `19782`, requiring **zero firewall configuration**.

### 2. 85 Hz Mini-Cintiq / 2nd E-Ink Monitor (Wayland / PipeWire)

Dependencies: Python 3, PyGObject (`gi`), `dbus-python`, GStreamer + PipeWire plugin (`gst-plugin-pipewire`), and `bin/libk78enc_x64.so` (`make host`).

```bash
# Open "06_ecran_eink" on the K78W, then on your Linux desktop:
python3 host/k78_display_host.py                 # USB RNDIS (default 192.168.7.2)
python3 host/k78_display_host.py --host <WIFI_IP> # Over Wi-Fi
```

Select a monitor, window, or **New Virtual Output** (KDE Plasma Wayland) in the XDG ScreenCast portal.

---

## Stock Android Tool: Boyue `.note` → PDF `/Ink`

Even without installing Pure Linux, you can convert Boyue's proprietary `.note` files into standard PDF `/Ink` annotations:

```bash
pip install pymupdf
python3 tools/boyue_notes/boyue_note.py handwriting123456_0.note
python3 tools/boyue_notes/notes_to_pdf.py NOTES_DIR PDFS_DIR OUTPUT_DIR
```

See [`docs/03-boyue-note-format.md`](docs/03-boyue-note-format.md) for the reverse-engineered binary specification.

---

## Safety Notes

- Always take a full eMMC partition backup before touching eMMC partitions.
- Never submit `epd_mode` values `4, 7, 10, 11, 12` to `/dev/ebc` — they deadlock `ebc_thread` in the RK3368 `4.4.103` kernel (see [`docs/01-hardware-and-ebc.md`](docs/01-hardware-and-ebc.md)).
- The RK3368 pinhole reset + USB MaskROM/Loader (`2207:330a`) makes recovery straightforward as long as you keep your stock backup.

## License

MIT — see [`LICENSE`](LICENSE). Third-party projects packaged at build time (Alpine Linux, Debian glibc, KOReader, Syncthing) retain their respective upstream licenses.
