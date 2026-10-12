local _, GH = ...

local BANNER = 36 -- height of the guild-name banner under the window title; everything below is shifted down by it
local FRAME_W, FRAME_H = 1120, 720 + BANNER
local ROW_H = 22
local ROWS_TOP = 146 + BANNER -- distance from the top of the window to the first row
local MAX_ROWS = math.floor((FRAME_H - ROWS_TOP - 44) / ROW_H) -- room below the page header, above the hint and version lines
local ACTIONS_PER_ROW = 4
local frame, rows = nil, {}

local PARCHMENT_ATLAS = "QuestBG-Parchment"
local PARCHMENT = "Interface\\QuestFrame\\QuestBG" -- fallback if the atlas is missing
local PARCHMENT_COORDS = { 0, 1, 0, 1 }
local TEXT = { 0.2, 0.1, 0.0 } -- dark brown, readable on parchment
local TINT = { 0.30, 0.62, 0.70 } -- teal gradient over the bottom of the parchment
local TINT_ALPHA = 0.65           -- strength at the very bottom (0 = invisible, 1 = solid)
local TINT_HEIGHT = 0.55          -- how far up the page it reaches (fraction of the page height)

-- Spellbook-style layout: tabs along the top pick a page, the page has a title, and a page can have sections.
local PAGES = {
    { key = "events", label = "Events", title = "Guild Events" },
    { key = "crafting", label = "Crafting", title = "Crafting Orders",
      sections = {
          { key = "requests", label = "Requests" },
          { key = "fulfill", label = "Fulfill Requests" },
          { key = "crafters", label = "Crafters" },
      } },
    { key = "board", label = "Board", title = "Guild Board" },
    { key = "guild", label = "Guild", title = "Guild",
      sections = {
          { key = "bank", label = "Bank Requests" },
          { key = "attendance", label = "Attendance" },
          { key = "leaderboard", label = "Leaderboard" },
      } },
}
local page = "events"
local sections = { crafting = "requests", guild = "bank" } -- the section open on each page
local crafterPlayer, crafterProf -- drill-down position in the Crafters section
local offset, lastKey = 0, nil   -- list scroll position, reset whenever the list changes
local actionsFor                 -- defined below; RefreshUI needs it first

-- Filters on the Events page (kept for the session). The name filter is the search box.
local filters = { kind = "any", date = "upcoming", role = "any" }
local reqFilter = { prof = "any" } -- Requests / Fulfill filter; the item-name filter is the search box
local KIND_LIST = { "any", "raid", "dungeon", "battleground" }
local DATE_LIST = { "upcoming", "today", "week", "past", "all" }
local ROLE_LIST = { "any", "tank", "healer", "dps" }
local DATE_LABEL = { upcoming = "Upcoming", today = "Today", week = "Next 7 days", past = "Past", all = "All" }
local ROLE_LABEL = { any = "Any", tank = "Tank", healer = "Healer", dps = "DPS" }

-- The list currently shown: events, requests, fulfill, crafters, board, bank, attendance or leaderboard.
local function currentView()
    if page == "events" or page == "board" then return page end
    return sections[page]
end

local function sorted(list)
    table.sort(list, function(a, b) return (a.ts or 0) > (b.ts or 0) end)
    return list
end

-- Event rows ------------------------------------------------------------------------------------------------

local function colorOf(list, key)
    for _, e in ipairs(list) do
        if e.key == key then return e end
    end
end

-- Your sign-up as a colored tag, e.g. [Tank], [Waitlist: Healer] or [Tentative].
local function eventMark(ev)
    local kind, val = GH:StateOf(ev, GH.me)
    if kind == "role" then
        local r = colorOf(GH.ROLES, val)
        return string.format("|c%s[%s]|r ", r.color, r.label)
    elseif kind == "wait" then
        local r = colorOf(GH.ROLES, val)
        return string.format("|cff8a6d00[Waitlist: %s]|r ", r.label)
    elseif kind == "status" then
        local s = colorOf(GH.STATUSES, val)
        return string.format("|c%s[%s]|r ", s.color, s.label)
    end
    return ""
end

