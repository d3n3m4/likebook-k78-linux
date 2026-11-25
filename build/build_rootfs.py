#!/usr/bin/env python3
"""Build persistent Pure Linux rootfs tarball (k78_rootfs.tar.gz) for Likebook Ares K78W.

Combines:
- Alpine Linux 3.20.10 ARM64 base + Wi-Fi/disk/SSH utilities
- Official Debian 12 Bookworm glibc 2.36 + libgcc-s1 (for native KOReader ARM64)
- Official KOReader v2026.07.1 headless e-ink ARM64 + Likebook K78W /dev/ebc,
  Wacom, cyttsp5, dual frontlight, Wi-Fi, and real suspend-to-RAM drivers
- Syncthing v2.1.7 ARM64 static binary
- AP6236/bcm43436b0 + AP6255 Wi-Fi/BT firmware blobs
"""
import io
import os
import shutil
import stat
import subprocess
import tarfile
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DL = Path(os.environ.get("K78_DL_DIR", ROOT / "dl"))
OUT_DIR = Path(os.environ.get("K78_OUT_DIR", ROOT / "out"))
OUT_TAR = OUT_DIR / "k78_rootfs.tar.gz"
SSH_PUB = Path(os.environ.get("K78_SSH_PUB", ROOT / "k78_id_ed25519.pub"))
BIN_DIR = ROOT / "bin"
BUILD_DIR = ROOT / "build"
BLOBS_DIR = Path(os.environ.get("K78_BLOBS_DIR", ROOT / "blobs"))
K78_KO = ROOT / "koreader"
INK_AWAY = Path(os.environ.get("K78_INK_AWAY", ROOT / "plugins" / "ink-away.koplugin"))

