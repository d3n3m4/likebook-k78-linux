#!/usr/bin/env python3
"""
k78_tablet_host.py — Native Linux uinput Wacom Tablet + Trackpad + ExpressKeys receiver
for Boyue Likebook Ares Note K78W (Pure Linux) on Linux (KDE Plasma / GNOME / Wayland & X11).

Creates 3 clean uinput devices (zero sudo needed when /dev/uinput is user-writable):
  1. "Likebook K78W Wacom Tablet"  (ABS_X/Y, 4096-level Pressure, Hover Distance, Tilt X/Y, Rubber/Stylus)
  2. "Likebook K78W Trackpad"      (REL_X/Y, Scroll Wheel, Left/Right/Middle clicks)
  3. "Likebook K78W ExpressKeys"   (Customizable E-Ink Stream Deck shortcuts)

Two clean transports:
  - USB Host Client (default, ZERO firewall/ufw config needed!): automatically connects
    outbound to Likebook USB 192.168.7.2:19782 whenever App: Tablette PC or App: Ecran eink is open!
  - Optional UDP listener on 0.0.0.0:19780 (for Wi-Fi mode if 19780/udp is allowed).
"""

import fcntl
import os
import signal
import socket
import struct
import sys
import threading
import time

UDP_PORT = 19780
USB_HOST = "192.168.7.2"
USB_TCP_PORT = 19782

# Linux uinput ioctl constants (64-bit LP64)
UI_DEV_CREATE  = 0x5501
UI_DEV_DESTROY = 0x5502
UI_DEV_SETUP   = 0x405c5503
UI_ABS_SETUP   = 0x401c5504
UI_SET_EVBIT   = 0x40045564
UI_SET_KEYBIT  = 0x40045565
UI_SET_RELBIT  = 0x40045566
UI_SET_ABSBIT  = 0x40045567
UI_SET_PROPBIT = 0x4004556e

EV_SYN = 0x00
EV_KEY = 0x01
EV_REL = 0x02
EV_ABS = 0x03
SYN_REPORT = 0

INPUT_PROP_POINTER = 0x00

ABS_X        = 0x00
ABS_Y        = 0x01
ABS_PRESSURE = 0x18
ABS_DISTANCE = 0x19
ABS_TILT_X   = 0x1a
ABS_TILT_Y   = 0x1b

REL_X      = 0x00
REL_Y      = 0x01
REL_HWHEEL = 0x06
REL_WHEEL  = 0x08

BTN_LEFT        = 0x110
BTN_RIGHT       = 0x111
BTN_MIDDLE      = 0x112
BTN_TOOL_PEN    = 0x140
BTN_TOOL_RUBBER = 0x141
BTN_TOUCH       = 0x14a
BTN_STYLUS      = 0x14b
BTN_STYLUS2     = 0x14c

KEY_LEFTCTRL  = 29
KEY_LEFTSHIFT = 42
KEY_LEFTALT   = 56
KEY_LEFTMETA  = 125

MOD_MAP = [
    (0x01, KEY_LEFTCTRL),
    (0x02, KEY_LEFTSHIFT),
    (0x04, KEY_LEFTALT),
    (0x08, KEY_LEFTMETA),
]

ALL_KEYS = list(range(1, 128)) + [113, 114, 115, 164]

ABS_MAX_X = 15818
ABS_MAX_Y = 11864


