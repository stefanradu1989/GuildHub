local _, GH = ...

-- A request: { id, item, requester, ts, prof, itemID, mats, due, bank, claimedBy, claimRev, done, doneAt, counted }
--   prof / itemID  the recipe's profession and item (when known), for filtering and item tooltips
--   mats           free text: materials the requester will provide, or notes
--   due            timestamp: "needed by"
--   bank           true for a guild bank request (someone with bank access fulfills it, nothing is crafted)

function GH:BroadcastRequest(rq)
    self:Send("RQ", rq.id, rq.item, rq.requester, rq.ts, rq.prof or "", rq.itemID or "", rq.mats or "",
        rq.due or "", rq.bank and 1 or 0)
    if rq.claimedBy then
        self:Send("CLAIM", rq.id, rq.claimedBy, rq.claimRev or 1)
    elseif rq.claimRev then
        self:Send("UNCLAIM", rq.id, rq.claimRev) -- so stale copies learn the claim was given back
    end
    if rq.done then self:Send("DONE", rq.id) end
end

-- opts: item, prof, itemID, mats, due (text like "sat 20:00" or "2026-11-04"), bank
-- The profession and item id are looked up in the shared recipe directory when not given.
function GH:CreateRequest(opts)
    local prof, itemID = opts.prof, opts.itemID
    if not opts.bank then
        local p, id = self:RecipeInfo(opts.item)
        prof, itemID = prof or p, itemID or id
    end
    local due
    if opts.due and opts.due ~= "" then
        due = self:ParseWhen(opts.due)
        if not due then
            self:Print("Couldn't read the 'needed by' time, so the request has no deadline. " ..
                "Use e.g. sat, tomorrow 20:00 or 2026-11-04.")
        end
    end
    local mats = (opts.mats and opts.mats ~= "") and (opts.mats:gsub("~", "-")) or nil
    local rq = { id = self:NewId(), item = opts.item, requester = self.me, ts = self:Now(), prof = prof,
                 itemID = itemID, mats = mats, due = due, bank = opts.bank or nil }
    self.db.requests[rq.id] = rq
    self:BroadcastRequest(rq)
    self:RefreshUI()
    self:Print((opts.bank and "Posted a guild bank request for " or "Posted a request for ") .. opts.item)
end

-- Marks a request finished and updates the leaderboard counters (once per request).
local function markDone(rq)
    if rq.done then return end
    rq.done = true
    rq.doneAt = GH:Now()
    if not rq.counted then
        rq.counted = true
        local stats = GH.db.stats
        stats.requested[rq.requester] = (stats.requested[rq.requester] or 0) + 1
        if rq.claimedBy then stats.fulfilled[rq.claimedBy] = (stats.fulfilled[rq.claimedBy] or 0) + 1 end
    end
end

-- Returns { { name =, fulfilled =, requested = }, ... }, most fulfilled first. Counts what this client has seen.
function GH:Leaderboard()
    local stats, names = self.db.stats, {}
    for name in pairs(stats.fulfilled) do names[name] = true end
    for name in pairs(stats.requested) do names[name] = true end
    local list = {}
    for name in pairs(names) do
        if self:IsMember(name) then
            list[#list + 1] = { name = name, fulfilled = stats.fulfilled[name] or 0,
                                requested = stats.requested[name] or 0 }
        end
    end
    table.sort(list, function(a, b)
        if a.fulfilled ~= b.fulfilled then return a.fulfilled > b.fulfilled end
        if a.requested ~= b.requested then return a.requested > b.requested end
        return a.name < b.name
    end)
    return list
end

function GH:ClaimRequest(id)
    local rq = self.db.requests[id]
    if not rq or rq.done or rq.claimedBy or rq.requester == self.me then return end
    rq.claimedBy = self.me
    rq.claimRev = (rq.claimRev or 0) + 1
    self:Send("CLAIM", id, self.me, rq.claimRev)
    self:RefreshUI()