SBIN_INIT = r"""#!/bin/sh
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME=/root
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

# 1. Core virtual filesystems (safe if initramfs already moved /dev /proc /sys)
mkdir -p /dev /proc /sys /tmp /run /mnt /mnt/sd /data /config /var/run/wpa_supplicant
mountpoint -q /dev      || mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mkdir -p /dev/pts /dev/shm
mountpoint -q /dev/pts  || mount -t devpts -o gid=5,mode=620,ptmxmode=0666 devpts /dev/pts 2>/dev/null || true
mountpoint -q /dev/shm  || mount -t tmpfs tmpfs /dev/shm 2>/dev/null || true
mountpoint -q /proc     || mount -t proc proc /proc 2>/dev/null || true
mountpoint -q /sys      || mount -t sysfs sysfs /sys 2>/dev/null || true
mountpoint -q /tmp      || mount -t tmpfs tmpfs /tmp 2>/dev/null || true
mountpoint -q /run      || mount -t tmpfs tmpfs /run 2>/dev/null || true
mountpoint -q /config   || mount -t configfs none /config 2>/dev/null || true

# Ensure / is remounted rw
mount -o remount,rw / 2>/dev/null || true

exec >>/tmp/k78-init.log 2>&1
echo "=== Likebook K78W Pure Linux /sbin/init starting ==="
uname -a
hostname -F /etc/hostname 2>/dev/null || hostname likebook-k78w
hwclock -s 2>/dev/null || true

# 2. Loopback
ip link set lo up 2>/dev/null || true

# 3. CPU low-power profile & Bluetooth rfkill off
for c in 0 4; do
    g="/sys/devices/system/cpu/cpu${c}/cpufreq"
    [ -w "$g/scaling_governor" ] && echo conservative > "$g/scaling_governor" 2>/dev/null || true
done
[ -w /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq ] && echo 1008000 > /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null || true
[ -w /sys/devices/system/cpu/cpu4/cpufreq/scaling_max_freq ] && echo 1200000 > /sys/devices/system/cpu/cpu4/cpufreq/scaling_max_freq 2>/dev/null || true
for r in /sys/class/rfkill/rfkill*; do
    [ -r "$r/type" ] && [ "$(cat "$r/type")" = "bluetooth" ] && echo 0 > "$r/state" 2>/dev/null || true
done

# 4. Pre-configure bcmdhd Wi-Fi firmware paths (stays DOWN until requested)
echo "/lib/firmware/fw_bcm43436b0.bin" > /sys/module/bcmdhd/parameters/firmware_path 2>/dev/null || true
echo "/lib/firmware/nvram_ap6236.txt"  > /sys/module/bcmdhd/parameters/nvram_path 2>/dev/null || true

# 5. USB Gadget RNDIS (192.168.7.2/24) + dnsmasq DHCP + Dropbear SSH
G=/config/usb_gadget/g1
if [ ! -d "$G" ] || [ -z "$(cat "$G/UDC" 2>/dev/null)" ]; then
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
    [ -e "$G/functions/rndis.gs4/dev_addr" ] && echo "02:78:00:00:00:02" > "$G/functions/rndis.gs4/dev_addr" 2>/dev/null || true
    [ -e "$G/functions/rndis.gs4/host_addr" ] && echo "02:78:00:00:00:01" > "$G/functions/rndis.gs4/host_addr" 2>/dev/null || true
    mkdir -p "$G/configs/b.1/strings/0x409"
    echo "rndis" > "$G/configs/b.1/strings/0x409/configuration"
    echo 500 > "$G/configs/b.1/MaxPower"
    [ -e "$G/configs/b.1/f1" ] || ln -s "$G/functions/rndis.gs4" "$G/configs/b.1/f1"
    UDC=$(ls /sys/class/udc 2>/dev/null | head -n1)
    [ -n "$UDC" ] && echo "$UDC" > "$G/UDC" 2>/dev/null || true
fi

USB_IF=""
for i in 1 2 3 4 5; do
    [ -r "$G/functions/rndis.gs4/ifname" ] && USB_IF=$(cat "$G/functions/rndis.gs4/ifname" 2>/dev/null)
    if [ -z "$USB_IF" ]; then
        for n in /sys/class/net/*; do
            b=$(basename "$n")
            case "$b" in usb*|rndis*) USB_IF="$b"; break ;; esac
        done
    fi
    [ -n "$USB_IF" ] && break
    sleep 1
done
echo "USB_IF=$USB_IF"
if [ -n "$USB_IF" ]; then
    ip addr flush dev "$USB_IF" 2>/dev/null || true
    ip addr add 192.168.7.2/24 dev "$USB_IF" 2>/dev/null || true
    ip link set "$USB_IF" up 2>/dev/null || true
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
        && echo "dnsmasq OK" || echo "dnsmasq failed"
fi

# Persistent Dropbear SSH host key on /etc/dropbear
mkdir -p /etc/dropbear
(
    [ -f /etc/dropbear/dropbear_ed25519_host_key ] || /usr/bin/dropbearkey -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key
    exec /usr/sbin/dropbear -F -R -E -p 22
) >>/tmp/dropbear.log 2>&1 &

# 6. Mount /data (if mmcblk1p17 is formatted ext4) and /mnt/sd (microSD FAT32)
if [ -b /dev/mmcblk1p17 ]; then
    if blkid /dev/mmcblk1p17 2>/dev/null | grep -q 'TYPE="ext4"'; then
        mount -t ext4 -o noatime /dev/mmcblk1p17 /data && echo "Mounted /dev/mmcblk1p17 at /data"
    fi
fi
mkdir -p /data/books /data/syncthing /data/koreader-settings

if [ -b /dev/mmcblk0p1 ]; then
    mount -t vfat -o rw,utf8,shortname=mixed /dev/mmcblk0p1 /mnt/sd 2>/dev/null && echo "Mounted /dev/mmcblk0p1 at /mnt/sd" || true
fi
[ -d /mnt/sd ] && [ ! -e /data/books/microSD ] && ln -s /mnt/sd /data/books/microSD 2>/dev/null || true

# 7. Start Syncthing if enabled
if [ -f /etc/k78/syncthing.enabled ]; then
    /usr/local/bin/k78-syncthing start || true
fi

# 8. Launch KOReader in respawn loop (create /tmp/no-koreader over SSH to stop)
(
    sleep 1
    while true; do
        if [ -f /tmp/no-koreader ]; then
            sleep 3
            continue
        fi
        echo "=== Launching KOReader ==="
        cd /opt/koreader
        HOME=/data KOREADER_DIR=/opt/koreader LD_LIBRARY_PATH=/opt/koreader/libs:/lib/aarch64-linux-gnu ./luajit ./reader.lua /data/books >>/tmp/koreader.log 2>&1
        rc=$?
        echo "KOReader exited rc=$rc"
        if [ "$rc" -eq 85 ]; then
            echo "KOReader requested restart"
            sleep 1
        else
            sleep 2
        fi
    done
) >>/tmp/k78-init.log 2>&1 &

echo "=== /sbin/init complete ==="
while true; do
    sleep 60
done
"""

