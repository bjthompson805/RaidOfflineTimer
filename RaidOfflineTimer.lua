-- RaidOfflineTimer.lua  (v3 – restored settings window, subtitle, slim scrollbar)
-- Numeric timestamps only; 0 = offline, waiting for real timestamp

local RaidOfflineTimer = {}
local offlineTimers    = {}   -- [playerName] = timestamp | 0 (pending)
local playerLocation   = {}   -- [playerName] = location | null

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("VARIABLES_LOADED")
frame:RegisterEvent("GROUP_ROSTER_UPDATE")
frame:RegisterEvent("UNIT_CONNECTION")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:RegisterEvent("GROUP_JOINED")

frame:SetScript("OnEvent", function(_, event, ...)
    if RaidOfflineTimer[event] then RaidOfflineTimer[event](RaidOfflineTimer, ...) end
end)

---------------------------------------------------------------------
-- Helpers ----------------------------------------------------------
---------------------------------------------------------------------
local now = GetServerTime      -- realm‑wide epoch
local function fmtClock(sec)   -- mm:ss
    local m = math.floor(sec/60)
    local s = math.floor(sec%60)
    return string.format("%02d:%02d", m, s)
end
local function raidOrParty() return IsInRaid() and "RAID" or "PARTY" end

---------------------------------------------------------------------
-- PLAYER_LOGIN -----------------------------------------------------
---------------------------------------------------------------------
local settingsFrame            -- forward‑declare for slash cmd reuse
function RaidOfflineTimer:PLAYER_LOGIN()
    if not RaidOfflineTimerDB then
        RaidOfflineTimerDB = {
            enablePrint = false,
            showPanel   = false,
            panelWidth  = 250,
            panelHeight = 200,
        }
    end
    self.settings = RaidOfflineTimerDB
    C_ChatInfo.RegisterAddonMessagePrefix("RaidOfflineTimer")

    ----------------------------------------------------------------
    -- MAIN PANEL ---------------------------------------------------
    ----------------------------------------------------------------
    local panel = CreateFrame("Frame", "RaidOfflinePanel", UIParent, "BackdropTemplate")
    panel:SetSize(self.settings.panelWidth, self.settings.panelHeight)
    local p, px, py = self.settings.panelPoint or "CENTER", self.settings.panelX or 0, self.settings.panelY or 0
    panel:SetPoint(p, UIParent, p, px, py)
    panel:SetBackdrop({ bgFile = "Interface/Tooltips/UI-Tooltip-Background" })
    panel:SetBackdropColor(0,0,0,0.7)
    panel:SetMovable(true); panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", function(selfF)
        selfF:StopMovingOrSizing()
        local pt, _, _, xO, yO = selfF:GetPoint()
        RaidOfflineTimerDB.panelPoint, RaidOfflineTimerDB.panelX, RaidOfflineTimerDB.panelY = pt, xO, yO
    end)

    panel.title = panel:CreateFontString(nil, "OVERLAY")
    panel.title:SetFont("Fonts\\FRIZQT__.TTF", 12)
    panel.title:SetTextColor(1,0.82,0)
    panel.title:SetPoint("TOP", 0, -10)
    panel.title:SetText("Raid Offline Timer")

    panel.subtitle = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    panel.subtitle:SetPoint("TOP", panel.title, "BOTTOM", 0, -2)
    panel.subtitle:SetText("/ROT")

    local scroll = CreateFrame("ScrollFrame", "ROTScroll", panel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -45)
    scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -15, 1)

    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(self.settings.panelWidth-50, 400)
    scroll:SetScrollChild(content)

    local font = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    font:SetJustifyH("LEFT")
    font:SetPoint("TOPLEFT")
    font:SetWidth(self.settings.panelWidth-50)
    font:SetText("No one offline.")

    panel.content = font
    self.panel   = panel

    -- Slim scrollbar tweaks
    C_Timer.After(0, function()
        local sb = scroll.ScrollBar; if not sb then return end
        sb:SetWidth(6)
        if sb.ThumbTexture then sb.ThumbTexture:SetWidth(6) end
        if sb.ScrollUpButton then
            sb.ScrollUpButton:SetSize(8,8)
            sb.ScrollUpButton:ClearAllPoints()
            sb.ScrollUpButton:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", 13, -1)
        end
        if sb.ScrollDownButton then
            sb.ScrollDownButton:SetSize(8,8)
            sb.ScrollDownButton:ClearAllPoints()
            sb.ScrollDownButton:SetPoint("BOTTOMRIGHT", scroll, "BOTTOMRIGHT", 13, 2)
        end
    end)

    -- Close button for panel
    local closeBtn = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT")
    closeBtn:SetScale(0.6)
    closeBtn:SetScript("OnClick", function() panel:Hide(); self.settings.showPanel=false end)

    ----------------------------------------------------------------
    -- PANEL UPDATER ------------------------------------------------
    ----------------------------------------------------------------
    panel.elapsed = 0
    panel:SetScript("OnUpdate", function(_, dt)
        panel.elapsed = panel.elapsed + dt
        if panel.elapsed < 1 then return end
        panel.elapsed = 0

        if not self.settings.showPanel then panel:Hide(); return end
        panel:Show()

        local lines = {}
        for name, ts in pairs(offlineTimers) do
            if ts > 0 then
                local lastKnownLocation = playerLocation[name]
                if not lastKnownLocation then
                    lastKnownLocation = "Unknown"
                end

                lines[#lines+1] = string.format("%s: %s (%s)", name, fmtClock(now()-ts), lastKnownLocation)
            end
        end
        table.sort(lines)
        panel.content:SetText(next(lines) and table.concat(lines, "\n") or "No one offline.")
    end)

    ----------------------------------------------------------------
    -- SETTINGS WINDOW (lazy‑create) -------------------------------
    ----------------------------------------------------------------
    local function openSettings()
        if not settingsFrame then
            settingsFrame = CreateFrame("Frame", "ROTSettingsFrame", UIParent, "BackdropTemplate")
            settingsFrame:SetSize(360, 400)
            settingsFrame:SetPoint("CENTER", 0, 200)
            settingsFrame:SetBackdrop({ bgFile = "Interface/Tooltips/UI-Tooltip-Background" })
            settingsFrame:SetBackdropColor(0,0,0,0.8)

            settingsFrame.title = settingsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            settingsFrame.title:SetPoint("TOP", 0, -10)
            settingsFrame.title:SetText("ROT Settings")

            local close = CreateFrame("Button", nil, settingsFrame, "UIPanelCloseButton")
            close:SetPoint("TOPRIGHT")

            -- Enable print checkbox
            local printChk = CreateFrame("CheckButton", "ROTPrintCheckbox", settingsFrame, "ChatConfigCheckButtonTemplate")
            printChk:SetPoint("TOPLEFT", 10, -30)
            printChk.Text:SetText("Enable Print Notifications")
            printChk:SetChecked(self.settings.enablePrint)
            printChk:SetScript("OnClick", function() self.settings.enablePrint = printChk:GetChecked() end)

            -- Show panel checkbox
            local panelChk = CreateFrame("CheckButton", "ROTPanelCheckbox", settingsFrame, "ChatConfigCheckButtonTemplate")
            panelChk:SetPoint("TOPLEFT", 10, -55)
            panelChk.Text:SetText("Show Offline Panel")
            panelChk:SetChecked(self.settings.showPanel)
            panelChk:SetScript("OnClick", function()
                self.settings.showPanel = panelChk:GetChecked()
                panel:SetShown(self.settings.showPanel)
            end)

            -- Width slider
            local wLabel = settingsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            wLabel:SetPoint("TOPLEFT", 10, -90)
            wLabel:SetText("Panel Width")
            local wSlider = CreateFrame("Slider", "ROTWidthSlider", settingsFrame, "OptionsSliderTemplate")
            wSlider:SetPoint("TOPLEFT", 10, -110)
            wSlider:SetMinMaxValues(150, 600)
            wSlider:SetValue(self.settings.panelWidth)
            wSlider:SetValueStep(10)
            wSlider:SetWidth(250)
            wSlider:SetScript("OnValueChanged", function(_, val)
                RaidOfflineTimerDB.panelWidth = val
                panel:SetWidth(val)
                panel.content:SetWidth(val-20)
            end)

            -- Height slider
            local hLabel = settingsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            hLabel:SetPoint("TOPLEFT", 10, -160)
            hLabel:SetText("Panel Height")
            local hSlider = CreateFrame("Slider", "ROTHeightSlider", settingsFrame, "OptionsSliderTemplate")
            hSlider:SetPoint("TOPLEFT", 10, -180)
            hSlider:SetMinMaxValues(100, 600)
            hSlider:SetValue(self.settings.panelHeight)
            hSlider:SetValueStep(10)
            hSlider:SetWidth(250)
            hSlider:SetScript("OnValueChanged", function(_, val)
                RaidOfflineTimerDB.panelHeight = val
                panel:SetHeight(val)
            end)
        end
        settingsFrame:Show()
    end

    ----------------------------------------------------------------
    -- SLASH COMMAND -----------------------------------------------
    ----------------------------------------------------------------
    SLASH_RAIDOFFLINETIMER1 = "/rot"
    SlashCmdList["RAIDOFFLINETIMER"] = function() openSettings() end

    ----------------------------------------------------------------
    -- Initial sync after /reload ----------------------------------
    ----------------------------------------------------------------
    C_Timer.After(2, function()
        -- Decide which channel to use
        local channel
        if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then        -- dungeon / raid finder
            channel = "INSTANCE_CHAT"
        elseif IsInRaid() then
            channel = "RAID"
        elseif IsInGroup() then
            channel = "PARTY"
        end

        -- Ask the group for their current timers
        if channel then
            C_ChatInfo.SendAddonMessage("RaidOfflineTimer", "REQUEST", channel)
        end

        -- Run a local scan right away so you pick up anyone already offline
        RaidOfflineTimer:GROUP_ROSTER_UPDATE()

        RaidOfflineTimer:GROUP_JOINED()
    end)
end

---------------------------------------------------------------------
-- GROUP_ROSTER_UPDATE / UNIT_CONNECTION ----------------------------
---------------------------------------------------------------------
function RaidOfflineTimer:GROUP_ROSTER_UPDATE()
    local current, sawOffline = {}, false

    for i=1, GetNumGroupMembers() do
        local unit = "raid"..i
        local name = GetUnitName(unit, true)
        if name then
            current[name] = true
            local online = UnitIsConnected(unit)

            if not online then
                if offlineTimers[name]==nil then
                    offlineTimers[name] = 0 -- pending
                    C_ChatInfo.SendAddonMessage("RaidOfflineTimer", "REQUEST:"..name, "RAID")
                    C_Timer.After(3, function()
                        if offlineTimers[name]==0 then
                            offlineTimers[name] = now()
                            if self.settings.enablePrint then print("[ROT]", name, "offline (fallback)") end
                        end
                    end)
                end
            else
                if offlineTimers[name] then
                    offlineTimers[name] = nil
                    C_ChatInfo.SendAddonMessage("RaidOfflineTimer", "ONLINE:"..name..":0", "RAID")
                    if self.settings.enablePrint then print("[ROT]", name, "online") end
                end
            end
        end
    end

    for _, ts in pairs(offlineTimers) do if ts>0 then sawOffline=true break end end
    C_Timer.After(2, function()
        if sawOffline then self:BroadcastOfflineTimers() else C_ChatInfo.SendAddonMessage("RaidOfflineTimer", "REQUEST", "RAID") end
    end)

    for name in pairs(offlineTimers) do if not current[name] then offlineTimers[name]=nil end end
end
function RaidOfflineTimer:UNIT_CONNECTION() self:GROUP_ROSTER_UPDATE() end

function RaidOfflineTimer:GROUP_JOINED()
    RaidOfflineTimer:UpdatePlayerLocations()
end

function RaidOfflineTimer:UpdatePlayerLocations()
    for i=1, GetNumGroupMembers() do
        local unit = "raid"..i
        local name = GetUnitName(unit, true)
        if name then
            local online = UnitIsConnected(unit)
            if online then
                local _, _, _, _, _, _, zone = GetRaidRosterInfo(i)
                local mapID = C_Map.GetBestMapForUnit(unit)
                local mapInfo = C_Map.GetMapInfo(mapID)
                local mapName = mapInfo.name
                playerLocation[name] = zone .. " (" .. mapName .. ")"
            end
        end
    end

    C_Timer.After(5, function() RaidOfflineTimer:UpdatePlayerLocations() end)
end

---------------------------------------------------------------------
-- SYNC -------------------------------------------------------------
---------------------------------------------------------------------
function RaidOfflineTimer:BroadcastOfflineTimers()
    local ch = raidOrParty()
    for name, ts in pairs(offlineTimers) do
        if ts>0 then
            C_ChatInfo.SendAddonMessage("RaidOfflineTimer", "OFFLINE:"..name..":"..ts, ch)
        end
    end
end

function RaidOfflineTimer:CHAT_MSG_ADDON(prefix, msg, _, sender)
    if prefix~="RaidOfflineTimer" or sender==UnitName("player") then return end

    if msg=="REQUEST" then self:BroadcastOfflineTimers(); return end

    local cmd, player, tsStr = strsplit(":", msg)
    local ts = tonumber(tsStr)

    if cmd=="REQUEST" and player then
        if offlineTimers[player] and offlineTimers[player]>0 then
            C_ChatInfo.SendAddonMessage("RaidOfflineTimer", "OFFLINE:"..player..":"..offlineTimers[player], raidOrParty())
        end
        return
    end

    if not cmd or not player or not ts then return end
    if ts>0 and math.abs(now()-ts) > 604800 then return end -- >1 week old

    if cmd=="OFFLINE" then
        if not offlineTimers[player] or offlineTimers[player]==0 or ts<offlineTimers[player] then
            offlineTimers[player] = ts
            if self.settings.enablePrint then print("[ROT] synced", player, "offline →", fmtClock(now()-ts)) end
        end
    elseif cmd=="ONLINE" then
        offlineTimers[player] = nil
    end
end

---------------------------------------------------------------------
-- SavedVars / Tooltip ---------------------------------------------
---------------------------------------------------------------------
function RaidOfflineTimer:VARIABLES_LOADED() print("RaidOfflineTimer vars loaded") end

GameTooltip:HookScript("OnTooltipSetUnit", function(tip)
    local name = select(1, tip:GetUnit())
    if name and offlineTimers[name] and offlineTimers[name]>0 then
        local lastKnownLocation = playerLocation[name]
        if not lastKnownLocation then
            lastKnownLocation = "Unknown"
        end

        tip:AddLine("Offline for: "..fmtClock(now()-offlineTimers[name]), 1,0,0)
        tip:AddLine("Last known location: "..lastKnownLocation, 1,0,0)
        tip:Show()
    end
end)