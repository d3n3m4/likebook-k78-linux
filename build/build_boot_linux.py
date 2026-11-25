#!/usr/bin/env python3
"""Build boot_linux.img for Boyue Likebook Ares Note K78W (RK3368).

Reuses stock V3.1.1 kernel (4.4.103 aarch64) + second (resource.img) from
boot_v311_stock.img, builds an Alpine 3.20.10 ARM64 initramfs with USB RNDIS,
dnsmasq DHCP, Dropbear SSH, rk_reboot, k78_ebc_banner, and AP6255 Wi-Fi blobs,
and signs the ANDROID! header with the exact Boyue/Rockchip u-boot SHA-1.
"""
import gzip
import hashlib
import os
import stat
import struct
import subprocess
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = Path(os.environ.get("K78_OUT_DIR", ROOT / "out"))
STOCK_BOOT = Path(os.environ.get("K78_STOCK_BOOT", ROOT / "stock" / "boot_v311_stock.img"))
OUT_INITRAMFS = OUT_DIR / "initramfs_linux.cpio.gz"
OUT_BOOT = OUT_DIR / "boot_linux.img"
SSH_PUB = Path(os.environ.get("K78_SSH_PUB", ROOT / "k78_id_ed25519.pub"))
BIN_DIR = ROOT / "bin"
BLOBS_DIR = Path(os.environ.get("K78_BLOBS_DIR", ROOT / "blobs"))

DL = Path(os.environ.get("K78_DL_DIR", ROOT / "dl"))
TARBALLS = [
    DL / "alpine-minirootfs-3.20.10-aarch64.tar.gz",
    DL / "dropbear-2024.85-r0.apk",
    DL / "dropbear-scp-2024.85-r0.apk",
    DL / "dnsmasq-2.90-r3.apk",
    DL / "busybox-extras-1.36.1-r31.apk",
]

