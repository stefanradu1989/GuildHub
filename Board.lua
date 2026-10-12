local _, GH = ...

-- Guild board: short announcements from officers, shown on login and listed on the Board page.
-- db.board[id] = { id, text, author, ts }

local MAX_LEN = 150

function GH:BroadcastAnnouncement(a)
    self:SendRaw("BRD", a.id, a.ts, a.author, a.text)
end

function GH:BroadcastBoard()
    for _, a in pairs(self.db.board) do self:BroadcastAnnouncement(a) end
end

function GH:PostAnnouncement(text)
    if not self:IsOfficer() then
        self:Print("Only officers can post announcements.")
        return
    end
    text = (text or ""):gsub("~", "-")
    text = text:sub(1, MAX_LEN)
    if text == "" then return end
    local a = { id = self:NewId(), text = text, author = self.me, ts = self:Now() }
    self.db.board[a.id] = a
    self:BroadcastAnnouncement(a)
    self.db.settings.lastBoardSeen = math.max(self.db.settings.lastBoardSeen or 0, a.ts)
    self:RefreshUI()
    self:Print("Posted your announcement.")
end

function GH:DeleteAnnouncement(id)
    local a = self.db.board[id]
    if a and a.author == self.me then
        self.db.board[id] = nil
        self:Send("DELBRD", id)
        self:RefreshUI()
    end
end

-- Prints announcements posted since you last looked.
function GH:ShowNewAnnouncements()
    local seen = self.db.settings.lastBoardSeen or 0
    local fresh = {}
    for _, a in pairs(self.db.board) do
        if a.ts > seen then fresh[#fresh + 1] = a end
    end
    table.sort(fresh, function(a, b) return a.ts < b.ts end)
    for _, a in ipairs(fresh) do
        self:Print(string.format("|cffffd100Guild announcement|r from %s: %s", a.author, a.text))
        seen = math.max(seen, a.ts)
    end
    if #fresh > 0 then self:Ping() end
    self.db.settings.lastBoardSeen = seen
end

GH:Handle("BRD", function(sender, id, ts, author, text)
    if GH.db.board[id] or not text or text == "" then return end
    ts = tonumber(ts) or GH:Now()
    if ts < GH:Now() - 30 * 86400 then return end
    GH.db.board[id] = { id = id, text = text, author = author or sender, ts = ts }
    -- While quiet (login sync), ShowNewAnnouncements prints these instead.
    if not GH.quiet then
        GH:Notify("board", string.format("Guild announcement from %s: %s", author or sender, text))
        GH.db.settings.lastBoardSeen = math.max(GH.db.settings.lastBoardSeen or 0, ts)
    end
    GH:RefreshUI()
end)

GH:Handle("DELBRD", function(sender, id)
    local a = GH.db.board[id]
    if a and a.author == sender then
        GH.db.board[id] = nil
        GH:RefreshUI()
    end
end)
