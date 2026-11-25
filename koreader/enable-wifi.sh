#!/bin/sh
# Enable AP6236/bcm43436b0 Wi-Fi + wpa_supplicant on Likebook K78W Pure Linux
mkdir -p /var/run/wpa_supplicant /etc/wpa_supplicant
if [ ! -f /etc/wpa_supplicant/wpa_supplicant.conf ]; then
    cat > /etc/wpa_supplicant/wpa_supplicant.conf <<'EOF'
ctrl_interface=/var/run/wpa_supplicant
update_config=1
EOF
fi
echo "/lib/firmware/fw_bcm43436b0.bin" > /sys/module/bcmdhd/parameters/firmware_path 2>/dev/null || true
echo "/lib/firmware/nvram_ap6236.txt"  > /sys/module/bcmdhd/parameters/nvram_path 2>/dev/null || true
ip link set wlan0 up 2>/dev/null || true
if ! pidof wpa_supplicant >/dev/null 2>&1; then
    wpa_supplicant -B -i wlan0 -c /etc/wpa_supplicant/wpa_supplicant.conf -D nl80211,wext >/tmp/wpa.log 2>&1 || true
fi
exit 0
