--[[
    RmStrawSink.lua

    Slice 2 (instance half) -- the runtime husbandry straw/manure sink.

    For each strawless husbandry instance whose type RmSpecInjector injected onto, build
    the missing objects AT RUNTIME -- with no i3d/XML edit -- so straw can be stored,
    consumed on the server hour-tick, and converted to MANURE:
      * build + assign a STRAW+MANURE Storage at onLoad (appended, before the base
        savegame loadFromXMLFile so straw/manure round-trip);
      * build + assign an UnloadingStation AND a LoadingStation at onFinalizePlacement
        (prepended) -- then let the base finalize that runs right after register and wire all
        three itself (re-running that registration ourselves is not safe, so we never do).

    The LoadingStation is REQUIRED for manure: without it removeHusbandryFillLevel returns
    the full requested amount, so the producer's delta = amount - removeHusbandryFillLevel
    = 0 and no manure is produced. With it, straw is drawn down and delta > 0.

    Build is ALL-OR-NOTHING: on any partial-build failure (nil node / unresolved fill
    types) we unsubscribe the built storage's FARM_DELETED subscription and clear Storage
    AND both stations so the base wires nothing -- never a half-wired husbandry (a missing
    LoadingStation makes removeHusbandryFillLevel consume 0: straw absorbed, no manure).

    The internal MANURE capacity is built at 0 (base-exact): produced manure is skipped
    past the 0-free internal store and flows to a player-placed external heap that connects
    to the extension-enabled UnloadingStation (the base barn pattern). The heap load-order
    reconnect pass and the no-heap warning are a later slice.

    MARKER (from RmManureShared) is LOAD-BEARING: the console iterator, the warning sweep,
    and the later heap pass all visit EVERY husbandry -- our mod-built objects are told
    apart from base barns' only by the MARKER on our Storage/stations.

    Author: Ritter
]]

-- Module table doubles as the install-guard home (survives re-source in testing).
RmStrawSink = RmStrawSink or {}

-- Paired with the SAVEGAME_LOADED subscription; guards unsubscribe on map delete.
RmStrawSink.subscribed = RmStrawSink.subscribed or false

-- Own logger: the `Log` in main.lua is a file-local and is not visible here.
local Log = RmLogging.getLogger("ManureForAll")

local STORAGE_CAPACITY = 100000 -- liters of STRAW held internally (MANURE is held at 0 -- see below)
local DEFAULT_ADD_LITERS = 1000 -- default deposit for `mfaAddStraw`
-- Extension-connect radius for the manure UnloadingStation, in meters. Measured from the
-- station's REUSED component rootNode (not the husbandry center), so kept generous so a heap
-- placed near the visible building still connects; the distance check runs against the heap's
-- world position when a heap is placed.
local STORAGE_RADIUS = 100

-- The only mod-vs-native discriminant on our Storage / stations (shared home, slice 0).
local MARKER = RmManureShared.MARKER

-- ============================================================================
-- OBJECT BUILDERS
--
-- No i3d/XML edit: the Storage carries no scene node (rootNode=0 from Storage.new);
-- the stations reuse an existing placeable component node and get NO triggers/samples
-- (so their delete no-ops on the reused node). supportedFillTypes is seeded DIRECTLY
-- (the support getters just test the field) and updateSupportedFillTypes is NEVER called --
-- it would rebuild the set from triggers our stations do not have and blank the seed. The
-- manure UnloadingStation is built supportsExtension=true + a storageRadius so it registers as
-- an extension target (a player-placed manure heap in range then connects as a target); the
-- LoadingStation stays supportsExtension=false (straw removal only, never a heap target).
-- ============================================================================

