--[[
    RmHeapConnector.lua

    Connects the manure station of each mod-wired husbandry to player-placed manure heaps in range,
    and warns when a husbandry has no heap to catch its manure.

    A heap placed after its husbandry connects on its own. This module covers the other orders:
      * a server-only pass on SAVEGAME_LOADED (placeables are not loaded yet at loadMapFinished);
      * a scoped pass when a husbandry is placed after existing heaps;
      * a re-sweep when a heap is deleted, so a husbandry that lost its last heap warns again;
      * a re-sweep when a heap is placed, clearing the warned flag of a husbandry it connected.

    Rules: wire on the server only (storage links replicate to clients); wire only stations that
    carry our MARKER; skip pairs already linked; always pass the heap's world position to the range
    query.

    No heap in range means produced manure is discarded every hour. Each heap-less, player-owned
    husbandry logs one warning, again on every load, and re-arms once a heap connects. The
    on-screen notice fires only for in-session changes and never on a dedicated server.

    Author: Ritter
]]

-- Module table doubles as the install-guard home (survives re-source in testing).
RmHeapConnector = RmHeapConnector or {}

-- Paired with the SAVEGAME_LOADED subscription; guards unsubscribe on map delete.
RmHeapConnector.subscribed = RmHeapConnector.subscribed or false

-- Own logger: the `Log` in main.lua is a file-local and is not visible here.
local Log = RmLogging.getLogger("ManureForAll")

local MARKER = RmManureShared.MARKER   -- shared marker on our Storage + both stations
local NOHEAP_WARNED = "rmNoHeapWarned" -- one-time no-heap warning flag, set on the husbandry placeable

-- ============================================================================
-- ENGINE / REGISTRY SEAMS
--
-- Read INDIRECTLY through the module table so the in-game suite can point them at fakes to drive
-- the reconnect passes WITHOUT reassigning the engine globals. Ritter convention: the FS25
-- mod sandbox (setfenv) makes a bare `g_xxx = nil` a no-op
-- (the read falls through __index to the still-present real global), and mutating the LIVE
-- g_server / g_dedicatedServer mid-game is unsafe -- so the server / dedicated-server GATES read
-- through these seams and the suite flips the seam, never the global. Container collaborators
-- (placeables / storageSystem / notifier) inject via the `deps` param instead; the world-position /
-- node-liveness / registry reads that the frozen-signature wireHeapToOurStations also needs live
-- here. Default to the real engine + shared resolver; set unconditionally so a re-source restores.
-- ============================================================================

RmHeapConnector.entityExists = entityExists             -- engine node liveness
RmHeapConnector.getWorldTranslation = getWorldTranslation -- engine node world position

---Server-gate seam: true on the server/host (storage wiring is server-authoritative). Default is
--- exactly `g_server ~= nil` (the frozen server-only gate) -- the suite flips it to drive the
--- client-no-op asserts without reassigning g_server.
---@return boolean
function RmHeapConnector.isServer()
    return g_server ~= nil
end

---Dedicated-server seam: true on a headless dedicated server (no HUD). Default `g_dedicatedServer
--- ~= nil` -- the suite flips it for the dedi-toast-suppression assert without reassigning the global.
---@return boolean
function RmHeapConnector.isDedicatedServer()
    return g_dedicatedServer ~= nil
end

---Resolve the MANURE fill-type index via the shared resolver (manure is its SECOND return).
--- nil = unavailable or enum-vs-manager inconsistent (RmManureShared already logged the specifics);
--- the caller aborts its pass with a call-site WARNING so the skip stays diagnosable.
---@return integer|nil manure
function RmHeapConnector.resolveManure()
    local _, manure = RmManureShared.resolveFillTypes()
    return manure
end

-- ============================================================================
-- COLLABORATOR SEAM (optional param, defaults to the live game)
-- ============================================================================

---The live container collaborators the passes read. A nil `deps` anywhere below means "read the
--- live game"; the suite passes a fake deps table (fake placeables list, recording storageSystem,
--- notification recorder) so it drives the passes as params, not global swaps.
---@return table deps { placeables, storageSystem, notifier }
local function liveDeps()
    local mission = g_currentMission
    local placeables = (mission ~= nil and mission.placeableSystem ~= nil)
        and mission.placeableSystem.placeables or nil
    return {
        placeables = placeables,
        storageSystem = mission ~= nil and mission.storageSystem or nil,
        notifier = mission, -- exposes addIngameNotification (the local host HUD)
    }
