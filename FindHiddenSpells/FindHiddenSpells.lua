-- FindHiddenSpells: Discover usable spells not in your spellbook
-- TOC Version: 110205 (Patch 11.2.5)
-- Uses modern C_SpellBook and C_ClassTalents APIs

local ADDON_NAME = "FindHiddenSpells"
local db = {}
local scanInProgress = false
local currentBatch = 0
local knownSpells = {}  -- Set of all spells the player "knows"

-- Saved variables
FindHiddenSpellsDB = FindHiddenSpellsDB or {
    scannedSpells = {},
    lastScan = nil,
    settings = {
        minSpellID = 1,
        maxSpellID = 500000,
        batchSize = 500,
        batchDelay = 0.05,
        includePassive = false,
        debugMode = false,
    }
}

-- Utility Functions
local function DebugPrint(msg)
    if db.settings.debugMode then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFF00FF[FHS Debug]|r " .. msg)
    end
end

local function AddMessage(msg, color)
    color = color or {r=1, g=1, b=1}
    DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[FindHiddenSpells]|r " .. msg, color.r, color.g, color.b)
end

local function FormatSpellResult(spellID, spellInfo)
    local iconStr = "|T" .. spellInfo.iconID .. ":20|t"
    local link = C_Spell.GetSpellLink(spellID) or ("[" .. spellInfo.name .. "]")
    local isPassive = C_Spell.IsSpellPassive(spellID) and " |cFFFFFF00[Passive]|r" or ""
    return string.format("%s %d - %s%s", iconStr, spellID, link, isPassive)
end

-- Build Known Spells Set
local function BuildKnownSpellsSet()
    knownSpells = {}
    local count = 0
    
    DebugPrint("Building known spells set...")
    
    -- 1. Iterate Spellbook using proper skill-line iteration
    for i = 1, C_SpellBook.GetNumSpellBookSkillLines() do
        local skillLineInfo = C_SpellBook.GetSpellBookSkillLineInfo(i)
        if skillLineInfo then
            DebugPrint(string.format("Scanning skill line: %s (offset=%d, num=%d)", 
                skillLineInfo.name or "Unknown", 
                skillLineInfo.itemIndexOffset or 0, 
                skillLineInfo.numSpellBookItems or 0))
            
            -- Iterate spells in this skill line
            for j = skillLineInfo.itemIndexOffset + 1, skillLineInfo.itemIndexOffset + skillLineInfo.numSpellBookItems do
                local spellBookItemInfo = C_SpellBook.GetSpellBookItemInfo(j, Enum.SpellBookSpellBank.Player)
                
                if spellBookItemInfo and spellBookItemInfo.spellID then
                    knownSpells[spellBookItemInfo.spellID] = true
                    count = count + 1
                    
                    -- If it's a flyout, get sub-spells
                    if spellBookItemInfo.itemType == Enum.SpellBookItemType.Flyout then
                        local _, _, numSlots = GetFlyoutInfo(spellBookItemInfo.actionID)
                        if numSlots then
                            for k = 1, numSlots do
                                local flyoutSpellID = GetFlyoutSlotInfo(spellBookItemInfo.actionID, k)
                                if flyoutSpellID then
                                    knownSpells[flyoutSpellID] = true
                                    count = count + 1
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    
    DebugPrint(string.format("Found %d spellbook spells", count))
    
    -- 2. Get Active Talents via C_ClassTalents
    local configID = C_ClassTalents.GetActiveConfigID()
    if configID then
        local configInfo = C_Traits.GetConfigInfo(configID)
        if configInfo and configInfo.treeIDs then
            for _, treeID in ipairs(configInfo.treeIDs) do
                local nodes = C_Traits.GetTreeNodes(treeID)
                if nodes then
                    for _, nodeID in ipairs(nodes) do
                        local nodeInfo = C_Traits.GetNodeInfo(configID, nodeID)
                        if nodeInfo and nodeInfo.currentRank and nodeInfo.currentRank > 0 then
                            -- Node is active, get entries
                            if nodeInfo.entryIDs then
                                for _, entryID in ipairs(nodeInfo.entryIDs) do
                                    local entryInfo = C_Traits.GetEntryInfo(configID, entryID)
                                    if entryInfo and entryInfo.definitionID then
                                        local definitionInfo = C_Traits.GetDefinitionInfo(entryInfo.definitionID)
                                        if definitionInfo and definitionInfo.spellID then
                                            knownSpells[definitionInfo.spellID] = true
                                            count = count + 1
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
            DebugPrint(string.format("Added talent spells, total now: %d", count))
        end
    end
    
    -- 3. Get PvP Talents
    local pvpTalentIDs = C_SpecializationInfo.GetAllSelectedPvpTalentIDs()
    if pvpTalentIDs then
        for _, pvpTalentID in ipairs(pvpTalentIDs) do
            local _, _, _, _, _, spellID = GetPvpTalentInfoByID(pvpTalentID)
            if spellID then
                knownSpells[spellID] = true
                count = count + 1
            end
        end
        DebugPrint(string.format("Added PvP talents, total now: %d", count))
    end
    
    -- 4. Get Pet Spells
    local hasPetSpells, petToken = C_SpellBook.HasPetSpells()
    if hasPetSpells then
        for i = 1, C_SpellBook.GetNumSpellBookSkillLines() do
            local skillLineInfo = C_SpellBook.GetSpellBookSkillLineInfo(i)
            if skillLineInfo and skillLineInfo.shouldHide == false then
                for j = skillLineInfo.itemIndexOffset + 1, skillLineInfo.itemIndexOffset + skillLineInfo.numSpellBookItems do
                    local petSpellInfo = C_SpellBook.GetSpellBookItemInfo(j, Enum.SpellBookSpellBank.Pet)
                    if petSpellInfo and petSpellInfo.spellID then
                        knownSpells[petSpellInfo.spellID] = true
                        count = count + 1
                    end
                end
            end
        end
        DebugPrint(string.format("Added pet spells, total now: %d", count))
    end
    
    AddMessage(string.format("Built known spells set: %d spells", count), {r=0, g=1, b=1})
    return count