---Build a straw/manure husbandry Storage with the COMPLETE field set a fully-loaded storage
--- carries (a fresh Storage.new has only a minimal core, so a bare instance would crash on the
--- fill-level / free-capacity calls and on the server hour-tick).
---@param self table the placeable
---@param straw integer
---@param manure integer
---@return table storage
local function buildStrawStorage(self, straw, manure)
    local storage = Storage.new(self.isServer, self.isClient) --[[@as table]]
    storage.capacity = STORAGE_CAPACITY
    storage.costsPerFillLevelAndDay = 0 -- the server hour-tick reads this; omit -> nil-crash ~1h after build
    storage.fillLevelSyncThreshold = 1
    storage.supportsMultipleFillTypes = true
    -- MANURE stays a supported fill type (so the UnloadingStation still accepts + passes it
    -- through) but its INTERNAL capacity is 0 -- matching the base cattleshed. Produced manure
    -- is skipped past the 0-free internal store (UnloadingStation distribution skips 0-free
    -- targets) and flows to the connected external heap instead of pooling uncollectably here.
    storage.fillTypes = { [straw] = true, [manure] = true }
    storage.capacities = { [straw] = STORAGE_CAPACITY, [manure] = 0 }
    storage.fillLevels = { [straw] = 0, [manure] = 0 }
    storage.fillLevelsLastSynced = { [straw] = 0, [manure] = 0 }
    storage.fillLevelsLastPublished = { [straw] = 0, [manure] = 0 }
    storage.sortedFillTypes = { straw, manure }
    storage.storageDirtyFlag = storage:getNextDirtyFlag() -- on the STORAGE, not the placeable
    storage[MARKER] = true -- mod-owned marker
    -- Match a loaded storage: zero the fill levels if the owner farm is deleted. A fresh
    -- Storage.new does not carry this subscription; the storage's own delete path clears it.
    g_messageCenter:subscribe(MessageType.FARM_DELETED, storage.farmDestroyed, storage)
    return storage
end

---Build a straw/manure UnloadingStation reusing an existing component node. Fields
--- mirror what the base onLoad/load set for a trigger-less station.
---@param self table the placeable
---@param rootNode number an existing component scene node
---@param straw integer
---@param manure integer
---@return table station
local function buildStrawStation(self, rootNode, straw, manure)
    local station = UnloadingStation.new(self.isServer, self.isClient) --[[@as table]]
    station.rootNode = rootNode -- reuse existing node; NO i3d edit, NO triggers
    -- owningPlaceable kept non-nil so station-name lookups stay safe (we set no stationName,
    -- so the name resolves to nil -- benign; nothing reads the name this slice).
    station.owningPlaceable = self
    station.hasStoragePerFarm = false
    -- Extension-connectable: supportsExtension MUST be set at build time so the station
    -- registers as an extension target during finalize (there is no re-register step to flip it
    -- afterwards). A player-placed manure heap in range then connects its storage as a target and
    -- produced manure flows to the heap. storageRadius is required by the compatibility check
    -- (nil radius = never in range).
    station.supportsExtension = true
    station.storageRadius = STORAGE_RADIUS
    station.targetStorages = {}
    station.unloadTriggers = {} -- seeded empty so trigger-walking station setup stays safe
    station.aiSupportedFillTypes = {}
    station.supportedFillTypes = { [straw] = true, [manure] = true } -- seed; never updateSupportedFillTypes()
    station[MARKER] = true
    return station
end

