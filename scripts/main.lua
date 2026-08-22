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

source(modDirectory .. "scripts/rmlib/RmVersion.lua")
local Ver = RmVersion.forMod(g_currentModName, Log)
Log:info("Build: %s", Ver:describe())
-- DEBUG unless this is a released stable version (>= 1.0.0.0 with no -dev suffix).
Ver:applyBuildLogLevel()
-- Log:setLevel(RmLogging.LOG_LEVEL.DEBUG) -- Manual override of log level

-- =============================================================================
-- SHARED + CORE + CONSOLE (loaded before the main module)
-- =============================================================================

source(modDirectory .. "scripts/core/RmManureShared.lua")
source(modDirectory .. "scripts/core/RmManureRatios.lua")
source(modDirectory .. "scripts/core/RmCurveInjector.lua")
source(modDirectory .. "scripts/core/RmSpecInjector.lua")
source(modDirectory .. "scripts/core/RmStrawSink.lua")
source(modDirectory .. "scripts/core/RmTroughDivert.lua")
source(modDirectory .. "scripts/core/RmHeapConnector.lua")
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
