------------------------------------------------------------------------------
--  FILE:     Lekmap_Strategics.lua
--  AUTHOR:   EnormousApplePie
--  PURPOSE:  Strategic resource placement for Lekmap.
--            Handles major deposits (terrain-based), small scattered deposits,
--            city-state minor strategics, sea oil, strategic balance near
--            starts, and minimum-count safety checks.
------------------------------------------------------------------------------
--  Depends on:
--      Lekmap_Constants.lua      (IMPACT_LAYER)
--      Lekmap_ResourceDefs.lua   (active set, GetID, IsActive, RESOURCE_PREFERENCES)
--      Lekmap_Resources.lua      (ProcessWeightedList, PlaceSpecificNumber,
--                                 GeneratePlotList, GetPlotCache, GetMapDimensions)
--      Lekmap_Impact.lua         (PlaceImpact, IsImpacted)
--      Lekmap_Regions.lua        (GetRegionCount)
--      Lekmap_Spawns.lua         (GetAllStartPlots)
--  Engine globals: Map, PlotTypes, TerrainTypes, FeatureTypes, GameInfo
------------------------------------------------------------------------------
--luacheck: globals Lekmap_Strategics Lekmap_ResourceDefs Lekmap_Resources Lekmap_Regions
--luacheck: globals Lekmap_Spawns Lekmap_Impact Lekmap_HexUtil
--luacheck: globals Lekmap_Constants
--luacheck: globals Map PlotTypes TerrainTypes FeatureTypes GameInfo

Lekmap_Strategics = {}

------------------------------------------------------------------------------
-- QUANTITY TABLES
-- Indexed by resource key, returns quantity per tile for the given density.
------------------------------------------------------------------------------

--- Major deposit quantities, keyed by resource setting bracket.
local MAJOR_QUANTITIES = {
    sparse   = { URANIUM = 2, HORSE = 2, OIL = 5, IRON = 4, COAL = 5, ALUMINUM = 6 },
    mediocre = { URANIUM = 2, HORSE = 3, OIL = 6, IRON = 5, COAL = 6, ALUMINUM = 7 },
    normal   = { URANIUM = 2, HORSE = 4, OIL = 7, IRON = 6, COAL = 7, ALUMINUM = 8 },
    plenty   = { URANIUM = 2, HORSE = 5, OIL = 8, IRON = 7, COAL = 8, ALUMINUM = 9 },
    abundant = { URANIUM = 2, HORSE = 6, OIL = 9, IRON = 8, COAL = 9, ALUMINUM = 10 },
}

--- Small deposit quantities.
local SMALL_QUANTITIES = {
    sparse   = { URANIUM = 1, HORSE = 1, OIL = 2, IRON = 1, COAL = 2, ALUMINUM = 2 },
    normal   = { URANIUM = 2, HORSE = 2, OIL = 4, IRON = 2, COAL = 3, ALUMINUM = 3 },
    abundant = { URANIUM = 2, HORSE = 3, OIL = 3, IRON = 3, COAL = 3, ALUMINUM = 3 },
}

--- Map the 1-10 resource setting to a bracket name.
local function GetBracket(setting)
    if setting <= 2 then return "sparse" end
    if setting == 3 then return "mediocre" end
    if setting >= 8 then return "abundant" end
    if setting == 7 then return "plenty" end
    return "normal"
end

local function GetSmallBracket(setting)
    if setting <= 3 then return "sparse" end
    if setting >= 7 then return "abundant" end
    return "normal"
end

--- Frequency multiplier for appearance rate (higher = fewer resources).
local BONUS_MULTIPLIER = {
    [1]  = 1.00,
    [2]  = 0.90,
    [3]  = 0.80,
    [4]  = 0.75,
    [5]  = 0.65,
    [6]  = 0.55,
    [7]  = 0.45,
    [8]  = 0.35,
    [9]  = 0.25,
    [10] = 0.15,
}

--- Sea oil base amount adjustments.
local SEA_OIL_ADJUST = {
    [1]  = -2, [2] = -2,
    [3]  = -1,
    [7]  =  1,
    [8]  =  2, [9] = 2, [10] = 2,
}