---Build a straw/manure LoadingStation reusing an existing component node -- the
--- sibling of the UnloadingStation and the object that makes removeHusbandryFillLevel
--- draw straw down (delta > 0) so manure is produced. MANURE is seeded as the solid
--- fill type (NOT LIQUIDMANURE), so any liquid-manure loading-station handling during finalize
--- stays a safe no-op. LoadingStation.new already sets sourceStorages / loadTriggers, but we
--- assign them explicitly for parity + robustness.
---@param self table the placeable
---@param rootNode number an existing component scene node
---@param straw integer
---@param manure integer
---@return table station
local function buildStrawLoadingStation(self, rootNode, straw, manure)
    local station = LoadingStation.new(self.isServer, self.isClient) --[[@as table]]
    station.rootNode = rootNode -- reuse existing node; NO i3d edit, NO triggers
    -- owningPlaceable kept non-nil so station-name lookups stay safe (we set no stationName,
    -- so the name resolves to nil -- benign; nothing reads the name this slice).
    station.owningPlaceable = self
    station.hasStoragePerFarm = false
    station.supportsExtension = false -- stay out of base extendable-station pools this slice
    station.sourceStorages = {}
    station.loadTriggers = {} -- seeded empty so trigger-walking station setup stays safe
    station.aiSupportedFillTypes = {}
    station.supportedFillTypes = { [straw] = true, [manure] = true } -- seed; addSourceStorage intersection gate
    station[MARKER] = true
    return station
end

-- ============================================================================
-- GUARDS
-- ============================================================================

---Base early-out shared by both build wrappers: the type is in the injected set (a
--- strawless husbandry WE inject onto), not in ERROR load state, and has the husbandry
--- spec. Keying on injected-set membership (via RmSpecInjector) aligns build-scope with
--- inject-scope. loadingState is a FIELD on the placeable, not a getter.
---@param self table
---@return boolean
local function isLiveHusbandry(self)
    if self == nil or not RmSpecInjector.isInjected(self.typeName) then
        return false
    end
    if self.loadingState == PlaceableLoadingState.ERROR then
        return false
    end
    return self.spec_husbandry ~= nil
end

---STRUCTURAL "owns none of storage/unloadingStation/loadingStation" test: true only for a
--- husbandry that declares no central storage of its own. An instance that already owns ANY
--- of the three is left entirely untouched (never overwrite persisted state; a milk /
--- liquid-manure husbandry that rides a central store is the deferred augment case, warned by
--- the post-load sweep). Not a straw test -- purely storage presence.
---@param h table spec_husbandry
---@return boolean
local function hasNoHusbandryStorage(h)
    return h.storage == nil and h.unloadingStation == nil and h.loadingStation == nil
end

---True if a pre-existing (non-mod) central storage cannot hold BOTH STRAW and MANURE -- the
--- deferred milk / liquid-manure augment case that warrants a warning. Excludes our own
--- mod-built storage (MARKER: it always holds both). Reads storage.fillTypes directly (NOT
--- getHusbandryIsFillTypeSupported, which reads the possibly-nil unloadingStation of a
--- storage-only husbandry and would misclassify). Pure; exposed for the unit test.
---@param storage table|nil spec_husbandry.storage
---@param straw integer
---@param manure integer
---@return boolean
local function storageNeedsWarning(storage, straw, manure)
    if storage == nil or storage[MARKER] == true then
        return false -- no central storage, or it is ours (holds STRAW+MANURE already)
    end
    local fillTypes = storage.fillTypes
    if fillTypes == nil then
        return true -- a central storage that lists no fill types cannot hold STRAW+MANURE
    end
    return fillTypes[straw] ~= true or fillTypes[manure] ~= true
end

-- ============================================================================
-- PHASE-1 INJECTION-TIMING MITIGATION
--
-- Slice 1 injects the straw/manure curves at loadMapFinished;
-- onHusbandryAnimalsUpdate sets inputLitersPerHour/outputLitersPerHour from
-- subType.input.straw:get(age) on cluster changes. If a husbandry's clusters last updated
-- BEFORE the curves existed, rates lock at 0 until an animal add/remove. Force a recompute
-- so a just-wired husbandry re-reads the (now-present) curves.
-- ============================================================================

---Force an animal-cluster recompute on a husbandry that has the animals spec, so the
--- straw producer re-reads the slice-1 curves. Guards the animals spec/clusterSystem.
---@param self table the placeable
local function recomputeAnimalRates(self)
    local animals = self.spec_husbandryAnimals
    if self.updatedClusters ~= nil and animals ~= nil and animals.clusterSystem ~= nil then
        self:updatedClusters(self) -- raises onHusbandryAnimalsUpdate with current clusters
    end