K78_WIFI = r"""#!/bin/sh
set -e
case "${1:-status}" in
    on)
        /opt/koreader/enable-wifi.sh
        echo "wlan0 ON"
        ;;
    off)
        /opt/koreader/disable-wifi.sh
        echo "wlan0 OFF"
        ;;
    scan)
        /opt/koreader/enable-wifi.sh
        sleep 1
        iw dev wlan0 scan | grep -E 'SSID:|signal:' | head -n 40
        ;;
    connect)
        SSID="${2:?Usage: k78-wifi connect <SSID> <PASSWORD>}"
        PASS="${3:-}"
        /opt/koreader/enable-wifi.sh
        mkdir -p /etc/wpa_supplicant
        cat > /etc/wpa_supplicant/wpa_supplicant.conf <<EOF
ctrl_interface=/var/run/wpa_supplicant
update_config=1
EOF
        if [ -n "$PASS" ]; then
            wpa_passphrase "$SSID" "$PASS" >> /etc/wpa_supplicant/wpa_supplicant.conf
        else
            cat >> /etc/wpa_supplicant/wpa_supplicant.conf <<EOF
network={
    ssid="$SSID"
    key_mgmt=NONE
}
EOF
        fi
        killall wpa_supplicant 2>/dev/null || true
        sleep 1
        wpa_supplicant -B -i wlan0 -c /etc/wpa_supplicant/wpa_supplicant.conf -D nl80211,wext
        sleep 3
        udhcpc -i wlan0 -n -q -t 10 -T 2 -s /usr/share/udhcpc/default.script
        ip -4 addr show wlan0
        ;;
    status|*)
        ip -4 addr show wlan0 2>/dev/null || true
        iw dev wlan0 link 2>/dev/null || true
        ;;
esac
"""

K78_SYNCTHING = r"""#!/bin/sh
ST_HOME=/data/syncthing
PIDFILE=/run/syncthing.pid
mkdir -p "$ST_HOME" /etc/k78
case "${1:-status}" in
    start)
        if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
            echo "syncthing already running (pid $(cat "$PIDFILE"))"
            exit 0
        fi
        HOME=/data STNOUPGRADE=1 STNODEFAULTFOLDER=1 /usr/local/bin/syncthing serve \
            --home="$ST_HOME" \
            --gui-address=http://0.0.0.0:8384 \
            --no-browser \
            >>/tmp/syncthing.log 2>&1 &
        echo $! > "$PIDFILE"
        echo "syncthing started (pid $!, GUI http://192.168.7.2:8384)"
        ;;
    stop)
        [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null || killall syncthing 2>/dev/null || true
        rm -f "$PIDFILE"
        echo "syncthing stopped"
        ;;
    enable)
        touch /etc/k78/syncthing.enabled
        "$0" start
        ;;
    disable)
        rm -f /etc/k78/syncthing.enabled
        "$0" stop
        ;;
    status|*)
        if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
            echo "syncthing running (pid $(cat "$PIDFILE")), GUI :8384"
        else
            echo "syncthing stopped"
        fi
        ;;
esac
"""

K78_LIGHT = r"""#!/bin/sh
C="${1:-0}"
W="${2:-0}"
echo "$C" > /sys/class/backlight/rk28_bl/brightness
echo "$W" > /sys/class/backlight/rk28_bl_warm/brightness
echo "Frontlight set: cold=$C warm=$W"
"""

K78_BAT = r"""#!/bin/sh
B=/sys/class/power_supply/battery
CAP=$(cat $B/capacity 2>/dev/null)
ST=$(cat $B/status 2>/dev/null)
UV=$(cat $B/voltage_now 2>/dev/null)
UA=$(cat $B/current_now 2>/dev/null)
CF=$(cat $B/charge_full 2>/dev/null)
echo "Battery: ${CAP}% (${ST})  V=$((UV/1000)) mV  I=$((UA/1000)) mA  Full=$((CF/1000)) mAh"
"""