end

-- Spell Detection Logic
local function IsSpellRelevant(spellID, spellInfo)
    if not spellInfo or not spellInfo.name then
        return false
    end

    -- Filter passive spells if disabled
    if not db.settings.includePassive and C_Spell.IsSpellPassive(spellID) then
        return false
    end

    -- Check if already known
    if knownSpells[spellID] then
        return false
    end

    -- Check if usable (this is the key check)
    local isUsable = C_Spell.IsSpellUsable(spellID)
    if not isUsable then
        return false
    end

    -- Additional validation: spell must be pickupable
    C_Spell.PickupSpell(spellID)
    local hasSpell = CursorHasSpell()
    if hasSpell then
        ClearCursor()
        return true
    end

    return false
end

-- Main Scanning Function
local function ScanSpellBatch(startID, endID, callback)
    local results = {}
    local scanned = 0
    
    for i = startID, endID do
        local spellInfo = C_Spell.GetSpellInfo(i)
        
        if IsSpellRelevant(i, spellInfo) then
            table.insert(results, {
                id = i,
                name = spellInfo.name,
                icon = spellInfo.iconID,
                info = spellInfo
            })
        end
        
        scanned = scanned + 1
    end
    
    if callback then
        callback(results, scanned)
    end
    
    return results
end

local function StartScan()
    if scanInProgress then
        AddMessage("Scan already in progress!", {r=1, g=0.5, b=0})
        return
    end

    -- Rebuild known spells set first
    AddMessage("Analyzing your character's known spells...", {r=0, g=1, b=1})
    local knownCount = BuildKnownSpellsSet()
    
    if knownCount == 0 then
        AddMessage("Warning: Could not build known spells set. Results may include false positives.", {r=1, g=0.5, b=0})
    end

    scanInProgress = true
    currentBatch = 0
    db.scannedSpells = {}
    
    local minID = db.settings.minSpellID
    local maxID = db.settings.maxSpellID
    local batchSize = db.settings.batchSize
    local batchDelay = db.settings.batchDelay
    
    AddMessage(string.format("Starting scan from %d to %d...", minID, maxID), {r=0, g=1, b=1})
    
    local function ScanNextBatch()
        local startID = minID + (currentBatch * batchSize)
        local endID = math.min(startID + batchSize - 1, maxID)
        
        if startID > maxID then
            -- Scan complete
            scanInProgress = false
            db.lastScan = time()
            AddMessage(string.format("Scan complete! Found %d hidden spells.", #db.scannedSpells), {r=0, g=1, b=0})
            
            if FindHiddenSpellsUI then
                FindHiddenSpellsUI:UpdateResults()
            end
            return
        end
        
        local results = ScanSpellBatch(startID, endID, function(batchResults, scannedCount)
            for _, spell in ipairs(batchResults) do
                table.insert(db.scannedSpells, spell)
            end
            
            currentBatch = currentBatch + 1
            local progress = math.floor((startID - minID) / (maxID - minID) * 100)
            
            if FindHiddenSpellsUI and FindHiddenSpellsUI.UpdateProgress then
                FindHiddenSpellsUI:UpdateProgress(progress, #db.scannedSpells)
            end
        end)
        
        C_Timer.After(batchDelay, ScanNextBatch)
    end
    
    ScanNextBatch()
end

local function StopScan()
    scanInProgress = false
    AddMessage("Scan stopped.", {r=1, g=1, b=0})
end

local function ExportResults()
    if #db.scannedSpells == 0 then
        AddMessage("No results to export. Run a scan first.", {r=1, g=0, b=0})
        return
    end
    
    local exportText = "-- Hidden Spells Export\n"
    exportText = exportText .. string.format("-- Generated: %s\n", date("%Y-%m-%d %H:%M:%S", db.lastScan))
    exportText = exportText .. string.format("-- Total Spells: %d\n\n", #db.scannedSpells)
    
    for _, spell in ipairs(db.scannedSpells) do
        exportText = exportText .. string.format("-- %d: %s\n", spell.id, spell.name)
    end
    
    return exportText
end

-- UI Frame Creation
FindHiddenSpellsUI = CreateFrame("Frame", "FindHiddenSpellsMainFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate")
local ui = FindHiddenSpellsUI

ui:SetSize(650, 500)
ui:SetPoint("CENTER")
ui:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 8, right = 8, top = 8, bottom = 8 }
})
ui:SetMovable(true)
ui:EnableMouse(true)
ui:RegisterForDrag("LeftButton")
ui:SetScript("OnDragStart", ui.StartMoving)
ui:SetScript("OnDragStop", ui.StopMovingOrSizing)
ui:SetFrameStrata("DIALOG")
ui:Hide()

-- Title
local title = ui:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOP", 0, -15)
title:SetText("Find Hidden Spells")

-- Close Button
local closeBtn = CreateFrame("Button", nil, ui, "UIPanelCloseButton")
closeBtn:SetPoint("TOPRIGHT", -5, -5)

-- Control Panel
local controlPanel = CreateFrame("Frame", nil, ui, BackdropTemplateMixin and "BackdropTemplate")
controlPanel:SetSize(630, 100)
controlPanel:SetPoint("TOPLEFT", 10, -45)
controlPanel:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 }
})
controlPanel:SetBackdropColor(0, 0, 0, 0.5)