end

-- ============================================================================
-- HEAP + STATION HELPERS (pure -- unit tested)
-- ============================================================================

---Return the manure-heap Storage a placeable owns, or nil if it is not a manure heap. Nil-guards
--- BOTH hops (spec_manureHeap and its manureHeap) so a DLC/modded heap that exposes the spec but
--- no storage (mid-load) is skipped, not nil-crashed.
---@param placeable table
---@return table|nil heapStorage
local function getHeapStorage(placeable)
    local spec = placeable ~= nil and placeable.spec_manureHeap or nil
    if spec == nil then
        return nil
    end
    return spec.manureHeap -- the ManureHeap Storage, or nil while mid-load
end

---True only for a husbandry whose manure station WE own: not in the ERROR load state, FULLY
--- wired (our MARKED Storage AND UnloadingStation AND LoadingStation). With no type gate, the
--- station marker is what keeps this off base/other stations. loadingState is a FIELD, not a getter.
---@param self table the placeable
---@return boolean
local function isOurWiredHusbandry(self)
    if self == nil or self.spec_husbandry == nil then
        return false
    end
    if PlaceableLoadingState ~= nil and self.loadingState == PlaceableLoadingState.ERROR then
        return false
    end
    local h = self.spec_husbandry
    return h.storage ~= nil and h.storage[MARKER] == true
        and h.unloadingStation ~= nil and h.unloadingStation[MARKER] == true
        and h.loadingStation ~= nil
end

---Count linked external storages that accept MANURE (a linked straw extension is not a heap). 0 if manure nil.
---@param station table|nil the husbandry's manure UnloadingStation
---@param internalStorage table|nil the husbandry's own internal Storage
---@param manure integer|nil the resolved MANURE fill-type index
---@return integer
local function connectedHeapCount(station, internalStorage, manure)
    if manure == nil then
        return 0
    end
    if station == nil or station.targetStorages == nil then
        return 0
    end
    local n = 0
    for storage, _ in pairs(station.targetStorages) do
        if storage ~= internalStorage
            and storage.fillTypes ~= nil and storage.fillTypes[manure] ~= nil then
            n = n + 1
        end
    end
    return n
end

-- ============================================================================
-- CORE WIRING (pure given a storageSystem -- unit tested)
-- ============================================================================

---Wire a heap's storage into OUR in-range manure UnloadingStations. Given the heap storage, its
--- owner farm and WORLD position, ask the storage system for the extendable stations in range and
--- for each that is OURS (marker), still alive (entityExists), and not already a target of this
--- heap (reverse-link idempotency), add the heap storage as a target. Optionally scope to a SINGLE
--- station (the husbandry-finalize variant).
---@param storageSystem table
---@param heapStorage table
---@param farmId integer
---@param hx number
---@param hy number
---@param hz number
---@param onlyStation table|nil when non-nil, wire ONLY this station (scoped husbandry reconnect)
---@return integer wired number of husbandry<->heap pairs newly wired
local function wireHeapToOurStations(storageSystem, heapStorage, farmId, hx, hy, hz, onlyStation)
    local stations = storageSystem:getExtendableUnloadingStationsInRange(heapStorage, farmId, hx, hy, hz)
    local wired = 0
    for _, station in ipairs(stations) do
        if station[MARKER] ~= true then
            -- Base barns' stations come back in the same pool -- NEVER wire them (base's job).
            Log:debug("reconnect skip: station is not ours (base barn) -- not wiring")
        elseif onlyStation ~= nil and station ~= onlyStation then
            -- Scoped (husbandry-finalize) variant: another husbandry's station, not this one -- quiet skip.
        elseif not RmHeapConnector.entityExists(station.rootNode) then
            -- Never touch a freed station node.
            Log:debug("reconnect skip: station node no longer exists -- not wiring")
        elseif heapStorage.unloadingStations[station] ~= nil then
            -- Already linked: skip, so each pair is added exactly once.
            Log:debug("reconnect skip: pair already wired -- idempotent")
        else
            storageSystem:addStorageToUnloadingStation(heapStorage, station)
            wired = wired + 1
        end
    end
    return wired
