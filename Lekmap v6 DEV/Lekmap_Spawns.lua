------------------------------------------------------------------------------
--  FILE:     Lekmap_Spawns.lua
--  AUTHOR:   EnormousApplePie
--  PURPOSE:  Player spawn system for Lekmap.
--            Evaluates candidate start plots, finds optimal starts within
--            regions, gathers civ biases from the database, scores
--            civ-region matchups, and assigns regions respecting biases.
--
--            Coastal bias strength depends on map settings (Option 16).
--            Terrain and river biases are always soft preferences.
------------------------------------------------------------------------------
--  Depends on:
--      Lekmap_Constants.lua     (IMPACT_LAYER, REGION_TYPE)
--      Lekmap_HexUtil.lua       (PlotRingIterator)
--      Lekmap_Utilities.lua     (coastal data, civ bias queries, PlotIndex)
--      Lekmap_Regions.lua       (region data, terrain counts, types)
--      Lekmap_Impact.lua        (PlaceImpact, IsImpacted, GetValue)
--  Engine globals: Map, PlotTypes, TerrainTypes, FeatureTypes, GameInfo, Players
------------------------------------------------------------------------------
--luacheck: globals Lekmap_Spawns Lekmap_HexUtil Lekmap_Utilities Lekmap_Regions Lekmap_Impact
--luacheck: globals Lekmap_Constants
--luacheck: globals Map PlotTypes TerrainTypes FeatureTypes GameInfo Players DB

Lekmap_Spawns = {}

------------------------------------------------------------------------------
-- PRIVATE STATE
------------------------------------------------------------------------------
local map_width, map_height = 0, 0

--- Precomputed coastal proximity data tables (populated at init).
local plot_data_is_coastal         = {}
local plot_data_is_next_to_coast   = {}
local plot_data_is_three_from_coast = {}

--- Per-region condition flags, set after start plots are chosen.
--- start_conditions[region_index] = { along_ocean, along_inland_sea_coast, next_to_lake, ... }
local start_conditions = {}

--- Chosen start plots: start_plots[region_index] = { x, y, score }
local start_plots = {}

--- After ChooseLocations: region_to_player[region_index] = major-civ player ID (for debug / tools).
local region_to_player = {}

--- Stored settings from map script.
local settings = {}

------------------------------------------------------------------------------
-- NAMED CONSTANTS
------------------------------------------------------------------------------

--- Minimum thresholds for plot evaluation.  Can be overridden via args.
local DEFAULT_THRESHOLDS = {
    min_food_inner  = 2,
    min_prod_inner  = 1,
    min_good_inner  = 3,
    min_food_middle = 4,
    min_prod_middle = 2,
    min_good_middle = 6,
    min_food_outer  = 4,
    min_prod_outer  = 4,
    min_good_outer  = 8,
    max_junk        = 5,
}

--- Region center bias defaults (percentage of region dimensions).
local DEFAULT_CENTER_BIAS = 20
local DEFAULT_MIDDLE_BIAS = 50

--- Score awarded when a candidate plot is adjacent to salt water.
local COASTAL_SCORE_BONUS = 40
--- Nudge starts toward plots that can receive guaranteed coastal lux (WHALE/CRAB/PEARLS) per Option 17.
local COAST_LUX_PREFERENCE_BONUS = 28

------------------------------------------------------------------------------
--- Extra score when the start matches Option 17 coastal-luxury coast rules.
------------------------------------------------------------------------------
local function CoastalLuxPreferenceBonus(plot, plot_index)
    local clm = settings.coast_lux_mode or 2
    if clm == 2 or clm == 5 then
        return 0
    end
    local ocean = plot_data_is_coastal[plot_index] == true
    local inland_coast = Lekmap_Utilities.AdjacentToInlandSea(plot:GetX(), plot:GetY())
    if clm == 1 then
        return ocean and COAST_LUX_PREFERENCE_BONUS or 0
    elseif clm == 3 then
        if ocean then return COAST_LUX_PREFERENCE_BONUS end
        if settings.allow_inland_sea and inland_coast then return COAST_LUX_PREFERENCE_BONUS end
        return 0
    elseif clm == 4 then
        if inland_coast and not ocean then return COAST_LUX_PREFERENCE_BONUS end
        return 0
    end
    return 0
end

--- Weighted score look-up tables for inner ring totals.
local WEIGHTED_FOOD_INNER = { [0] = 0, 8, 14, 19, 22, 24, 25 }
local WEIGHTED_PROD_INNER = { [0] = 0, 10, 16, 20, 20, 12, 0 }

--- Weighted score look-up tables for middle ring totals.
local WEIGHTED_FOOD_MIDDLE = { [0] = 0, 2, 5, 10, 20, 25, 28, 30, 32, 34, 35 }
local WEIGHTED_PROD_MIDDLE = { [0] = 0, 10, 20, 25, 30, 35 }

--- Maximum food/prod index before capping.
local FOOD_MIDDLE_CAP  = 35
local PROD_MIDDLE_CAP  = 35

--- BalancedCoastal probability tables (threshold values per player count).
--- Each entry: list of roll-thresholds.  A roll >= threshold adds +1 coastal.
local BALANCED_COASTAL_CHANCES = {
    [6] = {
        [0] = { 5, 10, 95 },
        [1] = { 5, 95 },
        [2] = { 95 },
    },
    [8] = {
        [0] = { 15, 35, 65, 85 },
        [1] = { 10, 55, 85 },
        [2] = { 35, 80, 95 },
        [3] = { 60, 90 },
        [4] = { 75, 95 },
    },
}

--- Player spawn impact parameters.
--- Ripple values for the PLAYER_SPAWN layer, per start distance setting.
local SPAWN_RIPPLE_VALUES = {
    [1] = { 97, 95, 92, 89, 69, 57, 24, 15 },                         -- Close
    [2] = { 97, 95, 92, 88, 83, 77, 70, 62, 51, 41, 30, 18 },         -- Normal (default)
    [3] = { 99, 98, 97, 89, 88, 83, 77, 70, 62, 51, 41, 30, 18, 12 }, -- Far
}

--- City-state layer radius for non-coastal vs coastal spawns.
local CS_LAYER_RADIUS         = 5
local CS_COASTAL_INNER_RADIUS = 3
local CS_COASTAL_OUTER_RADIUS = 4
local CS_COASTAL_EXPAND       = 3

--- Natural wonder exclusion radius (fraction of map height).


