------------------------------------------------------------------------------
--  FILE:     Lekmap_Luxuries.lua
--  PURPOSE:  Luxury role assignment (regional / city-state / random) and
--            placement for major civs. City-state type pool uses the same
--            terrain weight tables as majors (random host region per pick).
--
--  File layout: CONFIGURATION → runtime state → helpers (distance, coastal) →
--    assignment (AssignToRegion, AssignRoles) → placement (starts, region,
--    random) → orchestrator / accessors.
--
--  Pipeline:
--    • AssignAll(args) — fills GetRegionLuxury() for city-state logic.
--      balancedRegionals: Yes = extended ∪ balanced regional keys; No = balanced only.
--    • PlaceAll(args) — regional near-cap at starts, separate secondary (random-pool)
--      lux, coastal pass (Option 17), CS luxuries, regional scatter, deferred start
--      shortfalls + random world pool (tiles filtered by CITY_STATE impact ripples
--      from spawn + CS placement — same system as Lekmap_Spawns / Lekmap_CityStates).
--
--  Map script / PlaceAll args (see MAJOR_START_OPTIONS):
--    startingLuxuries, additionalStartLuxuries, guaranteedStrategics
--    coastLuxMode (1–5, Option 17 — Lekmap_Spawns)
--    additionalCoastalLuxuries (1–4, Option 24)
--    (camelCase or snake_case; nil = CONFIG defaults.)
------------------------------------------------------------------------------
--  Depends on: Lekmap_Constants, Lekmap_ResourceDefs, Lekmap_Resources,
--              Lekmap_Regions, Lekmap_Spawns, Lekmap_CityStates, Lekmap_Impact, Lekmap_HexUtil, Map, Players
------------------------------------------------------------------------------
--luacheck: globals Lekmap_Luxuries Lekmap_ResourceDefs Lekmap_Resources Lekmap_Regions
--luacheck: globals Lekmap_Spawns Lekmap_CityStates Lekmap_Impact Lekmap_HexUtil Lekmap_Constants
--luacheck: globals Map GameInfo Game Players PlotTypes

Lekmap_Luxuries = {}

------------------------------------------------------------------------------
--  CONFIGURATION — debug (set true for per-swap / shortfall logs)
------------------------------------------------------------------------------

--- Verbose placement logs (reassignments, unplaced shortfalls after cascade).
Lekmap_Luxuries.DEBUG_PLACEMENT = false

local function Dbg(fmt, ...)
    if Lekmap_Luxuries.DEBUG_PLACEMENT then
        print(string.format(fmt, ...))
    end
end

------------------------------------------------------------------------------
--  CONFIGURATION — map-facing defaults (override via PlaceAll / Initialize args)
------------------------------------------------------------------------------

--- Resolved at PlaceAll from args; defaults below if keys omitted.
Lekmap_Luxuries.MAJOR_START_OPTIONS = {
    --- Count of **this region’s land regional** luxury near the capital (ring-weighted).
    starting_luxuries = 3,
    --- **Secondary** start luxury: one pick from the random-pool types (not the regional type).
    --- Unplaced copies are queued for world scatter (away from starts).
    additional_start_luxuries = 1,
    --- Passed through for Lekmap_Strategics later; stored only here for now.
    guaranteed_strategics = true,
}

--[[
  MAJOR_START_LUXURY_SEARCH — ring-weighted tries (same idea as Lekmap_Bonus start bonuses).

  search_ring_max           Max hex ring distance from start for the *additional* pass.
  starting_phase_max_ring   Rings 1..this for the *starting_luxuries* pass only.
  ring_weights              [ring] = weight for additional pass (1..search_ring_max).
  starting_ring_weights     optional; if omitted, starting pass uses ring_weights clamped to starting_phase_max_ring.
]]
Lekmap_Luxuries.MAJOR_START_LUXURY_SEARCH = {
    search_ring_max           = 3,
    starting_phase_max_ring   = 3,
    ring_weights              = { [1] = 40, [2] = 30, [3] = 18 },
    starting_ring_weights     = { [1] = 55, [2] = 45, [3] = 15 },
}

--[[
  REGIONAL_LUXURY_DISTANCE_RULES — extra copies of the regional luxury inside the map region.

  max_hex_ring_from_own_major_start
      If set and > 0, candidate plots must be within this hex distance of this region's major start.
      If nil or <= 0, no max (whole region rectangle from GeneratePlotListInRegion).

  min_hex_ring_from_other_major_start
      If set and > 0, candidate must be at least this far from every other major start
      (graph distance in hex rings), unless same_team_ignores_other_player_clearance applies.

  same_team_ignores_other_player_clearance
      If true, skip the "min distance to other start" check when the other region's player
      is on the same team as this region's player (requires Players[] + GetTeam()).
]]
Lekmap_Luxuries.REGIONAL_LUXURY_DISTANCE_RULES = {
    max_hex_ring_from_own_major_start       = 12,
    min_hex_ring_from_other_major_start     = 8,
    same_team_ignores_other_player_clearance = true,
}

--[[
  REGIONAL_LUXURY_WEIGHTS_BY_TERRAIN — bonus-style maps only: [terrain_type][luxuryKey] = weight.
  terrain_type: 1 TUNDRA … 9 WETLANDS (Lekmap_Regions.GetRegionType).

  Used when rolling which luxury is assigned as *the* regional type for each map region.
  Omit a key or use weight <= 0 to exclude. Higher weight = more likely when eligible.

  Balanced Regionals (map option) + subclasses:
    • EXTENDED_REGIONAL_LUXURY_KEYS — “non‑balanced” pool (e.g. coast luxuries). These may be
      assigned as regionals only when Balanced Regionals = Yes (both pools allowed).
    • BALANCED_REGIONAL_LUXURY_KEYS — optional explicit allow‑list for strict mode. If nil,
      every luxury not in EXTENDED_REGIONAL_LUXURY_KEYS counts as balanced (land‑style default).
    When Balanced Regionals = No: only keys in the balanced pool may be regionals.
    When Yes: balanced ∪ extended may be regionals (still gated by weights + active + split cap).
]]
local function _LuxuryWeightMapFromPairs(pairs_list)
    local m = {}
    for _, e in ipairs(pairs_list) do
        m[e[1]] = e[2]
    end
    return m
end

--- Terrain regional rolls exclude Coastal Luxuries — those use Option 17 + coastal placement only.
Lekmap_Luxuries.REGIONAL_LUXURY_WEIGHTS_BY_TERRAIN = {
    [1] = _LuxuryWeightMapFromPairs({ -- TUNDRA
        { "FUR", 40 }, { "MARBLE", 10 }, { "SILVER", 40 }, { "AMBER", 40 },
        { "SALT", 40 }, { "GOLD", 10 }, { "COPPER", 10 }, { "GEMS", 10 },
        { "JADE", 10 }, { "LAPIS", 10 }, { "OBSIDIAN", 10 },
    }),
    [2] = _LuxuryWeightMapFromPairs({ -- JUNGLE
        { "CITRUS", 40 }, { "COCOA", 40 }, { "SPICES", 40 }, { "SUGAR", 40 },
        { "OBSIDIAN", 40 }, { "COCONUT", 40 }, { "RUBBER", 40 }, { "TRUFFLES", 40 },
        { "SILK", 10 }, { "DYE", 10 }, { "FUR", 10 },
    }),
    [3] = _LuxuryWeightMapFromPairs({ -- FOREST
        { "TRUFFLES", 40 }, { "MARBLE", 5 }, { "SILK", 30 }, { "DYE", 30 },
        { "FUR", 40 }, { "COCONUT", 30 }, { "RUBBER", 10 }, { "CITRUS", 40 },
        { "COCOA", 30 }, { "SPICES", 30 }, { "SUGAR", 10 },
    }),
    [4] = _LuxuryWeightMapFromPairs({ -- DESERT
        { "INCENSE", 40 }, { "MARBLE", 5 }, { "SALT", 40 }, { "GOLD", 40 },
        { "LAPIS", 40 }, { "OBSIDIAN", 10 }, { "COPPER", 10 }, { "SILVER", 10 },
        { "AMBER", 10 }, { "GEMS", 10 }, { "JADE", 10 },
    }),
    [5] = _LuxuryWeightMapFromPairs({ -- HILLS
        { "GOLD", 30 }, { "MARBLE", 15 }, { "SILVER", 30 }, { "COPPER", 30 },
        { "GEMS", 30 }, { "SALT", 30 }, { "JADE", 30 }, { "AMBER", 30 },
        { "LAPIS", 30 }, { "OBSIDIAN", 30 },
    }),
    [6] = _LuxuryWeightMapFromPairs({ -- PLAINS
        { "INCENSE", 40 }, { "MARBLE", 10 }, { "IVORY", 40 }, { "WINE", 40 },
        { "OLIVE", 40 }, { "COFFEE", 40 }, { "TOBACCO", 10 }, { "TEA", 10 },
        { "PERFUME", 40 }, { "COTTON", 10 },
    }),
    [7] = _LuxuryWeightMapFromPairs({ -- GRASS
        { "TOBACCO", 40 }, { "MARBLE", 10 }, { "TEA", 40 }, { "COTTON", 40 },
        { "PERFUME", 25 }, { "IVORY", 10 }, { "WINE", 10 }, { "OLIVE", 25 },
        { "COFFEE", 25 },
    }),
    [8] = _LuxuryWeightMapFromPairs({ -- HYBRID
        { "GOLD", 30 }, { "MARBLE", 15 }, { "SILVER", 30 }, { "COPPER", 30 },
        { "GEMS", 30 }, { "SALT", 30 }, { "JADE", 30 }, { "AMBER", 30 },
        { "LAPIS", 30 }, { "OBSIDIAN", 30 }, { "COFFEE", 5 }, { "COCONUT", 5 },
        { "RUBBER", 5 }, { "TOBACCO", 5 }, { "TEA", 5 }, { "PERFUME", 5 },
        { "COTTON", 5 }, { "IVORY", 5 }, { "WINE", 5 }, { "OLIVE", 5 },
        { "INCENSE", 5 }, { "TRUFFLES", 5 }, { "SILK", 5 }, { "DYE", 5 },
        { "FUR", 5 }, { "CITRUS", 5 }, { "COCOA", 5 }, { "SPICES", 5 },
        { "SUGAR", 5 },
    }),
    [9] = _LuxuryWeightMapFromPairs({ -- WETLANDS
        { "TOBACCO", 40 }, { "TEA", 40 }, { "PERFUME", 20 }, { "COTTON", 30 },
        { "OLIVE", 20 }, { "SILVER", 20 }, { "SUGAR", 20 }, { "COPPER", 20 }, 
        { "COCONUT", 30 },
        { "RUBBER", 5 }, { "COCOA", 10 }, { "TRUFFLES", 5 },
        { "SPICES", 5 }, { "GEMS", 20 },
    }),
}

