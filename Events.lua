local _, GH = ...

GH.ROLES = {
    { key = "tank",   label = "Tank",   color = "ff1a5fbf" },
    { key = "healer", label = "Healer", color = "ff1a8a3a" },
    { key = "dps",    label = "DPS",    color = "ffc0301a" },
}

-- Sign-up answers that aren't a role.
GH.STATUSES = {
    { key = "tentative", label = "Tentative", color = "ff8a6d00" },
    { key = "declined",  label = "Declined",  color = "ff555555" },
}

-- Event types. Events made before types existed have no kind.
GH.KINDS = {
    { key = "raid", label = "Raid", color = "ff8a3b00", defaultCaps = nil },
    { key = "dungeon", label = "Dungeon", color = "ff2a6a8a", defaultCaps = { tank = 1, healer = 1, dps = 3 } },
    { key = "battleground", label = "Battleground", color = "ff8a1a3a", defaultCaps = nil },
}

local ROLE_SET = { tank = true, healer = true, dps = true }
local STATUS_SET = { tentative = true, declined = true }

local function validKind(key)
    for _, k in ipairs(GH.KINDS) do
        if k.key == key then return key end
    end
end

-- ev.rsvps[player] is one of:
--   "tank" | "healer" | "dps"       signed up with that role
--   "wait:tank" | "wait:healer" ... on the waitlist for a full role
--   "tentative" | "declined"
--   nil                             not signed up (data from v0.1 used `true`, meaning DPS)
-- ev.rsvpTs[player] is the server time of that answer, so older messages can't overwrite newer ones
-- and the waitlist has an order.
-- Returns kind ("role", "wait" or "status") and the role / status; nothing for an invalid value.
local function parse(v)
    if v == true then return "role", "dps" end
    if ROLE_SET[v] then return "role", v end
    if STATUS_SET[v] then return "status", v end
    if type(v) == "string" then
        local role = v:match("^wait:(%a+)$")
        if role and ROLE_SET[role] then return "wait", role end
    end
end

local function validAnswer(v) return parse(v) ~= nil end

local function rsvpTs(ev)
    ev.rsvpTs = ev.rsvpTs or {}
    return ev.rsvpTs
end

-- The confirmed role of `name`, if they have one.
function GH:RoleOf(ev, name)
    local kind, val = parse(ev.rsvps[name])
    if kind == "role" then return val end
end

-- What `name` answered: kind ("role", "wait", "status") and the role / status.
function GH:StateOf(ev, name)
    return parse(ev.rsvps[name])
end