class UInputDev:
    def __init__(self, name: str, vendor: int = 0x2d1f, product: int = 0x0056):
        self.fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
        self.name = name
        self.vendor = vendor
        self.product = product
        self._buf = bytearray()

    def set_ev(self, ev): fcntl.ioctl(self.fd, UI_SET_EVBIT, ev)
    def set_key(self, code): fcntl.ioctl(self.fd, UI_SET_KEYBIT, code)
    def set_rel(self, code): fcntl.ioctl(self.fd, UI_SET_RELBIT, code)
    def set_prop(self, prop): fcntl.ioctl(self.fd, UI_SET_PROPBIT, prop)

    def set_abs(self, code, lo, hi, res=0):
        fcntl.ioctl(self.fd, UI_SET_ABSBIT, code)
        setup = struct.pack("<HHiiiiii", code, 0, 0, lo, hi, 0, 0, res)
        fcntl.ioctl(self.fd, UI_ABS_SETUP, setup)

    def create(self):
        setup = struct.pack("<HHHH80sI", 0x03, self.vendor, self.product, 1,
                            self.name.encode("utf-8")[:79], 0)
        fcntl.ioctl(self.fd, UI_DEV_SETUP, setup)
        fcntl.ioctl(self.fd, UI_DEV_CREATE)

    def emit(self, ev_type: int, code: int, value: int):
        self._buf += struct.pack("<qqHHi", 0, 0, ev_type, code, int(value))

    def syn(self):
        self._buf += struct.pack("<qqHHi", 0, 0, EV_SYN, SYN_REPORT, 0)
        os.write(self.fd, self._buf)
        self._buf.clear()

    def close(self):
        try:
            fcntl.ioctl(self.fd, UI_DEV_DESTROY)
        except OSError:
            pass
        try:
            os.close(self.fd)
        except OSError:
            pass


def create_tablet():
    d = UInputDev("Likebook K78W Wacom Tablet", vendor=0x2d1f, product=0x0056)
    d.set_ev(EV_SYN); d.set_ev(EV_KEY); d.set_ev(EV_ABS)
    d.set_prop(INPUT_PROP_POINTER)
    for k in (BTN_TOOL_PEN, BTN_TOOL_RUBBER, BTN_TOUCH, BTN_STYLUS, BTN_STYLUS2):
        d.set_key(k)
    d.set_abs(ABS_X, 0, ABS_MAX_X, res=100)
    d.set_abs(ABS_Y, 0, ABS_MAX_Y, res=100)
    d.set_abs(ABS_PRESSURE, 0, 4095, res=0)
    d.set_abs(ABS_DISTANCE, 0, 255, res=0)
    d.set_abs(ABS_TILT_X, -90, 90, res=57)
    d.set_abs(ABS_TILT_Y, -90, 90, res=57)
    d.create()
    return d


def create_trackpad():
    d = UInputDev("Likebook K78W Trackpad", vendor=0x2d1f, product=0x0057)
    d.set_ev(EV_SYN); d.set_ev(EV_KEY); d.set_ev(EV_REL)
    for k in (BTN_LEFT, BTN_RIGHT, BTN_MIDDLE):
        d.set_key(k)
    for r in (REL_X, REL_Y, REL_WHEEL, REL_HWHEEL):
        d.set_rel(r)
    d.create()
    return d


def create_keyboard():
    d = UInputDev("Likebook K78W ExpressKeys", vendor=0x2d1f, product=0x0058)
    d.set_ev(EV_SYN); d.set_ev(EV_KEY)
    for k in set(ALL_KEYS):
        d.set_key(k)
    d.create()
    return d