--- “Extended” subclass: may be regional only when map option Balanced Regionals = Yes.
Lekmap_Luxuries.EXTENDED_REGIONAL_LUXURY_KEYS = {
    SALT   = true,
    RUBBER    = true,
    SPICES  = true,
    GEMS   = true,
    PERFUME   = true,
}

--- Optional explicit balanced pool. If set, strict mode (Balanced Regionals = No) only allows
--- these keys (plus usual active/split/weight checks). If nil, balanced = “not in extended”.
Lekmap_Luxuries.BALANCED_REGIONAL_LUXURY_KEYS = nil

--- WHALE / CRAB / PEARLS: not chosen from REGIONAL_LUXURY_WEIGHTS_BY_TERRAIN; use Option 17 pipeline.
Lekmap_Luxuries.CORE_COAST_LUXURY_KEYS = {
    WHALE   = true,
    CRAB    = true,
    PEARLS  = true,
    CORAL   = true,
}

--- Weighted type roll when a start qualifies for a guaranteed coastal luxury (Option 17).
Lekmap_Luxuries.COASTAL_LUXURY_WEIGHTS = {
    WHALE   = 25,
    CRAB    = 25,
    PEARLS  = 25,
    CORAL   = 25
}

------------------------------------------------------------------------------
--  LUXURY_TARGETS — all “how many / how big” knobs in one place
--
--  Roles (types in the trade game):
--    • Regional — one land luxury type per major region (from terrain weights).
--    • Coastal  — optional second type per coast-qualified start (Option 17).
--    • CS       — up to `city_state_luxury_type_count` types for city-states.
--    • Random   — `random_pool_type_count.base_by_world_size` + uniform 0..random_extra_max types.
--    • Disabled — active luxuries not picked above.
--
--  Tiles (resource instances):
--    • Per major: target luxury tiles for that civ’s regional type = **number of majors** (simple).
--    • World phase: `world_luxury_tile_goal[density][world]` = { total_map_goal, min_per_random_type }.
------------------------------------------------------------------------------

do
    local W = GameInfo.Worlds

    Lekmap_Luxuries.LUXURY_TARGETS = {
        --- Weighted picks: how many distinct lux types to assign to the CS pool.
        city_state_luxury_type_count = {
            [W.WORLDSIZE_DUEL.ID]     = 3,
            [W.WORLDSIZE_TINY.ID]     = 3,
            [W.WORLDSIZE_SMALL.ID]    = 4,
            [W.WORLDSIZE_STANDARD.ID] = 4,
            [W.WORLDSIZE_LARGE.ID]    = 4,
            [W.WORLDSIZE_HUGE.ID]     = 4,
        },

        --- Random-pool type count = base_by_world_size[world] + Map.Rand(random_extra_max + 1) (0..max inclusive).
        random_pool_type_count = {
            base_by_world_size = {
                [W.WORLDSIZE_DUEL.ID]     = 6,
                [W.WORLDSIZE_TINY.ID]     = 8,
                [W.WORLDSIZE_SMALL.ID]    = 12,
                [W.WORLDSIZE_STANDARD.ID] = 14,
                [W.WORLDSIZE_LARGE.ID]    = 18,
                [W.WORLDSIZE_HUGE.ID]     = 22,
            },
            --- Extra types rolled each generation (0 .. random_extra_max). Set 0 for a fixed pool size.
            random_extra_max = 4,
            --- If set, used when world size id is missing from base_by_world_size.
            default_base = 12,
        },

        --- World scatter phase: { target_total_luxury_tiles_on_map, min_tiles_per_random_type }.
        world_luxury_tile_goal = {
            sparse = {
                [W.WORLDSIZE_DUEL.ID]     = { 14, 3 },
                [W.WORLDSIZE_TINY.ID]     = { 24, 4 },
                [W.WORLDSIZE_SMALL.ID]    = { 36, 4 },
                [W.WORLDSIZE_STANDARD.ID] = { 48, 5 },
                [W.WORLDSIZE_LARGE.ID]    = { 60, 5 },
                [W.WORLDSIZE_HUGE.ID]     = { 76, 6 },
            },
            normal = {
                [W.WORLDSIZE_DUEL.ID]     = { 20, 3 },
                [W.WORLDSIZE_TINY.ID]     = { 35, 4 },
                [W.WORLDSIZE_SMALL.ID]    = { 60, 5 },
                [W.WORLDSIZE_STANDARD.ID] = { 60, 5 },
                [W.WORLDSIZE_LARGE.ID]    = { 88, 5 },
                [W.WORLDSIZE_HUGE.ID]     = { 112, 6 },
            },
            abundant = {
                [W.WORLDSIZE_DUEL.ID]     = { 24, 3 },
                [W.WORLDSIZE_TINY.ID]     = { 40, 4 },
                [W.WORLDSIZE_SMALL.ID]    = { 80, 5 },
                [W.WORLDSIZE_STANDARD.ID] = { 80, 5 },
                [W.WORLDSIZE_LARGE.ID]    = { 100, 5 },
                [W.WORLDSIZE_HUGE.ID]     = { 128, 6 },
            },
        },
    }
end

--- Maximum regions that may share the same regional luxury type.
function Lekmap_Luxuries.GetSplitCap(num_civs)
    if num_civs > 16 then return 2 end
    return 1
end

function Lekmap_Luxuries.GetCSTarget()
    local t = Lekmap_Luxuries.LUXURY_TARGETS.city_state_luxury_type_count
    return t[Map.GetWorldSize()] or 4
end

function Lekmap_Luxuries.GetRandomTarget()
    local cfg = Lekmap_Luxuries.LUXURY_TARGETS.random_pool_type_count
    local ws = Map.GetWorldSize()
    local base_tbl = cfg.base_by_world_size or {}
    local base = base_tbl[ws] or cfg.default_base or 12
    base = math.max(0, math.floor(tonumber(base) or 0))
    local extra_max = math.max(0, math.floor(tonumber(cfg.random_extra_max) or 0))
    if extra_max <= 0 then
        return base
    end
    return base + Map.Rand(extra_max + 1, "Lekmap_Luxuries random pool type extra")
end

--- Target luxury tiles per major for their regional type (= major count for every map).
function Lekmap_Luxuries.GetPerRegionLuxuryTileTarget()
    local n = Lekmap_Regions.GetRegionCount()
    if n < 1 then return 1 end
    return n
end

--- Legacy shape for older callers: { [numMajors] = numMajors }.
function Lekmap_Luxuries.GetRegionTargets()
    local n = math.max(1, Lekmap_Regions.GetRegionCount())
    return { [n] = n }
end

function Lekmap_Luxuries.GetWorldTargets(resource_setting)
    local goals = Lekmap_Luxuries.LUXURY_TARGETS.world_luxury_tile_goal
    local set
    if resource_setting <= 3 then
        set = goals.sparse
    elseif resource_setting >= 7 then
        set = goals.abundant
    else
        set = goals.normal
    end
    local ws = Map.GetWorldSize()
    return set[ws] or set[GameInfo.Worlds.WORLDSIZE_STANDARD.ID] or { 60, 5 }
