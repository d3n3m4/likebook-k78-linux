#!/usr/bin/env python3
"""
k78_display_host.py — Mode Mini-Cintiq / 2e Écran E-Ink 85 Hz pour Likebook Ares Note K78W.

Capture nativement un écran, une fenêtre, ou un **Nouvel Écran Virtuel KDE Wayland**
via org.freedesktop.portal.ScreenCast + PipeWire + GStreamer, encode en < 1.2 ms via
libk78enc_x64.so (Bayer 4x4 85Hz / Texte Pur 85Hz / HQ 16-Gris + Auto-HQ + Delta-XOR PackBits),
et diffuse en temps réel sur TCP 19781 vers le Likebook K78W (USB 192.168.7.2 ou Wi-Fi).
"""

import argparse
import ctypes
import os
import select
import signal
import socket
import struct
import sys
import termios
import threading
import time
import tty
from pathlib import Path

import dbus
from dbus.mainloop.glib import DBusGMainLoop
import gi

gi.require_version("Gst", "1.0")
from gi.repository import GLib, Gst

PORT = 19781
EBC_W = 1872
EBC_H = 1404

BASE_DIR = Path(__file__).resolve().parent
_ENV_ENC = os.environ.get("K78_ENC_SO")
ENC_SO = (
    Path(_ENV_ENC)
    if _ENV_ENC
    else (
        BASE_DIR.parent / "bin" / "libk78enc_x64.so"
        if (BASE_DIR.parent / "bin" / "libk78enc_x64.so").exists()
        else BASE_DIR / "bin" / "libk78enc_x64.so"
    )
)
CACHE_DIR = Path.home() / ".cache" / "k78-screen"
TOKEN_FILE = CACHE_DIR / "restore_token"

MODE_NAMES = {0: "85Hz Bayer", 1: "85Hz Texte", 2: "HQ 16-Gris"}
ORIENT_NAMES = {2: "Paysage (USB-G)", 1: "Paysage (USB-D)", 0: "Portrait"}


def load_encoder():
    if not ENC_SO.is_file():
        raise FileNotFoundError(
            f"{ENC_SO} not found — run `make host` at the repository root first."
        )
    lib = ctypes.CDLL(str(ENC_SO))
    lib.k78_encode_frame.restype = ctypes.c_size_t
    lib.k78_encode_frame.argtypes = [
        ctypes.c_void_p,  # gray_src
        ctypes.c_void_p,  # curr_buf
        ctypes.c_void_p,  # prev_buf
        ctypes.c_void_p,  # delta_buf
        ctypes.c_void_p,  # pkt_out
        ctypes.c_size_t,  # pkt_cap
        ctypes.c_int,     # mode
        ctypes.c_int,     # orient
        ctypes.c_int,     # invert
        ctypes.c_int,     # threshold
        ctypes.c_int,     # force_full
        ctypes.c_int,     # force_flash
    ]
    return lib


