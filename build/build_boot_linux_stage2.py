#!/usr/bin/env python3
"""Build Stage-2 switch_root boot_linux_stage2.img for Likebook Ares Note K78W.

Mounts persistent Alpine+glibc+KOReader rootfs from /dev/mmcblk1p12 (system, 2 GiB ext4)
and execs `switch_root /newroot /sbin/init`. If mmcblk1p12 ever fails to mount,
automatically falls back to USB RNDIS + Dropbear SSH + E-ink banner rescue mode.
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
OUT_INITRAMFS = OUT_DIR / "initramfs_stage2.cpio.gz"
OUT_BOOT = OUT_DIR / "boot_linux_stage2.img"
SSH_PUB = Path(os.environ.get("K78_SSH_PUB", ROOT / "k78_id_ed25519.pub"))
BIN_DIR = ROOT / "bin"
DL = Path(os.environ.get("K78_DL_DIR", ROOT / "dl"))

TARBALLS = [
    DL / "alpine-minirootfs-3.20.10-aarch64.tar.gz",
    DL / "dropbear-2024.85-r0.apk",
    DL / "dropbear-scp-2024.85-r0.apk",
    DL / "dnsmasq-2.90-r3.apk",
]

INIT_SCRIPT = r"""#!/bin/sh
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

mkdir -p /dev /proc /sys /tmp /run /config /newroot
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true
mount -t tmpfs tmpfs /tmp 2>/dev/null || true
mount -t tmpfs tmpfs /run 2>/dev/null || true
mount -t configfs none /config 2>/dev/null || true

# Try mounting persistent Pure Linux rootfs (/dev/mmcblk1p12 = system, 2 GiB ext4)
ROOT_OK=0
for i in 1 2 3 4 5 6 7 8; do
    if [ -b /dev/mmcblk1p12 ]; then
        if mount -t ext4 -o rw,noatime /dev/mmcblk1p12 /newroot 2>/tmp/mount.err; then
            if [ -x /newroot/sbin/init ]; then
                ROOT_OK=1
                break
            fi
            umount /newroot 2>/dev/null || true
        fi
    fi
    sleep 1
done

if [ "$ROOT_OK" -eq 1 ]; then
    mkdir -p /newroot/dev /newroot/proc /newroot/sys /newroot/config
    mount --move /dev /newroot/dev 2>/dev/null || umount /dev 2>/dev/null || true
    mount --move /proc /newroot/proc 2>/dev/null || umount /proc 2>/dev/null || true
    mount --move /sys /newroot/sys 2>/dev/null || umount /sys 2>/dev/null || true
    mount --move /config /newroot/config 2>/dev/null || umount /config 2>/dev/null || true
    umount /tmp /run 2>/dev/null || true
    exec switch_root /newroot /sbin/init
fi

# === RESCUE FALLBACK (only reached if mmcblk1p12 fails) ===
mkdir -p /dev/pts /dev/shm
mount -t devpts -o gid=5,mode=620,ptmxmode=0666 devpts /dev/pts 2>/dev/null || true
exec >>/tmp/rescue.log 2>&1
echo "=== RESCUE FALLBACK ==="
cat /tmp/mount.err 2>/dev/null || true
hostname likebook-k78w-rescue
ip link set lo up 2>/dev/null || true

G=/config/usb_gadget/g1
mkdir -p "$G/strings/0x409" "$G/functions/rndis.gs4" "$G/configs/b.1/strings/0x409"
echo 0x2207 > "$G/idVendor"
echo 0x0003 > "$G/idProduct"
echo 0x0310 > "$G/bcdDevice"
echo 0x0200 > "$G/bcdUSB"
echo "K78W-RESCUE" > "$G/strings/0x409/serialnumber"
echo "Boyue" > "$G/strings/0x409/manufacturer"
echo "Likebook-K78W-Rescue" > "$G/strings/0x409/product"
[ -e "$G/functions/rndis.gs4/dev_addr" ] && echo "02:78:00:00:00:02" > "$G/functions/rndis.gs4/dev_addr" 2>/dev/null || true
[ -e "$G/functions/rndis.gs4/host_addr" ] && echo "02:78:00:00:00:01" > "$G/functions/rndis.gs4/host_addr" 2>/dev/null || true
echo "rndis" > "$G/configs/b.1/strings/0x409/configuration"
echo 500 > "$G/configs/b.1/MaxPower"
ln -s "$G/functions/rndis.gs4" "$G/configs/b.1/f1"
UDC=$(ls /sys/class/udc 2>/dev/null | head -n1)
[ -n "$UDC" ] && echo "$UDC" > "$G/UDC"