end

-- ============================================================================
-- LIFECYCLE WRAPPERS
-- ============================================================================

---onLoad (APPENDED, after base): for a strawless injected-set husbandry, build the
--- straw/manure Storage and assign it to spec_husbandry.storage BEFORE the base savegame
--- loadFromXMLFile so straw/manure round-trip. The no-storage guard means we never
--- overwrite a husbandry that already owns persisted storage and makes the build idempotent
--- within an instance.
---@param self table the placeable
local function husbandryOnLoad(self)
    if not isLiveHusbandry(self) then
        return
    end
    local h = self.spec_husbandry
    if not hasNoHusbandryStorage(h) then
        Log:debug("%s already owns storage/station -- not wiring", tostring(self.typeName))
        return
    end

    local straw, manure = RmManureShared.resolveFillTypes()
    if straw == nil or manure == nil then
        Log:warning("STRAW/MANURE fill type unresolved; skipping storage build for %s", tostring(self.typeName))
        return
    end

    h.storage = buildStrawStorage(self, straw, manure)
    Log:debug("assigned straw/manure Storage to %s at onLoad", tostring(self.typeName))
end

---onFinalizePlacement (PREPENDED, before base): for a husbandry whose Storage WE built at
--- onLoad (marker) and that has no station yet, build BOTH the UnloadingStation and the
--- LoadingStation and assign them. Registration/wiring is left to the base finalize that
--- runs right after -- it sees storage + both stations non-nil and registers + wires all
--- three itself (we never re-run that registration).
---
--- ALL-OR-NOTHING: on any failure to fully build (nil node / unresolved fill types),
--- unsubscribe the built storage's FARM_DELETED subscription (leak hardening) and clear
--- Storage AND both stations so the base wires nothing. After a successful build, force the
--- slice-1 rate-recompute mitigation on this husbandry.
---@param self table the placeable
local function husbandryOnFinalizePlacement(self)
    if not isLiveHusbandry(self) then
        return
    end
    local h = self.spec_husbandry
    local storage = h.storage
    if storage == nil or storage[MARKER] ~= true then
        return -- not our storage -- do not touch husbandries with real/other storage
    end
    if h.unloadingStation ~= nil or h.loadingStation ~= nil then
        return -- idempotent -- stations already built
    end

    -- All-or-nothing: unsubscribe the built storage's FARM_DELETED (it is never delete()d
    -- when aborted, so its subscription would otherwise leak) and clear Storage + both
    -- stations so base wires nothing.
    local function abort(reason)
        Log:warning("%s: %s; clearing storage + stations, not wiring", tostring(self.typeName), reason)
        if h.storage ~= nil and g_messageCenter ~= nil then
            g_messageCenter:unsubscribe(MessageType.FARM_DELETED, h.storage)
        end
        h.storage = nil
        h.unloadingStation = nil
        h.loadingStation = nil
    end

    local node = self.components ~= nil and self.components[1] ~= nil and self.components[1].node or nil
    if node == nil then
        abort("no component node")
        return
    end

    local straw, manure = RmManureShared.resolveFillTypes()
    if straw == nil or manure == nil then
        abort("STRAW/MANURE fill type unresolved")
        return
    end

    local unloadingStation = buildStrawStation(self, node, straw, manure)
    local loadingStation = buildStrawLoadingStation(self, node, straw, manure)
    if unloadingStation == nil or loadingStation == nil then
        abort("station build failed")
        return
    end

    h.unloadingStation = unloadingStation
    h.loadingStation = loadingStation

    -- Re-read the slice-1 curves now that the sink exists (see mitigation note above).
    recomputeAnimalRates(self)

    Log:info("wired straw sink for %s '%s' "
        .. "(Storage + UnloadingStation + LoadingStation; base finalize registers)",
        tostring(self.typeName), tostring(self:getName()))
