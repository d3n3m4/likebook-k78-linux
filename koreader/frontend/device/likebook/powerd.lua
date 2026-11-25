--[[
frontend/device/likebook/powerd.lua — Power, battery, dual frontlight (cold+warm)
for Boyue Likebook Ares Note K78W running Pure Linux.
]]--

local BasePowerD = require("device/generic/powerd")
local ffiUtil = require("ffi/util")

local COLD_BL = "/sys/class/backlight/rk28_bl/brightness"
local WARM_BL = "/sys/class/backlight/rk28_bl_warm/brightness"
local BAT_CAP = "/sys/class/power_supply/battery/capacity"
local BAT_STATUS = "/sys/class/power_supply/battery/status"

local LikebookPowerD = BasePowerD:new{
    fl_min = 0,
    fl_max = 100,
    fl_warmth_min = 0,
    fl_warmth_max = 100,
    fl_intensity = 0,
    fl_warmth = 30,
}

function LikebookPowerD:init()
    self.fl_intensity = G_reader_settings:readSetting("frontlight_intensity") or 0
    self.fl_warmth = G_reader_settings:readSetting("frontlight_warmth") or 30
    self.is_fl_on = G_reader_settings:readSetting("is_frontlight_on") or false
    if self.is_fl_on and self.fl_intensity > 0 then
        self:_applyLights(self.fl_intensity, self.fl_warmth)
    else
        self:_applyLights(0, self.fl_warmth)
        self.is_fl_on = false
    end
end

function LikebookPowerD:saveSettings()
    G_reader_settings:saveSetting("frontlight_intensity", self.fl_intensity)
    G_reader_settings:saveSetting("frontlight_warmth", self.fl_warmth)
    G_reader_settings:saveSetting("is_frontlight_on", self.is_fl_on)
end

function LikebookPowerD:_applyLights(intensity, warmth)
    local inten = math.max(0, math.min(100, intensity or 0))
    local warm = math.max(0, math.min(100, warmth or 0))
    local cold_hw = 0
    local warm_hw = 0
    if inten > 0 then
        -- Mix cold and warm channels cleanly across 0..255 PWM range
        cold_hw = math.floor(inten * (100 - warm) * 255 / 10000 + 0.5)
        warm_hw = math.floor(inten * warm * 255 / 10000 + 0.5)
        -- Guarantee at least 1 PWM step when intensity > 0
        if cold_hw == 0 and warm_hw == 0 then
            if warm >= 50 then warm_hw = 1 else cold_hw = 1 end
        end
    end
    ffiUtil.writeToSysfs(cold_hw, COLD_BL)
    ffiUtil.writeToSysfs(warm_hw, WARM_BL)
end

function LikebookPowerD:frontlightIntensityHW()
    return self.fl_intensity or 0
end

function LikebookPowerD:frontlightWarmthHW()
    return self.fl_warmth or 30
end

function LikebookPowerD:isFrontlightOnHW()
    return self.is_fl_on == true
end

function LikebookPowerD:setIntensityHW(intensity)
    self.fl_intensity = math.max(0, math.min(100, intensity or 0))
    self:_applyLights(self.fl_intensity, self.fl_warmth)
    self:_decideFrontlightState()
    self:saveSettings()
end

function LikebookPowerD:setWarmthHW(warmth)
    self.fl_warmth = math.max(0, math.min(100, warmth or 0))
    if self.is_fl_on and self.fl_intensity > 0 then
        self:_applyLights(self.fl_intensity, self.fl_warmth)
    end
    self:saveSettings()
end

function LikebookPowerD:turnOffFrontlightHW(done_callback)
    self:_applyLights(0, self.fl_warmth)
    return false
end

function LikebookPowerD:turnOnFrontlightHW(done_callback)
    if (self.fl_intensity or 0) <= 0 then
        self.fl_intensity = 10
    end
    self:_applyLights(self.fl_intensity, self.fl_warmth)
    return false
end

function LikebookPowerD:getCapacityHW()
    return self:read_int_file(BAT_CAP) or 0
end

function LikebookPowerD:isChargingHW()
    local st = self:read_str_file(BAT_STATUS)
    return st == "Charging" or st == "Full"
end

function LikebookPowerD:isChargedHW()
    return self:read_str_file(BAT_STATUS) == "Full"
end

function LikebookPowerD:beforeSuspend()
    self.fl_was_on = self.is_fl_on
    self.device:_beforeSuspend()
    self:_applyLights(0, self.fl_warmth)
end

function LikebookPowerD:afterResume()
    if self.fl_was_on and (self.fl_intensity or 0) > 0 then
        self:_applyLights(self.fl_intensity, self.fl_warmth)
    else
        self:_applyLights(0, self.fl_warmth)
    end
    self:invalidateCapacityCache()
    self.device:_afterResume()
end

return LikebookPowerD
