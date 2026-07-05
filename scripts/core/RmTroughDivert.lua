--[[
    RmTroughDivert.lua

    Player-facing straw tip point on mod-wired husbandries (permanent, shipping).

    RmSpecInjector + RmStrawSink build a runtime STRAW+MANURE Storage +
    UnloadingStation + LoadingStation on strawless husbandries (any type/animal), but straw
    only enters via the host-only DEBUG command (mfaAddStraw). This module gives the player a
    PHYSICAL way to load straw with no i3d edit: a husbandry's existing food-trough
    UnloadTrigger has a plain closure `target`; wrapping that target to ACCEPT straw and DIVERT
    it to the husbandry's straw UnloadingStation turns the food trough into a real bulk-straw
    tip point. FOOD still routes to addFood unchanged; straw is branched to the straw storage
    BEFORE addFood, so it never lands in the food fill levels. The gate is the MARKER on our
    Storage/stations, not a type name -- every mod-wired husbandry (chicken, sheep, pasture,
    modded) gets the divert.

    For each FULLY wired husbandry, at an APPENDED onFinalizePlacement (after RmStrawSink's
    prepended finalize built the station AND base finalize wired it, AND after the trough was
    built in onLoad):
      * straw-enable EVERY food trough's own `fillTypes` gate (they are per-trough);
      * wrap the SHARED closure target ONCE (idempotency marker on the target) so straw is
        allowed, sized, and deposited through the straw UnloadingStation, read LIVE.

    Correctness points this productionizes over the raw mechanism:
      * a husbandry with a NATIVE straw intake (RmStrawSink samples + records the
        per-placeable flag before augmenting) keeps its own intake: the divert is skipped
        whole, so there is never a double straw path on one husbandry;
      * the trough `target` is ONE closure table shared across every feedingTrough, but each
        trough keeps its OWN `fillTypes` -- so wrap the target once yet set fillTypes on all
        (a nil fillTypes table already accepts all types and is NOT mutated);
      * the wrapped getFreeCapacity FORWARDS farmId (a nil farm reads access-blind, which
        would let a client predict capacity the farm-gated server deposit then refuses);
      * the wrapped addFillLevelFromTool deposits as the tipping farm, falling back to the
        storage owner for a nil/AI/script farm, and never calls the station with a nil farm;
        it also rejects a non-finite or non-positive delta before the station's assert;
      * all three wrapped closures read the station LIVE and defer to the base original when
        it is nil (mid-delete / pre-replication), so straw is never silently half-accepted.

    Applied DETERMINISTICALLY on ALL peers (never server-gated): the trough target exists on
    every peer, the client's discharge prediction reads the wrapped getIsFillTypeAllowed /
    getFreeCapacity, and the authoritative fill runs server-side through the station and
    replicates via base storage sync. MP verification is the consolidated slice-5 session.
    Bulk straw only (the food trough has no bale trigger). A modded/pasture trough with a
    non-standard shape (no closure target, or zero troughs -> ERROR load state) is skipped by
    the existing guards -- straw intake applies where a compatible bulk food trough exists.

    Author: Ritter
]]

-- Module table doubles as the install-guard home (survives re-source in testing).
RmTroughDivert = RmTroughDivert or {}

-- Own logger: the `Log` in main.lua is a file-local and is not visible here.
local Log = RmLogging.getLogger("ManureForAll")

-- The mod-vs-native discriminant on our Storage / stations (shared home).
local MARKER = RmManureShared.MARKER
-- Marks a trough target we already wrapped this load (per-load idempotency).
local FOODROUTE_MARKER = "rmStrawFoodroute"

-- ============================================================================
-- GUARD
-- ============================================================================

---True only for a husbandry we may wire straw intake onto: not in the ERROR load state,
--- FULLY wired (our marked Storage AND UnloadingStation AND LoadingStation). Requiring all
--- three avoids wiring straw intake onto a half-built husbandry that would accept straw but
--- never consume it, and (with no type gate) the MARKER is what keeps this off base barns'
--- own storage. loadingState is a FIELD, not a getter.
---@param self table the placeable
---@return boolean
local function isWiredHusbandry(self)
    if self == nil then
        return false
    end
    if PlaceableLoadingState ~= nil and self.loadingState == PlaceableLoadingState.ERROR then
        return false
    end
    local h = self.spec_husbandry
    return h ~= nil
        and h.storage ~= nil and h.storage[MARKER] == true
        and h.unloadingStation ~= nil
        and h.loadingStation ~= nil
