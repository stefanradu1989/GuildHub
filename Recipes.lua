local _, GH = ...

local MAX_PAYLOAD = 170 -- bytes of recipe entries per message, leaves room for the header

-- db.recipes[player][profession] = {
--     ts = <time>,
--     list = { "Recipe A", "Recipe B", ... },          -- names, sorted
--     items = { ["Recipe A"] = <itemID>, ... },         -- only for recipes that make an item
-- }

-- Gathering professions aren't tracked: they don't craft anything other players would request.
-- Matched by English name; the profession names of the player's own language are added from the spell names
-- the first time we check. The modern API's profession id is checked too.
local IGNORED_NAMES = { skinning = true, mining = true, herbalism = true, ["herb gathering"] = true, fishing = true }
local IGNORED_IDS = { [393] = true, [186] = true, [182] = true, [356] = true } -- skinning, mining, herbalism, fishing
local IGNORED_SPELLS = { 8613, 2575, 2366, 7620 } -- Skinning, Mining, Herb Gathering, Fishing
local localeAdded = false

function GH:IsIgnoredProfession(prof, id)
    if not localeAdded then
        localeAdded = true
        for _, spellId in ipairs(IGNORED_SPELLS) do
            local name = (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellId))
                or (GetSpellInfo and GetSpellInfo(spellId))
            if type(name) == "string" then IGNORED_NAMES[name:lower()] = true end
        end
    end
    return (prof and IGNORED_NAMES[prof:lower()]) or (id and IGNORED_IDS[id]) or false
end