-- Everyone's answers, grouped: tank / healer / dps / tentative / declined are sorted name lists,
-- wait.tank / wait.healer / wait.dps are in the order people joined the waitlist.
function GH:Roster(ev)
    local out = { tank = {}, healer = {}, dps = {}, tentative = {}, declined = {},
                  wait = { tank = {}, healer = {}, dps = {} } }
    for name, v in pairs(ev.rsvps) do
        local kind, val = parse(v)
        if kind == "role" or kind == "status" then
            out[val][#out[val] + 1] = name
        elseif kind == "wait" then
            out.wait[val][#out.wait[val] + 1] = name
        end
    end
    for _, key in ipairs({ "tank", "healer", "dps", "tentative", "declined" }) do table.sort(out[key]) end
    local ts = ev.rsvpTs or {}
    for _, list in pairs(out.wait) do
        table.sort(list, function(a, b)
            local ta, tb = ts[a] or 0, ts[b] or 0
            if ta ~= tb then return ta < tb end
            return a < b
        end)
    end
    return out
end

GH.RosterByRole = GH.Roster

-- Event times. ev.start is a Unix timestamp (so it means the same moment for everyone, whatever
-- their time zone); ev.when keeps the text the host typed for events whose time couldn't be parsed.
local DAYS = { sun = 1, mon = 2, tue = 3, wed = 4, thu = 5, fri = 6, sat = 7 } -- matches date("*t").wday

-- Accepts "2026-11-04 20:00", "20:00" / "today 20:00", "tomorrow 20:00" or "sat 20:00" (the next Saturday),
-- all in the player's local time. A date or day without a time ("2026-11-04", "sat") means the end of that day.
-- Returns a timestamp, or nil if it can't be read.
function GH:ParseWhen(str)
    str = ((str or ""):lower():gsub("^%s+", ""):gsub("%s+$", ""))
    local now = time()
    local t = date("*t", now)

    local y, mo, d, hh, mm = str:match("^(%d%d%d%d)%-(%d%d?)%-(%d%d?)%s+(%d%d?):(%d%d)$")
    if not y then
        y, mo, d = str:match("^(%d%d%d%d)%-(%d%d?)%-(%d%d?)$")
        hh, mm = 23, 59
    end
    if y then
        y, mo, d, hh, mm = tonumber(y), tonumber(mo), tonumber(d), tonumber(hh), tonumber(mm)
        if mo < 1 or mo > 12 or d < 1 or d > 31 or hh > 23 or mm > 59 then return nil end
        return time({ year = y, month = mo, day = d, hour = hh, min = mm, sec = 0 })
    end

    local word, h, m = str:match("^(%a*)%s*(%d%d?):(%d%d)$")
    if h then
        h, m = tonumber(h), tonumber(m)
    else
        word = str:match("^(%a+)$")
        if not word then return nil end
        h, m = 23, 59
    end
    if h > 23 or m > 59 then return nil end
    local base = { year = t.year, month = t.month, day = t.day, hour = h, min = m, sec = 0 }
    if word == "" or word == "today" then
        return time(base)
    elseif word == "tomorrow" then
        base.day = base.day + 1
        return time(base)
    end
    local wd = DAYS[word:sub(1, 3)]
    if not wd then return nil end
    base.day = base.day + (wd - t.wday) % 7
    local ts = time(base)
    if ts < now then -- that weekday is today but the time has passed: use next week
        base.day = base.day + 7
        ts = time(base)
    end
    return ts
end

-- What to show for an event's time, in the viewer's own time zone when we have a timestamp.
function GH:WhenText(ev)
    if ev.start then return date("%a %d %b %H:%M", ev.start) end
    return ev.when
end

-- ev.caps = { tank = n, healer = n, dps = n }, where 0 means no limit. nil means no limits at all.
function GH:CapOf(ev, role)
    return ev.caps and ev.caps[role] or 0
end

-- True if signing up as `role` would exceed its cap. Your own current role never counts as full.
function GH:IsFull(ev, role)
    local cap = self:CapOf(ev, role)
    if cap == 0 or self:RoleOf(ev, self.me) == role then return false end
    return #self:Roster(ev)[role] >= cap
end

-- Parses "2/4/14" (tank/healer/dps) into a caps table; returns nil for blank, invalid or all-zero input.
function GH:ParseCaps(str)
    local t, h, d = (str or ""):match("^%s*(%d+)%s*/%s*(%d+)%s*/%s*(%d+)%s*$")
    if not t then return nil end
    t, h, d = tonumber(t), tonumber(h), tonumber(d)
    if t == 0 and h == 0 and d == 0 then return nil end
    return { tank = t, healer = h, dps = d }
end

local function capsString(ev)
    local c = ev.caps
    return c and string.format("%d/%d/%d", c.tank, c.healer, c.dps) or ""
end

function GH:BroadcastEvent(ev)
    self:Send("EV", ev.id, ev.title, ev.when, ev.host, ev.ts, capsString(ev), ev.capsRev or 0, ev.start or "",
        ev.kind or "", ev.whenRev or 0)
    if ev.desc then self:SendRaw("DESC", ev.id, ev.descRev or 0, ev.desc) end
    for name, v in pairs(ev.rsvps) do
        if validAnswer(v) then self:Send("RSVP", ev.id, name, v, (ev.rsvpTs or {})[name] or 0) end
    end
    if ev.attended then self:BroadcastAttendance(ev) end
end

-- opts: title, when (text), start (timestamp; parsed from `when` if not given), caps, kind, desc, repeatDays, silent
function GH:CreateEvent(opts)
    local when = (opts.when and opts.when ~= "") and opts.when or "TBD"
    local start = opts.start or self:ParseWhen(when)
    if not start and not opts.silent then
        self:Print("Couldn't read that time, so there will be no reminder for this event. " ..
            "Use e.g. 2026-11-04 20:00, sat 20:00 or tomorrow 20:00.")
    end
    local desc = (opts.desc and opts.desc ~= "") and (opts.desc:gsub("~", "-")) or nil
    local days = opts.repeatDays or 0
    local ev = { id = self:NewId(), title = opts.title, when = when, host = self.me, ts = self:Now(),
                 rsvps = {}, rsvpTs = {}, caps = opts.caps, start = start, kind = validKind(opts.kind),
                 desc = desc, repeatDays = days > 0 and days or nil, capsRev = 0, whenRev = 0, descRev = 0 }
    self.db.events[ev.id] = ev
    self:BroadcastEvent(ev)
    self:RefreshUI()
    if not opts.silent then
        self:Print("Created event '" .. opts.title .. "'." ..
            (IsInGuild() and "" or " You're not in a guild, so it's only saved on this character's addon data."))
    end
    return ev
end

-- A waitlisted player takes a free slot once one opens up and they're first in line.
-- Each player only ever changes their own answer, so this runs on every client and acts for "me" only.
function GH:CheckWaitlist(ev)
    local kind, role = parse(ev.rsvps[self.me])
    if kind ~= "wait" then return end
    local cap = self:CapOf(ev, role)
    local roster = self:Roster(ev)
    if (cap == 0 or #roster[role] < cap) and roster.wait[role][1] == self.me then
        ev.rsvps[self.me] = role
        rsvpTs(ev)[self.me] = self:Now()
        self:Send("RSVP", ev.id, self.me, role, ev.rsvpTs[self.me])
        self:Print(string.format("A %s slot opened up in '%s' - you're in!", role, ev.title))
        self:Ping()
    end
end

-- Tells the host when every role has reached its cap.
function GH:CheckEventFull(ev)
    if ev.host ~= self.me or not ev.caps then return end
    local roster = self:Roster(ev)
    local full = true
    for _, r in ipairs(GH.ROLES) do
        local cap = self:CapOf(ev, r.key)
        if cap == 0 or #roster[r.key] < cap then full = false end
    end
    if full and not ev.notifiedFull then
        ev.notifiedFull = true
        self:Notify("events", "Your event '" .. ev.title .. "' is full.")
    elseif not full then
        ev.notifiedFull = nil
    end
end

-- answer = "tank" | "healer" | "dps" | "tentative" | "declined", or nil to withdraw.
-- Choosing a full role puts you on that role's waitlist.
function GH:SetRole(id, answer)
    local ev = self.db.events[id]
    if not ev then return end
    if answer ~= nil and not validAnswer(answer) then return end
    local kind, role = parse(answer)
    if kind == "role" and self:IsFull(ev, role) then
        answer = "wait:" .. role
        self:Print(string.format("The %s slots for '%s' are full - you're on the waitlist.", role, ev.title))
    end
    ev.rsvps[self.me] = answer
    rsvpTs(ev)[self.me] = self:Now()
    self:Send("RSVP", id, self.me, answer or "none", ev.rsvpTs[self.me])
    self:CheckWaitlist(ev)
    self:RefreshUI()
end

local function hostOnly(self, ev, what)
    if ev.host ~= self.me then
        self:Print("Only the host (" .. ev.host .. ") can change " .. what .. ".")
        return false
    end
    return true
end

-- Host only. Each edit bumps a revision number so stale copies of the event can't overwrite newer values.
function GH:EditCaps(id, caps)
    local ev = self.db.events[id]
    if not ev or not hostOnly(self, ev, "the slots") then return end
    ev.caps = caps
    ev.capsRev = (ev.capsRev or 0) + 1
    self:Send("CAPS", id, capsString(ev), ev.capsRev)
    self:CheckWaitlist(ev)
    self:RefreshUI()
end

function GH:EditWhen(id, text)
    local ev = self.db.events[id]
    if not ev or not hostOnly(self, ev, "the time") then return end
    local start = self:ParseWhen(text)
    if not start then
        self:Print("Couldn't read that time, so there will be no reminder for this event.")
    end
    ev.when = (text ~= "" and text) or "TBD"
    ev.start = start
    ev.whenRev = (ev.whenRev or 0) + 1
    if self.reminded then self.reminded[id] = nil end
    if self.remindedSoon then self.remindedSoon[id] = nil end
    self:Send("WHEN", id, ev.whenRev, ev.when, start or "")
    self:RefreshUI()
end

function GH:EditDesc(id, text)
    local ev = self.db.events[id]
    if not ev or not hostOnly(self, ev, "the description") then return end
    text = (text or ""):gsub("~", "-")
    ev.desc = text ~= "" and text or nil
    ev.descRev = (ev.descRev or 0) + 1
    self:SendRaw("DESC", id, ev.descRev, ev.desc or "")
    self:RefreshUI()
end

-- Host only; kept on the host's client, which creates the next event when this one has passed.
function GH:SetRepeat(id, days)
    local ev = self.db.events[id]
    if not ev or not hostOnly(self, ev, "repeating") then return end
    ev.repeatDays = (days or 0) > 0 and days or nil
    self:Print(ev.repeatDays and ("'" .. ev.title .. "' will repeat weekly.")
        or ("'" .. ev.title .. "' will no longer repeat."))
    self:RefreshUI()
end

function GH:DeleteEvent(id)
    local ev = self.db.events[id]
    if ev and ev.host == self.me then
        self.db.events[id] = nil
        self:Send("DELEV", id)
        self:RefreshUI()
    end
end

-- Sharing: a prefilled guild chat message, and /gh #CODE to open an event from it.
function GH:ShareText(ev)
    local roster = self:Roster(ev)
    local open = {}
    for _, r in ipairs(GH.ROLES) do
        local cap = self:CapOf(ev, r.key)
        if cap > 0 and #roster[r.key] < cap then
            open[#open + 1] = (cap - #roster[r.key]) .. " " .. r.label:lower()
        end
    end
    local slots = "signups open"
    if ev.caps then slots = #open > 0 and ("open: " .. table.concat(open, ", ")) or "full" end
    local kindLabel = ""
    for _, k in ipairs(GH.KINDS) do
        if k.key == ev.kind then kindLabel = k.label .. ": " end
    end
    return string.format("[GuildHub] %s%s - %s - %s - sign up: /gh #%s",
        kindLabel, ev.title, self:WhenText(ev), slots, self:ShortId(ev.id))
end

function GH:ShareEvent(id)
    local ev = self.db.events[id]
    if ev then self:SayGuild(self:ShareText(ev)) end
end

function GH:EventByCode(code)
    code = (code or ""):upper()
    for _, ev in pairs(self.db.events) do
        if self:ShortId(ev.id) == code then return ev end
    end
end

-- Attendance: the host records who is in the group; stats are built from events with a record.
function GH:GroupNames()
    local names = {}
    local count = GetNumGroupMembers and GetNumGroupMembers() or 0
    if IsInRaid and IsInRaid() then
        for i = 1, count do
            local name = GetRaidRosterInfo(i)
            if name then names[Ambiguate(name, "short")] = true end
        end
    else
        names[self.me] = true
        for i = 1, count - 1 do
            local name = UnitName("party" .. i)
            if name then names[name] = true end
        end
    end
    return names
end

function GH:RecordAttendance(id)
    local ev = self.db.events[id]
    if not ev or not hostOnly(self, ev, "attendance") then return end
    ev.attended = ev.attended or {}
    local n = 0
    for name in pairs(self:GroupNames()) do
        ev.attended[name] = true
    end
    for _ in pairs(ev.attended) do n = n + 1 end
    self:BroadcastAttendance(ev)
    self:Print(string.format("Recorded attendance for '%s': %d player%s.", ev.title, n, n == 1 and "" or "s"))
    self:RefreshUI()
end

function GH:BroadcastAttendance(ev)
    local cur = ""
    local function flush()
        if cur ~= "" then self:SendRaw("ATT", ev.id, cur) end
        cur = ""
    end
    for name in pairs(ev.attended or {}) do
        if cur ~= "" and #cur + #name + 1 > 170 then flush() end
        cur = (cur == "") and name or (cur .. ";" .. name)
    end
    flush()
end

-- Returns { { name =, attended =, signed =, rate = }, ... } over events with a record, best first.
-- `signed` counts the events the person had a confirmed role in.
function GH:AttendanceStats()
    local stats = {}
    local function entry(name)
        stats[name] = stats[name] or { name = name, attended = 0, signed = 0 }
        return stats[name]
    end
    for _, ev in pairs(self.db.events) do
        if ev.attended then
            for name, v in pairs(ev.rsvps) do
                if parse(v) == "role" then entry(name).signed = entry(name).signed + 1 end
            end
            for name in pairs(ev.attended) do entry(name).attended = entry(name).attended + 1 end
        end
    end
    local list = {}
    for _, s in pairs(stats) do
        s.rate = s.signed > 0 and math.min(100, math.floor(s.attended / s.signed * 100 + 0.5)) or nil
        list[#list + 1] = s
    end
    table.sort(list, function(a, b)
        if a.attended ~= b.attended then return a.attended > b.attended end
        return a.name < b.name
    end)
    return list
end

-- Reminders ----------------------------------------------------------------------------------------------

-- "tank" / "healer" / "dps" / "tentative" if you're attending, else nil.
local function attendingAs(ev)
    local kind, val = parse(ev.rsvps[GH.me])
    if kind == "role" then return val end
    if kind == "status" and val == "tentative" then return val end
end

-- Prints a login reminder for events that start today (or began within the last 2 hours).
-- Each event is announced at most once per session.
function GH:RemindToday()
    self.reminded = self.reminded or {}
    local now = time()
    local today = date("%Y%m%d", now)
    local due = {}
    for _, ev in pairs(self.db.events) do
        local kind, val = parse(ev.rsvps[self.me])
        local declined = kind == "status" and val == "declined"
        if ev.start and not self.reminded[ev.id] and not declined and date("%Y%m%d", ev.start) == today
            and ev.start > now - 2 * 3600 then
            due[#due + 1] = ev
        end
    end
    table.sort(due, function(a, b) return a.start < b.start end)
    for _, ev in ipairs(due) do
        self.reminded[ev.id] = true
        local as = attendingAs(ev)
        self:Print(string.format("Today: |cffffd100%s|r at %s %s", ev.title, date("%H:%M", ev.start),
            as and ("(you're signed up as " .. as .. ")") or "(you're not signed up - type /gh)"))
    end
end

-- Runs every 30 seconds: a reminder shortly before an event you're signed up for starts.
function GH:RemindSoon()
    local lead = self.db.settings.reminderLead or 0
    if lead <= 0 then return end
    self.remindedSoon = self.remindedSoon or {}
    local now = time()
    for _, ev in pairs(self.db.events) do
        if ev.start and not self.remindedSoon[ev.id] and attendingAs(ev)
            and ev.start - now <= lead * 60 and ev.start > now - 300 then
            self.remindedSoon[ev.id] = true
            local mins = math.max(0, math.floor((ev.start - now) / 60 + 0.5))
            self:Print(string.format("|cffffd100%s|r starts %s.", ev.title,
                mins <= 0 and "now" or ("in " .. mins .. " minute" .. (mins == 1 and "" or "s"))))
            self:Ping()
        end
    end
end

-- Checks once from saved data, then again after the login sync has had time to bring in new events.
function GH:ScheduleReminders()
    C_Timer.After(4, function() GH:RemindToday() end)
    C_Timer.After(20, function() GH:RemindToday() GH:ShowNewAnnouncements() end)
    C_Timer.After(6, function() GH:ShowNewAnnouncements() end)
end

-- Recurring events: when a weekly event you host has passed, create next week's.
function GH:ProcessRecurring()
    local now = time()
    local due = {}
    for _, ev in pairs(self.db.events) do
        if ev.host == self.me and (ev.repeatDays or 0) > 0 and ev.start and ev.start < now - 3600 then
            due[#due + 1] = ev
        end
    end
    for _, ev in ipairs(due) do
        local days = ev.repeatDays
        local nextStart = ev.start
        repeat
            local t = date("*t", nextStart)
            t.day = t.day + days
            t.isdst = nil -- let the system work out daylight saving, so the event stays at the same local time
            nextStart = time(t)
        until nextStart > now
        ev.repeatDays = nil
        local caps = ev.caps and { tank = ev.caps.tank, healer = ev.caps.healer, dps = ev.caps.dps } or nil
        local created = self:CreateEvent({ title = ev.title, when = date("%a %d %b %H:%M", nextStart),
            start = nextStart, caps = caps, kind = ev.kind, desc = ev.desc, repeatDays = days, silent = true })
        self:Print(string.format("Created next week's '%s' for %s.", created.title, self:WhenText(created)))
    end
end

-- Deletes finished events (and requests and announcements) from this client's saved data.
-- Events with an attendance record are kept for 90 days so the stats stay meaningful.
function GH:Cleanup()
    local now = self:Now()
    local days = self.db.settings.cleanupDays or 7
    for id, ev in pairs(self.db.events) do
        local keep = (ev.attended and 90 or days) * 86400
        if (ev.start or ev.ts or 0) < now - keep then self.db.events[id] = nil end
    end
    for id, rq in pairs(self.db.requests) do
        if (rq.done and (rq.doneAt or rq.ts or 0) < now - 3 * 86400) or (rq.ts or 0) < now - 30 * 86400 then
            self.db.requests[id] = nil
        end
    end
    for id, a in pairs(self.db.board) do
        if (a.ts or 0) < now - 30 * 86400 then self.db.board[id] = nil end
    end
    for player, profs in pairs(self.db.recipeGone) do -- old "dropped profession" records
        for prof, ts in pairs(profs) do
            if ts < time() - 90 * 86400 then profs[prof] = nil end
        end
        if next(profs) == nil then self.db.recipeGone[player] = nil end
    end
end

function GH:StartTimers()
    C_Timer.NewTicker(30, function()
        GH:RemindSoon()
        GH:ProcessRecurring()
    end)
    C_Timer.NewTicker(3600, function()
        GH:Cleanup()
        GH:RefreshUI()
    end)
    C_Timer.After(10, function() GH:ProcessRecurring() end)
end

-- Messages ------------------------------------------------------------------------------------------------

GH:Handle("EV", function(sender, id, title, when, host, ts, caps, rev, start, kind, whenRev)
    rev, whenRev = tonumber(rev) or 0, tonumber(whenRev) or 0
    local ev = GH.db.events[id]
    if not ev then
        local startNum = tonumber(start)
        local days = GH.db.settings.cleanupDays or 7
        if (startNum or tonumber(ts) or 0) < GH:Now() - days * 86400 then return end -- already finished
        GH.db.events[id] = { id = id, title = title, when = when, host = host,
                             ts = tonumber(ts) or GH:Now(), rsvps = {}, rsvpTs = {},
                             caps = GH:ParseCaps(caps), capsRev = rev, start = startNum,
                             kind = validKind(kind), whenRev = whenRev, descRev = 0 }
        if host ~= GH.me then
            GH:Notify("events", string.format("New event: %s (%s)", title, GH:WhenText(GH.db.events[id])))
        end
        GH:RefreshUI()
        return
    end
    -- A relayed copy of an event we know: take newer caps / time if we missed the host's edit.
    local changed = false
    if rev > (ev.capsRev or 0) then
        ev.caps, ev.capsRev = GH:ParseCaps(caps), rev
        changed = true
    end
    if whenRev > (ev.whenRev or 0) then
        ev.when, ev.start, ev.whenRev = when, tonumber(start), whenRev
        changed = true
    end
    if changed then
        GH:CheckWaitlist(ev)
        GH:RefreshUI()
    end
end)

GH:Handle("CAPS", function(sender, id, caps, rev)
    local ev = GH.db.events[id]
    rev = tonumber(rev) or 0
    if ev and sender == ev.host and rev > (ev.capsRev or 0) then
        ev.caps, ev.capsRev = GH:ParseCaps(caps), rev
        GH:CheckWaitlist(ev)
        GH:RefreshUI()
    end
end)

GH:Handle("WHEN", function(sender, id, rev, when, start)
    local ev = GH.db.events[id]
    rev = tonumber(rev) or 0
    if ev and sender == ev.host and rev > (ev.whenRev or 0) then
        ev.when, ev.start, ev.whenRev = when, tonumber(start), rev
        GH:RefreshUI()
    end
end)

GH:Handle("DESC", function(sender, id, rev, text)
    local ev = GH.db.events[id]
    rev = tonumber(rev) or 0
    if ev and rev > (ev.descRev or 0) then
        ev.desc = (text and text ~= "") and text or nil
        ev.descRev = rev
        GH:RefreshUI()
    end
end)

-- The answer is a role, "wait:<role>", "tentative", "declined", "none" to withdraw, or "1"/"0" from old versions.
GH:Handle("RSVP", function(sender, id, name, answer, ts)
    local ev = GH.db.events[id]
    if not ev or not name then return end
    if answer == "1" then answer = "dps" elseif answer == "0" or answer == "none" then answer = nil end
    if answer ~= nil and not validAnswer(answer) then return end
    ts = tonumber(ts) or 0
    local stamps = rsvpTs(ev)
    if ts < (stamps[name] or 0) then return end -- older than what we already have
    ev.rsvps[name] = answer
    stamps[name] = ts
    GH:CheckWaitlist(ev)
    GH:CheckEventFull(ev)
    GH:RefreshUI()
end)

GH:Handle("ATT", function(sender, id, payload)
    local ev = GH.db.events[id]
    if not ev or not payload then return end
    ev.attended = ev.attended or {}
    for name in payload:gmatch("[^;]+") do ev.attended[name] = true end
    GH:RefreshUI()
end)

GH:Handle("DELEV", function(sender, id)
    local ev = GH.db.events[id]
    if ev and ev.host == sender then
        GH.db.events[id] = nil
        GH:RefreshUI()
    end
end)