end

-- ============================================================================
-- FOODROUTE OVERRIDE
-- ============================================================================

---Wrap a wired husbandry's food-trough closure target so bulk straw tipped at the food
--- trough diverts to the husbandry's straw UnloadingStation, and straw-enable every trough's
--- own fillTypes gate. Idempotent within a load via a marker on the shared target; re-applied
--- on every load because the trough target is rebuilt fresh each onLoad (not persisted).
---@param self table the placeable
local function applyFoodroute(self)
    -- A husbandry that brought its OWN straw intake (flag sampled by RmStrawSink BEFORE it
    -- added STRAW to the station) keeps it -- never add a second straw path via the trough.
    if self[RmManureShared.NATIVE_STRAW_INTAKE] == true then
        Log:debug("foodroute: %s has a native straw intake -- divert skipped", tostring(self.typeName))
        return
    end

    local straw = RmManureShared.resolveFillTypes()
    if straw == nil then
        Log:warning("foodroute: STRAW fill type unresolved -- skipped")
        return
    end

    local fs = self.spec_husbandryFood
    if fs == nil or fs.feedingTroughs == nil then
        Log:warning("foodroute: %s has no food trough -- skipped", tostring(self.typeName))
        return
    end

    -- The trough `target` is ONE closure table shared by every feedingTrough; wrap it once.
    local firstTrough = fs.feedingTroughs[1]
    local tgt = firstTrough ~= nil and firstTrough.target or nil
    if tgt == nil then
        Log:warning("foodroute: %s food trough has no target -- skipped", tostring(self.typeName))
        return
    end
    if tgt[FOODROUTE_MARKER] == true then
        Log:debug("foodroute: shared target already wrapped -- skip")
        return
    end
    -- Guard the target exposes all three closures BEFORE wrapping OR advertising STRAW, so a
    -- modded/non-standard trough is skipped whole -- never a dangling fillTypes[STRAW] that
    -- base getIsFillTypeSupported would nil-call on the missing closure.
    if tgt.getIsFillTypeAllowed == nil or tgt.addFillLevelFromTool == nil or tgt.getFreeCapacity == nil then
        Log:warning("foodroute: %s food trough target missing a closure -- skipped", tostring(self.typeName))
        return
    end

    -- Straw-enable EVERY trough's own fillTypes gate (per-trough, unlike the shared target),
    -- else tipping at a second trough whose fillTypes gate is populated is rejected by
    -- getIsFillTypeSupported (a nil fillTypes table already accepts all types).
    for _, trough in ipairs(fs.feedingTroughs) do
        if trough.fillTypes ~= nil then
            trough.fillTypes[straw] = true
        end
    end

    -- Read the straw UnloadingStation LIVE on every call (never a captured handle): during a
    -- mid-delete / pre-replication window it is nil, and each wrapped closure then defers to
    -- the base original -- so straw is neither allowed, nor sized, nor deposited (consistent,
    -- no "looks accepted, moves 0" state).
    local function station()
        local h = self.spec_husbandry
        return h ~= nil and h.unloadingStation or nil
    end

    local origAllow = tgt.getIsFillTypeAllowed
    local origAdd = tgt.addFillLevelFromTool
    local origFree = tgt.getFreeCapacity

    tgt.getIsFillTypeAllowed = function(s, fillTypeIndex, ...)
        if fillTypeIndex == straw and station() ~= nil then
            return true
        end
        return origAllow(s, fillTypeIndex, ...)
    end

    tgt.getFreeCapacity = function(s, fillTypeIndex, farmId, ...)
        local st = station()
        if fillTypeIndex == straw and st ~= nil then
            -- Forward farmId: the station treats a nil farm as access-blind, so dropping it
            -- lets the client predict capacity the farm-gated server deposit then refuses.
            return st:getFreeCapacity(fillTypeIndex, farmId)
        end
        return origFree(s, fillTypeIndex, farmId, ...)
    end

    tgt.addFillLevelFromTool = function(s, farmId, delta, fillTypeIndex, ...)
        local st = station()
        if fillTypeIndex == straw and st ~= nil then
            -- The straw station asserts 0 <= delta; a nil/negative/non-finite delta (e.g. from
            -- a modded tool/trigger) would hard-crash or mis-clamp it, where the base addFood
            -- path tolerates more. Reject non-finite (NaN passes <= 0; +inf passes the assert)
            -- and non-positive deltas -- consistent with the nil-farm guard just below and with
            -- the finite-only validation on the mfaAddStraw console path.
            if type(delta) ~= "number" or delta ~= delta or delta == math.huge or delta <= 0 then
                return 0
            end
            local h = self.spec_husbandry
            -- Deposit as the TIPPING farm (so a cross-farm tip is correctly access-denied),
            -- falling back to the storage owner for a nil/AI/script farm; never a nil farm.
            local depositFarm = farmId or (h.storage ~= nil and h.storage:getOwnerFarmId() or nil)
            if depositFarm == nil then
                Log:warning("foodroute: nil farm on straw divert -- skipped")
                return 0
            end
            local moved = st:addFillLevelFromTool(depositFarm, delta, fillTypeIndex, ...)
            if (moved or 0) <= 0 then
                -- Attribute a 0-liter divert (dev-only): the trigger farm gate is fill-type-
                -- agnostic, so name farm-access vs storage-full here.
                local access = st.getIsFillAllowedFromFarm == nil or st:getIsFillAllowedFromFarm(depositFarm)
                local free = st:getFreeCapacity(fillTypeIndex, depositFarm) or 0
                local why = (not access) and "farm access denied" or (free <= 0 and "storage full" or "other")
                Log:debug("foodroute: 0 L straw moved (farm=%s access=%s free=%.0f) -- %s",
                    tostring(depositFarm), tostring(access), free, why)
            end
            return moved or 0 -- NEVER addFood for straw; always a number to the fill accountant
        end
        return origAdd(s, farmId, delta, fillTypeIndex, ...)
    end

    tgt[FOODROUTE_MARKER] = true
    Log:info("foodroute: %s food trough accepts+diverts straw (%d trough(s))",
        tostring(self.typeName), #fs.feedingTroughs)
end

-- ============================================================================
-- LIFECYCLE WRAPPER
-- ============================================================================

---onFinalizePlacement (APPENDED, after base): for a fully wired husbandry, apply the
--- food-trough straw foodroute. Runs after RmStrawSink's prepended finalize builds the
--- station and base finalize wires it (addStorageToUnloadingStation populates the station's
--- targetStorages the divert needs).
---@param self table the placeable
local function onFinalizePlacement(self)
    if not isWiredHusbandry(self) then
        return
    end
    applyFoodroute(self)
end

-- Expose the pure table-manipulation functions + the idempotency marker for the fakes unit
-- test (see tests/RmTroughDivertTests.lua). No engine state is touched at call time beyond
-- the fakes the test injects.
RmTroughDivert.isWiredHusbandry = isWiredHusbandry
RmTroughDivert.applyFoodroute = applyFoodroute
RmTroughDivert.FOODROUTE_MARKER = FOODROUTE_MARKER

-- ============================================================================
-- INSTALL (top-level, guarded once per process)
--
-- APPENDED to onFinalizePlacement so it runs AFTER RmStrawSink's prepended finalize (which
-- builds the station) and base finalize (which wires it). Deterministic and per-peer -- NOT
-- server-gated: the client's discharge prediction must read the wrapped closures locally, and
-- the authoritative deposit runs server-side through the station. Guarded once so re-sourcing
-- during testing cannot double-wrap the finalize hook.
-- ============================================================================

if not RmTroughDivert.installed then
    PlaceableHusbandry.onFinalizePlacement =
        Utils.appendedFunction(PlaceableHusbandry.onFinalizePlacement, onFinalizePlacement)
    RmTroughDivert.installed = true
end
