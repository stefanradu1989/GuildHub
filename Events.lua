local _, GH = ...

GH.ROLES = {
    { key = "tank",   label = "Tank",   color = "ff1a5fbf" },
    { key = "healer", label = "Healer", color = "ff1a8a3a" },
    { key = "dps",    label = "DPS",    color = "ffc0301a" },
}
local VALID = { tank = true, healer = true, dps = true }

-- ev.rsvps[player] = "tank" | "healer" | "dps". Data saved by v0.1 used `true`; treat that as DPS.
local function roleOf(v)
    if VALID[v] then return v end
    if v then return "dps" end
end

function GH:RoleOf(ev, name) return roleOf(ev.rsvps[name]) end

-- Returns { tank = {names...}, healer = {...}, dps = {...} } with sorted names.
function GH:RosterByRole(ev)
    local out = { tank = {}, healer = {}, dps = {} }
    for name, v in pairs(ev.rsvps) do
        local r = roleOf(v)
        if r then out[r][#out[r] + 1] = name end
    end
    for _, list in pairs(out) do table.sort(list) end
    return out
end

-- Event times. ev.start is a Unix timestamp (so it means the same moment for everyone, whatever
-- their time zone); ev.when keeps the text the host typed for events whose time couldn't be parsed.
local DAYS = { sun = 1, mon = 2, tue = 3, wed = 4, thu = 5, fri = 6, sat = 7 } -- matches date("*t").wday

-- Accepts "2026-11-04 20:00", "20:00" / "today 20:00", "tomorrow 20:00" or "sat 20:00" (the next Saturday),
-- all in the player's local time. Returns a timestamp, or nil if it can't be read.
function GH:ParseWhen(str)
    str = (str or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    local now = time()
    local t = date("*t", now)

    local y, mo, d, hh, mm = str:match("^(%d%d%d%d)%-(%d%d?)%-(%d%d?)%s+(%d%d?):(%d%d)$")
    if y then
        y, mo, d, hh, mm = tonumber(y), tonumber(mo), tonumber(d), tonumber(hh), tonumber(mm)
        if mo < 1 or mo > 12 or d < 1 or d > 31 or hh > 23 or mm > 59 then return nil end
        return time({ year = y, month = mo, day = d, hour = hh, min = mm, sec = 0 })
    end

    local word, h, m = str:match("^(%a*)%s*(%d%d?):(%d%d)$")
    if not h then return nil end
    h, m = tonumber(h), tonumber(m)
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

-- Prints a login reminder for events that start today (or began within the last 2 hours).
-- Each event is announced at most once per session.
function GH:RemindToday()
    self.reminded = self.reminded or {}
    local now = time()
    local today = date("%Y%m%d", now)
    local due = {}
    for _, ev in pairs(self.db.events) do
        if ev.start and not self.reminded[ev.id] and date("%Y%m%d", ev.start) == today
            and ev.start > now - 2 * 3600 then
            due[#due + 1] = ev
        end
    end
    table.sort(due, function(a, b) return a.start < b.start end)
    for _, ev in ipairs(due) do
        self.reminded[ev.id] = true
        local role = self:RoleOf(ev, self.me)
        self:Print(string.format("Today: |cffffd100%s|r at %s %s", ev.title, date("%H:%M", ev.start),
            role and ("(you're signed up as " .. role .. ")") or "(you're not signed up - type /gh)"))
    end
end

-- Checks once from saved data, then again after the login sync has had time to bring in new events.
function GH:ScheduleReminders()
    C_Timer.After(4, function() GH:RemindToday() end)
    C_Timer.After(20, function() GH:RemindToday() end)
end

-- ev.caps = { tank = n, healer = n, dps = n }, where 0 means no limit. nil means no limits at all.
function GH:CapOf(ev, role)
    return ev.caps and ev.caps[role] or 0
end

-- True if signing up as `role` would exceed its cap. Your own current role never counts as full.
function GH:IsFull(ev, role)
    local cap = self:CapOf(ev, role)
    if cap == 0 or roleOf(ev.rsvps[self.me]) == role then return false end
    return #self:RosterByRole(ev)[role] >= cap
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
    self:Send("EV", ev.id, ev.title, ev.when, ev.host, ev.ts, capsString(ev), ev.capsRev or 0, ev.start or "")
    for name, v in pairs(ev.rsvps) do
        local r = roleOf(v)
        if r then self:Send("RSVP", ev.id, name, r) end
    end
end

function GH:CreateEvent(title, when, caps)
    local start = self:ParseWhen(when)
    if not start then
        self:Print("Couldn't read that time, so there will be no reminder for this event. " ..
            "Use e.g. 2026-11-04 20:00, sat 20:00 or tomorrow 20:00.")
    end
    local ev = { id = self:NewId(), title = title, when = when, host = self.me,
                 ts = time(), rsvps = {}, caps = caps, start = start }
    self.db.events[ev.id] = ev
    self:BroadcastEvent(ev)
    self:RefreshUI()
    self:Print("Created event '" .. title .. "'." ..
        (IsInGuild() and "" or " You're not in a guild, so it's only saved on this character's addon data."))
end

-- role = "tank" | "healer" | "dps", or nil to withdraw.
function GH:SetRole(id, role)
    local ev = self.db.events[id]
    if not ev then return end
    role = roleOf(role)
    if role and self:IsFull(ev, role) then
        self:Print(string.format("The %s slots for '%s' are full.", role, ev.title))
        return
    end
    ev.rsvps[self.me] = role
    self:Send("RSVP", id, self.me, role or "none")
    self:RefreshUI()
end

-- Host only. Each edit bumps capsRev so stale copies of the event can't overwrite newer caps.
function GH:EditCaps(id, caps)
    local ev = self.db.events[id]
    if not ev then return end
    if ev.host ~= self.me then
        self:Print("Only the host (" .. ev.host .. ") can change the slots.")
        return
    end
    ev.caps = caps
    ev.capsRev = (ev.capsRev or 0) + 1
    self:Send("CAPS", id, capsString(ev), ev.capsRev)
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

GH:Handle("EV", function(sender, id, title, when, host, ts, caps, rev, start)
    rev = tonumber(rev) or 0
    local ev = GH.db.events[id]
    if not ev then
        GH.db.events[id] = { id = id, title = title, when = when, host = host,
                             ts = tonumber(ts) or time(), rsvps = {},
                             caps = GH:ParseCaps(caps), capsRev = rev, start = tonumber(start) }
        GH:RefreshUI()
    elseif rev > (ev.capsRev or 0) then
        -- A relayed copy with newer caps (we missed the host's edit).
        ev.caps, ev.capsRev = GH:ParseCaps(caps), rev
        GH:RefreshUI()
    end
end)

GH:Handle("CAPS", function(sender, id, caps, rev)
    local ev = GH.db.events[id]
    rev = tonumber(rev) or 0
    if ev and sender == ev.host and rev > (ev.capsRev or 0) then
        ev.caps, ev.capsRev = GH:ParseCaps(caps), rev
        GH:RefreshUI()
    end
end)

-- Third field is a role, "none" to withdraw, or "1"/"0" from older versions.
GH:Handle("RSVP", function(sender, id, name, role)
    local ev = GH.db.events[id]
    if not ev or not name then return end
    if role == "1" then role = "dps" end
    ev.rsvps[name] = VALID[role] and role or nil
    GH:RefreshUI()
end)

GH:Handle("DELEV", function(sender, id)
    local ev = GH.db.events[id]
    if ev and ev.host == sender then
        GH.db.events[id] = nil
        GH:RefreshUI()
    end
end)