--- Minimum per-civ requirements. { key, absolute_min, per_civ_min }
local MINIMUM_REQUIREMENTS = {
    { "IRON",     8, 4 },
    { "HORSE",    0, 4 },
    { "COAL",     8, 4 },
    { "OIL",      0, 4 },
    { "ALUMINUM", 0, 4 },
    { "URANIUM",  0, 5 },
}

------------------------------------------------------------------------------
-- TERRAIN-SPECIFIC PLOT LIST BUILDERS
-- These generate plot lists filtered by specific terrain+feature combos,
-- matching the original placement groupings.
------------------------------------------------------------------------------

local function BuildFilteredList(plot_cache, map_width, filter_fn)
    local list = {}
    for i, entry in ipairs(plot_cache) do
        if not entry.has_resource and filter_fn(entry) then
            table.insert(list, i)
        end
    end
    -- Shuffle.
    for i = #list, 2, -1 do
        local j = Map.Rand(i, "Shuffle filtered list") + 1
        list[i], list[j] = list[j], list[i]
    end
    return list
end

local function IsMarsh(entry)
    return entry.feature_type == FeatureTypes.FEATURE_MARSH and not entry.is_mountain and not entry.is_water
end

local function IsTundraFlat(entry)
    return entry.terrain_type == TerrainTypes.TERRAIN_TUNDRA and entry.is_flat
       and entry.feature_type == FeatureTypes.NO_FEATURE
end

local function IsSnowFlat(entry)
    return entry.terrain_type == TerrainTypes.TERRAIN_SNOW and entry.is_flat
end

local function IsDesertFlat(entry)
    return entry.terrain_type == TerrainTypes.TERRAIN_DESERT and entry.is_flat
       and entry.feature_type == FeatureTypes.NO_FEATURE
end

local function IsHills(entry)
    return entry.is_hill
end

local function IsJungleFlat(entry)
    return entry.feature_type == FeatureTypes.FEATURE_JUNGLE and entry.is_flat
end

local function IsForestFlat(entry)
    return entry.feature_type == FeatureTypes.FEATURE_FOREST and entry.is_flat
end

local function IsDryGrassFlat(entry)
    return entry.terrain_type == TerrainTypes.TERRAIN_GRASS and entry.is_flat
       and entry.feature_type == FeatureTypes.NO_FEATURE
end

local function IsPlainsFlat(entry)
    return entry.terrain_type == TerrainTypes.TERRAIN_PLAINS and entry.is_flat
       and entry.feature_type == FeatureTypes.NO_FEATURE
end

local function IsLand(entry)
    return not entry.is_water and not entry.is_mountain
end

local function IsCoast(entry)
    return entry.is_coast
end

------------------------------------------------------------------------------
-- MAJOR DEPOSIT PLACEMENT
-- Places terrain-specific weighted strategic deposits.
------------------------------------------------------------------------------

--- Placement instructions: { filter_fn, frequency, { {key, weight_pct, min_radius, max_radius}, ... } }
local function GetMajorPlacementRules()
    return {
        { IsMarsh,        7,  { {"OIL", 65, 1, 4}, {"URANIUM", 35, 1, 4} } },
        { IsTundraFlat,   16, { {"OIL", 55, 1, 5}, {"ALUMINUM", 15, 1, 2}, {"IRON", 35, 1, 2} } },
        { IsSnowFlat,     15, { {"OIL", 65, 1, 5}, {"ALUMINUM", 15, 1, 2}, {"IRON", 20, 1, 2} } },
        { IsDesertFlat,   11, { {"OIL", 70, 1, 2}, {"IRON", 30, 1, 2} } },
        { IsHills,        22, { {"IRON", 26, 1, 3}, {"COAL", 35, 1, 3}, {"ALUMINUM", 39, 1, 3} } },
        { IsJungleFlat,   33, { {"COAL", 30, 1, 2}, {"URANIUM", 70, 1, 2} } },
        { IsForestFlat,   39, { {"COAL", 25, 1, 2}, {"OIL", 25, 1, 5}, {"URANIUM", 50, 10, 0} } },
        { IsDryGrassFlat, 10, { {"HORSE", 100, 1, 5} } },
        { IsPlainsFlat,   10, { {"HORSE", 100, 1, 5} } },
    }
end