USB_IF=$(cat "$G/functions/rndis.gs4/ifname" 2>/dev/null || echo usb0)
ip addr add 192.168.7.2/24 dev "$USB_IF" 2>/dev/null || true
ip link set "$USB_IF" up 2>/dev/null || true
/usr/sbin/dnsmasq --conf-file=/dev/null --user=root --interface="$USB_IF" --except-interface=lo --bind-interfaces --port=0 --dhcp-range=192.168.7.10,192.168.7.20,255.255.255.0,12h --dhcp-option=3 --dhcp-option=6 --dhcp-leasefile=/tmp/dnsmasq.leases --pid-file=/run/dnsmasq.pid || true
mkdir -p /etc/dropbear
( /usr/bin/dropbearkey -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key; exec /usr/sbin/dropbear -F -R -E -p 22 ) >>/tmp/dropbear.log 2>&1 &
( sleep 1; /bin/k78_ebc_banner ) >>/tmp/rescue.log 2>&1 &
while true; do sleep 60; done
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
    path = norm_path(path); add_parents(entries, path)
    entries[path] = (stat.S_IFDIR | (mode & 0o7777), b"", 0, 0)


def add_file(entries: dict, path: str, data: bytes, mode: int = 0o644) -> None:
    path = norm_path(path); add_parents(entries, path)
    entries[path] = (stat.S_IFREG | (mode & 0o7777), data, 0, 0)


def add_symlink(entries: dict, path: str, target: str) -> None:
    path = norm_path(path); add_parents(entries, path)
    entries[path] = (stat.S_IFLNK | 0o777, target.encode("utf-8"), 0, 0)


def add_chardev(entries: dict, path: str, mode: int, major: int, minor: int) -> None:
    path = norm_path(path); add_parents(entries, path)
    entries[path] = (stat.S_IFCHR | (mode & 0o7777), b"", major, minor)


def cpio_entry(ino: int, mode: int, name: str, data: bytes, maj: int = 0, mino: int = 0) -> bytes:
    nb = name.encode("utf-8") + b"\x00"
    nlink = 2 if stat.S_ISDIR(mode) else 1
    hdr = f"070701{ino:08x}{mode:08x}{0:08x}{0:08x}{nlink:08x}{0:08x}{len(data):08x}{0:08x}{0:08x}{maj:08x}{mino:08x}{len(nb):08x}{0:08x}".encode("ascii")
    out = bytearray(hdr) + nb
    while len(out) % 4: out.append(0)
    out += data
    while len(out) % 4: out.append(0)
    return bytes(out)


def rk_boot_sha1(hdr: bytes, kernel: bytes, ramdisk: bytes, second: bytes) -> bytes:
    h = hashlib.sha1()
    h.update(kernel);  h.update(struct.pack("<I", len(kernel)))
    h.update(ramdisk); h.update(struct.pack("<I", len(ramdisk)))
    h.update(second);  h.update(struct.pack("<I", len(second)))
    h.update(hdr[0x20:0x240])
    return h.digest()


