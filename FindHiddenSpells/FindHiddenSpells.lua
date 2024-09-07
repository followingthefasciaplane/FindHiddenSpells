local optionsFrame = CreateFrame("Frame", "FindHiddenSpellsOptionsFrame", InterfaceOptionsFramePanelContainer)
optionsFrame.name = "Find Hidden Spells"

local optionsTitle = optionsFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
optionsTitle:SetPoint("TOPLEFT", 16, -16)
optionsTitle:SetText("Find Hidden Spells")

local optionsDesc = optionsFrame:CreateFontString(nil, "ARTWORK", "GameFontHighlightMedium")
optionsDesc:SetPoint("TOPLEFT", optionsTitle, "BOTTOMLEFT", 0, -8)
optionsDesc:SetWidth(450)
optionsDesc:SetJustifyH("LEFT")
optionsDesc:SetJustifyV("TOP")
optionsDesc:SetText("This addon will scan every spellID in the game by trying to pick them up with your cursor. It will then check if the spell is usable or not, and print out a list of spellIDs and spell names that the WoW API considers usable.")

local optionsWarning = optionsFrame:CreateFontString(nil, "ARTWORK", "GameFontHighlightMedium")
optionsWarning:SetPoint("TOPLEFT", optionsDesc, "BOTTOMLEFT", 0, -8)
optionsWarning:SetWidth(450)
optionsWarning:SetJustifyH("LEFT")
optionsWarning:SetJustifyV("TOP")
optionsWarning:SetText("|cFFFF0000Warning: This will clear out the first slot on your first action bar. This will cause lag and potentially crash the game on lower-end hardware. User discretion is advised.|r")

local scanButton = CreateFrame("Button", "FindHiddenSpellsScanButton", optionsFrame, "UIPanelButtonTemplate")
scanButton:SetSize(100, 30)
scanButton:SetPoint("BOTTOMLEFT", 10, 10)
scanButton:SetText("Scan Spells")

local spellFrame = CreateFrame("Frame", "FindHiddenSpellsSpellFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate")
spellFrame:SetSize(300, 400)
spellFrame:SetPoint("CENTER")
spellFrame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\PVPFrame\\UI-Character-PVP-Highlight",
    edgeSize = 16,
    insets = { left = 8, right = 8, top = 8, bottom = 8 },
})
spellFrame:SetMovable(true)
spellFrame:EnableMouse(true)
spellFrame:RegisterForDrag("LeftButton")
spellFrame:SetScript("OnDragStart", spellFrame.StartMoving)
spellFrame:SetScript("OnDragStop", spellFrame.StopMovingOrSizing)

local spellTitle = spellFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
spellTitle:SetPoint("TOPLEFT", 16, -16)
spellTitle:SetText("Find Hidden Spells")

local spellScroll = CreateFrame("ScrollFrame", "FindHiddenSpellsSpellScroll", spellFrame, "UIPanelScrollFrameTemplate")
spellScroll:SetPoint("TOPLEFT", spellTitle, "BOTTOMLEFT", 0, -8)
spellScroll:SetPoint("BOTTOMRIGHT", -30, 10)

local spellScrollChild = CreateFrame("Frame", "FindHiddenSpellsSpellScrollChild", spellScroll)
spellScrollChild:SetSize(spellScroll:GetWidth(), spellScroll:GetHeight())
spellScroll:SetScrollChild(spellScrollChild)

local spellMsg = CreateFrame("EditBox", "FindHiddenSpellsSpellMsg", spellScrollChild)
spellMsg:SetPoint("TOPLEFT")
spellMsg:SetWidth(spellScroll:GetWidth())
spellMsg:SetFontObject("GameFontHighlight")
spellMsg:SetAutoFocus(false)
spellMsg:SetMultiLine(true)

local PostSpell = 0
local batchSize = 1000  -- Number of spellIDs to check in each batch
local function findHiddenSpells(startID, endID)
    local currentID = startID

    local function scanBatch()
        local msg = ""
        for i = currentID, math.min(currentID + batchSize - 1, endID) do
            local name, rank, icon, powerCost, isFunnel, powerType, castingTime, minRange, maxRange = C_Spell.GetSpellInfo(i)
            local usable, nomana = C_Spell.IsSpellUsable(i)
            C_Spell.PickupSpell(i)

            if CursorHasSpell() then
                if not C_Spell.IsSpellPassive(i) then
                    PlaceAction(1, 1)
                    if usable and PostSpell ~= i then
                        msg = msg .. "[" .. i .. "] - " .. (C_Spell.GetSpellLink(i) or "! [" .. name .. "]") .. "\n"
                        PostSpell = i
                    end
                    ClearCursor()
                end
            end
        end
        spellMsg:SetText(spellMsg:GetText() .. msg)

        local fontHeight = select(2, spellMsg:GetFont())
        local spacing = spellMsg:GetSpacing()
        local height = fontHeight + spacing
        spellScrollChild:SetHeight(height)

        currentID = currentID + batchSize
        if currentID <= endID then
            C_Timer.After(0.1, scanBatch)
        end
    end

    scanBatch()
end

scanButton:SetScript("OnClick", function()
    findHiddenSpells(1, 2000)
end)

local copyButton = CreateFrame("Button", "FindHiddenSpellsCopyButton", spellFrame, "UIPanelButtonTemplate")
copyButton:SetSize(100, 30)
copyButton:SetPoint("TOPRIGHT", -10, -10)
copyButton:SetText("Menu")
copyButton:SetScript("OnClick", function()
    Settings.OpenToCategory(optionsFrame.name)
end)

local category, layout = Settings.RegisterCanvasLayoutCategory(optionsFrame, optionsFrame.name, optionsFrame.name);
category.ID = optionsFrame.name;
Settings.RegisterAddOnCategory(category);

optionsFrame:RegisterEvent("ADDON_LOADED")
optionsFrame:SetScript("OnEvent", function(self, event, addon)
    if addon == "FindHiddenSpells" then
        optionsFrame:UnregisterEvent("ADDON_LOADED")
    end
end)
