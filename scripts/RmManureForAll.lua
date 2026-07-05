--[[
    RmManureForAll.lua

    Main module for ManureForAll mod -- thin by design: mod-level lifecycle
    markers and the version log. The feature logic lives in scripts/core/,
    each module installing its own hooks when sourced (before this file).

    This file is loaded by scripts/main.lua.

    Author: Ritter
]]

-- Module declaration
-- Note: Dependencies (RmLogging) are loaded via scripts/main.lua
RmManureForAll = {}
RmManureForAll.modDirectory = g_currentModDirectory
RmManureForAll.modName = g_currentModName

-- Per-mod logger instance with automatic multiplayer context
local Log = RmLogging.getLogger("ManureForAll")

-- ============================================================================
-- Lifecycle markers
-- ============================================================================

---Runs after the core modules' own loadMapFinished appends (they are sourced,
--- and hooked, before this file), so this log marks map-load work complete.
local function onLoadMapFinished()
    Log:info("ManureForAll initialization complete")
end

BaseMission.loadMapFinished = Utils.appendedFunction(
    BaseMission.loadMapFinished,
    onLoadMapFinished
)

---Map-unload marker; each core module owns its own teardown.
local function onDeleteMap()
    Log:debug("Cleaning up ManureForAll")
end

BaseMission.delete = Utils.appendedFunction(
    BaseMission.delete,
    onDeleteMap
)

Log:info("ManureForAll mod loaded (v%s)",
    g_modManager:getModByName(RmManureForAll.modName).version)