INIT_SCRIPT = r"""#!/bin/sh
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 1. Core virtual filesystems
mkdir -p /dev /proc /sys /tmp /run /mnt /config
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mkdir -p /dev/pts /dev/shm
mount -t devpts -o gid=5,mode=620,ptmxmode=0666 devpts /dev/pts 2>/dev/null || mount -t devpts devpts /dev/pts 2>/dev/null || true
mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true
mount -t tmpfs tmpfs /tmp 2>/dev/null || true
mount -t tmpfs tmpfs /run 2>/dev/null || true
mount -t tmpfs tmpfs /dev/shm 2>/dev/null || true
mount -t configfs none /config 2>/dev/null || true

exec >>/tmp/init.log 2>&1
echo "=== Likebook K78W Pure Linux init starting ==="
uname -a
hostname -F /etc/hostname 2>/dev/null || hostname likebook-k78w

# 2. Loopback
ip link set lo up 2>/dev/null || ifconfig lo 127.0.0.1 up

# 3. USB Gadget RNDIS via ConfigFS (matches init.rk30board.usb.rc)
echo "=== USB OTG sysfs ==="
ls -la /sys/class/udc /sys/bus/platform/drivers/usb20_otg 2>&1 || true
for f in /sys/bus/platform/drivers/usb20_otg/force_usb_mode /sys/bus/platform/drivers/usb20_otg/dwc_otg_conn_en /sys/bus/platform/drivers/usb20_otg/vbus_status; do
    [ -r "$f" ] && echo "$f = $(cat "$f" 2>/dev/null)"
done

G=/config/usb_gadget/g1
mkdir -p "$G"
echo 0x2207 > "$G/idVendor"
echo 0x0003 > "$G/idProduct"
echo 0x0310 > "$G/bcdDevice"
echo 0x0200 > "$G/bcdUSB"
mkdir -p "$G/strings/0x409"
echo "K78W-LINUX" > "$G/strings/0x409/serialnumber"
echo "Boyue" > "$G/strings/0x409/manufacturer"
echo "Likebook-K78W-Linux" > "$G/strings/0x409/product"

mkdir -p "$G/functions/rndis.gs4"
[ -e "$G/functions/rndis.gs4/wceis" ] && echo 1 > "$G/functions/rndis.gs4/wceis" 2>/dev/null || true
[ -e "$G/functions/rndis.gs4/dev_addr" ] && echo "02:78:00:00:00:02" > "$G/functions/rndis.gs4/dev_addr" 2>/dev/null || true
[ -e "$G/functions/rndis.gs4/host_addr" ] && echo "02:78:00:00:00:01" > "$G/functions/rndis.gs4/host_addr" 2>/dev/null || true

mkdir -p "$G/configs/b.1/strings/0x409"
echo "rndis" > "$G/configs/b.1/strings/0x409/configuration"
echo 500 > "$G/configs/b.1/MaxPower"
ln -s "$G/functions/rndis.gs4" "$G/configs/b.1/f1"

UDC=""
for i in 1 2 3 4 5; do
    UDC=$(ls /sys/class/udc 2>/dev/null | head -n1)
    [ -n "$UDC" ] && break
    sleep 1
done
echo "UDC=$UDC"
if [ -n "$UDC" ]; then
    echo "$UDC" > "$G/UDC"
    echo "UDC write rc=$?"
fi

# 4. Bring up USB RNDIS network interface
USB_IF=""
for i in 1 2 3 4 5; do
    if [ -r "$G/functions/rndis.gs4/ifname" ]; then
        USB_IF=$(cat "$G/functions/rndis.gs4/ifname" 2>/dev/null)
    fi
    if [ -z "$USB_IF" ]; then
        for n in /sys/class/net/*; do
            b=$(basename "$n")
            case "$b" in
                usb*|rndis*) USB_IF="$b"; break ;;
            esac
        done
    fi
    [ -n "$USB_IF" ] && break
    sleep 1
done
echo "USB_IF=$USB_IF"
if [ -n "$USB_IF" ]; then
    ip addr flush dev "$USB_IF" 2>/dev/null || true
    ip addr add 192.168.7.2/24 dev "$USB_IF" 2>/dev/null || ifconfig "$USB_IF" 192.168.7.2 netmask 255.255.255.0 up
    ip link set "$USB_IF" up 2>/dev/null || true
    ip addr show dev "$USB_IF"

    # DHCP server on USB RNDIS only (no DNS, no default gateway so PC keeps internet)
    /usr/sbin/dnsmasq \
        --conf-file=/dev/null \
        --user=root \
        --interface="$USB_IF" \
        --except-interface=lo \
        --bind-interfaces \
        --port=0 \
        --dhcp-range=192.168.7.10,192.168.7.20,255.255.255.0,12h \
        --dhcp-option=3 \
        --dhcp-option=6 \
        --dhcp-leasefile=/tmp/dnsmasq.leases \
        --pid-file=/run/dnsmasq.pid \
        --log-facility=/tmp/dnsmasq.log \
        && echo "dnsmasq started OK" || echo "dnsmasq failed ($?)"

    # Stage-1 bring-up fallback shell bound strictly to USB link
    /usr/sbin/telnetd -b 192.168.7.2 -p 23 -l /bin/sh && echo "telnetd started OK" || true
fi

# 5. Start Dropbear SSH (backgrounded so host keygen / getrandom never blocks PID 1)
mkdir -p /etc/dropbear
(
    [ -f /etc/dropbear/dropbear_ed25519_host_key ] || /usr/bin/dropbearkey -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key
    exec /usr/sbin/dropbear -F -R -E -p 22
) >>/tmp/dropbear.log 2>&1 &
echo "dropbear launched (pid $!)"

# 6. Render E-ink status banner (backgrounded, retry if /dev/ebc initializes async)
(
    for i in 1 2 3 4 5; do
        sleep 1
        /bin/k78_ebc_banner
        rc=$?
        echo "k78_ebc_banner attempt=$i exit=$rc"
        [ "$rc" -eq 0 ] && break
    done
) >>/tmp/init.log 2>&1 &

# 7. Auto-mount microSD FAT32 partition (/mnt/sd) to mirror boot logs + optional trigger
(
    mkdir -p /mnt/sd
    SD_MOUNTED=0
    for tries in 1 2 3 4 5 6; do
        for dev in /dev/mmcblk0p1 /dev/mmcblk1p1 /dev/mmcblk2p1; do
            [ -b "$dev" ] || continue
            if mount -t vfat -o rw,sync "$dev" /mnt/sd 2>/dev/null; then
                echo "Mounted SD FAT32 $dev at /mnt/sd"
                SD_MOUNTED=1
                break
            fi
        done
        [ "$SD_MOUNTED" -eq 1 ] && break
        sleep 1
    done
    if [ "$SD_MOUNTED" -eq 1 ]; then
        if [ -f /mnt/sd/DO_REBOOT_LOADER ]; then
            rm -f /mnt/sd/DO_REBOOT_LOADER
            sync
            umount /mnt/sd 2>/dev/null || true
            /sbin/rk_reboot loader
        fi
        for snap in 1 2; do
            sleep 3
            {
                echo "=== SNAP $snap ==="
                cat /tmp/init.log 2>/dev/null
                echo "=== dropbear.log ==="
                cat /tmp/dropbear.log 2>/dev/null
                echo "=== dnsmasq.log ==="
                cat /tmp/dnsmasq.log 2>/dev/null
                echo "=== ip addr ==="
                ip addr 2>/dev/null
                echo "=== ps ==="
                ps 2>/dev/null
                echo "=== block ==="
                ls -la /dev/mmcblk* /dev/ebc /dev/input/* 2>/dev/null
            } > /mnt/sd/k78_boot.log
            dmesg > /mnt/sd/k78_dmesg.log 2>/dev/null
            sync
        done
    fi
) >>/tmp/init.log 2>&1 &

echo "=== init setup complete; entering idle loop ==="
while true; do
    sleep 60
done
"""


