--[[
    RmPenSwitch.lua

    Per-pen manure production switch. A pen of an injected type is ACTIVE only when it is fully
    wired (RmTroughDivert.isWiredHusbandry) and not switched off; an inactive pen skips the
    straw specialization's layer for updateOutput, updateProduction, getConditionInfos and
    updateInfo, so it shows no straw or manure rows, consumes nothing, makes no manure and
    takes no straw productivity factor. Native straw barns are never gated.

    The server keeps the switched-off set by uniqueId, saves it to rm_ManureForAllSettings.xml
    in the savegame directory, and syncs it to clients as node objects (RmPenSwitchStateEvent).
    Every peer reads the flag as a runtime field on the placeable.

    Author: Ritter
]]

-- Module table doubles as the install-guard home (survives re-source in testing).
RmPenSwitch = RmPenSwitch or {}

local Log = RmLogging.getLogger("ManureForAll")

-- ============================================================================
-- CONSTANTS
-- ============================================================================

-- Runtime field on the placeable: true when manure production is switched off.
RmPenSwitch.DISABLED_FIELD = "rmPenSwitchDisabled"
RmPenSwitch.SETTINGS_FILE = "rm_ManureForAllSettings.xml"
RmPenSwitch.XML_ROOT = "rmManureForAllSettings"
RmPenSwitch.XML_PEN_KEY = "rmManureForAllSettings.disabledPens.pen"
-- Neutral text for a dialog column whose source is missing.
RmPenSwitch.NEUTRAL_LABEL = "-"

-- The four straw functions the gated slot wraps, in registration order.
local GATED_FUNCTIONS = { "updateOutput", "updateProduction", "getConditionInfos", "updateInfo" }

-- Server state, reset per map load.
RmPenSwitch.disabledByUniqueId = RmPenSwitch.disabledByUniqueId or {}
RmPenSwitch.loaded = RmPenSwitch.loaded or false
RmPenSwitch.subscribed = RmPenSwitch.subscribed or false

local FIELD = RmPenSwitch.DISABLED_FIELD

-- ============================================================================
-- SEAMS
-- ============================================================================

---Server-gate seam: true on the server or host. Suites swap it to drive the client branch.
---@return boolean
function RmPenSwitch.isServer()
    return g_server ~= nil
end

---Client-side master-rights check (UX only; the server re-checks every request).
---@return boolean
function RmPenSwitch.localHasMasterRights()
    if RmPenSwitch.isServer() then
        return true
    end
    local mission = g_currentMission
    return mission ~= nil and mission.isMasterUser == true
end

---The live placeable list, or nil before a mission exists.
---@return table|nil
function RmPenSwitch.livePlaceables()
    local mission = g_currentMission
    if mission == nil or mission.placeableSystem == nil then
        return nil
    end
    return mission.placeableSystem.placeables
end

-- ============================================================================
-- PREDICATE
-- ============================================================================

---Pure predicate: a pen is active when its type is injected, it is fully wired and not disabled.
---@param isInjected boolean
---@param isWired boolean
---@param isDisabled boolean
---@return boolean
function RmPenSwitch.computeActive(isInjected, isWired, isDisabled)
    return isInjected == true and isWired == true and isDisabled ~= true
end

---True when the placeable carries the switched-off runtime field.
---@param placeable table|nil
---@return boolean
function RmPenSwitch.isDisabled(placeable)
    return placeable ~= nil and placeable[FIELD] == true
end

---True when the placeable's type had husbandryStraw injected by this mod.
---@param placeable table|nil
---@return boolean
function RmPenSwitch.isGated(placeable)
    return placeable ~= nil and RmSpecInjector.isInjected(placeable.typeName)
end

---True when the pen's straw pipeline runs: injected, fully wired and not switched off.
---@param placeable table|nil
---@return boolean
function RmPenSwitch.isActive(placeable)
    local injected = RmPenSwitch.isGated(placeable)
    local wired = injected and RmTroughDivert.isWiredHusbandry(placeable) or false
    return RmPenSwitch.computeActive(injected, wired, RmPenSwitch.isDisabled(placeable))