-- Scan Button
local scanBtn = CreateFrame("Button", nil, controlPanel, "UIPanelButtonTemplate")
scanBtn:SetSize(100, 25)
scanBtn:SetPoint("TOPLEFT", 10, -10)
scanBtn:SetText("Start Scan")
scanBtn:SetScript("OnClick", function()
    if not scanInProgress then
        StartScan()
        scanBtn:SetText("Stop Scan")
    else
        StopScan()
        scanBtn:SetText("Start Scan")
    end
end)

-- Clear Button
local clearBtn = CreateFrame("Button", nil, controlPanel, "UIPanelButtonTemplate")
clearBtn:SetSize(80, 25)
clearBtn:SetPoint("LEFT", scanBtn, "RIGHT", 5, 0)
clearBtn:SetText("Clear")
clearBtn:SetScript("OnClick", function()
    db.scannedSpells = {}
    ui:UpdateResults()
    AddMessage("Results cleared.")
end)

-- Export Button
local exportBtn = CreateFrame("Button", nil, controlPanel, "UIPanelButtonTemplate")
exportBtn:SetSize(80, 25)
exportBtn:SetPoint("LEFT", clearBtn, "RIGHT", 5, 0)
exportBtn:SetText("Export")
exportBtn:SetScript("OnClick", function()
    local exportText = ExportResults()
    if exportText then
        ui:ShowExportWindow(exportText)
    end
end)

