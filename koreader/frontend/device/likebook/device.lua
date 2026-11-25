--[[
frontend/device/likebook/device.lua — Native Pure Linux KOReader port
for Boyue Likebook Ares Note K78W (RK3368, 7.8" 1404x1872 E-ink + Wacom EMR + Dual FL).
]]--

local Generic = require("device/generic/device")
local logger = require("logger")
local ffi = require("ffi")
local C = ffi.C
require("ffi/linux_input_h")

local function yes() return true end
local function no() return false end

local SCREEN_W = 1404
local SCREEN_H = 1872

-- Exact axis ranges will be calibrated dynamically via EVIOCGABS (with safe defaults)
local Likebook = Generic:extend{
    model = "Likebook_K78W",
    isLikebook = yes,
    isTouchDevice = yes,
    hasKeys = yes,
    hasFrontlight = yes,
    hasNaturalLight = yes,
    canTurnFrontlightOff = yes,
    hasWifiManager = yes,
    hasWifiToggle = yes,
    hasFastWifiStatusQuery = yes,
    canSuspend = yes,
    canReboot = yes,
    canPowerOff = yes,
    canHWInvert = no,
    hasSystemFonts = yes,
    needsScreenRefreshAfterResume = no,
    display_dpi = 226,
    home_dir = "/data",

    input_wacom = "/dev/input/event0",
    input_ts    = "/dev/input/event1",
    input_btn   = "/dev/input/event2",
    input_keys  = "/dev/input/event4",

    -- Touch/Wacom calibration (measured via EVIOCGABS on live K78W)
    mt_max_x = 1403,
    mt_max_y = 1871,
    mt_swap_xy = false,
    mt_mirror_x = false,
    mt_mirror_y = false,

    wacom_max_x = 11864,
    wacom_max_y = 15818,
    wacom_swap_xy = false,
    wacom_mirror_x = false,
    wacom_mirror_y = false,

    -- Live Wacom EMR telemetry exposed to stylus apps (pressure, hover distance, tilt)
    wacom_pressure = 0.0,
    wacom_distance = 255,
    wacom_tilt_x = 0.0,
    wacom_tilt_y = 0.0,
    wacom_in_range = false,
    wacom_touching = false,
}

function Likebook:init()
    self.screen = require("ffi/framebuffer_ebc"):new{
        device = self,
        debug  = logger.dbg,
    }
    self.powerd = require("device/likebook/powerd"):new{ device = self }

    local event_map = {
        [116] = "Power",
        [158] = "Back",
    }

    self.input = require("device/input"):new{
        device = self,
        event_map = event_map,
        wacom_protocol = true,
    }
    -- Capacitive touch (cyttsp5_mt) and Wacom digitizer are separate devices:
    -- use handleMixedTouchEv so panel ABS_X/Y never collide with Wacom stylus slots.
    self.input.handleTouchEv = self.input.handleMixedTouchEv

    -- Open touchscreen, capacitive Back button, Power/keypad, and Wacom digitizer
    self.input:open(self.input_ts)
    self.input:open(self.input_btn)
    self.input:open(self.input_keys)
    self.input:open(self.input_wacom)

    local dev = self
    self.input:registerEventAdjustHook(function(this, ev)
        -- Track Wacom EMR pen hover / contact state (EV_KEY=1: BTN_TOOL_PEN=320, BTN_TOOL_RUBBER=321, BTN_TOUCH=330)
        if ev.type == C.EV_KEY then
            if ev.code == C.BTN_TOOL_PEN or ev.code == C.BTN_TOOL_RUBBER then
                dev.wacom_in_range = (ev.value ~= 0)
                if ev.value == 0 then
                    dev.wacom_touching = false
                    dev.wacom_pressure = 0.0
                    dev.wacom_distance = 255
                end
            elseif ev.code == C.BTN_TOUCH and dev.wacom_in_range then
                dev.wacom_touching = (ev.value ~= 0)
                if ev.value == 0 then dev.wacom_pressure = 0.0 end
            end
            return
        end
        if ev.type ~= C.EV_ABS then return end
        -- Wacom EMR 3D telemetry: pressure (0..4095), hover distance (0..255), tilt X/Y (-9000..9000)
        if ev.code == 24 then -- ABS_PRESSURE
            dev.wacom_pressure = math.max(0.0, math.min(1.0, ev.value / 4095.0))
            return
        elseif ev.code == 25 then -- ABS_DISTANCE
            dev.wacom_distance = math.max(0, math.min(255, ev.value))
            return
        elseif ev.code == 26 then -- ABS_TILT_X
            local v = ev.value > 32767 and (ev.value - 65536) or ev.value
            dev.wacom_tilt_x = math.max(-1.0, math.min(1.0, v / 9000.0))
            return
        elseif ev.code == 27 then -- ABS_TILT_Y
            local v = ev.value > 32767 and (ev.value - 65536) or ev.value
            dev.wacom_tilt_y = math.max(-1.0, math.min(1.0, v / 9000.0))
            return
        end
        -- Capacitive multitouch (ABS_MT_POSITION_X=53, ABS_MT_POSITION_Y=54)
        if ev.code == C.ABS_MT_POSITION_X or ev.code == C.ABS_MT_POSITION_Y then
            if dev.mt_swap_xy then
                if ev.code == C.ABS_MT_POSITION_X then
                    ev.code = C.ABS_MT_POSITION_Y
                    local v = dev.mt_mirror_y and (dev.mt_max_y - ev.value) or ev.value
                    ev.value = math.floor(v * SCREEN_H / dev.mt_max_y + 0.5)
                else
                    ev.code = C.ABS_MT_POSITION_X
                    local v = dev.mt_mirror_x and (dev.mt_max_x - ev.value) or ev.value
                    ev.value = math.floor(v * SCREEN_W / dev.mt_max_x + 0.5)
                end
            else
                if ev.code == C.ABS_MT_POSITION_X then
                    local v = dev.mt_mirror_x and (dev.mt_max_x - ev.value) or ev.value
                    ev.value = math.floor(v * SCREEN_W / dev.mt_max_x + 0.5)
                else
                    local v = dev.mt_mirror_y and (dev.mt_max_y - ev.value) or ev.value
                    ev.value = math.floor(v * SCREEN_H / dev.mt_max_y + 0.5)
                end
            end
        -- Wacom EMR stylus (ABS_X=0, ABS_Y=1)
        elseif ev.code == C.ABS_X or ev.code == C.ABS_Y then
            if dev.wacom_swap_xy then
                if ev.code == C.ABS_X then
                    ev.code = C.ABS_Y
                    local v = dev.wacom_mirror_y and (dev.wacom_max_y - ev.value) or ev.value
                    ev.value = math.floor(v * SCREEN_H / dev.wacom_max_y + 0.5)
                else
                    ev.code = C.ABS_X
                    local v = dev.wacom_mirror_x and (dev.wacom_max_x - ev.value) or ev.value
                    ev.value = math.floor(v * SCREEN_W / dev.wacom_max_x + 0.5)
                end
            else
                if ev.code == C.ABS_X then
                    local v = dev.wacom_mirror_x and (dev.wacom_max_x - ev.value) or ev.value
                    ev.value = math.floor(v * SCREEN_W / dev.wacom_max_x + 0.5)
                else
                    local v = dev.wacom_mirror_y and (dev.wacom_max_y - ev.value) or ev.value
                    ev.value = math.floor(v * SCREEN_H / dev.wacom_max_y + 0.5)
                end
            end
        end
    end)

    Generic.init(self)
end

function Likebook:supportsScreensaver() return true end

function Likebook:initNetworkManager(NetworkMgr)
    function NetworkMgr:turnOnWifi(complete_callback, interactive)
        os.execute("/opt/koreader/enable-wifi.sh")
        return self:reconnectOrShowNetworkMenu(complete_callback, interactive)
    end

    function NetworkMgr:turnOffWifi(complete_callback)
        os.execute("/opt/koreader/disable-wifi.sh")
        if complete_callback then complete_callback() end
    end

    function NetworkMgr:obtainIP()
        os.execute("killall udhcpc 2>/dev/null; udhcpc -i wlan0 -b -q -t 8 -T 2 -s /usr/share/udhcpc/default.script >/tmp/udhcpc.log 2>&1")
    end

    function NetworkMgr:releaseIP()
        os.execute("killall udhcpc 2>/dev/null; ip addr flush dev wlan0 2>/dev/null")
    end

    function NetworkMgr:restoreWifiAsync()
        os.execute("(/opt/koreader/enable-wifi.sh && sleep 2 && udhcpc -i wlan0 -b -q -t 8 -T 2 -s /usr/share/udhcpc/default.script) >/tmp/wifi_async.log 2>&1 &")
    end

    function NetworkMgr:getNetworkInterfaceName()
        return "wlan0"
    end

    NetworkMgr:setWirelessBackend("wpa_supplicant", {
        ctrl_interface = "/var/run/wpa_supplicant/wlan0",
    })
    function NetworkMgr:isWifiOn()
        local f = io.open("/sys/class/net/wlan0/flags", "r")
        if not f then return false end
        local flags = tonumber(f:read("*l")) or 0
        f:close()
        return (flags % 2 == 1) and (os.execute("[ -S /var/run/wpa_supplicant/wlan0 ]") == 0)
    end
    NetworkMgr.isConnected = NetworkMgr.ifHasAnAddress
end

function Likebook:suspend()
    if self.screen and self.screen.prepareSuspend then
        self.screen:prepareSuspend()
    end
    -- Shut down Wi-Fi cleanly before deep sleep (AP6236 SDIO hates active suspend)
    os.execute("/opt/koreader/disable-wifi.sh >/dev/null 2>&1")
    -- Unbind dwc_otg USB gadget before suspend so RNDIS DMA never wedges on wake!
    os.execute("echo '' > /config/usb_gadget/g1/UDC 2>/dev/null || true")
    os.execute("sync")
    -- Real RK3368 suspend-to-RAM; wakes on Power button (rockchip-key wakeup=enabled)
    os.execute("echo mem > /sys/power/state")
end

function Likebook:resume()
    -- Keep Wi-Fi off until user enables it (max battery life),
    -- and cleanly re-enumerate USB RNDIS gadget + dnsmasq after suspend!
    os.execute("/usr/local/bin/k78-usb-reset >/tmp/k78-usb-reset.log 2>&1 &")
end

function Likebook:powerOff()
    os.execute("/sbin/rk_reboot poweroff")
end

function Likebook:reboot()
    os.execute("/sbin/rk_reboot")
end

function Likebook:saveSettings()
    self.powerd:saveSettings()
end

function Likebook:setEventHandlers(UIManager)
    UIManager.event_handlers.Suspend = function()
        self:onPowerEvent("Suspend")
    end
    UIManager.event_handlers.Resume = function()
        self:onPowerEvent("Resume")
    end
    UIManager.event_handlers.PowerPress = function()
        UIManager:scheduleIn(2.5, UIManager.poweroff_action)
    end
    UIManager.event_handlers.PowerRelease = function()
        if not UIManager._entered_poweroff_stage then
            UIManager:unschedule(UIManager.poweroff_action)
            if self.screen_saver_mode then
                if self.screen_saver_lock then
                    UIManager.event_handlers.Suspend()
                else
                    UIManager.event_handlers.Resume()
                end
            else
                UIManager.event_handlers.Suspend()
            end
        end
    end
end

return Likebook