end

-- ============================================================================
-- RECONNECT PASSES (server-only; read the live placeableSystem, hold no cached refs)
-- ============================================================================

---Shared reading pass: for each placed manure heap, wire it to our in-range manure stations.
--- Resolves+guards MANURE; skips a heap with no world node or one that does not carry MANURE.
--- onlyStation scopes to a single husbandry's station. deps inject the placeables/storageSystem.
---@param onlyStation table|nil
---@param deps table|nil
---@return integer pairsWired
---@return integer heapCount
local function wireAllHeaps(onlyStation, deps)
    deps = deps or liveDeps()
    local placeables, storageSystem = deps.placeables, deps.storageSystem
    if placeables == nil or storageSystem == nil then
        return 0, 0
    end
    local manure = RmHeapConnector.resolveManure()
    if manure == nil then
        Log:warning("reconnect pass skipped: MANURE fill type unresolved")
        return 0, 0
    end
    local pairsWired, heapCount = 0, 0
    for _, placeable in ipairs(placeables) do
        local heapStorage = getHeapStorage(placeable)
        if heapStorage ~= nil then
            -- It is a manure heap. Verify it exposes a MANURE storage with a LIVE world node BEFORE
            -- reading its owner/position, so a half-deleted heap cannot yield a stale owner farm.
            local node = heapStorage.rootNode
            local hasManure = heapStorage.unloadingStations ~= nil
                and heapStorage.fillTypes ~= nil and heapStorage.fillTypes[manure] ~= nil
            if not hasManure then
                Log:debug("reconnect skip: manure heap has no MANURE storage -- skipping")
            elseif node == nil or node == 0 or not RmHeapConnector.entityExists(node) then
                Log:debug("reconnect skip: manure heap node not live -- skipping")
            else
                heapCount = heapCount + 1
                local farmId = heapStorage:getOwnerFarmId()
                local hx, hy, hz = RmHeapConnector.getWorldTranslation(node)
                pairsWired = pairsWired
                    + wireHeapToOurStations(storageSystem, heapStorage, farmId, hx, hy, hz, onlyStation)
            end
        end
    end
    return pairsWired, heapCount
end

---Best-effort on-screen notification on the local host (SP), COALESCED to one toast per sweep (not
--- one per husbandry). Nil-guarded for a dedicated server (no HUD) and pre-mission windows; the
--- per-husbandry Log:warning is the guaranteed record. MP per-farm delivery is a later phase.
---@param count integer how many husbandries were newly found heap-less this sweep
---@param deps table|nil supplies the notifier (defaults to the live host)
local function notifyNoHeap(count, deps)
    if count <= 0 then
        return
    end
    -- A dedicated server has no HUD to show it; the per-husbandry Log:warning is the record there.
    if RmHeapConnector.isDedicatedServer() then
        return
    end
    deps = deps or liveDeps()
    local notifier = deps.notifier
    if notifier == nil or notifier.addIngameNotification == nil
        or FSBaseMission == nil or FSBaseMission.INGAME_NOTIFICATION_CRITICAL == nil then
        return
    end
    local text
    if count == 1 then
        text = "ManureForAll: place a manure heap near your animal husbandry to collect its manure "
            .. "-- otherwise straw is consumed but the manure is lost."
    else
        -- This branch is only reached when count > 1, so the plural is unconditional.
        text = string.format("ManureForAll: %d husbandries have no manure heap in range -- straw is "
            .. "consumed but the manure is lost. Place a manure heap near each.", count)
    end
    notifier:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL, text)
end

---True only for a husbandry owned by a real farm; a map-preplaced one has no owner farm and never produces.
---@param husbandry table
---@return boolean
local function isPlayerOwnedHusbandry(husbandry)
    local h = husbandry.spec_husbandry
    local storage = h ~= nil and h.storage or nil
    if storage == nil or g_farmManager == nil then
        return false
    end
    return g_farmManager:getFarmById(storage:getOwnerFarmId()) ~= nil
end