K78_SLEEP_TEST = r"""#!/bin/sh
SEC="${1:-8}"
echo "=== Testing RK3368 suspend-to-RAM (mem) for ${SEC}s via rtc0 wakealarm ==="
/usr/local/bin/k78-bat
/opt/koreader/disable-wifi.sh >/dev/null 2>&1 || true
echo 0 > /sys/class/backlight/rk28_bl/brightness
echo 0 > /sys/class/backlight/rk28_bl_warm/brightness
echo 0 > /sys/class/rtc/rtc0/wakealarm 2>/dev/null || true
NOW=$(cat /sys/class/rtc/rtc0/since_epoch)
echo $((NOW + SEC)) > /sys/class/rtc/rtc0/wakealarm
sync
T0=$(date +%s)
echo mem > /sys/power/state
T1=$(date +%s)
echo "Woke up! Elapsed wall seconds: $((T1 - T0))"
/usr/local/bin/k78-bat
"""


def extract_tar_clean(tf_path: Path, dest: Path) -> None:
    with tarfile.open(tf_path, "r:*") as tf:
        for m in tf.getmembers():
            name = m.name.lstrip("./")
            if not name or name == ".":
                continue
            top = name.split("/")[0]
            if top.startswith(".SIGN") or top in (".PKGINFO", ".pre-install", ".post-install", ".pre-upgrade", ".pre-deinstall"):
                continue
            target = dest / name
            if m.isdir():
                target.mkdir(parents=True, exist_ok=True)
            elif m.issym():
                target.parent.mkdir(parents=True, exist_ok=True)
                if target.exists() or target.is_symlink():
                    target.unlink()
                os.symlink(m.linkname, target)
            elif m.isfile():
                target.parent.mkdir(parents=True, exist_ok=True)
                if target.exists() or target.is_symlink():
                    target.unlink()
                with tf.extractfile(m) as src, open(target, "wb") as dst:
                    shutil.copyfileobj(src, dst)
                os.chmod(target, m.mode & 0o7777)


def extract_deb(deb_path: Path, dest: Path) -> None:
    with tempfile.TemporaryDirectory() as td:
        subprocess.run(["ar", "x", str(deb_path)], cwd=td, check=True)
        data_tar = next(Path(td).glob("data.tar.*"))
        extract_tar_clean(data_tar, dest)