-- Settings Button
local settingsBtn = CreateFrame("Button", nil, controlPanel, "UIPanelButtonTemplate")
settingsBtn:SetSize(80, 25)
settingsBtn:SetPoint("LEFT", exportBtn, "RIGHT", 5, 0)
settingsBtn:SetText("Settings")
settingsBtn:SetScript("OnClick", function()
    ui:ShowSettings()
end)

-- Rebuild Known Button
local rebuildBtn = CreateFrame("Button", nil, controlPanel, "UIPanelButtonTemplate")
rebuildBtn:SetSize(120, 25)
rebuildBtn:SetPoint("LEFT", settingsBtn, "RIGHT", 5, 0)
rebuildBtn:SetText("Rebuild Known")
rebuildBtn:SetScript("OnClick", function()
    BuildKnownSpellsSet()
end)

-- Progress Display
local progressText = controlPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
progressText:SetPoint("TOPLEFT", 10, -40)
progressText:SetText("Ready to scan")

local resultsText = controlPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
resultsText:SetPoint("TOPLEFT", 10, -55)
resultsText:SetText("Results: 0 spells found")

local knownText = controlPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
knownText:SetPoint("TOPLEFT", 10, -70)
knownText:SetText("Known spells: Not built yet")

-- Results ScrollFrame
local scrollFrame = CreateFrame("ScrollFrame", "FindHiddenSpellsScrollFrame", ui, "UIPanelScrollFrameTemplate")
scrollFrame:SetPoint("TOPLEFT", controlPanel, "BOTTOMLEFT", 5, -10)
scrollFrame:SetPoint("BOTTOMRIGHT", ui, "BOTTOMRIGHT", -30, 10)

local scrollChild = CreateFrame("Frame", nil, scrollFrame)
scrollChild:SetSize(scrollFrame:GetWidth(), 1)
scrollFrame:SetScrollChild(scrollChild)

local resultsEditBox = CreateFrame("EditBox", nil, scrollChild)
resultsEditBox:SetPoint("TOPLEFT")
resultsEditBox:SetWidth(scrollChild:GetWidth() - 10)
resultsEditBox:SetFontObject("GameFontHighlightSmall")
resultsEditBox:SetAutoFocus(false)
resultsEditBox:SetMultiLine(true)
resultsEditBox:SetMaxLetters(0)
resultsEditBox:SetHyperlinksEnabled(true)
resultsEditBox:SetScript("OnHyperlinkClick", function(self, linkData, link, button)
    SetItemRef(linkData, link, button)
end)

-- Update Functions
function ui:UpdateProgress(percent, count)
    progressText:SetText(string.format("Progress: %d%% (%d spells found)", percent, count))
    resultsText:SetText(string.format("Results: %d spells found", count))
end

