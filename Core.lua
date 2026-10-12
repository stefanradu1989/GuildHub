local ADDON, GH = ...
_G.GuildHub = GH

GH.PREFIX = "GuildHub"
GH.me = nil

function GH:Print(...)
    print("|cff33ccff[GuildHub]|r", ...)
end

function GH:NewId()
    return string.format("%s%d%d", self.me or "x", time(), math.random(100, 999))
end

-- Saved data layout. Bump DB_VERSION and add a MIGRATIONS entry whenever the format changes.
local DB_VERSION = 2

local DEFAULTS = {
    version = DB_VERSION,
    events = {},
    requests = {},
    recipes = {},
    settings = {},
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
        GH:InitComms()
        GH:InitUI()
        GH:ScheduleReminders()
        GH:Print("loaded. Type /gh to open.")
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
    else
        GH:ToggleUI()
    end
end