def write_text(path: Path, content: str, mode: int = 0o644) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink() or path.exists():
        path.unlink()
    path.write_text(content, encoding="utf-8")
    os.chmod(path, mode)


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="k78_rootfs_") as td:
        root = Path(td)

        # 1. Alpine minirootfs + core APKs + extra APKs
        print("1. Extracting Alpine 3.20.10 ARM64 + APKs...")
        apks = [
            DL / "alpine-minirootfs-3.20.10-aarch64.tar.gz",
            DL / "dropbear-2024.85-r0.apk",
            DL / "dropbear-scp-2024.85-r0.apk",
            DL / "dnsmasq-2.90-r3.apk",
            DL / "busybox-extras-1.36.1-r31.apk",
        ] + sorted((DL / "apks").glob("*.apk"))
        for p in apks:
            extract_tar_clean(p, root)

        # Symlink busybox-extras applets
        for app in ("usr/sbin/udhcpd", "usr/sbin/telnetd", "usr/bin/tftp"):
            dst = root / app
            dst.parent.mkdir(parents=True, exist_ok=True)
            if dst.exists() or dst.is_symlink():
                dst.unlink()
            os.symlink("/bin/busybox-extras", dst)

        # 2. Debian 12 Bookworm glibc 2.36 + libgcc-s1 (for native KOReader ARM64)
        print("2. Extracting Debian 12 Bookworm glibc 2.36 + libgcc-s1...")
        with tempfile.TemporaryDirectory() as gtd:
            gd = Path(gtd)
            extract_deb(DL / "libc6_2.36-9+deb12u14_arm64.deb", gd)
            extract_deb(DL / "libgcc-s1_12.2.0-14+deb12u1_arm64.deb", gd)

            # Copy /lib/aarch64-linux-gnu and /lib/ld-linux-aarch64.so.1
            gnu_lib_src = gd / "lib/aarch64-linux-gnu"
            gnu_lib_dst = root / "lib/aarch64-linux-gnu"
            gnu_lib_dst.mkdir(parents=True, exist_ok=True)
            for item in gnu_lib_src.iterdir():
                dst = gnu_lib_dst / item.name
                if item.is_symlink():
                    os.symlink(os.readlink(item), dst)
                elif item.is_file():
                    shutil.copy2(item, dst)

            # Dynamic linker /lib/ld-linux-aarch64.so.1
            ld_dst = root / "lib/ld-linux-aarch64.so.1"
            if ld_dst.exists() or ld_dst.is_symlink():
                ld_dst.unlink()
            os.symlink("aarch64-linux-gnu/ld-linux-aarch64.so.1", ld_dst)

            # Convenience symlinks in /lib for glibc libs (no collision with musl!)
            for soname in (
                "libc.so.6", "libm.so.6", "libgcc_s.so.1", "libdl.so.2",
                "libpthread.so.0", "librt.so.1", "libresolv.so.2",
                "libnss_files.so.2", "libnss_dns.so.2", "libutil.so.1",
            ):
                if (gnu_lib_dst / soname).exists():
                    s = root / "lib" / soname
                    if s.exists() or s.is_symlink():
                        s.unlink()
                    os.symlink(f"aarch64-linux-gnu/{soname}", s)

            # Copy gconv minimal (UTF-8 / ISO8859) if present
            gconv_src = gd / "usr/lib/aarch64-linux-gnu/gconv"
            if gconv_src.exists():
                shutil.copytree(gconv_src, root / "usr/lib/aarch64-linux-gnu/gconv", symlinks=True)

        write_text(root / "etc/ld.so.conf", "/lib/aarch64-linux-gnu\n/usr/lib/aarch64-linux-gnu\n/opt/koreader/libs\n")
        write_text(root / "etc/nsswitch.conf", "passwd: files\ngroup: files\nshadow: files\nhosts: files dns\n")

        # 3. Firmware blobs (AP6236 + AP6255 — extracted by user from stock firmware)
        print("3. Installing Wi-Fi/BT firmware blobs...")
        fw_dst = root / "lib/firmware"
        fw_dst.mkdir(parents=True, exist_ok=True)
        fw_src = BLOBS_DIR / "firmware"
        if fw_src.is_dir():
            for f in fw_src.iterdir():
                if f.is_file():
                    shutil.copy2(f, fw_dst / f.name)
                    os.chmod(fw_dst / f.name, 0o644)
        else:
            print(f"Warning: {fw_src} not found; Wi-Fi firmware blobs must be added to /lib/firmware.")
        for sym in ("vendor/etc/firmware", "system/vendor/firmware", "system/etc/firmware"):
            sp = root / sym
            sp.parent.mkdir(parents=True, exist_ok=True)
            if sp.exists() or sp.is_symlink():
                sp.unlink()
            os.symlink("/lib/firmware", sp)

        # 4. Custom binaries + Syncthing v2.1.7 ARM64
        print("4. Installing rk_reboot, k78_ebc_banner, and Syncthing v2.1.7...")
        shutil.copy2(BIN_DIR / "rk_reboot", root / "sbin/rk_reboot")
        os.chmod(root / "sbin/rk_reboot", 0o755)
        shutil.copy2(BIN_DIR / "k78_ebc_banner", root / "bin/k78_ebc_banner")
        os.chmod(root / "bin/k78_ebc_banner", 0o755)
        if (BIN_DIR / "k78_upic_engine").exists():
            (root / "usr/local/bin").mkdir(parents=True, exist_ok=True)
            shutil.copy2(BIN_DIR / "k78_upic_engine", root / "usr/local/bin/k78_upic_engine")
            os.chmod(root / "usr/local/bin/k78_upic_engine", 0o755)
        if (BIN_DIR / "k78_tablet_sender").exists():
            (root / "usr/local/bin").mkdir(parents=True, exist_ok=True)
            shutil.copy2(BIN_DIR / "k78_tablet_sender", root / "usr/local/bin/k78_tablet_sender")
            os.chmod(root / "usr/local/bin/k78_tablet_sender", 0o755)
        usb_reset = BUILD_DIR / "k78-usb-reset"
        if usb_reset.exists():
            (root / "usr/local/bin").mkdir(parents=True, exist_ok=True)
            shutil.copy2(usb_reset, root / "usr/local/bin/k78-usb-reset")
            os.chmod(root / "usr/local/bin/k78-usb-reset", 0o755)
        if (K78_KO / "apps").exists():
            (root / "data/apps").mkdir(parents=True, exist_ok=True)
            for af in (K78_KO / "apps").iterdir():
                if af.is_file():
                    shutil.copy2(af, root / "data/apps" / af.name)
                    os.chmod(root / "data/apps" / af.name, 0o755 if af.suffix == ".sh" else 0o644)

        (root / "usr/local/bin").mkdir(parents=True, exist_ok=True)
        with tarfile.open(DL / "syncthing-linux-arm64-v2.1.7.tar.gz", "r:gz") as st:
            m = [x for x in st.getmembers() if x.name.count("/") == 1 and x.name.endswith("/syncthing")][0]
            with st.extractfile(m) as src, open(root / "usr/local/bin/syncthing", "wb") as dst:
                shutil.copyfileobj(src, dst)
        os.chmod(root / "usr/local/bin/syncthing", 0o755)

        # 5. Native KOReader v2026.07.1 ARM64 + Likebook K78W drivers + ink-away.koplugin
        print("5. Installing KOReader v2026.07.1 ARM64 + Likebook K78W native drivers...")
        opt = root / "opt"
        opt.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(DL / "koreader-remarkable-aarch64-v2026.07.1.zip") as zf:
            for info in zf.infolist():
                out_p = opt / info.filename
                if info.is_dir():
                    out_p.mkdir(parents=True, exist_ok=True)
                else:
                    # Preserve symlinks in zip
                    unix_mode = info.external_attr >> 16
                    out_p.parent.mkdir(parents=True, exist_ok=True)
                    if stat.S_ISLNK(unix_mode):
                        target = zf.read(info).decode("utf-8")
                        if out_p.exists() or out_p.is_symlink():
                            out_p.unlink()
                        os.symlink(target, out_p)
                    else:
                        with zf.open(info) as src, open(out_p, "wb") as dst:
                            shutil.copyfileobj(src, dst)
                        mode = unix_mode & 0o7777
                        os.chmod(out_p, mode if mode else 0o644)

        ko = opt / "koreader"
        # Ensure executable bits on KOReader binaries
        for exe in ("luajit", "koreader.sh", "sdcv", "tar", "zsync2"):
            ep = ko / exe
            if ep.exists():
                os.chmod(ep, 0o755)

        # Patch frontend/device.lua to detect /dev/ebc -> device/likebook/device
        dev_lua = ko / "frontend/device.lua"
        txt = dev_lua.read_text(encoding="utf-8")
        needle = "    if isAndroid then\n        return require(\"device/android/device\")\n    end\n"
        patch = needle + "\n    if lfs.attributes(\"/dev/ebc\") then\n        return require(\"device/likebook/device\")\n    end\n"
        assert needle in txt, "Could not find probeDevice anchor in frontend/device.lua!"
        dev_lua.write_text(txt.replace(needle, patch, 1), encoding="utf-8")

        # Install Likebook K78W drivers & Wi-Fi helper scripts
        for rel in (
            "ffi/ebc_h.lua",
            "ffi/framebuffer_ebc.lua",
            "frontend/device/likebook/device.lua",
            "frontend/device/likebook/powerd.lua",
            "libs/libk78ebc.so",
            "libs/libk78stream.so",
            "enable-wifi.sh",
            "disable-wifi.sh",
        ):
            src = K78_KO / rel
            dst = ko / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)
            os.chmod(dst, 0o755 if rel.endswith((".sh", ".so")) else 0o644)

        k78_plug = K78_KO / "plugins" / "k78tools.koplugin"
        if k78_plug.exists():
            dst_p = ko / "plugins" / "k78tools.koplugin"
            if dst_p.exists():
                shutil.rmtree(dst_p)
            shutil.copytree(k78_plug, dst_p)

        # Persistent KOReader settings symlink -> /data/koreader-settings
        ko_set = ko / "settings"
        if ko_set.exists() and not ko_set.is_symlink():
            shutil.rmtree(ko_set)
        elif ko_set.is_symlink():
            ko_set.unlink()
        os.symlink("/data/koreader-settings", ko_set)

        # Install user's ink-away.koplugin
        if INK_AWAY.is_dir():
            shutil.copytree(INK_AWAY, ko / "plugins/ink-away.koplugin", dirs_exist_ok=True)

        # 6. Accounts, SSH key, hostname, /sbin/init, CLI helpers
        print("6. Configuring accounts, SSH, /sbin/init, and K78W CLI helpers...")
        pw_hash = subprocess.check_output(["openssl", "passwd", "-6", "k78"], text=True).strip()
        shadow_p = root / "etc/shadow"
        new_shadow = []
        for line in shadow_p.read_text(encoding="utf-8").splitlines():
            if line.startswith("root:"):
                new_shadow.append(f"root:{pw_hash}:19000:0:99999:7:::")
            else:
                new_shadow.append(line)
        write_text(shadow_p, "\n".join(new_shadow) + "\n", 0o600)
        write_text(root / "etc/hostname", "likebook-k78w\n", 0o644)
        write_text(root / "etc/hosts", "127.0.0.1\tlocalhost likebook-k78w\n", 0o644)
        write_text(root / "etc/resolv.conf", "nameserver 1.1.1.1\nnameserver 8.8.8.8\n", 0o644)
        write_text(root / "etc/profile", 'export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\nexport PS1="\\u@\\h:\\w# "\n', 0o644)

        (root / "etc/dropbear").mkdir(parents=True, exist_ok=True)
        os.chmod(root / "etc/dropbear", 0o700)
        (root / "root/.ssh").mkdir(parents=True, exist_ok=True)
        os.chmod(root / "root", 0o700)
        os.chmod(root / "root/.ssh", 0o700)
        if SSH_PUB.is_file():
            shutil.copy2(SSH_PUB, root / "root/.ssh/authorized_keys")
            os.chmod(root / "root/.ssh/authorized_keys", 0o600)
        else:
            print(f"Note: {SSH_PUB} not found; skipping authorized_keys.")
        OUT_DIR.mkdir(parents=True, exist_ok=True)

        # Clean udhcpc script executable bit
        udhcpc_scr = root / "usr/share/udhcpc/default.script"
        if udhcpc_scr.exists():
            os.chmod(udhcpc_scr, 0o755)

        write_text(root / "sbin/init", SBIN_INIT, 0o755)
        write_text(root / "usr/local/bin/k78-wifi", K78_WIFI, 0o755)
        write_text(root / "usr/local/bin/k78-syncthing", K78_SYNCTHING, 0o755)
        write_text(root / "usr/local/bin/k78-light", K78_LIGHT, 0o755)
        write_text(root / "usr/local/bin/k78-bat", K78_BAT, 0o755)
        write_text(root / "usr/local/bin/k78-sleep-test", K78_SLEEP_TEST, 0o755)

        for d in ("dev", "proc", "sys", "tmp", "run", "mnt", "mnt/sd", "data", "config", "etc/k78"):
            (root / d).mkdir(parents=True, exist_ok=True)

        # Validate shell scripts with sh -n
        for scr in (
            root / "sbin/init",
            root / "usr/local/bin/k78-wifi",
            root / "usr/local/bin/k78-syncthing",
            root / "usr/local/bin/k78-light",
            root / "usr/local/bin/k78-bat",
            root / "usr/local/bin/k78-sleep-test",
            ko / "enable-wifi.sh",
            ko / "disable-wifi.sh",
        ):
            subprocess.run(["sh", "-n", str(scr)], check=True)
        print("All shell scripts passed sh -n!")

        # 7. Pack rootfs tarball with uid=0, gid=0
        print(f"7. Packing {OUT_TAR}...")
        def reset_owner(ti: tarfile.TarInfo) -> tarfile.TarInfo:
            ti.uid = 0
            ti.gid = 0
            ti.uname = "root"
            ti.gname = "root"
            return ti

        with tarfile.open(OUT_TAR, "w:gz", compresslevel=6) as out:
            for item in sorted(root.iterdir()):
                out.add(item, arcname=item.name, filter=reset_owner)

        sz = OUT_TAR.stat().st_size
        print(f"DONE: {OUT_TAR} ({sz:,} B, {sz/1048576:.2f} MiB)")


if __name__ == "__main__":
    main()
