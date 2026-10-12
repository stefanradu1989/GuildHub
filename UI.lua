local _, GH = ...

local BANNER = 36 -- height of the guild-name banner under the window title; everything below is shifted down by it
local FRAME_W, FRAME_H = 1120, 720 + BANNER
local ROW_H = 22
local ROWS_TOP = 146 + BANNER -- distance from the top of the window to the first row
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
local crafterPlayer, crafterProf -- drill-down position in the Crafters section
local offset, lastKey = 0, nil   -- list scroll position, reset whenever the list changes
local actionsFor                 -- defined below; RefreshUI needs it first

-- Filters on the Events page (kept for the session). The name filter is the search box.
local filters = { kind = "any", date = "upcoming", role = "any" }
local KIND_CYCLE = { "any", "raid", "dungeon", "battleground" }
local DATE_CYCLE = { "upcoming", "today", "week", "past", "all" }
local ROLE_CYCLE = { "any", "tank", "healer", "dps" }
local DATE_LABEL = { upcoming = "Upcoming", today = "Today", week = "Next 7 days", past = "Past", all = "All" }

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
    -- The callback runs on the next frame: if it opens another prompt (as creating an event does),
    -- that prompt would otherwise be closed right after this handler returns.
    EditBoxOnEnterPressed = function(self)
        local p = self:GetParent()
        local cb, text = p.data, self:GetText()
        p:Hide()
        C_Timer.After(0, function() cb(text) end)
    end,
    OnAccept = function(self, cb)
        local box = self.editBox or self.EditBox
        local text = box:GetText()
        C_Timer.After(0, function() cb(text) end)
    end,
}

