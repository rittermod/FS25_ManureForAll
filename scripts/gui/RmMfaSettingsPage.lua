--[[
    RmMfaSettingsPage.lua

    Game settings page row: a cloned section header plus one button row in gameSettingsLayout
    that opens RmPenSelectorDialog. The button is disabled without master rights; the click
    re-checks them. Clones are built at source time, once per map load.

    Author: Ritter
]]

RmMfaSettingsPage = RmMfaSettingsPage or {}

local Log = RmLogging.getLogger("ManureForAll")
local modDirectory = g_currentModDirectory
local modName = g_currentModName

---Text of a mod or base l10n key.
---@param key string
---@return string
local function text(key)
    return g_i18n:getText(key, modName)
end

---Find the clone templates in the settings layout.
---@param layout table gameSettingsLayout
---@return table|nil header section header Text
---@return table|nil buttonRow Bitmap row whose first child is a Button
---@return table|nil tooltip Text nested in a MultiTextOption row's option
function RmMfaSettingsPage.findTemplates(layout)
    local header, buttonRow, tooltip = nil, nil, nil
    for _, element in ipairs(layout.elements) do
        if element.name == "sectionHeader" and header == nil then
            header = element
        end
        local first = element.elements ~= nil and element.elements[1] or nil
        if element.typeName == "Bitmap" and first ~= nil then
            if first.typeName == "Button" and buttonRow == nil then
                buttonRow = element
            elseif first.typeName == "MultiTextOption" and tooltip == nil and first.elements[1] ~= nil
                and first.elements[1].typeName == "Text" then
                tooltip = first.elements[1]
            end
        end
    end
    Log:trace("RmMfaSettingsPage.findTemplates: header=%s buttonRow=%s tooltip=%s", tostring(header ~= nil),
        tostring(buttonRow ~= nil), tostring(tooltip ~= nil))
    return header, buttonRow, tooltip
end

---Grey the button out without master rights.
---@param page table InGameMenuSettingsFrame
function RmMfaSettingsPage.refreshDisabled(page)
    local button = page ~= nil and page.rmMfaPensButton or nil
    if button == nil then
        return
    end
    button:setDisabled(not page.hasMasterRights)
    Log:trace("RmMfaSettingsPage.refreshDisabled: disabled=%s", tostring(not page.hasMasterRights))
end

---Button click: re-check rights (the disabled state can be stale), then open the dialog.
---@param _target table|nil the clone's target, passed first by the button
function RmMfaSettingsPage.onClickOpen(_target)
    if not RmPenSwitch.localHasMasterRights() then
        Log:warning("RmMfaSettingsPage: pen dialog refused - no master rights")
        return
    end
    Log:debug("RmMfaSettingsPage: opening the pen dialog")
    RmPenSelectorDialog.show()
end

---Clone the header and the button row into the layout; fail closed on a template mismatch.
---@param page table InGameMenuSettingsFrame
---@param layout table gameSettingsLayout
---@return boolean built
local function buildRows(page, layout)
    local headerTemplate, rowTemplate, tooltipTemplate = RmMfaSettingsPage.findTemplates(layout)
    if headerTemplate == nil or rowTemplate == nil then
        Log:warning("RmMfaSettingsPage: settings templates missing (header=%s buttonRow=%s) - no settings button",
            tostring(headerTemplate ~= nil), tostring(rowTemplate ~= nil))
        return false
    end
    local header = headerTemplate:clone(layout)
    header:setText(text("rm_mfa_settings_section"))
    -- The template is the Pause Game row, the page's open focus: register the clone only after
    -- its button drops that flag, or it takes the page's open-focus slot.
    local row = rowTemplate:clone(layout, false, false, true)
    local buttons, label = {}, nil
    for _, element in ipairs(row.elements) do
        if element.typeName == "Button" then
            buttons[#buttons + 1] = element
        elseif element.typeName == "Text" then
            label = element
        end
    end
    if #buttons ~= 1 or label == nil then
        row:delete()
        header:delete()
        Log:warning("RmMfaSettingsPage: self-check failed (buttons=%s label=%s) - clones removed",
            tostring(#buttons), tostring(label ~= nil))
        return false
    end
    local button = buttons[1]
    label:setText(text("rm_mfa_settings_pens"))
    button:applyProfile("rmMfa_settingsButton")
    button:setText(text("rm_mfa_pens_title"))
    button.isAlwaysFocusedOnOpen = false
    button.focused = false
    button.onClickCallback = RmMfaSettingsPage.onClickOpen
    if tooltipTemplate ~= nil then
        local tooltip = tooltipTemplate:clone(button, false, false, true)
        tooltip:setText(text("rm_mfa_settings_pens_tooltip"))
    else
        Log:warning("RmMfaSettingsPage: no tooltip template - the settings button has no tooltip")
    end
    row:reloadFocusHandling(true)
    Log:debug("RmMfaSettingsPage: row registered for focus (button focusId=%s, open focus=%s)",
        tostring(button.focusId), tostring(button.isAlwaysFocusedOnOpen))
    page.rmMfaPensButton = button
    layout:invalidateLayout()
    return true
end

---Source-time build: profiles, then the clones under the settings frame's focus context.
function RmMfaSettingsPage.initGui()
    if g_dedicatedServer ~= nil then
        Log:trace("RmMfaSettingsPage.initGui: dedicated server - skipped")
        return
    end
    local page = g_inGameMenu ~= nil and g_inGameMenu.pageSettings or nil
    local layout = page ~= nil and page.gameSettingsLayout or nil
    if layout == nil then
        Log:warning("RmMfaSettingsPage: settings layout not available - no settings button")
        return
    end
    g_gui:loadProfiles(modDirectory .. "gui/guiProfiles.xml")
    local previousGui = FocusManager.currentGui
    if page.name ~= nil then
        FocusManager:setGui(page.name)
    end
    local ok, result = pcall(buildRows, page, layout)
    if page.name ~= nil then
        FocusManager:setGui(previousGui)
    end
    if not ok then
        Log:warning("RmMfaSettingsPage: building the settings button raised: %s", tostring(result))
        return
    end
    Log:debug("RmMfaSettingsPage.initGui: built=%s focusGui=%s restored=%s", tostring(result),
        tostring(page.name), tostring(previousGui))
end

---InGameMenuSettingsFrame.updateGameSettings append: refresh on page open.
---@param page table
local function onUpdateGameSettings(page)
    RmMfaSettingsPage.refreshDisabled(page)
end

---InGameMenuSettingsFrame.setHasMasterRights append: refresh on a rights change.
---@param page table
local function onSetHasMasterRights(page)
    RmMfaSettingsPage.refreshDisabled(page)
end

if not RmMfaSettingsPage.hooksInstalled then
    RmMfaSettingsPage.hooksInstalled = true
    InGameMenuSettingsFrame.updateGameSettings = Utils.appendedFunction(
        InGameMenuSettingsFrame.updateGameSettings, onUpdateGameSettings)
    InGameMenuSettingsFrame.setHasMasterRights = Utils.appendedFunction(
        InGameMenuSettingsFrame.setHasMasterRights, onSetHasMasterRights)
end

RmMfaSettingsPage.initGui()
