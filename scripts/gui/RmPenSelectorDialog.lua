--[[
    RmPenSelectorDialog.lua

    Pen dialog: one row per animal building of an injected type, with name, animal type, owner
    farm and a checkbox (ticked = manure production on). Pens the mod could not set up are greyed
    and cannot be toggled. Selection logic lives in RmPenSelectorModel; rows come from
    RmPenSwitch.listPens.

    Author: Ritter
]]

RmPenSelectorDialog = {}
local RmPenSelectorDialog_mt = Class(RmPenSelectorDialog, MessageDialog)

local Log = RmLogging.getLogger("ManureForAll")
local modDirectory = g_currentModDirectory
local modName = g_currentModName

---Text of a mod or base l10n key.
---@param key string
---@return string
local function text(key)
    return g_i18n:getText(key, modName)
end

---Load the profiles and the dialog XML and keep the singleton (eager, once per map load).
function RmPenSelectorDialog.register()
    g_gui:loadProfiles(modDirectory .. "gui/guiProfiles.xml")
    local dialog = RmPenSelectorDialog.new()
    g_gui:loadGui(modDirectory .. "gui/RmPenSelectorDialog.xml", "RmPenSelectorDialog", dialog)
    RmPenSelectorDialog.INSTANCE = dialog
    Log:debug("RmPenSelectorDialog registered")
end

---Field-only constructor: it runs on every map load, so it reads nothing live.
---@param target table|nil
---@param customMt table|nil
---@return table self
function RmPenSelectorDialog.new(target, customMt)
    local self = MessageDialog.new(target, customMt or RmPenSelectorDialog_mt)
    self.model = nil
    self.selected = {}
    return self
end

---Open the dialog over the current pens.
function RmPenSelectorDialog.show()
    local dialog = rawget(RmPenSelectorDialog, "INSTANCE")
    if dialog == nil then
        Log:warning("RmPenSelectorDialog.show: dialog not registered - cannot open")
        return
    end
    dialog:setData(RmPenSwitch.listPens())
    g_gui:showDialog("RmPenSelectorDialog")
end

