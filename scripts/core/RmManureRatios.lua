--[[
    RmManureRatios.lua

    PURE ratios logic for the animal-IO curve injection: the per-subType
    straw/manure ratio tables (K) plus the two engine-free functions that carry the
    load-bearing branches -- `scaledKeyframes` (scale a food curve + normalize a
    single-keyframe source) and `kForSubType` (subType override -> type default ->
    fallback resolution).

    Split rationale: this is the pure, unit-testable home (and the future
    modSettings home for user-editable K). The engine glue that builds and injects
    the AnimCurves lives in core/RmCurveInjector.lua, which consumes the tables and
    functions exposed here.

    Loaded by scripts/main.lua before RmCurveInjector (the only hard load-time
    dependency is rmlib's logger).

    Author: Ritter
]]

RmManureRatios = {}

-- ============================================================================
-- PER-SUBTYPE K
--
-- The straw/manure ratios applied to the food curve: injected straw = food * straw,
-- injected manure = food * manure. Values are the ADULT (steady-state) straw/food
-- and manure/food ratios read from the animal XMLs -- base data for COW/PIG/HORSE
-- (and water buffalo), and RealisticLivestock for SHEEP/CHICKEN (left undefined by
-- the base game). To be exposed as user-editable modSettings in a later cycle.
--
-- Resolution order: subType-name override -> type-name default -> global fallback.
-- Type defaults cover EVERY subType of that type: SHEEP covers the sheep breeds AND
-- goat (goat is a subType of type SHEEP, not a type); CHICKEN covers CHICKEN and
-- CHICKEN_ROOSTER. In a base game COW/PIG/HORSE are never injected (they already
-- define curves) -- those three exist here only as safety-nets for a map/mod that
-- strips a subType's straw/manure. The one subType override is COW_WATERBUFFALO,
-- whose manure ratio (~0.85) is far above ordinary cattle (~0.55). An unknown modded
-- TYPE lands on K_FALLBACK. Solid manure + straw only; liquidManure stays off.
-- ============================================================================

local K_BY_SUBTYPE = {
    COW_WATERBUFFALO = { straw = 0.25, manure = 0.85 }, -- manure ~0.85 vs ordinary cattle ~0.55
}
local K_BY_TYPE = {
    COW     = { straw = 0.25, manure = 0.55 }, -- ex-buffalo cattle; safety-net (base cows have curves)
    PIG     = { straw = 0.35, manure = 0.60 }, -- safety-net (base pigs have curves)
    SHEEP   = { straw = 0.40, manure = 0.35 }, -- sheep breeds AND goat (all subTypes of type SHEEP)
    HORSE   = { straw = 0.20, manure = 0.50 }, -- safety-net (base horses have curves)
    CHICKEN = { straw = 1.00, manure = 2.00 }, -- CHICKEN + CHICKEN_ROOSTER
}
local K_FALLBACK = { straw = 0.25, manure = 0.50 } -- unknown modded type

-- ============================================================================
-- PURE LOGIC (engine-free, unit-testable)
--
-- These two functions carry the load-bearing branches (single-keyframe
-- normalization, K fallback) and have NO engine dependency, so they are covered
-- by the RmManureRatios in-game suite against the real module. Exposed on the
-- module table for that suite and for RmCurveInjector.
-- ============================================================================

---Scale a food curve's keyframes by k and normalize to a get()-safe (>= 2 kf) shape.
--- Returns a NEW keyframe list `{ [1]=value*k, ["time"]=ageMonth }` in source order.
--- A single-keyframe source (e.g. base CHICKEN food) is normalized to a flat
--- 2-keyframe curve by appending a duplicate value at `time + 1`; a 0-keyframe
--- source returns `{}` (the caller guards against that -- never builds a curve).
---@param keyframes table list of `{ value, ["time"]=ageMonth }` (the source curve's keyframes)
---@param k number scale factor
---@return table out a new keyframe list, length >= 2 unless the source was empty
local function scaledKeyframes(keyframes, k)
    local out = {}
    for i = 1, #keyframes do
        local kf = keyframes[i]
        out[i] = { kf[1] * k, ["time"] = kf.time }        -- value at [1], age in months
    end
    if #out == 1 then                                      -- single-kf source: make get() safe
        -- Duplicate the value at time+1. The +1 delta is arbitrary (any strictly
        -- positive gap works): both keyframes hold the SAME value, so the curve
        -- samples flat at every age and the exact second time never matters.
        out[2] = { out[1][1], ["time"] = out[1].time + 1 }
    end
    return out                                             -- {} for a 0-kf source (caller guards)
end

---Resolve the straw/manure K for a subType: subType-name override, then type-name
--- default, then the global fallback. Never indexes a table with a nil key (a nil
--- name is skipped), so an unresolved subType or type still returns K_FALLBACK.
---@param subTypeName string|nil the UPPERCASE subType name (`subType.name`)
---@param typeName string|nil the UPPERCASE type name (`getTypeByIndex(subType.typeIndex).name`)
---@return table k `{ straw=<ratio>, manure=<ratio> }`
local function kForSubType(subTypeName, typeName)
    return (subTypeName ~= nil and K_BY_SUBTYPE[subTypeName])
        or (typeName ~= nil and K_BY_TYPE[typeName])
        or K_FALLBACK
end

-- Exposed for the in-game suite (no engine deps) and for RmCurveInjector. The K
-- tables are exposed BY REFERENCE so RmCurveInjector's fallback-identity check
-- (`k == RmManureRatios.K_FALLBACK`) tests the same object kForSubType returns.
RmManureRatios.scaledKeyframes = scaledKeyframes
RmManureRatios.kForSubType = kForSubType
RmManureRatios.K_BY_SUBTYPE = K_BY_SUBTYPE
RmManureRatios.K_BY_TYPE = K_BY_TYPE
RmManureRatios.K_FALLBACK = K_FALLBACK
