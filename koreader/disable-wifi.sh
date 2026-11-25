#!/bin/sh
# Disable Wi-Fi cleanly on Likebook K78W Pure Linux (saves battery & allows deep suspend)
killall udhcpc 2>/dev/null || true
killall wpa_supplicant 2>/dev/null || true
rm -rf /var/run/wpa_supplicant/wlan0 2>/dev/null || true
ip addr flush dev wlan0 2>/dev/null || true
ip link set wlan0 down 2>/dev/null || true
exit 0