--- Resource layer radii applied at each start.
local START_STRATEGIC_RADIUS   = 0
local START_LUXURY_RADIUS      = 3
local START_BONUS_RADIUS       = 3
local START_NW_RADIUS          = 4

------------------------------------------------------------------------------
-- PART 1: PLOT EVALUATION
------------------------------------------------------------------------------

------------------------------------------------------------------------------
--- Classify a single plot's contribution to a start location.
--  Returns a named table with boolean flags:
--    food     : plot provides food
--    prod     : plot provides production
--    good     : plot is "good" quality for its region type
--    junk     : plot is junk (mountain, ice, snow, etc.)
--    double   : count this plot twice (hills on city, snow as junk)
--
--  @param x               plot X
--  @param y               plot Y
--  @param region_type     REGION_TYPE constant for the owning region
--  @param dist_from_city  0 = city tile itself, 1/2/3 = ring number
------------------------------------------------------------------------------
function Lekmap_Spawns.MeasurePlot(x, y, region_type, dist_from_city)
    local REGION_TYPE = Lekmap_Constants.REGION_TYPE
    local result = { food = false, prod = false, good = false, junk = false, double = false }
    local plot         = Map.GetPlot(x, y)
    local plot_type    = plot:GetPlotType()
    local terrain_type = plot:GetTerrainType()
    local feature_type = plot:GetFeatureType()

    -- Mountains are always junk.
    if plot_type == PlotTypes.PLOT_MOUNTAIN then
        result.junk = true
        return result
    end

    -- Water tiles.
    if plot_type == PlotTypes.PLOT_OCEAN then
        if feature_type == FeatureTypes.FEATURE_ICE then
            result.junk = true
        elseif plot:IsLake() then
            result.food = true
        elseif terrain_type == TerrainTypes.TERRAIN_COAST then
            result.food = true
        end
        return result
    end

    -- Jungle (not on city tile).
    if feature_type == FeatureTypes.FEATURE_JUNGLE and dist_from_city ~= 0 then
        if plot_type == PlotTypes.PLOT_HILLS then
            result.prod = true
        end
        if region_type ~= REGION_TYPE.GRASS then
            result.food = true
            if region_type == REGION_TYPE.JUNGLE then
                result.good = true
            end
        end
        return result
    end

    -- Forest (not on city tile).
    if feature_type == FeatureTypes.FEATURE_FOREST and dist_from_city ~= 0 then
        result.prod = true
        if plot_type == PlotTypes.PLOT_HILLS then
            result.good = true
        else
            if terrain_type ~= TerrainTypes.TERRAIN_TUNDRA then
                result.food = true
            end
        end
        return result
    end

    -- Oasis.
    if feature_type == FeatureTypes.FEATURE_OASIS then
        result.food = true
        result.good = true
        return result
    end

    -- Flood Plains.
    if feature_type == FeatureTypes.FEATURE_FLOOD_PLAINS then
        result.food = true
        result.good = true
        return result
    end

    -- Marsh (not on city tile).
    if feature_type == FeatureTypes.FEATURE_MARSH and dist_from_city ~= 0 then
        if region_type == REGION_TYPE.WETLANDS then
            result.good = true
        else
            result.junk = true
        end
        return result
    end

    -- Bare hills (no feature).
    if plot_type == PlotTypes.PLOT_HILLS then
        result.prod = true
        result.good = true
        return result
    end

    -- Flatlands with no feature.
    if terrain_type == TerrainTypes.TERRAIN_SNOW then
        result.junk   = true
        result.double = true
        return result
    end

    if terrain_type == TerrainTypes.TERRAIN_DESERT then
        if region_type == REGION_TYPE.DESERT then
            result.good = true
        else
            result.junk = true
        end
        return result
    end

    if terrain_type == TerrainTypes.TERRAIN_TUNDRA then
        if region_type == REGION_TYPE.TUNDRA then
            result.good = true
        else
            result.junk = true
        end
        return result
    end

    if terrain_type == TerrainTypes.TERRAIN_PLAINS then
        result.good = true
        if region_type == REGION_TYPE.TUNDRA  or region_type == REGION_TYPE.DESERT
        or region_type == REGION_TYPE.HILLS   or region_type == REGION_TYPE.PLAINS
        or region_type == REGION_TYPE.HYBRID then
            result.food = true
        end
        return result
    end

    if terrain_type == TerrainTypes.TERRAIN_GRASS then
        result.food = true
        result.good = true
        return result
    end

    -- Non-standard terrain fallback.
    return result
end

------------------------------------------------------------------------------
--- Tally a ring measurement result into running totals.
--  Handles the `double` flag for double-counting.
local function AccumulateResult(result, totals, ring_plot, center_plot, ring_weight)
    if result.junk then
        totals.junk = totals.junk + 1
        if ring_plot and ring_plot:GetPlotType() == PlotTypes.PLOT_MOUNTAIN and totals.adj_mountains == 0 then
            totals.adj_mountains = totals.adj_mountains + 1
        elseif result.double then
            totals.junk = totals.junk + 1
        end
    else
        if result.food then
            totals.food = totals.food + 1
            if result.double then totals.food = totals.food + 1 end
        end
        if result.prod then
            totals.prod = totals.prod + 1
            if result.double then totals.prod = totals.prod + 1 end
        end
        if result.good then
            totals.good = totals.good + 1
            if result.double then totals.good = totals.good + 1 end
        end
        if ring_plot then
            if ring_plot:IsRiverSide() or (center_plot and center_plot:IsFreshWater()) then
                totals.river = totals.river + ring_weight
            end
        end
    end
end