def norm_path(p: str) -> str:
    while p.startswith("./") or p.startswith("/"):
        p = p[2:] if p.startswith("./") else p[1:]
    p = p.rstrip("/")
    return "" if p == "." else p


def add_parents(entries: dict, path: str) -> None:
    parts = path.split("/")[:-1]
    cur = ""
    for part in parts:
        cur = f"{cur}/{part}" if cur else part
        if cur not in entries:
            entries[cur] = (stat.S_IFDIR | 0o755, b"", 0, 0)


def add_dir(entries: dict, path: str, mode: int = 0o755) -> None:
    path = norm_path(path)
    add_parents(entries, path)
    entries[path] = (stat.S_IFDIR | (mode & 0o7777), b"", 0, 0)


def add_file(entries: dict, path: str, data: bytes, mode: int = 0o644) -> None:
    path = norm_path(path)
    add_parents(entries, path)
    entries[path] = (stat.S_IFREG | (mode & 0o7777), data, 0, 0)


def add_symlink(entries: dict, path: str, target: str) -> None:
    path = norm_path(path)
    add_parents(entries, path)
    entries[path] = (stat.S_IFLNK | 0o777, target.encode("utf-8"), 0, 0)


def add_chardev(entries: dict, path: str, mode: int, major: int, minor: int) -> None:
    path = norm_path(path)
    add_parents(entries, path)
    entries[path] = (stat.S_IFCHR | (mode & 0o7777), b"", major, minor)


def cpio_entry(ino: int, mode: int, name: str, data: bytes, rdev_maj: int = 0, rdev_min: int = 0) -> bytes:
    name_b = name.encode("utf-8") + b"\x00"
    nlink = 2 if stat.S_ISDIR(mode) else 1
    hdr = (
        f"070701"
        f"{ino:08x}{mode:08x}{0:08x}{0:08x}"
        f"{nlink:08x}{0:08x}{len(data):08x}"
        f"{0:08x}{0:08x}{rdev_maj:08x}{rdev_min:08x}"
        f"{len(name_b):08x}{0:08x}"
    ).encode("ascii")
    out = bytearray(hdr)
    out += name_b
    while len(out) % 4:
        out.append(0)
    out += data
    while len(out) % 4:
        out.append(0)
    return bytes(out)


def rk_boot_sha1(hdr: bytes, kernel: bytes, ramdisk: bytes, second: bytes) -> bytes:
    h = hashlib.sha1()
    h.update(kernel)
    h.update(struct.pack("<I", len(kernel)))
    h.update(ramdisk)
    h.update(struct.pack("<I", len(ramdisk)))
    h.update(second)
    h.update(struct.pack("<I", len(second)))
    h.update(hdr[0x20:0x240])
    return h.digest()


