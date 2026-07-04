--[[
    RmManureForAll.lua

    Main module for ManureForAll mod.
    Contains all mod logic, state, and game integration hooks.

    This file is loaded by scripts/main.lua.

    Author: Ritter

    ARCHITECTURE:
    - Module declaration and state management
    - Game lifecycle hooks (loadMapFinished, delete, saveSavegame)
    - Core business logic
]]

-- Module declaration
-- Note: Dependencies (RmLogging) are loaded via scripts/main.lua
RmManureForAll = {}
RmManureForAll.modDirectory = g_currentModDirectory
RmManureForAll.modName = g_currentModName

-- Per-mod logger instance with automatic multiplayer context
local Log = RmLogging.getLogger("ManureForAll")

-- Module constants (use UPPER_SNAKE_CASE, scoped to module)
-- RmManureForAll.SOME_CONSTANT = "value"

-- ============================================================================
-- INITIALIZATION: Lifecycle hooks
-- ============================================================================

---Called when map finishes loading
---This is the main entry point for mod initialization
local function onLoadMapFinished()
    Log:info("Map loaded, initializing ManureForAll")

    -- TODO: Add initialization logic here
    -- Examples:
    -- - Load configuration from XML
    -- - Subscribe to message center events
    -- - Initialize state variables
    -- - Register console commands

    -- Example: Subscribe to savegame loaded event
    -- g_messageCenter:subscribe(MessageType.SAVEGAME_LOADED, RmManureForAll.onSavegameLoaded, RmManureForAll)

    Log:info("ManureForAll initialization complete")
end

-- Hook into map loading completion
BaseMission.loadMapFinished = Utils.appendedFunction(
    BaseMission.loadMapFinished,
    onLoadMapFinished
)

-- ============================================================================
-- CLEANUP: Map unload
-- ============================================================================

---Called when map is being deleted/unloaded
---Clean up subscriptions, state, and references
local function onDeleteMap()
    Log:debug("Cleaning up ManureForAll")
    -- TODO: Unsubscribe from message center, clear state
end

BaseMission.delete = Utils.appendedFunction(
    BaseMission.delete,
    onDeleteMap
)

-- ============================================================================
-- OPTIONAL: Save/Load handling
-- ============================================================================

---Called when game saves
---Uncomment and implement if your mod needs to save data
-- local function onSaveSavegame()
--     Log:debug("Saving ManureForAll data...")
--     -- TODO: Save mod data to XML/savegame
-- end

-- Uncomment to hook into save
-- FSBaseMission.saveSavegame = Utils.appendedFunction(
--     FSBaseMission.saveSavegame,
--     onSaveSavegame
-- )

-- ============================================================================
-- CORE FUNCTIONALITY
-- ============================================================================

-- TODO: Add your mod's core functions here
-- Follow these conventions:
-- - Public functions: function RmManureForAll:functionName() or RmManureForAll.functionName()
-- - Private/local functions: local function functionName()
-- - Server mutations: always check `if g_server == nil then return end`

-- ============================================================================
-- INITIALIZATION COMPLETE
-- ============================================================================

Log:info("ManureForAll mod loaded (v%s)",
    g_modManager:getModByName(RmManureForAll.modName).version)
