--[[
    RmManureConsole.lua

    Console dispatcher shell for ManureForAll. Registers the read/write console
    command family; the real subcommands land with their slices (1-4), so the
    shell answers "not yet migrated" until then.

    Self-installs via BaseMission.loadMapFinished / delete (project-context: NOT
    addModEventListener). Commands register only on a SP server; a module-level
    registered flag pairs register/remove.

    Author: Ritter
]]

RmManureConsole = {}

-- Paired with the SP+server registration gate; guards removal on map delete.
RmManureConsole.registered = false

local Log = RmLogging.getLogger("ManureForAll")

-- Recognised mfaDump subcommands (subcommand bodies land in slices 1-4).
local DUMP_SUBCOMMANDS = { curves = true, sinks = true, heaps = true }

---mfaDump [curves|sinks|heaps] [name]: dump migrated state for a domain.
--- `curves` delegates to RmCurveInjector.dumpCurves (slice 1); `sinks` delegates to
--- RmStrawSink.dumpSinks (slice 2), RETURNING its string for the console to print;
--- `heaps` stays a "not yet migrated" placeholder until its slice; missing/unknown
--- subcommand -> usage line. Args beyond `[name]` are ignored. Never errors on a
--- nil arg.
---@param subcommand string|nil
---@param name string|nil optional subType-or-type name for `curves`
---@return string|nil message console-return string when a subcommand produces one
function RmManureConsole:consoleDump(subcommand, name)
    if subcommand == "curves" then
        return RmCurveInjector.dumpCurves(name)
    elseif subcommand == "sinks" then
        return RmStrawSink.dumpSinks()
    elseif subcommand ~= nil and DUMP_SUBCOMMANDS[subcommand] then
        Log:info("mfaDump %s: not yet migrated", subcommand) -- heaps: slice 4
    else
        Log:info("Usage: mfaDump curves|sinks|heaps [name]")
    end
end

---mfaAddStraw [liters] [index]: deposit STRAW on a wired husbandry.
--- Thin dispatcher: delegates to RmStrawSink.addStraw (bodies + validation live there)
--- and RETURNS its string for the console to print. Never errors on missing args.
---@param litersArg string|nil deposit liters (default 1000; finite positive; fractional ok)
---@param indexArg string|nil optional 1-based dump-ordinal target (fan-out to all if omitted)
---@return string message console-return string
function RmManureConsole:consoleAddStraw(litersArg, indexArg)
    return RmStrawSink.addStraw(litersArg, indexArg)
end

-- =============================================================================
-- SELF-INSTALL (SP + server gate, paired register/remove via registered flag)
-- =============================================================================

local function registerConsoleCommands()
    if RmManureConsole.registered then
        return
    end
    if g_currentMission == nil then
        return
    end
    if g_currentMission:getIsServer()
        and not g_currentMission.missionDynamicInfo.isMultiplayer then
        addConsoleCommand("mfaDump", "ManureForAll: dump migrated state (curves|sinks|heaps [name])",
            "consoleDump", RmManureConsole)
        addConsoleCommand("mfaAddStraw", "ManureForAll: deposit STRAW on wired husbandries [liters] [index]",
            "consoleAddStraw", RmManureConsole)
        RmManureConsole.registered = true
        Log:debug("mfa console commands registered")
    end
end

local function removeConsoleCommands()
    if RmManureConsole.registered then
        removeConsoleCommand("mfaDump")
        removeConsoleCommand("mfaAddStraw")
        RmManureConsole.registered = false
        Log:trace("mfa console commands unregistered")
    end
end

BaseMission.loadMapFinished = Utils.appendedFunction(BaseMission.loadMapFinished, registerConsoleCommands)
BaseMission.delete = Utils.appendedFunction(BaseMission.delete, removeConsoleCommands)