class InputInjector:
    def __init__(self):
        self.lock = threading.Lock()
        self.tablet = create_tablet()
        self.mouse = create_trackpad()
        self.kbd = create_keyboard()
        self.pen_in_range = False
        self.pen_rubber = False
        self.pen_touch = False
        self.pen_btn1 = False
        self.pen_btn2 = False
        self.mouse_btns = 0
        self.last_pen_ts = 0.0

    def lift_pen(self):
        with self.lock:
            self._lift_pen_locked()

    def _lift_pen_locked(self):
        if not self.pen_in_range:
            return
        if self.pen_touch:
            self.tablet.emit(EV_KEY, BTN_TOUCH, 0)
            self.pen_touch = False
        if self.pen_btn1:
            self.tablet.emit(EV_KEY, BTN_STYLUS, 0)
            self.pen_btn1 = False
        if self.pen_btn2:
            self.tablet.emit(EV_KEY, BTN_STYLUS2, 0)
            self.pen_btn2 = False
        self.tablet.emit(EV_ABS, ABS_PRESSURE, 0)
        self.tablet.emit(EV_KEY, BTN_TOOL_RUBBER if self.pen_rubber else BTN_TOOL_PEN, 0)
        self.tablet.syn()
        self.pen_in_range = False

    def watchdog(self):
        with self.lock:
            if self.pen_in_range and (time.monotonic() - self.last_pen_ts) > 0.6:
                self._lift_pen_locked()

    def handle_packet(self, data: bytes):
        if len(data) < 2 or data[0] != 0x4B:
            return
        ptype = data[1]

        with self.lock:
            if ptype == 1 and len(data) >= 15:
                _, _, flags, x, y, press, dist, tx, ty = struct.unpack("<BBBHHHHhh", data[:15])
                in_r   = bool(flags & 0x01)
                touch  = bool(flags & 0x02)
                rubber = bool(flags & 0x04)
                btn1   = bool(flags & 0x08)
                btn2   = bool(flags & 0x10)
                self.last_pen_ts = time.monotonic()

                if in_r:
                    if self.pen_in_range and rubber != self.pen_rubber:
                        self.tablet.emit(EV_KEY, BTN_TOOL_RUBBER if self.pen_rubber else BTN_TOOL_PEN, 0)
                        self.pen_in_range = False
                    if not self.pen_in_range:
                        self.tablet.emit(EV_KEY, BTN_TOOL_RUBBER if rubber else BTN_TOOL_PEN, 1)
                        self.pen_in_range = True
                        self.pen_rubber = rubber
                    self.tablet.emit(EV_ABS, ABS_X, max(0, min(ABS_MAX_X, x)))
                    self.tablet.emit(EV_ABS, ABS_Y, max(0, min(ABS_MAX_Y, y)))
                    self.tablet.emit(EV_ABS, ABS_PRESSURE, max(0, min(4095, press if touch else 0)))
                    self.tablet.emit(EV_ABS, ABS_DISTANCE, max(0, min(255, 0 if touch else dist)))
                    self.tablet.emit(EV_ABS, ABS_TILT_X, max(-90, min(90, tx)))
                    self.tablet.emit(EV_ABS, ABS_TILT_Y, max(-90, min(90, ty)))
                    if touch != self.pen_touch:
                        self.tablet.emit(EV_KEY, BTN_TOUCH, 1 if touch else 0)
                        self.pen_touch = touch
                    if btn1 != self.pen_btn1:
                        self.tablet.emit(EV_KEY, BTN_STYLUS, 1 if btn1 else 0)
                        self.pen_btn1 = btn1
                    if btn2 != self.pen_btn2:
                        self.tablet.emit(EV_KEY, BTN_STYLUS2, 1 if btn2 else 0)
                        self.pen_btn2 = btn2
                    self.tablet.syn()
                else:
                    self._lift_pen_locked()

            elif ptype == 2 and len(data) >= 11:
                _, _, dx, dy, wv, wh, bmask = struct.unpack("<BBhhhhB", data[:11])
                if dx: self.mouse.emit(EV_REL, REL_X, dx)
                if dy: self.mouse.emit(EV_REL, REL_Y, dy)
                if wv: self.mouse.emit(EV_REL, REL_WHEEL, wv)
                if wh: self.mouse.emit(EV_REL, REL_HWHEEL, wh)
                for bit, btn in ((1, BTN_LEFT), (2, BTN_RIGHT), (4, BTN_MIDDLE)):
                    if (bmask & bit) != (self.mouse_btns & bit):
                        self.mouse.emit(EV_KEY, btn, 1 if (bmask & bit) else 0)
                self.mouse_btns = bmask
                self.mouse.syn()

            elif ptype == 3 and len(data) >= 6:
                _, _, mods, kcode, action = struct.unpack("<BBBHB", data[:6])
                if action == 2:
                    for bit, mk in MOD_MAP:
                        if mods & bit: self.kbd.emit(EV_KEY, mk, 1)
                    self.kbd.emit(EV_KEY, kcode, 1)
                    self.kbd.syn()
                    time.sleep(0.012)
                    self.kbd.emit(EV_KEY, kcode, 0)
                    for bit, mk in reversed(MOD_MAP):
                        if mods & bit: self.kbd.emit(EV_KEY, mk, 0)
                    self.kbd.syn()
                else:
                    if action == 1:
                        for bit, mk in MOD_MAP:
                            if mods & bit: self.kbd.emit(EV_KEY, mk, 1)
                        self.kbd.emit(EV_KEY, kcode, 1)
                    else:
                        self.kbd.emit(EV_KEY, kcode, 0)
                        for bit, mk in reversed(MOD_MAP):
                            if mods & bit: self.kbd.emit(EV_KEY, mk, 0)
                    self.kbd.syn()

    def close(self):
        self.tablet.close()
        self.mouse.close()
        self.kbd.close()