------------------------------------------------------------------------------
--- Evaluate a candidate start plot by scoring its 3-ring neighbourhood.
--  Returns (score, meets_min).
--
--  @param x            plot X
--  @param y            plot Y
--  @param region_type  REGION_TYPE constant
--  @param thresholds   minimum quality thresholds table
--  @return score       numeric quality score
--  @return meets_min   true if all ring minimums are satisfied
------------------------------------------------------------------------------
function Lekmap_Spawns.EvaluateCandidate(x, y, region_type, thresholds)
    local IMPACT_LAYER = Lekmap_Constants.IMPACT_LAYER
    thresholds = thresholds or DEFAULT_THRESHOLDS
    local plot = Map.GetPlot(x, y)
    local meets_min = true

    local plot_index = Lekmap_Utilities.PlotIndex(x, y)

    local totals = { food = 0, prod = 0, good = 0, junk = 0, river = 0, adj_mountains = 0 }

    -- Coast bonus.
    local coast_score = 0
    if plot_data_is_coastal[plot_index] == true then
        coast_score = COASTAL_SCORE_BONUS
    end

    -- City tile itself (ring 0).
    local inner_ring_score = 0
    local city_result = Lekmap_Spawns.MeasurePlot(x, y, region_type, 0)
    if city_result.prod then
        inner_ring_score = inner_ring_score + 4
        if city_result.double then inner_ring_score = inner_ring_score + 4 end
    end
    if city_result.good then
        totals.good = totals.good + 1
        if city_result.double then totals.good = totals.good + 1 end
    end
    if plot:IsRiverSide() or plot:IsFreshWater() then
        totals.river = totals.river + 4
    end

    -- Ring 1 (inner ring).
    for ring_plot in Lekmap_HexUtil.PlotRingIterator(plot, 1) do
        local rx = ring_plot:GetX()
        local ry = ring_plot:GetY()
        local result = Lekmap_Spawns.MeasurePlot(rx, ry, region_type, 1)
        AccumulateResult(result, totals, ring_plot, plot, 2)
    end

    -- Check inner ring minimums.
    if totals.food < thresholds.min_food_inner then meets_min = false end
    if totals.prod < thresholds.min_prod_inner then meets_min = false end
    if totals.good < thresholds.min_good_inner then meets_min = false end

    -- Inner ring score.
    local food_score_inner = WEIGHTED_FOOD_INNER[math.min(totals.food, 6)] or 25
    local prod_score_inner = WEIGHTED_PROD_INNER[math.min(totals.prod, 6)] or 0
    local good_score_inner = totals.good * 2
    inner_ring_score = inner_ring_score + food_score_inner + prod_score_inner + good_score_inner + totals.river - (totals.junk * 3)

    -- Ring 2 (middle ring).
    for ring_plot in Lekmap_HexUtil.PlotRingIterator(plot, 2) do
        local rx = ring_plot:GetX()
        local ry = ring_plot:GetY()
        local result = Lekmap_Spawns.MeasurePlot(rx, ry, region_type, 2)
        AccumulateResult(result, totals, ring_plot, plot, 2)
    end

    -- Check middle ring minimums (cumulative totals).
    if totals.food < thresholds.min_food_middle then meets_min = false end
    if totals.prod < thresholds.min_prod_middle then meets_min = false end
    if totals.good < thresholds.min_good_middle then meets_min = false end

    -- Middle ring score.
    local food_score_middle = FOOD_MIDDLE_CAP
    if totals.food < 10 then
        food_score_middle = WEIGHTED_FOOD_MIDDLE[totals.food] or FOOD_MIDDLE_CAP
    end
    local effective_prod = totals.prod
    if totals.food * 2 < totals.prod then
        effective_prod = math.ceil(totals.food / 2)
    end
    local prod_score_middle = PROD_MIDDLE_CAP
    if effective_prod < 5 then
        prod_score_middle = WEIGHTED_PROD_MIDDLE[effective_prod] or PROD_MIDDLE_CAP
    end
    local good_score_middle = totals.good * 2
    local middle_ring_score = food_score_middle + prod_score_middle + good_score_middle + totals.river - (totals.junk * 3)

    -- Ring 3 (outer ring).
    for ring_plot in Lekmap_HexUtil.PlotRingIterator(plot, 3) do
        local rx = ring_plot:GetX()
        local ry = ring_plot:GetY()
        local result = Lekmap_Spawns.MeasurePlot(rx, ry, region_type, 3)
        AccumulateResult(result, totals, ring_plot, plot, 2)
    end

    -- Check outer ring minimums (cumulative totals).
    if totals.food < thresholds.min_food_outer then meets_min = false end
    if totals.prod < thresholds.min_prod_outer then meets_min = false end
    if totals.good < thresholds.min_good_outer then meets_min = false end
    if totals.junk > thresholds.max_junk       then meets_min = false end

    -- Outer ring score.
    local outer_ring_score = totals.food + totals.prod + totals.good + totals.river - (totals.junk * 2)

    -- Final score.
    local final_score = inner_ring_score + middle_ring_score + outer_ring_score + coast_score
        + CoastalLuxPreferenceBonus(plot, plot_index)

    -- Distance bias penalty from already-placed spawns.
    local distance_bias = Lekmap_Impact.GetValue(IMPACT_LAYER.PLAYER_SPAWN, x, y)
    if distance_bias > 0 then
        meets_min = false
        final_score = final_score - math.floor(final_score * distance_bias / 100)
    end

    return final_score, meets_min
end

------------------------------------------------------------------------------
--- Iterate a list of candidate plot indices and return the best.
--  Returns: { found_eligible, best_score, best_index, found_fallback, fallback_score, fallback_index }
local function IterateCandidates(plot_list, region_type, thresholds)
    local best_score, best_index         = -5000, nil
    local fallback_score, fallback_index = -5000, nil
    local found_eligible                 = false
    local found_fallback                 = false

    for _, plot_index in ipairs(plot_list) do
        local px = (plot_index - 1) % map_width
        local py = (plot_index - px - 1) / map_width
        local score, meets_min = Lekmap_Spawns.EvaluateCandidate(px, py, region_type, thresholds)
        if meets_min then
            found_eligible = true
            if score > best_score then
                best_score = score
                best_index = plot_index
            end
        else
            found_fallback = true
            if score > fallback_score then
                fallback_score = score
                fallback_index = plot_index
            end
        end
    end
    return { found_eligible, best_score, best_index, found_fallback, fallback_score, fallback_index }
end

------------------------------------------------------------------------------
-- PART 2: FIND START IN REGION
------------------------------------------------------------------------------

------------------------------------------------------------------------------
--- Compute center and middle sub-rectangle bounds within a region.
local function ComputeBiasZones(west_x, south_y, width, height, center_bias, middle_bias)
    -- Center zone.
    local fractional_center_w = (center_bias / 100) * width
    local non_center_w = math.floor((width - fractional_center_w) / 2)
    local center_w = width - non_center_w * 2
    local center_west_x = west_x + non_center_w
    local center_east_x = center_west_x + center_w - 1

    local fractional_center_h = (center_bias / 100) * height
    local non_center_h = math.floor((height - fractional_center_h) / 2)
    local center_h = height - non_center_h * 2
    local center_south_y = south_y + non_center_h
    local center_north_y = center_south_y + center_h - 1

    -- Middle zone.
    local fractional_middle_w = (middle_bias / 100) * width
    local offset_middle_w = math.floor((width - fractional_middle_w) / 2)
    local middle_w = width - offset_middle_w * 2
    local middle_west_x = west_x + offset_middle_w
    local middle_east_x = middle_west_x + middle_w - 1

    local fractional_middle_h = (middle_bias / 100) * height
    local offset_middle_h = math.floor((height - fractional_middle_h) / 2)
    local middle_h = height - offset_middle_h * 2
    local middle_south_y = south_y + offset_middle_h
    local middle_north_y = middle_south_y + middle_h - 1

    return {
        center_west = center_west_x, center_east = center_east_x, center_south = center_south_y, center_north = center_north_y,
        middle_west = middle_west_x, middle_east = middle_east_x, middle_south = middle_south_y, middle_north = middle_north_y,
    }