function ui:UpdateResults()
    local text = ""
    
    if #db.scannedSpells == 0 then
        text = "No hidden spells found.\n\nClick 'Start Scan' to begin searching.\n\nThe addon will first analyze your known spells (spellbook, talents, PvP talents, pet spells), then scan for spells that are usable but not in that set."
    else
        text = string.format("Found %d hidden usable spells:\n\n", #db.scannedSpells)
        
        for _, spell in ipairs(db.scannedSpells) do
            text = text .. FormatSpellResult(spell.id, spell.info) .. "\n"
        end
    end
    
    resultsEditBox:SetText(text)
    
    local fontHeight = 12
    local numLines = #db.scannedSpells + 5
    scrollChild:SetHeight(math.max(numLines * fontHeight, scrollFrame:GetHeight()))
    
    resultsText:SetText(string.format("Results: %d spells found", #db.scannedSpells))
    
    local knownCount = 0
    for _ in pairs(knownSpells) do knownCount = knownCount + 1 end
    knownText:SetText(string.format("Known spells: %d tracked", knownCount))
end

-- Export Window (same as before)
function ui:ShowExportWindow(text)
    if not ui.exportFrame then
        local export = CreateFrame("Frame", "FindHiddenSpellsExportFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate")
        export:SetSize(500, 400)
        export:SetPoint("CENTER")
        export:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 8, right = 8, top = 8, bottom = 8 }
        })
        export:SetFrameStrata("FULLSCREEN_DIALOG")
        export:SetMovable(true)
        export:EnableMouse(true)
        export:RegisterForDrag("LeftButton")
        export:SetScript("OnDragStart", export.StartMoving)
        export:SetScript("OnDragStop", export.StopMovingOrSizing)
        
        local exportTitle = export:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        exportTitle:SetPoint("TOP", 0, -15)
        exportTitle:SetText("Export Results")
        
        local exportClose = CreateFrame("Button", nil, export, "UIPanelCloseButton")
        exportClose:SetPoint("TOPRIGHT", -5, -5)
        
        local exportScroll = CreateFrame("ScrollFrame", nil, export, "UIPanelScrollFrameTemplate")
        exportScroll:SetPoint("TOPLEFT", 15, -40)
        exportScroll:SetPoint("BOTTOMRIGHT", -30, 40)
        
        local exportChild = CreateFrame("Frame", nil, exportScroll)
        exportChild:SetSize(exportScroll:GetWidth(), 1)
        exportScroll:SetScrollChild(exportChild)
        
        local exportBox = CreateFrame("EditBox", nil, exportChild)
        exportBox:SetPoint("TOPLEFT")
        exportBox:SetWidth(exportChild:GetWidth())
        exportBox:SetFontObject("GameFontHighlightSmall")
        exportBox:SetAutoFocus(false)
        exportBox:SetMultiLine(true)
        exportBox:SetMaxLetters(0)
        
        export.editBox = exportBox
        export.scrollChild = exportChild
        ui.exportFrame = export
    end
    
    ui.exportFrame.editBox:SetText(text)
    ui.exportFrame.editBox:HighlightText()
    ui.exportFrame.editBox:SetFocus()
    
    local fontHeight = 12
    local numLines = select(2, text:gsub("\n", "\n")) + 1
    ui.exportFrame.scrollChild:SetHeight(math.max(numLines * fontHeight, ui.exportFrame:GetHeight()))
    
    ui.exportFrame:Show()
end

-- Settings Window
function ui:ShowSettings()
    if not ui.settingsFrame then
        local settings = CreateFrame("Frame", "FindHiddenSpellsSettingsFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate")
        settings:SetSize(400, 350)
        settings:SetPoint("CENTER")
        settings:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 8, right = 8, top = 8, bottom = 8 }
        })
        settings:SetFrameStrata("FULLSCREEN_DIALOG")
        settings:SetMovable(true)
        settings:EnableMouse(true)
        settings:RegisterForDrag("LeftButton")
        settings:SetScript("OnDragStart", settings.StartMoving)
        settings:SetScript("OnDragStop", settings.StopMovingOrSizing)
        
        local settingsTitle = settings:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        settingsTitle:SetPoint("TOP", 0, -15)
        settingsTitle:SetText("Scan Settings")
        
        local settingsClose = CreateFrame("Button", nil, settings, "UIPanelCloseButton")
        settingsClose:SetPoint("TOPRIGHT", -5, -5)
        
        -- Min Spell ID
        local minLabel = settings:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        minLabel:SetPoint("TOPLEFT", 20, -50)
        minLabel:SetText("Minimum Spell ID:")
        
        local minEdit = CreateFrame("EditBox", nil, settings, "InputBoxTemplate")
        minEdit:SetSize(100, 25)
        minEdit:SetPoint("LEFT", minLabel, "RIGHT", 10, 0)
        minEdit:SetAutoFocus(false)
        minEdit:SetText(tostring(db.settings.minSpellID))
        
        -- Max Spell ID
        local maxLabel = settings:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        maxLabel:SetPoint("TOPLEFT", minLabel, "BOTTOMLEFT", 0, -20)
        maxLabel:SetText("Maximum Spell ID:")
        
        local maxEdit = CreateFrame("EditBox", nil, settings, "InputBoxTemplate")
        maxEdit:SetSize(100, 25)
        maxEdit:SetPoint("LEFT", maxLabel, "RIGHT", 10, 0)
        maxEdit:SetAutoFocus(false)
        maxEdit:SetText(tostring(db.settings.maxSpellID))
        
        -- Batch Size
        local batchLabel = settings:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        batchLabel:SetPoint("TOPLEFT", maxLabel, "BOTTOMLEFT", 0, -20)
        batchLabel:SetText("Batch Size:")
        
        local batchEdit = CreateFrame("EditBox", nil, settings, "InputBoxTemplate")
        batchEdit:SetSize(100, 25)
        batchEdit:SetPoint("LEFT", batchLabel, "RIGHT", 10, 0)
        batchEdit:SetAutoFocus(false)
        batchEdit:SetText(tostring(db.settings.batchSize))
        
        -- Include Passive
        local passiveCheck = CreateFrame("CheckButton", nil, settings, "UICheckButtonTemplate")
        passiveCheck:SetPoint("TOPLEFT", batchLabel, "BOTTOMLEFT", 0, -20)
        passiveCheck:SetChecked(db.settings.includePassive)
        
        local passiveLabel = settings:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        passiveLabel:SetPoint("LEFT", passiveCheck, "RIGHT", 5, 0)
        passiveLabel:SetText("Include Passive Spells")
        
        -- Debug Mode
        local debugCheck = CreateFrame("CheckButton", nil, settings, "UICheckButtonTemplate")
        debugCheck:SetPoint("TOPLEFT", passiveCheck, "BOTTOMLEFT", 0, -10)
        debugCheck:SetChecked(db.settings.debugMode)
        
        local debugLabel = settings:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        debugLabel:SetPoint("LEFT", debugCheck, "RIGHT", 5, 0)
        debugLabel:SetText("Debug Mode (verbose output)")
        
        -- Save Button
        local saveBtn = CreateFrame("Button", nil, settings, "UIPanelButtonTemplate")
        saveBtn:SetSize(100, 25)
        saveBtn:SetPoint("BOTTOM", 0, 15)
        saveBtn:SetText("Save")
        saveBtn:SetScript("OnClick", function()
            db.settings.minSpellID = tonumber(minEdit:GetText()) or 1
            db.settings.maxSpellID = tonumber(maxEdit:GetText()) or 500000
            db.settings.batchSize = tonumber(batchEdit:GetText()) or 500
            db.settings.includePassive = passiveCheck:GetChecked()
            db.settings.debugMode = debugCheck:GetChecked()
            AddMessage("Settings saved!")
            settings:Hide()
        end)
        
        ui.settingsFrame = settings
    end
    
    ui.settingsFrame:Show()