def has_usb_subnet() -> bool:
    try:
        with open("/proc/net/route", "r", encoding="utf-8") as f:
            for line in f.readlines()[1:]:
                parts = line.split()
                if len(parts) >= 2 and parts[1] == "0007A8C0":
                    return True
    except OSError:
        return False
    return False


def recv_exact(sock: socket.socket, n: int):
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return bytes(buf)


def usb_tcp_client_loop(inj: InputInjector, stop_ev: threading.Event):
    """Outbound TCP client to Likebook USB 192.168.7.2:19782 (zero inbound firewall ports!)."""
    while not stop_ev.is_set():
        if not has_usb_subnet():
            stop_ev.wait(0.8)
            continue
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(0.5)
        try:
            s.connect((USB_HOST, USB_TCP_PORT))
            s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            s.settimeout(1.0)
            print(f"Connected to Likebook USB tablet {USB_HOST}:{USB_TCP_PORT}", flush=True)
            while not stop_ev.is_set():
                try:
                    hdr = recv_exact(s, 1)
                    if not hdr:
                        break
                    plen = hdr[0]
                    if plen == 0 or plen > 120:
                        break
                    pkt = recv_exact(s, plen)
                    if not pkt:
                        break
                    inj.handle_packet(pkt)
                except socket.timeout:
                    inj.watchdog()
                    continue
        except OSError:
            pass
        finally:
            try:
                s.close()
            except OSError:
                pass
            inj.lift_pen()
        stop_ev.wait(0.4)


def main():
    inj = InputInjector()
    stop_ev = threading.Event()

    def on_sig(_s, _f):
        stop_ev.set()
    signal.signal(signal.SIGINT, on_sig)
    signal.signal(signal.SIGTERM, on_sig)

    t_usb = threading.Thread(target=usb_tcp_client_loop, args=(inj, stop_ev), daemon=True)
    t_usb.start()

    # Optional UDP listener for Wi-Fi users (if 19780/udp is allowed in firewall)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("0.0.0.0", UDP_PORT))
    sock.settimeout(0.5)

    print(f"k78_tablet_host ready: USB auto-connect {USB_HOST}:{USB_TCP_PORT} + optional UDP :{UDP_PORT}", flush=True)

    try:
        while not stop_ev.is_set():
            try:
                data, addr = sock.recvfrom(128)
            except socket.timeout:
                inj.watchdog()
                continue
            if len(data) >= 2 and data[0] == 0x4B and data[1] == 4:
                sock.sendto(b"KPONG", addr)
            else:
                inj.handle_packet(data)
    finally:
        stop_ev.set()
        sock.close()
        t_usb.join(timeout=1.5)
        inj.close()
        print("k78_tablet_host stopped cleanly.", flush=True)


if __name__ == "__main__":
    main()