StaticPopupDialogs["GUILDHUB_CONFIRM"] = {
    text = "%s",
    button1 = YES,
    button2 = NO,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    OnAccept = function(self, fn) fn() end,
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
    local kindTag = ""
    for _, k in ipairs(GH.KINDS) do
        if k.key == ev.kind then kindTag = string.format("|c%s[%s]|r ", k.color, k.label) end
    end
    local mark = ""
    if mine then
        for _, r in ipairs(GH.ROLES) do
            if r.key == mine then mark = string.format("|c%s[%s]|r ", r.color, r.label) end
        end
    end
    return string.format("%s%s%s - %s (host %s)  T/H/D %s", mark, kindTag, ev.title, GH:WhenText(ev), ev.host, counts)
end

local function requestText(rq)
    local status
    if rq.done then status = "|cff555555done|r"
    elseif rq.claimedBy == GH.me then status = "|cff8a6d00claimed by you|r"
    elseif rq.claimedBy then status = "|cff8a6d00claimed by " .. rq.claimedBy .. "|r"
    else status = "|cff1a7a1aopen|r" end
    return string.format("%s - for %s [%s]", rq.item, rq.requester == GH.me and "you" or rq.requester, status)
end

local function crafterText(item)
    if item.kind == "player" then
        return string.format("%s  |cff555555- %s|r", item.name, table.concat(item.profs, ", "))
    elseif item.kind == "prof" then
        return string.format("%s |cff555555(%d recipes)|r", item.prof, item.count)
    elseif item.kind == "recipe" then
        return item.recipe
    end
    -- "found": a recipe matched by the search box, with everyone who can craft it
    return string.format("%s |cff555555(%s)|r - %s", item.recipe, item.prof, table.concat(item.crafters, ", "))
end

-- Crafters drill-down: "players" -> "professions" (of one player) -> "recipes" (of one profession).
-- Typing in the search box at the top level switches to "search": recipes across everyone.
local function crafterLevel()
    if crafterProf then return "recipes"
    elseif crafterPlayer then return "professions"
    elseif frame.search:GetText() ~= "" then return "search" end
    return "players"
end

local function crafterItems(level)
    local query = frame.search:GetText():lower()
    local list = {}
    if level == "players" then
        for name, profs in pairs(GH.db.recipes) do
            local names = {}
            for prof in pairs(profs) do names[#names + 1] = prof end
            table.sort(names)
            if #names > 0 then list[#list + 1] = { kind = "player", name = name, profs = names } end
        end
        table.sort(list, function(a, b) return a.name < b.name end)
    elseif level == "professions" then
        for prof, entry in pairs(GH.db.recipes[crafterPlayer] or {}) do
            list[#list + 1] = { kind = "prof", prof = prof, count = #entry.list }
        end
        table.sort(list, function(a, b) return a.prof < b.prof end)
    elseif level == "recipes" then
        local entry = GH.db.recipes[crafterPlayer] and GH.db.recipes[crafterPlayer][crafterProf]
        for _, name in ipairs(entry and entry.list or {}) do
            if query == "" or name:lower():find(query, 1, true) then
                list[#list + 1] = { kind = "recipe", recipe = name }
            end
        end
    else
        list = GH:FindCrafters(query)
        for _, r in ipairs(list) do r.kind = "found" end
    end
    return list
end

-- Items for the list currently shown.
local function viewItems(view)
    local list = {}
    if view == "events" then
        local now = time()
        local query = frame.search:GetText():lower()
        for _, ev in pairs(GH.db.events) do
            local s, d = ev.start, filters.date
            local ok = (filters.kind == "any" or ev.kind == filters.kind)
                and (query == "" or ev.title:lower():find(query, 1, true) ~= nil)
                and (filters.role == "any" or not GH:IsFull(ev, filters.role)) -- "free tank spot" etc.
            if ok then
                -- events with no parsed time count as upcoming; they never match Today / Next 7 days / Past
                if d == "upcoming" then ok = s == nil or s >= now - 7200
                elseif d == "today" then ok = s ~= nil and date("%Y%m%d", s) == date("%Y%m%d", now)
                elseif d == "week" then ok = s ~= nil and s >= now - 7200 and s <= now + 7 * 86400
                elseif d == "past" then ok = s ~= nil and s < now - 7200 end
            end
            if ok then list[#list + 1] = ev end
        end
        -- soonest first (latest first for Past); events without a time go last
        table.sort(list, function(a, b)
            local as, bs = a.start, b.start
            if as and bs and as ~= bs then
                if filters.date == "past" then return as > bs end
                return as < bs
            end
            if (as ~= nil) ~= (bs ~= nil) then return as ~= nil end
            return (a.ts or 0) > (b.ts or 0)
        end)
        return list
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
    return crafterItems(crafterLevel())
end

local EMPTY = {
    events = "No events yet. Click New Event to create one.",
    events_filtered = "No events match your filters.",
    requests = "You haven't posted any requests. Click New Request, or pick a recipe under Crafters.",
    fulfill = "No open requests from your guildmates right now.",
    crafters_players = "Nobody has shared their professions yet. Open your profession windows to share yours.",
    crafters_professions = "No professions shared by this player.",
    crafters_recipes = "No matching recipes.",
    crafters_search = "No matching recipes.",
}

local HINTS = {
    events = "Click an event to sign up. Use the buttons above to filter by type, date or a free role slot; the host also gets edit and delete buttons.",
    requests = "Use the buttons on the right to mark a request as received or delete it.",
    fulfill = "Use the + button to take a request; once it's yours you can mark it crafted or give it back.",
    crafters_players = "Click a player to see their professions, or type to search for a recipe.",
    crafters_professions = "Click a profession to see its recipes.",
    crafters_recipes = "Click a recipe to post a craft request for it.",
    crafters_search = "Click a recipe to post a craft request for it. Clear the search to browse by player.",
}

function GH:RefreshUI()
    if not frame or not frame:IsShown() then return end
    local view = currentView()
    local def
    for _, p in ipairs(PAGES) do if p.key == page then def = p end end

    frame.banner:SetText((IsInGuild() and GetGuildInfo("player")) or "Guild Hub")
    frame.pageTitle:SetText(def.title)
    for _, b in ipairs(frame.pageButtons) do b:SetEnabled(b.key ~= page) end
    for _, b in ipairs(frame.sectionButtons) do
        b:SetShown(def.sections ~= nil)
        b:SetEnabled(b.key ~= section)
    end
    local level = view == "crafters" and crafterLevel() or nil
    local key = level and ("crafters_" .. level) or view
    frame.search:SetShown(view == "events" or (view == "crafters" and level ~= "professions"))
    frame.searchLabel:SetShown(view == "events")
    for _, b in pairs(frame.filterButtons) do b:SetShown(view == "events") end
    frame.filterButtons.kind:SetText("Type: " .. (filters.kind == "any" and "All" or filters.kind:gsub("^%l", string.upper)))
    frame.filterButtons.date:SetText("Date: " .. DATE_LABEL[filters.date])
    frame.filterButtons.role:SetText("Free slot: " .. (filters.role == "any" and "Any" or
        (filters.role == "dps" and "DPS" or filters.role:gsub("^%l", string.upper))))
    frame.backBtn:SetShown(view == "crafters" and crafterPlayer ~= nil)
    frame.crumb:SetShown(view == "crafters" and crafterPlayer ~= nil)
    frame.crumb:SetText(crafterPlayer and (crafterPlayer .. (crafterProf and (" > " .. crafterProf) or "")) or "")
    frame.newBtn:SetShown(view == "events" or view == "requests")
    frame.newBtn:SetText(view == "events" and "New Event" or "New Request")

    local list = viewItems(view)
    local pos = table.concat({ key, tostring(crafterPlayer), tostring(crafterProf), page,
        filters.kind, filters.date, filters.role, frame.search:GetText() }, "|")
    if pos ~= lastKey then offset, lastKey = 0, pos end -- new list: scroll back to the top
    offset = math.max(0, math.min(offset, #list - MAX_ROWS))
    frame.count = #list

    for i = 1, MAX_ROWS do
        local row, item = rows[i], list[offset + i]
        if item then
            row.id, row.item = item.id, item
            row.text:SetText(view == "events" and eventText(item)
                or view == "crafters" and crafterText(item) or requestText(item))
            local acts = actionsFor(view, item)
            for j, b in ipairs(row.actions) do
                local a = acts[j]
                if a then
                    b.icon:SetTexture(a.icon)
                    b.tip, b.fn = a.tip, a.fn
                    b:Show()
                else
                    b:Hide()
                end
            end
            row:Show()
        else
            row:Hide()
        end
    end
    frame.empty:SetText(EMPTY[(view == "events" and next(GH.db.events)) and "events_filtered" or key])
    frame.empty:SetShown(#list == 0)
    frame.hint:SetText(HINTS[key] .. (#list > MAX_ROWS and "   (scroll for more)" or ""))
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
    if button ~= "LeftButton" then return end
    local view = currentView()
    if view == "crafters" then
        local item = self.item
        if item.kind == "player" then
            crafterPlayer = item.name
            frame.search:SetText("")
        elseif item.kind == "prof" then
            crafterProf = item.prof
            frame.search:SetText("")
        else -- a recipe, from the profession list or from search results
            GH:CreateRequest(item.recipe)
            GH:Print("Posted a request for " .. item.recipe)
        end
        GH:RefreshUI()
    elseif view == "events" then
        showRoleMenu(self.id)
    end
    -- requests are handled by the buttons at the end of each row
end

local function confirm(prompt, fn)
    StaticPopup_Show("GUILDHUB_CONFIRM", prompt, nil, fn)
end

local ICON = {
    delete = "Interface\\RaidFrame\\ReadyCheck-NotReady", -- red X (the game has no bin icon to borrow)
    done = "Interface\\RaidFrame\\ReadyCheck-Ready",      -- green check
    edit = "Interface\\Buttons\\UI-OptionsButton",        -- gear
    take = "Interface\\Buttons\\UI-PlusButton-Up",        -- plus
    giveBack = "Interface\\Buttons\\UI-RefreshButton",    -- circular arrow
}

-- Icon buttons for a row, rightmost first. Each is { icon, tip, fn }.
function actionsFor(view, item)
    local acts = {}
    local id = item.id
    if view == "events" and item.host == GH.me then
        acts[#acts + 1] = { icon = ICON.delete, tip = "Delete event", fn = function()
            confirm("Delete the event '" .. item.title .. "' for everyone?", function() GH:DeleteEvent(id) end)
        end }
        acts[#acts + 1] = { icon = ICON.edit, tip = "Edit slots", fn = function()
            ask("New slots tank/healer/dps, e.g. 2/4/14 (blank = no limits):", function(caps)
                GH:EditCaps(id, GH:ParseCaps(caps))
            end)
        end }
    elseif view == "requests" then
        acts[#acts + 1] = { icon = ICON.delete, tip = "Delete request", fn = function()
            confirm("Delete your request for '" .. item.item .. "'?", function() GH:DeleteRequest(id) end)
        end }
        if not item.done then
            acts[#acts + 1] = { icon = ICON.done, tip = "Mark as received", fn = function() GH:CompleteRequest(id) end }
        end
    elseif view == "fulfill" then
        if item.claimedBy == GH.me then
            acts[#acts + 1] = { icon = ICON.done, tip = "Mark as crafted", fn = function() GH:CompleteRequest(id) end }
            acts[#acts + 1] = { icon = ICON.giveBack, tip = "Give back (let someone else take it)",
                                fn = function() GH:UnclaimRequest(id) end }
        elseif not item.claimedBy then
            acts[#acts + 1] = { icon = ICON.take, tip = "Take this request", fn = function() GH:ClaimRequest(id) end }
        end
    end
    return acts
end

-- A small pick-one menu at the cursor. choices = { { label = "Raid", value = "raid" }, ... }
local choiceMenu

local function showChoice(choices, onPick)
    if not choiceMenu then
        local catcher = CreateFrame("Button", nil, UIParent)
        catcher:SetAllPoints(UIParent)
        catcher:SetFrameStrata("FULLSCREEN")
        catcher:Hide()
        catcher:SetScript("OnClick", function(self) self:Hide(); choiceMenu:Hide() end)

        choiceMenu = CreateFrame("Frame", nil, UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
        choiceMenu:SetFrameStrata("FULLSCREEN_DIALOG")
        choiceMenu:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
                                 edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                                 edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
        choiceMenu:SetBackdropColor(0, 0, 0, 0.95)
        choiceMenu.catcher = catcher
        choiceMenu.buttons = {}
        choiceMenu:SetScript("OnHide", function(self) self.catcher:Hide() end)
    end
    choiceMenu:SetSize(120, #choices * 22 + 12)
    for i, c in ipairs(choices) do
        local btn = choiceMenu.buttons[i]
        if not btn then
            btn = CreateFrame("Button", nil, choiceMenu)
            btn:SetSize(108, 22)
            btn:SetPoint("TOPLEFT", 6, -6 - (i - 1) * 22)
            btn:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
            btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            btn.text:SetPoint("LEFT", 6, 0)
            choiceMenu.buttons[i] = btn
        end
        btn.text:SetText(c.label)
        btn:SetScript("OnClick", function()
            choiceMenu:Hide()
            C_Timer.After(0, function() onPick(c.value) end)
        end)
        btn:Show()
    end
    for i = #choices + 1, #choiceMenu.buttons do choiceMenu.buttons[i]:Hide() end
    local x, y = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale()
    choiceMenu:ClearAllPoints()
    choiceMenu:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / scale, y / scale)
    choiceMenu.catcher:Show()
    choiceMenu:Show()
end

local function newClicked()
    if currentView() == "events" then
        local choices = {}
        for _, k in ipairs(GH.KINDS) do choices[#choices + 1] = { label = k.label, value = k } end
        showChoice(choices, function(kind)
            ask("Event title:", function(title)
                if title == "" then return end
                ask("When (your local time)? e.g. sat 20:00, tomorrow 20:00 or 2026-11-04 20:00", function(when)
                    local hint = kind.defaultCaps and "blank = 1/1/3, the usual 5-man" or "blank = no limits"
                    ask("Slots tank/healer/dps, e.g. 2/4/14 (0 = no limit; " .. hint .. "):", function(caps)
                        GH:CreateEvent(title, when ~= "" and when or "TBD",
                            GH:ParseCaps(caps) or kind.defaultCaps, kind.key)
                    end)
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
    bg:SetPoint("TOPLEFT", 6, -58 - BANNER)
    bg:SetPoint("BOTTOMRIGHT", -6, 6)

    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    frame.title:SetPoint("TOP", 0, -5)
    frame.title:SetText("Guild Hub")

    -- Big banner under the window title: the guild's name (set in RefreshUI).
    local fontFile = GameFontNormalHuge:GetFont()
    frame.banner = frame:CreateFontString(nil, "OVERLAY")
    frame.banner:SetFont(fontFile, 30, "OUTLINE")
    frame.banner:SetPoint("TOP", 0, -28)
    frame.banner:SetTextColor(1, 0.82, 0)
    frame:RegisterEvent("PLAYER_GUILD_UPDATE") -- the guild name isn't available right at login
    frame:SetScript("OnEvent", function() GH:RefreshUI() end)

    -- Page tabs along the top, like the spellbook's.
    frame.pageButtons = {}
    for i, p in ipairs(PAGES) do
        local b = newButton(frame, p.label, 110, p.key, function()
            page = p.key
            frame.search:SetText("") -- the search box is shared by the Events and Crafters pages
            GH:RefreshUI()
        end)
        if i == 1 then b:SetPoint("TOPLEFT", 12, -32 - BANNER) else b:SetPoint("LEFT", frame.pageButtons[i - 1], "RIGHT", 4, 0) end
        frame.pageButtons[i] = b
    end

    -- Page title with a divider underneath, like the heading on a spellbook page.
    frame.pageTitle = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    frame.pageTitle:SetPoint("TOP", 0, -72 - BANNER)
    frame.pageTitle:SetTextColor(unpack(TEXT))
    local divider = frame:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(0.35, 0.2, 0.05, 0.6)
    divider:SetHeight(2)
    divider:SetPoint("TOPLEFT", 24, -102 - BANNER)
    divider:SetPoint("TOPRIGHT", -24, -102 - BANNER)

    -- Sections inside a page (only the Crafting page has them).
    frame.sectionButtons = {}
    for _, p in ipairs(PAGES) do
        for _, s in ipairs(p.sections or {}) do
            local b = newButton(frame, s.label, 130, s.key, function()
                section = s.key
                if s.key == "crafters" then crafterPlayer, crafterProf = nil, nil end
                GH:RefreshUI()
            end)
            local prev = frame.sectionButtons[#frame.sectionButtons]
            if prev then b:SetPoint("LEFT", prev, "RIGHT", 4, 0) else b:SetPoint("TOPLEFT", 24, -110 - BANNER) end
            frame.sectionButtons[#frame.sectionButtons + 1] = b
        end
    end

    frame.search = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
    frame.search:SetSize(180, 20)
    frame.search:SetPoint("TOPRIGHT", -30, -111 - BANNER)
    frame.search:SetAutoFocus(false)
    frame.search:SetScript("OnTextChanged", function() GH:RefreshUI() end)
    frame.search:SetScript("OnEscapePressed", frame.search.ClearFocus)
    frame.search:Hide()

    -- Events filters: each button cycles through its options; the search box filters by name.
    frame.searchLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    frame.searchLabel:SetPoint("RIGHT", frame.search, "LEFT", -8, 0)
    frame.searchLabel:SetTextColor(unpack(TEXT))
    frame.searchLabel:SetText("Name:")
    local function cycleOf(list, value)
        for i, v in ipairs(list) do
            if v == value then return list[i % #list + 1] end
        end
        return list[1]
    end
    frame.filterButtons = {}
    local specs = {
        { key = "kind", width = 130, list = KIND_CYCLE },
        { key = "date", width = 170, list = DATE_CYCLE },
        { key = "role", width = 170, list = ROLE_CYCLE },
    }
    for i, spec in ipairs(specs) do
        local b = newButton(frame, spec.key, spec.width, spec.key, function()
            filters[spec.key] = cycleOf(spec.list, filters[spec.key])
            GH:RefreshUI()
        end)
        local prev = specs[i - 1] and frame.filterButtons[specs[i - 1].key]
        if prev then b:SetPoint("LEFT", prev, "RIGHT", 4, 0) else b:SetPoint("TOPLEFT", 24, -110 - BANNER) end
        b:Hide()
        frame.filterButtons[spec.key] = b
    end

    -- Crafters drill-down: a Back button and a "Player > Profession" trail.
    frame.backBtn = newButton(frame, "< Back", 80, nil, function()
        if crafterProf then crafterProf = nil else crafterPlayer = nil end
        frame.search:SetText("")
        GH:RefreshUI()
    end)
    frame.backBtn:SetPoint("TOPRIGHT", -220, -110 - BANNER)
    frame.backBtn:Hide()
    frame.crumb = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    frame.crumb:SetPoint("TOPLEFT", 460, -114 - BANNER)
    frame.crumb:SetTextColor(unpack(TEXT))

    frame:EnableMouseWheel(true)
    frame:SetScript("OnMouseWheel", function(_, delta)
        offset = math.max(0, math.min(offset - delta * 3, (frame.count or 0) - MAX_ROWS))
        GH:RefreshUI()
    end)

    frame.newBtn = newButton(frame, "New", 120, nil, newClicked)
    frame.newBtn:SetPoint("TOPRIGHT", -24, -110 - BANNER)

    for i = 1, MAX_ROWS do
        local row = CreateFrame("Button", nil, frame)
        row:SetSize(FRAME_W - 60, ROW_H)
        row:SetPoint("TOPLEFT", 24, -ROWS_TOP - (i - 1) * ROW_H)
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.text:SetPoint("LEFT", 4, 0)
        row.text:SetPoint("RIGHT", row, "RIGHT", -52, 0) -- leave room for the action buttons
        row.text:SetJustifyH("LEFT")
        row.text:SetWordWrap(false)
        row.actions = {}
        for j = 1, 2 do
            local b = CreateFrame("Button", nil, row)
            b:SetSize(18, 18)
            b:SetPoint("RIGHT", -4 - (j - 1) * 22, 0)
            b.icon = b:CreateTexture(nil, "ARTWORK")
            b.icon:SetAllPoints()
            b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
            b:SetScript("OnClick", function(self) if self.fn then self.fn() end end)
            b:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:SetText(self.tip or "")
                GameTooltip:Show()
            end)
            b:SetScript("OnLeave", GameTooltip_Hide)
            b:Hide()
            row.actions[j] = b
        end
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
