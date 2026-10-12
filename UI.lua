local _, GH = ...

local ROW_H, MAX_ROWS = 22, 12
local frame, rows, tab = nil, {}, "events"

local PARCHMENT_ATLAS = "QuestBG-Parchment"
local PARCHMENT = "Interface\\QuestFrame\\QuestBG" -- fallback if the atlas is missing
local PARCHMENT_COORDS = { 0, 1, 0, 1 }
local TEXT = { 0.2, 0.1, 0.0 } -- dark brown, readable on parchment

StaticPopupDialogs["GUILDHUB_NEW"] = {
    text = "%s",
    button1 = ACCEPT,
    button2 = CANCEL,
    hasEditBox = true,
    maxLetters = 60,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    EditBoxOnEnterPressed = function(self)
        local p = self:GetParent()
        p.data(self:GetText())
        p:Hide()
    end,
    OnAccept = function(self, cb)
        local box = self.editBox or self.EditBox
        cb(box:GetText())
    end,
}

local function ask(prompt, cb)
    StaticPopup_Show("GUILDHUB_NEW", prompt, nil, cb)
end

local function sorted(tbl)
    local list = {}
    for _, v in pairs(tbl) do list[#list + 1] = v end
    table.sort(list, function(a, b) return (a.ts or 0) > (b.ts or 0) end)
    return list
end

local function eventText(ev)
    local roster = GH:RosterByRole(ev)
    local parts = {}
    for _, r in ipairs(GH.ROLES) do
        local cap = GH:CapOf(ev, r.key)
        parts[#parts + 1] = string.format("|c%s%d%s|r", r.color, #roster[r.key], cap > 0 and ("/" .. cap) or "")
    end
    local counts = table.concat(parts, " ")
    local mine = GH:RoleOf(ev, GH.me)
    local mark = mine and ("|cff1a7a1a[" .. mine .. "]|r ") or ""
    return string.format("%s%s - %s (host %s)  T/H/D %s", mark, ev.title, GH:WhenText(ev), ev.host, counts)
end

local function requestText(rq)
    local status = rq.done and "|cff555555done|r" or
        (rq.claimedBy and ("|cff8a6d00claimed by " .. rq.claimedBy .. "|r") or "|cff1a7a1aopen|r")
    return string.format("%s - for %s [%s]", rq.item, rq.requester, status)
end

local function crafterText(r)
    return string.format("%s |cff555555(%s)|r - %s", r.recipe, r.prof, table.concat(r.crafters, ", "))
end

function GH:RefreshUI()
    if not frame or not frame:IsShown() then return end
    local list
    if tab == "crafters" then
        list = GH:FindCrafters(frame.search:GetText())
    else
        list = sorted(tab == "events" and GH.db.events or GH.db.requests)
    end
    frame.search:SetShown(tab == "crafters")
    frame.newBtn:SetShown(tab ~= "crafters")
    for i = 1, MAX_ROWS do
        local row, item = rows[i], list[i]
        if item then
            row.id, row.recipe = item.id, item.recipe
            row.text:SetText(tab == "events" and eventText(item)
                or tab == "requests" and requestText(item) or crafterText(item))
            row:Show()
        else
            row:Hide()
        end
    end
    frame.hint:SetText(tab == "events" and "Click: sign up   Right-click: edit slots   Shift-click: delete (host only)"
        or tab == "requests" and "Click: claim   Right-click: mark done   Shift-click: delete (requester only)"
        or "Type to search recipes. Click a recipe to post a craft request for it. Open your profession windows to share yours.")
    frame.newBtn:SetText(tab == "events" and "New Event" or "New Request")
end

local menu

local function showRoleMenu(id)
    if not menu then
        local catcher = CreateFrame("Button", nil, UIParent)
        catcher:SetAllPoints(UIParent)
        catcher:SetFrameStrata("FULLSCREEN")
        catcher:Hide()
        catcher:SetScript("OnClick", function(self) self:Hide(); menu:Hide() end)

        menu = CreateFrame("Frame", nil, UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
        menu:SetFrameStrata("FULLSCREEN_DIALOG")
        menu:SetSize(120, 4 * 22 + 12)
        menu:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
                           edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                           edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
        menu:SetBackdropColor(0, 0, 0, 0.95)
        menu.catcher = catcher
        menu:SetScript("OnHide", function(self) self.catcher:Hide() end)

        local choices = {}
        for _, r in ipairs(GH.ROLES) do
            choices[#choices + 1] = { key = r.key, label = "|c" .. r.color .. r.label .. "|r" }
        end
        choices[#choices + 1] = { key = nil, label = "Withdraw" }
        for i, c in ipairs(choices) do
            local btn = CreateFrame("Button", nil, menu)
            btn:SetSize(108, 22)
            btn:SetPoint("TOPLEFT", 6, -6 - (i - 1) * 22)
            btn:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
            btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            btn.text:SetPoint("LEFT", 6, 0)
            btn.text:SetText(c.label)
            btn:SetScript("OnClick", function()
                GH:SetRole(menu.eventId, c.key)
                menu:Hide()
            end)
            btn.key, btn.baseLabel = c.key, c.label
            menu.buttons = menu.buttons or {}
            menu.buttons[i] = btn
        end
    end
    menu.eventId = id
    local ev = GH.db.events[id]
    for _, btn in ipairs(menu.buttons) do
        local full = ev and btn.key and GH:IsFull(ev, btn.key)
        btn.text:SetText(btn.baseLabel .. (full and " |cff555555(full)|r" or ""))
    end
    local x, y = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale()
    menu:ClearAllPoints()
    menu:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / scale, y / scale)
    menu.catcher:Show()
    menu:Show()
end

local function onRowClick(self, button)
    if tab == "crafters" then
        GH:CreateRequest(self.recipe)
        GH:Print("Posted a request for " .. self.recipe)
    elseif tab == "events" then
        if IsShiftKeyDown() then GH:DeleteEvent(self.id)
        elseif button == "RightButton" then
            local id = self.id
            ask("New slots tank/healer/dps, e.g. 2/4/14 (blank = no limits):", function(caps)
                GH:EditCaps(id, GH:ParseCaps(caps))
            end)
        else showRoleMenu(self.id) end
    else
        if IsShiftKeyDown() then GH:DeleteRequest(self.id)
        elseif button == "RightButton" then GH:CompleteRequest(self.id)
        else GH:ClaimRequest(self.id) end
    end
end

local function newClicked()
    if tab == "events" then
        ask("Event title:", function(title)
            if title == "" then return end
            ask("When (your local time)? e.g. sat 20:00, tomorrow 20:00 or 2026-11-04 20:00", function(when)
                ask("Slots tank/healer/dps, e.g. 2/4/14 (0 = no limit, blank = none):", function(caps)
                    GH:CreateEvent(title, when ~= "" and when or "TBD", GH:ParseCaps(caps))
                end)
            end)
        end)
    else
        ask("What do you need crafted?", function(item)
            if item ~= "" then GH:CreateRequest(item) end
        end)
    end
end

local function setTab(name)
    tab = name
    GH:RefreshUI()
end

function GH:InitUI()
    frame = CreateFrame("Frame", "GuildHubFrame", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(560, 360)
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetScript("OnShow", function() GH:RefreshUI() end)
    frame:Hide()
    tinsert(UISpecialFrames, "GuildHubFrame")

    -- Quest-log parchment behind the list. Adjust PARCHMENT / PARCHMENT_COORDS if it looks off on your client.
    local bg = frame:CreateTexture(nil, "BACKGROUND", nil, 2)
    if C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(PARCHMENT_ATLAS) then
        bg:SetAtlas(PARCHMENT_ATLAS) -- the same atlas the quest window uses
    else
        bg:SetTexture(PARCHMENT)
        bg:SetTexCoord(unpack(PARCHMENT_COORDS))
    end
    bg:SetPoint("TOPLEFT", 6, -58)
    bg:SetPoint("BOTTOMRIGHT", -6, 6)

    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    frame.title:SetPoint("TOP", 0, -5)
    frame.title:SetText("Guild Hub")

    local evBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    evBtn:SetSize(90, 22); evBtn:SetPoint("TOPLEFT", 12, -32); evBtn:SetText("Events")
    evBtn:SetScript("OnClick", function() setTab("events") end)

    local rqBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    rqBtn:SetSize(90, 22); rqBtn:SetPoint("LEFT", evBtn, "RIGHT", 4, 0); rqBtn:SetText("Requests")
    rqBtn:SetScript("OnClick", function() setTab("requests") end)

    local crBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    crBtn:SetSize(90, 22); crBtn:SetPoint("LEFT", rqBtn, "RIGHT", 4, 0); crBtn:SetText("Crafters")
    crBtn:SetScript("OnClick", function() setTab("crafters") end)

    frame.search = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
    frame.search:SetSize(150, 20)
    frame.search:SetPoint("TOPRIGHT", -20, -33)
    frame.search:SetAutoFocus(false)
    frame.search:SetScript("OnTextChanged", function() GH:RefreshUI() end)
    frame.search:SetScript("OnEscapePressed", frame.search.ClearFocus)
    frame.search:Hide()

    frame.newBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.newBtn:SetSize(110, 22); frame.newBtn:SetPoint("TOPRIGHT", -12, -32)
    frame.newBtn:SetScript("OnClick", newClicked)

    for i = 1, MAX_ROWS do
        local row = CreateFrame("Button", nil, frame)
        row:SetSize(530, ROW_H)
        row:SetPoint("TOPLEFT", 14, -62 - (i - 1) * ROW_H)
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.text:SetPoint("LEFT", 4, 0)
        row.text:SetJustifyH("LEFT")
        row.text:SetTextColor(unpack(TEXT))
        row:SetScript("OnClick", onRowClick)
        row:SetScript("OnEnter", function(self)
            local ev = tab == "events" and self.id and GH.db.events[self.id]
            if not ev then return end
            local roster = GH:RosterByRole(ev)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(ev.title)
            GameTooltip:AddLine(GH:WhenText(ev) .. (ev.start and (" " .. date("%Z", ev.start)) or ""), 1, 1, 1)
            if ev.start then GameTooltip:AddLine("Shown in your local time", 0.6, 0.6, 0.6) end
            for _, r in ipairs(GH.ROLES) do
                local names = roster[r.key]
                local cap = GH:CapOf(ev, r.key)
                GameTooltip:AddLine(string.format("|c%s%s (%d%s)|r: %s", r.color, r.label, #names,
                    cap > 0 and ("/" .. cap) or "",
                    #names > 0 and table.concat(names, ", ") or "-"), 1, 1, 1, true)
            end
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", GameTooltip_Hide)
        rows[i] = row
    end

    frame.hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.hint:SetPoint("BOTTOM", 0, 10)
    frame.hint:SetTextColor(unpack(TEXT))
end

function GH:ToggleUI()
    if frame:IsShown() then frame:Hide() else frame:Show() end
end