class PortalScreenCast:
    """Clean KDE Plasma / XDG Desktop Portal ScreenCast session (supports Virtual Output!)."""

    def __init__(self, force_pick: bool = False):
        self.force_pick = force_pick
        self.bus = dbus.SessionBus()
        self.portal = self.bus.get_object(
            "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop"
        )
        self.sc = dbus.Interface(self.portal, "org.freedesktop.portal.ScreenCast")
        self.sender = self.bus.get_unique_name().lstrip(":").replace(".", "_")
        self.session_handle = None
        self.node_id = None
        self.pw_fd = None
        self._req_n = 0

    def _call_req(self, fn, *args, **kwargs):
        self._req_n += 1
        token = f"k78s_{os.getpid()}_{self._req_n}"
        req_path = f"/org/freedesktop/portal/desktop/request/{self.sender}/{token}"
        result = {}
        loop = GLib.MainLoop()

        def on_resp(response, results):
            result["code"] = int(response)
            result["data"] = results
            loop.quit()

        sig = self.bus.add_signal_receiver(
            on_resp,
            dbus_interface="org.freedesktop.portal.Request",
            signal_name="Response",
            path=req_path,
        )
        try:
            opts = kwargs.get("options", {})
            opts["handle_token"] = token
            fn(*args, opts)
            loop.run()
        finally:
            sig.remove()

        if result.get("code", 1) != 0:
            raise RuntimeError(f"Portal ScreenCast annulé ou refusé (code={result.get('code')})")
        return result["data"]

    def start(self):
        # 1. CreateSession
        sess_token = f"k78sess_{os.getpid()}"
        res = self._call_req(
            self.sc.CreateSession,
            options={"session_handle_token": sess_token},
        )
        self.session_handle = str(res["session_handle"])

        # 2. SelectSources: Monitor(1) | Window(2) | Virtual(4) = 7, Cursor Embedded(2), persist=2
        sel_opts = {
            "types": dbus.UInt32(1 | 2 | 4),
            "multiple": dbus.Boolean(False),
            "cursor_mode": dbus.UInt32(2),
            "persist_mode": dbus.UInt32(2),
        }
        if not self.force_pick and TOKEN_FILE.exists():
            saved = TOKEN_FILE.read_text(encoding="utf-8").strip()
            if saved:
                sel_opts["restore_token"] = dbus.String(saved)

        self._call_req(self.sc.SelectSources, self.session_handle, options=sel_opts)

        # 3. Start (pops KDE picker once; remembers choice if user ticks Mémoriser!)
        res = self._call_req(self.sc.Start, self.session_handle, "", options={})
        new_tok = str(res.get("restore_token", ""))
        if new_tok:
            CACHE_DIR.mkdir(parents=True, exist_ok=True)
            TOKEN_FILE.write_text(new_tok, encoding="utf-8")

        streams = res.get("streams", [])
        if not streams:
            raise RuntimeError("Aucun flux PipeWire retourné par le portail.")
        self.node_id = int(streams[0][0])

        # 4. OpenPipeWireRemote -> UnixFd
        ufd = self.sc.OpenPipeWireRemote(self.session_handle, dbus.Dictionary({}, signature="sv"))
        self.pw_fd = ufd.take()
        return self.pw_fd, self.node_id

    def close(self):
        if self.pw_fd is not None:
            try:
                os.close(self.pw_fd)
            except OSError:
                pass
            self.pw_fd = None
        if self.session_handle:
            try:
                s = self.bus.get_object("org.freedesktop.portal.Desktop", self.session_handle)
                dbus.Interface(s, "org.freedesktop.portal.Session").Close()
            except Exception:
                pass
            self.session_handle = None