---Decide whether a husbandry should warn about lost manure, and record the per-husbandry state.
--- Logs the honest straw-loss warning but does NOT emit the on-screen toast (the caller coalesces
--- that). RE-ARMS the one-time flag whenever the husbandry currently HAS a connected manure-capable
--- target, so a husbandry that later loses its last heap warns again. Warns only for player-owned
--- husbandries that can actually produce. Callers resolve MANURE and never call with nil (an
--- unclassifiable world must not warn). Returns true if it NEWLY warned this call.
---@param husbandry table the placeable
---@param manure integer the resolved MANURE fill-type index
---@return boolean warned
local function warnIfHeapless(husbandry, manure)
    local h = husbandry.spec_husbandry
    if h == nil then
        return false -- defense-in-depth: callers gate via isOurWiredHusbandry, but never nil-deref here
    end
    if connectedHeapCount(h.unloadingStation, h.storage, manure) ~= 0 then
        husbandry[NOHEAP_WARNED] = nil -- re-arm: manure is being collected again, clear any prior warning
        return false
    end
    if not isPlayerOwnedHusbandry(husbandry) then
        return false -- NOBODY/EVERYONE preplaced husbandry: produces nothing, do not false-warn
    end
    if husbandry[NOHEAP_WARNED] == true then
        return false -- already warned since it last had a heap
    end
    husbandry[NOHEAP_WARNED] = true
    Log:warning("husbandry '%s' has no manure heap in range -- straw is consumed but manure is LOST each hour; "
        .. "place a manure heap near it to collect it", tostring(husbandry:getName()))
    return true
end

---Log-warn each wired husbandry newly found heap-less. Emits no toast; the caller decides.
---@param deps table|nil
---@return integer warned husbandries newly found heap-less this sweep
local function warnHeaplessHusbandries(deps)
    deps = deps or liveDeps()
    local placeables = deps.placeables
    if placeables == nil then
        Log:trace("<<< warnHeaplessHusbandries = 0 (no placeables)")
        return 0
    end
    local manure = RmHeapConnector.resolveManure()
    if manure == nil then
        Log:debug("heapless sweep skipped: MANURE fill type unresolved -- cannot classify heap targets")
        return 0
    end
    local warned = 0
    for _, placeable in ipairs(placeables) do
        if isOurWiredHusbandry(placeable) and warnIfHeapless(placeable, manure) then
            warned = warned + 1
        end
    end
    Log:trace("<<< warnHeaplessHusbandries = %d", warned)
    return warned
end

---Server-only post-load pass: wire all our husbandry<->heap pairs, then log heap-less ones (no toast).
---@param deps table|nil injectable collaborators (defaults to the live game)
function RmHeapConnector.reconnectAll(deps)
    if not RmHeapConnector.isServer() then
        return -- storage wiring is server-authoritative; NEVER wire on a client
    end
    local pairsWired, heapCount = wireAllHeaps(nil, deps)
    Log:info("reconnect: wired %d husbandry<->heap pair(s) across %d manure heap(s)", pairsWired, heapCount)
    local warned = warnHeaplessHusbandries(deps)
    Log:debug("reconnect: %d heap-less husbandr%s logged, no on-screen notification at load",
        warned, warned == 1 and "y" or "ies")
end

---Server-only scoped pass for one husbandry (appended onFinalizePlacement): pull in existing
--- in-range heaps for a husbandry placed AFTER them. A husbandry placed BEFORE its heap is handled
--- by base auto-connect at the heap's finalize. Warns only AFTER the savegame has fully loaded --
--- during load a husbandry can finalize before its saved heap, and the post-load sweep covers those.
---@param husbandry table the placeable
---@param deps table|nil injectable collaborators (defaults to the live game)
function RmHeapConnector.reconnectHusbandry(husbandry, deps)
    if not RmHeapConnector.isServer() then
        return -- server-authoritative
    end
    if not isOurWiredHusbandry(husbandry) then
        return
    end
    local pairsWired = wireAllHeaps(husbandry.spec_husbandry.unloadingStation, deps)
    if pairsWired > 0 then
        Log:info("reconnect: husbandry '%s' picked up %d in-range heap(s) at placement",
            tostring(husbandry:getName()), pairsWired)
    end
    if RmHeapConnector.savegameLoaded then
        -- Resolve for the scoped warn; wireAllHeaps above already WARNINGed when MANURE is
        -- unresolved, so an unclassifiable world just skips the warn (never a false loss warning).
        local manure = RmHeapConnector.resolveManure()
        if manure ~= nil and warnIfHeapless(husbandry, manure) then
            notifyNoHeap(1, deps)
        end
    end