end

------------------------------------------------------------------------------
--  PRIVATE STATE
------------------------------------------------------------------------------

local region_luxury           = {}
--- Per-region coastal luxury (WHALE/CRAB/PEARLS) when Option 17 allows and start qualifies.
local region_coastal_luxury   = {}
local luxury_assignment_count = {}
local assigned_to_regions     = {}
local assigned_to_cs          = {}
local assigned_to_random      = {}
local disabled_luxuries       = {}
local num_types_assigned_to_regions = 0

--- Filled in PlaceAll from args + MAJOR_START_OPTIONS.
local resolved_starting_luxuries          = 3
local resolved_additional_start_luxuries  = 1
local resolved_guaranteed_strategics      = true
--- True when map “Balanced Regionals” = Yes: regional rolls may use extended + balanced pools.
local resolved_allow_extended_regional_pool = true
--- Option 24: 1 Allowed, 2 Not Allowed, 3 Ocean Only, 4 Inland Sea Only (extra regional scatter).
local resolved_additional_coastal_mode      = 1

--- { { key = "GOLD", count = n }, ... } — regional/secondary lux not placed at starts → world pass.
local pending_world_luxury_shortfalls       = {}

------------------------------------------------------------------------------
--  RUNTIME OPTIONS (for Strategics / debug)
------------------------------------------------------------------------------

function Lekmap_Luxuries.GetResolvedStartingLuxuryCount()
    return resolved_starting_luxuries
end

function Lekmap_Luxuries.GetResolvedAdditionalStartLuxuryCount()
    return resolved_additional_start_luxuries
end

function Lekmap_Luxuries.GetGuaranteedStrategics()
    return resolved_guaranteed_strategics == true
end

function Lekmap_Luxuries.GetAllowExtendedRegionalLuxuries()
    return resolved_allow_extended_regional_pool == true
end

function Lekmap_Luxuries.GetAdditionalCoastalLuxuriesMode()
    return resolved_additional_coastal_mode
end

function Lekmap_Luxuries.IsCoreCoastLuxuryKey(key)
    return Lekmap_Luxuries.CORE_COAST_LUXURY_KEYS[key] == true
end

local function ResolveAssignOptions(args)
    args = args or {}
    local v = args.balancedRegionals
    if v == nil then v = args.balanced_regionals end
    if v == nil then
        resolved_allow_extended_regional_pool = true
    else
        resolved_allow_extended_regional_pool = (v ~= false and v ~= 0)
    end
end

--- Balanced Regionals = No → only “balanced” subclass. Yes → balanced ∪ extended.
local function LuxuryKeyEligibleForRegionalAssignment(key)
    local ext_set = Lekmap_Luxuries.EXTENDED_REGIONAL_LUXURY_KEYS
    local bal_set = Lekmap_Luxuries.BALANCED_REGIONAL_LUXURY_KEYS
    local in_ext = ext_set and ext_set[key] == true
    local in_bal
    if bal_set then
        in_bal = bal_set[key] == true
    else
        in_bal = not in_ext
    end
    if resolved_allow_extended_regional_pool then
        return in_bal or in_ext
    end
    return in_bal
end

--- Read-only: bonus-style weight map for a terrain class (1–9), or empty {}.
function Lekmap_Luxuries.GetRegionalLuxuryWeightsForTerrain(region_type)
    local t = Lekmap_Luxuries.REGIONAL_LUXURY_WEIGHTS_BY_TERRAIN[region_type]
    return t or {}
end

--- Per-key max weight across REGIONAL_LUXURY_WEIGHTS_BY_TERRAIN (terrain 1–9).
local function BuildMergedRegionalMaxWeights()
    local merged = {}
    for terrain = 1, 9 do
        local wm = Lekmap_Luxuries.REGIONAL_LUXURY_WEIGHTS_BY_TERRAIN[terrain]
        if wm then
            for key, w in Lekmap_Utilities.OrderedPairs(wm) do
                w = tonumber(w) or 0
                if w > 0 then
                    merged[key] = math.max(merged[key] or 0, w)
                end
            end
        end
    end
    return merged
end

local function SortKeysByMergedWeightDesc(keys, merged_weights)
    local rows = {}
    for _, k in ipairs(keys) do
        table.insert(rows, { k = k, w = tonumber(merged_weights[k]) or 0 })
    end
    table.sort(rows, function(a, b)
        if a.w ~= b.w then return a.w > b.w end
        return a.k < b.k
    end)
    local out = {}
    for _, r in ipairs(rows) do
        table.insert(out, r.k)
    end
    return out
end

--- Active luxury keys (any class luxury in ResourceDefs.active), optional filter.
local function CollectAllActiveLuxuryKeysSorted()
    local t = {}
    local active = Lekmap_ResourceDefs.active
    if not active then return t end
    for key, entry in Lekmap_Utilities.OrderedPairs(active) do
        if entry.def and entry.def.class == "luxury" then
            table.insert(t, key)
        end
    end
    table.sort(t)
    return t
end

local function ResolvePlaceAllOptions(args)
    args = args or {}
    local base = Lekmap_Luxuries.MAJOR_START_OPTIONS
    local function pick(camel, snake, default)
        local v = args[camel]
        if v == nil then v = args[snake] end
        if v == nil then v = default end
        return v
    end
    resolved_starting_luxuries = math.max(0, math.floor(tonumber(pick("startingLuxuries", "starting_luxuries", base.starting_luxuries)) or base.starting_luxuries))
    resolved_additional_start_luxuries = math.max(0, math.floor(tonumber(pick("additionalStartLuxuries", "additional_start_luxuries", base.additional_start_luxuries)) or base.additional_start_luxuries))
    local gs = pick("guaranteedStrategics", "guaranteed_strategics", base.guaranteed_strategics)
    resolved_guaranteed_strategics = (gs ~= false and gs ~= 0)
    local ac = pick("additionalCoastalLuxuries", "additional_coastal_luxuries", 1)
    resolved_additional_coastal_mode = math.max(1, math.min(4, math.floor(tonumber(ac) or 1)))
end

------------------------------------------------------------------------------
--  HELPERS — hex distance, teams, plot lists
------------------------------------------------------------------------------

--- Hex ring distance between two plots (0 = same tile). Caps at max_cap for safety.
local function PlotHexDistance(x1, y1, x2, y2, max_cap)
    max_cap = max_cap or 200
    if x1 == x2 and y1 == y2 then
        return 0
    end
    local center = Map.GetPlot(x1, y1)
    local target = Map.GetPlot(x2, y2)
    if not center or not target then
        return max_cap
    end
    for ring = 1, max_cap do
        for ring_plot in Lekmap_HexUtil.PlotRingIterator(center, ring) do
            if ring_plot:GetX() == x2 and ring_plot:GetY() == y2 then
                return ring
            end
        end
    end
    return max_cap
end

--- World / deferred luxury scatter: skip tiles inside the **CITY_STATE** impact ripples.
--- Those ripples are stamped during start choice (major CS buffer; see Lekmap_Spawns.PlaceSpawnImpact)
--- and city-state placement (Lekmap_CityStates.ApplyCSImpact) — same rules CS placement uses
--- to stay clear of majors and each other. (PLAYER_SPAWN is not used here: overlapping major
--- ripples cover most of the map and would starve scatter.)
local function FilterPlotListExcludingCityStateRipple(plot_list)
    if not plot_list or #plot_list == 0 then
        return plot_list or {}
    end
    local IMPACT_LAYER = Lekmap_Constants.IMPACT_LAYER
    local cache = Lekmap_Resources.GetPlotCache()
    local out = {}
    for _, plot_index in ipairs(plot_list) do
        local e = cache[plot_index]
        if e and not Lekmap_Impact.IsImpacted(IMPACT_LAYER.CITY_STATE, e.x, e.y) then
            table.insert(out, plot_index)
        end
    end
    for i = #out, 2, -1 do
        local j = Map.Rand(i, "Lekmap_Luxuries world lux CS-layer filter shuffle") + 1
        out[i], out[j] = out[j], out[i]
    end
    return out
end

local function SameMajorTeam(region_index_a, region_index_b)
    local pa = Lekmap_Spawns.GetPlayerForRegion(region_index_a)
    local pb = Lekmap_Spawns.GetPlayerForRegion(region_index_b)
    if not pa or not pb then
        return false
    end
    local pla = Players[pa]
    local plb = Players[pb]
    if not pla or not plb or pla:IsMinorCiv() or plb:IsMinorCiv() then
        return false
    end
    return pla:GetTeam() == plb:GetTeam()
end