end

-- ============================================================================
-- POST-LOAD WARNING SWEEP (read-only diagnostic)
--
-- An injected-set husbandry that DID own a central storage was skipped by the build gate
-- (hasNoHusbandryStorage was false). If that pre-existing storage cannot hold STRAW+MANURE
-- (a milk / liquid-manure-only husbandry riding a central store, common in mods), the mod
-- builds/mutates NOTHING on it (augment deferred) -- but the player should know it will not
-- collect manure. This standalone sweep classifies each such instance and logs one WARNING
-- plus a per-load summary.
--
-- Runs on the SAVEGAME_LOADED message (fires AFTER all savegame placeables have loaded --
-- loadMapFinished is the terrain-init callback and fires BEFORE them). READ ONLY -- never
-- mutates a pre-existing storage/station. Per-load re-derive (no persistent flag): a fresh
-- sweep each load naturally warns once per instance present at load; a mid-session placement
-- is swept next load.
--
-- Deviation from the PoC: RETURNS the warned count and takes the placeable list as a param
-- (defaulting to the live mission), so the in-game suite can assert the count directly --
-- the PoC test's logger-replacement counting trick cannot work in-game.
-- ============================================================================

---Sweep every placed injected-set husbandry that owns a pre-existing central storage lacking
--- STRAW+MANURE; log one WARNING each and one per-load summary. Read-only.
---@param placeables table[]|nil defaults to g_currentMission.placeableSystem.placeables
---@return integer warned number of incompatible-storage husbandries warned about
local function warnUnsupportedStorages(placeables)
    if placeables == nil then
        local mission = g_currentMission
        if mission == nil or mission.placeableSystem == nil then
            return 0
        end
        placeables = mission.placeableSystem.placeables
    end
    local straw, manure = RmManureShared.resolveFillTypes()
    if straw == nil or manure == nil then
        return 0 -- registry inconsistent; the build sweep already logged the WARNING
    end
    local warned = 0
    for _, placeable in ipairs(placeables) do
        if isLiveHusbandry(placeable) then
            local h = placeable.spec_husbandry
            if storageNeedsWarning(h.storage, straw, manure) then
                warned = warned + 1
                Log:warning("husbandry '%s' (%s) owns a central storage that cannot hold STRAW+MANURE -- "
                    .. "left untouched; the mod cannot collect its manure (augment deferred)",
                    tostring(placeable:getName()), tostring(placeable.typeName))
            end
        end
    end
    -- Summary only when there is something to report: a "0 incompatible" line every single
    -- load (the common case) would be INFO noise.
    if warned > 0 then
        Log:info("straw pipeline: %d husbandr%s own an incompatible central storage -- augment deferred",
            warned, warned == 1 and "y" or "ies")
    end
    return warned
end

-- ============================================================================
-- CONSOLE BODIES (delegated from the console shell)
--
--   mfaDump sinks                     per-husbandry presence / support / levels / capacity
--   mfaAddStraw [liters] [index]      host-only STRAW deposit (default 1000 L)
--
-- Positive observation only -- success is never inferred from error-absence. Reads no
-- module-level cached placeable references (live placeableSystem each call). Bodies live
-- here; the console shell dispatches to them and prints the returned string.
-- ============================================================================

---Iterate live placed husbandries in placeable order. cb(placeable, spec, index) per
--- husbandry, index being the 1-based ordinal used by dump/add. Degated -- visits EVERY
--- husbandry; our mod-wired ones are told apart by the MARKER (isModWired).
---@param cb fun(placeable: table, spec: table, index: integer)
---@return boolean ok, string|nil errText bare reason (caller prefixes it per command)
local function forEachHusbandry(cb)
    local mission = g_currentMission
    if mission == nil or mission.placeableSystem == nil then
        return false, "no mission/placeableSystem yet -- load a save first"
    end
    local index = 0
    for _, placeable in ipairs(mission.placeableSystem.placeables) do
        if placeable.spec_husbandry ~= nil then
            index = index + 1
            cb(placeable, placeable.spec_husbandry, index)
        end
    end
    return true, nil
