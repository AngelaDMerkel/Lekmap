------------------------------------------------------------------------------
--  FILE:     Lekmap_Bonus.lua
--  PURPOSE:  (1) Start-area bonus resources for major civs and city-states:
--            subclass pools, ring-weighted search, ResourceDefs + relaxed fallback.
--            (2) World scatter on land and sea scatter (e.g. fish) using per-region
--            quotas, terrain weights, fertility scaling, and spawn-buffer rings.
--
--  Typical pipeline (Lekmap_Resources.PlaceAll phase 3):
--    • Major + city-state start bonuses
--    • PlaceWorldScatter(resource_setting)
--    • PlaceSeaResourceScatter(resource_setting)
--
--  File layout: CONFIGURATION blocks first (all tunable tables), then implementation
--  grouped by feature (start helpers → start API → scatter helpers → scatter API).
------------------------------------------------------------------------------
--  Depends on: Lekmap_Spawns, Lekmap_Regions, Lekmap_Resources, Lekmap_ResourceDefs,
--              Lekmap_CityStates, Lekmap_Utilities, Lekmap_Constants, Lekmap_HexUtil, Map
------------------------------------------------------------------------------
--luacheck: globals Lekmap_Bonus Lekmap_Spawns Lekmap_Resources Lekmap_ResourceDefs Lekmap_Impact
--luacheck: globals Lekmap_Regions Lekmap_CityStates Lekmap_Utilities Lekmap_Constants Lekmap_HexUtil Map Players GameInfo
--luacheck: globals FeatureTypes TerrainTypes

Lekmap_Bonus = {}

------------------------------------------------------------------------------
--  CONFIGURATION — debug & subclass definitions (resource pools + processing order)
------------------------------------------------------------------------------

--- When true, logs one line per major civ and per city-state when placing start bonuses
--- (map region index, terrain class name, tile, how many bonuses placed).
Lekmap_Bonus.DEBUG_PRINT_STARTS = true

local SUB = {
    GRANARY = "GRANARY",
    STABLE  = "STABLE",
    COASTAL = "COASTAL",
    QUARRY  = "QUARRY",
    OTHER   = "OTHER",
}

Lekmap_Bonus.SUBCLASS_ORDER = {
    SUB.GRANARY, SUB.STABLE, SUB.COASTAL, SUB.QUARRY, SUB.OTHER,
}

Lekmap_Bonus.SUBCLASS_POOLS = {
    [SUB.GRANARY] = { "WHEAT", "BANANA", "DEER", "BISON" },
    [SUB.STABLE]  = { "SHEEP", "COW", "MAIZE" },
    [SUB.COASTAL] = { "FISH" },
    [SUB.QUARRY]  = { "STONE" },
    [SUB.OTHER]   = { "HARDWOOD" },
}

------------------------------------------------------------------------------
--  CONFIGURATION — global start defaults (rings, weights, slot counts by resource setting)
------------------------------------------------------------------------------
-- Global defaults: subclass search rings + slot counts by map resource option (1–10).
-- Per terrain region (START_BY_REGION): major = civ starts, minor = city-state starts.
-- Each branch merges: global row -> default_slots -> slots_by_setting[setting].
-- Ring weights: per-subclass table [ring] = weight; max ring = *search_ring_by_subclass.
------------------------------------------------------------------------------
Lekmap_Bonus.START_CONFIG = {
    -- Max hex ring (distance from start) scanned for that subclass.
    major_search_ring_by_subclass = {
        GRANARY = 3, STABLE = 3, COASTAL = 3, QUARRY = 3, OTHER = 3,
    },

    -- Weight per ring 1..max (roll which ring to search first for this placement try).
    major_ring_weights_by_subclass = {
        GRANARY = { [1] = 45, [2] = 35, [3] = 20 },
        STABLE  = { [1] = 30, [2] = 35, [3] = 35 },
        COASTAL = { [1] = 25, [2] = 30, [3] = 45 },
        QUARRY  = { [1] = 25, [2] = 35, [3] = 40 },
        OTHER   = { [1] = 25, [2] = 35, [3] = 40 },
    },

    major_counts_by_resource_setting = {
        [1]  = { GRANARY = 1, STABLE = 0, COASTAL = 0, QUARRY = 0, OTHER = 0 },
        [2]  = { GRANARY = 1, STABLE = 1, COASTAL = 0, QUARRY = 0, OTHER = 0 },
        [3]  = { GRANARY = 1, STABLE = 2, COASTAL = 1, QUARRY = 0, OTHER = 1 },
        [4]  = { GRANARY = 1, STABLE = 2, COASTAL = 1, QUARRY = 1, OTHER = 1 },
        [5]  = { GRANARY = 3, STABLE = 3, COASTAL = 2, QUARRY = 2, OTHER = 2 },
        [6]  = { GRANARY = 3, STABLE = 3, COASTAL = 2, QUARRY = 2, OTHER = 2 },
        [7]  = { GRANARY = 4, STABLE = 4, COASTAL = 3, QUARRY = 3, OTHER = 3 },
        [8]  = { GRANARY = 4, STABLE = 4, COASTAL = 3, QUARRY = 3, OTHER = 3 },
        [9]  = { GRANARY = 5, STABLE = 5, COASTAL = 4, QUARRY = 4, OTHER = 4 },
        [10] = { GRANARY = 5, STABLE = 5, COASTAL = 4, QUARRY = 4, OTHER = 4 },
    },

    city_state_search_ring_by_subclass = {
        GRANARY = 2, STABLE = 2, COASTAL = 2, QUARRY = 2, OTHER = 2,
    },

    minor_ring_weights_by_subclass = {
        GRANARY = { [1] = 40, [2] = 60 },
        STABLE  = { [1] = 35, [2] = 65 },
        COASTAL = { [1] = 35, [2] = 65 },
        QUARRY  = { [1] = 35, [2] = 65 },
        OTHER   = { [1] = 35, [2] = 65 },
    },

    city_state_counts_by_resource_setting = {
        [1]  = { GRANARY = 1, STABLE = 0, COASTAL = 0, QUARRY = 0, OTHER = 0 },
        [2]  = { GRANARY = 1, STABLE = 0, COASTAL = 0, QUARRY = 0, OTHER = 0 },
        [3]  = { GRANARY = 1, STABLE = 1, COASTAL = 1, QUARRY = 0, OTHER = 0 },
        [4]  = { GRANARY = 1, STABLE = 1, COASTAL = 2, QUARRY = 0, OTHER = 0 },
        [5]  = { GRANARY = 2, STABLE = 2, COASTAL = 2, QUARRY = 1, OTHER = 1 },
        [6]  = { GRANARY = 2, STABLE = 2, COASTAL = 2, QUARRY = 1, OTHER = 1 },
        [7]  = { GRANARY = 2, STABLE = 2, COASTAL = 3, QUARRY = 2, OTHER = 2 },
        [8]  = { GRANARY = 3, STABLE = 2, COASTAL = 3, QUARRY = 2, OTHER = 2 },
        [9]  = { GRANARY = 3, STABLE = 2, COASTAL = 4, QUARRY = 3, OTHER = 3 },
        [10] = { GRANARY = 3, STABLE = 2, COASTAL = 4, QUARRY = 3, OTHER = 3 },
    },
}