class K78DisplayStreamer:
    def __init__(self, host: str, port: int, mode: int, orient: int, invert: bool, auto_hq: bool, fps: int):
        self.host = host
        self.port = port
        self.mode = mode
        self.orient = orient
        self.invert = invert
        self.auto_hq = auto_hq
        self.max_fps = fps
        self.threshold = 138

        self.enc = load_encoder()
        self.curr_buf = (ctypes.c_ubyte * (EBC_W * EBC_H // 2))()
        self.prev_1b  = (ctypes.c_ubyte * (EBC_W * EBC_H // 8))()
        self.prev_4b  = (ctypes.c_ubyte * (EBC_W * EBC_H // 2))()
        self.delta_buf = (ctypes.c_ubyte * (EBC_W * EBC_H // 2))()
        self.pkt_out = (ctypes.c_ubyte * 1400000)()

        self.lock = threading.Lock()
        self.sock = None
        self.running = True
        self.force_full = True
        self.force_flash = False
        self.last_was_hq = False
        self._last_status_str = ""
        self._big_motion = False

        self.latest_gray = None
        self.latest_seq = 0
        self.sent_seq = 0
        self.last_motion_t = 0.0
        self.hq_settled = True

        self.frames_sent = 0
        self.bytes_sent = 0
        self.stat_t0 = time.monotonic()
        self.fps_cur = 0.0
        self.kbps_cur = 0.0

        self.pipeline = None
        self.capsfilter = None

    def target_dims(self):
        return (EBC_H, EBC_W) if self.orient == 0 else (EBC_W, EBC_H)

    def build_pipeline(self, pw_fd: int, node_id: int):
        w, h = self.target_dims()
        pipe_str = (
            f"pipewiresrc fd={pw_fd} path={node_id} do-timestamp=true keepalive-time=1000 ! "
            f"videoconvert ! "
            f"videoscale method=1 add-borders=true ! "
            f"capsfilter name=cf caps=video/x-raw,format=GRAY8,width={w},height={h} ! "
            f"appsink name=sink emit-signals=true max-buffers=2 drop=true sync=false"
        )
        self.pipeline = Gst.parse_launch(pipe_str)
        self.capsfilter = self.pipeline.get_by_name("cf")
        sink = self.pipeline.get_by_name("sink")
        sink.connect("new-sample", self._on_sample)
        self.pipeline.set_state(Gst.State.PLAYING)

    def update_caps(self):
        if not self.capsfilter:
            return
        w, h = self.target_dims()
        caps = Gst.Caps.from_string(f"video/x-raw,format=GRAY8,width={w},height={h}")
        self.capsfilter.set_property("caps", caps)

    def _on_sample(self, sink):
        sample = sink.emit("pull-sample")
        if not sample:
            return Gst.FlowReturn.OK
        buf = sample.get_buffer()
        ok, mapinfo = buf.map(Gst.MapFlags.READ)
        if not ok:
            return Gst.FlowReturn.OK
        try:
            if mapinfo.size == EBC_W * EBC_H:
                data = bytes(mapinfo.data)
                with self.lock:
                    self.latest_gray = data
                    self.latest_seq += 1
        finally:
            buf.unmap(mapinfo)
        return Gst.FlowReturn.OK

    def _send_all(self, view):
        if not self.sock:
            return False
        try:
            self.sock.sendall(view)
            return True
        except OSError:
            self._drop_sock()
            return False

    def _drop_sock(self):
        if self.sock:
            try:
                self.sock.close()
            except OSError:
                pass
            self.sock = None

    def _poll_client_cmds(self):
        if not self.sock:
            return
        try:
            r, _, _ = select.select([self.sock], [], [], 0)
            if not r:
                return
            data = self.sock.recv(256)
            if not data:
                self._drop_sock()
                return
            # 4-byte control commands from Likebook: b'C', cmd, val, 0
            i = 0
            while i + 4 <= len(data):
                if data[i] == 0x43:  # 'C'
                    cmd = chr(data[i + 1])
                    val = data[i + 2]
                    self.apply_cmd(cmd, val)
                    i += 4
                else:
                    i += 1
        except OSError:
            self._drop_sock()

    def apply_cmd(self, cmd: str, val: int):
        changed_orient = False
        with self.lock:
            if cmd == "M" and val in (0, 1, 2):
                self.mode = val
                self.force_full = True
            elif cmd == "A":
                self.auto_hq = bool(val)
            elif cmd == "I":
                self.invert = bool(val)
                self.force_full = True
            elif cmd == "O" and val in (0, 1, 2):
                if self.orient != val:
                    self.orient = val
                    self.force_full = True
                    changed_orient = True
            elif cmd == "F":
                self.force_full = True
                self.force_flash = bool(val)
            elif cmd == "Q":
                self.running = False
        if changed_orient:
            GLib.idle_add(self.update_caps)

    def _has_usb_subnet(self):
        if self.host != "192.168.7.2":
            return True
        try:
            with open("/proc/net/route", "r", encoding="utf-8") as f:
                for line in f.readlines()[1:]:
                    parts = line.split()
                    # 192.168.7.0 in little-endian hex = 0007A8C0
                    if len(parts) >= 2 and parts[1] == "0007A8C0":
                        return True
        except OSError:
            return True
        return False

    def _connect_if_needed(self):
        if self.sock:
            return True
        if not self._has_usb_subnet():
            self._usb_missing = True
            return False
        self._usb_missing = False
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(1.2)
        try:
            s.connect((self.host, self.port))
            s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            s.settimeout(3.0)
            self.sock = s
            with self.lock:
                self.force_full = True
                self.force_flash = False
                self.hq_settled = False
                self.last_was_hq = False
            return True
        except OSError:
            s.close()
            return False

    def net_loop(self):
        min_dt = 1.0 / max(1, self.max_fps)
        last_send_t = 0.0
        while self.running:
            if not self._connect_if_needed():
                self._print_status(connected=False)
                time.sleep(0.7)
                continue

            self._poll_client_cmds()
            if not self.sock:
                continue

            now = time.monotonic()
            with self.lock:
                gray = self.latest_gray
                seq = self.latest_seq
                mode = self.mode
                orient = self.orient
                invert = self.invert
                auto_hq = self.auto_hq
                force_full = self.force_full
                force_flash = self.force_flash

            if gray is None:
                time.sleep(0.01)
                continue

            # Auto-HQ settle (optional): 1.8s after REAL motion (>4% screen) -> one crisp 16-gray HQ frame!
            do_auto_hq = (
                auto_hq
                and mode in (0, 1)
                and self._big_motion
                and not self.hq_settled
                and (now - self.last_motion_t) >= 1.8
                and not force_full
            )

            if not force_full and not do_auto_hq and seq == self.sent_seq:
                time.sleep(0.008)
                continue

            if not force_full and not do_auto_hq and (now - last_send_t) < min_dt:
                time.sleep(0.004)
                continue

            eff_mode = 2 if do_auto_hq else mode
            prev_target = self.prev_4b if eff_mode == 2 else self.prev_1b
            need_full = force_full or do_auto_hq

            src_ptr = ctypes.c_char_p(gray)
            pkt_len = self.enc.k78_encode_frame(
                src_ptr,
                self.curr_buf,
                prev_target,
                self.delta_buf,
                self.pkt_out,
                len(self.pkt_out),
                eff_mode,
                orient,
                1 if invert else 0,
                self.threshold,
                1 if need_full else 0,
                1 if force_flash else 0,
            )

            with self.lock:
                if force_full:
                    self.force_full = False
                if force_flash:
                    self.force_flash = False
            self.sent_seq = seq

            if pkt_len > 0:
                if not self._send_all(memoryview(self.pkt_out)[:pkt_len]):
                    continue
                last_send_t = now
                self.frames_sent += 1
                self.bytes_sent += pkt_len
                if do_auto_hq:
                    self.hq_settled = True
                    self._big_motion = False
                    self.last_was_hq = True
                else:
                    self.last_was_hq = (eff_mode == 2)
                    if eff_mode != 2:
                        self.last_motion_t = now
                        self.hq_settled = False
                        # Only flag big motion when dirty rect covers > 4% of panel
                        x1, y1, x2, y2 = struct.unpack("<HHHH", bytes(self.pkt_out[6:14]))
                        if (x2 - x1) * (y2 - y1) > (EBC_W * EBC_H // 25):
                            self._big_motion = True

            if (now - self.stat_t0) >= 1.5:
                dt = now - self.stat_t0
                self.fps_cur = self.frames_sent / dt
                self.kbps_cur = (self.bytes_sent / 1024.0) / dt
                had_activity = self.frames_sent > 0
                self.frames_sent = 0
                self.bytes_sent = 0
                self.stat_t0 = now
                if had_activity or self.fps_cur == 0.0:
                    self._print_status(connected=True)

        self._drop_sock()

    def _print_status(self, connected: bool):
        if connected:
            st = "● CONNECTÉ"
        elif getattr(self, "_usb_missing", False):
            st = "○ USB 192.168.7.x INACTIF (branche/redémarre Likebook ou --host <IP-WiFi>)"
        else:
            st = "○ ATTENTE LIKEBOOK (ouvre App: Ecran eink)"
        m = MODE_NAMES.get(self.mode, "?")
        o = ORIENT_NAMES.get(self.orient, "?")
        ahq = "ON" if self.auto_hq else "OFF"
        inv = "ON" if self.invert else "OFF"
        line = (
            f"\r{st} [{self.host}:{self.port}] | {m} | Auto-HQ:{ahq} | Inv:{inv} | {o} | "
            f"{self.fps_cur:4.1f} fps | {self.kbps_cur:6.1f} Ko/s   "
        )
        if line != self._last_status_str:
            self._last_status_str = line
            sys.stdout.write(line)
            sys.stdout.flush()

    def stop(self):
        self.running = False
        if self.pipeline:
            self.pipeline.set_state(Gst.State.NULL)


def key_listener(streamer: K78DisplayStreamer, mainloop: GLib.MainLoop):
    if not sys.stdin.isatty():
        return
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    try:
        tty.setcbreak(fd)
        while streamer.running:
            r, _, _ = select.select([fd], [], [], 0.2)
            if not r:
                continue
            ch = sys.stdin.read(1).lower()
            if ch == "q":
                streamer.running = False
                GLib.idle_add(mainloop.quit)
                break
            elif ch == "m":
                streamer.apply_cmd("M", (streamer.mode + 1) % 3)
            elif ch == "a":
                streamer.apply_cmd("A", 0 if streamer.auto_hq else 1)
            elif ch == "i":
                streamer.apply_cmd("I", 0 if streamer.invert else 1)
            elif ch == "o":
                nxt = {2: 1, 1: 0, 0: 2}[streamer.orient]
                streamer.apply_cmd("O", nxt)
            elif ch == "f":
                streamer.apply_cmd("F", 1)
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)


def main():
    ap = argparse.ArgumentParser(description="Likebook K78W Mini-Cintiq / 2e Écran E-Ink 85 Hz")
    ap.add_argument("--host", default="192.168.7.2", help="IP du Likebook (défaut USB: 192.168.7.2)")
    ap.add_argument("--port", type=int, default=PORT)
    ap.add_argument("--mode", type=int, default=0, choices=(0, 1, 2), help="0=85Hz Bayer, 1=85Hz Texte, 2=HQ 16-Gris")
    ap.add_argument("--orient", type=int, default=2, choices=(0, 1, 2), help="2=Paysage USB-G, 1=Paysage USB-D, 0=Portrait")
    ap.add_argument("--invert", action="store_true", help="Inverser (Dark Mode -> papier blanc)")
    ap.add_argument("--auto-hq", action="store_true", help="Activer l'affinage HQ auto 1.8s après un mouvement")
    ap.add_argument("--fps", type=int, default=35, help="FPS max (défaut: 35)")
    ap.add_argument("--pick", action="store_true", help="Forcer le sélecteur d'écran/fenêtre KDE")
    args = ap.parse_args()

    DBusGMainLoop(set_as_default=True)
    Gst.init(None)

    print("=== Likebook K78W — 2e Écran E-Ink 85 Hz / Mini-Cintiq ===")
    print("Astuce KDE : choisis 'Nouvel écran virtuel' pour un vrai 2e bureau, ou une fenêtre/écran.")
    print("Raccourcis : [M] Mode  [A] Auto-HQ  [I] Inverser Dark-Mode  [O] Orientation  [F] Flash  [Q] Quitter\n")

    portal = PortalScreenCast(force_pick=args.pick)
    try:
        pw_fd, node_id = portal.start()
    except Exception as e:
        print(f"Erreur ScreenCast KDE : {e}", file=sys.stderr)
        portal.close()
        return 1

    streamer = K78DisplayStreamer(
        host=args.host,
        port=args.port,
        mode=args.mode,
        orient=args.orient,
        invert=args.invert,
        auto_hq=args.auto_hq,
        fps=args.fps,
    )
    streamer.build_pipeline(pw_fd, node_id)

    mainloop = GLib.MainLoop()

    def on_sig(_s, _f):
        streamer.running = False
        GLib.idle_add(mainloop.quit)

    signal.signal(signal.SIGINT, on_sig)
    signal.signal(signal.SIGTERM, on_sig)

    t_net = threading.Thread(target=streamer.net_loop, daemon=True)
    t_net.start()
    t_key = threading.Thread(target=key_listener, args=(streamer, mainloop), daemon=True)
    t_key.start()

    try:
        mainloop.run()
    finally:
        streamer.stop()
        t_net.join(timeout=1.5)
        portal.close()
        print("\nArrêt propre du 2e écran E-Ink.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