-- "Recipe name@itemID" entries joined by ";", split into chunks that fit in one message.
local function chunkEntries(list, items)
    local chunks, cur = {}, ""
    for _, name in ipairs(list) do
        local entry = name:gsub("[;~@]", "-")
        local id = items and items[name]
        if id then entry = entry .. "@" .. id end
        if cur ~= "" and #cur + #entry + 1 > MAX_PAYLOAD then
            chunks[#chunks + 1] = cur
            cur = ""
        end
        cur = (cur == "") and entry or (cur .. ";" .. entry)
    end
    chunks[#chunks + 1] = cur
    return chunks
end

local function signature(list, items)
    return table.concat(chunkEntries(list, items), "|")
end

function GH:BroadcastRecipes(player, prof, entry)
    local chunks = chunkEntries(entry.list, entry.items)
    for i, payload in ipairs(chunks) do
        self:SendRaw("REC", player, prof, entry.ts, i, #chunks, payload)
    end
end

function GH:BroadcastAllRecipes()
    for player, profs in pairs(self.db.recipes) do
        for prof, entry in pairs(profs) do self:BroadcastRecipes(player, prof, entry) end
    end
end

local function itemIdFromLink(link)
    local id = type(link) == "string" and link:match("item:(%d+)")
    return id and tonumber(id)
end

-- Reads the open profession window. Supports the modern C_TradeSkillUI API and the legacy globals.
-- Returns the profession name, the sorted recipe names, and a { name = itemID } table.
local function readOpenProfession()
    local prof, names, items = nil, {}, {}
    if C_TradeSkillUI and C_TradeSkillUI.GetAllRecipeIDs then
        if (C_TradeSkillUI.IsTradeSkillLinked and C_TradeSkillUI.IsTradeSkillLinked())
            or (C_TradeSkillUI.IsTradeSkillGuild and C_TradeSkillUI.IsTradeSkillGuild()) then
            return
        end
        local info = C_TradeSkillUI.GetBaseProfessionInfo and C_TradeSkillUI.GetBaseProfessionInfo()
        prof = info and info.professionName
        if GH:IsIgnoredProfession(prof, info and info.professionID) then return end
        for _, id in ipairs(C_TradeSkillUI.GetAllRecipeIDs()) do
            local ri = C_TradeSkillUI.GetRecipeInfo(id)
            if ri and ri.learned and ri.name then
                names[#names + 1] = ri.name
                if C_TradeSkillUI.GetRecipeItemLink then
                    local ok, link = pcall(C_TradeSkillUI.GetRecipeItemLink, id)
                    local itemId = ok and itemIdFromLink(link)
                    if itemId then items[ri.name] = itemId end
                end
            end
        end
    elseif GetNumTradeSkills then
        if IsTradeSkillLinked and IsTradeSkillLinked() then return end
        prof = GetTradeSkillLine()
        for i = 1, GetNumTradeSkills() do
            local name, kind = GetTradeSkillInfo(i)
            if name and kind ~= "header" and kind ~= "subheader" then
                names[#names + 1] = name
                if GetTradeSkillItemLink then
                    local itemId = itemIdFromLink(GetTradeSkillItemLink(i))
                    if itemId then items[name] = itemId end
                end
            end
        end
    end
    if not prof or prof == "" or prof == "UNKNOWN" or #names == 0 or GH:IsIgnoredProfession(prof) then return end
    table.sort(names)
    return prof, names, items
end

function GH:ScanProfession()
    local prof, names, items = readOpenProfession()
    if not prof then return end
    local mine = self.db.recipes[self.me] or {}
    self.db.recipes[self.me] = mine
    local old = mine[prof]
    if old and signature(old.list, old.items) == signature(names, items) then return end
    mine[prof] = { ts = time(), list = names, items = items }
    self.recipesVersion = (self.recipesVersion or 0) + 1
    self:BroadcastRecipes(self.me, prof, mine[prof])
    self:Print(string.format("Shared %d %s recipes with the guild.", #names, prof))
    self:RefreshUI()
end

-- Lookup tables over the shared recipes (lowercase recipe name -> profession / item id), rebuilt only when
-- recipes change. People who have left the guild are left out.
local function recipeIndex()
    if GH.recipeIndex and GH.recipeIndexVersion == (GH.recipesVersion or 0) then return GH.recipeIndex end
    local byProf, byItem = {}, {}
    for player, profs in pairs(GH.db.recipes) do
        if GH:IsMember(player) then
            for prof, entry in pairs(profs) do
                for _, name in ipairs(entry.list) do
                    local key = name:lower()
                    byProf[key] = prof
                    local id = entry.items and entry.items[name]
                    if id then byItem[key] = id end
                end
            end
        end
    end
    GH.recipeIndex = { prof = byProf, item = byItem }
    GH.recipeIndexVersion = GH.recipesVersion or 0
    return GH.recipeIndex
end

-- Profession and item id of a recipe, by exact (case-insensitive) name. Both are nil if nobody has shared it.
function GH:RecipeInfo(item)
    local index, key = recipeIndex(), (item or ""):lower()
    return index.prof[key], index.item[key]
end

function GH:ProfessionOf(item)
    return (self:RecipeInfo(item))
end

-- True if you know the recipe (from a profession window you opened with the addon loaded).
function GH:CanCraft(item)
    local key = (item or ""):lower()
    for _, entry in pairs(self.db.recipes[self.me] or {}) do
        for _, name in ipairs(entry.list) do
            if name:lower() == key then return true end
        end
    end
    return false
end

-- Returns { {recipe=, prof=, crafters={...}}, ... } for recipes matching query, sorted by name.
function GH:FindCrafters(query)
    query = (query or ""):lower()
    local byKey, out = {}, {}
    for player, profs in pairs(self.db.recipes) do
        if self:IsMember(player) then
            for prof, entry in pairs(profs) do
                for _, name in ipairs(entry.list) do
                    if query == "" or name:lower():find(query, 1, true) then
                        local key = prof .. "\0" .. name
                        local r = byKey[key]
                        if not r then
                            r = { recipe = name, prof = prof, crafters = {},
                                  itemID = entry.items and entry.items[name] }
                            byKey[key] = r
                            out[#out + 1] = r
                        end
                        r.crafters[#r.crafters + 1] = player
                    end
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
    if GH:IsIgnoredProfession(prof) then return end -- e.g. sent by someone on an older version
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

    local list, items = {}, {}
    for i = 1, total do
        for entry in (buf.parts[i] or ""):gmatch("[^;]+") do
            local name, id = entry:match("^(.*)@(%d+)$")
            if name then
                list[#list + 1] = name
                items[name] = tonumber(id)
            else
                list[#list + 1] = entry
            end
        end
    end
    GH.recvBuf[key] = nil
    GH.db.recipes[player] = GH.db.recipes[player] or {}
    GH.db.recipes[player][prof] = { ts = ts, list = list, items = items }
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