end

-- Slash Commands
SLASH_FINDHIDDENSPELLS1 = "/fhs"
SLASH_FINDHIDDENSPELLS2 = "/findhiddenspells"
SlashCmdList["FINDHIDDENSPELLS"] = function(msg)
    msg = msg:lower()
    
    if msg == "scan" then
        StartScan()
    elseif msg == "stop" then
        StopScan()
    elseif msg == "show" or msg == "" then
        ui:Show()
        ui:UpdateResults()
    elseif msg == "hide" then
        ui:Hide()
    elseif msg == "clear" then
        db.scannedSpells = {}
        AddMessage("Results cleared.")
    elseif msg == "rebuild" then
        BuildKnownSpellsSet()
    elseif msg == "debug" then
        db.settings.debugMode = not db.settings.debugMode
        AddMessage(string.format("Debug mode: %s", db.settings.debugMode and "ON" or "OFF"))
    else
        AddMessage("Commands: /fhs [scan|stop|show|hide|clear|rebuild|debug]")
    end
end

-- Event Handling
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_TALENT_UPDATE")
eventFrame:RegisterEvent("SPELLS_CHANGED")
eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local addonName = ...
        if addonName == ADDON_NAME then
            db = FindHiddenSpellsDB
            AddMessage("Loaded! Type /fhs to open the interface.")
            -- Initialize UI after db is loaded
            if FindHiddenSpellsUI and FindHiddenSpellsUI.UpdateResults then
                FindHiddenSpellsUI:UpdateResults()
            end
        end
    elseif event == "PLAYER_LOGIN" then
        C_Timer.After(2, function()
            if #db.scannedSpells > 0 then
                AddMessage(string.format("Last scan found %d hidden spells. Type /fhs to view.", #db.scannedSpells))
            end
        end)
    elseif event == "PLAYER_TALENT_UPDATE" or event == "SPELLS_CHANGED" then
        -- Invalidate known spells cache when talents/spells change
        if not scanInProgress then
            DebugPrint("Talents or spells changed - known spell set invalidated")
        end
    end
end)