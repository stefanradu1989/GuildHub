local _, GH = ...

local SEP = "~"
local handlers = {}
local queue, ticker = {}, nil

local function clean(s, max)
    s = tostring(s or ""):gsub(SEP, "-")
    return max and s:sub(1, max) or s
end

-- Messages go through a queue (one every 0.15s) so bulk syncs don't get dropped by the server throttle.
local function flush()
    local msg = table.remove(queue, 1)
    if msg then
        C_ChatInfo.SendAddonMessage(GH.PREFIX, msg, "GUILD")
    end
    if #queue == 0 and ticker then
        ticker:Cancel()
        ticker = nil
    end
end

local function enqueue(parts, max)
    if not IsInGuild() then return end
    for i = 1, #parts do parts[i] = clean(parts[i], max) end
    queue[#queue + 1] = table.concat(parts, SEP)
    if not ticker then ticker = C_Timer.NewTicker(0.15, flush) end
end

function GH:Send(...) enqueue({ ... }, 60) end
-- For payloads the caller has already sized to fit in 255 bytes.
function GH:SendRaw(...) enqueue({ ... }) end

function GH:InitComms()
    C_ChatInfo.RegisterAddonMessagePrefix(self.PREFIX)
    local f = CreateFrame("Frame")
    f:RegisterEvent("CHAT_MSG_ADDON")
    f:SetScript("OnEvent", function(_, _, prefix, msg, _, sender)
        if prefix ~= GH.PREFIX then return end
        sender = Ambiguate(sender, "short")
        if sender == GH.me then return end
        local fields = { strsplit(SEP, msg) }
        local h = handlers[fields[1]]
        if h then h(sender, unpack(fields, 2)) end
    end)
    -- ask whoever is online for their data
    C_Timer.After(5, function() GH:Send("SYNCREQ") end)
end

function GH:Handle(cmd, fn) handlers[cmd] = fn end

-- Someone asked for data: reply after a random delay to avoid everyone replying at once.
GH:Handle("SYNCREQ", function()
    C_Timer.After(math.random() * 8, function()
        for _, ev in pairs(GH.db.events) do GH:BroadcastEvent(ev) end
        for _, rq in pairs(GH.db.requests) do GH:BroadcastRequest(rq) end
        GH:BroadcastAllRecipes()
    end)
end)
