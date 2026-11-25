# Non-Destructive Rockchip SDCard Boot & `ANDROID!` Boot Image Signing

This document records the low-level boot chain verified from the Boyue Likebook Ares Note K78W (`RK3368`, stock firmware `V3.1.1`) U-Boot and kernel binaries.

---

## 1. Non-Destructive SDCard Boot (`build/write_sd_boot.sh`)

Stock K78W `uboot.img` (`0x20d500..0x20d548` and `0x20d828`) checks for a Rockchip SDCard Boot signature at **LBA 64 (`0x40`)** on the microSD card before booting eMMC:

- **LBA 64 (`2048` bytes)**:
  - Offset `+0x000` (little-endian `u32`): **`0xfcdc8c3b`** (`3b 8c dc fc`)
  - Offset `+0x268` (little-endian `u32`): **`1`** (SDCard Boot mode → load `PARM` + `boot` from microSD)
- **Physical-to-logical offset**: Rockchip partitions on the microSD sit at `physical_LBA = logical_LBA + 0x2000`:
  - `0x02000`: `parameter.img` (`PARM`)
  - `0x08000`: `wbf.img` (E-Ink waveform table)
  - `0x0a000`: zeroed `misc` (`0x2000` sectors)
  - `0x0c000`: `resource.img` (DTB + boot logo)
  - `0x24000`: `boot_linux.img` (72 MiB offset)
  - `0x34000`: stock `recovery.img` safety net (104 MiB offset)
  - `0x60000` (192 MiB): standard MBR Partition 1 (`FAT32 LBA`)

Removing the microSD card immediately boots stock Android from eMMC untouched.

---

## 2. `ANDROID!` Boot Image Rockchip SHA-1 & Alignment Quirks

Verified in `build/build_boot_linux.py` and `build/build_boot_linux_stage2.py`:

1. **4-Byte Ramdisk Alignment (Hardware SHA-1 DMA)**:
   RK3368 U-Boot's hardware SHA-1 DMA (`0x20de68`, `CRYPTO_HRDMAL`) hashes `(len + 3) >> 2` 32-bit words, so `ramdisk_size` **must be divisible by 4**.
2. **Plain Gzip Header (`FLG = 0x00`)**:
   Kernel `4.4.103`'s `__gunzip()` (`0x1166358`) ignores gzip `FEXTRA` (`0x04`) and only supports plain `FLG = 0x00` or `FNAME` (`0x08`). Both stock `boot.img` and our builders emit `gzip(mtime=0)` (`1f 8b 08 00`) padded with `0..3` trailing `0x00` bytes (which `init/initramfs.c` skips).
3. **SHA-1 Digest Layout (`hdr[0x240:0x254]`)**:
   `build_boot_linux.py` self-verifies the exact Rockchip SHA-1 formula against the user-supplied stock `boot_v311_stock.img` before signing the new image:
   ```text
   SHA1( kernel || u32(len(kernel))
       || ramdisk || u32(len(ramdisk))
       || second || u32(len(second))
       || hdr[0x20:0x240] )
   ```
4. **Initramfs Size Ceiling**: must stay strictly under **8 MiB** (`PARM` initrd window) and total `boot.img` under **32 MiB** (512-byte aligned).

---

## 3. Two-Stage Boot Architecture & Automatic Rescue Fallback

- **Stage 1 (`build/build_boot_linux.py` → `boot_linux.img`)**:
  Self-contained Alpine ARM64 initramfs with USB Gadget RNDIS (`192.168.7.2/24`), `dnsmasq` DHCP, Dropbear SSH, `rk_reboot`, and `/dev/ebc` splash banner. Ideal for initial microSD bring-up and inspecting/formatting partitions safely over SSH.
- **Stage 2 (`build/build_boot_linux_stage2.py` → `boot_linux_stage2.img`)**:
  Mounts the persistent ext4 Pure Linux rootfs (`/dev/mmcblk1p12`, 2 GiB) created by `build/build_rootfs.py` and runs `exec switch_root /newroot /sbin/init`.
  - **Built-in rescue fallback**: if `/dev/mmcblk1p12` fails to mount or `/newroot/sbin/init` is missing, Stage 2 automatically brings up USB RNDIS (`192.168.7.2`), Dropbear SSH, and the E-Ink rescue banner so the device stays recoverable without opening Loader/MaskROM.
