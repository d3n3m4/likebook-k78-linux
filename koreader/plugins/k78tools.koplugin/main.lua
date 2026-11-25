--[[
k78tools.koplugin — Barre rapide et lanceur d'apps custom pour Likebook Ares Note K78W (Linux Pur).

Ajoute 5 icônes 1-tap à droite de l'icône crayon d'Ink Away dans la barre de menu KOReader :
  1. k78.eink  : Modes E-Ink (Auto GC16+Waterfall 85Hz / Waterfall forcé / Qualité GC16 / Flash / Mode Nuit)
  2. k78.light : Éclairage froid / chaud (panneau natif KOReader en 1 tap)
  3. k78.wifi  : Wi-Fi & Syncthing (bascule rapide + réseaux + URL & IP)
  4. k78.apps  : Lanceur Apps Custom (/data/apps/*.sh et *.lua) + Rotation + État système + Alimentation
  5. k78.sleep : Mise en veille matérielle immédiate (Suspend-to-RAM)
]]--

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")

local Screen = Device.screen

local K78Tools = WidgetContainer:extend{
    name = "k78tools",
    is_doc_only = false,
}

local APPS_DIR = "/data/apps"
local ICON_NAMES = { "k78.eink", "k78.light", "k78.wifi", "k78.apps", "k78.sleep" }

local function readAll(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function readLine(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*l")
    f:close()
    return s
end

local function cmdOut(cmd)
    local p = io.popen(cmd .. " 2>&1", "r")
    if not p then return "" end
    local out = p:read("*a") or ""
    p:close()
    return out
end

local function copyIfChanged(src, dst)
    local data = readAll(src)
    if not data then return false end
    if lfs.attributes(dst) and readAll(dst) == data then return true end
    local out = io.open(dst, "wb")
    if not out then return false end
    out:write(data)
    out:close()
    return true
end

local function installIcons(plugin_dir)
    local data_dir = DataStorage:getDataDir()
    local cwd = lfs.currentdir()
    for _, dir in ipairs({ data_dir and (data_dir .. "/icons"), cwd and (cwd .. "/resources/icons") }) do
        if dir then
            pcall(function()
                if lfs.attributes(dir, "mode") ~= "directory" then lfs.mkdir(dir) end
                for _, name in ipairs(ICON_NAMES) do
                    copyIfChanged(plugin_dir .. "icons/" .. name .. ".svg", dir .. "/" .. name .. ".svg")
                end
            end)
        end
    end
end

local function closeTopMenu(menu)
    local mc = menu and menu.menu_container
    if mc then
        local tm = mc[1]
        if tm and tm.close_callback then
            tm.close_callback()
        else
            UIManager:close(mc)
        end
        menu.menu_container = nil
    end
end

local function isSyncthingRunning()
    return os.execute("pidof syncthing >/dev/null 2>&1") == 0
end

local function getIfaceIP(iface)
    local ip = cmdOut("ip -4 -o addr show dev " .. iface .. " 2>/dev/null | awk '{print $4}' | cut -d/ -f1")
    ip = ip:gsub("%s+$", "")
    return ip ~= "" and ip or nil
end

local function getWifiSSID()
    local s = cmdOut("iw dev wlan0 link 2>/dev/null | awk -F'SSID: ' '/SSID:/{print $2}'")
    s = s:gsub("%s+$", "")
    return s ~= "" and s or nil
end

local function buildSystemReport()
    local lines = {}
    local cap = readLine("/sys/class/power_supply/battery/capacity") or "?"
    local st = readLine("/sys/class/power_supply/battery/status") or "?"
    local uv = tonumber(readLine("/sys/class/power_supply/battery/voltage_now") or "") or 0
    local ua = tonumber(readLine("/sys/class/power_supply/battery/current_now") or "") or 0
    local temp_bat = tonumber(readLine("/sys/class/power_supply/battery/temp") or "") or 0
    local temp_cpu = tonumber(readLine("/sys/class/thermal/thermal_zone0/temp") or "") or 0
    local bl_c = readLine("/sys/class/backlight/rk28_bl/brightness") or "?"
    local bl_w = readLine("/sys/class/backlight/rk28_bl_warm/brightness") or "?"
    local mode = Screen.getK78Mode and Screen:getK78Mode() or "?"
    local usb_ip = getIfaceIP("usb0") or "débranché"
    local wifi_ip = getIfaceIP("wlan0") or "coupé"
    local ssid = getWifiSSID() or "-"
    local st_run = isSyncthingRunning() and "ACTIF" or "ARRÊTÉ"

    table.insert(lines, "=== Likebook Ares Note K78W — Linux Pur ===")
    table.insert(lines, "")
    table.insert(lines, string.format("Batterie   : %s%% (%s)", cap, st))
    table.insert(lines, string.format("Tension    : %.2f V  |  Courant : %.0f mA", uv / 1e6, ua / 1000))
    table.insert(lines, string.format("Temp.      : CPU %.1f °C  |  Batterie %.1f °C", temp_cpu / 1000, temp_bat / 10))
    table.insert(lines, string.format("Éclairage  : Froid %s/255  |  Chaud %s/255", bl_c, bl_w))
    table.insert(lines, string.format("Mode E-Ink : %s", mode))
    table.insert(lines, "")
    table.insert(lines, string.format("USB RNDIS  : %s  (SSH root@192.168.7.2)", usb_ip))
    table.insert(lines, string.format("Wi-Fi      : %s  (SSID: %s)", wifi_ip, ssid))
    local sync_ip = (wifi_ip ~= "coupé") and wifi_ip or usb_ip
    table.insert(lines, string.format("Syncthing  : %s  (http://%s:8384)", st_run, sync_ip))
    table.insert(lines, "")
    table.insert(lines, "--- Uptime & Mémoire ---")
    table.insert(lines, (cmdOut("uptime"):gsub("%s+$", "")))
    table.insert(lines, (cmdOut("free -m"):gsub("%s+$", "")))
    table.insert(lines, "")
    table.insert(lines, "--- Stockage ---")
    table.insert(lines, (cmdOut("df -h / /data /mnt/sd 2>/dev/null | uniq"):gsub("%s+$", "")))
    return table.concat(lines, "\n")
end

-- 1. Dialog Mode E-Ink (Auto / Waterfall 85Hz / Haute Qualité / Flash / Mode Nuit)
function K78Tools:showEinkDialog()
    local cur = Screen.getK78Mode and Screen:getK78Mode() or "auto"
    local night = Screen.night_mode and true or false
    local dlg
    local function pick(mode, label)
        if Screen.setK78Mode then Screen:setK78Mode(mode) end
        UIManager:close(dlg)
        UIManager:show(InfoMessage:new{ text = "Mode E-Ink : " .. label, timeout = 1.5 })
    end
    local function mark(m) return (cur == m) and "● " or "○ " end

    dlg = ButtonDialog:new{
        title = "Mode E-Ink K78W",
        title_align = "center",
        buttons = {
            { {
                text = mark("auto") .. "Auto (GC16 + Stylet Waterfall 85 Hz)",
                callback = function() pick("auto", "Auto (GC16 + Waterfall 85 Hz)") end,
            } },
            { {
                text = mark("waterfall") .. "Ultra-Rapide (Waterfall 85 Hz forcé)",
                callback = function() pick("waterfall", "Ultra-Rapide Waterfall 85 Hz") end,
            } },
            { {
                text = mark("hq") .. "Haute Qualité (GC16 16 gris uniquement)",
                callback = function() pick("hq", "Haute Qualité GC16") end,
            } },
            { {
                text = "Nettoyer l'écran (Flash complet)",
                callback = function()
                    UIManager:close(dlg)
                    UIManager:nextTick(function()
                        if Screen.cleanFlash then
                            Screen:cleanFlash()
                        else
                            UIManager:setDirty("all", "full")
                        end
                    end)
                end,
            } },
            { {
                text = night and "Désactiver le Mode Nuit" or "Activer le Mode Nuit",
                callback = function()
                    UIManager:close(dlg)
                    UIManager:broadcastEvent(Event:new("ToggleNightMode"))
                end,
            } },
            { {
                text = "Fermer",
                callback = function() UIManager:close(dlg) end,
            } },
        },
    }
    UIManager:show(dlg)
end

-- 2. Éclairage Froid / Chaud en 1 tap
function K78Tools:showFrontlight()
    UIManager:broadcastEvent(Event:new("ShowFlDialog"))
end

-- 3. Dialog Wi-Fi & Syncthing
function K78Tools:showWifiSyncDialog()
    local wifi_on = NetworkMgr:isWifiOn()
    local wifi_ip = getIfaceIP("wlan0")
    local ssid = getWifiSSID()
    local st_on = isSyncthingRunning()
    local usb_ip = getIfaceIP("usb0") or "192.168.7.2"
    local url_ip = wifi_ip or usb_ip

    local header = string.format(
        "Wi-Fi : %s\nSyncthing : %s\nWeb UI : http://%s:8384",
        wifi_on and ((ssid or "Actif") .. (wifi_ip and (" (" .. wifi_ip .. ")") or " (sans IP)")) or "Coupé",
        st_on and "Actif" or "Arrêté",
        url_ip
    )

    local dlg
    dlg = ButtonDialog:new{
        title = header,
        title_align = "center",
        buttons = {
            { {
                text = wifi_on and "Couper le Wi-Fi" or "Activer le Wi-Fi",
                callback = function()
                    UIManager:close(dlg)
                    if wifi_on then
                        NetworkMgr:turnOffWifi(function()
                            UIManager:show(InfoMessage:new{ text = "Wi-Fi coupé.", timeout = 1.5 })
                        end)
                    else
                        NetworkMgr:turnOnWifi(nil, true)
                    end
                end,
            } },
            { {
                text = "Choisir un réseau Wi-Fi…",
                callback = function()
                    UIManager:close(dlg)
                    if not NetworkMgr:isWifiOn() then
                        NetworkMgr:turnOnWifi(nil, true)
                    elseif NetworkMgr.showNetworkMenu then
                        NetworkMgr:showNetworkMenu()
                    else
                        NetworkMgr:reconnectOrShowNetworkMenu(nil, true)
                    end
                end,
            } },
            { {
                text = st_on and "Arrêter Syncthing (économie batterie)" or "Démarrer Syncthing",
                callback = function()
                    UIManager:close(dlg)
                    if st_on then
                        os.execute("/usr/local/bin/k78-syncthing stop >/dev/null 2>&1")
                        UIManager:show(InfoMessage:new{ text = "Syncthing arrêté.", timeout = 1.5 })
                    else
                        os.execute("/usr/local/bin/k78-syncthing start >/dev/null 2>&1")
                        UIManager:show(InfoMessage:new{
                            text = "Syncthing démarré.\nWeb UI : http://" .. url_ip .. ":8384",
                            timeout = 2.5,
                        })
                    end
                end,
            } },
            { {
                text = "Fermer",
                callback = function() UIManager:close(dlg) end,
            } },
        },
    }
    UIManager:show(dlg)
end

-- Scan /data/apps/*.sh and /data/apps/*.lua
local function listCustomApps()
    local apps = {}
    if lfs.attributes(APPS_DIR, "mode") ~= "directory" then
        pcall(lfs.mkdir, APPS_DIR)
        return apps
    end
    for entry in lfs.dir(APPS_DIR) do
        if entry:sub(1, 1) ~= "." then
            local full = APPS_DIR .. "/" .. entry
            if lfs.attributes(full, "mode") == "file" then
                local ext = entry:lower():match("%.([a-z0-9]+)$")
                if ext == "sh" or ext == "lua" then
                    local title = entry:gsub("^%d+[_%-]", ""):gsub("%.[^%.]+$", ""):gsub("[_%-]", " ")
                    title = title:sub(1, 1):upper() .. title:sub(2)
                    table.insert(apps, { name = entry, title = title, path = full, ext = ext })
                end
            end
        end
    end
    table.sort(apps, function(a, b) return a.name < b.name end)
    return apps
end

function K78Tools:runCustomApp(app)
    if app.ext == "lua" then
        local ok, res = pcall(dofile, app.path)
        if not ok then
            UIManager:show(InfoMessage:new{ text = "Erreur app Lua :\n" .. tostring(res) })
        elseif type(res) == "function" then
            local ok2, err2 = pcall(res, self.ui)
            if not ok2 then
                UIManager:show(InfoMessage:new{ text = "Erreur exécution :\n" .. tostring(err2) })
            end
        end
    else
        local out = cmdOut("sh '" .. app.path:gsub("'", "'\\''") .. "'")
        if out == "" then out = "(Terminé sans sortie)" end
        UIManager:show(TextViewer:new{
            title = app.title,
            text = out,
        })
    end
end

-- 4. Dialog Apps Custom & Outils K78W
function K78Tools:showAppsDialog()
    local dlg
    local buttons = {
        {
            {
                text = "Portrait ↔ Paysage",
                callback = function()
                    UIManager:close(dlg)
                    UIManager:broadcastEvent(Event:new("SwapRotation"))
                end,
            },
            {
                text = "Pivoter +90°",
                callback = function()
                    UIManager:close(dlg)
                    UIManager:broadcastEvent(Event:new("IterateRotation"))
                end,
            },
        },
        { {
            text = "État système K78W (Batterie / RAM / Disques / IP)",
            callback = function()
                UIManager:close(dlg)
                UIManager:show(TextViewer:new{
                    title = "Système K78W — Linux Pur",
                    text = buildSystemReport(),
                })
            end,
        } },
    }

    local custom = listCustomApps()
    for _, app in ipairs(custom) do
        local a = app
        table.insert(buttons, { {
            text = "App : " .. a.title,
            callback = function()
                UIManager:close(dlg)
                self:runCustomApp(a)
            end,
        } })
    end

    table.insert(buttons, {
        {
            text = "Relancer KOReader",
            callback = function()
                UIManager:close(dlg)
                UIManager:restartKOReader()
            end,
        },
        {
            text = "Redémarrer / Éteindre",
            callback = function()
                UIManager:close(dlg)
                local pdlg
                pdlg = ButtonDialog:new{
                    title = "Alimentation K78W",
                    title_align = "center",
                    buttons = {
                        { {
                            text = "Redémarrer le Likebook",
                            callback = function()
                                UIManager:close(pdlg)
                                UIManager:show(ConfirmBox:new{
                                    text = "Redémarrer le Likebook K78W ?",
                                    ok_callback = function() Device:reboot() end,
                                })
                            end,
                        } },
                        { {
                            text = "Éteindre complètement",
                            callback = function()
                                UIManager:close(pdlg)
                                UIManager:show(ConfirmBox:new{
                                    text = "Éteindre complètement le Likebook K78W ?",
                                    ok_callback = function() Device:powerOff() end,
                                })
                            end,
                        } },
                        { { text = "Annuler", callback = function() UIManager:close(pdlg) end } },
                    },
                }
                UIManager:show(pdlg)
            end,
        },
    })

    table.insert(buttons, { {
        text = "Fermer  (dossier apps : /data/apps/)",
        callback = function() UIManager:close(dlg) end,
    } })

    dlg = ButtonDialog:new{
        title = "Apps & Outils K78W",
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dlg)
end

-- 5. Mise en veille immédiate
function K78Tools:triggerSleep()
    UIManager:broadcastEvent(Event:new("RequestSuspend"))
end

-- Patch FileManagerMenu & ReaderMenu to insert our 5 icons right after Ink Away's pencil icon
local function patchMenuClass(menu_class)
    if not menu_class or menu_class.__k78tools_patched then return end
    local orig = menu_class.setUpdateItemTable
    if type(orig) ~= "function" then return end
    menu_class.__k78tools_patched = true

    menu_class.setUpdateItemTable = function(self, ...)
        orig(self, ...)
        local tabs = self.tab_item_table
        if type(tabs) ~= "table" then return end
        for _, t in ipairs(tabs) do
            if t.icon == "k78.eink" then return end
        end

        -- Find insertion position: right after inkaway.tab if present, else right before last tab (appbar.menu)
        local pos = math.max(1, #tabs)
        for i, t in ipairs(tabs) do
            if t.icon == "inkaway.tab" then
                pos = i + 1
                break
            end
        end

        local function wrap(action)
            return function()
                UIManager:nextTick(function()
                    closeTopMenu(self)
                    local plugin = self.ui and K78Tools.by_ui[self.ui]
                    if plugin then action(plugin) end
                end)
            end
        end

        local entries = {
            { icon = "k78.eink",  remember = false, callback = wrap(function(p) p:showEinkDialog() end) },
            { icon = "k78.light", remember = false, callback = wrap(function(p) p:showFrontlight() end) },
            { icon = "k78.wifi",  remember = false, callback = wrap(function(p) p:showWifiSyncDialog() end) },
            { icon = "k78.apps",  remember = false, callback = wrap(function(p) p:showAppsDialog() end) },
            { icon = "k78.sleep", remember = false, callback = wrap(function(p) p:triggerSleep() end) },
        }
        for idx, entry in ipairs(entries) do
            table.insert(tabs, pos + idx - 1, entry)
        end
    end
end

K78Tools.by_ui = setmetatable({}, { __mode = "k" })

function K78Tools:init()
    K78Tools.by_ui[self.ui] = self
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)

    if not K78Tools._installed then
        K78Tools._installed = true
        local dir = debug.getinfo(1, "S").source:match("^@(.*/)main%.lua$") or "./"
        installIcons(dir)
        for _, mod in ipairs({ "apps/filemanager/filemanagermenu", "apps/reader/modules/readermenu" }) do
            local ok, cls = pcall(require, mod)
            if ok then patchMenuClass(cls) end
        end
    end
end

function K78Tools:onDispatcherRegisterActions()
    Dispatcher:registerAction("k78_eink_mode", {
        category = "none", event = "K78EinkMenu",
        title = _("K78W : Mode E-Ink"), general = true,
    })
    Dispatcher:registerAction("k78_apps_menu", {
        category = "none", event = "K78AppsMenu",
        title = _("K78W : Apps Custom & Outils"), general = true,
    })
    Dispatcher:registerAction("k78_wifi_sync", {
        category = "none", event = "K78WifiSync",
        title = _("K78W : Wi-Fi & Syncthing"), general = true,
    })
end

function K78Tools:onK78EinkMenu() self:showEinkDialog(); return true end
function K78Tools:onK78AppsMenu() self:showAppsDialog(); return true end
function K78Tools:onK78WifiSync() self:showWifiSyncDialog(); return true end

function K78Tools:addToMainMenu(menu_items)
    menu_items.k78tools = {
        text = _("K78W Outils & Modes"),
        sorting_hint = "tools",
        sub_item_table = {
            { text = _("Mode E-Ink (Auto / Waterfall 85 Hz / GC16)"),
              keep_menu_open = false,
              callback = function() self:showEinkDialog() end },
            { text = _("Wi-Fi & Syncthing"),
              keep_menu_open = false,
              callback = function() self:showWifiSyncDialog() end },
            { text = _("Apps Custom & Système (/data/apps)"),
              keep_menu_open = false,
              callback = function() self:showAppsDialog() end },
        },
    }
end

return K78Tools