end

-- ============================================================================
-- DIAGNOSTIC (mfaDump heaps -- delegated to by the console shell)
-- ============================================================================

---`mfaDump heaps`: report each wired husbandry's manure-collection wiring state. Reads no cached
--- refs. Per wired husbandry logs the verbatim heap-diag INFO line; returns the summary string.
---@return string
function RmHeapConnector.consoleDump()
    local mission = g_currentMission
    if mission == nil or mission.placeableSystem == nil or mission.storageSystem == nil then
        return "mfaDump heaps: no mission/placeableSystem yet -- load a save first"
    end
    local manure = RmHeapConnector.resolveManure()
    local storageSystem = mission.storageSystem
    local found = 0
    for _, placeable in ipairs(mission.placeableSystem.placeables) do
        if isOurWiredHusbandry(placeable) then
            found = found + 1
            local h = placeable.spec_husbandry
            local station = h.unloadingStation
            local inPool = storageSystem.extendableUnloadingStations ~= nil
                and storageSystem.extendableUnloadingStations[station] ~= nil
            local manureCapStr = "n/a" -- MANURE unresolved (broken registry) -> not a real "0"
            local heapCountStr = "n/a" -- same: an unclassifiable world cannot count heaps
            if manure ~= nil then
                if h.storage.capacities ~= nil then
                    manureCapStr = string.format("%.0f", h.storage.capacities[manure] or 0)
                end
                heapCountStr = tostring(connectedHeapCount(station, h.storage, manure))
            end
            Log:info("heap-diag: husbandry '%s' (%s) -- MANURE cap=%s supportsExtension=%s inExtendablePool=%s connectedHeaps=%s",
                tostring(placeable:getName()), tostring(placeable.typeName), manureCapStr,
                tostring(station.supportsExtension), tostring(inPool), heapCountStr)
        end
    end
    if found == 0 then
        return "mfaDump heaps: no wired husbandry found"
    end
    return string.format(
        "mfaDump heaps: %d wired husbandr%s -- see log for MANURE cap / extendable-pool / heap-connection state",
        found, found == 1 and "y" or "ies")
end

-- ============================================================================
-- LIFECYCLE HOOK BODIES
-- ============================================================================

---SAVEGAME_LOADED handler: fired AFTER all savegame placeables (husbandries + heaps) have loaded,
--- and published only on the server. Marks the game loaded so post-load fresh placements may warn,
--- then runs the server backstop reconnect + the log-only heap-less warning sweep. `deps` is the
--- injectable-collaborator table; the live message publishes with NO args, so it
--- fires this with deps=nil -> the live game. The suite passes fakes to drive the pass.
---@param deps table|nil
function RmHeapConnector.onSavegameLoaded(self, deps)
    RmHeapConnector.savegameLoaded = true
    RmHeapConnector.reconnectAll(deps)
end

---Appended husbandry onFinalizePlacement: scoped reconnect, once the station exists and is found in range.
---@param self table the placeable
local function onHusbandryFinalizePlacement(self)
    RmHeapConnector.reconnectHusbandry(self)
end

---PlaceableManureHeap:onDelete (APPENDED, after base): base has already removed the deleted heap
--- from our stations' target lists, so re-run the heap-less sweep -- a husbandry that just lost its
--- LAST heap warns again (re-armed). Server-only; skipped during teardown (savegameLoaded false).
--- The engine calls this with the heap placeable as `self` (unused -- the sweep re-reads the live
--- world); `deps` is the injectable-collaborator seam (nil in production, fakes in the suite).
---@param _ table the heap placeable (unused)
---@param deps table|nil
local function onManureHeapDelete(_, deps)
    if not RmHeapConnector.isServer() then
        return
    end
    if not RmHeapConnector.savegameLoaded then
        return -- teardown heap-deletes during BaseMission.delete must not sweep
    end
    notifyNoHeap(warnHeaplessHusbandries(deps), deps)