--- Keep plot indices that satisfy REGIONAL_LUXURY_DISTANCE_RULES for this region.
local function FilterPlotListForRegionalDistance(plot_list, region_index)
    local rules = Lekmap_Luxuries.REGIONAL_LUXURY_DISTANCE_RULES
    if not plot_list or #plot_list == 0 then
        return plot_list
    end

    local own = Lekmap_Spawns.GetStartPlot(region_index)
    local max_own = rules.max_hex_ring_from_own_major_start
    local min_other = rules.min_hex_ring_from_other_major_start
    local ignore_team = rules.same_team_ignores_other_player_clearance == true
    local num_regions = Lekmap_Regions.GetRegionCount()
    local plot_cache = Lekmap_Resources.GetPlotCache()

    local need_max = max_own and max_own > 0
    local need_min = min_other and min_other > 0

    if not need_max and not need_min then
        return plot_list
    end

    local out = {}
    for _, plot_index in ipairs(plot_list) do
        local entry = plot_cache[plot_index]
        if entry then
            local px, py = entry.x, entry.y
            local ok = true

            if need_max and own and own.x ~= nil and own.y ~= nil then
                if PlotHexDistance(px, py, own.x, own.y) > max_own then
                    ok = false
                end
            end

            if ok and need_min then
                for other_r = 1, num_regions do
                    if other_r ~= region_index then
                        if not (ignore_team and SameMajorTeam(region_index, other_r)) then
                            local osp = Lekmap_Spawns.GetStartPlot(other_r)
                            if osp and osp.x ~= nil and osp.y ~= nil then
                                if PlotHexDistance(px, py, osp.x, osp.y) < min_other then
                                    ok = false
                                    break
                                end
                            end
                        end
                    end
                end
            end

            if ok then
                table.insert(out, plot_index)
            end
        end
    end

    for i = #out, 2, -1 do
        local j = Map.Rand(i, "Lekmap_Luxuries regional filter shuffle") + 1
        out[i], out[j] = out[j], out[i]
    end
    return out
end

local function PlotTouchesOcean(plot)
    if not plot then return false end
    if plot:IsWater() then return Lekmap_Utilities.GetWaterKind(plot) == "ocean" end
    return Lekmap_Utilities.AdjacentToOcean(plot:GetX(), plot:GetY())
end

local function PlotIsInlandSeaCoastalLandPlot(plot)
    if not plot then return false end
    if plot:IsWater() then return Lekmap_Utilities.GetWaterKind(plot) == "inland_sea" end
    return Lekmap_Utilities.AdjacentToInlandSea(plot:GetX(), plot:GetY())
end

--- Option 17: start plot qualifies for one guaranteed WHALE/CRAB/PEARLS near capital.
local function StartQualifiesForCoastalLuxury(region_index)
    local mode = Lekmap_Spawns.GetCoastLuxMode()
    if mode == 5 or mode == 2 then
        return false
    end
    local sc = Lekmap_Spawns.GetStartConditions(region_index)
    if not sc then
        return false
    end
    if mode == 1 then
        return sc.along_ocean == true
    end
    if mode == 3 then
        if sc.along_ocean then return true end
        return Lekmap_Spawns.GetAllowInlandSea() and sc.along_inland_sea_coast == true
    end
    if mode == 4 then
        return sc.along_inland_sea_coast == true
    end
    return false
end

--- Option 24 filters for extra regional scatter of coastal luxuries.
local function FilterPlotListForAdditionalCoastalMode(plot_list, mode)
    if not plot_list or #plot_list == 0 then
        return plot_list or {}
    end
    if mode == 1 then
        return plot_list
    end
    if mode == 2 then
        return {}
    end
    local map_w = select(1, Lekmap_Resources.GetMapDimensions())
    local out = {}
    for _, plot_index in ipairs(plot_list) do
        local i0 = plot_index - 1
        local y = math.floor(i0 / map_w)
        local x = i0 - y * map_w
        local plot = Map.GetPlot(x, y)
        if plot then
            if mode == 3 and PlotTouchesOcean(plot) then
                table.insert(out, plot_index)
            elseif mode == 4 and PlotIsInlandSeaCoastalLandPlot(plot) then
                table.insert(out, plot_index)
            end
        end
    end
    for i = #out, 2, -1 do
        local j = Map.Rand(i, "Lekmap_Luxuries coastal extra filter shuffle") + 1
        out[i], out[j] = out[j], out[i]
    end
    return out
end

------------------------------------------------------------------------------
--  WEIGHTED ROLL (role assignment) — defined before coastal roll uses it
------------------------------------------------------------------------------

local function WeightedRoll(keys, weights)
    local total_weight = 0
    for _, w in ipairs(weights) do total_weight = total_weight + w end
    if total_weight <= 0 then return nil end

    local accumulated = 0
    local thresholds = {}
    for i, w in ipairs(weights) do
        accumulated = accumulated + w
        thresholds[i] = accumulated * 10000 / total_weight
    end

    local roll = Map.Rand(10000, "Luxury weighted roll")
    for i, t in ipairs(thresholds) do
        if roll < t then
            local chosen = keys[i]
            table.remove(keys, i)
            table.remove(weights, i)
            return chosen
        end
    end
    local last = #keys
    local chosen = keys[last]
    table.remove(keys, last)
    table.remove(weights, last)
    return chosen
end

local function RollCoastalLuxuryType()
    local split_cap = Lekmap_Luxuries.GetSplitCap(Lekmap_Regions.GetRegionCount())
    local keys, weights = {}, {}
    for key, w in Lekmap_Utilities.OrderedPairs(Lekmap_Luxuries.COASTAL_LUXURY_WEIGHTS) do
        w = tonumber(w) or 0
        if w > 0 and Lekmap_ResourceDefs.IsActive(key) and Lekmap_Luxuries.IsCoreCoastLuxuryKey(key) then
            local count = luxury_assignment_count[key] or 0
            if count < split_cap then
                table.insert(keys, key)
                table.insert(weights, w)
            end
        end
    end
    if #keys == 0 then
        return nil
    end
    return WeightedRoll(keys, weights)
end

------------------------------------------------------------------------------
--  HELPERS — weighted ring pick (major start luxuries)
------------------------------------------------------------------------------

local function PickWeightedRing(weights_by_ring, max_ring)
    if max_ring < 1 then
        return 1
    end
    local total = 0
    for ring_index = 1, max_ring do
        total = total + (weights_by_ring[ring_index] or 0)
    end
    if total <= 0 then
        return 1 + Map.Rand(max_ring, "Lekmap_Luxuries ring uniform")
    end
    local roll = Map.Rand(total, "Lekmap_Luxuries ring weight")
    local acc = 0
    for ring_index = 1, max_ring do
        acc = acc + (weights_by_ring[ring_index] or 0)
        if roll < acc then
            return ring_index
        end
    end
    return max_ring
end

--- Try to place one luxury at (x,y); uses Lekmap_Resources.PlaceOne (luxury impact from class).
local function TryPlaceLuxuryAt(key, x, y, start_plot, radius)
    if start_plot and not Lekmap_Resources.CanSupplyStart(key, x, y, start_plot, radius) then return false end
    if Lekmap_Resources.IsCollision(x, y) then
        return false
    end
    local plot = Map.GetPlot(x, y)
    if not plot or plot:GetResourceType(-1) ~= -1 then
        return false
    end
    Lekmap_Resources.RefreshPlotCacheAt(x, y)
    local map_w = select(1, Lekmap_Resources.GetMapDimensions())
    local idx = y * map_w + x + 1
    local entry = (Lekmap_Resources.GetPlotCache())[idx]
    if not entry then
        return false
    end
    local active = Lekmap_ResourceDefs.active and Lekmap_ResourceDefs.active[key]
    if not active then
        return false
    end
    if not Lekmap_Resources.IsValidPlotForResource(entry, active.def) then
        return false
    end
    return Lekmap_Resources.PlaceOne(x, y, key, 1)
end