end

--- Classify a test coordinate into center / middle / outer zone.
local function ClassifyZone(test_x, test_y, zones)
    if test_x >= zones.center_west and test_x <= zones.center_east
    and test_y >= zones.center_south and test_y <= zones.center_north then
        return "center"
    end
    if test_x >= zones.middle_west and test_x <= zones.middle_east
    and test_y >= zones.middle_south and test_y <= zones.middle_north then
        return "middle"
    end
    return "outer"
end

--- Pick the closest eligible plot to the region center.
local function PickClosestToCenter(eligible_list, west_x, south_y, width, height, region_type, thresholds)
    local bullseye_x = west_x + width  / 2
    local bullseye_y = south_y + height / 2
    if bullseye_y / 2 ~= math.floor(bullseye_y / 2) then bullseye_x = bullseye_x + 0.5 end

    local closest_plot
    local closest_dist = math.max(map_width, map_height)
    for _, plot_index in ipairs(eligible_list) do
        local px = (plot_index - 1) % map_width
        local py = (plot_index - px - 1) / map_width
        local adj_x = px
        if py / 2 ~= math.floor(py / 2) then adj_x = adj_x + 0.5 end
        if px < west_x then adj_x = adj_x + map_width end
        local adj_y = py
        if py < south_y then adj_y = adj_y + map_height end
        local dist = math.sqrt((adj_x - bullseye_x) ^ 2 + (adj_y - bullseye_y) ^ 2)
        if dist < closest_dist then
            closest_dist = dist
            closest_plot = plot_index
        end
    end
    return closest_plot
end

------------------------------------------------------------------------------
--- Find the best start plot within a single region.
--
--  @param region_index   1-based region number
--  @param constraints    table:
--      require_coastal   (bool)  HARD: plot must be adjacent to ocean
--      allow_inland_sea  (bool)  if true, inland sea adjacency counts
--      require_river     (bool)  soft preference for river-adjacent
--      no_coast          (bool)  avoid coastal plots (for inland civs when no_coast_inland)
--  @param thresholds     optional override for quality thresholds
--  @return x, y, score, success, forced
------------------------------------------------------------------------------
-- Hard legality is separate from the existing yield score and soft spacing
-- ripples. Even a fallback must be habitable and clear of earlier starts.
function Lekmap_Spawns.IsLegalStart(x, y, minimum_distance)
    local plot = Map.GetPlot(x, y)
    if not plot or plot:IsWater() or plot:IsMountain() or Lekmap_Utilities.IsNaturalWonder(plot)
        or plot:GetFeatureType() == FeatureTypes.FEATURE_OASIS then return false end
    for _, start in Lekmap_Utilities.OrderedPairs(start_plots) do
        if Map.PlotDistance(x, y, start.x, start.y) < (minimum_distance or 5) then return false end
    end
    return true
end

