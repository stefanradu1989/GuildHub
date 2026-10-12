local _, GH = ...

-- Guild roster (who is currently a member) and officer check.

GH.guildMembers = {}
GH.rosterLoaded = false

function GH:RequestRoster()
    if C_GuildInfo and C_GuildInfo.GuildRoster then
        C_GuildInfo.GuildRoster()
    elseif GuildRoster then
        GuildRoster()
    end
end

function GH:UpdateRoster()
    local set, count = {}, 0
    local total = GetNumGuildMembers and GetNumGuildMembers() or 0
    for i = 1, total do
        local name = GetGuildRosterInfo(i)
        if name then
            set[Ambiguate(name, "short")] = true
            count = count + 1
        end
    end
    if count > 0 then self.guildMembers, self.rosterLoaded = set, true end
end

-- True if `name` is in the guild. Until the roster has loaded we can't tell, so everyone counts as a member.
function GH:IsMember(name)
    if not self.rosterLoaded then return true end
    return self.guildMembers[name] == true
end

-- Officers (and the guild master) can post announcements. This only hides the button for other members;
-- addon messages themselves can't be verified.
function GH:IsOfficer()
    if IsGuildLeader and IsGuildLeader() then return true end
    if C_GuildInfo and C_GuildInfo.IsGuildOfficer and C_GuildInfo.IsGuildOfficer() then return true end
    return (CanEditOfficerNote and CanEditOfficerNote()) or false
end

-- Drops recipe data for people who are no longer in the guild.
function GH:PruneMembers()
    if not self.rosterLoaded then return end
    local removed = false
    for player in pairs(self.db.recipes) do
        if not self.guildMembers[player] then
            self.db.recipes[player] = nil
            removed = true
        end
    end
    if removed then self.recipesVersion = (self.recipesVersion or 0) + 1 end
end

-- Opens the chat box with a prefilled whisper. The player reviews it and presses Enter.
function GH:Whisper(name, text)
    ChatFrame_OpenChat("/w " .. name .. " " .. (text or ""))
end

-- Opens the chat box with a prefilled guild message.
function GH:SayGuild(text)
    ChatFrame_OpenChat("/g " .. text)
end

local f = CreateFrame("Frame")
f:RegisterEvent("GUILD_ROSTER_UPDATE")
f:SetScript("OnEvent", function()
    if not GH.db then return end
    GH:UpdateRoster()
    GH:PruneMembers()
    GH:RefreshUI()
end)
