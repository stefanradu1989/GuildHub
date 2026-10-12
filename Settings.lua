local _, GH = ...

-- Settings window (/gh settings, the minimap button's right click, or the Settings button in the main window)
-- and the minimap button.

local settingsFrame

local CHECKS = {
    { key = "notify_events",    label = "Notify me about new events, and when my event is full" },
    { key = "notify_requests",  label = "Notify me when my requests are taken or finished" },
    { key = "notify_craftable", label = "Notify me when someone requests something I can craft" },
    { key = "notify_board",     label = "Notify me about new guild announcements" },
    { key = "sound",            label = "Play a sound with notifications and reminders" },
}

local LEAD_OPTIONS = {
    { label = "Off", value = 0 }, { label = "5 minutes", value = 5 }, { label = "10 minutes", value = 10 },
    { label = "15 minutes", value = 15 }, { label = "30 minutes", value = 30 }, { label = "60 minutes", value = 60 },
}

local CLEANUP_OPTIONS = {
    { label = "3 days", value = 3 }, { label = "7 days", value = 7 },
    { label = "14 days", value = 14 }, { label = "30 days", value = 30 },
}

local function labelFor(options, value)
    for _, o in ipairs(options) do
        if o.value == value then return o.label end
    end
    return tostring(value)
end

local function refreshSettings()
    if not settingsFrame then return end
    local s = GH.db.settings
    for _, c in ipairs(settingsFrame.checks) do c:SetChecked(s[c.key] and true or false) end
    settingsFrame.minimapCheck:SetChecked(not s.minimap.hide)
    settingsFrame.leadButton:SetText("Event reminder: " .. labelFor(LEAD_OPTIONS, s.reminderLead))
    settingsFrame.cleanupButton:SetText("Keep finished items: " .. labelFor(CLEANUP_OPTIONS, s.cleanupDays))
end

function GH:InitSettings()
    local f = CreateFrame("Frame", "GuildHubSettings", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(440, 340)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetScript("OnShow", refreshSettings)
    f:Hide()
    tinsert(UISpecialFrames, "GuildHubSettings")
    settingsFrame = f

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title:SetPoint("TOP", 0, -5)
    f.title:SetText("Guild Hub Settings")

    local function newCheck(y, label, onClick)
        local c = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
        c:SetPoint("TOPLEFT", 20, y)
        c:SetSize(26, 26)
        c:SetScript("OnClick", onClick)
        local text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        text:SetPoint("LEFT", c, "RIGHT", 4, 0)
        text:SetText(label)
        return c
    end

    f.checks = {}
    local y = -36
    for _, spec in ipairs(CHECKS) do
        local c = newCheck(y, spec.label, function(self) GH.db.settings[spec.key] = self:GetChecked() and true or false end)
        c.key = spec.key
        f.checks[#f.checks + 1] = c
        y = y - 28
    end
    f.minimapCheck = newCheck(y, "Show the minimap button", function(self)
        GH.db.settings.minimap.hide = not self:GetChecked()
        GH:UpdateMinimapButton()
    end)
    y = y - 40

    f.leadButton = GH.NewButton(f, "", 260, nil, function(self)
        GH.ShowChoice(LEAD_OPTIONS, function(v)
            GH.db.settings.reminderLead = v
            refreshSettings()
        end, self, GH.db.settings.reminderLead)
    end)
    f.leadButton:SetPoint("TOPLEFT", 24, y)
    y = y - 32

    f.cleanupButton = GH.NewButton(f, "", 260, nil, function(self)
        GH.ShowChoice(CLEANUP_OPTIONS, function(v)
            GH.db.settings.cleanupDays = v
            GH:Cleanup()
            GH:RefreshUI()
            refreshSettings()
        end, self, GH.db.settings.cleanupDays)
    end)
    f.cleanupButton:SetPoint("TOPLEFT", 24, y)
end

function GH:ToggleSettings()
    if not settingsFrame then return end
    if settingsFrame:IsShown() then settingsFrame:Hide() else settingsFrame:Show() end
end

-- Minimap button -----------------------------------------------------------------------------------------

local button

local function placeButton()
    local angle = math.rad(GH.db.settings.minimap.angle or 215)
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * 80, math.sin(angle) * 80)
end

function GH:UpdateMinimapButton()
    if not button then return end
    button:SetShown(not self.db.settings.minimap.hide)
end

function GH:InitMinimapButton()
    button = CreateFrame("Button", "GuildHubMinimapButton", Minimap)
    button:SetSize(31, 31)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")

    local icon = button:CreateTexture(nil, "BACKGROUND")
    icon:SetTexture("Interface\\Icons\\INV_Misc_Book_09")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER", 0, 1)
    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    button:SetScript("OnClick", function(_, mouseButton)
        if mouseButton == "RightButton" then GH:ToggleSettings() else GH:ToggleUI() end
    end)
    button:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            GH.db.settings.minimap.angle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
            placeButton()
        end)
    end)
    button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("Guild Hub")
        GameTooltip:AddLine("Left-click: open", 1, 1, 1)
        GameTooltip:AddLine("Right-click: settings", 1, 1, 1)
        GameTooltip:AddLine("Drag: move this button", 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", GameTooltip_Hide)

    placeButton()
    self:UpdateMinimapButton()
end
