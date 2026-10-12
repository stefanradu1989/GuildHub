local _, GH = ...

function GH:BroadcastRequest(rq)
    self:Send("RQ", rq.id, rq.item, rq.requester, rq.ts)
    if rq.claimedBy then self:Send("CLAIM", rq.id, rq.claimedBy) end
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
    self:Send("CLAIM", id, self.me)
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

GH:Handle("CLAIM", function(sender, id, name)
    local rq = GH.db.requests[id]
    if rq and not rq.claimedBy then rq.claimedBy = name; GH:RefreshUI() end
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