function Lekmap_Strategics.PlaceMajorDeposits(resource_setting)
    local IMPACT_LAYER = Lekmap_Constants.IMPACT_LAYER
    local bracket = GetBracket(resource_setting)
    local quantities = MAJOR_QUANTITIES[bracket]
    local plot_cache = Lekmap_Resources.GetPlotCache()
    local map_width, _ = Lekmap_Resources.GetMapDimensions()
    local layer = IMPACT_LAYER.STRATEGIC

    local rules = GetMajorPlacementRules()

    for _, rule in ipairs(rules) do
        local filter_fn  = rule[1]
        local frequency  = rule[2]
        local res_specs  = rule[3]

        local plot_list = BuildFilteredList(plot_cache, map_width, filter_fn)
        if #plot_list > 0 then
            -- Build entries array: { resource_id, quantity, weight, min_radius, max_radius }
            local entries = {}
            for _, spec in ipairs(res_specs) do
                local key = spec[1]
                local resource_id = Lekmap_ResourceDefs.GetID(key)
                if resource_id then
                    local qty = quantities[key] or 2
                    table.insert(entries, { resource_id, qty, spec[2], spec[3], spec[4] })
                end
            end
            if #entries > 0 then
                Lekmap_Resources.ProcessWeightedList(frequency, layer, plot_list, entries)
            end
        end
    end
end

------------------------------------------------------------------------------
-- SMALL DEPOSIT PLACEMENT
-- Scatters small strategic deposits across all land.
------------------------------------------------------------------------------

