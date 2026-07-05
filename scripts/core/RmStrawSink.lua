--[[
    RmStrawSink.lua

    The runtime husbandry straw/manure sink -- BUILD-OR-AUGMENT per placeable.

    For each husbandry instance whose type RmSpecInjector injected onto, make sure a
    STRAW+MANURE-capable sink exists AT RUNTIME -- with no i3d/XML edit -- so straw can be
    stored, consumed on the server hour-tick, and converted to MANURE. Two paths, chosen
    per placeable:
      * CLEAN SLATE (owns no storage/stations): build + assign a STRAW+MANURE Storage at
        onLoad (appended, before the base savegame loadFromXMLFile so straw/manure
        round-trip); build + assign an UnloadingStation AND a LoadingStation at
        onFinalizePlacement (prepended) -- then let the base finalize that runs right after
        register and wire all three itself (re-running that registration is not safe, so
        we never do).
      * AUGMENT (owns a central storage -- manual-water pastures, milk, liquid-manure):
        mutate the EXISTING storage in place at onLoad, adding only the MISSING of STRAW
        (cap N) / MANURE (cap 0) and never touching a native type's capacity or level;
        then at onFinalizePlacement add STRAW+MANURE support + extension to the existing
        UnloadingStation (or build one), and REUSE an existing LoadingStation completely
        untouched -- its source-storage link is what lets the producer draw straw, and
        never adding STRAW to its supported types keeps straw one-way IN at its real
        trigger. A storage that cannot isolate STRAW (single fill type, or a native type
        drawing on the shared capacity pool) is skipped whole and warned by the post-load
        sweep -- no partial wiring.

    The LoadingStation is REQUIRED for manure: without it removeHusbandryFillLevel returns
    the full requested amount, so the producer's delta = amount - removeHusbandryFillLevel
    = 0 and no manure is produced. With it, straw is drawn down and delta > 0.

    Both paths are ALL-OR-NOTHING: on any station-phase failure the clean-slate build
    clears its own Storage + stations (never a half-wired husbandry), and the augment path
    SURGICALLY reverts every field it added on BOTH the storage and the station -- base
    objects end exactly as base built them and are never deleted or nil'd.

    The internal MANURE capacity is 0 on both paths (base-exact): produced manure is
    skipped past the 0-free internal store and flows to a player-placed external heap that
    connects to the extension-enabled UnloadingStation (the base barn pattern).

    MARKER (from RmManureShared) is LOAD-BEARING: the console iterator, the warning sweep,
    and the heap pass all visit EVERY husbandry -- our built/augmented objects are told
    apart from untouched base storage only by the MARKER on our Storage/stations. A reused
    LoadingStation is deliberately NEVER stamped: wired-ness keys on the storage +
    unloadingStation MARKER only.

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
-- Per-placeable native-straw-intake flag name (shared home; RmTroughDivert reads it).
-- Runtime-only, never persisted; sampled BEFORE the mod adds STRAW to a station.
local NATIVE_STRAW_INTAKE = RmManureShared.NATIVE_STRAW_INTAKE
-- Runtime-only field on the placeable carrying the onLoad storage revert-record to the
-- finalize station phase (set by the augment branch of husbandryOnLoad; consumed AND
-- cleared -- success or abort -- by husbandryOnFinalizePlacement). Never persisted.
local AUGMENT_STATE = "rmStrawAugmentState"

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

---Build a straw LoadingStation reusing an existing component node -- the sibling of the
--- UnloadingStation and the object that makes removeHusbandryFillLevel draw straw down
--- (delta > 0) so manure is produced. Seeds STRAW ONLY: STRAW alone satisfies the
--- addSourceStorage fill-type intersection, and MANURE never belongs on any
--- loadingStation (manure is one-way OUT through the UnloadingStation, never loadable
--- here). LoadingStation.new already sets sourceStorages / loadTriggers, but we assign
--- them explicitly for parity + robustness.
---@param self table the placeable
---@param rootNode number an existing component scene node
---@param straw integer
---@return table station
local function buildStrawLoadingStation(self, rootNode, straw)
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
    station.supportedFillTypes = { [straw] = true } -- seed STRAW only; addSourceStorage intersection gate
    station[MARKER] = true
    return station
end

-- ============================================================================
-- AUGMENT BUILDERS (in-place mutation of a pre-existing storage / station)
--
-- A husbandry that already OWNS a central storage (manual-water pastures, milk,
-- liquid-manure) is augmented IN PLACE instead of built on: add only the MISSING of
-- STRAW/MANURE, never touch a native type's capacity or level, and record every mutation
-- so the finalize station phase can surgically revert BOTH the storage and the station on
-- any failure. Field mutation only -- no i3d/XML edit, no registration (the base finalize
-- that runs right after our prepended wrapper registers and wires the augmented objects
-- exactly like untouched base ones). Re-runs every load: the MARKER is runtime-only and
-- the base storage is rebuilt from store XML each load, so the augment is re-derived
-- per-load (the MARKER guard only prevents a double-augment WITHIN a load). Runs
-- identically per-peer -- every mutation below is deterministic.
-- ============================================================================

---Classify whether a pre-existing central storage can hold STRAW in isolation. False for
--- a single-fill-type storage; false when any EXISTING fill type lacks an explicit
--- per-type capacity (that native type draws on the shared capacity pool, so an added
--- STRAW level would eat its headroom -- never accept that competition); false when any
--- of the six fill-type/level tables a fully loaded storage carries is missing, or when a
--- listed fill type is not materialized in ALL of them (defensive; the base storage load
--- always creates all six and materializes every type). Pure; exposed for the unit test.
---@param storage table pre-existing spec_husbandry.storage
---@return boolean canIsolate
---@return string|nil reason skip reason when false
local function storageCanIsolateStraw(storage)
    if storage.supportsMultipleFillTypes ~= true then
        return false, "single-fill-type storage"
    end
    if storage.fillTypes == nil or storage.capacities == nil or storage.fillLevels == nil
        or storage.fillLevelsLastSynced == nil or storage.fillLevelsLastPublished == nil
        or storage.sortedFillTypes == nil then
        return false, "unexpected storage shape"
    end
    for fillType in pairs(storage.fillTypes) do
        if storage.capacities[fillType] == nil then
            return false, "shared-pool native fill type"
        end
        -- A listed type must be materialized everywhere: absent from fillLevels/mirrors the
        -- storage's own level setter silently no-ops on it, absent from sortedFillTypes it
        -- never streams to peers -- and augment would skip it as "already present", shipping
        -- a silently inert store.
        if storage.fillLevels[fillType] == nil
            or storage.fillLevelsLastSynced[fillType] == nil
            or storage.fillLevelsLastPublished[fillType] == nil then
            return false, "unexpected storage shape"
        end
        local sorted = false
        for _, sortedType in ipairs(storage.sortedFillTypes) do
            if sortedType == fillType then
                sorted = true
                break
            end
        end
        if not sorted then
            return false, "unexpected storage shape"
        end
    end
    return true, nil
end

---Add the MISSING of STRAW/MANURE to a pre-existing multi-fill-type storage, in fixed
--- order STRAW then MANURE. capacities[straw]=STORAGE_CAPACITY; the explicit
--- capacities[manure]=0 is LOAD-BEARING: per-type free capacity only isolates when the
--- capacity is set, so the 0 keeps manure free-capacity at 0 -- produced manure skips the
--- internal store and flows to the connected heap instead of pooling uncollectably here.
--- sortedFillTypes is APPENDED, never table.sort'ed: the storage read/write streams pair
--- fill levels POSITIONALLY by sortedFillTypes, and both peers run this same
--- deterministic append (keeping index 1 native also preserves the base dynamicFillPlane
--- default). Never touches an existing type's capacity or level. Exposed for the
--- unit test.
---@param storage table pre-existing spec_husbandry.storage (storageCanIsolateStraw true)
---@param straw integer
---@param manure integer
---@return table record { addedTypes = { <the fill types actually added, in order> } }
local function augmentStorage(storage, straw, manure)
    local record = { addedTypes = {} }
    for _, fillType in ipairs({ straw, manure }) do
        if storage.fillTypes[fillType] ~= true then
            storage.fillTypes[fillType] = true
            storage.capacities[fillType] = fillType == straw and STORAGE_CAPACITY or 0
            storage.fillLevels[fillType] = 0
            storage.fillLevelsLastSynced[fillType] = 0
            storage.fillLevelsLastPublished[fillType] = 0
            table.insert(storage.sortedFillTypes, fillType)
            table.insert(record.addedTypes, fillType)
        end
    end
    storage[MARKER] = true
    return record
end

---SURGICAL revert of augmentStorage: remove exactly the fill types the record says were
--- added -- from all five capacity/level tables and (by value) from sortedFillTypes --
--- and clear the MARKER. NOTHING else: the base savegame loadFromXMLFile restores the
--- native (e.g. WATER) saved level BETWEEN our onLoad augment and the finalize station
--- phase, so a whole-table snapshot restore would wipe it -- only ever remove our own
--- additions. Exposed for the unit test.
---@param storage table the storage augmentStorage mutated
---@param record table the record augmentStorage returned
local function revertStorageAugment(storage, record)
    for _, fillType in ipairs(record.addedTypes) do
        storage.fillTypes[fillType] = nil
        storage.capacities[fillType] = nil
        storage.fillLevels[fillType] = nil
        storage.fillLevelsLastSynced[fillType] = nil
        storage.fillLevelsLastPublished[fillType] = nil
        for i = #storage.sortedFillTypes, 1, -1 do
            if storage.sortedFillTypes[i] == fillType then
                table.remove(storage.sortedFillTypes, i)
            end
        end
    end
    storage[MARKER] = nil
end

---True when a station already brings its OWN straw intake: STRAW in the station's
--- supported types, or any unload trigger declaring STRAW in the trigger's own fill-type
--- gate (a trigger with a nil fill-type table accepts everything and defers to station
--- support, which the first test already covered). Pure -- MUST be sampled BEFORE the mod
--- adds STRAW to the station, or it would read our own addition back as "native".
--- Exposed for the unit test.
---@param station table a pre-existing UnloadingStation
---@param straw integer
---@return boolean
local function sampleNativeStrawIntake(station, straw)
    if station.supportedFillTypes ~= nil and station.supportedFillTypes[straw] ~= nil then
        return true
    end
    if station.unloadTriggers ~= nil then
        for _, trigger in ipairs(station.unloadTriggers) do
            if trigger.fillTypes ~= nil and trigger.fillTypes[straw] then
                return true
            end
        end
    end
    return false
end

---Augment a pre-existing UnloadingStation for the straw sink: add the MISSING of
--- STRAW/MANURE to supportedFillTypes (== nil test, matching the base support getter),
--- ensure supportsExtension (must happen in our PREPENDED finalize so the base
--- registration right after sees it; base water stations already ship true) and a
--- storageRadius (set only when ABSENT -- never shrink or overwrite an existing radius),
--- and stamp the MARKER. aiSupportedFillTypes is deliberately untouched: straw/manure are
--- never advertised to AI. Every mutation is recorded for revertStationAugment. The direct
--- seed is durable for the whole session: the engine rebuilds a station's supported types
--- only while the station itself loads, never after finalize (verified), so nothing wipes
--- the seed mid-session. Exposed for the unit test.
---@param station table a pre-existing UnloadingStation (caller verified supportedFillTypes is present)
---@param straw integer
---@param manure integer
---@return table record { addedTypes = {...}, setExtension = boolean, setRadius = boolean }
local function augmentStation(station, straw, manure)
    local record = { addedTypes = {}, setExtension = false, setRadius = false }
    for _, fillType in ipairs({ straw, manure }) do
        if station.supportedFillTypes[fillType] == nil then
            station.supportedFillTypes[fillType] = true
            table.insert(record.addedTypes, fillType)
        end
    end
    if station.supportsExtension ~= true then
        station.supportsExtension = true
        record.setExtension = true
    end
    if station.storageRadius == nil then
        station.storageRadius = STORAGE_RADIUS
        record.setRadius = true
    end
    station[MARKER] = true
    return record
end

---Inverse of augmentStation: remove exactly the recorded supported-type additions,
--- restore supportsExtension / storageRadius only when the record says WE set them, and
--- clear the MARKER -- the station ends exactly as base built it. Exposed for the
--- unit test.
---@param station table the station augmentStation mutated
---@param record table the record augmentStation returned
local function revertStationAugment(station, record)
    for _, fillType in ipairs(record.addedTypes) do
        station.supportedFillTypes[fillType] = nil
    end
    if record.setExtension then
        station.supportsExtension = false
    end
    if record.setRadius then
        station.storageRadius = nil
    end
    station[MARKER] = nil
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
--- husbandry that declares no central storage of its own -- the CLEAN-SLATE build case.
--- An instance that owns a central storage is the AUGMENT case (mutated in place, never
--- overwritten); storage nil with a station present is a degenerate modded shape left
--- untouched. Not a straw test -- purely storage presence.
---@param h table spec_husbandry
---@return boolean
local function hasNoHusbandryStorage(h)
    return h.storage == nil and h.unloadingStation == nil and h.loadingStation == nil
end

---True if a pre-existing (non-mod) central storage cannot hold BOTH STRAW and MANURE --
--- the augment-skipped case that warrants a warning -- with a second return naming WHY
--- (derived via storageCanIsolateStraw, so the warning names the actual augment blocker).
--- Excludes our own built/augmented storage (MARKER: it always holds both). Reads
--- storage.fillTypes directly (NOT getHusbandryIsFillTypeSupported, which reads the
--- possibly-nil unloadingStation of a storage-only husbandry and would misclassify).
--- Pure; exposed for the unit test.
---@param storage table|nil spec_husbandry.storage
---@param straw integer
---@param manure integer
---@return boolean needsWarning
---@return string|nil reason skip reason for the warning text (nil when no warning)
local function storageNeedsWarning(storage, straw, manure)
    if storage == nil or storage[MARKER] == true then
        return false, nil -- no central storage, or ours (built/augmented: holds both already)
    end
    local fillTypes = storage.fillTypes
    if fillTypes == nil then
        return true, "central storage lists no fill types"
    end
    if fillTypes[straw] == true and fillTypes[manure] == true then
        return false, nil -- already holds both (e.g. a native straw setup) -- nothing lost
    end
    local canIsolate, why = storageCanIsolateStraw(storage)
    if not canIsolate and why == "single-fill-type storage" then
        return true, "cannot isolate STRAW (single-fill-type storage)"
    end
    if not canIsolate and why == "shared-pool native fill type" then
        return true, "cannot isolate STRAW (shared-pool fill type)"
    end
    if not canIsolate and why == "unexpected storage shape" then
        return true, "cannot isolate STRAW (unexpected storage shape)"
    end
    -- Isolatable (or an unexpected shape) yet still lacking STRAW/MANURE: the augment did
    -- not stick this load (e.g. a station-phase abort reverted it).
    return true, "could not be augmented"
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

---onLoad (APPENDED, after base): make sure an injected-set husbandry ends with a
--- STRAW+MANURE-capable storage BEFORE the base savegame loadFromXMLFile runs, so saved
--- straw/manure levels round-trip (the base restore drops a saved level whose fill type
--- is absent from fillLevels). Three shapes:
---   * owns nothing -> CLEAN-SLATE build (assign a fresh mod storage);
---   * owns a central storage that is not ours/augmented this load -> AUGMENT it in place
---     when it can isolate STRAW, parking the revert-record on the placeable for the
---     finalize station phase; a cannot-isolate storage is skipped whole -- the
---     SAVEGAME_LOADED sweep owns the once-per-load WARNING, so no double-warn here;
---   * storage nil but some station exists (degenerate modded shape) -> left untouched.
--- Runs identically per-peer.
---@param self table the placeable
local function husbandryOnLoad(self)
    if not isLiveHusbandry(self) then
        return
    end
    local h = self.spec_husbandry

    if hasNoHusbandryStorage(h) then
        local straw, manure = RmManureShared.resolveFillTypes()
        if straw == nil or manure == nil then
            Log:warning("STRAW/MANURE fill type unresolved; skipping storage build for %s", tostring(self.typeName))
            return
        end
        h.storage = buildStrawStorage(self, straw, manure)
        Log:debug("assigned straw/manure Storage to %s at onLoad", tostring(self.typeName))
        return
    end

    if h.storage ~= nil and h.storage[MARKER] ~= true then
        local straw, manure = RmManureShared.resolveFillTypes()
        if straw == nil or manure == nil then
            Log:warning("STRAW/MANURE fill type unresolved; leaving %s central storage untouched",
                tostring(self.typeName))
            return
        end
        local canIsolate, reason = storageCanIsolateStraw(h.storage)
        if not canIsolate then
            -- The SAVEGAME_LOADED sweep owns the once-per-load WARNING; never double-warn here.
            Log:debug("%s central storage cannot isolate STRAW (%s) -- skipped, left untouched",
                tostring(self.typeName), tostring(reason))
            return
        end
        self[AUGMENT_STATE] = { storage = augmentStorage(h.storage, straw, manure) }
        Log:debug("augmented central storage of %s at onLoad (%d fill type(s) added)",
            tostring(self.typeName), #self[AUGMENT_STATE].storage.addedTypes)
        return
    end

    -- Storage nil with a station present (degenerate modded shape), or the storage is
    -- already ours this load -- nothing to build or augment.
    Log:debug("%s owns station state the mod does not build on or augment -- not wiring",
        tostring(self.typeName))
end

---onFinalizePlacement (PREPENDED, before base): station phase for a husbandry whose
--- storage WE built or augmented at onLoad (MARKER). Registration/wiring is left to the
--- base finalize that runs right after -- it sees storage + stations non-nil and
--- registers + wires them itself (we never re-run that registration).
---
--- AUGMENT path (the onLoad revert-record is parked on the placeable): sample the
--- native-straw-intake flag BEFORE any station mutation, then augment the existing
--- UnloadingStation (or build one), and reuse an existing LoadingStation COMPLETELY
--- untouched (or build the trigger-less STRAW-seeded one). ALL-OR-NOTHING: on any failure
--- BOTH the storage and the station end exactly as base built them (surgical reverts;
--- a base object is never deleted or nil'd).
---
--- CLEAN-SLATE path: build BOTH stations; on any failure to fully build (nil node /
--- unresolved fill types), unsubscribe the built storage's FARM_DELETED subscription
--- (leak hardening) and clear Storage AND both stations so the base wires nothing.
---
--- After either path succeeds, force the slice-1 rate-recompute mitigation on
--- this husbandry.
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

    if self[AUGMENT_STATE] ~= nil then
        -- ------------------------------------------------------------------
        -- AUGMENT path: the onLoad augment succeeded; finish the station half.
        -- ------------------------------------------------------------------
        local state = self[AUGMENT_STATE]
        if h.unloadingStation ~= nil and h.unloadingStation[MARKER] == true then
            self[AUGMENT_STATE] = nil -- consume the stale record -- nothing here left to revert
            return -- idempotent -- stations already augmented this load
        end

        local stationRecord = nil -- set once the pre-existing unloadingStation was augmented
        local builtUnloading, builtLoading = nil, nil -- stations WE built THIS call

        -- All-or-nothing: surgically undo every augment mutation so BOTH the storage and
        -- the station end exactly as base built them. Mod-built stations carry no
        -- subscriptions, so nil-ing ONLY the ones we built leaks nothing; a pre-existing
        -- base object is NEVER nil'd or deleted.
        local function abortAugment(reason)
            -- A savegame level the base restore placed onto a type we are about to remove is
            -- unavoidably discarded with it -- name the liters so the loss is never silent.
            local discarded = 0
            for _, fillType in ipairs(state.storage.addedTypes) do
                discarded = discarded + (h.storage.fillLevels[fillType] or 0)
            end
            if discarded > 0 then
                Log:warning("%s: %s -- reverting augment; discarding %.0f l of saved STRAW/MANURE",
                    tostring(self.typeName), reason, discarded)
            else
                Log:warning("%s: %s -- leaving base storage/stations untouched",
                    tostring(self.typeName), reason)
            end
            if stationRecord ~= nil then
                revertStationAugment(h.unloadingStation, stationRecord)
            end
            if builtUnloading ~= nil and h.unloadingStation == builtUnloading then
                h.unloadingStation = nil
            end
            if builtLoading ~= nil and h.loadingStation == builtLoading then
                h.loadingStation = nil
            end
            revertStorageAugment(h.storage, state.storage)
            self[AUGMENT_STATE] = nil
            self[NATIVE_STRAW_INTAKE] = nil
        end

        local straw, manure = RmManureShared.resolveFillTypes()
        if straw == nil or manure == nil then
            abortAugment("STRAW/MANURE fill type unresolved")
            return
        end

        -- Sample BEFORE any station mutation: the flag must record the husbandry's OWN
        -- straw intake, never the support the augment is about to add.
        self[NATIVE_STRAW_INTAKE] = h.unloadingStation ~= nil
            and sampleNativeStrawIntake(h.unloadingStation, straw) or false

        local node = self.components ~= nil and self.components[1] ~= nil and self.components[1].node or nil

        local unloadingReused = h.unloadingStation ~= nil
        if unloadingReused and h.unloadingStation.supportedFillTypes == nil then
            -- Mirrors the storage-side shape gate: a modded/script-built station without its
            -- supported-types table cannot be augmented safely, and a raw error here would
            -- also block the base finalize that runs right after us.
            abortAugment("station without supportedFillTypes (unexpected station shape)")
            return
        end
        if unloadingReused then
            stationRecord = augmentStation(h.unloadingStation, straw, manure)
        else
            if node == nil then
                abortAugment("no component node for the unloading station")
                return
            end
            builtUnloading = buildStrawStation(self, node, straw, manure)
            h.unloadingStation = builtUnloading
        end

        -- A pre-existing loadingStation is reused COMPLETELY untouched (no MARKER, no fill
        -- types): wired-ness never keys on the loadingStation MARKER, and straw stays
        -- one-way IN because STRAW is never added to a trigger-bearing loadingStation's
        -- supported types -- the producer draws straw through the storage->loadingStation
        -- source link (base finalize wires it), which needs no fill-type support.
        local loadingReused = h.loadingStation ~= nil
        if not loadingReused then
            if node == nil then
                abortAugment("no component node for the loading station")
                return
            end
            builtLoading = buildStrawLoadingStation(self, node, straw)
            h.loadingStation = builtLoading
        end

        local addedNames = {}
        for _, fillType in ipairs(state.storage.addedTypes) do
            addedNames[#addedNames + 1] = fillType == straw and "STRAW"
                or (fillType == manure and "MANURE" or tostring(fillType))
        end
        self[AUGMENT_STATE] = nil

        -- Re-read the slice-1 curves now that the sink exists (see mitigation note above).
        recomputeAnimalRates(self)

        Log:info("augmented central storage for %s '%s' (added %s; unloadingStation %s; loadingStation %s)",
            tostring(self.typeName), tostring(self:getName()),
            #addedNames > 0 and table.concat(addedNames, "+") or "nothing",
            unloadingReused and "reused" or "built",
            loadingReused and "reused" or "built")
        return
    end

    -- ----------------------------------------------------------------------
    -- CLEAN-SLATE path: our onLoad-built storage; build BOTH stations.
    -- ----------------------------------------------------------------------
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
    local loadingStation = buildStrawLoadingStation(self, node, straw)
    if unloadingStation == nil or loadingStation == nil then
        abort("station build failed")
        return
    end

    h.unloadingStation = unloadingStation
    h.loadingStation = loadingStation
    -- No pre-existing station -> no native straw intake; recorded explicitly (false, not
    -- absent) so the divert and diagnostics always read a definite value.
    self[NATIVE_STRAW_INTAKE] = false

    -- Re-read the slice-1 curves now that the sink exists (see mitigation note above).
    recomputeAnimalRates(self)

    Log:info("wired straw sink for %s '%s' "
        .. "(Storage + UnloadingStation + LoadingStation; base finalize registers)",
        tostring(self.typeName), tostring(self:getName()))
end

-- ============================================================================
-- POST-LOAD WARNING SWEEP (read-only diagnostic)
--
-- An injected-set husbandry whose central storage the augment path could NOT take (cannot
-- isolate STRAW: single fill type / shared-pool native type; or an augment that had to
-- abort and reverted) still shows the injected "Straw" line but collects no manure -- the
-- player should know. This standalone sweep classifies each such instance (a MARKER'd
-- built/augmented storage is excluded by the classifier's early-out) and logs one WARNING
-- naming the skip reason, plus a per-load summary. The sweep itself mutates nothing --
-- building/augmenting happened (or was skipped) back at onLoad/onFinalizePlacement.
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

---Sweep every placed injected-set husbandry whose pre-existing central storage still
--- lacks STRAW+MANURE (the augment was skipped or aborted); log one WARNING each naming
--- the skip reason, and one per-load summary. Read-only.
---@param placeables table[]|nil defaults to g_currentMission.placeableSystem.placeables
---@return integer warned number of could-not-augment husbandries warned about
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
            local needsWarning, reason = storageNeedsWarning(h.storage, straw, manure)
            if needsWarning then
                warned = warned + 1
                Log:warning("husbandry '%s' (%s): %s -- left untouched; the mod cannot collect its manure",
                    tostring(placeable:getName()), tostring(placeable.typeName), tostring(reason))
            end
        end
    end
    -- Summary only when there is something to report: a "0 incompatible" line every single
    -- load (the common case) would be INFO noise.
    if warned > 0 then
        Log:info("straw pipeline: %d husbandr%s own a central storage the mod could not augment",
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

-- Expose the guards, the augment builders and the lifecycle wrappers for the fakes unit
-- test (pure decision logic + the count-returning sweep + the build-or-augment flow).
-- isLiveHusbandry reads RmSpecInjector.isInjected, the sweep takes its placeable list as
-- a param, and the lifecycle wrappers take the placeable itself -- so all drive off fakes
-- the test injects.
RmStrawSink.isLiveHusbandry = isLiveHusbandry
RmStrawSink.hasNoHusbandryStorage = hasNoHusbandryStorage
RmStrawSink.storageNeedsWarning = storageNeedsWarning
RmStrawSink.warnUnsupportedStorages = warnUnsupportedStorages
RmStrawSink.storageCanIsolateStraw = storageCanIsolateStraw
RmStrawSink.augmentStorage = augmentStorage
RmStrawSink.revertStorageAugment = revertStorageAugment
RmStrawSink.sampleNativeStrawIntake = sampleNativeStrawIntake
RmStrawSink.augmentStation = augmentStation
RmStrawSink.revertStationAugment = revertStationAugment
RmStrawSink.husbandryOnLoad = husbandryOnLoad
RmStrawSink.husbandryOnFinalizePlacement = husbandryOnFinalizePlacement
RmStrawSink.AUGMENT_STATE = AUGMENT_STATE

-- ============================================================================
-- INSTALL (top-level, guarded once per process)
--
-- onLoad is APPENDED (build/augment storage after base sets up spec_husbandry);
-- onFinalizePlacement is PREPENDED (build/augment stations before base registers + wires
-- them). SAVEGAME_LOADED subscribe/unsubscribe
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
