--[[
    RmManureShared.lua

    Shared home for the ManureForAll marker constant and the STRAW / MANURE
    fill-type resolver that the core modules consume. One shared home so the
    resolver is never duplicated; callers keep their own failure policy.

    Loaded by scripts/main.lua before the console shell and the main module.

    Author: Ritter
]]

RmManureShared = {}

-- Husbandry marker: tags fill-type / husbandry state owned by this mod.
RmManureShared.MARKER = "rmManureForAll"

-- Per-placeable native-straw-intake flag name. RUNTIME-ONLY: written by RmStrawSink at
-- augment/build time, read by RmTroughDivert, never persisted. Sampled BEFORE the mod adds
-- STRAW to a station, so it records whether the husbandry brought its OWN straw intake
-- (station support or a straw-accepting unload trigger) -- true means the food-trough
-- straw divert must not add a second intake path.
RmManureShared.NATIVE_STRAW_INTAKE = "rmNativeStrawIntake"

local Log = RmLogging.getLogger("ManureForAll")

---Resolve a single fill type from its enum value and manager lookup.
--- Enum value wins unless nil (the manager value fills in); both non-nil and
--- unequal is a registry disagreement -> WARNING + nil; absent from both
--- sources -> WARNING + nil.
---@param name string fill-type name (for the warning text)
---@param enumVal integer|nil FillType.<NAME>
---@param managerVal integer|nil g_fillTypeManager:getFillTypeIndexByName(NAME)
---@return integer|nil index resolved index, or nil when unavailable/inconsistent
local function resolveOne(name, enumVal, managerVal)
    if enumVal == nil then
        if managerVal == nil then
            Log:warning("Fill type %s absent from both the FillType enum and the fill-type manager; resolved to nil", name)
            return nil
        end
        return managerVal
    end
    if managerVal ~= nil and enumVal ~= managerVal then
        Log:warning("Fill type %s enum index %s disagrees with manager index %s; resolved to nil",
            name, tostring(enumVal), tostring(managerVal))
        return nil
    end
    return enumVal
end

---Resolve the STRAW and MANURE fill-type indices.
--- Both params are optional and default to the FillType enum / g_fillTypeManager
--- globals (injectable for tests). Each result is independently nil when its type
--- is unavailable or its two sources disagree. Nil-guarded: resolves
--- from whichever source exists and never errors, even pre-init.
---@param fillTypeEnum table|nil defaults to the global FillType enum
---@param fillTypeManager table|nil defaults to g_fillTypeManager
---@return integer|nil straw
---@return integer|nil manure
function RmManureShared.resolveFillTypes(fillTypeEnum, fillTypeManager)
    fillTypeEnum = fillTypeEnum or FillType
    fillTypeManager = fillTypeManager or g_fillTypeManager

    local strawEnum, manureEnum
    if fillTypeEnum ~= nil then
        strawEnum = fillTypeEnum.STRAW
        manureEnum = fillTypeEnum.MANURE
    end

    local strawManager, manureManager
    if fillTypeManager ~= nil then
        strawManager = fillTypeManager:getFillTypeIndexByName("STRAW")
        manureManager = fillTypeManager:getFillTypeIndexByName("MANURE")
    end

    local straw = resolveOne("STRAW", strawEnum, strawManager)
    local manure = resolveOne("MANURE", manureEnum, manureManager)
    return straw, manure
end
