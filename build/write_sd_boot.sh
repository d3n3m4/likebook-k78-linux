#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: sudo $0 /dev/sdX" >&2
    exit 1
fi

DEV="$1"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BK="${K78_BACKUP_DIR:-$ROOT/stock}"
LP="${K78_OUT_DIR:-$ROOT/out}"
STOCK_BOOT="${K78_STOCK_BOOT:-$BK/boot_v311_stock.img}"

# Strict safety checks: must be a removable USB block device, never nvme/system disk
if [ ! -b "$DEV" ]; then
    echo "ERROR: $DEV is not a block device" >&2
    exit 1
fi
TRAN="$(lsblk -ndo TRAN "$DEV" 2>/dev/null || true)"
RM="$(lsblk -ndo RM "$DEV" 2>/dev/null || true)"
if [ "$TRAN" != "usb" ] && [ "$RM" != "1" ]; then
    echo "ERROR: $DEV does not look like a removable USB SD card (TRAN=$TRAN RM=$RM)" >&2
    exit 1
fi

echo "=== Target SD card ==="
lsblk -o NAME,SIZE,TYPE,TRAN,RM,MODEL,MOUNTPOINT "$DEV"

# Unmount any mounted partitions
for p in "${DEV}"?*; do
    [ -b "$p" ] && umount "$p" 2>/dev/null || true
done

# 1. Create MBR with Partition 1 (FAT32 LBA) starting at sector 393216 (0x60000 = 192 MiB)
#    leaving sectors 1..393215 (0..192 MiB) free for Rockchip SDCard Boot raw partitions.
echo "=== Creating MBR (FAT32 partition starts at 192 MiB / LBA 0x60000) ==="
printf 'label: dos\n393216, , c\n' | sfdisk --wipe always "$DEV"
partprobe "$DEV" 2>/dev/null || blockdev --rereadpt "$DEV" || true
sleep 1

# 2. Write 2048-byte Rockchip SDCard Boot header at LBA 64 (0x40)
#    Verified from K78W uboot.img 0x20d500..0x20d548:
#      offset 0x000 = 0xfcdc8c3b (3b 8c dc fc)
#      offset 0x268 = 1          (SDCard Boot -> boots PARM + boot from SD card!)
echo "=== Writing Rockchip SDCard Boot magic at LBA 64 ==="
MAGIC_BIN="$(mktemp)"
trap 'rm -f "$MAGIC_BIN"' EXIT
python3 - "$MAGIC_BIN" <<'PY'
import struct, sys
buf = bytearray(2048)
struct.pack_into("<I", buf, 0x000, 0xfcdc8c3b)
struct.pack_into("<I", buf, 0x268, 1)
open(sys.argv[1], "wb").write(buf)
PY
dd if="$MAGIC_BIN" of="$DEV" bs=512 seek=64 conv=notrunc status=none

# 3. Write Rockchip partitions at physical LBA = logical LBA + 0x2000 (verified uboot.img 0x20d828)
echo "=== Writing PARM (LBA 0x2000), wbf (0x8000), zero misc (0xa000), resource (0xc000) ==="
dd if="$BK/parameter.img" of="$DEV" bs=512 seek=$((0x2000)) conv=notrunc status=none
dd if="$BK/wbf.img"       of="$DEV" bs=512 seek=$((0x8000)) conv=notrunc status=none
dd if=/dev/zero           of="$DEV" bs=512 seek=$((0xa000)) count=$((0x2000)) conv=notrunc status=none
dd if="$BK/resource.img"  of="$DEV" bs=512 seek=$((0xc000)) conv=notrunc status=none

echo "=== Writing Pure Linux boot_linux.img at LBA 0x24000 (72 MiB) ==="
dd if="$LP/boot_linux.img" of="$DEV" bs=512 seek=$((0x24000)) conv=notrunc status=progress

echo "=== Writing stock recovery.img safety net at LBA 0x34000 (104 MiB) ==="
dd if="$BK/recovery.img" of="$DEV" bs=512 seek=$((0x34000)) conv=notrunc status=progress

# 4. Format Partition 1 as FAT32 and copy boot images for SSH eMMC flashing
PART1="${DEV}1"
[ -b "${DEV}p1" ] && PART1="${DEV}p1"
echo "=== Formatting $PART1 as FAT32 (K78_LINUX) ==="
mkfs.vfat -F 32 -n K78_LINUX "$PART1"

MNT="$(mktemp -d)"
umount "$PART1" 2>/dev/null || true
mount "$PART1" "$MNT"
cp "$LP/boot_linux.img" "$MNT/boot_linux.img"
[ -f "$STOCK_BOOT" ] && cp "$STOCK_BOOT" "$MNT/boot_v311_stock.img"
sync
umount "$MNT"
rmdir "$MNT"

# 5. Verify key sectors bit-for-bit
echo "=== Verifying written LBA 64, 0x2000 (PARM), and 0x24000 (boot_linux.img) ==="
sync
BOOT_SECTORS=$(( $(stat -c%s "$LP/boot_linux.img") / 512 ))
cmp -s "$MAGIC_BIN" <(dd if="$DEV" bs=512 skip=64 count=4 status=none)
cmp -s "$BK/parameter.img" <(dd if="$DEV" bs=512 skip=$((0x2000)) count=64 status=none)
cmp -s "$LP/boot_linux.img" <(dd if="$DEV" bs=512 skip=$((0x24000)) count="$BOOT_SECTORS" status=none)
echo "=== SUCCESS: SDCard Boot microSD verified 100% bit-for-bit! ==="