end

---True when a husbandry is fully mod-wired (our Storage AND both stations present).
---@param spec table spec_husbandry
---@return boolean
local function isModWired(spec)
    return spec.storage ~= nil and spec.storage[MARKER] == true
        and spec.unloadingStation ~= nil and spec.loadingStation ~= nil
end

---Read farm for out-of-band access: the STORAGE's owner (base finalize may remap an
--- EVERYONE-owned husbandry's storage owner to NOBODY, and reading with the placeable owner
--- would fail hasFarmAccessToStorage and report a false 0). Nil-guards a mid-delete storage
--- by falling back to the placeable owner.
---@param placeable table
---@param spec table spec_husbandry
---@return integer farmId
local function accessFarmId(placeable, spec)
    if spec.storage ~= nil then
        return spec.storage:getOwnerFarmId()
    end
    return placeable:getOwnerFarmId()
end

---`mfaDump sinks`: report per husbandry the Storage/station presence + STRAW/MANURE support,
--- level and capacity, read with the storage owner farm.
---@return string
function RmStrawSink.dumpSinks()
    local straw, manure = RmManureShared.resolveFillTypes()
    if straw == nil or manure == nil then
        return "mfaDump sinks: STRAW/MANURE fill type unresolved -- cannot dump"
    end

    local found, wired = 0, 0
    local ok, errText = forEachHusbandry(function(placeable, spec, index)
        found = found + 1
        local isWired = isModWired(spec)
        if isWired then
            wired = wired + 1
        end
        local farmId = accessFarmId(placeable, spec)
        Log:info(
            "dump: %s #%d -- storage=%s unloading=%s loading=%s wired=%s farm=%s | "
                .. "STRAW supported=%s level=%.0f cap=%.0f | MANURE supported=%s level=%.0f cap=%.0f",
            tostring(placeable.typeName), index,
            tostring(spec.storage ~= nil), tostring(spec.unloadingStation ~= nil), tostring(spec.loadingStation ~= nil),
            tostring(isWired), tostring(farmId),
            tostring(placeable:getHusbandryIsFillTypeSupported(straw)),
            placeable:getHusbandryFillLevel(straw, farmId) or 0, placeable:getHusbandryCapacity(straw, farmId) or 0,
            tostring(placeable:getHusbandryIsFillTypeSupported(manure)),
            placeable:getHusbandryFillLevel(manure, farmId) or 0, placeable:getHusbandryCapacity(manure, farmId) or 0)
    end)

    if not ok then
        return "mfaDump sinks: " .. errText
    end
    if found == 0 then
        return "mfaDump sinks: no placed husbandry found -- nothing to dump"
    end
    return string.format(
        "mfaDump sinks: %d placed husbandr%s, %d wired -- see log for per-husbandry STRAW/MANURE support+level",
        found, found == 1 and "y" or "ies", wired)
end