function Lekmap_Strategics.PlaceSmallDeposits(resource_setting)
    local IMPACT_LAYER = Lekmap_Constants.IMPACT_LAYER
    local small_bracket = GetSmallBracket(resource_setting)
    local quantities = SMALL_QUANTITIES[small_bracket]
    local plot_cache = Lekmap_Resources.GetPlotCache()
    local map_width, _ = Lekmap_Resources.GetMapDimensions()
    local layer = IMPACT_LAYER.STRATEGIC

    local multiplier = BONUS_MULTIPLIER[resource_setting] or 0.65
    local frequency = math.ceil(23 * multiplier)

    local land_list = BuildFilteredList(plot_cache, map_width, IsLand)
    if #land_list == 0 then return end

    local num_to_place = math.ceil(#land_list / frequency)

    -- For each placement, pick a resource based on the plot's terrain/feature.
    local current_idx = 1
    for _ = 1, num_to_place do
        if current_idx > #land_list then break end
        for idx = current_idx, #land_list do
            current_idx = idx + 1
            local plot_index = land_list[idx]
            local entry = plot_cache[plot_index]

            if not Lekmap_Impact.IsImpacted(layer, entry.x, entry.y) then
                local plot = Map.GetPlot(entry.x, entry.y)
                if plot:GetResourceType(-1) == -1 then
                    local key, qty = Lekmap_Strategics.ChooseSmallStrategicForPlot(entry, quantities)
                    if key then
                        local resource_id = Lekmap_ResourceDefs.GetID(key)
                        if resource_id then
                            Lekmap_Resources.PlaceOne(entry.x, entry.y, key, qty)
                        end
                    end
                    break
                end
            end
        end
    end
end

------------------------------------------------------------------------------
--- Choose a small strategic resource appropriate for a plot's terrain/feature.
--  Mirrors the original PlaceSmallQuantitiesOfStrategics terrain logic.
------------------------------------------------------------------------------
function Lekmap_Strategics.ChooseSmallStrategicForPlot(entry, quantities)
    local feature_type = entry.feature_type
    local terrain_type = entry.terrain_type
    local is_hill = entry.is_hill

    if feature_type == FeatureTypes.FEATURE_MARSH then
        local roll = Map.Rand(4, "Small strategic - marsh")
        if roll == 0 then return "IRON", quantities.IRON
        elseif roll == 1 then return "COAL", quantities.COAL
        else return "OIL", quantities.OIL end
    end

    if feature_type == FeatureTypes.FEATURE_JUNGLE then
        local roll = Map.Rand(4, "Small strategic - jungle")
        if roll == 0 then
            if is_hill then return "ALUMINUM", quantities.ALUMINUM
            else return "IRON", quantities.IRON end
        elseif roll == 1 then return "COAL", quantities.COAL
        else return "URANIUM", quantities.URANIUM end
    end

    if feature_type == FeatureTypes.FEATURE_FOREST then
        local roll = Map.Rand(4, "Small strategic - forest")
        if roll == 0 then
            if is_hill then return "ALUMINUM", quantities.ALUMINUM
            else return "IRON", quantities.IRON end
        elseif roll == 1 then return "COAL", quantities.COAL
        else return "URANIUM", quantities.URANIUM end
    end

    if is_hill then
        local roll = Map.Rand(4, "Small strategic - hills")
        if roll < 2 then return "IRON", quantities.IRON
        elseif roll == 2 then return "COAL", quantities.COAL
        else return "ALUMINUM", quantities.ALUMINUM end
    end

    if terrain_type == TerrainTypes.TERRAIN_GRASS then
        local roll = Map.Rand(3, "Small strategic - grass")
        if roll == 0 then return "HORSE", quantities.HORSE
        elseif roll == 1 then return "IRON", quantities.IRON
        else return "COAL", quantities.COAL end
    end

    if terrain_type == TerrainTypes.TERRAIN_PLAINS then
        local roll = Map.Rand(3, "Small strategic - plains")
        if roll == 0 then return "HORSE", quantities.HORSE
        elseif roll == 1 then return "IRON", quantities.IRON
        else return "COAL", quantities.COAL end
    end

    if terrain_type == TerrainTypes.TERRAIN_DESERT then
        local roll = Map.Rand(2, "Small strategic - desert")
        if roll == 0 then return "OIL", quantities.OIL
        else return "IRON", quantities.IRON end
    end

    if terrain_type == TerrainTypes.TERRAIN_TUNDRA then
        local roll = Map.Rand(3, "Small strategic - tundra")
        if roll == 0 then return "OIL", quantities.OIL
        elseif roll == 1 then return "IRON", quantities.IRON
        else return "ALUMINUM", quantities.ALUMINUM end
    end

    if terrain_type == TerrainTypes.TERRAIN_SNOW then
        local roll = Map.Rand(2, "Small strategic - snow")
        if roll == 0 then return "OIL", quantities.OIL
        else return "IRON", quantities.IRON end
    end

    return nil, 0
end

------------------------------------------------------------------------------
-- CITY STATE MINOR STRATEGICS
-- 75% chance per CS to get coal, oil, or aluminum near them.
------------------------------------------------------------------------------

function Lekmap_Strategics.PlaceAtCityStates(args)
    local resource_setting = Lekmap_Resources.GetResourceSetting()
    local small_bracket = GetSmallBracket(resource_setting)
    local quantities = SMALL_QUANTITIES[small_bracket]

    local city_states = args.cityStatePlots or {}
    local validity_table = args.cityStateValidity or {}

    for cs = 1, #city_states do
        if validity_table[cs] ~= false then
            local cs_plot = city_states[cs]
            if cs_plot then
                local x, y = cs_plot[1], cs_plot[2]
                local roll = Map.Rand(4, "CS strategic type")
                if roll > 0 then
                    local key, qty
                    if roll == 1 then key = "COAL" qty = quantities.COAL
                    elseif roll == 2 then key = "OIL" qty = quantities.OIL
                    else key = "ALUMINUM" qty = quantities.ALUMINUM end

                    if Lekmap_ResourceDefs.IsActive(key) then
                        local resource_id = Lekmap_ResourceDefs.GetID(key)
                        local plot_list = Lekmap_Resources.GeneratePlotList(key, { x = x, y = y, radius = 3 })
                        Lekmap_Resources.PlaceSpecificNumber(resource_id, qty, 1, 1.0, -1, 0, 0, plot_list)
                    end
                end
            end
        end
    end
end

------------------------------------------------------------------------------
-- SEA OIL PLACEMENT
-- Places oil on coast tiles, targeting roughly half the land oil count.
------------------------------------------------------------------------------

function Lekmap_Strategics.PlaceSeaOil(resource_setting)
    local IMPACT_LAYER = Lekmap_Constants.IMPACT_LAYER
    local oil_id = Lekmap_ResourceDefs.GetID("OIL")
    if not oil_id then return end

    local base_amount = 4
    local adjust = SEA_OIL_ADJUST[resource_setting] or 0
    local sea_oil_amount = base_amount + adjust
    if sea_oil_amount < 1 then sea_oil_amount = 1 end

    local land_oil_placed = Lekmap_Resources.GetAmountPlaced(oil_id)
    local num_to_place = math.floor((land_oil_placed / 2) / (sea_oil_amount / 2))

    print("Lekmap_Strategics: Sea oil - land oil=" .. land_oil_placed .. ", placing " .. num_to_place .. " at qty " .. sea_oil_amount)

    local plot_cache = Lekmap_Resources.GetPlotCache()
    local map_width, _ = Lekmap_Resources.GetMapDimensions()
    local coast_list = BuildFilteredList(plot_cache, map_width, IsCoast)

    Lekmap_Resources.PlaceSpecificNumber(oil_id, sea_oil_amount, num_to_place, 1.0,
        IMPACT_LAYER.STRATEGIC, 7, 10, coast_list)
end

------------------------------------------------------------------------------
-- STRATEGIC BALANCE (optional)
-- When strategic balance setting is on, places guaranteed strategics near starts.
------------------------------------------------------------------------------

--- Strategic balance guarantee rules:
--- max_radius = hard maximum search distance (3 for most, 6 for uranium).
--- preferred  = preferred distance; if empty at preferred, expand to max.
--- Iron and Horse prefer 1-2 tiles, all others use max directly.
local STRAT_BALANCE_RULES = {
    { key = "IRON",     count = 1, preferred = 2, max_radius = 3 },
    { key = "HORSE",    count = 1, preferred = 2, max_radius = 3 },
    { key = "OIL",      count = 2, preferred = 3, max_radius = 3 },
    { key = "COAL",     count = 1, preferred = 3, max_radius = 3 },
    { key = "ALUMINUM", count = 1, preferred = 3, max_radius = 3 },
    { key = "URANIUM",  count = 1, preferred = 6, max_radius = 6 },
}

-- Preserve the six existing menu choices. The capital luxury/bonus budgets are
-- controlled separately; this setting selects which strategic types are supplied.
function Lekmap_Strategics.GetStartRules(start_quality)
    local quality = start_quality or 2
    local rules = {}
    for _, rule in ipairs(STRAT_BALANCE_RULES) do
        local enabled = rule.key == "IRON" or rule.key == "HORSE" or rule.key == "OIL"
        if rule.key == "COAL" then enabled = quality == 1 or quality == 2 or quality == 4 or quality == 6 end
        if rule.key == "ALUMINUM" then enabled = quality == 1 or quality == 2 or quality == 5 or quality == 6 end
        if rule.key == "URANIUM" then enabled = quality == 2 end
        if enabled then table.insert(rules, rule) end
    end
    return rules
end

function Lekmap_Strategics.PlaceAtStarts(args)
    if not args.strategicBalance or args.guaranteedStrategics == false then return end

    local resource_setting = Lekmap_Resources.GetResourceSetting()
    local bracket = GetBracket(resource_setting)
    local quantities = MAJOR_QUANTITIES[bracket]
    local start_plots = Lekmap_Spawns.GetAllStartPlots()
    if not start_plots then return end

    for region_index, start_plot in pairs(start_plots) do
        if start_plot and start_plot.x and start_plot.y then
            for _, rule in ipairs(Lekmap_Strategics.GetStartRules(args.startQuality)) do
                local resource_id = Lekmap_ResourceDefs.GetID(rule.key)
                if resource_id then
                    local qty = quantities[rule.key] or 2
                    local remaining = rule.count

                    -- First pass: preferred radius.
                    local plot_list = Lekmap_Resources.GeneratePlotList(rule.key, {
                        x = start_plot.x, y = start_plot.y, radius = rule.preferred,
                    })
                    if #plot_list > 0 then
                        remaining = Lekmap_Resources.PlaceSpecificNumber(
                            resource_id, qty, remaining, 1.0, -1, 0, 0, plot_list)
                    end

                    -- Second pass: expand to max_radius if preferred failed.
                    if remaining > 0 and rule.max_radius > rule.preferred then
                        plot_list = Lekmap_Resources.GeneratePlotList(rule.key, {
                            x = start_plot.x, y = start_plot.y, radius = rule.max_radius,
                        })
                        if #plot_list > 0 then
                            remaining = Lekmap_Resources.PlaceSpecificNumber(
                                resource_id, qty, remaining, 1.0, -1, 0, 0, plot_list)
                        end
                    end

                    if remaining > 0 then
                        print(string.format(
                            "Lekmap_Strategics WARNING: Could not guarantee %s for region %d (%d/%d placed).",
                            rule.key, region_index, rule.count - remaining, rule.count))
                    end
                end
            end
        end
    end
end

------------------------------------------------------------------------------
-- MINIMUM SAFETY CHECKS
-- Ensures the map has enough of each strategic for the number of civs.
------------------------------------------------------------------------------

function Lekmap_Strategics.EnforceMinimums(num_civs, resource_setting)
    local IMPACT_LAYER = Lekmap_Constants.IMPACT_LAYER
    local bracket = GetBracket(resource_setting)
    local quantities = MAJOR_QUANTITIES[bracket]
    local plot_cache = Lekmap_Resources.GetPlotCache()
    local map_width, _ = Lekmap_Resources.GetMapDimensions()

    for _, req in ipairs(MINIMUM_REQUIREMENTS) do
        local key         = req[1]
        local abs_min     = req[2]
        local per_civ     = req[3]
        local resource_id = Lekmap_ResourceDefs.GetID(key)
        if resource_id then
            local required = math.max(abs_min, per_civ * num_civs)
            local placed   = Lekmap_Resources.GetAmountPlaced(resource_id)
            local qty      = quantities[key] or 2

            -- For uranium, use a while loop (can need many passes).
            if key == "URANIUM" then
                local max_attempts = 50
                local attempts = 0
                while Lekmap_Resources.GetAmountPlaced(resource_id) < required and attempts < max_attempts do
                    attempts = attempts + 1
                    local land_list = BuildFilteredList(plot_cache, map_width, IsLand)
                    local entries = { { resource_id, qty, 100, 0, 0 } }
                    Lekmap_Resources.ProcessWeightedList(99999, IMPACT_LAYER.STRATEGIC, land_list, entries)
                end
            else
                if placed < required then
                    -- Try specific terrain first for iron/coal on hills.
                    if (key == "IRON" or key == "COAL") and placed < abs_min then
                        local hill_list = BuildFilteredList(plot_cache, map_width, IsHills)
                        local entries = { { resource_id, qty, 100, 0, 0 } }
                        Lekmap_Resources.ProcessWeightedList(99999, IMPACT_LAYER.STRATEGIC, hill_list, entries)
                    end
                    -- Then try any land.
                    if Lekmap_Resources.GetAmountPlaced(resource_id) < required then
                        local filter_fn = IsLand
                        if key == "HORSE" then filter_fn = IsPlainsFlat end
                        local land_list = BuildFilteredList(plot_cache, map_width, filter_fn)
                        local entries = { { resource_id, qty, 100, 0, 0 } }
                        Lekmap_Resources.ProcessWeightedList(99999, IMPACT_LAYER.STRATEGIC, land_list, entries)
                    end
                    -- If horse still low, try grass.
                    if key == "HORSE" and Lekmap_Resources.GetAmountPlaced(resource_id) < required then
                        local grass_list = BuildFilteredList(plot_cache, map_width, IsDryGrassFlat)
                        local entries = { { resource_id, qty, 100, 0, 0 } }
                        Lekmap_Resources.ProcessWeightedList(99999, IMPACT_LAYER.STRATEGIC, grass_list, entries)
                    end
                end
            end
        end
    end
end

------------------------------------------------------------------------------
-- ORCHESTRATOR
------------------------------------------------------------------------------

function Lekmap_Strategics.PlaceAll(args)
    args = args or {}
    local resource_setting = Lekmap_Resources.GetResourceSetting()
    local num_civs = Lekmap_Regions.GetRegionCount()

    print("Lekmap_Strategics: Beginning strategic placement.")

    -- Step 1: Strategic balance (optional).
    Lekmap_Strategics.PlaceAtStarts(args)

    -- Step 2: Major terrain-specific deposits.
    Lekmap_Strategics.PlaceMajorDeposits(resource_setting)

    -- Step 3: City state minor strategics.
    Lekmap_Strategics.PlaceAtCityStates(args)

    -- Step 4: Small scattered deposits.
    Lekmap_Strategics.PlaceSmallDeposits(resource_setting)

    -- Step 5: Sea oil.
    Lekmap_Strategics.PlaceSeaOil(resource_setting)

    -- Step 6: Minimum safety checks.
    Lekmap_Strategics.EnforceMinimums(num_civs, resource_setting)

    print("Lekmap_Strategics: Strategic placement complete.")
end