def pad_gzip_4byte(gz: bytes) -> bytes:
    """Pad a plain FLG=0x00 gzip initramfs to a multiple of 4 bytes with trailing NULs.

    Two platform quirks verified by disassembling stock uboot.img + kernel 4.4.103:
    1. RK3368 U-Boot HW SHA-1 DMA (0x20de68, CRYPTO_HRDMAL) uses `(len + 3) >> 2`
       32-bit words, so ramdisk_size MUST be divisible by 4.
    2. Linux 4.4.103 __gunzip() (0x1166358) ignores gzip FEXTRA (0x04) and only
       supports plain FLG=0x00 or FNAME (0x08). Stock boot.img and recovery.img
       both use FLG=0x00 + trailing b'\\x00' bytes, which init/initramfs.c skips.
    """
    assert gz[:4] == b"\x1f\x8b\x08\x00", f"Unexpected gzip header: {gz[:10].hex()}"
    pad_len = (4 - (len(gz) % 4)) % 4
    out = gz + (b"\x00" * pad_len)
    assert len(out) % 4 == 0
    return out


def main() -> None:
    entries: dict[str, tuple[int, bytes, int, int]] = {}

    # 1. Extract Alpine minirootfs + APKs
    for tb in TARBALLS:
        with tarfile.open(tb, "r:gz") as tf:
            for m in tf.getmembers():
                p = norm_path(m.name)
                if not p:
                    continue
                base = p.split("/")[0]
                if base.startswith(".SIGN") or base in (".PKGINFO", ".pre-install", ".post-install", ".pre-upgrade", ".pre-deinstall"):
                    continue
                if m.isdir():
                    add_dir(entries, p, m.mode or 0o755)
                elif m.issym():
                    add_symlink(entries, p, m.linkname)
                elif m.isfile():
                    f = tf.extractfile(m)
                    assert f is not None
                    add_file(entries, p, f.read(), m.mode or 0o644)
                else:
                    raise RuntimeError(f"Unsupported tar entry {tb}:{m.name} type={m.type}")

    # 2. Essential /dev nodes for early kernel boot before devtmpfs mounts
    add_dir(entries, "dev", 0o755)
    add_chardev(entries, "dev/console", 0o600, 5, 1)
    add_chardev(entries, "dev/null", 0o666, 1, 3)

    # 3. busybox-extras applets
    add_symlink(entries, "usr/sbin/telnetd", "/bin/busybox-extras")
    add_symlink(entries, "usr/sbin/udhcpd", "/bin/busybox-extras")

    # 4. Custom AArch64 utilities (compiled via `make device`)
    add_file(entries, "sbin/rk_reboot", (BIN_DIR / "rk_reboot").read_bytes(), 0o755)
    add_file(entries, "bin/k78_ebc_banner", (BIN_DIR / "k78_ebc_banner").read_bytes(), 0o755)

    # 5. AP6255 Wi-Fi/BT firmware blobs (user-extracted from device stock firmware)
    fw_dir = BLOBS_DIR / "firmware"
    add_dir(entries, "lib/firmware", 0o755)
    if fw_dir.is_dir():
        for f in sorted(fw_dir.iterdir()):
            if f.is_file():
                add_file(entries, f"lib/firmware/{f.name}", f.read_bytes(), 0o644)
    add_dir(entries, "vendor/etc", 0o755)
    add_symlink(entries, "vendor/etc/firmware", "/lib/firmware")

    # 6. Unlock root account (default password "k78" — change on device!) + optional SSH authorized_keys
    pw_hash = subprocess.check_output(["openssl", "passwd", "-6", "k78"], text=True).strip()
    shadow_lines = entries["etc/shadow"][1].decode("utf-8").splitlines()
    new_shadow = []
    for line in shadow_lines:
        if line.startswith("root:"):
            new_shadow.append(f"root:{pw_hash}:19000:0:99999:7:::")
        else:
            new_shadow.append(line)
    add_file(entries, "etc/shadow", ("\n".join(new_shadow) + "\n").encode("utf-8"), 0o600)
    add_file(entries, "etc/hostname", b"likebook-k78w\n", 0o644)
    add_file(entries, "etc/hosts", b"127.0.0.1\tlocalhost likebook-k78w\n", 0o644)
    add_dir(entries, "etc/dropbear", 0o700)
    add_dir(entries, "root", 0o700)
    add_dir(entries, "root/.ssh", 0o700)
    if SSH_PUB.is_file():
        add_file(entries, "root/.ssh/authorized_keys", SSH_PUB.read_bytes(), 0o600)
    else:
        print(f"Note: {SSH_PUB} not found; skipping authorized_keys (password login still enabled).")

    OUT_DIR.mkdir(parents=True, exist_ok=True)

    # 7. /init
    add_file(entries, "init", INIT_SCRIPT.encode("utf-8"), 0o755)

    # 8. Pack deterministic newc CPIO (directories first / sorted paths) and gzip -9
    cpio_buf = bytearray()
    ino = 1
    for path in sorted(entries.keys()):
        mode, data, maj, mino = entries[path]
        cpio_buf += cpio_entry(ino, mode, path, data, maj, mino)
        ino += 1
    cpio_buf += cpio_entry(0, 0, "TRAILER!!!", b"")

    initramfs_gz = pad_gzip_4byte(gzip.compress(bytes(cpio_buf), compresslevel=9, mtime=0))
    OUT_INITRAMFS.write_bytes(initramfs_gz)
    print(f"initramfs: {len(entries)} entries, raw={len(cpio_buf):,} B, gz={len(initramfs_gz):,} B ({len(initramfs_gz)/1048576:.2f} MiB, mod4={len(initramfs_gz)%4})")
    assert len(initramfs_gz) % 4 == 0, "initramfs_gz must be 4-byte aligned for RK3368 HW SHA-1 DMA!"
    assert len(initramfs_gz) < 8 * 1024 * 1024, "initramfs_gz exceeds 8 MiB PARM initrd window!"

    # 9. Repack boot_linux.img from stock V3.1.1 boot.img
    stock = STOCK_BOOT.read_bytes()
    magic, ksz, kaddr, rsz, raddr, ssz, saddr, tags, pgsz = struct.unpack("<8s8I", stock[:40])
    assert magic == b"ANDROID!" and pgsz == 2048
    align = lambda n: (n + pgsz - 1) // pgsz * pgsz

    k_off = pgsz
    r_off = k_off + align(ksz)
    s_off = r_off + align(rsz)

    stock_hdr = stock[:pgsz]
    kernel = stock[k_off : k_off + ksz]
    stock_ramdisk = stock[r_off : r_off + rsz]
    second = stock[s_off : s_off + ssz]

    # Self-verify Rockchip SHA-1 formula against stock boot_v311_stock.img
    stock_sha_calc = rk_boot_sha1(stock_hdr, kernel, stock_ramdisk, second)
    stock_sha_hdr = stock_hdr[0x240:0x254]
    assert stock_sha_calc == stock_sha_hdr, f"Stock SHA mismatch: {stock_sha_calc.hex()} != {stock_sha_hdr.hex()}"
    print(f"Stock V3.1.1 SHA-1 verified: {stock_sha_calc.hex()}")

    new_hdr = bytearray(stock_hdr)
    struct.pack_into("<I", new_hdr, 16, len(initramfs_gz))
    new_sha = rk_boot_sha1(bytes(new_hdr), kernel, initramfs_gz, second)
    new_hdr[0x240:0x254] = new_sha
    new_hdr[0x254:0x260] = b"\x00" * 12

    pad = lambda b: b + b"\x00" * (align(len(b)) - len(b))
    boot_img = bytes(new_hdr) + pad(kernel) + pad(initramfs_gz) + pad(second)
    assert len(boot_img) <= 32 * 1024 * 1024, "boot_linux.img exceeds 32 MiB boot partition!"
    assert len(boot_img) % 512 == 0, "boot_linux.img not 512-byte aligned!"
    OUT_BOOT.write_bytes(boot_img)
    print(f"Wrote {OUT_BOOT}: {len(boot_img):,} B ({len(boot_img)//512} sectors, {len(boot_img)/1048576:.2f} MiB)")
    print(f"New boot_linux.img Rockchip SHA-1: {new_sha.hex()}")


if __name__ == "__main__":
    main()