---`mfaAddStraw [liters] [index]`: host-only STRAW deposit via addHusbandryFillLevelFromTool
--- using the storage owner farm; logs moved vs requested per husbandry. With an index, only
--- the Nth husbandry in the dump ordering is targeted; omitted, EVERY wired husbandry
--- receives `liters` (fan-out). Rejects non-finite / non-positive liters.
---@param litersArg string|nil
---@param indexArg string|nil
---@return string
function RmStrawSink.addStraw(litersArg, indexArg)
    if g_server == nil then
        return "mfaAddStraw: host-only (no g_server) -- run on the host/SP"
    end
    if litersArg ~= nil and tonumber(litersArg) == nil then
        return string.format("mfaAddStraw: invalid liters '%s' -- use a positive number", tostring(litersArg))
    end
    local liters = tonumber(litersArg) or DEFAULT_ADD_LITERS
    -- Reject NaN (liters ~= liters) and +/-inf before the engine sees them: base
    -- addHusbandryFillLevelFromTool asserts 0 <= delta (NaN -> Lua error) and inf silently
    -- clamps to capacity. Require a finite positive number.
    if liters ~= liters or liters == math.huge or liters == -math.huge then
        return "mfaAddStraw: liters must be a finite positive number"
    end
    if liters <= 0 then
        return "mfaAddStraw: liters must be > 0"
    end

    local wantIndex = nil
    if indexArg ~= nil and indexArg ~= "" then
        wantIndex = tonumber(indexArg)
        -- Reject non-numeric, NaN and +inf before the positive-integer floor: LuaJIT's
        -- tonumber maps "nan"/"1e999" to NaN/inf (NOT nil, unlike stock 5.1), and every
        -- NaN comparison is false, so a bare `< 1` guard would let them through and format
        -- garbage via %d. Mirrors the finite-liters check above. (-inf is caught by `< 1`.)
        if wantIndex == nil or wantIndex ~= wantIndex or wantIndex == math.huge or wantIndex < 1 then
            return string.format(
                "mfaAddStraw: invalid husbandry index '%s' -- use a positive integer", tostring(indexArg))
        end
        wantIndex = math.floor(wantIndex)
    end

    local straw = RmManureShared.resolveFillTypes()
    if straw == nil then
        return "mfaAddStraw: STRAW fill type unresolved -- cannot add"
    end

    -- Deposit `liters` STRAW into one wired husbandry using the STORAGE owner farm (nil-guarded
    -- mid-delete); logs moved vs requested. Returns moved liters, or -1 if storage vanished.
    local function depositInto(placeable, hIndex)
        local storage = placeable.spec_husbandry.storage
        if storage == nil then
            Log:warning("add: husbandry #%d storage vanished (mid-delete) -- nothing added", hIndex)
            return -1
        end
        local farmId = storage:getOwnerFarmId()
        local moved = placeable:addHusbandryFillLevelFromTool(farmId, liters, straw, nil, nil, nil)
        local level = placeable:getHusbandryFillLevel(straw, farmId)
        if moved <= 0 then
            Log:warning(
                "add: requested %.0f L STRAW into husbandry #%d but moved 0 (farm=%s) -- access/capacity/rejection",
                liters, hIndex, tostring(farmId))
        elseif moved < liters then
            Log:info(
                "add: requested %.0f L STRAW into husbandry #%d, moved %.0f L "
                    .. "(clamped by free capacity), farm=%s, level now %.0f",
                liters, hIndex, moved, tostring(farmId), level)
        else
            Log:info(
                "add: requested %.0f L STRAW into husbandry #%d, moved %.0f L, farm=%s, level now %.0f",
                liters, hIndex, moved, tostring(farmId), level)
        end
        return moved
    end

    -- Explicit index: deposit into that one husbandry only.
    if wantIndex ~= nil then
        local target, targetWired, maxIndex = nil, false, 0
        local ok, errText = forEachHusbandry(function(placeable, spec, index)
            maxIndex = index
            if index == wantIndex then
                target, targetWired = placeable, isModWired(spec)
            end
        end)
        if not ok then
            return "mfaAddStraw: " .. errText
        end
        if target == nil then
            return string.format(
                "mfaAddStraw: no husbandry at index %d (found %d placed)", wantIndex, maxIndex)
        end
        if not targetWired then
            return string.format(
                "mfaAddStraw: husbandry #%d is not wired (no straw sink) -- nothing added", wantIndex)
        end
        local moved = depositInto(target, wantIndex)
        if moved < 0 then
            return string.format(
                "mfaAddStraw: husbandry #%d storage vanished (mid-delete) -- nothing added", wantIndex)
        end
        return string.format(
            "mfaAddStraw: moved %.0f / %.0f L STRAW into husbandry #%d (see log)", moved, liters, wantIndex)
    end

    -- No index: fan out to EVERY wired husbandry, depositing `liters` into each.
    local wiredCount, totalMoved = 0, 0
    local ok, errText = forEachHusbandry(function(placeable, spec, index)
        if isModWired(spec) then
            wiredCount = wiredCount + 1
            local moved = depositInto(placeable, index)
            if moved > 0 then
                totalMoved = totalMoved + moved
            end
        end
    end)
    if not ok then
        return "mfaAddStraw: " .. errText
    end
    if wiredCount == 0 then
        return "mfaAddStraw: no wired husbandry (no mod storage+stations on any placed husbandry)"
    end
    return string.format(
        "mfaAddStraw: moved %.0f L STRAW total into %d wired husbandr%s (%.0f requested each; see log)",
        totalMoved, wiredCount, wiredCount == 1 and "y" or "ies", liters)
