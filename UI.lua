local _, GH = ...

local FRAME_W, FRAME_H = 1120, 720
local ROW_H = 22
local ROWS_TOP = 146 -- distance from the top of the window to the first row
local MAX_ROWS = math.floor((FRAME_H - ROWS_TOP - 30) / ROW_H) -- room below the page header, above the hint line
local frame, rows = nil, {}

local PARCHMENT_ATLAS = "QuestBG-Parchment"
local PARCHMENT = "Interface\\QuestFrame\\QuestBG" -- fallback if the atlas is missing
local PARCHMENT_COORDS = { 0, 1, 0, 1 }
local TEXT = { 0.2, 0.1, 0.0 } -- dark brown, readable on parchment

-- Spellbook-style layout: tabs along the top pick a page, the page has a title, and a page can have sections.
local PAGES = {
    { key = "events", label = "Events", title = "Guild Events" },
    { key = "crafting", label = "Crafting", title = "Crafting Orders",
      sections = {
          { key = "requests", label = "Requests" },
          { key = "fulfill", label = "Fulfill Requests" },
          { key = "crafters", label = "Crafters" },
      } },
}
local page, section = "events", "requests"

-- The list currently shown: "events", "requests", "fulfill" or "crafters".
local function currentView()
    return page == "events" and "events" or section
end

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

local function sorted(list)
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
    local status
    if rq.done then status = "|cff555555done|r"
    elseif rq.claimedBy == GH.me then status = "|cff8a6d00claimed by you|r"
    elseif rq.claimedBy then status = "|cff8a6d00claimed by " .. rq.claimedBy .. "|r"
    else status = "|cff1a7a1aopen|r" end
    return string.format("%s - for %s [%s]", rq.item, rq.requester == GH.me and "you" or rq.requester, status)
end

local function crafterText(r)
    return string.format("%s |cff555555(%s)|r - %s", r.recipe, r.prof, table.concat(r.crafters, ", "))
end