end

---Normalized uniqueId of a placeable: nil when absent or empty.
---@param placeable table
---@return string|nil
function RmPenSwitch.uniqueIdOf(placeable)
    local id
    if placeable.getUniqueId ~= nil then
        id = placeable:getUniqueId()
    else
        id = placeable.uniqueId
    end
    if id == nil or id == "" then
        return nil
    end
    return id
end

---Display name of a placeable, or the neutral label.
---@param placeable table
---@return string
local function nameOf(placeable)
    local name = placeable.getName ~= nil and placeable:getName() or nil
    if name == nil or name == "" then
        return RmPenSwitch.NEUTRAL_LABEL
    end
    return name
end

-- ============================================================================
-- GATED WRAPPER
-- ============================================================================

---Wrap one straw function: an inactive injected pen skips the straw layer, anything else runs it.
---@param original function the straw function read from the class field at swap time
---@param fnName string|nil function name for the trace line
---@return function wrapper with the overwritten-function signature (self, superFunc, ...)
function RmPenSwitch.gate(original, fnName)
    return function(self, superFunc, ...)
        if RmPenSwitch.isGated(self) and not RmPenSwitch.isActive(self) then
            Log:trace("gate: %s skips the straw layer on '%s' (inactive)", tostring(fnName), tostring(self.typeName))
            return superFunc(self, ...)
        end
        return original(self, superFunc, ...)
    end
end

---Swap the four class fields for gated wrappers while the straw spec registers them; always restore.
---@param placeableType table the type being finalized
---@param superFunc function the straw spec's own registrar chain
local function gatedRegistrar(placeableType, superFunc)
    local spec = PlaceableHusbandryStraw
    local saved = {}
    for _, name in ipairs(GATED_FUNCTIONS) do
        saved[name] = spec[name]
        if saved[name] ~= nil then
            spec[name] = RmPenSwitch.gate(saved[name], name)
        end
    end
    local ok, err = pcall(superFunc, placeableType)
    for _, name in ipairs(GATED_FUNCTIONS) do
        spec[name] = saved[name]
    end
    if not ok then
        error(err, 0)
    end
    Log:trace("gated slot registered on type '%s'", tostring(placeableType ~= nil and placeableType.name))
end

-- ============================================================================
-- DIALOG ROWS
-- ============================================================================

---Owner farm name by ID: real farms 1..MAX_NUM_FARMS with a farm object, else the neutral label.
---@param placeable table
---@return string
local function farmNameOf(placeable)
    local farmId = placeable.getOwnerFarmId ~= nil and placeable:getOwnerFarmId() or nil
    local maxFarms = FarmManager ~= nil and FarmManager.MAX_NUM_FARMS or 8
    if type(farmId) ~= "number" or farmId <= 0 or farmId > maxFarms or g_farmManager == nil then
        return RmPenSwitch.NEUTRAL_LABEL
    end
    local farm = g_farmManager:getFarmById(farmId)
    if farm == nil or farm.name == nil or farm.name == "" then
        return RmPenSwitch.NEUTRAL_LABEL
    end
    return farm.name
end

---Animal type title of a pen, or the neutral label.
---@param placeable table
---@return string
local function animalTypeOf(placeable)
    local mission = g_currentMission
    if placeable.getAnimalTypeIndex == nil or mission == nil or mission.animalSystem == nil then
        return RmPenSwitch.NEUTRAL_LABEL
    end
    local animalType = mission.animalSystem:getTypeByIndex(placeable:getAnimalTypeIndex())
    if animalType == nil or animalType.groupTitle == nil or animalType.groupTitle == "" then
        return RmPenSwitch.NEUTRAL_LABEL
    end
    return animalType.groupTitle