--- Place `count` luxuries via weighted ring search from start_plot.
--- @param max_attempts optional cap on outer tries (default count * 25).
--- @param desperate_ring_max if set, when normal ring_cap exhausted occasionally try rings up to this.
local function PlaceLuxuriesRingWeighted(start_plot, key, count, weights_by_ring, ring_cap, max_attempts, desperate_ring_max)
    if count < 1 or not start_plot or start_plot.x == nil or start_plot.y == nil then
        return count
    end
    ring_cap = math.max(1, ring_cap or 1)
    desperate_ring_max = desperate_ring_max and math.max(ring_cap, desperate_ring_max) or ring_cap
    local left = count
    local attempts = 0
    max_attempts = max_attempts or (count * 25)
    while left > 0 and attempts < max_attempts do
        attempts = attempts + 1
        local ring = PickWeightedRing(weights_by_ring, ring_cap)
        local indices = Lekmap_Resources.GetShuffledRingPlotIndices(start_plot.x, start_plot.y, ring)
        local placed_this = false
        for _, plot_index in ipairs(indices) do
            local map_w = select(1, Lekmap_Resources.GetMapDimensions())
            local i0 = plot_index - 1
            local y = math.floor(i0 / map_w)
            local x = i0 - y * map_w
            if TryPlaceLuxuryAt(key, x, y, start_plot, desperate_ring_max) then
                left = left - 1
                placed_this = true
                break
            end
        end
        if not placed_this and ring == ring_cap then
            -- expand: try uniform ring fallback
            ring = 1 + Map.Rand(ring_cap, "Lekmap_Luxuries ring fallback")
            indices = Lekmap_Resources.GetShuffledRingPlotIndices(start_plot.x, start_plot.y, ring)
            for _, plot_index in ipairs(indices) do
                local map_w = select(1, Lekmap_Resources.GetMapDimensions())
                local i0 = plot_index - 1
                local yy = math.floor(i0 / map_w)
                local xx = i0 - yy * map_w
                if TryPlaceLuxuryAt(key, xx, yy, start_plot, desperate_ring_max) then
                    left = left - 1
                    placed_this = true
                    break
                end
            end
        end
        if not placed_this and desperate_ring_max > ring_cap and Map.Rand(5, "Lekmap_Luxuries desperate ring") == 0 then
            local dr = ring_cap + 1 + Map.Rand(desperate_ring_max - ring_cap, "Lekmap_Luxuries desperate pick")
            indices = Lekmap_Resources.GetShuffledRingPlotIndices(start_plot.x, start_plot.y, dr)
            for _, plot_index in ipairs(indices) do
                local map_w = select(1, Lekmap_Resources.GetMapDimensions())
                local i0 = plot_index - 1
                local yy = math.floor(i0 / map_w)
                local xx = i0 - yy * map_w
                if TryPlaceLuxuryAt(key, xx, yy, start_plot, desperate_ring_max) then
                    left = left - 1
                    placed_this = true
                    break
                end
            end
        end
    end
    return left
end

local function IsMember(list, value)
    for _, v in ipairs(list) do
        if v == value then return true end
    end
    return false
end

--- Terrain weight map → keys/weights for assignment rolls (respects split cap + luxury_assignment_count).
local function CollectRegionalCandidatesFromWeightMap(weight_map, split_cap)
    local keys, weights = {}, {}
    if not weight_map then
        return keys, weights
    end
    split_cap = split_cap or 1
    for key, w in Lekmap_Utilities.OrderedPairs(weight_map) do
        w = tonumber(w) or 0
        if w > 0
            and Lekmap_ResourceDefs.IsActive(key)
            and not Lekmap_Luxuries.IsCoreCoastLuxuryKey(key)
            and LuxuryKeyEligibleForRegionalAssignment(key) then
            local count = luxury_assignment_count[key] or 0
            if count < split_cap then
                table.insert(keys, key)
                table.insert(weights, w)
            end
        end
    end
    return keys, weights
end

------------------------------------------------------------------------------
--  ROLE ASSIGNMENT
------------------------------------------------------------------------------

function Lekmap_Luxuries.AssignToRegion(region_index)
    local region_type = Lekmap_Regions.GetRegionType(region_index)
    local weight_map = Lekmap_Luxuries.REGIONAL_LUXURY_WEIGHTS_BY_TERRAIN[region_type]

    local split_cap = Lekmap_Luxuries.GetSplitCap(Lekmap_Regions.GetRegionCount())
    local keys, weights = CollectRegionalCandidatesFromWeightMap(weight_map, split_cap)

    if #keys == 0 then
        local merged = BuildMergedRegionalMaxWeights()
        keys, weights = {}, {}
        for key, w in Lekmap_Utilities.OrderedPairs(merged) do
            w = tonumber(w) or 0
            if w > 0
                and Lekmap_ResourceDefs.IsActive(key)
                and not Lekmap_Luxuries.IsCoreCoastLuxuryKey(key)
                and LuxuryKeyEligibleForRegionalAssignment(key) then
                local count = luxury_assignment_count[key] or 0
                if count < split_cap then
                    table.insert(keys, key)
                    table.insert(weights, w)
                end
            end
        end
    end

    if #keys == 0 then
        for _, key in ipairs(CollectAllActiveLuxuryKeysSorted()) do
            if not Lekmap_Luxuries.IsCoreCoastLuxuryKey(key)
                and LuxuryKeyEligibleForRegionalAssignment(key) then
                local count = luxury_assignment_count[key] or 0
                if count < split_cap then
                    table.insert(keys, key)
                    table.insert(weights, 1)
                end
            end
        end
    end

    if #keys == 0 then
        print("Lekmap_Luxuries: WARNING - no luxury candidates for region " .. region_index)
        return nil
    end

    return WeightedRoll(keys, weights)
end