end

---PlaceableManureHeap:onFinalizePlacement (APPENDED, after base): the re-arm HARDENING. Base
--- auto-connect wires this newly placed heap to our in-range stations but runs NO mod code, so a
--- previously-warned husbandry that just gained the heap keeps rmNoHeapWarned set. Re-run the sweep
--- so warnIfHeapless re-arms (clears) the flag while the heap is connected -- otherwise a later
--- delete of that heap re-sweeps into an already-set flag and the loss resumes silently. Server-only,
--- post-load only; idempotent with base auto-connect. `self` (the just-placed heap) is unused -- the
--- sweep re-reads the live world; `deps` is the injectable seam (nil in production).
---@param _ table the heap placeable (unused)
---@param deps table|nil
local function onManureHeapFinalize(_, deps)
    if not RmHeapConnector.isServer() then
        return
    end
    if not RmHeapConnector.savegameLoaded then
        return -- during-load finalizes: the post-load sweep arms the state
    end
    notifyNoHeap(warnHeaplessHusbandries(deps), deps)
end

---BaseMission.loadMapFinished append: reset the per-load flag and subscribe the post-load pass
--- (flag-paired). loadMapFinished fires before SAVEGAME_LOADED, so the subscription is in place
--- when it fires.
local function onLoadMapFinished()
    RmHeapConnector.savegameLoaded = false
    if RmHeapConnector.subscribed then
        return
    end
    if g_messageCenter == nil then
        return
    end
    g_messageCenter:subscribe(MessageType.SAVEGAME_LOADED, RmHeapConnector.onSavegameLoaded, RmHeapConnector)
    RmHeapConnector.subscribed = true
end

---BaseMission.delete append: mark unloaded FIRST (so teardown heap-deletes never sweep), then drop
--- the subscription (flag-paired).
local function onDeleteMap()
    RmHeapConnector.savegameLoaded = false
    if not RmHeapConnector.subscribed then
        return
    end
    if g_messageCenter ~= nil then
        g_messageCenter:unsubscribe(MessageType.SAVEGAME_LOADED, RmHeapConnector)
    end
    RmHeapConnector.subscribed = false
end

-- Expose the pure table-manipulation functions for the fakes unit test. No engine state is touched
-- at call time beyond the seams / injected collaborators the test provides.
RmHeapConnector.getHeapStorage = getHeapStorage
RmHeapConnector.isOurWiredHusbandry = isOurWiredHusbandry
RmHeapConnector.connectedHeapCount = connectedHeapCount
RmHeapConnector.wireHeapToOurStations = wireHeapToOurStations
-- The two appended manure-heap hook bodies (server + savegameLoaded gated), exposed so the suite
-- drives them directly.
RmHeapConnector.onManureHeapDelete = onManureHeapDelete
RmHeapConnector.onManureHeapFinalize = onManureHeapFinalize

-- ============================================================================
-- INSTALL (top-level, guarded once per process)
--
-- Husbandry finalize is appended so the station already exists and is found in range. The heap
-- hooks install only when a heap type is loaded. The load-time pass runs from the SAVEGAME_LOADED
-- subscription. Guarded once so re-sourcing during testing cannot double-wrap.
-- ============================================================================

if not RmHeapConnector.installed then
    PlaceableHusbandry.onFinalizePlacement =
        Utils.appendedFunction(PlaceableHusbandry.onFinalizePlacement, onHusbandryFinalizePlacement)
    if PlaceableManureHeap ~= nil then
        if PlaceableManureHeap.onDelete ~= nil then
            PlaceableManureHeap.onDelete = Utils.appendedFunction(PlaceableManureHeap.onDelete, onManureHeapDelete)
        end
        if PlaceableManureHeap.onFinalizePlacement ~= nil then
            PlaceableManureHeap.onFinalizePlacement =
                Utils.appendedFunction(PlaceableManureHeap.onFinalizePlacement, onManureHeapFinalize)
        end
    end
    BaseMission.loadMapFinished = Utils.appendedFunction(BaseMission.loadMapFinished, onLoadMapFinished)
    BaseMission.delete = Utils.appendedFunction(BaseMission.delete, onDeleteMap)
    RmHeapConnector.installed = true
end
