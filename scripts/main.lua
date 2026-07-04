--[[
    main.lua

    Main loader for ManureForAll mod.
    Loads all dependencies in the correct order.

    ============================================================
    IMPORTANT: This file is a LOADER ONLY.
    ============================================================
    - It loads dependencies via source() in the correct order
    - All mod logic belongs in scripts/RmManureForAll.lua
    - Do NOT add module definitions (ManureForAll = {}) here
    - Do NOT add business logic or game hooks here
    ============================================================

    Author: Ritter
]]

local modDirectory = g_currentModDirectory

-- =============================================================================
-- INFRASTRUCTURE
-- =============================================================================

source(modDirectory .. "scripts/rmlib/RmLogging.lua")
local Log = RmLogging.getLogger("ManureForAll")
Log:setLevel(RmLogging.LOG_LEVEL.INFO) -- Set to DEBUG/TRACE for development

-- =============================================================================
-- SHARED + CONSOLE (loaded before the main module)
-- =============================================================================

source(modDirectory .. "scripts/core/RmManureShared.lua")
source(modDirectory .. "scripts/console/RmManureConsole.lua")

-- =============================================================================
-- MAIN MODULE
-- =============================================================================

source(modDirectory .. "scripts/RmManureForAll.lua")

-- =============================================================================
-- TESTING (conditional - tests are excluded from release builds)
-- =============================================================================

local testRunnerPath = modDirectory .. "scripts/tests/RmTestRunner.lua"
if fileExists(testRunnerPath) then
    source(testRunnerPath)
end