function Lekmap_Spawns.FindStartInRegion(region_index, constraints, thresholds)
    thresholds  = thresholds or DEFAULT_THRESHOLDS
    constraints = constraints or {}

    local region      = Lekmap_Regions.GetRegion(region_index)
    local region_type = Lekmap_Regions.GetRegionType(region_index)
    local west_x      = region.westX
    local south_y     = region.southY
    local width       = region.width
    local height      = region.height
    local area_id     = region.areaID

    local center_bias = settings.center_bias or DEFAULT_CENTER_BIAS
    local middle_bias = settings.middle_bias or DEFAULT_MIDDLE_BIAS
    local zones       = ComputeBiasZones(west_x, south_y, width, height, center_bias, middle_bias)

    -- Candidate buckets.
    local center_river      = {}
    local center_coastal    = {}
    local center_inland_dry = {}
    local middle_river      = {}
    local middle_coastal    = {}
    local middle_inland_dry = {}
    local outer_plots       = {}
    local fallback_plots    = {}

    -- Scan every plot in the region rectangle.
    for ry = 0, height - 1 do
        for rx = 0, width - 1 do
            local px = (rx + west_x) % map_width
            local py = (ry + south_y) % map_height
            local plot_index = py * map_width + px + 1
            local plot = Map.GetPlot(px, py)
            local plot_type = plot:GetPlotType()

            if plot_type == PlotTypes.PLOT_HILLS or plot_type == PlotTypes.PLOT_LAND then
                local minimum_distance = constraints.minimum_distance or ({6, 8, 10})[settings.start_distance or 2]
                local dominated = not Lekmap_Spawns.IsLegalStart(px, py, minimum_distance)

                -- Hard filter: coastal requirement.
                if not dominated and constraints.require_coastal then
                    local is_ocean_coastal = plot_data_is_coastal[plot_index] == true
                    local is_inland_coastal = constraints.allow_inland_sea and Lekmap_Utilities.AdjacentToInlandSea(px, py)
                    if not is_ocean_coastal and not is_inland_coastal then
                        dominated = true
                    end
                end

                -- Soft filter: avoid coast for inland civs.
                if not dominated and constraints.no_coast and plot_data_is_coastal[plot_index] == true then
                    dominated = true
                end

                -- Skip plots too close to ocean (2 or 3 tiles from coast) for non-coastal starts.
                if not dominated and not constraints.require_coastal and not constraints.relax_preferences then
                    if plot_data_is_next_to_coast[plot_index] == true then dominated = true end
                    if not dominated and plot_data_is_three_from_coast[plot_index] == true then dominated = true end
                end

                if not dominated and not constraints.allow_inland_sea
                    and Lekmap_Utilities.AdjacentToInlandSea(px, py)
                    and not plot_data_is_coastal[plot_index] then dominated = true end

                -- Area membership check.
                if not dominated then
                    local plot_area = plot:GetArea()
                    if plot_area ~= area_id and area_id ~= -1 then
                        dominated = true
                    end
                end

                -- Classify into zone.
                if not dominated then
                    local test_x = rx + west_x
                    local test_y = ry + south_y
                    local zone   = ClassifyZone(test_x, test_y, zones)

                    if zone == "center" then
                        if plot:IsRiverSide() then
                            table.insert(center_river, plot_index)
                        elseif plot:IsFreshWater() or plot_data_is_coastal[plot_index] == true then
                            table.insert(center_coastal, plot_index)
                        else
                            table.insert(center_inland_dry, plot_index)
                        end
                    elseif zone == "middle" then
                        if plot:IsRiverSide() then
                            table.insert(middle_river, plot_index)
                        elseif plot:IsFreshWater() or plot_data_is_coastal[plot_index] == true then
                            table.insert(middle_coastal, plot_index)
                        else
                            table.insert(middle_inland_dry, plot_index)
                        end
                    else
                        table.insert(outer_plots, plot_index)
                    end
                end
            end
        end
    end

    -- Build candidate lists in priority order.
    local candidate_lists = {}
    local function AddList(list) if #list > 0 then table.insert(candidate_lists, list) end end
    AddList(center_river)
    AddList(center_coastal)
    AddList(center_inland_dry)
    AddList(middle_river)
    AddList(middle_coastal)
    AddList(middle_inland_dry)

    -- Process center + middle candidates.
    for _, plot_list in ipairs(candidate_lists) do
        local result = IterateCandidates(plot_list, region_type, thresholds)
        if result[1] then -- found eligible
            local best_idx = result[3]
            local best_x = (best_idx - 1) % map_width
            local best_y = (best_idx - best_x - 1) / map_width
            return best_x, best_y, result[2], true, false
        end
        if result[4] then -- found fallback
            local fallback_idx = result[6]
            local fx = (fallback_idx - 1) % map_width
            local fy = (fallback_idx - fx - 1) / map_width
            table.insert(fallback_plots, { fx, fy, result[5] })
        end
    end

    -- Process outer zone.
    if #outer_plots > 0 then
        local outer_eligible = {}
        local fallback_score, fallback_index = -50, nil
        local found_fallback = false
        for _, plot_index in ipairs(outer_plots) do
            local px = (plot_index - 1) % map_width
            local py = (plot_index - px - 1) / map_width
            local score, meets_min = Lekmap_Spawns.EvaluateCandidate(px, py, region_type, thresholds)
            if meets_min then
                table.insert(outer_eligible, plot_index)
            else
                found_fallback = true
                if score > fallback_score then
                    fallback_score = score
                    fallback_index = plot_index
                end
            end
        end
        if #outer_eligible > 0 then
            local closest = PickClosestToCenter(outer_eligible, west_x, south_y, width, height, region_type, thresholds)
            if closest then
                local closest_x = (closest - 1) % map_width
                local closest_y = (closest - closest_x - 1) / map_width
                local closest_score = Lekmap_Spawns.EvaluateCandidate(closest_x, closest_y, region_type, thresholds)
                return closest_x, closest_y, closest_score, true, false
            end
        end
        if found_fallback and fallback_index then
            local fx = (fallback_index - 1) % map_width
            local fy = (fallback_index - fx - 1) / map_width
            table.insert(fallback_plots, { fx, fy, fallback_score })
        end
    end

    -- No eligible plot found anywhere.  Pick the best fallback.
    if #fallback_plots > 0 then
        local best_fallback = fallback_plots[1]
        for i = 2, #fallback_plots do
            if fallback_plots[i][3] > best_fallback[3] then
                best_fallback = fallback_plots[i]
            end
        end
        return best_fallback[1], best_fallback[2], best_fallback[3], true, false
    end

    -- Relax preferences in a defined order, never invent land or overlap a
    -- capital. Keep the region model and yield scoring of the original rewrite.
    local relaxed = {}
    for key, value in pairs(constraints) do relaxed[key] = value end
    if not constraints.relax_preferences then
        relaxed.relax_preferences = true
        relaxed.no_coast = false
    elseif constraints.require_coastal then
        relaxed.require_coastal = false
    elseif (constraints.minimum_distance or 8) > 5 then
        relaxed.minimum_distance = 5
    else
        local occupied={}
        for _,start in Lekmap_Utilities.OrderedPairs(start_plots) do occupied[#occupied+1]=start end
        for distance=5,1,-1 do
            local x,y=Lekmap_Utilities.FindFallbackStart(occupied,distance,false)
            if x then
                print("Lekmap recovery: region "..region_index.." uses a global start search, spacing "..distance)
                return x,y,0,true,true
            end
        end
        local x,y=Lekmap_Utilities.FindFallbackStart(occupied,1,true)
        if x then
            print("Lekmap recovery: made an emergency starting tile for region "..region_index)
            return x,y,0,true,true
        end
        return nil,nil,0,false,false
    end
    print("Lekmap_Spawns: relaxing start preference in region " .. region_index)
    local x, y, score, success = Lekmap_Spawns.FindStartInRegion(region_index, relaxed, thresholds)
    return x, y, score, success, success

end

------------------------------------------------------------------------------
-- PART 3: BIAS-AWARE REGION ASSIGNMENT
------------------------------------------------------------------------------

------------------------------------------------------------------------------
--- Gather start biases for every active civ from the database.
--  Returns a table keyed by player number:
--    biases[player_num] = {
--        coastal        = bool,   -- wants ocean-adjacent start
--        coastal_hard   = bool,   -- coastal is a hard guarantee (depends on settings)
--        place_first    = bool,   -- priority coastal (e.g. Polynesia)
--        river          = bool,   -- wants river start
--        priority_types = {},     -- list of REGION_TYPE IDs this civ prefers
--        avoid_types    = {},     -- list of REGION_TYPE IDs this civ avoids
--    }
------------------------------------------------------------------------------
function Lekmap_Spawns.GatherCivBiases(player_list, coastal_is_hard, balanced_coastal, mixed_bias)
    local biases = {}

    for _, player_num in ipairs(player_list) do
        local player   = Players[player_num]
        local civ_type = GameInfo.Civilizations[player:GetCivilizationType()].Type

        local wants_coastal = Lekmap_Utilities.CivNeedsCoastalStart(civ_type)
        local place_first   = Lekmap_Utilities.CivNeedsPlaceFirstCoastalStart(civ_type)
        local wants_river   = Lekmap_Utilities.CivNeedsRiverStart(civ_type)

        -- MixedBias: weak coastal civs have a chance to lose their coastal requirement.
        if mixed_bias and wants_coastal and not place_first then
            if Map.Rand(100, "MixedBias roll") >= 60 then
                wants_coastal = false
            end
        end

        local priority_types = Lekmap_Utilities.GetStartRegionPriorityListForCiv_GetIDs(civ_type)
        local avoid_types    = Lekmap_Utilities.GetStartRegionAvoidListForCiv_GetIDs(civ_type)

        biases[player_num] = {
            coastal        = wants_coastal,
            coastal_hard   = wants_coastal and coastal_is_hard,
            place_first    = place_first,
            river          = wants_river,
            priority_types = priority_types or {},
            avoid_types    = avoid_types or {},
        }
    end

    -- BalancedCoastal: promote extra random civs to coastal.
    if balanced_coastal then
        local num_regions    = Lekmap_Regions.GetRegionCount()
        local existing_coast = 0
        for _, bias_entry in Lekmap_Utilities.OrderedPairs(biases) do
            if bias_entry.coastal then existing_coast = existing_coast + 1 end
        end
        local chances = BALANCED_COASTAL_CHANCES[num_regions]
        if chances then
            local bucket = chances[existing_coast]
            if bucket then
                local roll = Map.Rand(100, "BalancedCoastal roll")
                local extra_coast = 0
                for _, threshold in ipairs(bucket) do
                    if roll >= threshold then
                        extra_coast = extra_coast + 1
                    end
                end
                -- Promote random non-coastal civs.
                if extra_coast > 0 then
                    local non_coastal_players = {}
                    for player_id, bias_entry in Lekmap_Utilities.OrderedPairs(biases) do
                        if not bias_entry.coastal then
                            table.insert(non_coastal_players, player_id)
                        end
                    end
                    -- Shuffle.
                    for i = #non_coastal_players, 2, -1 do
                        local j = Map.Rand(i, "Shuffle non-coastal") + 1
                        non_coastal_players[i], non_coastal_players[j] = non_coastal_players[j], non_coastal_players[i]
                    end
                    for i = 1, math.min(extra_coast, #non_coastal_players) do
                        local player_id = non_coastal_players[i]
                        biases[player_id].coastal      = true
                        biases[player_id].coastal_hard = coastal_is_hard
                        print("Lekmap_Spawns: BalancedCoastal promoted player " .. player_id .. " to coastal.")
                    end
                end
            end
        end
    end

    return biases
end

------------------------------------------------------------------------------
--- Score how well a region matches a civ's biases.
--  Higher score = better match.
--
--  @param region_index 1-based region number
--  @param bias         bias record for the civ
--  @param assigned     set of already-assigned region indices (for spacing penalty)
--  @return score       numeric match score
------------------------------------------------------------------------------
function Lekmap_Spawns.ScoreRegionForCiv(region_index, bias, assigned)
    local score       = 0
    local region_type = Lekmap_Regions.GetRegionType(region_index)
    local counts      = Lekmap_Regions.GetTerrainCounts(region_index)

    -- Terrain priority bonus.
    for _, pref_type in ipairs(bias.priority_types) do
        if region_type == pref_type then
            score = score + 40
        end
    end

    -- Terrain avoid penalty.
    for _, avoid_type in ipairs(bias.avoid_types) do
        if region_type == avoid_type then
            score = score - 30
        end
    end

    -- River preference.
    if bias.river and counts then
        local river_count = counts.river or 0
        if river_count > 5 then
            score = score + 15
        elseif river_count > 0 then
            score = score + 8
        end
    end

    -- Coastal soft bonus (when not hard).
    if bias.coastal and not bias.coastal_hard then
        if counts and (counts.coastalLand or 0) > 3 then
            score = score + 20
        end
    end

    -- Spacing penalty: adjacent to already-assigned regions.
    if assigned then
        -- Simple heuristic: penalise if a nearby region is already taken.
        -- (More sophisticated distance checks can be added later.)
        for taken_region, _ in Lekmap_Utilities.OrderedPairs(assigned) do
            if taken_region ~= region_index then
                score = score - 2
            end
        end
    end

    return score
end

------------------------------------------------------------------------------
--- Assign regions to civs respecting biases.
--
--  @param biases       table from GatherCivBiases
--  @param player_list  ordered list of player numbers
--  @return assignments table: assignments[player_num] = region_index
------------------------------------------------------------------------------
function Lekmap_Spawns.AssignRegions(biases, player_list)
    local num_regions  = Lekmap_Regions.GetRegionCount()
    local region_free  = {}
    for i = 1, num_regions do region_free[i] = true end

    local assignments = {}
    local assigned    = {}  -- set of assigned region indices

    -- Identify which regions have coastal availability.
    local coastal_regions = {}
    for i = 1, num_regions do
        local counts = Lekmap_Regions.GetTerrainCounts(i)
        if counts and ((counts.coastalLand or 0) + (settings.allow_inland_sea and (counts.inlandSeaCoast or 0) or 0)) >= 3 then
            coastal_regions[i] = true
        end
    end

    -- Sort players by priority: hard-coastal first (place_first = highest), then other coastal, then rest.
    local sorted = {}
    for _, player_num in ipairs(player_list) do table.insert(sorted, player_num) end
    table.sort(sorted, function(a, b)
        local bias_a, bias_b = biases[a], biases[b]
        -- Priority: place_first > coastal_hard > coastal > others
        local priority_a = (bias_a.place_first and 3) or (bias_a.coastal_hard and 2) or (bias_a.coastal and 1) or 0
        local priority_b = (bias_b.place_first and 3) or (bias_b.coastal_hard and 2) or (bias_b.coastal and 1) or 0
        if priority_a == priority_b then return a < b end
        return priority_a > priority_b
    end)

    -- Greedy assignment.
    for _, player_num in ipairs(sorted) do
        local bias        = biases[player_num]
        local best_region = nil
        local best_score  = -9999

        for r = 1, num_regions do
            if region_free[r] then
                -- Hard coastal filter: skip non-coastal regions for hard-coastal civs.
                local eligible = true
                if bias.coastal_hard and not coastal_regions[r] then
                    eligible = false
                end

                if eligible then
                    local score = Lekmap_Spawns.ScoreRegionForCiv(r, bias, assigned)
                    if score > best_score then
                        best_score  = score
                        best_region = r
                    end
                end
            end
        end

        -- If no region found for hard-coastal (edge case), fall back to best of any.
        if best_region == nil and bias.coastal_hard then
            print("Lekmap_Spawns: WARNING - no coastal region for player " .. player_num .. ", falling back.")
            for r = 1, num_regions do
                if region_free[r] then
                    local score = Lekmap_Spawns.ScoreRegionForCiv(r, bias, assigned)
                    if score > best_score then
                        best_score  = score
                        best_region = r
                    end
                end
            end
        end

        if best_region then
            assignments[player_num]  = best_region
            region_free[best_region] = false
            assigned[best_region]    = player_num
            print("Lekmap_Spawns: Player " .. player_num .. " -> Region " .. best_region .. " (score " .. best_score .. ")")
        else
            error("Lekmap: could not assign a region for player " .. player_num .. ". Increase map size or reduce the player count.")
        end
    end

    return assignments
end

------------------------------------------------------------------------------
-- PART 4: ORCHESTRATOR
------------------------------------------------------------------------------

------------------------------------------------------------------------------
--- Place the standard resource and spawn impacts around a start plot.
--  This replaces the old PlaceImpactAndRipples function.
local function PlaceSpawnImpact(x, y, use_collide_coastals)
    local IMPACT_LAYER = Lekmap_Constants.IMPACT_LAYER

    -- Resource layers.
    Lekmap_Impact.PlaceImpact(IMPACT_LAYER.STRATEGIC, x, y, START_STRATEGIC_RADIUS)
    Lekmap_Impact.PlaceImpact(IMPACT_LAYER.LUXURY,    x, y, START_LUXURY_RADIUS)
    Lekmap_Impact.PlaceImpact(IMPACT_LAYER.BONUS,     x, y, START_BONUS_RADIUS)

    -- City-state layer.
    local plot = Map.GetPlot(x, y)
    if plot:IsCoastalLand() and use_collide_coastals then
        Lekmap_Impact.PlaceCoastalImpact(x, y, CS_COASTAL_INNER_RADIUS, CS_COASTAL_OUTER_RADIUS, CS_COASTAL_EXPAND)
    else
        Lekmap_Impact.PlaceImpact(IMPACT_LAYER.CITY_STATE, x, y, CS_LAYER_RADIUS, { flat = true })
    end

    -- Natural wonders layer.
    Lekmap_Impact.PlaceImpact(IMPACT_LAYER.NATURAL_WONDER, x, y, START_NW_RADIUS)

    -- Player spawn distance layer (using custom ripple values).
    local dist_setting  = settings.start_distance or 2
    local ripple_values = SPAWN_RIPPLE_VALUES[dist_setting] or SPAWN_RIPPLE_VALUES[2]
    Lekmap_Impact.PlaceImpact(IMPACT_LAYER.PLAYER_SPAWN, x, y, #ripple_values, {
        rippleValues = ripple_values,
        overlapScale = 1.4,
        overlapCap   = 97,
    })
end

------------------------------------------------------------------------------
--- Record start location conditions for a region (for compatibility with
--  luxury assignment and other downstream systems).
local function RecordStartConditions(region_index, x, y)
    local plot = Map.GetPlot(x, y)
    local plot_index = Lekmap_Utilities.PlotIndex(x, y)

    local along_ocean   = plot_data_is_coastal[plot_index] == true
    --- Coastal land touching fresh water but not ocean (for inland-sea luxury rules).
    local along_inland_sea_coast = Lekmap_Utilities.AdjacentToInlandSea(plot:GetX(), plot:GetY()) and not along_ocean
    local next_to_lake  = plot:IsFreshWater() and not plot:IsRiverSide()
    local is_river      = plot:IsRiverSide()
    local near_river    = false
    local near_mountain = false
    local forest_count  = 0
    local jungle_count  = 0

    -- Check ring 1 for river, mountain, forest, jungle.
    for ring_plot in Lekmap_HexUtil.PlotRingIterator(plot, 1) do
        if ring_plot:IsRiverSide() then near_river = true end
        if ring_plot:GetPlotType() == PlotTypes.PLOT_MOUNTAIN then near_mountain = true end
        if ring_plot:GetFeatureType() == FeatureTypes.FEATURE_FOREST then forest_count = forest_count + 1 end
        if ring_plot:GetFeatureType() == FeatureTypes.FEATURE_JUNGLE then jungle_count = jungle_count + 1 end
    end

    -- Check ring 2 for river.
    if not near_river then
        for ring_plot in Lekmap_HexUtil.PlotRingIterator(plot, 2) do
            if ring_plot:IsRiverSide() then near_river = true break end
        end
    end

    start_conditions[region_index] = {
        along_ocean             = along_ocean,
        along_inland_sea_coast  = along_inland_sea_coast,
        next_to_lake            = next_to_lake,
        is_river      = is_river,
        near_river    = near_river,
        near_mountain = near_mountain,
        forest_count  = forest_count,
        jungle_count  = jungle_count,
    }
end

------------------------------------------------------------------------------
--- Main entry point for the player spawn system.
--
--  @param args  table of settings from the map script:
--      playerList        : ordered list of player numbers
--      NoCoastInland     : (bool) Option 16 - only coastal civs on coast
--      BalancedCoastal   : (bool) Option 16 - add extra random coastals
--      MixedBias         : (bool) weak coastal civs can lose bias
--      AllowInlandSea    : (bool/number) Option 18
--      CoastLuxMode      : (number) Option 17 — 1 ocean guarantee, 2 random, 3 +inland sea, 4 inland only, 5 blocked
--      CoastLux          : (bool, legacy) maps to CoastLuxMode 1 / 2 if CoastLuxMode omitted
--      startDistance     : (number) 1=close, 2=normal, 3=far
--      centerBias        : (number) % center bias (default 20)
--      middleBias        : (number) % middle bias (default 50)
--      collideCoastals   : (bool) use coastal CS collision mod
--      thresholds        : (table) override quality thresholds
--  @return start_plots       table: start_plots[region_index] = { x, y, score }
--  @return start_conditions  table of condition records per region
------------------------------------------------------------------------------
function Lekmap_Spawns.ChooseLocations(args)
    print("Lekmap_Spawns: Choosing start locations for civilizations.")
    args = args or {}

    -- Cache map dimensions.
    map_width, map_height = Map.GetGridSize()

    -- Store settings.
    -- NOTE: For boolean args, use explicit nil checks to avoid Lua's "false or true = true" gotcha.
    settings.center_bias      = args.centerBias    or DEFAULT_CENTER_BIAS
    settings.middle_bias      = args.middleBias    or DEFAULT_MIDDLE_BIAS
    settings.start_distance   = args.startDistance  or 2
    settings.no_coast_inland  = args.NoCoastInland == true
    settings.competitive = args.competitive == true
    if args.CoastLuxMode ~= nil then
        settings.coast_lux_mode = args.CoastLuxMode
    elseif args.CoastLux ~= nil then
        settings.coast_lux_mode = args.CoastLux and 1 or 2
    else
        settings.coast_lux_mode = 2
    end
    settings.collide_coastals = args.collideCoastals ~= false
    settings.allow_inland_sea = (args.AllowInlandSea   ~= nil) and args.AllowInlandSea   or false

    local coastal_is_hard   = (args.NoCoastInland    ~= nil) and args.NoCoastInland    or false
    local balanced_coastal  = (args.BalancedCoastal  ~= nil) and args.BalancedCoastal  or false
    local mixed_bias        = (args.MixedBias        ~= nil) and args.MixedBias        or false
    local no_coast_inland   = (args.NoCoastInland    ~= nil) and args.NoCoastInland    or false
    -- GetPlayerAndTeamInfo returns: num_civs, num_cs, player_id_list, ...
    local player_list       = args.playerList
    if not player_list then
        local _, _, default_list = Lekmap_Utilities.GetPlayerAndTeamInfo()
        player_list = default_list
    end
    local thresholds        = args.thresholds       or DEFAULT_THRESHOLDS

    -- Generate coastal proximity data.
    print("Lekmap_Spawns: Generating coastal proximity data.")
    plot_data_is_coastal, plot_data_is_next_to_coast = Lekmap_Utilities.GenerateNextToCoastalLandDataTables()
    plot_data_is_three_from_coast = Lekmap_Utilities.GenerateThreeFromCoastTable(plot_data_is_coastal, plot_data_is_next_to_coast)

    -- Gather civ biases.
    print("Lekmap_Spawns: Gathering civ biases.")
    local biases = Lekmap_Spawns.GatherCivBiases(player_list, coastal_is_hard, balanced_coastal, mixed_bias)

    -- Assign regions to civs.
    print("Lekmap_Spawns: Assigning regions to civs.")
    local assignments = Lekmap_Spawns.AssignRegions(biases, player_list)

    -- Sort assignment order by region fertility (lowest first, matching original logic).
    local num_regions = Lekmap_Regions.GetRegionCount()
    local region_order = {}
    for r = 1, num_regions do table.insert(region_order, r) end
    table.sort(region_order, function(a, b)
        local region_a = Lekmap_Regions.GetRegion(a)
        local region_b = Lekmap_Regions.GetRegion(b)
        if region_a.avgFertility == region_b.avgFertility then return a < b end
        return (region_a.avgFertility or 0) < (region_b.avgFertility or 0)
    end)

    -- Find starts.
    print("Lekmap_Spawns: Finding start plots.")
    start_plots = {}
    start_conditions = {}
    region_to_player = {}
    for pn, ri in Lekmap_Utilities.OrderedPairs(assignments) do
        region_to_player[ri] = pn
    end

    for _, region_index in ipairs(region_order) do
        -- Find which player is assigned to this region.
        local player_num = nil
        for pn, ri in Lekmap_Utilities.OrderedPairs(assignments) do
            if ri == region_index then player_num = pn break end
        end

        if player_num then
            local bias = biases[player_num]
            local constraints = {
                require_coastal  = bias.coastal_hard or false,
                allow_inland_sea = settings.allow_inland_sea,
                no_coast         = no_coast_inland and not bias.coastal,
            }

            local start_x, start_y, score, success, forced = Lekmap_Spawns.FindStartInRegion(region_index, constraints, thresholds)

            if success then
                start_plots[region_index] = { x = start_x, y = start_y, score = score }
                RecordStartConditions(region_index, start_x, start_y)
                PlaceSpawnImpact(start_x, start_y, settings.collide_coastals)
                print(string.format("  Region %d -> Player %d at (%d, %d) score=%d%s",
                    region_index, player_num, start_x, start_y, score, forced and " [PREFERENCE RELAXED]" or ""))
            else
                error("Lekmap: no legal start in region " .. region_index .. ". Increase map size or reduce the player count.")
            end
        end
    end

    if settings.competitive then
        Lekmap_Competition.RefineStarts(start_plots, assignments, biases, settings)
        -- Relocation is complete before any cities, wonders or resources exist.
        Lekmap_Impact.Initialize()
        for region, start in Lekmap_Utilities.OrderedPairs(start_plots) do
            RecordStartConditions(region, start.x, start.y)
            PlaceSpawnImpact(start.x, start.y, settings.collide_coastals)
        end
    end

    -- Set starting plots on player objects.
    for player_num, region_index in Lekmap_Utilities.OrderedPairs(assignments) do
        local start_data = start_plots[region_index]
        if start_data then
            local player = Players[player_num]
            local start_plot = Map.GetPlot(start_data.x, start_data.y)
            player:SetStartingPlot(start_plot)
            print(string.format("  Player %d starting plot set to (%d, %d).", player_num, start_data.x, start_data.y))
        end
    end

    print("Lekmap_Spawns: Done. " .. #region_order .. " starts placed.")
    return start_plots, start_conditions
end

------------------------------------------------------------------------------
-- ACCESSORS
------------------------------------------------------------------------------

--- Get the chosen start plot for a region.
function Lekmap_Spawns.GetStartPlot(region_index)
    return start_plots[region_index]
end

--- Major civ assigned to this map region (1..N), or nil if none / not yet chosen.
function Lekmap_Spawns.GetPlayerForRegion(region_index)
    return region_to_player[region_index]
end

--- Get the start conditions for a region.
function Lekmap_Spawns.GetStartConditions(region_index)
    return start_conditions[region_index]
end

--- Get all start plots.
function Lekmap_Spawns.GetAllStartPlots()
    return start_plots
end

--- Option 17 index: 1 ocean guarantee, 2 random, 3 guarantee+inland sea, 4 inland sea only, 5 blocked.
function Lekmap_Spawns.GetCoastLuxMode()
    return settings.coast_lux_mode or 2
end

--- Legacy: true when mode tries to place coastal lux (not Random / Blocked).
function Lekmap_Spawns.GetCoastLuxSetting()
    local m = settings.coast_lux_mode or 2
    return (m == 1 or m == 3 or m == 4)
end

--- Get stored settings table.
function Lekmap_Spawns.GetSettings()
    return settings
end

--- True when map script passed AllowInlandSea (Option 18): inland sea coast can count as coastal for starts.
function Lekmap_Spawns.GetAllowInlandSea()
    return settings.allow_inland_sea == true
end