end

-- Gives a request you took back to the pool so someone else can take it.
-- claimRev counts claim/unclaim changes, so an old copy of the request can't undo a newer one.
function GH:UnclaimRequest(id)
    local rq = self.db.requests[id]
    if not rq or rq.done or rq.claimedBy ~= self.me then return end
    rq.claimedBy = nil
    rq.claimRev = (rq.claimRev or 0) + 1
    self:Send("UNCLAIM", id, rq.claimRev)
    self:RefreshUI()
end

function GH:CompleteRequest(id)
    local rq = self.db.requests[id]
    if rq and (rq.requester == self.me or rq.claimedBy == self.me) then
        markDone(rq)
        self:Send("DONE", id)
        self:RefreshUI()
    end
end

function GH:DeleteRequest(id)
    local rq = self.db.requests[id]
    if rq and rq.requester == self.me then
        self.db.requests[id] = nil
        self:Send("DELRQ", id)
        self:RefreshUI()
    end
end

GH:Handle("RQ", function(sender, id, item, requester, ts, prof, itemID, mats, due, bank)
    if GH.db.requests[id] or not item or not requester then return end
    ts = tonumber(ts) or GH:Now()
    if ts < GH:Now() - 30 * 86400 then return end -- too old to bother with
    local rq = { id = id, item = item, requester = requester, ts = ts,
                 prof = (prof and prof ~= "") and prof or nil,
                 itemID = tonumber(itemID),
                 mats = (mats and mats ~= "") and mats or nil,
                 due = tonumber(due),
                 bank = bank == "1" or nil }
    GH.db.requests[id] = rq
    if requester ~= GH.me then
        if rq.bank then
            if GH:IsOfficer() then GH:Notify("requests", requester .. " asked the guild bank for " .. item .. ".") end
        elseif GH:CanCraft(item) then
            GH:Notify("craftable", requester .. " needs " .. item .. " - you can craft it! (open /gh)")
        end
    end
    GH:RefreshUI()
end)

-- A claim is accepted if it's newer than what we have, or the same revision and the request is still free.
-- (Messages from older versions have no revision; treat them as 1.)
GH:Handle("CLAIM", function(sender, id, name, rev)
    local rq = GH.db.requests[id]
    if not rq or not name then return end
    rev = tonumber(rev) or 1
    local have = rq.claimRev or 0
    if rev > have or (rev == have and not rq.claimedBy) then
        rq.claimedBy, rq.claimRev = name, rev
        if rq.requester == GH.me and name ~= GH.me then
            GH:Notify("requests", name .. (rq.bank and " will handle" or " is working on") .. " your request: " .. rq.item)
        end
        GH:RefreshUI()
    end
end)

GH:Handle("UNCLAIM", function(sender, id, rev)
    local rq = GH.db.requests[id]
    rev = tonumber(rev)
    if rq and rev and rev > (rq.claimRev or 0) then
        rq.claimedBy, rq.claimRev = nil, rev
        GH:RefreshUI()
    end
end)

GH:Handle("DONE", function(sender, id)
    local rq = GH.db.requests[id]
    if not rq or rq.done then return end
    -- Only the requester or whoever took it can finish it. If we missed the claim, the sender must have taken it.
    if sender ~= rq.requester and sender ~= rq.claimedBy then
        if rq.claimedBy then return end
        rq.claimedBy = sender
    end
    markDone(rq)
    if rq.requester == GH.me and sender == rq.claimedBy then
        GH:Notify("requests", string.format("%s marked your request for %s as %s.", sender, rq.item,
            rq.bank and "fulfilled" or "crafted"))
    end
    GH:RefreshUI()
end)

GH:Handle("DELRQ", function(sender, id)
    local rq = GH.db.requests[id]
    if rq and rq.requester == sender then GH.db.requests[id] = nil; GH:RefreshUI() end
end)