------------------------------------------------------------------------------
--  CONFIGURATION — per-terrain start packs & land resource_weights (1 TUNDRA … 9 WETLANDS)
------------------------------------------------------------------------------
--[[
  START_BY_REGION[terrain_type]
    terrain_type: 1 TUNDRA … 9 WETLANDS (Lekmap_Regions.GetRegionType).

    resource_weights — land bonus resources only (omit FISH; sea scatter handles fish).
      Relative frequency for (1) start-area subclass picks and (2) world scatter in that terrain.
      Omit key or 0 = not used for multi-resource subclasses; COASTAL/FISH still defaults to 1
      when it is the only pool member. World scatter: weight / scatter_weight_reference scales quota.

    major / minor — start placement only: default_slots, slots_by_setting (no weights here).
      minor.weights optional override for city-states; else resource_weights is used.

    COASTAL subclass slots zeroed when start is not coastal.

  Merge order: global counts -> branch.default_slots -> branch.slots_by_setting[setting]
]]
Lekmap_Bonus.START_BY_REGION = {

    -- TUNDRA
    [1] = {
        resource_weights = {
            WHEAT = 8, COW = 10, BANANA = 0, DEER = 45, MAIZE = 0, BISON = 10, SHEEP = 20, STONE = 20, HARDWOOD = 35,
        },
        major = {},
        -- minor = { weights = {...}, default_slots = {...}, slots_by_setting = {...} },
    },

    -- JUNGLE
    [2] = {
        resource_weights = {
            WHEAT = 0, COW = 15, BANANA = 55, DEER = 15, MAIZE = 0, BISON = 0, SHEEP = 15,
            STONE = 15, HARDWOOD = 35,
        },
        major = {
            slots_by_setting = {
                [1]  = { GRANARY = 1, STABLE = 0 },
                [2]  = { GRANARY = 1, STABLE = 0 },
                [3]  = { GRANARY = 1, STABLE = 0 },
                [4]  = { GRANARY = 1, STABLE = 0 },
                [5]  = { GRANARY = 4, STABLE = 1 },
                [6]  = { GRANARY = 4, STABLE = 1 },
                [7]  = { GRANARY = 5, STABLE = 2 },
                [8]  = { GRANARY = 5, STABLE = 2 },
                [9]  = { GRANARY = 6, STABLE = 3 },
                [10] = { GRANARY = 6, STABLE = 3 },
            },
        },
    },

    -- FOREST
    [3] = {
        resource_weights = {
            WHEAT = 10, COW = 30, BANANA = 0, DEER = 35, MAIZE = 10, BISON = 5,
            STONE = 1, HARDWOOD = 35, SHEEP = 12,
        },
        major = {
            slots_by_setting = {
                [1]  = { OTHER = 0 },
                [2]  = { OTHER = 0 },
                [3]  = { OTHER = 0 },
                [4]  = { OTHER = 0 },
                [5]  = { OTHER = 2 },
                [6]  = { OTHER = 2 },
                [7]  = { OTHER = 3 },
                [8]  = { OTHER = 3 },
                [9]  = { OTHER = 3 },
                [10] = { OTHER = 3 },
            },
        },
    },

    -- DESERT
    [4] = {
        resource_weights = {
            WHEAT = 35, COW = 8, BANANA = 0, DEER = 5, MAIZE = 30, BISON = 10,
            STONE = 20, HARDWOOD = 0, SHEEP = 35,
        },
        major = {
            default_slots = { OTHER = 0 },
        },
    },

    -- HILLS
    [5] = {
        resource_weights = {
            WHEAT = 15, COW = 10, BANANA = 0, DEER = 20, MAIZE = 12, BISON = 8,
            HARDWOOD = 0, SHEEP = 35, STONE = 14,
        },
        major = {
            default_slots = { OTHER = 0 },
            slots_by_setting = {
                [7] = { GRANARY = 2, STABLE = 2 },
                [8] = { GRANARY = 2, STABLE = 2 },
                [9] = { GRANARY = 2, STABLE = 3 },
                [10] = { GRANARY = 2, STABLE = 4, QUARRY = 1 },
            },
        },
    },

    -- PLAINS
    [6] = {
        resource_weights = {
            WHEAT = 30, COW = 22, BANANA = 0, DEER = 10, MAIZE = 25, BISON = 18,
            STONE = 18, HARDWOOD = 10, SHEEP = 14,
        },
        major = {},
    },

    -- GRASS
    [7] = {
        resource_weights = {
            WHEAT = 22, COW = 35, BANANA = 0, DEER = 12, MAIZE = 15, BISON = 22,
            STONE = 16, SHEEP = 20, HARDWOOD = 12,
        },
        major = {
            slots_by_setting = {
                [9]  = { GRANARY = 4, STABLE = 1 },
                [10] = { GRANARY = 4, STABLE = 2 },
            },
        },
    },

    -- HYBRID
    [8] = {
        resource_weights = {
            WHEAT = 20, COW = 22, BANANA = 8, DEER = 18, MAIZE = 18, BISON = 12,
            STONE = 15, HARDWOOD = 22, SHEEP = 14,
        },
        major = {},
    },

    -- WETLANDS
    [9] = {
        resource_weights = {
            WHEAT = 10, COW = 18, BANANA = 35, DEER = 20, MAIZE = 10, BISON = 0,
            STONE = 0, SHEEP = 12, HARDWOOD = 22,
        },
        major = {
            default_slots = { QUARRY = 0 },
        },
    },
}

------------------------------------------------------------------------------
--  CONFIGURATION — world / sea scatter (density scale, rules, spawn clear zones)
------------------------------------------------------------------------------
--  Land: valid plots from ResourceDefs via GeneratePlotListInRegion. Per map region we
--  compute a target count from base_frequency, SCATTER_DENSITY_MULTIPLIER,
--  START_BY_REGION.resource_weights (per resource × terrain), and avg fertility (quality).
--  Placement: (1) respect BONUS impact like normal scatter, (2) if short, ignore BONUS
--  crowding, (3) if still short, TryPlaceStartBonusAtPlot (same relax idea as starts).
--
--  Spawn buffers (WORLD_SCATTER_CONFIG): hex rings around major civ starts and around
--  city-state spawns (separate counts). Optional PLAYER_SPAWN impact layer filter.
--
--  Sea: separate rules / geometry; same spawn ring exclusion. No terrain-region weights.

--- Maps resource option 1–10 to frequency scale (same idea as legacy BONUS_MULTIPLIER).
Lekmap_Bonus.SCATTER_DENSITY_MULTIPLIER = {
    [1]  = 1.00, [2]  = 0.90, [3]  = 0.80, [4]  = 0.75, [5]  = 0.65,
    [6]  = 0.55, [7]  = 0.45, [8]  = 0.35, [9]  = 0.25, [10] = 0.15,
}

