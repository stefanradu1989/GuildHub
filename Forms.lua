local _, GH = ...

-- A small form window with a few text fields and pick-one buttons, used for new events, requests and announcements.
--
-- GH:ShowForm({
--     title = "New Event",
--     fields = { { key = "title", label = "Title", max = 60, required = true }, ... },   -- up to 5
--     choices = { { key = "kind", label = "Type", options = { { label = "Raid", value = "raid" }, ... },
--                  default = "raid" }, ... },                                              -- up to 2
--     submitText = "Create",
--     onSubmit = function(values) ... end,    -- values.<key> = trimmed text or the chosen value
-- })

local MAX_FIELDS, MAX_CHOICES = 5, 2
local form

local function labelFor(options, value)
    for _, o in ipairs(options) do
        if o.value == value then return o.label end
    end
    return "?"
end

local function updateChoiceText(btn)
    btn:SetText(btn.choice.label .. ": " .. labelFor(btn.choice.options, form.values[btn.choice.key]))
end

local function submit()
    local spec = form.spec
    local values = {}
    for i, f in ipairs(spec.fields or {}) do
        local text = strtrim(form.boxes[i]:GetText())
        if f.required and text == "" then
            GH:Print(f.label:gsub(" %-.*$", "") .. " is required.")
            return
        end
        values[f.key] = text
    end
    for k, v in pairs(form.values) do values[k] = v end
    form:Hide()
    spec.onSubmit(values)
end

local function build()
    form = CreateFrame("Frame", "GuildHubForm", UIParent, "BasicFrameTemplateWithInset")
    form:SetFrameStrata("DIALOG")
    form:SetWidth(500)
    form:SetPoint("CENTER")
    form:SetMovable(true)
    form:EnableMouse(true)
    form:RegisterForDrag("LeftButton")
    form:SetScript("OnDragStart", form.StartMoving)
    form:SetScript("OnDragStop", form.StopMovingOrSizing)
    form:Hide()
    tinsert(UISpecialFrames, "GuildHubForm")

    form.title = form:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    form.title:SetPoint("TOP", 0, -5)

    form.values = {}
    form.labels, form.boxes, form.choiceButtons = {}, {}, {}

    for i = 1, MAX_FIELDS do
        local label = form:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetJustifyH("LEFT")
        label:SetWidth(440)
        label:SetWordWrap(false)
        form.labels[i] = label

        local box = CreateFrame("EditBox", nil, form, "InputBoxTemplate")
        box:SetSize(440, 20)
        box:SetAutoFocus(false)
        box:SetScript("OnEscapePressed", box.ClearFocus)
        box:SetScript("OnEnterPressed", box.ClearFocus)
        box:SetScript("OnTabPressed", function()
            local nextBox = form.boxes[i + 1]
            if not (nextBox and nextBox:IsShown()) then nextBox = form.boxes[1] end
            nextBox:SetFocus()
        end)
        form.boxes[i] = box
    end

    for i = 1, MAX_CHOICES do
        local btn = GH.NewButton(form, "", 230, nil, function(self)
            local c = self.choice
            GH.ShowChoice(c.options, function(v)
                form.values[c.key] = v
                updateChoiceText(self)
            end, self, form.values[c.key])
        end)
        form.choiceButtons[i] = btn
    end

    form.submit = GH.NewButton(form, "Create", 110, nil, submit)
    form.cancel = GH.NewButton(form, "Cancel", 110, nil, function() form:Hide() end)
end

function GH:ShowForm(spec)
    if not form then build() end
    form.spec = spec
    form.title:SetText(spec.title)
    wipe(form.values)

    local y = -34
    for i = 1, MAX_FIELDS do
        local f = spec.fields and spec.fields[i]
        local label, box = form.labels[i], form.boxes[i]
        if f then
            label:ClearAllPoints()
            label:SetPoint("TOPLEFT", 24, y)
            label:SetText(f.label .. (f.required and " *" or ""))
            box:ClearAllPoints()
            box:SetPoint("TOPLEFT", 28, y - 14)
            box:SetMaxLetters(f.max or 60)
            box:SetText(f.default or "")
            label:Show()
            box:Show()
            y = y - 46
        else
            label:Hide()
            box:Hide()
        end
    end

    for i = 1, MAX_CHOICES do
        local c = spec.choices and spec.choices[i]
        local btn = form.choiceButtons[i]
        if c then
            btn.choice = c
            form.values[c.key] = c.default
            updateChoiceText(btn)
            btn:ClearAllPoints()
            btn:SetPoint("TOPLEFT", 24 + (i - 1) * 236, y)
            btn:Show()
        else
            btn:Hide()
        end
    end
    if spec.choices and #spec.choices > 0 then y = y - 34 end

    form.submit:SetText(spec.submitText or "OK")
    form.submit:ClearAllPoints()
    form.submit:SetPoint("TOPRIGHT", form, "TOPRIGHT", -140, y - 6)
    form.cancel:ClearAllPoints()
    form.cancel:SetPoint("LEFT", form.submit, "RIGHT", 8, 0)
    form:SetHeight(-y + 40)
    form:Show()
    if spec.fields and form.boxes[1]:IsShown() then form.boxes[1]:SetFocus() end
end
