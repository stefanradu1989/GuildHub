local ADDON, GH = ...
_G.GuildHub = GH

GH.PREFIX = "GuildHub"
GH.me = nil
GH.quiet = true -- no notifications while the login sync is still bringing in old data

function GH:Print(...)
    print("|cff33ccff[GuildHub]|r", ...)
end

-- Server time: the same moment for everyone, so it's what we use to order sign-ups.
function GH:Now()
    return (GetServerTime and GetServerTime()) or time()
end

function GH:NewId()
    return string.format("%s%d%d", self.me or "x", time(), math.random(100, 999))
end

-- A short code for an event (e.g. "4F9K"), used in shared chat messages: /gh #4F9K
function GH:ShortId(id)
    local h = 5381
    for i = 1, #id do h = (h * 33 + id:byte(i)) % 1679616 end -- 36^4
    local chars, out = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ", ""
    for _ = 1, 4 do
        local d = h % 36
        out = chars:sub(d + 1, d + 1) .. out
        h = math.floor(h / 36)
    end
    return out
end

function GH:Ping()
    if self.db and self.db.settings.sound then
        pcall(PlaySound, SOUNDKIT and SOUNDKIT.TELL_MESSAGE or 3081)
    end
end

-- Prints a notification if that kind is switched on in the settings. Silent during the login sync.
-- kind: "events" | "requests" | "craftable" | "board"
function GH:Notify(kind, msg)
    if self.quiet or not self.db.settings["notify_" .. kind] then return end
    self:Print(msg)
    self:Ping()
end

-- Saved data layout. Bump DB_VERSION and add a MIGRATIONS entry whenever the format changes.
local DB_VERSION = 3

local DEFAULTS = {
    version = DB_VERSION,
    events = {},
    requests = {},
    recipes = {},
    board = {},
    recipeGone = {}, -- professions people have dropped: recipeGone[player][profession] = time
    stats = { fulfilled = {}, requested = {} },
    settings = {
        notify_events = true,
        notify_requests = true,
        notify_craftable = true,
        notify_board = true,
        sound = true,
        minimap = { hide = false, angle = 215 },
        reminderLead = 15, -- minutes before an event you signed up for; 0 = off
        cleanupDays = 7,   -- how long finished events and requests are kept
        lastBoardSeen = 0,
    },
}

-- MIGRATIONS[n] upgrades data from version n to n + 1.
local MIGRATIONS = {
    -- v1 -> v2: event RSVPs went from `true` to a role string.
    [1] = function(db)
        for _, ev in pairs(db.events or {}) do
            for name, v in pairs(ev.rsvps or {}) do
                if v == true then ev.rsvps[name] = "dps" end
            end
        end
    end,
    -- v2 -> v3: gathering professions (skinning, mining, herbalism, fishing) are no longer tracked.
    [2] = function(db)
        for _, profs in pairs(db.recipes or {}) do
            for prof in pairs(profs) do
                if GH:IsIgnoredProfession(prof) then profs[prof] = nil end
            end
        end
    end,
}

-- Fills in any missing keys from defaults without touching values the user already has.
local function copyDefaults(src, dst)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then dst[k] = {} end
            copyDefaults(v, dst[k])
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
    return dst
end

local function initDB()
    local db = GuildHubDB
    if type(db) ~= "table" then db = {} end
    local version = db.version or 1 -- data saved before versioning existed is v1
    if version > DB_VERSION then
        -- Saved by a newer addon version (e.g. after a downgrade): don't touch it.
        GH:Print("saved data is from a newer version; running without changing it.")
        GH.db = copyDefaults(DEFAULTS, db)
        return
    end
    for v = version, DB_VERSION - 1 do
        local ok, err = pcall(MIGRATIONS[v], db)
        if not ok then GH:Print("migration from v" .. v .. " failed: " .. tostring(err)) end
    end
    db.version = DB_VERSION
    GuildHubDB = copyDefaults(DEFAULTS, db)
    GH.db = GuildHubDB
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON then
        initDB()
    elseif event == "PLAYER_LOGIN" then
        GH.me = UnitName("player")
        GH:Cleanup()
        GH:InitComms()
        GH:InitUI()
        GH:InitSettings()
        GH:InitMinimapButton()
        GH:ScheduleReminders()
        GH:StartTimers()
        GH:RequestRoster()
        GH:StartProfessionSync()
        C_Timer.After(25, function() GH.quiet = false end)
        GH:Print("loaded. Type /gh to open, or use the minimap button.")
    end
end)

SLASH_GUILDHUB1 = "/gh"
SLASH_GUILDHUB2 = "/guildhub"
SlashCmdList["GUILDHUB"] = function(msg)
    local cmd, rest = (msg or ""):match("^(%S*)%s*(.-)$")
    if cmd == "who" and rest ~= "" then
        local found = GH:FindCrafters(rest)
        if #found == 0 then
            GH:Print("No known crafters for '" .. rest .. "'. They need to open their profession window with the addon on.")
        end
        for i = 1, math.min(#found, 10) do
            GH:Print(string.format("%s (%s): %s", found[i].recipe, found[i].prof, table.concat(found[i].crafters, ", ")))
        end
    elseif cmd == "settings" then
        GH:ToggleSettings()
    elseif cmd:sub(1, 1) == "#" then
        GH:OpenEventByCode(cmd:sub(2))
    else
        GH:ToggleUI()
    end
end