--[[
  WORLD_SCATTER_RULES — one row per resource, processed per map region.

  resource_key    Lekmap_ResourceDefs key (must be active). FISH ignored (use sea scatter).
  base_frequency  Larger => fewer placements. Target uses terrain weight from
                  START_BY_REGION[regionType].resource_weights[key] / scatter_weight_reference.
  spacing         optional { min, max } BONUS impact radii; else defs bonus default_spacing.
]]
Lekmap_Bonus.WORLD_SCATTER_RULES = {
    { resource_key = "DEER",     base_frequency = 16 },
    { resource_key = "WHEAT",    base_frequency = 22 },
    { resource_key = "BANANA",   base_frequency = 12 },
    { resource_key = "BISON",    base_frequency = 20 },
    { resource_key = "COW",      base_frequency = 18 },
    { resource_key = "STONE",    base_frequency = 18 },
    { resource_key = "SHEEP",    base_frequency = 22 },
    { resource_key = "HARDWOOD", base_frequency = 18 },
    { resource_key = "MAIZE",    base_frequency = 26 },
}

Lekmap_Bonus.WORLD_SCATTER_CONFIG = {
    --- Hex rings around each *major* civ start to forbid land/sea scatter near capitals.
    major_spawn_clear_rings = 3,
    --- Hex rings around each *city-state* spawn (Lekmap_CityStates.GetAllPlots).
    city_state_spawn_clear_rings = 3,
    --- If true, also exclude tiles where PLAYER_SPAWN impact layer already has ripple (>0).
    exclude_player_spawn_impact = false,

    --- Divide START_BY_REGION.resource_weights by this for scatter (same numbers as start picks).
    scatter_weight_reference = 22,

    --- Scale quotas from Lekmap_Regions region avgFertility (higher = better land).
    region_quality = {
        enabled = true,
        bad_region_bonus    = 0.28,  -- extra quota for worst-fertility regions
        good_region_penalty = 0.12,  -- less quota for best-fertility regions
        min_mult = 0.82,
        max_mult = 1.38,
    },
}

--[[
  SEA_SCATTER_RULES — uses WORLD_SCATTER_CONFIG for spawn buffers (majors + city-states).

  mainland_ring_weights   optional [1],[2],[3] = relative fish density vs mainland distance.
                          Ring 1 = water adjacent to biggest landmass; 2 = next band; 3 = outer.
                          Higher weight => more fish in that band (effective frequency is divided by it).
                          If omitted, all enabled rings (1..max_ring_from_mainland) are merged into one pass.

  base_frequency_inland_sea  When Lekmap_Spawns.GetAllowInlandSea() is true, extra pass on *fresh-water*
                          coast ocean tiles (inland seas). If nil, defaults to base_frequency_open_coast.
                          When the option is on, open-coast pass uses salt-water coast only so inland seas
                          are covered here (not double-counted).
]]
Lekmap_Bonus.SEA_SCATTER_RULES = {
    {
        resource_key = "FISH",
        max_ring_from_mainland = 3,
        mainland_ring_weights = { [1] = 2.0, [2] = 1.0, [3] = 0.55 },
        base_frequency_near_mainland = 8,
        base_frequency_open_coast = 16,
        base_frequency_inland_sea = 16,
    },
}

------------------------------------------------------------------------------
--  INTERNAL — branch labels for major vs city-state start tables
------------------------------------------------------------------------------

local BRANCH_MAJOR = "major"
local BRANCH_MINOR = "minor"

------------------------------------------------------------------------------
--  START BONUSES — terrain, coastal checks, merged slot rows
------------------------------------------------------------------------------

--- Salt-water coastal land (along_ocean from spawn conditions).
local function IsMajorStartOceanCoastal(region_index)
    local c = Lekmap_Spawns.GetStartConditions(region_index)
    return c and c.along_ocean == true
end

--- Fresh-water coastal land (inland sea / lake coast); matches Lekmap_Spawns inland-sea start filter.
local function IsMajorStartInlandSeaCoastalLand(region_index)
    local sp = Lekmap_Spawns.GetStartPlot(region_index)
    if not sp or sp.x == nil or sp.y == nil then
        return false
    end
    local plot = Map.GetPlot(sp.x, sp.y)
    return plot and plot:IsFreshWater() and plot:IsCoastalLand()
end

--- COASTAL subclass (fish) applies on ocean coast, or on inland sea coast when map AllowInlandSea is on.
local function IsMajorStartCoastalForBonuses(region_index)
    if IsMajorStartOceanCoastal(region_index) then
        return true
    end
    if not Lekmap_Spawns.GetAllowInlandSea() then
        return false
    end
    return IsMajorStartInlandSeaCoastalLand(region_index)
end

--- City-state tile: ocean-adjacent or (with AllowInlandSea) inland sea coastal land.
local function IsCityStateCoastalForBonuses(x, y)
    if Lekmap_Utilities.AdjacentToSaltWater(x, y) then
        return true
    end
    if not Lekmap_Spawns.GetAllowInlandSea() then
        return false
    end
    local plot = Map.GetPlot(x, y)
    return plot and plot:IsFreshWater() and plot:IsCoastalLand()
end

--- Map region → terrain class id (1–9); invalid values clamp to grass (7).
local function RegionTypeForIndex(region_index)
    local terrain_type_id = Lekmap_Regions.GetRegionType(region_index) or 7
    if terrain_type_id < 1 or terrain_type_id > 9 then
        return 7
    end
    return terrain_type_id
end

local function CopySlotRow(source)
    return {
        GRANARY = source.GRANARY or 0,
        STABLE  = source.STABLE or 0,
        COASTAL = source.COASTAL or 0,
        QUARRY  = source.QUARRY or 0,
        OTHER   = source.OTHER or 0,
    }
end

local function MergeSlotRow(base, overlay)
    if not overlay then
        return base
    end
    local out = CopySlotRow(base)
    for k, v in Lekmap_Utilities.OrderedPairs(overlay) do
        out[k] = v
    end
    return out
end

------------------------------------------------------------------------------
--  START BONUSES — resolve per-terrain packs, slot merge chain, resource weights
------------------------------------------------------------------------------

local function StartPackForTerrain(terrain_type_id)
    return Lekmap_Bonus.START_BY_REGION[terrain_type_id]
end

local function StartBranchTable(pack, branch)
    if not pack then
        return nil
    end
    if branch == BRANCH_MAJOR then
        return pack.major
    end
    if branch == BRANCH_MINOR then
        return pack.minor
    end
    return nil
end

--- Merge chain: global START_CONFIG row → branch.default_slots → branch.slots_by_setting[setting].
--- @param branch  BRANCH_MAJOR | BRANCH_MINOR
--- @param along_coastal  if false, COASTAL subclass count is forced to 0 after merge
local function ResolvedStartSlots(terrain_type_id, setting, branch, along_coastal)
    local cfg = Lekmap_Bonus.START_CONFIG
    local global
    if branch == BRANCH_MAJOR then
        global = cfg.major_counts_by_resource_setting[setting]
            or cfg.major_counts_by_resource_setting[5]
    else
        global = cfg.city_state_counts_by_resource_setting[setting]
            or cfg.city_state_counts_by_resource_setting[5]
    end
    global = global or { GRANARY = 1, STABLE = 0, COASTAL = 0, QUARRY = 0, OTHER = 0 }

    local pack = StartPackForTerrain(terrain_type_id)
    local branch_tbl = StartBranchTable(pack, branch)
    local row = CopySlotRow(global)
    if branch_tbl then
        row = MergeSlotRow(row, branch_tbl.default_slots)
        row = MergeSlotRow(row, branch_tbl.slots_by_setting and branch_tbl.slots_by_setting[setting])
    end
    if along_coastal == false then
        row.COASTAL = 0
    end
    return row
