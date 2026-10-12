local _, GH = ...

local MAX_PAYLOAD = 170 -- bytes of recipe names per message, leaves room for the header

-- db.recipes[player][profession] = { ts = <time>, list = { "Recipe A", "Recipe B", ... } }

local function chunkNames(list)
    local chunks, cur = {}, ""
    for _, name in ipairs(list) do
        name = name:gsub(";", ","):gsub("~", "-")
        if cur ~= "" and #cur + #name + 1 > MAX_PAYLOAD then
            chunks[#chunks + 1] = cur
            cur = ""
        end
        cur = (cur == "") and name or (cur .. ";" .. name)
    end
    chunks[#chunks + 1] = cur
    return chunks
end

function GH:BroadcastRecipes(player, prof, entry)
    local chunks = chunkNames(entry.list)
    for i, payload in ipairs(chunks) do
        self:SendRaw("REC", player, prof, entry.ts, i, #chunks, payload)
    end
end

function GH:BroadcastAllRecipes()
    for player, profs in pairs(self.db.recipes) do
        for prof, entry in pairs(profs) do self:BroadcastRecipes(player, prof, entry) end
    end
end

-- Reads the open profession window. Supports the modern C_TradeSkillUI API and the legacy globals.
local function readOpenProfession()
    local prof, names = nil, {}
    if C_TradeSkillUI and C_TradeSkillUI.GetAllRecipeIDs then
        if (C_TradeSkillUI.IsTradeSkillLinked and C_TradeSkillUI.IsTradeSkillLinked())
            or (C_TradeSkillUI.IsTradeSkillGuild and C_TradeSkillUI.IsTradeSkillGuild()) then
            return
        end
        local info = C_TradeSkillUI.GetBaseProfessionInfo and C_TradeSkillUI.GetBaseProfessionInfo()
        prof = info and info.professionName
        for _, id in ipairs(C_TradeSkillUI.GetAllRecipeIDs()) do
            local ri = C_TradeSkillUI.GetRecipeInfo(id)
            if ri and ri.learned and ri.name then names[#names + 1] = ri.name end
        end
    elseif GetNumTradeSkills then
        if IsTradeSkillLinked and IsTradeSkillLinked() then return end
        prof = GetTradeSkillLine()
        for i = 1, GetNumTradeSkills() do
            local name, kind = GetTradeSkillInfo(i)
            if name and kind ~= "header" and kind ~= "subheader" then names[#names + 1] = name end
        end
    end
    if not prof or prof == "" or prof == "UNKNOWN" or #names == 0 then return end
    table.sort(names)
    return prof, names
end

function GH:ScanProfession()
    local prof, names = readOpenProfession()
    if not prof then return end
    local mine = self.db.recipes[self.me] or {}
    self.db.recipes[self.me] = mine
    local old = mine[prof]
    if old and table.concat(old.list, ";") == table.concat(names, ";") then return end
    mine[prof] = { ts = time(), list = names }
    self.recipesVersion = (self.recipesVersion or 0) + 1
    self:BroadcastRecipes(self.me, prof, mine[prof])
    self:Print(string.format("Shared %d %s recipes with the guild.", #names, prof))
    self:RefreshUI()
end

-- Which profession a recipe belongs to, by exact (case-insensitive) name, from the shared recipe directory.
-- Returns nil if nobody has shared it. The lookup table is rebuilt only when recipes change.
function GH:ProfessionOf(item)
    if self.profIndexVersion ~= (self.recipesVersion or 0) or not self.profIndex then
        local index = {}
        for _, profs in pairs(self.db.recipes) do
            for prof, entry in pairs(profs) do
                for _, name in ipairs(entry.list) do index[name:lower()] = prof end
            end
        end
        self.profIndex, self.profIndexVersion = index, self.recipesVersion or 0
    end
    return self.profIndex[(item or ""):lower()]
end

-- Returns { {recipe=, prof=, crafters={...}}, ... } for recipes matching query, sorted by name.
function GH:FindCrafters(query)
    query = (query or ""):lower()
    local byKey, out = {}, {}
    for player, profs in pairs(self.db.recipes) do
        for prof, entry in pairs(profs) do
            for _, name in ipairs(entry.list) do
                if query == "" or name:lower():find(query, 1, true) then
                    local key = prof .. "\0" .. name
                    local r = byKey[key]
                    if not r then
                        r = { recipe = name, prof = prof, crafters = {} }
                        byKey[key] = r
                        out[#out + 1] = r
                    end
                    r.crafters[#r.crafters + 1] = player
                end
            end
        end
    end
    for _, r in ipairs(out) do table.sort(r.crafters) end
    table.sort(out, function(a, b) return a.recipe < b.recipe end)
    return out
end

GH:Handle("REC", function(sender, player, prof, ts, seq, total, payload)
    ts, seq, total = tonumber(ts), tonumber(seq), tonumber(total)
    if not (player and prof and ts and seq and total) then return end
    local existing = GH.db.recipes[player] and GH.db.recipes[player][prof]
    if existing and existing.ts >= ts then return end -- already have this or newer

    GH.recvBuf = GH.recvBuf or {}
    local key = player .. "\0" .. prof
    local buf = GH.recvBuf[key]
    if not buf or buf.ts ~= ts or buf.total ~= total then
        buf = { ts = ts, total = total, parts = {}, count = 0 }
        GH.recvBuf[key] = buf
    end
    if not buf.parts[seq] then
        buf.parts[seq] = payload or ""
        buf.count = buf.count + 1
    end
    if buf.count < total then return end

    local list = {}
    for i = 1, total do
        for name in (buf.parts[i] or ""):gmatch("[^;]+") do list[#list + 1] = name end
    end
    GH.recvBuf[key] = nil
    GH.db.recipes[player] = GH.db.recipes[player] or {}
    GH.db.recipes[player][prof] = { ts = ts, list = list }
    GH.recipesVersion = (GH.recipesVersion or 0) + 1
    GH:RefreshUI()
end)

local pending
local scanFrame = CreateFrame("Frame")
for _, ev in ipairs({ "TRADE_SKILL_SHOW", "TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_UPDATE" }) do
    pcall(scanFrame.RegisterEvent, scanFrame, ev) -- skip events this client doesn't have
end
scanFrame:SetScript("OnEvent", function()
    if pending or not GH.db then return end
    pending = true
    C_Timer.After(1.5, function() -- debounce: these events fire many times while the window loads
        pending = false
        GH:ScanProfession()
    end)
end)
