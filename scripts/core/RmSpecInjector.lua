--[[
    RmSpecInjector.lua

    Slice 2 (type half) -- inject the husbandryStraw specialization onto every
    strawless food-bearing husbandry TYPE, and own the `injectedTypes` set that is the
    single source of truth aligning inject-, build-, and warn-scope.

    A strawless husbandry (any type/animal -- sheep, all pasture variants, chicken,
    modded) declares no straw producer, so nothing reads straw and no manure is made.
    This module supplies the missing husbandryStraw spec at type-validation time; the
    instance-level Storage + stations that make it collectable are built by RmStrawSink
    (the instance half), keyed off the set this module records.

    STRUCTURAL predicate -- NO literal type name: a type qualifies iff it carries the
    `husbandry` + `husbandryFood` specs (it IS an animal-feeding husbandry) and LACKS
    `husbandryStraw` (it has no native straw producer). Barns / native-straw types are
    excluded by the lacks-husbandryStraw clause and never enter the injected set.

    Injecting an abstract parent is INERT: the engine resolves inheritance when a child
    type is registered (the child copies its parent's spec list at that point), which
    happens BEFORE this validateTypes prepend runs -- so injecting onto an abstract
    parent never propagates to its children. Coverage is genuinely per-concrete-type:
    each strawless type must independently match the predicate. The lacks-husbandryStraw
    clause also doubles as the dup guard (a type carrying the spec natively is skipped, so
    addSpecialization never errors "already exists"). Load-order caveat: a mod-added
    husbandry type registered AFTER our prepend is not covered that load (re-derived
    every load).

    Runs per-peer (never server-gated) so clients build the same type shape as the host.

    Author: Ritter
]]

-- Module table doubles as the install-guard home (survives re-source in testing).
RmSpecInjector = RmSpecInjector or {}

-- Set of placeable type names we injected husbandryStraw onto (strawless husbandries) --
-- the single source of truth aligning inject-, build-, and warn-scope. Accumulated by
-- injectStraw at type-validation time (before any instance loads); read cross-module via
-- RmSpecInjector.isInjected. A native-straw type is never in this set (the inject
-- predicate excludes it), so it is never built on -- no double-wire.
--
-- Lifetime: RESET on map unload (the BaseMission.delete append below), NOT at the top of
-- injectStraw. The engine wipes its registered types every unload, so the set must be
-- per-map too -- a teardown reset keeps it aligned without staleness across a
-- return-to-menu + reload. It is NOT cleared inside injectStraw so that in-load
-- accumulation stays correct even if validateTypes ever runs twice in one load (a mid-load
-- clear would drop already-injected types, since our own inject makes shouldInject false
-- on the second pass).
RmSpecInjector.injectedTypes = RmSpecInjector.injectedTypes or {}

-- Own logger: the `Log` in main.lua is a file-local and is not visible here.
local Log = RmLogging.getLogger("ManureForAll")

local SPEC_NAME = "husbandryStraw"

-- ============================================================================
-- SPEC INJECTION
--
-- Prepended to TypeManager.validateTypes (runs before types are finalized) so
-- husbandryStraw is on every strawless husbandry type when instances are built.
-- Idempotent; runs per-peer.
-- ============================================================================

---True if a type ENTRY is a strawless, food-bearing husbandry we should inject onto:
--- carries `husbandry` + `husbandryFood` and lacks a native `husbandryStraw` producer.
--- Pure (reads only entry.specializationsByName); exposed for the unit test.
---@param entry table a TypeManager type entry (has specializationsByName)
---@return boolean
local function shouldInject(entry)
    local specs = entry ~= nil and entry.specializationsByName or nil
    if specs == nil then
        return false
    end
    return specs.husbandry ~= nil and specs.husbandryFood ~= nil and specs.husbandryStraw == nil
end

---Add husbandryStraw to every strawless food-bearing husbandry type before types are
--- finalized, recording each injected type name in RmSpecInjector.injectedTypes. A type
--- is recorded ONLY on an addSpecialization SUCCESS (a false return -> WARNING, not in the
--- set) so set membership never claims an injection that did not happen.
---@param typeManager table the TypeManager validateTypes was called on
local function injectStraw(typeManager)
    if typeManager == nil or typeManager.typeName ~= "placeable" then
        return
    end

    -- pairs() order is arbitrary, but only SET MEMBERSHIP (not iteration order) feeds the build
    -- gate / warn sweep, and membership is order-independent -- so this stays per-peer deterministic.
    local injected = 0
    for typeName, entry in pairs(typeManager:getTypes()) do
        if shouldInject(entry) then
            if typeManager:addSpecialization(typeName, SPEC_NAME) then
                RmSpecInjector.injectedTypes[typeName] = true
                injected = injected + 1
                Log:debug("injected %s onto %s", SPEC_NAME, typeName)
            else
                Log:warning("addSpecialization(%s, %s) returned false", typeName, SPEC_NAME)
            end
        end
    end
    Log:info("straw-spec injection: %d strawless husbandry type(s) wired", injected)
end

---Cross-module read of the injected set (dynamic -- never capture the table reference,
--- which the teardown reset replaces). RmStrawSink's build gate and warning sweep key on
--- this so build-scope always matches inject-scope.
---@param typeName string|nil placeable type name
---@return boolean
function RmSpecInjector.isInjected(typeName)
    return typeName ~= nil and RmSpecInjector.injectedTypes[typeName] == true
end

-- ============================================================================
-- LIFECYCLE
-- ============================================================================

---BaseMission.delete append: RESET the injected-type set on map unload (the engine wipes
--- its registered types too, so the set is per-map). Replaces the PoC's deleteMap reset.
local function onDeleteMap()
    RmSpecInjector.injectedTypes = {}
end

-- Expose the pure predicate + the loop body for the fakes unit test. injectStraw takes its
-- typeManager as a param so the test drives it off a fake.
RmSpecInjector.shouldInject = shouldInject
RmSpecInjector.injectStraw = injectStraw

-- ============================================================================
-- INSTALL (top-level, guarded once per process)
--
-- Wrap validateTypes before types finalize (source time). Guarded once so re-sourcing
-- during testing cannot double-wrap or double-append the teardown reset.
-- ============================================================================

if not RmSpecInjector.installed then
    TypeManager.validateTypes = Utils.prependedFunction(TypeManager.validateTypes, injectStraw)
    BaseMission.delete = Utils.appendedFunction(BaseMission.delete, onDeleteMap)
    RmSpecInjector.installed = true
end