---Per-open rebuild of the model and the working selection.
---@param rows table pen rows
function RmPenSelectorDialog:setData(rows)
    self.model = RmPenSelectorModel.buildModel(rows)
    self.selected = RmPenSelectorModel.initialSelection(self.model)
    Log:debug("RmPenSelectorDialog:setData: %d row(s)", #self.model.rows)
end

---Resolve the elements and bind the list.
function RmPenSelectorDialog:onGuiSetupFinished()
    RmPenSelectorDialog:superClass().onGuiSetupFinished(self)
    self.penList = self:getDescendantById("penList")
    self.selectButton = self:getDescendantById("selectButton")
    self.selectAllButton = self:getDescendantById("selectAllButton")
    self.okButton = self:getDescendantById("okButton")
    self.buttonsPC = self:getDescendantById("buttonsPC")
    if self.penList ~= nil then
        self.penList:setDataSource(self)
        self.penList:setDelegate(self)
    else
        Log:warning("RmPenSelectorDialog: penList element missing")
    end
end

---Dialog type that plays the query sample, not the warning sample.
function RmPenSelectorDialog:onCreate()
    RmPenSelectorDialog:superClass().onCreate(self)
    self:setDialogType(DialogElement.TYPE_QUESTION)
end

---One reference-pixel geometry line for an element.
---@param name string
---@param e table|nil
---@return string
local function geom(name, e)
    if e == nil or e.absSize == nil then
        return name .. "=nil"
    end
    return string.format("%s pos=%.1f,%.1f size=%.1fx%.1f", name, e.absPosition[1] * 1920,
        e.absPosition[2] * 1080, e.absSize[1] * 1920, e.absSize[2] * 1080)
end

---Label the list-wide toggle from whether any available pen is ticked.
function RmPenSelectorDialog:refreshSelectAllLabel()
    if self.selectAllButton == nil or self.model == nil then
        Log:trace("RmPenSelectorDialog:refreshSelectAllLabel: no button or model")
        return
    end
    local anySelected = RmPenSelectorModel.hasAnySelection(self.selected, self.model)
    self.selectAllButton:setText(text(anySelected and "button_deselectAll" or "button_selectAll"))
end

---Reload, re-anchor to the first row when there is one, and log the geometry.
function RmPenSelectorDialog:onOpen()
    RmPenSelectorDialog:superClass().onOpen(self)
    local rowCount = self.model ~= nil and #self.model.rows or 0
    local hasRows = rowCount > 0
    for _, button in ipairs({ self.okButton, self.selectButton, self.selectAllButton }) do
        button:setDisabled(not hasRows)
    end
    self:refreshSelectAllLabel()
    if self.penList ~= nil then
        self.penList:reloadData()
        if rowCount > 0 then
            self.penList:setSelectedItem(1, 1)
        end
    end
    local cell = self.penList ~= nil and self.penList.elements ~= nil and self.penList.elements[1] or nil
    local cellAttr = function(n)
        return cell ~= nil and cell.getAttribute ~= nil and cell:getAttribute(n) or nil
    end
    Log:debug("RmPenSelectorDialog:onOpen: %d row(s) | %s | %s | %s | %s | %s | %s | %s", rowCount,
        geom("dialog", self:getDescendantById("dialogElement")), geom("list", self.penList),
        geom("buttons", self.buttonsPC), geom("row", cell), geom("name", cellAttr("name")),
        geom("farm", cellAttr("farm")), geom("checkbox", cellAttr("checkbox")))
end

-- ============================================================================
-- SmoothList data source (single section)
-- ============================================================================

---@param list table
---@return number
function RmPenSelectorDialog:getNumberOfSections(list)
    return 1
end

---@param list table
---@param section number
---@return number
function RmPenSelectorDialog:getNumberOfItemsInSection(list, section)
    if list ~= self.penList or self.model == nil then
        return 0
    end
    return #self.model.rows
end

---Populate one row; an unavailable row is greyed with its checkbox hidden.
---@param list table
---@param section number
---@param index number
---@param cell table
function RmPenSelectorDialog:populateCellForItemInSection(list, section, index, cell)
    local row = self.model ~= nil and self.model.rows[index] or nil
    if list ~= self.penList or row == nil then
        return
    end
    local available = row.available == true
    local columns = { name = row.name, animalType = row.animalType, farm = row.farmName }
    -- Singleplayer has one farm, so the farm column is shown in multiplayer only.
    local mission = g_currentMission
    local isMultiplayer = mission ~= nil and mission.missionDynamicInfo ~= nil
        and mission.missionDynamicInfo.isMultiplayer == true
    local farmCell = cell:getAttribute("farm")
    if farmCell ~= nil then
        farmCell:setVisible(isMultiplayer)
    end
    for attr, value in pairs(columns) do
        local element = cell:getAttribute(attr)
        if element ~= nil then
            -- Disabled greys the text without touching the element's XML geometry.
            element:setDisabled(not available)
            element:setText(value)
        end
    end
    local status = cell:getAttribute("status")
    if status ~= nil then
        local label = ""
        if not available then
            label = text("ui_unavailable")
            if row.disabled == true then
                label = label .. " / " .. text("rm_mfa_pens_off")
            end
        end
        status:setText(label)
    end
    local checkbox = cell:getAttribute("checkbox")
    local check = cell:getAttribute("check")
    if checkbox ~= nil then
        checkbox:setVisible(available)
        -- Assigned, never wrapped: the list pools cells, so a cell is re-bound to its current row.
        checkbox.onClickCallback = function()
            self:toggleRow(row)
            if check ~= nil then
                check:setVisible(row.available == true and self.selected[row] == true)
            end
        end
    end
    if check ~= nil then
        check:setVisible(available and self.selected[row] == true)
    end
    Log:trace("RmPenSelectorDialog: row %s '%s' available=%s ticked=%s", tostring(index), tostring(row.name),
        tostring(available), tostring(self.selected[row] == true))
end

---Row click moves focus only.
---@param list table
---@param section number
---@param index number
function RmPenSelectorDialog:onListClick(list, section, index)
    Log:trace("RmPenSelectorDialog:onListClick: index=%s", tostring(index))
end

---Flip one row's box (unavailable rows refused) and refresh the list-wide label.
---@param row table
---@return boolean toggled
function RmPenSelectorDialog:toggleRow(row)
    local toggled = RmPenSelectorModel.toggle(self.selected, row)
    self:refreshSelectAllLabel()
    Log:debug("PENS: toggle '%s' -> %s (toggled=%s)", tostring(row ~= nil and row.name or nil),
        tostring(row ~= nil and self.selected[row] == true), tostring(toggled))
    return toggled
end

---Select (MENU_ACTIVATE): toggle the focused row; reload without re-anchoring.
function RmPenSelectorDialog:onClickSelect()
    if self.penList == nil or self.model == nil then
        Log:trace("RmPenSelectorDialog:onClickSelect: no list or model")
        return
    end
    local index = self.penList:getSelectedIndexInSection()
    local row = index ~= nil and self.model.rows[index] or nil
    if row == nil then
        Log:trace("RmPenSelectorDialog:onClickSelect: no focused row (index=%s)", tostring(index))
        return
    end
    self:toggleRow(row)
    self.penList:reloadData()
end

---Select all / none over the available rows.
function RmPenSelectorDialog:onClickSelectAll()
    if self.model == nil or #self.model.rows == 0 then
        Log:trace("RmPenSelectorDialog:onClickSelectAll: no rows")
        return
    end
    RmPenSelectorModel.toggleAll(self.selected, self.model)
    self:refreshSelectAllLabel()
    if self.penList ~= nil then
        self.penList:reloadData()
    end
end

---OK: re-check master rights, send the player's changes, close.
function RmPenSelectorDialog:onClickOk()
    if self.model == nil or #self.model.rows == 0 then
        Log:debug("RmPenSelectorDialog:onClickOk: no rows - ignored")
        return
    end
    if not RmPenSwitch.localHasMasterRights() then
        Log:warning("RmPenSelectorDialog:onClickOk: no master rights any more - nothing sent")
        self:close()
        return
    end
    local ops = RmPenSelectorModel.buildOps(self.model, self.selected)
    self:close()
    local ok, err = pcall(RmPenSwitchRequestEvent.send, ops)
    if not ok then
        Log:error("RmPenSelectorDialog:onClickOk: send failed: %s", tostring(err))
    end
end

---Back closes without changes.
function RmPenSelectorDialog:onClickBack()
    Log:debug("RmPenSelectorDialog:onClickBack: closed without changes")
    self:close()
end

---BaseMission.loadMapFinished append: register the dialog on every peer with a viewer.
local function onLoadMapFinished()
    if g_dedicatedServer ~= nil or g_gui == nil then
        return
    end
    RmPenSelectorDialog.register()
end

BaseMission.loadMapFinished = Utils.appendedFunction(BaseMission.loadMapFinished, onLoadMapFinished)