function Lekmap_Luxuries.AssignRoles()
    local num_regions = Lekmap_Regions.GetRegionCount()

    region_luxury               = {}
    region_coastal_luxury     = {}
    luxury_assignment_count     = {}
    assigned_to_regions         = {}
    assigned_to_cs              = {}
    assigned_to_random          = {}
    disabled_luxuries           = {}
    num_types_assigned_to_regions = 0

    for r = 1, num_regions do
        local key = Lekmap_Luxuries.AssignToRegion(r)
        if key then
            region_luxury[r] = key
            luxury_assignment_count[key] = (luxury_assignment_count[key] or 0) + 1
            if not IsMember(assigned_to_regions, key) then
                table.insert(assigned_to_regions, key)
                num_types_assigned_to_regions = num_types_assigned_to_regions + 1
            end
            print("Lekmap_Luxuries: Region " .. r .. " -> " .. key)
        end
    end

    for r = 1, num_regions do
        if StartQualifiesForCoastalLuxury(r) then
            local ck = RollCoastalLuxuryType()
            if ck then
                region_coastal_luxury[r] = ck
                luxury_assignment_count[ck] = (luxury_assignment_count[ck] or 0) + 1
                print("Lekmap_Luxuries: Region " .. r .. " coastal luxury -> " .. ck)
            end
        end
    end

    local coast_blocked = (Lekmap_Spawns.GetCoastLuxMode() == 5)

    local function KeyReservedForMajorLuxury(key)
        if IsMember(assigned_to_regions, key) then return true end
        for rr = 1, num_regions do
            if region_coastal_luxury[rr] == key then return true end
        end
        return false
    end

    local split_cap = Lekmap_Luxuries.GetSplitCap(num_regions)
    local merged_regional = BuildMergedRegionalMaxWeights()

    local function FilterPool(keys_in, weights_in)
        local fk, fw = {}, {}
        for i = 1, #keys_in do
            local key = keys_in[i]
            if Lekmap_ResourceDefs.IsActive(key)
                and not KeyReservedForMajorLuxury(key)
                and not (coast_blocked and Lekmap_Luxuries.IsCoreCoastLuxuryKey(key))
                and not IsMember(assigned_to_cs, key) then
                table.insert(fk, key)
                table.insert(fw, weights_in[i])
            end
        end
        return fk, fw
    end

    --- City-state luxury *types*: separate pool from majors; each pick rolls a random host
    --- region and uses that region's terrain weights (same table as AssignToRegion).
    local cs_target = Lekmap_Luxuries.GetCSTarget()
    for _ = 1, cs_target do
        local chosen
        if num_regions >= 1 then
            local host = 1 + Map.Rand(num_regions, "Lekmap_Luxuries CS host region")
            local rt = Lekmap_Regions.GetRegionType(host)
            local wm = Lekmap_Luxuries.REGIONAL_LUXURY_WEIGHTS_BY_TERRAIN[rt]
            local ck, cw = CollectRegionalCandidatesFromWeightMap(wm, split_cap)
            ck, cw = FilterPool(ck, cw)
            if #ck > 0 then
                chosen = WeightedRoll(ck, cw)
            end
        end
        if not chosen then
            local ck, cw = {}, {}
            for key, w in Lekmap_Utilities.OrderedPairs(merged_regional) do
                w = tonumber(w) or 0
                if w > 0
                    and LuxuryKeyEligibleForRegionalAssignment(key)
                    and not Lekmap_Luxuries.IsCoreCoastLuxuryKey(key) then
                    local cnt = luxury_assignment_count[key] or 0
                    if cnt < split_cap then
                        table.insert(ck, key)
                        table.insert(cw, w)
                    end
                end
            end
            ck, cw = FilterPool(ck, cw)
            if #ck > 0 then
                chosen = WeightedRoll(ck, cw)
            end
        end
        if not chosen then
            for _, key in ipairs(CollectAllActiveLuxuryKeysSorted()) do
                if not KeyReservedForMajorLuxury(key)
                    and not (coast_blocked and Lekmap_Luxuries.IsCoreCoastLuxuryKey(key))
                    and not IsMember(assigned_to_cs, key) then
                    chosen = key
                    break
                end
            end
        end
        if chosen then
            table.insert(assigned_to_cs, chosen)
            Dbg("Lekmap_Luxuries: CS pool + %s", chosen)
        end
    end

    local random_keys, random_weights = {}, {}
    for key, w in Lekmap_Utilities.OrderedPairs(merged_regional) do
        w = tonumber(w) or 0
        if w > 0
            and LuxuryKeyEligibleForRegionalAssignment(key)
            and Lekmap_ResourceDefs.IsActive(key)
            and not KeyReservedForMajorLuxury(key)
            and not (coast_blocked and Lekmap_Luxuries.IsCoreCoastLuxuryKey(key))
            and not IsMember(assigned_to_cs, key) then
            table.insert(random_keys, key)
            table.insert(random_weights, w)
        end
    end
    if not coast_blocked then
        for key, w in Lekmap_Utilities.OrderedPairs(Lekmap_Luxuries.COASTAL_LUXURY_WEIGHTS) do
            w = tonumber(w) or 0
            if w > 0
                and Lekmap_ResourceDefs.IsActive(key)
                and Lekmap_Luxuries.IsCoreCoastLuxuryKey(key)
                and not KeyReservedForMajorLuxury(key)
                and not IsMember(assigned_to_cs, key)
                and not IsMember(random_keys, key) then
                local count = luxury_assignment_count[key] or 0
                if count < split_cap then
                    table.insert(random_keys, key)
                    table.insert(random_weights, w)
                end
            end
        end
    end

    local random_target = Lekmap_Luxuries.GetRandomTarget()
    for _ = 1, math.min(random_target, #random_keys) do
        local chosen = WeightedRoll(random_keys, random_weights)
        if chosen then
            table.insert(assigned_to_random, chosen)
            print("Lekmap_Luxuries: " .. chosen .. " assigned to Random.")
        end
    end

    local in_use = {}
    for r = 1, num_regions do
        if region_luxury[r] then in_use[region_luxury[r]] = true end
        if region_coastal_luxury[r] then in_use[region_coastal_luxury[r]] = true end
    end
    for _, k in ipairs(assigned_to_cs) do in_use[k] = true end
    for _, k in ipairs(assigned_to_random) do in_use[k] = true end

    for _, key in ipairs(CollectAllActiveLuxuryKeysSorted()) do
        if not in_use[key] then
            table.insert(disabled_luxuries, key)
            Dbg("Lekmap_Luxuries: %s disabled (no role).", key)
        end
    end

    local coastal_assigned = 0
    for ri = 1, num_regions do
        if region_coastal_luxury[ri] then coastal_assigned = coastal_assigned + 1 end
    end

    print("--- Lekmap_Luxuries Role Summary ---")
    print("  Regional types: " .. num_types_assigned_to_regions)
    print("  Coastal start lux regions: " .. coastal_assigned)
    print("  CS types: " .. #assigned_to_cs)
    print("  Random types: " .. #assigned_to_random)
    print("  Disabled types: " .. #disabled_luxuries)
    print("------------------------------------")
end

------------------------------------------------------------------------------
--  PLACEMENT — major starts, region, CS, random
------------------------------------------------------------------------------

local function ReassignRegionalLuxury(region_index, new_key, reason)
    local old = region_luxury[region_index]
    if not new_key or old == new_key then
        return
    end
    if old then
        luxury_assignment_count[old] = math.max(0, (luxury_assignment_count[old] or 1) - 1)
        if luxury_assignment_count[old] <= 0 then
            luxury_assignment_count[old] = nil
        end
    end
    region_luxury[region_index] = new_key
    luxury_assignment_count[new_key] = (luxury_assignment_count[new_key] or 0) + 1
    Dbg("Lekmap_Luxuries: region %d regional lux %s -> %s (%s)",
        region_index, tostring(old), new_key, reason or "?")
end

--- Near-start **land regional** cascade only. Coastal luxuries are never swapped in here —
--- they are placed only via `PlaceNearStartCoastalCascade` (Option 17).
--- Order: primary → same-terrain weights → merged regional weights → every active land luxury.
local function BuildOrderedStartFallbackKeys(region_index)
    local ordered = {}
    local seen = {}

    local function add(k)
        if k and not seen[k] and Lekmap_ResourceDefs.IsActive(k) then
            seen[k] = true
            table.insert(ordered, k)
        end
    end

    add(region_luxury[region_index])

    local rt = Lekmap_Regions.GetRegionType(region_index)
    local wm = Lekmap_Luxuries.REGIONAL_LUXURY_WEIGHTS_BY_TERRAIN[rt]
    if wm then
        local rows = {}
        for k, w in Lekmap_Utilities.OrderedPairs(wm) do
            w = tonumber(w) or 0
            if w > 0
                and not Lekmap_Luxuries.IsCoreCoastLuxuryKey(k)
                and LuxuryKeyEligibleForRegionalAssignment(k) then
                table.insert(rows, { k = k, w = w })
            end
        end
        table.sort(rows, function(a, b)
            if a.w ~= b.w then return a.w > b.w end
            return a.k < b.k
        end)
        for _, r in ipairs(rows) do
            add(r.k)
        end
    end

    local merged = BuildMergedRegionalMaxWeights()
    local mk = {}
    for k, _ in Lekmap_Utilities.OrderedPairs(merged) do
        if not Lekmap_Luxuries.IsCoreCoastLuxuryKey(k) and LuxuryKeyEligibleForRegionalAssignment(k) then
            table.insert(mk, k)
        end
    end
    mk = SortKeysByMergedWeightDesc(mk, merged)
    for _, k in ipairs(mk) do
        add(k)
    end

    for _, k in ipairs(CollectAllActiveLuxuryKeysSorted()) do
        if not Lekmap_Luxuries.IsCoreCoastLuxuryKey(k) then
            add(k)
        end
    end

    return ordered
end

local function BuildOrderedCoastalStartKeys(region_index)
    local ordered = {}
    local seen = {}

    local function add(k)
        if k and not seen[k] and Lekmap_ResourceDefs.IsActive(k) then
            seen[k] = true
            table.insert(ordered, k)
        end
    end

    add(region_coastal_luxury[region_index])
    local crows = {}
    for k, w in Lekmap_Utilities.OrderedPairs(Lekmap_Luxuries.COASTAL_LUXURY_WEIGHTS) do
        w = tonumber(w) or 0
        if w > 0 and Lekmap_ResourceDefs.IsActive(k) and Lekmap_Luxuries.IsCoreCoastLuxuryKey(k) then
            table.insert(crows, { k = k, w = w })
        end
    end
    table.sort(crows, function(a, b)
        if a.w ~= b.w then return a.w > b.w end
        return a.k < b.k
    end)
    for _, r in ipairs(crows) do
        add(r.k)
    end
    return ordered
end

local function ReassignCoastalLuxury(region_index, new_key, reason)
    local old = region_coastal_luxury[region_index]
    if not new_key or old == new_key then
        return
    end
    if old then
        luxury_assignment_count[old] = math.max(0, (luxury_assignment_count[old] or 1) - 1)
        if luxury_assignment_count[old] <= 0 then
            luxury_assignment_count[old] = nil
        end
    end
    region_coastal_luxury[region_index] = new_key
    luxury_assignment_count[new_key] = (luxury_assignment_count[new_key] or 0) + 1
    Dbg("Lekmap_Luxuries: region %d coastal lux %s -> %s (%s)",
        region_index, tostring(old), new_key, reason or "?")
end

--- Weighted rings, trying each key in cascade order until `count` placed or keys exhausted.
local function PlaceNearStartLandCascade(region_index, start_plot, count,
    w_start, cap_start, w_full, cap_full, pass_tag)
    if count < 1 or not start_plot or start_plot.x == nil then
        return count
    end
    local keys = BuildOrderedStartFallbackKeys(region_index)
    local left = count

    for round = 1, 3 do
        local desperate = (round >= 2) and math.max(cap_full + 2, 8) or nil
        local attempts = math.max(count * 70, 120) * round
        for _, K in ipairs(keys) do
            if left <= 0 then
                break
            end
            local before = left
            left = PlaceLuxuriesRingWeighted(start_plot, K, left, w_start, cap_start, attempts, desperate)
            left = PlaceLuxuriesRingWeighted(start_plot, K, left, w_full, cap_full, attempts, desperate)
            if left < before and K ~= region_luxury[region_index] then
                ReassignRegionalLuxury(region_index, K, (pass_tag or "start") .. "_r" .. round)
            end
        end
        if left <= 0 then
            return 0
        end
    end

    if left > 0 then
        print(string.format(
            "Lekmap_Luxuries: WARNING — %d %s near-start land luxury instance(s) still unplaced (region %d).",
            left, pass_tag or "start", region_index))
    end
    return left
end

local function PlaceNearStartCoastalCascade(region_index, start_plot, w_start, cap_start, w_full, cap_full)
    if not StartQualifiesForCoastalLuxury(region_index) then
        return 1
    end
    local keys = BuildOrderedCoastalStartKeys(region_index)
    local left = 1
    for round = 1, 3 do
        local desperate = (round >= 2) and math.max(cap_full + 2, 8) or nil
        local attempts = 80 * round
        for _, K in ipairs(keys) do
            if left <= 0 then
                break
            end
            local before = left
            left = PlaceLuxuriesRingWeighted(start_plot, K, left, w_start, cap_start, attempts, desperate)
            left = PlaceLuxuriesRingWeighted(start_plot, K, left, w_full, cap_full, attempts, desperate)
            if left < before and K ~= region_coastal_luxury[region_index] then
                ReassignCoastalLuxury(region_index, K, "coastal_start_r" .. round)
            end
        end
        if left <= 0 then
            return 0
        end
    end
    if left > 0 then
        print(string.format(
            "Lekmap_Luxuries: WARNING — coastal luxury still unplaced at major start (region %d).",
            region_index))
    end
    return left
end

--- Regional scatter: ratio 1.0 first, then lowest LUXURY impact tiles (still IsValidPlotForResource only).
local function PlaceLuxuryRegionalScatterGuaranteed(region_index, key, target_count)
    local IMPACT_LAYER = Lekmap_Constants.IMPACT_LAYER
    local resource_id = Lekmap_ResourceDefs.GetID(key)
    if not resource_id or target_count <= 0 then
        return target_count
    end

    local plot_list = Lekmap_Resources.GeneratePlotListInRegion(key, region_index)
    plot_list = FilterPlotListForRegionalDistance(plot_list, region_index)
    if not plot_list or #plot_list == 0 then
        print(string.format(
            "Lekmap_Luxuries: WARNING — no valid plots in region %d for regional scatter (%s).",
            region_index, key))
        return target_count
    end

    local left = Lekmap_Resources.PlaceSpecificNumber(resource_id, 1, target_count, 1.0,
        IMPACT_LAYER.LUXURY, 3, 5, plot_list)

    if left <= 0 then
        return 0
    end

    local cache = Lekmap_Resources.GetPlotCache()
    local scored = {}
    for _, pi in ipairs(plot_list) do
        local e = cache[pi]
        if e and not e.has_resource then
            Lekmap_Resources.RefreshPlotCacheAt(e.x, e.y)
            e = cache[pi]
            local active = Lekmap_ResourceDefs.active[key]
            if active
                and Lekmap_Resources.IsValidPlotForResource(e, active.def)
                and not Lekmap_Resources.IsCollision(e.x, e.y) then
                local imp = Lekmap_Impact.GetValue(IMPACT_LAYER.LUXURY, e.x, e.y)
                table.insert(scored, { imp = imp, x = e.x, y = e.y })
            end
        end
    end
    table.sort(scored, function(a, b) return a.imp < b.imp end)
    for _, row in ipairs(scored) do
        if left <= 0 then
            break
        end
        if TryPlaceLuxuryAt(key, row.x, row.y) then
            left = left - 1
        end
    end

    if left > 0 then
        print(string.format(
            "Lekmap_Luxuries: WARNING — regional scatter short by %d for %s (region %d) after impact-soft pass.",
            left, key, region_index))
    end
    return left
end

local function PlaceLuxuryFromPlotListGuaranteed(key, target_count, plot_list, context)
    local IMPACT_LAYER = Lekmap_Constants.IMPACT_LAYER
    local resource_id = Lekmap_ResourceDefs.GetID(key)
    if not resource_id or target_count <= 0 or not plot_list or #plot_list == 0 then
        return target_count
    end

    local left = Lekmap_Resources.PlaceSpecificNumber(resource_id, 1, target_count, 1.0,
        IMPACT_LAYER.LUXURY, 3, 5, plot_list)

    if left <= 0 then
        return 0
    end

    local cache = Lekmap_Resources.GetPlotCache()
    local scored = {}
    for _, pi in ipairs(plot_list) do
        local e = cache[pi]
        if e and not e.has_resource then
            Lekmap_Resources.RefreshPlotCacheAt(e.x, e.y)
            e = cache[pi]
            local active = Lekmap_ResourceDefs.active[key]
            if active
                and Lekmap_Resources.IsValidPlotForResource(e, active.def)
                and not Lekmap_Resources.IsCollision(e.x, e.y) then
                local imp = Lekmap_Impact.GetValue(IMPACT_LAYER.LUXURY, e.x, e.y)
                table.insert(scored, { imp = imp, x = e.x, y = e.y })
            end
        end
    end
    table.sort(scored, function(a, b) return a.imp < b.imp end)
    for _, row in ipairs(scored) do
        if left <= 0 then
            break
        end
        if TryPlaceLuxuryAt(key, row.x, row.y) then
            left = left - 1
        end
    end

    if left > 0 then
        print(string.format(
            "Lekmap_Luxuries: WARNING — %s short by %d (%s) after impact-soft pass.",
            key, left, context or "plot list"))
    end
    return left
end

local function QueueWorldLuxuryShortfall(key, count)
    if not key or count <= 0 then
        return
    end
    for _, e in ipairs(pending_world_luxury_shortfalls) do
        if e.key == key then
            e.count = e.count + count
            return
        end
    end
    table.insert(pending_world_luxury_shortfalls, { key = key, count = count })
end

--- One “extra” start luxury per civ: type from random pool (never the regional land type).
local function PickSecondaryStartLuxuryKey(region_index)
    local reg = region_luxury[region_index]
    local candidates = {}
    for _, k in ipairs(assigned_to_random) do
        if k ~= reg and Lekmap_ResourceDefs.IsActive(k) then
            table.insert(candidates, k)
        end
    end
    if #candidates == 0 then
        for _, k in ipairs(disabled_luxuries) do
            if k ~= reg
                and Lekmap_ResourceDefs.IsActive(k)
                and not Lekmap_Luxuries.IsCoreCoastLuxuryKey(k) then
                table.insert(candidates, k)
            end
        end
    end
    if #candidates == 0 then
        return nil
    end
    return candidates[1 + Map.Rand(#candidates, "Lekmap_Luxuries secondary start lux")]
end

function Lekmap_Luxuries.PlaceAtCivStart(region_index)
    local start_plot = Lekmap_Spawns.GetStartPlot(region_index)
    if not start_plot then
        if region_luxury[region_index] then
            QueueWorldLuxuryShortfall(region_luxury[region_index], resolved_starting_luxuries)
        end
        return
    end

    local cfg = Lekmap_Luxuries.MAJOR_START_LUXURY_SEARCH
    local ring_cap_start = math.max(1, cfg.starting_phase_max_ring or 2)
    local ring_cap_full  = math.max(ring_cap_start, cfg.search_ring_max or 5)
    local w_full = cfg.ring_weights or { [1] = 1 }
    local w_start = cfg.starting_ring_weights or w_full

    if region_luxury[region_index] then
        --- Land regional only (3 by default). Shortfall → world scatter away from starts.
        local spill_reg = PlaceNearStartLandCascade(
            region_index, start_plot, resolved_starting_luxuries,
            w_start, ring_cap_start, w_full, ring_cap_full, "starting")
        if spill_reg > 0 then
            QueueWorldLuxuryShortfall(region_luxury[region_index], spill_reg)
            Dbg("Lekmap_Luxuries: region %d queued %d regional '%s' for world scatter.",
                region_index, spill_reg, region_luxury[region_index])
        end

        --- Secondary = random-pool luxury (not another regional copy).
        if resolved_additional_start_luxuries > 0 then
            local sec_key = PickSecondaryStartLuxuryKey(region_index)
            if sec_key then
                local attempts = math.max(resolved_additional_start_luxuries * 80, 120)
                local spill_sec = PlaceLuxuriesRingWeighted(
                    start_plot, sec_key, resolved_additional_start_luxuries,
                    w_full, ring_cap_full, attempts, math.max(ring_cap_full + 2, 8))
                if spill_sec > 0 then
                    spill_sec = PlaceLuxuriesRingWeighted(
                        start_plot, sec_key, spill_sec,
                        w_full, ring_cap_full, attempts * 2, math.max(ring_cap_full + 4, 10))
                end
                if spill_sec > 0 then
                    QueueWorldLuxuryShortfall(sec_key, spill_sec)
                    Dbg("Lekmap_Luxuries: region %d queued %d secondary '%s' for world scatter.",
                        region_index, spill_sec, sec_key)
                end
            else
                Dbg("Lekmap_Luxuries: region %d — no secondary start luxury candidate in pool.",
                    region_index)
            end
        end
    end

    if region_coastal_luxury[region_index] then
        PlaceNearStartCoastalCascade(region_index, start_plot, w_start, ring_cap_start, w_full, ring_cap_full)
    end
end

function Lekmap_Luxuries.PlaceAtCityState(x, y, city_state_luxury_key)
    local IMPACT_LAYER = Lekmap_Constants.IMPACT_LAYER

    if not city_state_luxury_key then return false end

    local resource_id = Lekmap_ResourceDefs.GetID(city_state_luxury_key)
    if not resource_id then return false end

    local plot_list = Lekmap_Resources.GeneratePlotList(city_state_luxury_key, { x = x, y = y, radius = 3 })
    if not plot_list or #plot_list == 0 then
        return false
    end
    for _, index in ipairs(plot_list) do
        local entry = Lekmap_Resources.GetPlotCache()[index]
        if entry and Lekmap_Resources.PlaceOne(entry.x, entry.y, city_state_luxury_key, 1) then
            return true
        end
    end
    return false
end

--- One luxury per valid city-state from `GetAssignedToCS()` (round-robin pool).
function Lekmap_Luxuries.PlaceAllCityStateLuxuries()
    local pool = assigned_to_cs
    if not pool or #pool == 0 then
        print("Lekmap_Luxuries: City-state luxury pool empty — skipping CS lux placement.")
        return
    end
    if not Lekmap_CityStates or not Lekmap_CityStates.GetAllPlots then
        print("Lekmap_Luxuries: WARNING — Lekmap_CityStates not available for CS lux placement.")
        return
    end
    local all = Lekmap_CityStates.GetAllPlots()
    local placed = 0
    local tried = 0
    for cs_number, pdata in Lekmap_Utilities.OrderedPairs(all) do
        local ok_cs = true
        if Lekmap_CityStates.IsValid then
            ok_cs = Lekmap_CityStates.IsValid(cs_number)
        end
        if pdata and pdata.x ~= nil and pdata.y ~= nil and ok_cs then
            tried = tried + 1
            local key = pool[((cs_number - 1) % #pool) + 1]
            if Lekmap_Luxuries.PlaceAtCityState(pdata.x, pdata.y, key) then
                placed = placed + 1
            end
        end
    end
    print(string.format("Lekmap_Luxuries: City-state luxuries placed %d / %d (pool size %d).",
        placed, tried, #pool))
end

function Lekmap_Luxuries.PlaceInRegion(region_index, target_count)
    local key = region_luxury[region_index]
    if not key or target_count <= 0 then
        return 0
    end
    local left = PlaceLuxuryRegionalScatterGuaranteed(region_index, key, target_count)
    return target_count - left
end

--- Extra WHALE/CRAB/PEARLS in the map region (Option 24); not used when Blocked or Not Allowed.
function Lekmap_Luxuries.PlaceCoastalLuxuryExtrasInRegion(region_index, target_count)
    if target_count <= 0 then return 0 end
    if Lekmap_Spawns.GetCoastLuxMode() == 5 then return 0 end
    if resolved_additional_coastal_mode == 2 then return 0 end

    local ckey = region_coastal_luxury[region_index]
    if not ckey then return 0 end

    local plot_list = Lekmap_Resources.GeneratePlotListInRegion(ckey, region_index)
    plot_list = FilterPlotListForRegionalDistance(plot_list, region_index)
    plot_list = FilterPlotListForAdditionalCoastalMode(plot_list, resolved_additional_coastal_mode)
    if not plot_list or #plot_list == 0 then return 0 end

    local left = PlaceLuxuryFromPlotListGuaranteed(ckey, target_count, plot_list,
        string.format("coastal_extra region %d", region_index))
    return target_count - left
end

local function PlacePendingWorldLuxuryShortfalls()
    if #pending_world_luxury_shortfalls == 0 then
        return
    end
    print("Lekmap_Luxuries: Placing deferred near-start luxuries (world pass, CITY_STATE ripple filter).")
    for _, item in ipairs(pending_world_luxury_shortfalls) do
        if item.count > 0 and item.key then
            local plot_list = Lekmap_Resources.GeneratePlotList(item.key, "world")
            plot_list = FilterPlotListExcludingCityStateRipple(plot_list)
            if plot_list and #plot_list > 0 then
                PlaceLuxuryFromPlotListGuaranteed(item.key, item.count, plot_list,
                    "deferred_start_shortfall " .. item.key)
            else
                print(string.format(
                    "Lekmap_Luxuries: WARNING — no world plots for deferred %s x%d after CITY_STATE filter.",
                    item.key, item.count))
            end
        end
    end
    pending_world_luxury_shortfalls = {}
end

function Lekmap_Luxuries.PlaceRandom(world_target, min_random)
    local IMPACT_LAYER = Lekmap_Constants.IMPACT_LAYER

    local current_total = Lekmap_Resources.GetTotalLuxPlaced()
    local remaining = world_target - current_total
    if remaining <= 0 then return end

    local num_random_types = #assigned_to_random
    if num_random_types == 0 then return end

    local per_type = math.max(min_random, math.ceil(remaining / num_random_types))

    for _, key in ipairs(assigned_to_random) do
        local rid = Lekmap_ResourceDefs.GetID(key)
        if rid then
            local plot_list = Lekmap_Resources.GeneratePlotList(key, "world")
            plot_list = FilterPlotListExcludingCityStateRipple(plot_list)
            if plot_list and #plot_list > 0 then
                Lekmap_Resources.PlaceSpecificNumber(rid, 1, per_type, 0.25,
                    IMPACT_LAYER.LUXURY, 3, 5, plot_list)
            end
        end
    end
end

------------------------------------------------------------------------------
--  ORCHESTRATOR
------------------------------------------------------------------------------

function Lekmap_Luxuries.AssignAll(args)
    ResolveAssignOptions(args)
    print(string.format(
        "Lekmap_Luxuries: Assigning luxury roles (extended regional pool = %s).",
        tostring(resolved_allow_extended_regional_pool)))
    Lekmap_Luxuries.AssignRoles()
    print("Lekmap_Luxuries: Role assignment complete.")
end

function Lekmap_Luxuries.PlaceAll(args)
    args = args or {}
    ResolvePlaceAllOptions(args)

    pending_world_luxury_shortfalls = {}

    print("Lekmap_Luxuries: Beginning luxury placement.")
    print(string.format(
        "Lekmap_Luxuries: Major start — regional_near_cap=%d, secondary_random_near=%d, strategics_flag=%s, additionalCoastalMode=%d",
        resolved_starting_luxuries,
        resolved_additional_start_luxuries,
        tostring(resolved_guaranteed_strategics),
        resolved_additional_coastal_mode))

    local num_regions      = Lekmap_Regions.GetRegionCount()
    local resource_setting = Lekmap_Resources.GetResourceSetting()

    print("Lekmap_Luxuries: Placing at major civ starts (land regional + secondary + coastal).")
    local regional_near_cap = resolved_starting_luxuries
    for r = 1, num_regions do
        Lekmap_Luxuries.PlaceAtCivStart(r)
    end
    print("Lekmap_Luxuries: Major start pass complete.")

    print("Lekmap_Luxuries: Placing city-state luxuries.")
    Lekmap_Luxuries.PlaceAllCityStateLuxuries()

    print("Lekmap_Luxuries: Placing regional luxuries (distance rules + per-major tile target).")
    local total_target = Lekmap_Luxuries.GetPerRegionLuxuryTileTarget()
    --- Secondary near-start lux is not part of the regional type tile budget.
    local region_extra = math.max(0, total_target - regional_near_cap)
    print("Lekmap_Luxuries: Total target per region = " .. total_target
        .. " (regional_near_start=" .. regional_near_cap .. ", region_fill=" .. region_extra .. ")")
    for r = 1, num_regions do
        Lekmap_Luxuries.PlaceInRegion(r, region_extra)
    end

    local coast_extra = 0
    if resolved_additional_coastal_mode ~= 2
        and Lekmap_Spawns.GetCoastLuxMode() ~= 5
        and region_extra >= 1 then
        coast_extra = 1
    end
    if coast_extra > 0 then
        print("Lekmap_Luxuries: Placing additional coastal luxuries in regions (Option 24).")
        for r = 1, num_regions do
            Lekmap_Luxuries.PlaceCoastalLuxuryExtrasInRegion(r, coast_extra)
        end
    end

    PlacePendingWorldLuxuryShortfalls()

    print("Lekmap_Luxuries: Placing random pool luxuries (world, CITY_STATE ripple filter).")
    local world_data = Lekmap_Luxuries.GetWorldTargets(resource_setting)
    Lekmap_Luxuries.PlaceRandom(world_data[1], world_data[2])

    print("Lekmap_Luxuries: Luxury placement complete. Total placed: " .. Lekmap_Resources.GetTotalLuxPlaced())
end

------------------------------------------------------------------------------
--  ACCESSORS
------------------------------------------------------------------------------

function Lekmap_Luxuries.GetRegionLuxury(region_index)
    return region_luxury[region_index]
end

function Lekmap_Luxuries.GetRegionCoastalLuxury(region_index)
    return region_coastal_luxury[region_index]
end

function Lekmap_Luxuries.GetAssignedToRegions()
    return assigned_to_regions
end

function Lekmap_Luxuries.GetAssignedToCS()
    return assigned_to_cs
end

function Lekmap_Luxuries.GetAssignedToRandom()
    return assigned_to_random
end
