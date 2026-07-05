--[[
    RmHeapConnector.lua

    Reconnect a mod-wired husbandry's manure UnloadingStation to in-range player-placed
    manure heaps, and warn honestly when there is no heap to catch the manure.

    RmStrawSink + RmTroughDivert build a runtime STRAW+MANURE Storage +
    UnloadingStation + LoadingStation on strawless husbandries, MARKER-tagged and registered in
    the extendable-station pool with the internal MANURE capacity at 0 (base-cattleshed-consistent).
    Produced manure then flows OUT to a player-placed external manure heap and is collected at the
    heap's own load trigger -- no building i3d edit, node-free on the husbandry side.

    Base husbandries auto-connect to in-range heaps at heap placement, but load-order can break that
    (a heap placed before the husbandry, a reload) -- so a load-order-proof reconnect pass is needed.
    This module is that safety net for OUR stations, self-contained:
      * a SERVER-ONLY post-load pass (MessageType.SAVEGAME_LOADED -- which fires AFTER savegame
        placeables load; BaseMission.loadMapFinished is the terrain-init callback and fires BEFORE
        them, so a pass there would see no placeables) rewires OUR husbandry<->heap pairs + warns;
      * an appended husbandry onFinalizePlacement pulls in existing in-range heaps for a husbandry
        placed AFTER a heap (heap-placed-after-husbandry is handled by base auto-connect at the
        heap's own finalize, which discovers our extendable husbandry station);
      * an appended PlaceableManureHeap onDelete re-sweeps so a husbandry that lost its last heap
        warns again;
      * an appended PlaceableManureHeap onFinalizePlacement re-sweep (a HARDENING over the
        prototype): base auto-connect runs no mod code, so a previously-warned husbandry
        that gains a heap keeps its one-time flag set and would NEVER re-warn after that heap is
        later deleted -- running the sweep on heap finalize re-arms the flag while connected.

    Correctness (verified in-game):
      * SERVER-ONLY (g_server): storage wiring is server-authoritative and replicates to clients
        via base storage sync; a client-side wire diverges target lists.
      * OURS-ONLY: getExtendableUnloadingStationsInRange returns ALL extendable stations incl.
        base barns'; wire only stations we marked (station[MARKER]) -- base barns are base's job,
        and re-publishing their links would desync.
      * IDEMPOTENT: addStorageToUnloadingStation re-publishes on every call, so skip a pair
        already wired (reverse-link heapStorage.unloadingStations[station] ~= nil).
      * the 5-arg getExtendableUnloadingStationsInRange(heapStorage, farmId, hx, hy, hz) with the
        heap's WORLD position -- the position is REQUIRED: a nil makes the in-range compare error,
        so we always resolve and pass it.
      * MANURE resolved via RmManureShared + guarded; entityExists(node) guarded (a reused node may
        be freed mid-delete); holds no cached refs (reads the live placeableSystem each pass).

    No heap in range = an honest loss: with internal MANURE capacity 0 and no connected heap the
    base producer consumes straw then discards the manure every hour (base-consistent), so a
    warning per player-owned heap-less husbandry tells the player to place a heap -- the loss is
    never shipped silently. The warning is one-time per husbandry while it stays heap-less (re-warns
    once per load: honest reminder), RE-ARMS when a heap connects, and fires again if the husbandry
    later loses its last heap. Fired only after the savegame is fully loaded, so a reload raises no
    false loss warnings. Dedicated-server players get no toast (log-only; a client notification needs
    a sync event, not yet implemented); a listen-server host may see coalesced toasts about other farms.

    Deviations from the prototype this module productionizes:
      * console lifecycle (addModEventListener + register/remove) NOT ported -- the console
        shell (RmManureConsole) owns registration; `mfaDump heaps` delegates here;
      * the `rmManureHeap reconnect` force-pass console action NOT ported -- save+reload is the
        contracted operator recovery (the SAVEGAME_LOADED pass re-derives all links);
      * the local resolveManureType NOT ported -- MANURE comes from RmManureShared.resolveFillTypes
        with a call-site WARNING when unresolved;
      * ADDED the heap-finalize re-arm sweep (hardening, above).

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

---Count the EXTERNAL manure-capable targets connected to a husbandry's manure
--- UnloadingStation: a targetStorage that is NOT the husbandry's own internal storage AND
--- lists MANURE among its fill types. The manure scoping is load-bearing: with the
--- augmented station's widened supported types, base finalize's extension pull can bring
--- NON-heap extension storages (e.g. a straw-capable silo extension) into targetStorages,
--- and counting one as a "heap" would silently suppress the honest manure-loss warning --
--- a manure-capable external target genuinely catches manure, so the fill-type test is
--- the exact semantic. Used by the diagnostic and the no-heap warning; a count of 0 is
--- the genuine "manure is destroyed" case. manure nil -> 0 (callers resolve + gate; an
--- unclassifiable world counts no heaps).
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
            -- Belt-and-suspenders: base delete unregisters the station from the pool, so a freed
            -- station should not appear here; guard anyway before touching its node.
            Log:debug("reconnect skip: station node no longer exists -- not wiring")
        elseif heapStorage.unloadingStations[station] ~= nil then
            -- Reverse-link idempotency: addStorageToUnloadingStation re-publishes every call.
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
    -- A dedicated server has no HUD (addIngameNotification -> hud:addSideNotification would nil-crash);
    -- the per-husbandry Log:warning is the record there. Per-farm client delivery is a later (MP) phase.
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

---True only for a husbandry owned by a REAL player farm, so it can house animals and actually
--- produce. A map-preplaced husbandry remapped EVERYONE->NOBODY at base finalize has no real owner
--- farm, never connects a heap, and produces nothing -- so it must not raise a false "place a heap"
--- warning.
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

---Sweep every wired husbandry, warn (once each since it last had a heap) any that has no connected
--- heap, and emit ONE coalesced on-screen notification for the whole batch. Bails when MANURE is
--- unresolved -- never warn on an unclassifiable world.
---@param deps table|nil
local function warnHeaplessHusbandries(deps)
    deps = deps or liveDeps()
    local placeables = deps.placeables
    if placeables == nil then
        return
    end
    local manure = RmHeapConnector.resolveManure()
    if manure == nil then
        Log:debug("heapless sweep skipped: MANURE fill type unresolved -- cannot classify heap targets")
        return
    end
    local warned = 0
    for _, placeable in ipairs(placeables) do
        if isOurWiredHusbandry(placeable) and warnIfHeapless(placeable, manure) then
            warned = warned + 1
        end
    end
    notifyNoHeap(warned, deps)
end

---Server-only post-load / on-demand pass: wire ALL our husbandry<->heap pairs, then warn per wired
--- heap-less husbandry. Idempotent -- safe to run every load and on demand.
---@param deps table|nil injectable collaborators (defaults to the live game)
function RmHeapConnector.reconnectAll(deps)
    if not RmHeapConnector.isServer() then
        return -- storage wiring is server-authoritative; NEVER wire on a client
    end
    local pairsWired, heapCount = wireAllHeaps(nil, deps)
    Log:info("reconnect: wired %d husbandry<->heap pair(s) across %d manure heap(s)", pairsWired, heapCount)
    warnHeaplessHusbandries(deps)
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
--- then runs the server backstop reconnect + the coalesced heap-less warning sweep. `deps` is the
--- injectable-collaborator table; the live message publishes with NO args, so it
--- fires this with deps=nil -> the live game. The suite passes fakes to drive the pass.
---@param deps table|nil
function RmHeapConnector.onSavegameLoaded(self, deps)
    RmHeapConnector.savegameLoaded = true
    RmHeapConnector.reconnectAll(deps)
end

---PlaceableHusbandry:onFinalizePlacement (APPENDED, after base): scoped reconnect for a just-placed
--- husbandry. Runs AFTER RmStrawSink's prepended finalize builds the station AND base finalize
--- registers it into the extendable pool -- so the station is discoverable by the range query.
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
    warnHeaplessHusbandries(deps)
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
    warnHeaplessHusbandries(deps)
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
-- drives them directly -- they are the slice's distinguishing hardening (delete re-sweep + re-arm).
RmHeapConnector.onManureHeapDelete = onManureHeapDelete
RmHeapConnector.onManureHeapFinalize = onManureHeapFinalize

-- ============================================================================
-- INSTALL (top-level, guarded once per process)
--
-- Husbandry onFinalizePlacement is APPENDED so it runs AFTER RmStrawSink's prepended finalize (which
-- builds the station) and base finalize (which registers it into the extendable pool). The
-- PlaceableManureHeap hooks are guarded on the spec class (and each event) existing -- absent if no
-- base/DLC heap type is loaded. onDelete re-sweeps a husbandry that lost its last heap; the appended
-- onFinalizePlacement is the re-arm hardening. The map-start reconnect + warning sweep run from the
-- SAVEGAME_LOADED subscription set up in onLoadMapFinished (loadMapFinished is too early -- terrain
-- init, before placeables load). Guarded once so re-sourcing during testing cannot double-wrap.
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