end

---Case-insensitive strict ordering on farm, then building, then animal type, then list position.
---@param a table row
---@param b table row
---@return boolean
local function rowLess(a, b)
    local fa, fb = string.lower(a.farmName), string.lower(b.farmName)
    if fa ~= fb then
        return fa < fb
    end
    local na, nb = string.lower(a.name), string.lower(b.name)
    if na ~= nb then
        return na < nb
    end
    local ta, tb = string.lower(a.animalType), string.lower(b.animalType)
    if ta ~= tb then
        return ta < tb
    end
    return a.order < b.order
end

---Rows for the dialog: every placed pen of an injected type, sorted for display.
---@param placeables table|nil defaults to the live placeable list
---@return table rows array of { placeable, name, animalType, farmName, available, disabled }
function RmPenSwitch.listPens(placeables)
    placeables = placeables or RmPenSwitch.livePlaceables()
    local rows = {}
    if placeables == nil then
        Log:debug("PENS: no placeable list - 0 rows")
        return rows
    end
    for index, placeable in ipairs(placeables) do
        if RmPenSwitch.isGated(placeable) and placeable.markedForDeletion ~= true then
            rows[#rows + 1] = {
                placeable = placeable,
                name = nameOf(placeable),
                animalType = animalTypeOf(placeable),
                farmName = farmNameOf(placeable),
                available = RmTroughDivert.isWiredHusbandry(placeable),
                disabled = RmPenSwitch.isDisabled(placeable),
                order = index,
            }
        end
    end
    table.sort(rows, rowLess)
    Log:debug("PENS: %d row(s) for the dialog", #rows)
    return rows
end

---Live pens currently switched off, for the state event.
---@param placeables table|nil defaults to the live placeable list
---@return table pens array of placeables
function RmPenSwitch.listDisabledPens(placeables)
    placeables = placeables or RmPenSwitch.livePlaceables()
    local pens = {}
    if placeables == nil then
        return pens
    end
    for _, placeable in ipairs(placeables) do
        if RmPenSwitch.isGated(placeable) and RmPenSwitch.isDisabled(placeable) then
            pens[#pens + 1] = placeable
        end
    end
    return pens
end

-- ============================================================================
-- SERVER APPLY
-- ============================================================================

---Set or clear the runtime field on one pen.
---@param placeable table
---@param disabled boolean
function RmPenSwitch.setDisabledLocal(placeable, disabled)
    if disabled == true then
        placeable[FIELD] = true
    else
        placeable[FIELD] = nil
    end
end

---Apply switch ops on the server: last op per pen wins, only net changes to the stored set count.
---@param ops table array of { pen = placeable, disabled = boolean }
---@return integer appliedCount number of pens whose stored state changed
---@return string reason "applied" or "no net change"
function RmPenSwitch.applyOps(ops)
    Log:trace(">>> applyOps(%d op(s))", ops ~= nil and #ops or 0)
    local lastByPen, order = {}, {}
    for _, op in ipairs(ops or {}) do
        if lastByPen[op.pen] == nil then
            order[#order + 1] = op.pen
        end
        lastByPen[op.pen] = op.disabled == true
    end

    local applied, warned = 0, 0
    for _, pen in ipairs(order) do
        local wantDisabled = lastByPen[pen]
        local id = RmPenSwitch.uniqueIdOf(pen)
        if id == nil then
            Log:warning("applyOps: pen '%s' has no uniqueId yet - skipped", tostring(nameOf(pen)))
        elseif not RmTroughDivert.isWiredHusbandry(pen) then
            Log:warning("applyOps: pen '%s' (%s) is not set up for straw - op skipped, stored state kept",
                tostring(nameOf(pen)), tostring(id))
        else
            local before = RmPenSwitch.disabledByUniqueId[id] == true
            if wantDisabled then
                RmPenSwitch.disabledByUniqueId[id] = true
            else
                RmPenSwitch.disabledByUniqueId[id] = nil
            end
            RmPenSwitch.setDisabledLocal(pen, wantDisabled)
            if before ~= wantDisabled then
                applied = applied + 1
                Log:debug("PENS: '%s' (%s) manure production %s", tostring(nameOf(pen)), tostring(id),
                    wantDisabled and "off" or "on")
                -- Off clears the pen's no-heap flag; on then warns at once when the pen has no heap.
                if RmHeapConnector.checkHeapNow(pen, nil, true) then
                    warned = warned + 1
                end
            else
                Log:trace("applyOps: '%s' unchanged", tostring(id))
            end
        end
    end

    if warned > 0 then
        Log:debug("PENS: %d switched-on pen(s) have no heap in range - one notification", warned)
        RmHeapConnector.notifyNoHeap(warned)
    end
    local reason = applied > 0 and "applied" or "no net change"
    Log:info("pen switch: %d pen(s) changed (%s)", applied, reason)
    return applied, reason
end

-- ============================================================================
-- CLIENT RECEIVE
-- ============================================================================

---Rebuild client flags from a full snapshot; touches only the runtime field, never spec tables.
---@param pens table array of placeables from the state event
---@param placeables table|nil defaults to the live placeable list
---@return integer setCount pens flagged after the rebuild
function RmPenSwitch.rebuildFromList(pens, placeables)
    placeables = placeables or RmPenSwitch.livePlaceables()
    local cleared = 0
    for _, placeable in ipairs(placeables or {}) do
        if RmPenSwitch.isGated(placeable) and placeable[FIELD] ~= nil then
            placeable[FIELD] = nil
            cleared = cleared + 1
        end
    end
    local set = 0
    for _, pen in ipairs(pens or {}) do
        if RmPenSwitch.isGated(pen) then
            pen[FIELD] = true
            set = set + 1
        else
            Log:trace("rebuildFromList: skipped a non-injected object '%s'", tostring(pen.typeName))
        end
    end
    Log:info("pen switch: received state - %d pen(s) off (%d flag(s) cleared first)", set, cleared)
    return set
end

-- ============================================================================
-- PERSISTENCE (codec seams + thin disk wrappers)
-- ============================================================================

---Read the switched-off uniqueIds from an open settings XMLFile; blank and duplicate ids skipped.
---@param xmlFile table an open XMLFile
---@return table ids array of uniqueId strings
function RmPenSwitch.readDisabledSet(xmlFile)
    local ids, seen = {}, {}
    xmlFile:iterate(RmPenSwitch.XML_PEN_KEY, function(_, key)
        local id = xmlFile:getString(key .. "#uniqueId")
        if id == nil or id == "" then
            Log:debug("PERSIST: blank pen entry at %s - skipped", tostring(key))
        elseif seen[id] then
            Log:debug("PERSIST: duplicate pen entry '%s' - skipped", tostring(id))
        else
            seen[id] = true
            ids[#ids + 1] = id
        end
    end)
    return ids
end

---Write the switched-off uniqueIds, sorted, into an open settings XMLFile.
---@param xmlFile table an open XMLFile
---@param ids table array of uniqueId strings
function RmPenSwitch.writeDisabledSet(xmlFile, ids)
    local sorted = {}
    for _, id in ipairs(ids) do
        sorted[#sorted + 1] = id
    end
    table.sort(sorted)
    for i, id in ipairs(sorted) do
        xmlFile:setString(string.format("%s(%d)#uniqueId", RmPenSwitch.XML_PEN_KEY, i - 1), id)
    end
end

---Settings file path inside a savegame directory.
---@param savegameDirectory string
---@return string
function RmPenSwitch.settingsPath(savegameDirectory)
    return savegameDirectory .. "/" .. RmPenSwitch.SETTINGS_FILE
end

---Read the set from disk; absent, unreadable or wrong-root files read as the empty set.
---@param path string
---@return table ids
function RmPenSwitch.readFromDisk(path)
    if not fileExists(path) then
        Log:debug("PERSIST: no %s - every pen enabled", tostring(path))
        return {}
    end
    local xmlFile = XMLFile.load("rmManureForAllSettings", path)
    if xmlFile == nil then
        Log:warning("could not load %s - every pen enabled", tostring(path))
        return {}
    end
    local ids = {}
    if xmlFile:getRootName() ~= RmPenSwitch.XML_ROOT then
        Log:warning("%s has root '%s', expected '%s' - every pen enabled", tostring(path),
            tostring(xmlFile:getRootName()), RmPenSwitch.XML_ROOT)
    else
        ids = RmPenSwitch.readDisabledSet(xmlFile)
    end
    xmlFile:delete()
    return ids
end

---Write the set to disk synchronously.
---@param path string
---@param ids table array of uniqueId strings
---@return boolean saved
function RmPenSwitch.writeToDisk(path, ids)
    local xmlFile = XMLFile.create("rmManureForAllSettings", path, RmPenSwitch.XML_ROOT)
    if xmlFile == nil then
        Log:warning("could not create %s - switched-off pens not saved", tostring(path))
        return false
    end
    RmPenSwitch.writeDisabledSet(xmlFile, ids)
    local saved = xmlFile:save(false, true) == true
    xmlFile:delete()
    if not saved then
        Log:warning("could not save %s - switched-off pens not saved", tostring(path))
    end
    return saved
end

---Stored ids as an array.
---@return table ids
function RmPenSwitch.storedIds()
    local ids = {}
    for id, flag in pairs(RmPenSwitch.disabledByUniqueId) do
        if flag == true then
            ids[#ids + 1] = id
        end
    end
    return ids
end

---Load the saved set once per map (server): flag placed pens, drop ids of pens no longer placed.
function RmPenSwitch.loadDisabledSet()
    if not RmPenSwitch.isServer() or RmPenSwitch.loaded then
        return
    end
    RmPenSwitch.loaded = true
    local mission = g_currentMission
    local dir = mission ~= nil and mission.missionInfo ~= nil and mission.missionInfo.savegameDirectory or nil
    if dir == nil then
        Log:debug("PERSIST: new unsaved game - every pen enabled")
        return
    end
    local placeableSystem = mission.placeableSystem
    local kept, dropped = 0, 0
    for _, id in ipairs(RmPenSwitch.readFromDisk(RmPenSwitch.settingsPath(dir))) do
        local pen = placeableSystem ~= nil and placeableSystem:getPlaceableByUniqueId(id) or nil
        if pen ~= nil and RmPenSwitch.isGated(pen) then
            RmPenSwitch.disabledByUniqueId[id] = true
            RmPenSwitch.setDisabledLocal(pen, true)
            kept = kept + 1
            Log:debug("PERSIST: '%s' (%s) loads switched off", tostring(nameOf(pen)), tostring(id))
        else
            dropped = dropped + 1
            Log:debug("PERSIST: '%s' is no longer placed - dropped", tostring(id))
        end
    end
    Log:info("pen switch: loaded %d switched-off pen(s), dropped %d stale id(s)", kept, dropped)
end

-- ============================================================================
-- LIFECYCLE HOOK BODIES
-- ============================================================================

---FSCareerMissionInfo.saveToXMLFile append: write the set beside the savegame (server).
---@param missionInfo table
local function onSaveToXMLFile(missionInfo)
    if not RmPenSwitch.isServer() then
        return
    end
    local dir = missionInfo ~= nil and missionInfo.savegameDirectory or nil
    if dir == nil then
        Log:trace("onSaveToXMLFile: no savegame directory - skipped")
        return
    end
    local ids = RmPenSwitch.storedIds()
    if RmPenSwitch.writeToDisk(RmPenSwitch.settingsPath(dir), ids) then
        Log:info("pen switch: saved %d switched-off pen(s)", #ids)
    end
end

---PlaceableHusbandry.onDelete append: a sold pen leaves the set (not on game exit).
---@param placeable table
local function onHusbandryDelete(placeable)
    if not RmPenSwitch.isServer() then
        return
    end
    local mission = g_currentMission
    if mission ~= nil and mission.isExitingGame then
        return
    end
    local id = RmPenSwitch.uniqueIdOf(placeable)
    if id ~= nil and RmPenSwitch.disabledByUniqueId[id] == true then
        RmPenSwitch.disabledByUniqueId[id] = nil
        Log:debug("PENS: deleted pen '%s' left the switched-off set", tostring(id))
    end
end

---FSBaseMission.sendInitialClientState append: send the full set to the joining client.
---@param _ table mission (unused)
---@param connection table the joining client's connection
local function onSendInitialClientState(_, connection)
    RmPenSwitchStateEvent.sendToConnection(connection)
end

---SAVEGAME_LOADED handler (server): load the saved set.
function RmPenSwitch:onSavegameLoaded()
    RmPenSwitch.loadDisabledSet()
end

---BaseMission.loadMapFinished append: subscribe the post-load read (flag-paired).
local function onLoadMapFinished()
    if RmPenSwitch.subscribed or g_messageCenter == nil then
        return
    end
    g_messageCenter:subscribe(MessageType.SAVEGAME_LOADED, RmPenSwitch.onSavegameLoaded, RmPenSwitch)
    RmPenSwitch.subscribed = true
end

---BaseMission.delete append: reset the per-map state and drop the subscription.
local function onDeleteMap()
    RmPenSwitch.disabledByUniqueId = {}
    RmPenSwitch.loaded = false
    if RmPenSwitch.subscribed and g_messageCenter ~= nil then
        g_messageCenter:unsubscribe(MessageType.SAVEGAME_LOADED, RmPenSwitch)
    end
    RmPenSwitch.subscribed = false
end

-- Exposed for the suites.
RmPenSwitch.gatedRegistrar = gatedRegistrar
RmPenSwitch.onSaveToXMLFile = onSaveToXMLFile
RmPenSwitch.onHusbandryDelete = onHusbandryDelete
RmPenSwitch.GATED_FUNCTIONS = GATED_FUNCTIONS

-- ============================================================================
-- INSTALL (top-level, guarded once per process; each hook only where its class is loaded)
-- ============================================================================

if not RmPenSwitch.installed then
    if PlaceableHusbandryStraw ~= nil and PlaceableHusbandryStraw.registerOverwrittenFunctions ~= nil then
        PlaceableHusbandryStraw.registerOverwrittenFunctions =
            Utils.overwrittenFunction(PlaceableHusbandryStraw.registerOverwrittenFunctions, gatedRegistrar)
    end
    if FSCareerMissionInfo ~= nil and FSCareerMissionInfo.saveToXMLFile ~= nil then
        FSCareerMissionInfo.saveToXMLFile = Utils.appendedFunction(FSCareerMissionInfo.saveToXMLFile, onSaveToXMLFile)
    end
    if PlaceableHusbandry ~= nil and PlaceableHusbandry.onDelete ~= nil then
        PlaceableHusbandry.onDelete = Utils.appendedFunction(PlaceableHusbandry.onDelete, onHusbandryDelete)
    end
    if FSBaseMission ~= nil and FSBaseMission.sendInitialClientState ~= nil then
        FSBaseMission.sendInitialClientState =
            Utils.appendedFunction(FSBaseMission.sendInitialClientState, onSendInitialClientState)
    end
    if BaseMission ~= nil then
        BaseMission.loadMapFinished = Utils.appendedFunction(BaseMission.loadMapFinished, onLoadMapFinished)
        BaseMission.delete = Utils.appendedFunction(BaseMission.delete, onDeleteMap)
    end
    RmPenSwitch.installed = true
end