def main() -> None:
    entries: dict[str, tuple[int, bytes, int, int]] = {}
    for tb in TARBALLS:
        with tarfile.open(tb, "r:gz") as tf:
            for m in tf.getmembers():
                p = norm_path(m.name)
                if not p: continue
                base = p.split("/")[0]
                if base.startswith(".SIGN") or base in (".PKGINFO", ".pre-install", ".post-install", ".pre-upgrade", ".pre-deinstall"):
                    continue
                if m.isdir(): add_dir(entries, p, m.mode or 0o755)
                elif m.issym(): add_symlink(entries, p, m.linkname)
                elif m.isfile():
                    f = tf.extractfile(m); assert f is not None
                    add_file(entries, p, f.read(), m.mode or 0o644)

    add_dir(entries, "dev", 0o755)
    add_chardev(entries, "dev/console", 0o600, 5, 1)
    add_chardev(entries, "dev/null", 0o666, 1, 3)
    add_file(entries, "sbin/rk_reboot", (BIN_DIR / "rk_reboot").read_bytes(), 0o755)
    add_file(entries, "bin/k78_ebc_banner", (BIN_DIR / "k78_ebc_banner").read_bytes(), 0o755)

    pw_hash = subprocess.check_output(["openssl", "passwd", "-6", "k78"], text=True).strip()
    new_shadow = [f"root:{pw_hash}:19000:0:99999:7:::" if l.startswith("root:") else l
                  for l in entries["etc/shadow"][1].decode().splitlines()]
    add_file(entries, "etc/shadow", ("\n".join(new_shadow) + "\n").encode(), 0o600)
    add_dir(entries, "etc/dropbear", 0o700)
    add_dir(entries, "root", 0o700)
    add_dir(entries, "root/.ssh", 0o700)
    if SSH_PUB.is_file():
        add_file(entries, "root/.ssh/authorized_keys", SSH_PUB.read_bytes(), 0o600)
    else:
        print(f"Note: {SSH_PUB} not found; skipping authorized_keys.")
    add_file(entries, "init", INIT_SCRIPT.encode(), 0o755)
    subprocess.run(["sh", "-n"], input=INIT_SCRIPT.encode(), check=True)
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    cpio = bytearray()
    for ino, path in enumerate(sorted(entries.keys()), start=1):
        mode, data, maj, mino = entries[path]
        cpio += cpio_entry(ino, mode, path, data, maj, mino)
    cpio += cpio_entry(0, 0, "TRAILER!!!", b"")

    gz = gzip.compress(bytes(cpio), compresslevel=9, mtime=0)
    assert gz[:4] == b"\x1f\x8b\x08\x00"
    gz += b"\x00" * ((4 - len(gz) % 4) % 4)
    assert len(gz) % 4 == 0 and len(gz) < 8 * 1024 * 1024
    OUT_INITRAMFS.write_bytes(gz)

    stock = STOCK_BOOT.read_bytes()
    magic, ksz, ka, rsz, ra, ssz, sa, ta, pgsz = struct.unpack("<8s8I", stock[:40])
    assert magic == b"ANDROID!" and pgsz == 2048 and ksz % 4 == 0 and ssz % 4 == 0
    al = lambda n: (n + pgsz - 1) // pgsz * pgsz
    k = stock[pgsz : pgsz + ksz]
    sec = stock[pgsz + al(ksz) + al(rsz) : pgsz + al(ksz) + al(rsz) + ssz]

    hdr = bytearray(stock[:pgsz])
    struct.pack_into("<I", hdr, 16, len(gz))
    sha = rk_boot_sha1(bytes(hdr), k, gz, sec)
    hdr[0x240:0x254] = sha
    hdr[0x254:0x260] = b"\x00" * 12
    pad = lambda b: b + b"\x00" * (al(len(b)) - len(b))
    out = bytes(hdr) + pad(k) + pad(gz) + pad(sec)
    assert len(out) <= 32 * 1024 * 1024 and len(out) % 512 == 0
    OUT_BOOT.write_bytes(out)
    print(f"Wrote {OUT_BOOT}: {len(out):,} B ({len(out)//512} sectors, rsz={len(gz):#x} mod4=0, sha={sha.hex()})")


if __name__ == "__main__":
    main()