-- Items for the list currently shown.
local function viewItems(view)
    local list = {}
    if view == "events" then
        for _, ev in pairs(GH.db.events) do list[#list + 1] = ev end
        return sorted(list)
    elseif view == "requests" then -- requests I posted
        for _, rq in pairs(GH.db.requests) do
            if rq.requester == GH.me then list[#list + 1] = rq end
        end
        return sorted(list)
    elseif view == "fulfill" then -- other people's requests I could take, plus the ones I already took
        for _, rq in pairs(GH.db.requests) do
            if rq.requester ~= GH.me and not rq.done and (not rq.claimedBy or rq.claimedBy == GH.me) then
                list[#list + 1] = rq
            end
        end
        return sorted(list)
    end
    return GH:FindCrafters(frame.search:GetText())
end

local EMPTY = {
    events = "No events yet. Click New Event to create one.",
    requests = "You haven't posted any requests. Click New Request, or pick a recipe under Crafters.",
    fulfill = "No open requests from your guildmates right now.",
    crafters = "No matching recipes. Open your profession windows to share yours.",
}

local HINTS = {
    events = "Click: sign up   Right-click: edit slots   Shift-click: delete (host only)",
    requests = "Right-click: mark as received   Shift-click: delete",
    fulfill = "Click: take a request   Right-click: mark as crafted   Shift-click: give back a request you took",
    crafters = "Type to search recipes. Click a recipe to post a craft request for it.",
}

function GH:RefreshUI()
    if not frame or not frame:IsShown() then return end
    local view = currentView()
    local def
    for _, p in ipairs(PAGES) do if p.key == page then def = p end end

    frame.pageTitle:SetText(def.title)
    for _, b in ipairs(frame.pageButtons) do b:SetEnabled(b.key ~= page) end
    for _, b in ipairs(frame.sectionButtons) do
        b:SetShown(def.sections ~= nil)
        b:SetEnabled(b.key ~= section)
    end
    frame.search:SetShown(view == "crafters")
    frame.newBtn:SetShown(view == "events" or view == "requests")
    frame.newBtn:SetText(view == "events" and "New Event" or "New Request")

    local list = viewItems(view)
    for i = 1, MAX_ROWS do
        local row, item = rows[i], list[i]
        if item then
            row.id, row.recipe = item.id, item.recipe
            row.text:SetText(view == "events" and eventText(item)
                or view == "crafters" and crafterText(item) or requestText(item))
            row:Show()
        else
            row:Hide()
        end
    end
    frame.empty:SetText(EMPTY[view])
    frame.empty:SetShown(#list == 0)
    frame.hint:SetText(HINTS[view])
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
    local view = currentView()
    if view == "crafters" then
        GH:CreateRequest(self.recipe)
        GH:Print("Posted a request for " .. self.recipe)
    elseif view == "events" then
        if IsShiftKeyDown() then GH:DeleteEvent(self.id)
        elseif button == "RightButton" then
            local id = self.id
            ask("New slots tank/healer/dps, e.g. 2/4/14 (blank = no limits):", function(caps)
                GH:EditCaps(id, GH:ParseCaps(caps))
            end)
        else showRoleMenu(self.id) end
    elseif view == "requests" then
        if IsShiftKeyDown() then GH:DeleteRequest(self.id)
        elseif button == "RightButton" then GH:CompleteRequest(self.id) end
    else -- fulfill
        if IsShiftKeyDown() then GH:UnclaimRequest(self.id)
        elseif button == "RightButton" then GH:CompleteRequest(self.id)
        else GH:ClaimRequest(self.id) end
    end
end

local function newClicked()
    if currentView() == "events" then
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

local function newButton(parent, label, width, key, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 22)
    b:SetText(label)
    b.key = key
    b:SetScript("OnClick", onClick)
    return b
end

function GH:InitUI()
    frame = CreateFrame("Frame", "GuildHubFrame", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(FRAME_W, FRAME_H)
    frame:SetClampedToScreen(true)
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetScript("OnShow", function() GH:RefreshUI() end)
    frame:Hide()
    tinsert(UISpecialFrames, "GuildHubFrame")

    -- Quest-log parchment for the "page". Adjust PARCHMENT / PARCHMENT_COORDS if it looks off on your client.
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

    -- Page tabs along the top, like the spellbook's.
    frame.pageButtons = {}
    for i, p in ipairs(PAGES) do
        local b = newButton(frame, p.label, 110, p.key, function()
            page = p.key
            GH:RefreshUI()
        end)
        if i == 1 then b:SetPoint("TOPLEFT", 12, -32) else b:SetPoint("LEFT", frame.pageButtons[i - 1], "RIGHT", 4, 0) end
        frame.pageButtons[i] = b
    end

    -- Page title with a divider underneath, like the heading on a spellbook page.
    frame.pageTitle = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    frame.pageTitle:SetPoint("TOP", 0, -72)
    frame.pageTitle:SetTextColor(unpack(TEXT))
    local divider = frame:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(0.35, 0.2, 0.05, 0.6)
    divider:SetHeight(2)
    divider:SetPoint("TOPLEFT", 24, -102)
    divider:SetPoint("TOPRIGHT", -24, -102)

    -- Sections inside a page (only the Crafting page has them).
    frame.sectionButtons = {}
    for _, p in ipairs(PAGES) do
        for _, s in ipairs(p.sections or {}) do
            local b = newButton(frame, s.label, 130, s.key, function()
                section = s.key
                GH:RefreshUI()
            end)
            local prev = frame.sectionButtons[#frame.sectionButtons]
            if prev then b:SetPoint("LEFT", prev, "RIGHT", 4, 0) else b:SetPoint("TOPLEFT", 24, -110) end
            frame.sectionButtons[#frame.sectionButtons + 1] = b
        end
    end

    frame.search = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
    frame.search:SetSize(180, 20)
    frame.search:SetPoint("TOPRIGHT", -30, -111)
    frame.search:SetAutoFocus(false)
    frame.search:SetScript("OnTextChanged", function() GH:RefreshUI() end)
    frame.search:SetScript("OnEscapePressed", frame.search.ClearFocus)
    frame.search:Hide()

    frame.newBtn = newButton(frame, "New", 120, nil, newClicked)
    frame.newBtn:SetPoint("TOPRIGHT", -24, -110)

    for i = 1, MAX_ROWS do
        local row = CreateFrame("Button", nil, frame)
        row:SetSize(FRAME_W - 60, ROW_H)
        row:SetPoint("TOPLEFT", 24, -ROWS_TOP - (i - 1) * ROW_H)
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.text:SetPoint("LEFT", 4, 0)
        row.text:SetJustifyH("LEFT")
        row.text:SetTextColor(unpack(TEXT))
        row:SetScript("OnClick", onRowClick)
        row:SetScript("OnEnter", function(self)
            local ev = currentView() == "events" and self.id and GH.db.events[self.id]
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

    frame.empty = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    frame.empty:SetPoint("TOP", 0, -ROWS_TOP - 40)
    frame.empty:SetTextColor(0.4, 0.3, 0.2)

    frame.hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.hint:SetPoint("BOTTOM", 0, 10)
    frame.hint:SetTextColor(unpack(TEXT))
end

function GH:ToggleUI()
    if frame:IsShown() then frame:Hide() else frame:Show() end
end
