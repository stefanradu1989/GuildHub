local _, GH = ...

-- Shared UI building blocks: text prompts, yes/no confirmation, a pick-one menu and a standard button.

local function makeAsk(name, maxLetters)
    StaticPopupDialogs[name] = {
        text = "%s",
        button1 = ACCEPT,
        button2 = CANCEL,
        hasEditBox = true,
        maxLetters = maxLetters,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        -- The callback runs on the next frame: if it opens another prompt, that prompt would otherwise
        -- be closed right after this handler returns.
        EditBoxOnEnterPressed = function(self)
            local p = self:GetParent()
            local cb, text = p.data, self:GetText()
            p:Hide()
            C_Timer.After(0, function() cb(text) end)
        end,
        OnAccept = function(self, cb)
            local box = self.editBox or self.EditBox
            local text = box:GetText()
            C_Timer.After(0, function() cb(text) end)
        end,
    }
end
makeAsk("GUILDHUB_ASK", 60)
makeAsk("GUILDHUB_ASK_LONG", 150)

StaticPopupDialogs["GUILDHUB_CONFIRM"] = {
    text = "%s",
    button1 = YES,
    button2 = NO,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    OnAccept = function(self, fn) fn() end,
}

-- Asks for a line of text (up to 60 characters, or 150 with `long`) and calls cb(text).
function GH.Ask(prompt, cb, long)
    StaticPopup_Show(long and "GUILDHUB_ASK_LONG" or "GUILDHUB_ASK", prompt, nil, cb)
end

function GH.Confirm(prompt, fn)
    StaticPopup_Show("GUILDHUB_CONFIRM", prompt, nil, fn)
end

function GH.NewButton(parent, label, width, key, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 22)
    b:SetText(label)
    b.key = key
    b:SetScript("OnClick", onClick)
    return b
end

-- A pick-one menu. choices = { { label = "Raid", value = "raid" }, ... }; onPick(value) runs on the next frame.
-- With `anchor` the menu opens under that frame (as wide as it); otherwise at the cursor.
-- `current` is marked with ">".
local choiceMenu

function GH.ShowChoice(choices, onPick, anchor, current)
    if not choiceMenu then
        local catcher = CreateFrame("Button", nil, UIParent)
        catcher:SetAllPoints(UIParent)
        catcher:SetFrameStrata("FULLSCREEN")
        catcher:Hide()
        catcher:SetScript("OnClick", function(self) self:Hide(); choiceMenu:Hide() end)

        choiceMenu = CreateFrame("Frame", nil, UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
        choiceMenu:SetFrameStrata("FULLSCREEN_DIALOG")
        choiceMenu:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
                                 edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                                 edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
        choiceMenu:SetBackdropColor(0, 0, 0, 0.95)
        choiceMenu.catcher = catcher
        choiceMenu.buttons = {}
        choiceMenu:SetScript("OnHide", function(self) self.catcher:Hide() end)
    end
    local width = anchor and math.max(anchor:GetWidth(), 120) or 190
    choiceMenu:SetSize(width, #choices * 22 + 12)
    for i, c in ipairs(choices) do
        local btn = choiceMenu.buttons[i]
        if not btn then
            btn = CreateFrame("Button", nil, choiceMenu)
            btn:SetHeight(22)
            btn:SetPoint("TOPLEFT", 6, -6 - (i - 1) * 22)
            btn:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
            btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            btn.text:SetPoint("LEFT", 6, 0)
            choiceMenu.buttons[i] = btn
        end
        btn:SetWidth(width - 12)
        btn.text:SetText((current ~= nil and c.value == current and "|cffffd100>|r " or "") .. c.label)
        btn:SetScript("OnClick", function()
            choiceMenu:Hide()
            C_Timer.After(0, function() onPick(c.value) end)
        end)
        btn:Show()
    end
    for i = #choices + 1, #choiceMenu.buttons do choiceMenu.buttons[i]:Hide() end
    choiceMenu:ClearAllPoints()
    if anchor then
        choiceMenu:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
    else
        local x, y = GetCursorPosition()
        local scale = UIParent:GetEffectiveScale()
        choiceMenu:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / scale, y / scale)
    end
    choiceMenu.catcher:Show()
    choiceMenu:Show()
end
