--[[
    RmPenSelectorModel.lua

    Pure selection logic for the pen dialog, keyed by row table identity. A ticked box means
    manure production ON. Unavailable rows (pens the mod could not set up) never toggle and never
    produce an op.

    Author: Ritter
]]

RmPenSelectorModel = {}

local Log = RmLogging.getLogger("ManureForAll")

---Build the model and the initial selection from RmPenSwitch.listPens rows.
---@param rows table|nil array of pen rows
---@return table model { rows, initialSelected } where initialSelected[row] = ticked
function RmPenSelectorModel.buildModel(rows)
    local model = { rows = rows or {}, initialSelected = {} }
    for _, row in ipairs(model.rows) do
        model.initialSelected[row] = row.disabled ~= true
    end
    Log:trace("RmPenSelectorModel.buildModel: %d row(s)", #model.rows)
    return model
end

---Working copy of the initial selection.
---@param model table
---@return table selected map row -> true when ticked
function RmPenSelectorModel.initialSelection(model)
    local selected = {}
    for _, row in ipairs(model.rows) do
        if model.initialSelected[row] == true then
            selected[row] = true
        end
    end
    return selected
end

---Flip one row's box; an unavailable row is refused.
---@param selected table map row -> true when ticked (mutated)
---@param row table
---@return boolean toggled
function RmPenSelectorModel.toggle(selected, row)
    if row == nil or row.available ~= true then
        Log:trace("RmPenSelectorModel.toggle: unavailable row - refused")
        return false
    end
    if selected[row] == true then
        selected[row] = nil
    else
        selected[row] = true
    end
    return true
end

---True when any available row is ticked.
---@param selected table
---@param model table
---@return boolean
function RmPenSelectorModel.hasAnySelection(selected, model)
    for _, row in ipairs(model.rows) do
        if row.available == true and selected[row] == true then
            return true
        end
    end
    return false
end

---Select none when any available row is ticked, otherwise select all; unavailable rows keep state.
---@param selected table map row -> true when ticked (mutated)
---@param model table
---@return table selected the same map
function RmPenSelectorModel.toggleAll(selected, model)
    local turnOn = not RmPenSelectorModel.hasAnySelection(selected, model)
    for _, row in ipairs(model.rows) do
        if row.available == true then
            if turnOn then
                selected[row] = true
            else
                selected[row] = nil
            end
        end
    end
    Log:trace("RmPenSelectorModel.toggleAll: every available pen %s", turnOn and "on" or "off")
    return selected
end

---One op per available row whose box differs from its initial state.
---@param model table
---@param selected table
---@return table ops array of { pen = placeable, disabled = boolean }
function RmPenSelectorModel.buildOps(model, selected)
    local ops = {}
    for _, row in ipairs(model.rows) do
        local ticked = selected[row] == true
        if row.available == true and ticked ~= (model.initialSelected[row] == true) then
            ops[#ops + 1] = { pen = row.placeable, disabled = not ticked }
        end
    end
    Log:debug("PENS: %d change(s) from the dialog", #ops)
    return ops
end