end

-- ============================================================================
-- LIFECYCLE (SAVEGAME_LOADED sweep subscription)
-- ============================================================================

---SAVEGAME_LOADED handler: run the read-only unsupported-storage warning sweep now that
--- every savegame placeable has loaded.
function RmStrawSink:onSavegameLoaded()
    warnUnsupportedStorages()
end

---BaseMission.loadMapFinished append: subscribe the post-load sweep (flag-paired).
--- loadMapFinished fires before SAVEGAME_LOADED, so the subscription is in place when it fires.
local function subscribeSweep()
    if RmStrawSink.subscribed then
        return
    end
    if g_messageCenter == nil then
        return
    end
    g_messageCenter:subscribe(MessageType.SAVEGAME_LOADED, RmStrawSink.onSavegameLoaded, RmStrawSink)
    RmStrawSink.subscribed = true
end

---BaseMission.delete append: drop the sweep subscription (flag-paired).
local function unsubscribeSweep()
    if not RmStrawSink.subscribed then
        return
    end
    if g_messageCenter ~= nil then
        g_messageCenter:unsubscribe(MessageType.SAVEGAME_LOADED, RmStrawSink)
    end
    RmStrawSink.subscribed = false
end

-- Expose the guards + the sweep for the fakes unit test (the pure decision logic + the
-- count-returning sweep). isLiveHusbandry reads RmSpecInjector.isInjected and the sweep
-- takes its placeable list as a param, so both drive off fakes the test injects.
RmStrawSink.isLiveHusbandry = isLiveHusbandry
RmStrawSink.hasNoHusbandryStorage = hasNoHusbandryStorage
RmStrawSink.storageNeedsWarning = storageNeedsWarning
RmStrawSink.warnUnsupportedStorages = warnUnsupportedStorages

-- ============================================================================
-- INSTALL (top-level, guarded once per process)
--
-- onLoad is APPENDED (build storage after base sets up spec_husbandry); onFinalizePlacement
-- is PREPENDED (build stations before base wires them). SAVEGAME_LOADED subscribe/unsubscribe
-- are paired via BaseMission hooks. Guarded once so re-sourcing during testing cannot
-- double-wrap or double-append.
-- ============================================================================

if not RmStrawSink.installed then
    PlaceableHusbandry.onLoad = Utils.appendedFunction(PlaceableHusbandry.onLoad, husbandryOnLoad)
    PlaceableHusbandry.onFinalizePlacement =
        Utils.prependedFunction(PlaceableHusbandry.onFinalizePlacement, husbandryOnFinalizePlacement)
    BaseMission.loadMapFinished = Utils.appendedFunction(BaseMission.loadMapFinished, subscribeSweep)
    BaseMission.delete = Utils.appendedFunction(BaseMission.delete, unsubscribeSweep)
    RmStrawSink.installed = true
end
