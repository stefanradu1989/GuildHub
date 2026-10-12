local _, GH = ...

function GH:BroadcastRequest(rq)
    self:Send("RQ", rq.id, rq.item, rq.requester, rq.ts)
    if rq.claimedBy then
        self:Send("CLAIM", rq.id, rq.claimedBy, rq.claimRev or 1)
    elseif rq.claimRev then
        self:Send("UNCLAIM", rq.id, rq.claimRev) -- so stale copies learn the claim was given back
    end
    if rq.done then self:Send("DONE", rq.id) end
end

function GH:CreateRequest(item)
    local rq = { id = self:NewId(), item = item, requester = self.me, ts = time() }
    self.db.requests[rq.id] = rq
    self:BroadcastRequest(rq)
    self:RefreshUI()
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
        rq.done = true
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

GH:Handle("RQ", function(sender, id, item, requester, ts)
    if not GH.db.requests[id] then
        GH.db.requests[id] = { id = id, item = item, requester = requester, ts = tonumber(ts) or time() }
        GH:RefreshUI()
    end
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
    if rq and (sender == rq.requester or sender == rq.claimedBy) then
        rq.done = true
        GH:RefreshUI()
    end
end)

GH:Handle("DELRQ", function(sender, id)
    local rq = GH.db.requests[id]
    if rq and rq.requester == sender then GH.db.requests[id] = nil; GH:RefreshUI() end
end)