local function eventText(ev)
    local roster = GH:Roster(ev)
    local parts, waiting = {}, 0
    for _, r in ipairs(GH.ROLES) do
        local cap = GH:CapOf(ev, r.key)
        parts[#parts + 1] = string.format("|c%s%d%s|r", r.color, #roster[r.key], cap > 0 and ("/" .. cap) or "")
        waiting = waiting + #roster.wait[r.key]
    end
    local kindTag = ""
    local k = colorOf(GH.KINDS, ev.kind)
    if k then kindTag = string.format("|c%s[%s]|r ", k.color, k.label) end
    local extra = ""
    if waiting > 0 then extra = extra .. "  |cff555555+" .. waiting .. " waiting|r" end
    if ev.repeatDays then extra = extra .. "  |cff555555(weekly)|r" end
    return string.format("%s%s%s - %s (host %s)  T/H/D %s%s", eventMark(ev), kindTag, ev.title, GH:WhenText(ev),
        ev.host, table.concat(parts, " "), extra)
end

local function eventTooltip(owner, ev)
    local roster = GH:Roster(ev)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:AddLine(ev.title)
    GameTooltip:AddLine(GH:WhenText(ev) .. (ev.start and (" " .. date("%Z", ev.start)) or ""), 1, 1, 1)
    if ev.start then GameTooltip:AddLine("Shown in your local time", 0.6, 0.6, 0.6) end
    if ev.desc then GameTooltip:AddLine(ev.desc, 1, 0.82, 0, true) end
    for _, r in ipairs(GH.ROLES) do
        local names = roster[r.key]
        local cap = GH:CapOf(ev, r.key)
        GameTooltip:AddLine(string.format("|c%s%s (%d%s)|r: %s", r.color, r.label, #names,
            cap > 0 and ("/" .. cap) or "", #names > 0 and table.concat(names, ", ") or "-"), 1, 1, 1, true)
    end
    for _, r in ipairs(GH.ROLES) do
        local names = roster.wait[r.key]
        if #names > 0 then
            GameTooltip:AddLine(string.format("Waitlist, %s: %s", r.label, table.concat(names, ", ")), 0.9, 0.7, 0.2, true)
        end
    end
    for _, s in ipairs(GH.STATUSES) do
        local names = roster[s.key]
        if #names > 0 then
            GameTooltip:AddLine(string.format("%s (%d): %s", s.label, #names, table.concat(names, ", ")), 0.7, 0.7, 0.7, true)
        end
    end
    if ev.attended then
        local n = 0
        for _ in pairs(ev.attended) do n = n + 1 end
        GameTooltip:AddLine("Attendance recorded: " .. n .. " players", 0.6, 0.9, 0.6)
    end
    GameTooltip:AddLine("Share code: #" .. GH:ShortId(ev.id), 0.6, 0.6, 0.6)
    GameTooltip:Show()
end

-- Request rows ----------------------------------------------------------------------------------------------

-- A request's profession: stored when it was made, else looked up from the shared recipes (nil if unknown).
local function requestProf(rq)
    return rq.prof or GH:ProfessionOf(rq.item)
end

local function requestMatches(rq, useProfession)
    local query = frame.search:GetText():lower()
    if query ~= "" and not rq.item:lower():find(query, 1, true) then return false end
    return not useProfession or reqFilter.prof == "any" or (requestProf(rq) or "other") == reqFilter.prof
end

-- The item's colored name when the game knows the item, else the name that was typed.
local function itemName(rq)
    if rq.itemID then
        local getInfo = GetItemInfo or (C_Item and C_Item.GetItemInfo)
        if getInfo then
            local a, b = getInfo(rq.itemID)
            if type(a) == "table" then
                if a.hyperlink then return a.hyperlink end
            elseif b then
                return b
            end
        end
    end
    return rq.item
end

local function requestText(rq)
    local prof = (not rq.bank) and requestProf(rq)
    local tag = rq.bank and "|cff2a6a8a[Bank]|r " or (prof and ("|cff555555[" .. prof .. "]|r ") or "")
    local status
    if rq.done then status = "|cff555555done|r"
    elseif rq.claimedBy == GH.me then status = "|cff8a6d00claimed by you|r"
    elseif rq.claimedBy then status = "|cff8a6d00claimed by " .. rq.claimedBy .. "|r"
    else status = "|cff1a7a1aopen|r" end
    local extra = ""
    if rq.mats then extra = extra .. "  |cff555555- " .. rq.mats .. "|r" end
    if rq.due then
        local urgent = not rq.done and rq.due - time() < 86400
        extra = extra .. string.format("  |c%sneeded by %s|r", urgent and "ffc0301a" or "ff555555",
            date("%a %d %b %H:%M", rq.due))
    end
    return string.format("%s%s - for %s [%s]%s", tag, itemName(rq), rq.requester == GH.me and "you" or rq.requester,
        status, extra)
end

-- Other rows ------------------------------------------------------------------------------------------------

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

local function boardText(a)
    return string.format("|cff8a6d00%s|r  %s  |cff555555(%s)|r", a.author, a.text, date("%d %b", a.ts))
end

local function attendanceText(s)
    return string.format("%s - attended %d, signed up for %d%s", s.name, s.attended, s.signed,
        s.rate and string.format(" (%d%%)", s.rate) or "")
end

local function leaderboardText(s)
    return string.format("%d. %s - fulfilled %d, requested %d", s.rank, s.name, s.fulfilled, s.requested)
end

local function rowText(view, item)
    if view == "events" then return eventText(item)
    elseif view == "crafters" then return crafterText(item)
    elseif view == "board" then return boardText(item)
    elseif view == "attendance" then return attendanceText(item)
    elseif view == "leaderboard" then return leaderboardText(item)
    end
    return requestText(item)
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
            if #names > 0 and GH:IsMember(name) then list[#list + 1] = { kind = "player", name = name, profs = names } end
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
                list[#list + 1] = { kind = "recipe", recipe = name, prof = crafterProf,
                                    itemID = entry.items and entry.items[name] }
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
    elseif view == "requests" then -- craft requests I posted
        for _, rq in pairs(GH.db.requests) do
            if not rq.bank and rq.requester == GH.me and requestMatches(rq, true) then list[#list + 1] = rq end
        end
        return sorted(list)
    elseif view == "fulfill" then -- other people's craft requests I could take, plus the ones I already took
        for _, rq in pairs(GH.db.requests) do
            if not rq.bank and rq.requester ~= GH.me and not rq.done and (not rq.claimedBy or rq.claimedBy == GH.me)
                and requestMatches(rq, true) then
                list[#list + 1] = rq
            end
        end
        return sorted(list)
    elseif view == "bank" then -- guild bank requests: everyone's open ones, plus my own
        for _, rq in pairs(GH.db.requests) do
            if rq.bank and (not rq.done or rq.requester == GH.me) and requestMatches(rq, false) then
                list[#list + 1] = rq
            end
        end
        return sorted(list)
    elseif view == "board" then
        for _, a in pairs(GH.db.board) do list[#list + 1] = a end
        return sorted(list)
    elseif view == "attendance" then
        return GH:AttendanceStats()
    elseif view == "leaderboard" then
        list = GH:Leaderboard()
        for i, s in ipairs(list) do s.rank = i end
        return list
    end
    return crafterItems(crafterLevel())
end

local EMPTY = {
    events = "No events yet. Click New Event to create one.",
    events_filtered = "No events match your filters.",
    requests_filtered = "No requests match your filters.",
    requests = "You haven't posted any requests. Click New Request, or pick a recipe under Crafters.",
    fulfill = "No open requests from your guildmates right now.",
    crafters_players = "Nobody has shared their professions yet. Open your profession windows to share yours.",
    crafters_professions = "No professions shared by this player.",
    crafters_recipes = "No matching recipes.",
    crafters_search = "No matching recipes.",
    board = "No announcements yet.",
    bank = "No guild bank requests.",
    attendance = "No attendance recorded yet. Event hosts can record it with the crown button on an event.",
    leaderboard = "Nothing here yet. Finished requests show up here.",
}

local HINTS = {
    events = "Click an event to sign up. Row buttons: share in guild chat (hosts also edit, record attendance, delete).",
    requests = "Row buttons: mark as received, delete, or whisper whoever took it. Filter by profession or item name above.",
    fulfill = "+ takes a request; once it's yours, mark it crafted or give it back. The speech bubble whispers the requester.",
    crafters_players = "Click a player to see their professions, or type to search for a recipe. The speech bubble whispers them.",
    crafters_professions = "Click a profession to see its recipes.",
    crafters_recipes = "Click a recipe to request it; hover for the item. The speech bubble whispers this player.",
    crafters_search = "Click a recipe to request it. Clear the search to browse by player.",
    board = "Announcements from your officers. Officers can post them with New Announcement.",
    bank = "Ask the guild bank for an item. Whoever can help takes it with the + button.",
    attendance = "Counts events where the host recorded who was in the group.",
    leaderboard = "Counts the requests this client has seen being finished.",
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
        b:SetShown(b.page == page)
        b:SetEnabled(sections[b.page] ~= b.key)
    end
    local level = view == "crafters" and crafterLevel() or nil
    local key = level and ("crafters_" .. level) or view
    local isRequests = view == "requests" or view == "fulfill" or view == "bank"
    local showNew = view == "events" or view == "requests" or view == "bank" or (view == "board" and GH:IsOfficer())

    frame.newBtn:SetShown(showNew)
    frame.newBtn:SetText(view == "events" and "New Event" or view == "board" and "New Announcement"
        or view == "bank" and "New Bank Request" or "New Request")
    frame.search:SetShown(view == "events" or isRequests or (view == "crafters" and level ~= "professions"))
    frame.search:ClearAllPoints()
    -- the New ... button sits at the right edge, so the search box moves left of it
    frame.search:SetPoint("TOPRIGHT", showNew and -190 or -30, -111 - BANNER)
    frame.searchLabel:SetShown(view == "events" or isRequests)
    frame.searchLabel:SetText(view == "events" and "Name:" or "Item:")
    frame.profButton:SetShown(view == "requests" or view == "fulfill")
    frame.profButton:SetText("Profession: " .. (reqFilter.prof == "any" and "All"
        or reqFilter.prof == "other" and "Unknown" or reqFilter.prof))
    for _, b in pairs(frame.filterButtons) do b:SetShown(view == "events") end
    frame.filterButtons.kind:SetText("Type: " .. (filters.kind == "any" and "All" or filters.kind:gsub("^%l", string.upper)))
    frame.filterButtons.date:SetText("Date: " .. DATE_LABEL[filters.date])
    frame.filterButtons.role:SetText("Free slot: " .. ROLE_LABEL[filters.role])
    frame.backBtn:SetShown(view == "crafters" and crafterPlayer ~= nil)
    frame.crumb:SetShown(view == "crafters" and crafterPlayer ~= nil)
    frame.crumb:SetText(crafterPlayer and (crafterPlayer .. (crafterProf and (" > " .. crafterProf) or "")) or "")

    local list = viewItems(view)
    local pos = table.concat({ key, tostring(crafterPlayer), tostring(crafterProf), page,
        filters.kind, filters.date, filters.role, reqFilter.prof, frame.search:GetText() }, "|")
    if pos ~= lastKey then offset, lastKey = 0, pos end -- new list: scroll back to the top
    offset = math.max(0, math.min(offset, #list - MAX_ROWS))
    frame.count = #list

    for i = 1, MAX_ROWS do
        local row, item = rows[i], list[offset + i]
        if item then
            row.id, row.item = item.id, item
            row.text:SetText(rowText(view, item))
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
    local emptyKey = key
    if view == "events" and next(GH.db.events) then
        emptyKey = "events_filtered"
    elseif (view == "requests" or view == "fulfill") and (reqFilter.prof ~= "any" or frame.search:GetText() ~= "") then
        emptyKey = "requests_filtered"
    end
    frame.empty:SetText(EMPTY[emptyKey])
    frame.empty:SetShown(#list == 0)
    frame.hint:SetText(HINTS[key] .. (#list > MAX_ROWS and "   (scroll for more)" or ""))
end

-- Menus and forms ---------------------------------------------------------------------------------------------

-- Sign up: pick a role (a full one puts you on its waitlist), tentative, declined, or withdraw.
local function showRoleMenu(id)
    local ev = GH.db.events[id]
    if not ev then return end
    local choices = {}
    for _, r in ipairs(GH.ROLES) do
        local full = GH:IsFull(ev, r.key)
        choices[#choices + 1] = { label = "|c" .. r.color .. r.label .. "|r" .. (full and " |cff888888(full - join waitlist)|r" or ""),
                                  value = r.key }
    end
    for _, s in ipairs(GH.STATUSES) do
        choices[#choices + 1] = { label = "|c" .. s.color .. s.label .. "|r", value = s.key }
    end
    choices[#choices + 1] = { label = "Withdraw", value = "none" }
    local kind, val = GH:StateOf(ev, GH.me)
    local current = (kind == "role" or kind == "status") and val or "none"
    GH.ShowChoice(choices, function(v) GH:SetRole(id, v ~= "none" and v or nil) end, nil, current)
end

local function editEventMenu(ev)
    local id = ev.id
    GH.ShowChoice({
        { label = "Edit slots", value = "slots" },
        { label = "Edit time", value = "when" },
        { label = "Edit description", value = "desc" },
        { label = ev.repeatDays and "Stop repeating weekly" or "Repeat weekly", value = "repeat" },
    }, function(v)
        if v == "slots" then
            GH.Ask("New slots tank/healer/dps, e.g. 2/4/14 (blank = no limits):", function(t) GH:EditCaps(id, GH:ParseCaps(t)) end)
        elseif v == "when" then
            GH.Ask("New time (your local time), e.g. sat 20:00 or 2026-11-04 20:00:", function(t) GH:EditWhen(id, t) end)
        elseif v == "desc" then
            GH.Ask("New description (blank = none):", function(t) GH:EditDesc(id, t) end, true)
        else
            GH:SetRepeat(id, ev.repeatDays and 0 or 7)
        end
    end)
end

local function newEventForm()
    local kinds = {}
    for _, k in ipairs(GH.KINDS) do kinds[#kinds + 1] = { label = k.label, value = k.key } end
    GH:ShowForm({
        title = "New Event",
        fields = {
            { key = "title", label = "Title", max = 60, required = true },
            { key = "when", label = "When (your local time): sat 20:00, tomorrow 20:00, 2026-11-04 20:00", max = 40 },
            { key = "slots", label = "Slots tank/healer/dps, e.g. 2/4/14 (0 = no limit; blank = default)", max = 20 },
            { key = "desc", label = "Description (optional)", max = 150 },
        },
        choices = {
            { key = "kind", label = "Type", options = kinds, default = "raid" },
            { key = "repeatDays", label = "Repeat", options = { { label = "Never", value = 0 }, { label = "Every week", value = 7 } },
              default = 0 },
        },
        submitText = "Create",
        onSubmit = function(v)
            local caps = GH:ParseCaps(v.slots)
            if not caps then
                local k = colorOf(GH.KINDS, v.kind)
                caps = k and k.defaultCaps
            end
            GH:CreateEvent({ title = v.title, when = v.when, caps = caps, kind = v.kind, desc = v.desc,
                             repeatDays = v.repeatDays })
        end,
    })
end

-- opts: item (prefilled text), prof, itemID (from the Crafters list), bank
local function requestForm(opts)
    opts = opts or {}
    GH:ShowForm({
        title = opts.bank and "New Guild Bank Request" or "New Craft Request",
        fields = {
            { key = "item", label = opts.bank and "Item you need from the guild bank" or "Item you need crafted",
              max = 60, required = true, default = opts.item },
            { key = "mats", label = opts.bank and "Quantity or notes (optional)" or "Materials you'll provide, or notes (optional)", max = 60 },
            { key = "due", label = "Needed by (optional) - e.g. sat, tomorrow 20:00, 2026-11-04", max = 40 },
        },
        submitText = "Post request",
        onSubmit = function(v)
            local same = opts.item and v.item:lower() == opts.item:lower()
            GH:CreateRequest({ item = v.item, mats = v.mats, due = v.due, bank = opts.bank,
                               prof = same and opts.prof or nil, itemID = same and opts.itemID or nil })
        end,
    })
end

local function newAnnouncementForm()
    GH:ShowForm({
        title = "New Announcement",
        fields = { { key = "text", label = "Message (shown to the whole guild)", max = 150, required = true } },
        submitText = "Post",
        onSubmit = function(v) GH:PostAnnouncement(v.text) end,
    })
end

local function newClicked()
    local view = currentView()
    if view == "events" then newEventForm()
    elseif view == "board" then newAnnouncementForm()
    elseif view == "bank" then requestForm({ bank = true })
    else requestForm() end
end

local function onRowClick(self, button)
    if button ~= "LeftButton" then return end
    local view = currentView()
    local item = self.item
    if view == "crafters" then
        if item.kind == "player" then
            crafterPlayer = item.name
            frame.search:SetText("")
        elseif item.kind == "prof" then
            crafterProf = item.prof
            frame.search:SetText("")
        else -- a recipe, from the profession list or from search results
            requestForm({ item = item.recipe, prof = item.prof or crafterProf, itemID = item.itemID })
        end
        GH:RefreshUI()
    elseif view == "events" then
        showRoleMenu(self.id)
    end
    -- everything else is handled by the buttons at the end of each row
end

-- Row buttons -----------------------------------------------------------------------------------------------

local ICON = {
    delete = "Interface\\RaidFrame\\ReadyCheck-NotReady", -- red X (the game has no bin icon to borrow)
    done = "Interface\\RaidFrame\\ReadyCheck-Ready",      -- green check
    edit = "Interface\\Buttons\\UI-OptionsButton",        -- gear
    take = "Interface\\Buttons\\UI-PlusButton-Up",        -- plus
    giveBack = "Interface\\Buttons\\UI-RefreshButton",    -- circular arrow
    whisper = "Interface\\ChatFrame\\UI-ChatIcon-Chat-Up", -- speech bubble
    share = "Interface\\Buttons\\UI-GuildButton-MOTD-Up", -- megaphone
    attend = "Interface\\GroupFrame\\UI-Group-LeaderIcon", -- crown
}

-- Icon buttons for a row, rightmost first. Each is { icon, tip, fn }.
function actionsFor(view, item)
    local acts = {}
    local id = item.id
    local function add(icon, tip, fn) acts[#acts + 1] = { icon = icon, tip = tip, fn = fn } end

    if view == "events" then
        if item.host == GH.me then
            add(ICON.delete, "Delete event", function()
                GH.Confirm("Delete the event '" .. item.title .. "' for everyone?", function() GH:DeleteEvent(id) end)
            end)
            add(ICON.edit, "Edit slots, time, description or repeat", function() editEventMenu(item) end)
            add(ICON.attend, "Record attendance (everyone in your group)", function() GH:RecordAttendance(id) end)
        end
        add(ICON.share, "Share in guild chat", function() GH:ShareEvent(id) end)
    elseif view == "requests" or view == "bank" then
        if item.requester == GH.me then
            add(ICON.delete, "Delete request", function()
                GH.Confirm("Delete your request for '" .. item.item .. "'?", function() GH:DeleteRequest(id) end)
            end)
            if not item.done then
                add(ICON.done, "Mark as received", function() GH:CompleteRequest(id) end)
            end
            if item.claimedBy then
                add(ICON.whisper, "Whisper " .. item.claimedBy, function()
                    GH:Whisper(item.claimedBy, "Hi! About my request for " .. item.item .. " - ")
                end)
            end
        else -- a bank request from someone else
            if item.claimedBy == GH.me then
                add(ICON.done, "Mark as fulfilled", function() GH:CompleteRequest(id) end)
                add(ICON.giveBack, "Give back (let someone else take it)", function() GH:UnclaimRequest(id) end)
            elseif not item.claimedBy then
                add(ICON.take, "Take this request", function() GH:ClaimRequest(id) end)
            end
            add(ICON.whisper, "Whisper " .. item.requester, function()
                GH:Whisper(item.requester, "Hi! About your request for " .. item.item .. " - ")
            end)
        end
    elseif view == "fulfill" then
        if item.claimedBy == GH.me then
            add(ICON.done, "Mark as crafted", function() GH:CompleteRequest(id) end)
            add(ICON.giveBack, "Give back (let someone else take it)", function() GH:UnclaimRequest(id) end)
        elseif not item.claimedBy then
            add(ICON.take, "Take this request", function() GH:ClaimRequest(id) end)
        end
        add(ICON.whisper, "Whisper " .. item.requester, function()
            GH:Whisper(item.requester, "Hi! I can craft " .. item.item .. " for you. ")
        end)
    elseif view == "board" then
        if item.author == GH.me then
            add(ICON.delete, "Delete announcement", function()
                GH.Confirm("Delete this announcement for everyone?", function() GH:DeleteAnnouncement(id) end)
            end)
        end
    elseif view == "crafters" then
        if item.kind == "player" then
            add(ICON.whisper, "Whisper " .. item.name, function() GH:Whisper(item.name, "Hi! ") end)
        elseif item.kind == "recipe" and crafterPlayer then
            add(ICON.whisper, "Whisper " .. crafterPlayer, function()
                GH:Whisper(crafterPlayer, "Hi! Could you craft " .. item.recipe .. " for me? ")
            end)
        end
    end
    return acts
end

-- Opening an event from a shared chat message (/gh #CODE)
function GH:OpenEvent(id)
    if not self.db.events[id] then return end
    page = "events"
    filters.kind, filters.date, filters.role = "any", "all", "any"
    frame:Show()
    frame.search:SetText(self.db.events[id].title)
    GH:RefreshUI()
end

function GH:OpenEventByCode(code)
    local ev = self:EventByCode(code)
    if ev then
        self:OpenEvent(ev.id)
    else
        self:Print("No event with the code #" .. code .. " yet - the host may be offline. Try again after the sync.")
    end
end

-- The window ------------------------------------------------------------------------------------------------

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

    -- Teal gradient rising from the bottom of the parchment, like the Forever quest windows.
    local tint = frame:CreateTexture(nil, "BACKGROUND", nil, 3)
    tint:SetColorTexture(1, 1, 1, 1)
    tint:SetPoint("BOTTOMLEFT", 6, 6)
    tint:SetPoint("BOTTOMRIGHT", -6, 6)
    tint:SetHeight((FRAME_H - 64 - BANNER) * TINT_HEIGHT)
    if tint.SetGradient and CreateColor then
        tint:SetGradient("VERTICAL", CreateColor(TINT[1], TINT[2], TINT[3], TINT_ALPHA),
            CreateColor(TINT[1], TINT[2], TINT[3], 0))
    else
        tint:SetGradientAlpha("VERTICAL", TINT[1], TINT[2], TINT[3], TINT_ALPHA, TINT[1], TINT[2], TINT[3], 0)
    end

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
        local b = GH.NewButton(frame, p.label, 110, p.key, function()
            page = p.key
            frame.search:SetText("") -- the search box is shared by several pages
            GH:RefreshUI()
        end)
        if i == 1 then b:SetPoint("TOPLEFT", 12, -32 - BANNER) else b:SetPoint("LEFT", frame.pageButtons[i - 1], "RIGHT", 4, 0) end
        frame.pageButtons[i] = b
    end

    local settingsBtn = GH.NewButton(frame, "Settings", 90, nil, function() GH:ToggleSettings() end)
    settingsBtn:SetPoint("TOPRIGHT", -12, -32 - BANNER)

    -- Page title with a divider underneath, like the heading on a spellbook page.
    frame.pageTitle = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    frame.pageTitle:SetPoint("TOP", 0, -72 - BANNER)
    frame.pageTitle:SetTextColor(unpack(TEXT))
    local divider = frame:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(0.35, 0.2, 0.05, 0.6)
    divider:SetHeight(2)
    divider:SetPoint("TOPLEFT", 24, -102 - BANNER)
    divider:SetPoint("TOPRIGHT", -24, -102 - BANNER)

    -- Sections inside a page (Crafting and Guild have them); only the current page's buttons are shown.
    frame.sectionButtons = {}
    for _, p in ipairs(PAGES) do
        local prev
        for _, s in ipairs(p.sections or {}) do
            local b = GH.NewButton(frame, s.label, 130, s.key, function()
                sections[p.key] = s.key
                frame.search:SetText("") -- each section starts with an empty search
                if s.key == "crafters" then crafterPlayer, crafterProf = nil, nil end
                GH:RefreshUI()
            end)
            b.page = p.key
            if prev then b:SetPoint("LEFT", prev, "RIGHT", 4, 0) else b:SetPoint("TOPLEFT", 24, -110 - BANNER) end
            prev = b
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

    frame.searchLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    frame.searchLabel:SetPoint("RIGHT", frame.search, "LEFT", -8, 0)
    frame.searchLabel:SetTextColor(unpack(TEXT))
    frame.searchLabel:SetText("Name:")

    -- Events filters: each button opens a dropdown with its options; the search box filters by name.
    local function kindLabel(v)
        local k = colorOf(GH.KINDS, v)
        return k and k.label or "All"
    end
    frame.filterButtons = {}
    local specs = {
        { key = "kind", width = 150, list = KIND_LIST, label = kindLabel },
        { key = "date", width = 170, list = DATE_LIST, label = function(v) return DATE_LABEL[v] end },
        { key = "role", width = 190, list = ROLE_LIST, label = function(v) return ROLE_LABEL[v] end },
    }
    for i, spec in ipairs(specs) do
        local b = GH.NewButton(frame, spec.key, spec.width, spec.key, function(self)
            local choices = {}
            for _, v in ipairs(spec.list) do choices[#choices + 1] = { label = spec.label(v), value = v } end
            GH.ShowChoice(choices, function(v)
                filters[spec.key] = v
                GH:RefreshUI()
            end, self, filters[spec.key])
        end)
        local prev = specs[i - 1] and frame.filterButtons[specs[i - 1].key]
        if prev then b:SetPoint("LEFT", prev, "RIGHT", 4, 0) else b:SetPoint("TOPLEFT", 24, -110 - BANNER) end
        b:Hide()
        frame.filterButtons[spec.key] = b
    end

    -- Requests / Fulfill: a dropdown of the professions that appear in requests.
    frame.profButton = GH.NewButton(frame, "Profession", 200, nil, function(self)
        local seen, profs, hasOther = {}, {}, false
        for _, rq in pairs(GH.db.requests) do
            if not rq.bank then
                local p = requestProf(rq)
                if not p then hasOther = true
                elseif not seen[p] then seen[p] = true; profs[#profs + 1] = p end
            end
        end
        table.sort(profs)
        local choices = { { label = "All", value = "any" } }
        for _, p in ipairs(profs) do choices[#choices + 1] = { label = p, value = p } end
        if hasOther then choices[#choices + 1] = { label = "Unknown", value = "other" } end
        GH.ShowChoice(choices, function(v)
            reqFilter.prof = v
            GH:RefreshUI()
        end, self, reqFilter.prof)
    end)
    frame.profButton:SetPoint("TOPLEFT", 432, -110 - BANNER)
    frame.profButton:Hide()

    -- Crafters drill-down: a Back button and a "Player > Profession" trail.
    frame.backBtn = GH.NewButton(frame, "< Back", 80, nil, function()
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

    frame.newBtn = GH.NewButton(frame, "New", 150, nil, newClicked)
    frame.newBtn:SetPoint("TOPRIGHT", -24, -110 - BANNER)

    for i = 1, MAX_ROWS do
        local row = CreateFrame("Button", nil, frame)
        row:SetSize(FRAME_W - 60, ROW_H)
        row:SetPoint("TOPLEFT", 24, -ROWS_TOP - (i - 1) * ROW_H)
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.text:SetPoint("LEFT", 4, 0)
        row.text:SetPoint("RIGHT", row, "RIGHT", -(ACTIONS_PER_ROW * 22 + 8), 0) -- leave room for the action buttons
        row.text:SetJustifyH("LEFT")
        row.text:SetWordWrap(false)
        row.text:SetTextColor(unpack(TEXT))
        row.actions = {}
        for j = 1, ACTIONS_PER_ROW do
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
        row:SetScript("OnClick", onRowClick)
        row:SetScript("OnEnter", function(self)
            local view, item = currentView(), self.item
            if not item then return end
            if view == "events" then
                eventTooltip(self, item)
            elseif item.itemID and (view == "requests" or view == "fulfill" or view == "bank" or view == "crafters") then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetHyperlink("item:" .. item.itemID)
                GameTooltip:Show()
            end
        end)
        row:SetScript("OnLeave", GameTooltip_Hide)
        rows[i] = row
    end

    frame.empty = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    frame.empty:SetPoint("TOP", 0, -ROWS_TOP - 40)
    frame.empty:SetTextColor(0.4, 0.3, 0.2)

    frame.hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.hint:SetPoint("BOTTOM", 0, 26)
    frame.hint:SetWidth(FRAME_W - 80)
    frame.hint:SetTextColor(unpack(TEXT))

    -- Version, read from the "## Version" line of GuildHub.toc, below the hint text.
    local getMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    frame.version = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.version:SetPoint("BOTTOM", 0, 10)
    frame.version:SetTextColor(unpack(TEXT))
    frame.version:SetText("Version " .. ((getMeta and getMeta("GuildHub", "Version")) or "?"))
end

function GH:ToggleUI()
    if frame:IsShown() then frame:Hide() else frame:Show() end
end
