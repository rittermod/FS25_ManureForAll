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
--- Known subcommand -> "not yet migrated" placeholder (further args ignored);
--- missing/unknown subcommand -> usage line. Never errors on a nil arg.
---@param subcommand string|nil
function RmManureConsole:consoleDump(subcommand)
    if subcommand ~= nil and DUMP_SUBCOMMANDS[subcommand] then
        Log:info("mfaDump %s: not yet migrated", subcommand)
    else
        Log:info("Usage: mfaDump curves|sinks|heaps [name]")
    end
end

---mfaAddStraw [liters] [index]: deposit STRAW on a wired husbandry.
--- Placeholder until slice 2; args are ignored (per-arg validation lands with the
--- real subcommand). Never errors on missing args.
function RmManureConsole:consoleAddStraw()
    Log:info("mfaAddStraw: not yet migrated")
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