end

local function ResolvedMajorSlots(region_index, setting)
    local terrain_type_id = RegionTypeForIndex(region_index)
    local along = IsMajorStartCoastalForBonuses(region_index)
    return ResolvedStartSlots(terrain_type_id, setting, BRANCH_MAJOR, along)
end

--- @param region_number  civ region index for terrain type, or nil / <1 for uninhabited CS (uses grass 7)
local function TerrainTypeForCityStateRegion(region_number)
    if region_number and region_number >= 1 then
        return Lekmap_Regions.GetRegionType(region_number) or 7
    end
    return 7
end

--- Land bonus weights for starts + world scatter (see START_BY_REGION.resource_weights).
--- minor.minor.weights overrides; else same table as majors. Legacy major.weights still read if present.
local function StartResourceWeights(terrain_type_id, branch)
    local pack = StartPackForTerrain(terrain_type_id)
    if not pack then
        return {}
    end
    if branch == BRANCH_MINOR then
        local m = pack.minor
        if m and m.weights then
            return m.weights
        end
    end
    if pack.resource_weights then
        return pack.resource_weights
    end
    local maj = pack.major
    if maj and maj.weights then
        return maj.weights
    end
    return {}
end

--- Read-only: land resource weight table for a terrain class id (1–9), or empty {}.
function Lekmap_Bonus.GetRegionResourceWeights(region_type)
    local pack = StartPackForTerrain(region_type)
    if not pack then
        return {}
    end
    if pack.resource_weights then
        return pack.resource_weights
    end
    if pack.major and pack.major.weights then
        return pack.major.weights
    end
    return {}
end

------------------------------------------------------------------------------
--  START BONUSES — ring depth, weighted ring pick, resource pick, placement tries
------------------------------------------------------------------------------

local function RingForSubclass(subclass, is_city_state)
    local cfg = Lekmap_Bonus.START_CONFIG
    local tbl = is_city_state and cfg.city_state_search_ring_by_subclass
        or cfg.major_search_ring_by_subclass
    if tbl and tbl[subclass] then
        return tbl[subclass]
    end
    return 2
end

--- Weighted random ring in 1..max_ring (uniform if no weights or zero total).
--- Ring 1 is adjacent hexes; higher rings are farther from the start plot.
local function PickSearchRing(subclass, is_city_state)
    local max_ring = RingForSubclass(subclass, is_city_state)
    if max_ring < 1 then
        return 1
    end
    local cfg = Lekmap_Bonus.START_CONFIG
    local ring_weight_table = is_city_state and cfg.minor_ring_weights_by_subclass
        or cfg.major_ring_weights_by_subclass
    ring_weight_table = ring_weight_table and ring_weight_table[subclass]
    local total_weight = 0
    if ring_weight_table then
        for ring_index = 1, max_ring do
            total_weight = total_weight + (ring_weight_table[ring_index] or 0)
        end
    end
    if total_weight <= 0 then
        return 1 + Map.Rand(max_ring, "Lekmap_Bonus ring uniform")
    end
    local roll = Map.Rand(total_weight, "Lekmap_Bonus ring weight")
    local accumulated = 0
    for ring_index = 1, max_ring do
        accumulated = accumulated + (ring_weight_table[ring_index] or 0)
        if roll < accumulated then
            return ring_index
        end
    end
    return max_ring
end

local function BuildWeightedCandidates(pool, weight_table)
    local total = 0
    local rows = {}
    if not pool then
        return rows, 0
    end
    weight_table = weight_table or {}
    local singleton_pool = #pool == 1
    for _, key in ipairs(pool) do
        local w = weight_table[key]
        if w == nil then
            w = singleton_pool and 1 or 0
        end
        if w > 0 and Lekmap_ResourceDefs.GetID(key) then
            total = total + w
            table.insert(rows, { resource_key = key, weight = w })
        end
    end
    return rows, total
end

local function WeightedPick(rows, total)
    if total <= 0 or #rows == 0 then
        return nil
    end
    local roll = Map.Rand(total, "Lekmap_Bonus res weight")
    local acc = 0
    for _, row in ipairs(rows) do
        acc = acc + row.weight
        if roll < acc then
            return row.resource_key
        end
    end
    return rows[#rows].resource_key
end

--- Convert 1-based linear plot index (row-major) to (x, y) for Map.GetPlot.
local function PlotXYFromRingIndex(plot_index)
    if not plot_index then return nil, nil end
    local w, h = Map.GetGridSize()
    if w < 1 then return nil, nil end
    local i0 = plot_index - 1
    local y = math.floor(i0 / w)
    local x = i0 - y * w
    return x, y
end

--- Shuffle ring tile order, then try TryPlaceStartBonusAtPlot on each until one succeeds.
local function TryPlaceResourceInRingResolved(start_plot, resource_key, ring, context_region_index)
    local indices = Lekmap_Resources.GetShuffledRingPlotIndices(start_plot.x, start_plot.y, ring)
    for _, plot_index in ipairs(indices) do
        local x, y = PlotXYFromRingIndex(plot_index)
        if x and y and Lekmap_Resources.TryPlaceStartBonusAtPlot(resource_key, x, y, context_region_index) then
            return true
        end
    end
    return false
end

--- One placement try for this subclass: weighted resource pick, weighted ring, intraclass fallbacks.
local function TryPlaceOneFromSubclass(start_plot, subclass, weight_table, is_city_state, context_region_index)
    local pool = Lekmap_Bonus.SUBCLASS_POOLS[subclass]
    if not pool then
        return false
    end

    local rows, total = BuildWeightedCandidates(pool, weight_table)
    if total <= 0 then
        return false
    end

    local order = {}
    local first = WeightedPick(rows, total)
    if first then
        table.insert(order, first)
    end
    table.sort(rows, function(a, b) return a.weight > b.weight end)
    for _, row in ipairs(rows) do
        if row.resource_key ~= first then
            table.insert(order, row.resource_key)
        end
    end

    for _, resource_key in ipairs(order) do
        local ring = PickSearchRing(subclass, is_city_state)
        if TryPlaceResourceInRingResolved(start_plot, resource_key, ring, context_region_index) then
            return true
        end
    end

    -- Second pass: same resources, other rings (if max_ring > 1)
    local max_ring = RingForSubclass(subclass, is_city_state)
    if max_ring > 1 then
        for _, resource_key in ipairs(order) do
            for ring_index = 1, max_ring do
                if TryPlaceResourceInRingResolved(start_plot, resource_key, ring_index, context_region_index) then
                    return true
                end
            end
        end
    end

    return false
end

--- Round-robin across subclasses until no slot can place anything.
--- @param along_coastal  if false, COASTAL subclass is skipped (fish etc.)
--- @param context_region_index  map region # for feature forcing (majors); CS may pass assigned region or nil
local function PlaceStartBonusesAtPlot(start_plot, terrain_type_id, branch, along_coastal, context_region_index)
    if not start_plot or start_plot.x == nil or start_plot.y == nil then
        return 0
    end

    local setting = Lekmap_Resources.GetResourceSetting() or 5
    local is_city_state = (branch == BRANCH_MINOR)
    local counts = ResolvedStartSlots(terrain_type_id, setting, branch, along_coastal)
    local weight_table = StartResourceWeights(terrain_type_id, branch)
    local remaining = CopySlotRow(counts)
    local placed = 0

    while true do
        local placed_this_round = false
        for _, subclass in ipairs(Lekmap_Bonus.SUBCLASS_ORDER) do
            local n = remaining[subclass] or 0
            if n > 0 then
                if TryPlaceOneFromSubclass(start_plot, subclass, weight_table, is_city_state, context_region_index) then
                    remaining[subclass] = n - 1
                    placed = placed + 1
                    placed_this_round = true
                end
            end
        end
        if not placed_this_round then
            break
        end
    end

    return placed
end

------------------------------------------------------------------------------
--  START BONUSES — public API (majors & city-states)
------------------------------------------------------------------------------

function Lekmap_Bonus.PlaceMajorStartBonusForRegion(region_index)
    local start_plot = Lekmap_Spawns.GetStartPlot(region_index)
    local terrain_type_id = RegionTypeForIndex(region_index)
    local along = IsMajorStartCoastalForBonuses(region_index)
    local placed = PlaceStartBonusesAtPlot(start_plot, terrain_type_id, BRANCH_MAJOR, along, region_index)

    if Lekmap_Bonus.DEBUG_PRINT_STARTS then
        local sx, sy = "?", "?"
        if start_plot and start_plot.x ~= nil and start_plot.y ~= nil then
            sx, sy = tostring(start_plot.x), tostring(start_plot.y)
        end
        local pnum = Lekmap_Spawns.GetPlayerForRegion(region_index)
        local who, pid = "unassigned", "n/a"
        if pnum then
            pid = tostring(pnum)
            local player = Players[pnum]
            if player then
                local cid = player:GetCivilizationType()
                local civ = GameInfo.Civilizations[cid]
                who = civ and civ.Type or ("Player_" .. pid)
            else
                who = "Player_" .. pid
            end
        end
        local tname = Lekmap_Regions.GetRegionTypeName(terrain_type_id)
        local ocean_c = IsMajorStartOceanCoastal(region_index)
        local inland_c = IsMajorStartInlandSeaCoastalLand(region_index)
        print(string.format(
            "Lekmap_Bonus [major] civ=%s (player %s) | map_region=%d | terrain_type=%d (%s) | tile=(%s,%s) coastal_bonuses=%s (ocean=%s inland_sea_land=%s) | start_bonuses_placed=%d",
            who, pid, region_index, terrain_type_id, tname, sx, sy, tostring(along), tostring(ocean_c), tostring(inland_c), placed))
    end

    return placed
end

function Lekmap_Bonus.PlaceAllMajorStartBonuses()
    local num_regions = Lekmap_Regions.GetRegionCount()
    for region_index = 1, num_regions do
        Lekmap_Bonus.PlaceMajorStartBonusForRegion(region_index)
    end
end

--- @param is_coastal  optional; if nil, derived from salt-water adjacency and (if AllowInlandSea) inland sea coastal land
function Lekmap_Bonus.PlaceCityStateStartBonus(cs_number, x, y, is_coastal)
    local pdata = Lekmap_CityStates.GetPlot and Lekmap_CityStates.GetPlot(cs_number)
    if not pdata and (x == nil or y == nil) then
        return 0
    end
    local px = x or (pdata and pdata.x)
    local py = y or (pdata and pdata.y)
    if px == nil or py == nil then
        return 0
    end
    local start_plot = { x = px, y = py }
    local rn = pdata and pdata.region_number
    local along = is_coastal
    if along == nil then
        along = IsCityStateCoastalForBonuses(px, py)
    end
    local terrain_type_id = TerrainTypeForCityStateRegion(rn)
    local ctx = (rn and rn >= 1) and rn or nil
    local placed = PlaceStartBonusesAtPlot(start_plot, terrain_type_id, BRANCH_MINOR, along, ctx)

    if Lekmap_Bonus.DEBUG_PRINT_STARTS then
        local tname = Lekmap_Regions.GetRegionTypeName(terrain_type_id)
        local reg_part
        if rn and rn >= 1 then
            reg_part = string.format("map_region=%d terrain_type=%d (%s)", rn, terrain_type_id, tname)
        else
            reg_part = string.format("no_major_region (defaults) terrain_type=%d (%s)", terrain_type_id, tname)
        end
        print(string.format(
            "Lekmap_Bonus [city_state] cs_slot=%d | %s | tile=(%d,%d) coastal_bonuses=%s | start_bonuses_placed=%d",
            cs_number, reg_part, px, py, tostring(along), placed))
    end

    return placed
end

function Lekmap_Bonus.PlaceAllCityStateStartBonuses()
    local all = Lekmap_CityStates.GetAllPlots and Lekmap_CityStates.GetAllPlots()
    if not all then
        return
    end
    for cs_number, _ in Lekmap_Utilities.OrderedPairs(all) do
        Lekmap_Bonus.PlaceCityStateStartBonus(cs_number)
    end
end

------------------------------------------------------------------------------
--  SCATTER — density / spacing helpers (uses tables at top of file)
------------------------------------------------------------------------------

--- Returns SCATTER_DENSITY_MULTIPLIER[row] or a mid default if setting is missing.
local function ScatterDensityMult(resource_setting)
    local density_table = Lekmap_Bonus.SCATTER_DENSITY_MULTIPLIER
    return density_table[resource_setting] or 0.65
end

--- BONUS impact layer spacing: explicit rule.spacing or ResourceDefs default_spacing.
local function SpacingForScatterRule(rule, resource_key)
    if rule.spacing then
        return rule.spacing.min, rule.spacing.max
    end
    local a = Lekmap_ResourceDefs.active and Lekmap_ResourceDefs.active[resource_key]
    if a and a.classInfo and a.classInfo.default_spacing then
        local s = a.classInfo.default_spacing
        return s.min, s.max
    end
    return 1, 2
end

------------------------------------------------------------------------------
--  SCATTER — spawn buffers (major + city-state) and candidate filtering
------------------------------------------------------------------------------

--- Add hex rings 1..num_rings around (cx,cy) into excluded[plot_index]=true (1-based grid index).
local function AddRingsToExclusion(excluded, map_width, cx, cy, num_rings)
    if not num_rings or num_rings < 1 then
        return
    end
    local center = Map.GetPlot(cx, cy)
    if not center then
        return
    end
    for ring_distance = 1, num_rings do
        for ring_plot in Lekmap_HexUtil.PlotRingIterator(center, ring_distance) do
            local rx, ry = ring_plot:GetX(), ring_plot:GetY()
            excluded[ry * map_width + rx + 1] = true
        end
    end
end

--- Union of rings around every major civ start (Lekmap_Spawns.GetAllStartPlots).
local function BuildMajorSpawnExclusionSet(num_rings)
    local excluded = {}
    if not num_rings or num_rings < 1 then
        return excluded
    end
    local map_width = select(1, Lekmap_Resources.GetMapDimensions())
    local starts = Lekmap_Spawns.GetAllStartPlots and Lekmap_Spawns.GetAllStartPlots()
    if not starts then
        return excluded
    end
    for _, sp in Lekmap_Utilities.OrderedPairs(starts) do
        if sp and sp.x ~= nil and sp.y ~= nil then
            AddRingsToExclusion(excluded, map_width, sp.x, sp.y, num_rings)
        end
    end
    return excluded
end

--- Union of rings around every city-state spawn (Lekmap_CityStates.GetAllPlots).
local function BuildCityStateSpawnExclusionSet(num_rings)
    local excluded = {}
    if not num_rings or num_rings < 1 then
        return excluded
    end
    local map_width = select(1, Lekmap_Resources.GetMapDimensions())
    local all = Lekmap_CityStates.GetAllPlots and Lekmap_CityStates.GetAllPlots()
    if not all then
        return excluded
    end
    for _, pdata in Lekmap_Utilities.OrderedPairs(all) do
        if pdata and pdata.x ~= nil and pdata.y ~= nil then
            AddRingsToExclusion(excluded, map_width, pdata.x, pdata.y, num_rings)
        end
    end
    return excluded
end

--- Union of forbidden plot indices: major starts + city-state spawns (each with its own ring count).
local function BuildWorldScatterSpawnExclusion(wcfg)
    wcfg = wcfg or Lekmap_Bonus.WORLD_SCATTER_CONFIG
    local excluded_plot_indices = {}
    local major_rings = wcfg.major_spawn_clear_rings
    if major_rings and major_rings >= 1 then
        local major_set = BuildMajorSpawnExclusionSet(major_rings)
        for plot_index, _ in Lekmap_Utilities.OrderedPairs(major_set) do
            excluded_plot_indices[plot_index] = true
        end
    end
    local city_state_rings = wcfg.city_state_spawn_clear_rings
    if city_state_rings and city_state_rings >= 1 then
        local cs_set = BuildCityStateSpawnExclusionSet(city_state_rings)
        for plot_index, _ in Lekmap_Utilities.OrderedPairs(cs_set) do
            excluded_plot_indices[plot_index] = true
        end
    end
    return excluded_plot_indices
end

local function FilterScatterIndices(plot_list, excluded_spawn, use_ps_impact)
    if not plot_list or #plot_list == 0 then
        return {}
    end
    local plot_cache = Lekmap_Resources.GetPlotCache()
    local IMPACT_LAYER = Lekmap_Constants.IMPACT_LAYER
    local out = {}
    for _, idx in ipairs(plot_list) do
        local entry = plot_cache[idx]
        if entry and not excluded_spawn[idx] then
            if use_ps_impact then
                if Lekmap_Impact.GetValue(IMPACT_LAYER.PLAYER_SPAWN, entry.x, entry.y) > 0 then
                    -- skip
                else
                    table.insert(out, idx)
                end
            else
                table.insert(out, idx)
            end
        end
    end
    return out
end

------------------------------------------------------------------------------
--  SCATTER — target counts (fertility, terrain weight, frequency)
------------------------------------------------------------------------------

--- One multiplier per map region: low avgFertility → higher quota (bad_region_bonus), high → lower (good_region_penalty).
local function BuildRegionQualityMultipliers()
    local region_count = Lekmap_Regions.GetRegionCount()
    local fertility_multiplier_by_region = {}
    local cfg = Lekmap_Bonus.WORLD_SCATTER_CONFIG.region_quality
    if not cfg or not cfg.enabled or region_count < 1 then
        for map_region_index = 1, region_count do
            fertility_multiplier_by_region[map_region_index] = 1
        end
        return fertility_multiplier_by_region
    end
    local min_avg_fertility, max_avg_fertility = math.huge, -math.huge
    for map_region_index = 1, region_count do
        local region = Lekmap_Regions.GetRegion(map_region_index)
        local avg_fertility = region and region.avgFertility or 0
        if avg_fertility < min_avg_fertility then
            min_avg_fertility = avg_fertility
        end
        if avg_fertility > max_avg_fertility then
            max_avg_fertility = avg_fertility
        end
    end
    if max_avg_fertility <= min_avg_fertility then
        for map_region_index = 1, region_count do
            fertility_multiplier_by_region[map_region_index] = 1
        end
        return fertility_multiplier_by_region
    end
    local bad_region_bonus = cfg.bad_region_bonus or 0
    local good_region_penalty = cfg.good_region_penalty or 0
    local min_clamp = cfg.min_mult or 0.8
    local max_clamp = cfg.max_mult or 1.4
    for map_region_index = 1, region_count do
        local region = Lekmap_Regions.GetRegion(map_region_index)
        local avg_fertility = region and region.avgFertility or min_avg_fertility
        local fertility_normalized = (avg_fertility - min_avg_fertility) / (max_avg_fertility - min_avg_fertility)
        local quality_mult = 1 + bad_region_bonus * (1 - fertility_normalized) - good_region_penalty * fertility_normalized
        if quality_mult < min_clamp then
            quality_mult = min_clamp
        end
        if quality_mult > max_clamp then
            quality_mult = max_clamp
        end
        fertility_multiplier_by_region[map_region_index] = quality_mult
    end
    return fertility_multiplier_by_region
end

--- Rough placements wanted ≈ num_candidates / (base_frequency * density_mult / (terrain_mult * quality_mult)).
--- Larger base_frequency ⇒ fewer resources; terrain_mult/quality_mult act as quota reducers when <1.
local function ScatterTargetCount(num_candidates, base_frequency, density_mult, terrain_resource_multiplier, region_fertility_multiplier)
    if num_candidates < 1 or base_frequency <= 0 then
        return 0
    end
    local terrain_mult = terrain_resource_multiplier or 1
    local fertility_mult = region_fertility_multiplier or 1
    if terrain_mult <= 0 or fertility_mult <= 0 then
        return 0
    end
    local denominator = base_frequency * density_mult / (terrain_mult * fertility_mult)
    if denominator < 1e-6 then
        denominator = 1e-6
    end
    return math.ceil(num_candidates / denominator)
end

--- Land scatter: multiplier from START_BY_REGION.resource_weights (FISH => 0). Omit/0 weight => no scatter.
local function WorldScatterResourceMultiplier(region_type, resource_key)
    if resource_key == "FISH" then
        return 0
    end
    local wcfg = Lekmap_Bonus.WORLD_SCATTER_CONFIG
    local ref = wcfg.scatter_weight_reference or 22
    if ref < 1 then
        ref = 1
    end
    local pack = StartPackForTerrain(region_type)
    if not pack then
        return 0
    end
    local tbl = pack.resource_weights or (pack.major and pack.major.weights) or {}
    local w = tbl[resource_key]
    if w == nil or w <= 0 then
        return 0
    end
    return w / ref
end

--- Land scatter for one resource in one region: soft -> force impact -> start-style relax.
local function PlaceLandScatterQuota(candidates, resource_key, min_r, max_r, target, region_index)
    local placed = 0
    if target < 1 or #candidates < 1 then
        return 0
    end
    for _, idx in ipairs(candidates) do
        if placed >= target then
            break
        end
        if Lekmap_Resources.PlaceScatterBonusAtPlotIndex(idx, resource_key, min_r, max_r, {}) then
            placed = placed + 1
        end
    end
    if placed < target then
        for _, idx in ipairs(candidates) do
            if placed >= target then
                break
            end
            if Lekmap_Resources.PlaceScatterBonusAtPlotIndex(idx, resource_key, min_r, max_r, { ignore_bonus_impact = true }) then
                placed = placed + 1
            end
        end
    end
    if placed < target and region_index then
        for _, idx in ipairs(candidates) do
            if placed >= target then
                break
            end
            local cache = Lekmap_Resources.GetPlotCache()
            local e = cache[idx]
            if e and Lekmap_Resources.TryPlaceStartBonusAtPlot(resource_key, e.x, e.y, region_index) then
                placed = placed + 1
            end
        end
    end
    return placed
end

--- Sea scatter: no TryPlaceStartBonusAtPlot relax (water tiles); soft then force impact only.
local function PlaceSeaScatterQuota(candidates, resource_key, min_r, max_r, target)
    local placed = 0
    if target < 1 or #candidates < 1 then
        return 0
    end
    for _, idx in ipairs(candidates) do
        if placed >= target then
            break
        end
        if Lekmap_Resources.PlaceScatterBonusAtPlotIndex(idx, resource_key, min_r, max_r, {}) then
            placed = placed + 1
        end
    end
    if placed < target then
        for _, idx in ipairs(candidates) do
            if placed >= target then
                break
            end
            if Lekmap_Resources.PlaceScatterBonusAtPlotIndex(idx, resource_key, min_r, max_r, { ignore_bonus_impact = true }) then
                placed = placed + 1
            end
        end
    end
    return placed
end

------------------------------------------------------------------------------
--  SCATTER — sea plot lists (mainland bands, open coast)
------------------------------------------------------------------------------

--- Live plot must still have no terrain feature (matches IsValidPlotForResource for coast water if cache is stale).
local function PlotIsBareCoastWaterForScatter(plot)
    return plot and plot:GetFeatureType() == FeatureTypes.NO_FEATURE
end

local function ShuffleIndexList(list)
    for end_index = #list, 2, -1 do
        local swap_index = Map.Rand(end_index, "Lekmap_Bonus sea scatter shuffle") + 1
        list[end_index], list[swap_index] = list[swap_index], list[end_index]
    end
end

--- Disjoint coast-water lists per mainland distance band (1 = inner, 2 = expanded, 3 = third ring).
local function CollectMainlandSeaRingLists(resource_key, max_ring, excluded_spawn, use_ps_impact)
    local def = Lekmap_ResourceDefs.active and Lekmap_ResourceDefs.active[resource_key]
        and Lekmap_ResourceDefs.active[resource_key].def
    local lists = { {}, {}, {} }
    if not def then
        return lists
    end
    local inner, expanded = Lekmap_Utilities.GenerateMainlandExpandedCoastData()
    local three = Lekmap_Utilities.GenerateThreeFromMainlandCoast(inner, expanded)
    local plot_cache = Lekmap_Resources.GetPlotCache()
    local map_width, map_height = Lekmap_Resources.GetMapDimensions()
    for y = 0, map_height - 1 do
        for x = 0, map_width - 1 do
            local idx = y * map_width + x + 1
            local band = nil
            if max_ring >= 1 and inner[idx] then
                band = 1
            elseif max_ring >= 2 and expanded[idx] then
                band = 2
            elseif max_ring >= 3 and three[idx] then
                band = 3
            end
            if band then
                local entry = plot_cache[idx]
                if entry and Lekmap_Resources.IsValidPlotForResource(entry, def) then
                    local plot = Map.GetPlot(x, y)
                    if PlotIsBareCoastWaterForScatter(plot) then
                        table.insert(lists[band], idx)
                    end
                end
            end
        end
    end
    for band_index = 1, 3 do
        lists[band_index] = FilterScatterIndices(lists[band_index], excluded_spawn, use_ps_impact)
        ShuffleIndexList(lists[band_index])
    end
    return lists
end

--- Single merged near-mainland list (used when SEA rule has no mainland_ring_weights).
local function BuildMainlandProximitySeaPlotsMerged(resource_key, max_ring, excluded_spawn, use_ps_impact)
    local ring_lists = CollectMainlandSeaRingLists(resource_key, max_ring, excluded_spawn, use_ps_impact)
    local merged = {}
    for band_index = 1, max_ring do
        for _, idx in ipairs(ring_lists[band_index] or {}) do
            table.insert(merged, idx)
        end
    end
    ShuffleIndexList(merged)
    return merged
end

local function BuildMainlandSeaLookup(max_ring)
    local inner, expanded = Lekmap_Utilities.GenerateMainlandExpandedCoastData()
    local three = Lekmap_Utilities.GenerateThreeFromMainlandCoast(inner, expanded)
    local map_width, map_height = Lekmap_Resources.GetMapDimensions()
    local lookup = {}
    for y = 0, map_height - 1 do
        for x = 0, map_width - 1 do
            local idx = y * map_width + x + 1
            local use = false
            if max_ring >= 1 and inner[idx] then
                use = true
            end
            if max_ring >= 2 and expanded[idx] then
                use = true
            end
            if max_ring >= 3 and three[idx] then
                use = true
            end
            if use then
                lookup[idx] = true
            end
        end
    end
    return lookup
end

--- Coast ocean tiles not in skip_lookup (typically: not already covered by near-mainland bands).
--- @param salt_water_coast_only  if true, skip fresh-water coast (inland seas); those use BuildInlandSeaFishPlots when AllowInlandSea is on.
local function BuildOpenCoastSeaPlots(resource_key, skip_lookup, excluded_spawn, use_ps_impact, salt_water_coast_only)
    local def = Lekmap_ResourceDefs.active and Lekmap_ResourceDefs.active[resource_key]
        and Lekmap_ResourceDefs.active[resource_key].def
    if not def then
        return {}
    end
    salt_water_coast_only = salt_water_coast_only == true
    local plot_cache = Lekmap_Resources.GetPlotCache()
    local raw = {}
    for i, entry in ipairs(plot_cache) do
        if not entry.has_resource and entry.is_coast and entry.is_water and not entry.is_lake then
            if not (skip_lookup and skip_lookup[i]) then
                if Lekmap_Resources.IsValidPlotForResource(entry, def) then
                    local plot = Map.GetPlot(entry.x, entry.y)
                    if PlotIsBareCoastWaterForScatter(plot) then
                        if not salt_water_coast_only or not plot:IsFreshWater() then
                            table.insert(raw, i)
                        end
                    end
                end
            end
        end
    end
    local filtered = FilterScatterIndices(raw, excluded_spawn, use_ps_impact)
    ShuffleIndexList(filtered)
    return filtered
end

--- Fresh-water coast ocean tiles (inland seas / large brackish bodies), not lakes; same skip_lookup as open coast.
local function BuildInlandSeaFishPlots(resource_key, skip_lookup, excluded_spawn, use_ps_impact)
    local def = Lekmap_ResourceDefs.active and Lekmap_ResourceDefs.active[resource_key]
        and Lekmap_ResourceDefs.active[resource_key].def
    if not def then
        return {}
    end
    local plot_cache = Lekmap_Resources.GetPlotCache()
    local raw = {}
    for i, entry in ipairs(plot_cache) do
        if not entry.has_resource and entry.is_coast and entry.is_water and not entry.is_lake then
            if not (skip_lookup and skip_lookup[i]) then
                if Lekmap_Resources.IsValidPlotForResource(entry, def) then
                    local plot = Map.GetPlot(entry.x, entry.y)
                    if PlotIsBareCoastWaterForScatter(plot) and plot:IsFreshWater() then
                        table.insert(raw, i)
                    end
                end
            end
        end
    end
    local filtered = FilterScatterIndices(raw, excluded_spawn, use_ps_impact)
    ShuffleIndexList(filtered)
    return filtered
end

------------------------------------------------------------------------------
--  SCATTER — public API (land then sea)
------------------------------------------------------------------------------

function Lekmap_Bonus.PlaceWorldScatter(resource_setting)
    resource_setting = resource_setting or Lekmap_Resources.GetResourceSetting() or 5
    local density_mult = ScatterDensityMult(resource_setting)
    local wcfg = Lekmap_Bonus.WORLD_SCATTER_CONFIG
    local excluded_spawn = BuildWorldScatterSpawnExclusion(wcfg)
    local use_player_spawn_impact = wcfg.exclude_player_spawn_impact == true
    local num_regions = Lekmap_Regions.GetRegionCount()
    local fertility_multiplier_by_region = BuildRegionQualityMultipliers()

    for _, rule in ipairs(Lekmap_Bonus.WORLD_SCATTER_RULES) do
        local resource_key = rule.resource_key
        if Lekmap_ResourceDefs.GetID(resource_key) then
            local spacing_min, spacing_max = SpacingForScatterRule(rule, resource_key)
            for map_region_index = 1, num_regions do
                local plot_list = Lekmap_Resources.GeneratePlotListInRegion(resource_key, map_region_index)
                local candidates = FilterScatterIndices(plot_list, excluded_spawn, use_player_spawn_impact)
                local terrain_type_id = Lekmap_Regions.GetRegionType(map_region_index) or 7
                local terrain_weight_multiplier = WorldScatterResourceMultiplier(terrain_type_id, resource_key)
                if terrain_weight_multiplier > 0 then
                    local region_fertility_multiplier = fertility_multiplier_by_region[map_region_index] or 1
                    local target_count = ScatterTargetCount(
                        #candidates,
                        rule.base_frequency,
                        density_mult,
                        terrain_weight_multiplier,
                        region_fertility_multiplier
                    )
                    PlaceLandScatterQuota(candidates, resource_key, spacing_min, spacing_max, target_count, map_region_index)
                end
            end
        end
    end
end

function Lekmap_Bonus.PlaceSeaResourceScatter(resource_setting)
    resource_setting = resource_setting or Lekmap_Resources.GetResourceSetting() or 5
    local density_mult = ScatterDensityMult(resource_setting)
    local wcfg = Lekmap_Bonus.WORLD_SCATTER_CONFIG
    local excluded_spawn = BuildWorldScatterSpawnExclusion(wcfg)
    local use_player_spawn_impact = wcfg.exclude_player_spawn_impact == true
    local allow_inland_sea = Lekmap_Spawns.GetAllowInlandSea()

    for _, rule in ipairs(Lekmap_Bonus.SEA_SCATTER_RULES) do
        local resource_key = rule.resource_key
        if not Lekmap_ResourceDefs.GetID(resource_key) then
            -- skip inactive defs
        else
            local spacing_min, spacing_max = SpacingForScatterRule(rule, resource_key)
            local max_mainland_ring = rule.max_ring_from_mainland or 3
            if max_mainland_ring < 1 then
                max_mainland_ring = 1
            end
            if max_mainland_ring > 3 then
                max_mainland_ring = 3
            end

            local mainland_ring_weights = rule.mainland_ring_weights
            local base_frequency_near_mainland = rule.base_frequency_near_mainland or 8
            if mainland_ring_weights and next(mainland_ring_weights) then
                local ring_lists_by_band = CollectMainlandSeaRingLists(resource_key, max_mainland_ring, excluded_spawn, use_player_spawn_impact)
                for band_index = 1, max_mainland_ring do
                    local band_weight = mainland_ring_weights[band_index] or mainland_ring_weights.default or 1
                    if band_weight <= 0 then
                        band_weight = 0.001
                    end
                    -- Higher band_weight ⇒ lower effective frequency ⇒ more fish in that band.
                    local effective_frequency_near_mainland = base_frequency_near_mainland / band_weight
                    local band_plot_list = ring_lists_by_band[band_index] or {}
                    local target_near_mainland = ScatterTargetCount(#band_plot_list, effective_frequency_near_mainland, density_mult, 1, 1)
                    PlaceSeaScatterQuota(band_plot_list, resource_key, spacing_min, spacing_max, target_near_mainland)
                end
            else
                local near_mainland_merged = BuildMainlandProximitySeaPlotsMerged(resource_key, max_mainland_ring, excluded_spawn, use_player_spawn_impact)
                local target_near_merged = ScatterTargetCount(#near_mainland_merged, base_frequency_near_mainland, density_mult, 1, 1)
                PlaceSeaScatterQuota(near_mainland_merged, resource_key, spacing_min, spacing_max, target_near_merged)
            end

            local base_frequency_open_coast = rule.base_frequency_open_coast
            local f_inland_sea = nil
            if allow_inland_sea and resource_key == "FISH" then
                f_inland_sea = rule.base_frequency_inland_sea
                if f_inland_sea == nil then
                    f_inland_sea = base_frequency_open_coast
                end
            end
            local need_mainland_skip_lookup =
                (base_frequency_open_coast and base_frequency_open_coast > 0)
                or (f_inland_sea and f_inland_sea > 0)
            local near_mainland_plot_lookup = need_mainland_skip_lookup
                and BuildMainlandSeaLookup(max_mainland_ring)
                or nil

            if base_frequency_open_coast and base_frequency_open_coast > 0 then
                -- When AllowInlandSea is on, salt-water open coast only; fresh-water inland seas get their own pass below.
                local open_coast_list = BuildOpenCoastSeaPlots(
                    resource_key,
                    near_mainland_plot_lookup,
                    excluded_spawn,
                    use_player_spawn_impact,
                    allow_inland_sea
                )
                local target_open_coast = ScatterTargetCount(#open_coast_list, base_frequency_open_coast, density_mult, 1, 1)
                PlaceSeaScatterQuota(open_coast_list, resource_key, spacing_min, spacing_max, target_open_coast)
            end

            if f_inland_sea and f_inland_sea > 0 then
                local inland_sea_list = BuildInlandSeaFishPlots(
                    resource_key,
                    near_mainland_plot_lookup,
                    excluded_spawn,
                    use_player_spawn_impact
                )
                local target_inland_sea = ScatterTargetCount(#inland_sea_list, f_inland_sea, density_mult, 1, 1)
                PlaceSeaScatterQuota(inland_sea_list, resource_key, spacing_min, spacing_max, target_inland_sea)
            end
        end
    end
end
