------------------------------------------------------------------------------
--  FILE:     Lekmap_CityStates.lua
--  AUTHOR:   EnormousApplePie
--  PURPOSE:  City State placement and normalization for Lekmap.
--            Assigns city states to regions or uninhabited areas, validates
--            candidate plots, places city states with coastal preference,
--            applies impacts, and normalizes terrain around placed locations.
------------------------------------------------------------------------------
--  Depends on:
--      Lekmap_Constants.lua      (IMPACT_LAYER, REGION_TYPE)
--      Lekmap_ResourceDefs.lua   (GetID, IsActive)
--      Lekmap_Resources.lua      (MarkCollision, IsCollision)
--      Lekmap_Regions.lua        (GetRegion, GetRegionCount, GetTerrainCounts)
--      Lekmap_Impact.lua         (PlaceImpact, IsImpacted, GetValue)
--      Lekmap_HexUtil.lua        (PlotRingIterator)
--      Lekmap_Utilities.lua      (GenerateCoastalLandDataTable,
--                                 GenerateNextToCoastalLandDataTables,
--                                 PlotIndex, TestMembership)
--      Lekmap_Luxuries.lua       (GetRegionLuxury, luxury_assignment_count)
--  Engine globals: Map, Players, GameDefines, PlotTypes, TerrainTypes,
--                  FeatureTypes
------------------------------------------------------------------------------
--luacheck: globals Lekmap_CityStates Lekmap_ResourceDefs Lekmap_Resources
--luacheck: globals Lekmap_Regions Lekmap_Impact Lekmap_HexUtil Lekmap_Utilities
--luacheck: globals Lekmap_Luxuries
--luacheck: globals Lekmap_Constants
--luacheck: globals Map Players GameDefines PlotTypes TerrainTypes FeatureTypes

Lekmap_CityStates = {}

------------------------------------------------------------------------------
-- PRIVATE STATE
------------------------------------------------------------------------------
local map_width, map_height = 0, 0

--- Per-CS placement data: city_state_plots[cs_number] = { x, y, region_number }
local city_state_plots = {}

--- Validity flag per CS: true if successfully placed.
local validity_table = {}

--- Region assignment per CS: region_assignments[cs_number] = region_number or -1.
local region_assignments = {}

--- Number of city states discarded (failed placement).
local num_discarded = 0
local city_state_player_ids = {}

--- Cached coastal data tables (generated once).
local plot_data_is_coastal = nil
local plot_data_is_next_to_coast = nil

------------------------------------------------------------------------------
-- NAMED CONSTANTS
------------------------------------------------------------------------------

--- 58% chance to prefer a coastal plot for a city state.
local COASTAL_PREFERENCE = 58

--- CS-to-civ ratio thresholds -> number of CS per region.
--- Checked in descending order; first match wins.
local CS_PER_REGION_THRESHOLDS = {
    { ratio = 14,   count = 10 },
    { ratio = 11,   count = 8 },
    { ratio = 8,    count = 7 },
    { ratio = 5.7,  count = 5 },
    { ratio = 4.35, count = 4 },
    { ratio = 2.7,  count = 3 },
    { ratio = 1.35, count = 2 },
}

--- Fraction of total CS allowed in uninhabited areas.
local UNINHABITED_CAP_METHOD1 = 0.25
local UNINHABITED_CAP_DEFAULT = 0.50

--- Minimum land area plot count to be considered for uninhabited CS.
local MIN_UNINHABITED_AREA_PLOTS = 60

--- Impact radii applied when a city state is placed.
--- numeric literal: Lekmap_Constants not available at load time
local CS_IMPACT = {
    { layer = 4, radius = 4 },  -- CITY_STATE
    { layer = 2, radius = 3 },  -- LUXURY
    { layer = 1, radius = 0 },  -- STRATEGIC
    { layer = 3, radius = 3 },  -- BONUS
}

--- Hammer score threshold for adding hills during normalization.
local MIN_HAMMER_SCORE = 6

------------------------------------------------------------------------------
-- INTERNAL HELPERS
------------------------------------------------------------------------------

--- Convert a 1-based plot index back to x, y coordinates.
local function IndexToXY(plot_index)
    local x = (plot_index - 1) % map_width
    local y = (plot_index - x - 1) / map_width
    return x, y
end

--- Shuffle a table in-place (Fisher-Yates).
local function Shuffle(t)
    for i = #t, 2, -1 do
        local j = Map.Rand(i, "Shuffle CS list") + 1
        t[i], t[j] = t[j], t[i]
    end
end

--- Apply all impact layers for a newly placed city state.
local function ApplyCSImpact(x, y)
    for _, entry in ipairs(CS_IMPACT) do
        Lekmap_Impact.PlaceImpact(entry.layer, x, y, entry.radius)
    end
    Lekmap_Resources.MarkCollision(x, y)
end

--- Remove ice from coast tiles adjacent to a city state.
local function RemoveAdjacentIce(x, y)
    local center_plot = Map.GetPlot(x, y)
    if not center_plot then return end
    for adj_plot in Lekmap_HexUtil.PlotRingIterator(center_plot, 1) do
        if adj_plot:GetFeatureType() == FeatureTypes.FEATURE_ICE then
            adj_plot:SetFeatureType(FeatureTypes.NO_FEATURE, -1)
        end
    end
end

--- Initialize coastal data caches if not already done.
local function EnsureCoastalData()
    if plot_data_is_coastal == nil then
        plot_data_is_coastal, plot_data_is_next_to_coast = Lekmap_Utilities.GenerateNextToCoastalLandDataTables()
    end
end

------------------------------------------------------------------------------
-- VALIDATION
------------------------------------------------------------------------------

------------------------------------------------------------------------------
--- Check whether a city state can be placed at (x, y).
--
--  @param x, y               plot coordinates
--  @param area_id             required area ID (-1 for any)
--  @param force_placement     if true, skip CS proximity check
--  @param ignore_collisions   if true, skip player collision check
--  @param method              placement method (1 = biggest landmass)
--  @return true if eligible
------------------------------------------------------------------------------
function Lekmap_CityStates.CanPlaceAt(x, y, area_id, force_placement, ignore_collisions, method)
    local IMPACT_LAYER = Lekmap_Constants.IMPACT_LAYER

    local plot = Map.GetPlot(x, y)
    if not plot then return false end

    -- Method 1: must be on the biggest landmass.
    if method == 1 then
        local biggest_area = Map.FindBiggestArea(false)
        if biggest_area then
            local biggest_id = biggest_area:GetID()
            if plot:GetArea() ~= biggest_id then
                return false
            end
        end
    end

    -- Area check.
    if area_id ~= -1 and plot:GetArea() ~= area_id then
        return false
    end

    if Lekmap_Competition and Lekmap_Competition.BlocksCityState(x,y) then return false end

    -- Hard exclusions also apply when a soft regional preference is relaxed.
    if plot:IsNaturalWonder() or Lekmap_Resources.IsCollision(x, y) then return false end
    for _, start in Lekmap_Utilities.OrderedPairs(Lekmap_Spawns.GetAllStartPlots()) do
        if Map.PlotDistance(x, y, start.x, start.y) < 5 then return false end
    end
    for _, start in Lekmap_Utilities.OrderedPairs(city_state_plots) do
        if Map.PlotDistance(x, y, start.x, start.y) < 5 then return false end
    end

    -- Terrain/plot type restrictions.
    local plot_type = plot:GetPlotType()
    if plot_type == PlotTypes.PLOT_OCEAN or plot_type == PlotTypes.PLOT_MOUNTAIN then
        return false
    end
    if plot:GetTerrainType() == TerrainTypes.TERRAIN_SNOW then
        return false
    end
    if plot:GetFeatureType() == FeatureTypes.FEATURE_OASIS then
        return false
    end

    -- Reject plots that already have a resource.
    if plot:GetResourceType(-1) ~= -1 then
        return false
    end

    -- Impact layer check: city state spacing and luxury proximity.
    -- NOTE: We do NOT check PLAYER_SPAWN here.  The PLAYER_SPAWN layer has a
    -- huge radius (8-14 tiles) designed for spacing major civs.  CS proximity
    -- to players is already handled by the CITY_STATE impact (radius 5)
    -- applied at each player start in Lekmap_Spawns.
    if not force_placement then
        if Lekmap_Impact.IsImpacted(IMPACT_LAYER.CITY_STATE, x, y) then
            return false
        end
        if Lekmap_Impact.IsImpacted(IMPACT_LAYER.LUXURY, x, y) then
            return false
        end
    end

    -- Player collision check.
    if not ignore_collisions then
        if Lekmap_Resources.IsCollision(x, y) then
            return false
        end
    end

    return true
end

------------------------------------------------------------------------------
-- PLOT SELECTION
------------------------------------------------------------------------------

------------------------------------------------------------------------------
--- Select a plot from coastal and inland candidate lists.
--  58% chance to prefer coastal, 42% inland. Falls back to the other list.
--
--  @param coastal_list      array of 1-based plot indices
--  @param inland_list       array of 1-based plot indices
--  @param check_proximity   if true, verify CS-to-CS distance
--  @param check_collision   if true, verify no player collision
--  @return x, y, success
------------------------------------------------------------------------------
function Lekmap_CityStates.SelectPlot(coastal_list, inland_list, check_proximity, check_collision)
    local IMPACT_LAYER = Lekmap_Constants.IMPACT_LAYER

    coastal_list = coastal_list or {}
    inland_list  = inland_list or {}

    local prefer_coastal = Map.Rand(100, "CS coast vs inland") < COASTAL_PREFERENCE

    --- Try to pick from a given list.
    local function TryList(plot_list)
        if #plot_list == 0 then return nil, nil, false end

        -- Collision check: shuffle and iterate.
        local shuffled = {}
        for _, v in ipairs(plot_list) do table.insert(shuffled, v) end
        Shuffle(shuffled)

        for _, candidate in ipairs(shuffled) do
            local cx, cy = IndexToXY(candidate)
            if Lekmap_CityStates.CanPlaceAt(cx, cy, -1, not check_proximity, false, 0) then
                if not check_proximity or not Lekmap_Impact.IsImpacted(IMPACT_LAYER.CITY_STATE, cx, cy) then
                    return cx, cy, true
                end
            end
        end
        return nil, nil, false
    end

    local x, y, success
    if prefer_coastal then
        x, y, success = TryList(coastal_list)
        if not success then
            x, y, success = TryList(inland_list)
        end
    else
        x, y, success = TryList(inland_list)
        if not success then
            x, y, success = TryList(coastal_list)
        end
    end

    return x or 0, y or 0, success or false
end

------------------------------------------------------------------------------
-- REGION EDGE SCANNING
------------------------------------------------------------------------------

------------------------------------------------------------------------------
--- Carve off the outermost ~20% of a region rectangle and collect eligible
--  city state plots. Returns the remaining inner rectangle for iteration.
--
--  @return coastal_plots, inland_plots, new_wx, new_sy, new_w, new_h, reached_middle
------------------------------------------------------------------------------
local function ObtainNextSection(west_x, south_y, width, height, area_id, force_placement, ignore_collisions, method)
    if width <= 0 or height <= 0 then
        return {}, {}, -1, -1, -1, -1, true
    end

    local reached_middle = (width < 4 or height < 4)
    local taller = (height > width)
    local rows_to_check = math.ceil(0.2 * (taller and height or width))

    local coastal_plots, inland_plots = {}, {}
    EnsureCoastalData()

    for sy = south_y, south_y + height - 1 do
        for sx = west_x, west_x + width - 1 do
            local process_plot = reached_middle

            if not process_plot then
                if not taller then
                    -- Check leftmost and rightmost columns.
                    process_plot = (sx < west_x + rows_to_check) or (sx >= west_x + width - rows_to_check)
                else
                    -- Check top and bottom rows.
                    process_plot = (sy < south_y + rows_to_check) or (sy >= south_y + height - rows_to_check)
                end
            end

            if process_plot then
                local x = sx % map_width
                local y = sy % map_height
                if Lekmap_CityStates.CanPlaceAt(x, y, area_id, force_placement, ignore_collisions, method) then
                    local i = y * map_width + x + 1
                    if plot_data_is_coastal[i] == true then
                        table.insert(coastal_plots, i)
                    else
                        table.insert(inland_plots, i)
                    end
                end
            end
        end
    end

    -- Compute remaining inner rectangle.
    local new_wx, new_sy, new_w, new_h
    if taller then
        new_wx = west_x + rows_to_check
        new_sy = south_y
        new_w  = width - (2 * rows_to_check)
        new_h  = height
    else
        new_wx = west_x
        new_sy = south_y + rows_to_check
        new_w  = width
        new_h  = height - (2 * rows_to_check)
    end

    return coastal_plots, inland_plots, new_wx, new_sy, new_w, new_h, reached_middle
end

------------------------------------------------------------------------------
-- REGION PLACEMENT
------------------------------------------------------------------------------

------------------------------------------------------------------------------
--- Place a city state within a region by scanning edges inward.
------------------------------------------------------------------------------
function Lekmap_CityStates.PlaceInRegion(cs_number, region_number, method)
    local region = Lekmap_Regions.GetRegion(region_number)
    if not region then
        num_discarded = num_discarded + 1
        return
    end

    local placed = false
    local reached_middle = false
    local cur_wx  = region.westX
    local cur_sy  = region.southY
    local cur_w   = region.width
    local cur_h   = region.height
    local area_id = region.areaID

    while not placed and not reached_middle do
        local coastal, inland, next_wx, next_sy, next_w, next_h
        coastal, inland, next_wx, next_sy, next_w, next_h, reached_middle =
            ObtainNextSection(cur_wx, cur_sy, cur_w, cur_h, area_id, false, false, method)
        cur_wx, cur_sy, cur_w, cur_h = next_wx, next_sy, next_w, next_h

        local x, y, success = Lekmap_CityStates.SelectPlot(coastal, inland, false, false)
        if success then
            Lekmap_CityStates.RecordPlacement(cs_number, x, y, region_number)
            placed = true
        end
    end

    if not placed then
        num_discarded = num_discarded + 1
    end
end

------------------------------------------------------------------------------
-- PLACEMENT RECORDING
------------------------------------------------------------------------------

--- Record a successful city state placement: set start plot, apply impacts.
function Lekmap_CityStates.RecordPlacement(cs_number, x, y, region_number)
    city_state_plots[cs_number] = { x = x, y = y, region_number = region_number }
    validity_table[cs_number] = true

    -- Set the engine start plot for this city state player.
    local city_state_id = city_state_player_ids[cs_number]
    local city_state = Players[city_state_id]
    if city_state then
        local start_plot = Map.GetPlot(x, y)
        city_state:SetStartingPlot(start_plot)
    end

    -- Remove adjacent ice.
    RemoveAdjacentIce(x, y)

    -- Apply impact layers.
    ApplyCSImpact(x, y)
end

------------------------------------------------------------------------------
-- ASSIGNMENT
------------------------------------------------------------------------------

------------------------------------------------------------------------------
--- Determine how many city states go per region and to uninhabited areas.
--  Populates the region_assignments table.
--
--  @param num_city_states  total city states in the game
--  @param num_civs         number of major civilizations
--  @param method           placement method (1 = biggest landmass)
------------------------------------------------------------------------------
function Lekmap_CityStates.AssignToRegions(num_city_states, num_civs, method)
    region_assignments = {}
    for i = 1, num_city_states do
        region_assignments[i] = -1
    end

    local num_unassigned = num_city_states
    local current_cs_index = 1

    -- Step 1: Determine per-region count.
    local ratio = num_city_states / num_civs
    local per_region = 0
    for _, threshold in ipairs(CS_PER_REGION_THRESHOLDS) do
        if ratio > threshold.ratio then
            per_region = threshold.count
            break
        end
    end

    -- Assign the per-region city states.
    if per_region > 0 then
        for r = 1, num_civs do
            for _ = 1, per_region do
                if current_cs_index <= num_city_states then
                    region_assignments[current_cs_index] = r
                    current_cs_index = current_cs_index + 1
                    num_unassigned = num_unassigned - 1
                end
            end
        end
    end

    -- Step 2: Uninhabited areas.
    local num_uninhabited = 0
    local uninhabited_coastal = {}
    local uninhabited_inland = {}

    if method ~= 3 then -- Method 3 = rectangular, no uninhabited areas.
        EnsureCoastalData()

        -- Gather inhabited area IDs from regions.
        local inhabited_areas = {}
        for r = 1, num_civs do
            local region = Lekmap_Regions.GetRegion(r)
            if region then
                local aid = region.areaID
                if not Lekmap_Utilities.TestMembership(inhabited_areas, aid) then
                    table.insert(inhabited_areas, aid)
                end
            end
        end

        -- Scan all land plots, categorize by area.
        local civ_land_plots = 0
        local uninhabited_land_plots = 0
        local area_plot_tables = {}
        local area_sizes = {}
        local area_list = {}

        for x = 0, map_width - 1 do
            for y = 0, map_height - 1 do
                local plot = Map.GetPlot(x, y)
                local plot_type = plot:GetPlotType()
                local terrain_type = plot:GetTerrainType()
                if (plot_type == PlotTypes.PLOT_LAND or plot_type == PlotTypes.PLOT_HILLS)
                and terrain_type ~= TerrainTypes.TERRAIN_SNOW then
                    local aid = plot:GetArea()
                    if Lekmap_Utilities.TestMembership(inhabited_areas, aid) then
                        civ_land_plots = civ_land_plots + 1
                    else
                        uninhabited_land_plots = uninhabited_land_plots + 1
                        if not area_sizes[aid] then
                            area_sizes[aid] = 0
                            area_plot_tables[aid] = {}
                            table.insert(area_list, aid)
                        end
                        area_sizes[aid] = area_sizes[aid] + 1
                        local plot_index = y * map_width + x + 1
                        table.insert(area_plot_tables[aid], plot_index)
                    end
                end
            end
        end

        -- Collect candidate plots from large enough uninhabited areas.
        for _, aid in ipairs(area_list) do
            if area_sizes[aid] >= MIN_UNINHABITED_AREA_PLOTS then
                for _, plot_index in ipairs(area_plot_tables[aid]) do
                    local px, py = IndexToXY(plot_index)
                    local plot = Map.GetPlot(px, py)
                    if plot:GetTerrainType() ~= TerrainTypes.TERRAIN_SNOW then
                        if plot_data_is_coastal[plot_index] == true then
                            table.insert(uninhabited_coastal, plot_index)
                        else
                            table.insert(uninhabited_inland, plot_index)
                        end
                    end
                end
            end
        end

        -- Determine how many CS for uninhabited.
        local total_land = civ_land_plots + uninhabited_land_plots
        if total_land > 0 then
            local uninhabited_ratio = uninhabited_land_plots / total_land
            local max_by_ratio = math.floor(3 * uninhabited_ratio * num_city_states)
            local cap = (method == 1) and UNINHABITED_CAP_METHOD1 or UNINHABITED_CAP_DEFAULT
            local max_by_method = math.ceil(num_city_states * cap)
            num_uninhabited = math.min(num_unassigned, max_by_ratio, max_by_method)
        end
        num_unassigned = num_unassigned - num_uninhabited
    end

    -- Reserve indices for uninhabited CS (they keep region_assignments = -1).
    current_cs_index = current_cs_index + num_uninhabited

    -- Step 3: Shared luxury compensation.
    -- Regions that share their luxury with 2 others get extra CS.
    if num_unassigned > 0 then
        local shared_luxury_regions = {}
        for r = 1, num_civs do
            local luxury_key = Lekmap_Luxuries.GetRegionLuxury(r)
            if luxury_key then
                -- Count how many regions share this luxury.
                local count = 0
                for r2 = 1, num_civs do
                    if Lekmap_Luxuries.GetRegionLuxury(r2) == luxury_key then
                        count = count + 1
                    end
                end
                if count == 3 then
                    table.insert(shared_luxury_regions, r)
                end
            end
        end

        if #shared_luxury_regions > 0 and #shared_luxury_regions <= num_unassigned then
            for _, r in ipairs(shared_luxury_regions) do
                if current_cs_index <= num_city_states then
                    region_assignments[current_cs_index] = r
                    current_cs_index = current_cs_index + 1
                    num_unassigned = num_unassigned - 1
                end
            end
        end

        -- Step 4: Low fertility compensation - assign remaining to lowest fertility regions.
        if num_unassigned > 0 then
            -- Assign full rounds first.
            while num_unassigned >= num_civs do
                for r = 1, num_civs do
                    if current_cs_index <= num_city_states then
                        region_assignments[current_cs_index] = r
                        current_cs_index = current_cs_index + 1
                        num_unassigned = num_unassigned - 1
                    end
                end
            end

            -- Partial round: sort regions by fertility ascending.
            if num_unassigned > 0 then
                local fert_list = {}
                for r = 1, num_civs do
                    local region = Lekmap_Regions.GetRegion(r)
                    local counts = Lekmap_Regions.GetTerrainCounts(r)
                    local fertility = (region and region.fertility) or 0
                    local area_plots = (counts and counts.areaPlots) or 1
                    local per_plot = fertility / area_plots
                    table.insert(fert_list, { region = r, fert = per_plot })
                end
                table.sort(fert_list, function(a, b) return a.fert < b.fert end)

                for i = 1, math.min(num_unassigned, #fert_list) do
                    if current_cs_index <= num_city_states then
                        region_assignments[current_cs_index] = fert_list[i].region
                        current_cs_index = current_cs_index + 1
                        num_unassigned = num_unassigned - 1
                    end
                end
            end
        end
    end

    if num_unassigned ~= 0 then
        print("Lekmap_CityStates: WARNING - " .. num_unassigned .. " city states still unassigned after assignment.")
    else
        print("Lekmap_CityStates: All " .. num_city_states .. " city states assigned.")
    end

    return uninhabited_coastal, uninhabited_inland
end

------------------------------------------------------------------------------
-- NORMALIZATION HELPERS
------------------------------------------------------------------------------

--- Attempt to convert a flat plot to hills.
local function AttemptToPlaceHills(x, y)
    local plot = Map.GetPlot(x, y)
    if not plot then return false end
    if plot:GetResourceType(-1) ~= -1 then return false end
    local plot_type = plot:GetPlotType()
    if plot_type ~= PlotTypes.PLOT_LAND or plot:IsNaturalWonder() or Lekmap_Resources.IsCollision(x, y) then return false end
    if plot:IsRiverSide() then return false end
    if plot:GetFeatureType() == FeatureTypes.FEATURE_FOREST then return false end
    plot:SetPlotType(PlotTypes.PLOT_HILLS, false, true)
    plot:SetFeatureType(FeatureTypes.NO_FEATURE, -1)
    return true
end

--- Attempt to place a food bonus at a plot. Returns placed_bonus, placed_oasis, placed_fish.
local function AttemptToPlaceBonus(x, y, allow_oasis, fish_count)
    local plot = Map.GetPlot(x, y)
    if not plot or plot:IsMountain() or plot:IsNaturalWonder()
        or Lekmap_Resources.IsCollision(x, y) or plot:GetResourceType(-1) ~= -1 then
        return false, false, false
    end
    local terrain, feature = plot:GetTerrainType(), plot:GetFeatureType()
    if terrain == TerrainTypes.TERRAIN_SNOW or feature == FeatureTypes.FEATURE_OASIS then return false, false, false end
    if plot:IsWater() then
        local placed = fish_count > 0 and Lekmap_Resources.PlaceOne(x, y, "FISH", 1)
        return placed, false, placed
    end
    local key
    if feature == FeatureTypes.FEATURE_JUNGLE then key = "BANANA"
    elseif feature == FeatureTypes.FEATURE_FOREST or plot:IsHills() or terrain == TerrainTypes.TERRAIN_TUNDRA then key = "DEER"
    elseif feature == FeatureTypes.FEATURE_FLOOD_PLAINS or terrain == TerrainTypes.TERRAIN_PLAINS then key = "WHEAT"
    elseif terrain == TerrainTypes.TERRAIN_GRASS then key = "COW"
    elseif terrain == TerrainTypes.TERRAIN_DESERT and not plot:IsFreshWater() and allow_oasis
        and plot:CanHaveFeature(FeatureTypes.FEATURE_OASIS) then
        plot:SetFeatureType(FeatureTypes.FEATURE_OASIS, -1)
        Lekmap_Resources.RefreshPlotCacheAt(x, y)
        return true, true, false
    end
    return key and Lekmap_Resources.PlaceOne(x, y, key, 1) or false, false, false
end

------------------------------------------------------------------------------
--- Evaluate a ring of plots around (cx, cy) and count food/hammer potential.
--
--  @return table with fields: four_food, three_food, two_food, hills, forest,
--          one_hammer, ocean, can_have_bonus, bad_tiles
------------------------------------------------------------------------------
local function EvaluateRing(cx, cy, ring)
    local counts = {
        four_food = 0, three_food = 0, two_food = 0,
        hills = 0, forest = 0, one_hammer = 0, ocean = 0,
        can_have_bonus = 0, bad_tiles = 0,
    }

    local center_plot = Map.GetPlot(cx, cy)
    if not center_plot then return counts end

    for adj_plot in Lekmap_HexUtil.PlotRingIterator(center_plot, ring) do
        local plot_type    = adj_plot:GetPlotType()
        local terrain_type = adj_plot:GetTerrainType()
        local feature_type = adj_plot:GetFeatureType()

        if plot_type == PlotTypes.PLOT_MOUNTAIN then
            counts.bad_tiles = counts.bad_tiles + 1
        elseif plot_type == PlotTypes.PLOT_OCEAN then
            if adj_plot:IsLake() then
                if feature_type == FeatureTypes.FEATURE_ICE then
                    counts.bad_tiles = counts.bad_tiles + 1
                else
                    counts.two_food = counts.two_food + 1
                end
            else
                if feature_type == FeatureTypes.FEATURE_ICE then
                    counts.bad_tiles = counts.bad_tiles + 1
                elseif terrain_type == TerrainTypes.TERRAIN_COAST then
                    counts.ocean = counts.ocean + 1
                    counts.can_have_bonus = counts.can_have_bonus + 1
                end
            end
        else -- Land
            if plot_type == PlotTypes.PLOT_HILLS then
                counts.hills = counts.hills + 1
                if feature_type == FeatureTypes.FEATURE_JUNGLE then
                    counts.two_food = counts.two_food + 1
                    counts.can_have_bonus = counts.can_have_bonus + 1
                elseif feature_type == FeatureTypes.FEATURE_FOREST then
                    counts.can_have_bonus = counts.can_have_bonus + 1
                    counts.forest = counts.forest + 1
                end
            elseif adj_plot:IsFreshWater() then
                if terrain_type == TerrainTypes.TERRAIN_GRASS then
                    counts.four_food = counts.four_food + 1
                    if feature_type ~= FeatureTypes.FEATURE_MARSH then
                        counts.can_have_bonus = counts.can_have_bonus + 1
                    end
                    if feature_type == FeatureTypes.FEATURE_FOREST then
                        counts.forest = counts.forest + 1
                    end
                elseif feature_type == FeatureTypes.FEATURE_FLOOD_PLAINS then
                    counts.four_food = counts.four_food + 1
                    counts.can_have_bonus = counts.can_have_bonus + 1
                elseif terrain_type == TerrainTypes.TERRAIN_PLAINS then
                    counts.three_food = counts.three_food + 1
                    counts.can_have_bonus = counts.can_have_bonus + 1
                    if feature_type == FeatureTypes.FEATURE_FOREST then
                        counts.forest = counts.forest + 1
                    else
                        counts.one_hammer = counts.one_hammer + 1
                    end
                elseif terrain_type == TerrainTypes.TERRAIN_TUNDRA then
                    counts.three_food = counts.three_food + 1
                    counts.can_have_bonus = counts.can_have_bonus + 1
                    if feature_type == FeatureTypes.FEATURE_FOREST then
                        counts.forest = counts.forest + 1
                    end
                elseif terrain_type == TerrainTypes.TERRAIN_DESERT then
                    counts.bad_tiles = counts.bad_tiles + 1
                    counts.can_have_bonus = counts.can_have_bonus + 1
                else
                    counts.bad_tiles = counts.bad_tiles + 1
                end
            else -- Dry flatlands
                if terrain_type == TerrainTypes.TERRAIN_GRASS then
                    counts.three_food = counts.three_food + 1
                    if feature_type ~= FeatureTypes.FEATURE_MARSH then
                        counts.can_have_bonus = counts.can_have_bonus + 1
                    end
                    if feature_type == FeatureTypes.FEATURE_FOREST then
                        counts.forest = counts.forest + 1
                    end
                elseif terrain_type == TerrainTypes.TERRAIN_PLAINS then
                    counts.two_food = counts.two_food + 1
                    counts.can_have_bonus = counts.can_have_bonus + 1
                    if feature_type == FeatureTypes.FEATURE_FOREST then
                        counts.forest = counts.forest + 1
                    else
                        counts.one_hammer = counts.one_hammer + 1
                    end
                elseif terrain_type == TerrainTypes.TERRAIN_TUNDRA then
                    counts.can_have_bonus = counts.can_have_bonus + 1
                    if feature_type == FeatureTypes.FEATURE_FOREST then
                        counts.forest = counts.forest + 1
                    else
                        counts.bad_tiles = counts.bad_tiles + 1
                    end
                elseif terrain_type == TerrainTypes.TERRAIN_DESERT then
                    counts.bad_tiles = counts.bad_tiles + 1
                    counts.can_have_bonus = counts.can_have_bonus + 1
                else
                    counts.bad_tiles = counts.bad_tiles + 1
                end
            end
        end
    end

    return counts
end

------------------------------------------------------------------------------
-- NORMALIZATION
------------------------------------------------------------------------------

------------------------------------------------------------------------------
--- Normalize terrain around a city state to ensure adequate food and hammers.
------------------------------------------------------------------------------
function Lekmap_CityStates.NormalizeLocation(x, y)
    local center_plot = Map.GetPlot(x, y)
    if not center_plot then return end

    -- Evaluate rings.
    local inner = EvaluateRing(x, y, 1)
    local outer = EvaluateRing(x, y, 2)

    -- Hammer adjustment: if low on production, convert a first-ring flat to hills.
    local hammer_score = (4 * inner.hills) + (2 * inner.forest) + inner.one_hammer
    if hammer_score < MIN_HAMMER_SCORE then
        for adj_plot in Lekmap_HexUtil.PlotRingIterator(center_plot, 1) do
            if AttemptToPlaceHills(adj_plot:GetX(), adj_plot:GetY()) then
                break
            end
        end
    end

    -- Food scoring.
    local inner_food_score = (4 * inner.four_food) + (2 * inner.three_food) + inner.two_food
    local outer_food_score = (4 * outer.four_food) + (2 * outer.three_food) + outer.two_food
    local total_food_score = inner_food_score + outer_food_score

    -- Determine how many food bonuses are needed.
    local num_food_bonus_needed = 1
    if total_food_score < 8 or inner_food_score < 4 then
        num_food_bonus_needed = 3
    elseif total_food_score < 12 and inner_food_score < 9 then
        num_food_bonus_needed = 2
    end

    if num_food_bonus_needed <= 0 then return end

    -- Place bonus resources in rings 1 and 2.
    local inner_placed = 0
    local outer_placed = 0
    local allow_oasis = true
    local fish_count = 2
    local tried_all_inner = false
    local tried_all_outer = false

    while num_food_bonus_needed > 0 do
        if inner_placed < 2 and inner.can_have_bonus > 0 and not tried_all_inner then
            -- Try ring 1.
            local found_inner = false
            for adj_plot in Lekmap_HexUtil.PlotRingIterator(center_plot, 1) do
                local b_placed, b_oasis, b_fish = AttemptToPlaceBonus(adj_plot:GetX(), adj_plot:GetY(), allow_oasis, fish_count)
                if b_placed then
                    if b_fish then fish_count = fish_count - 1 end
                    if b_oasis then allow_oasis = false end
                    inner_placed = inner_placed + 1
                    inner.can_have_bonus = inner.can_have_bonus - 1
                    num_food_bonus_needed = num_food_bonus_needed - 1
                    found_inner = true
                    break
                end
            end
            if not found_inner then
                tried_all_inner = true
            end

        elseif (inner_placed + outer_placed) < 4 and outer.can_have_bonus > 0 and not tried_all_outer then
            -- Try ring 2.
            local found_outer = false
            for adj_plot in Lekmap_HexUtil.PlotRingIterator(center_plot, 2) do
                local b_placed, b_oasis, b_fish = AttemptToPlaceBonus(adj_plot:GetX(), adj_plot:GetY(), allow_oasis, fish_count)
                if b_placed then
                    if b_fish then fish_count = fish_count - 1 end
                    if b_oasis then allow_oasis = false end
                    outer_placed = outer_placed + 1
                    outer.can_have_bonus = outer.can_have_bonus - 1
                    num_food_bonus_needed = num_food_bonus_needed - 1
                    found_outer = true
                    break
                end
            end
            if not found_outer then
                tried_all_outer = true
            end
        else
            -- Tried everywhere, give up.
            break
        end
    end
end

--- Normalize all valid city state locations.
function Lekmap_CityStates.NormalizeAll()
    for cs_number, data in Lekmap_Utilities.OrderedPairs(city_state_plots) do
        if validity_table[cs_number] then
            Lekmap_CityStates.NormalizeLocation(data.x, data.y)
        end
    end
end

------------------------------------------------------------------------------
-- ORCHESTRATOR
------------------------------------------------------------------------------

------------------------------------------------------------------------------
--- Main entry point for city state placement.
--
--  @param args  table:
--      numCityStates   (number) total city states
--      numCivs         (number) total major civs
--      method          (number) placement method (1 = biggest landmass)
------------------------------------------------------------------------------
function Lekmap_CityStates.PlaceAll(args)
    args = args or {}
    local num_city_states = args.numCityStates or 0
    local num_civs       = args.numCivs or Lekmap_Regions.GetRegionCount()
    local method         = args.method or 1
    local _, _, _, _, _, _, alive_minor_ids = Lekmap_Utilities.GetPlayerAndTeamInfo()
    city_state_player_ids = args.playerList or alive_minor_ids
    assert(#city_state_player_ids == num_city_states, "City-state count does not match alive player slots")

    map_width, map_height = Map.GetGridSize()
    print("Lekmap_CityStates: Placing " .. num_city_states .. " city states.")

    -- Reset state.
    city_state_plots       = {}
    validity_table         = {}
    region_assignments     = {}
    num_discarded          = 0
    plot_data_is_coastal       = nil
    plot_data_is_next_to_coast = nil

    if num_city_states == 0 then
        print("Lekmap_CityStates: No city states to place.")
        return
    end

    -- Initialize validity table.
    for i = 1, num_city_states do
        validity_table[i] = false
    end

    -- Step 1: Assign city states to regions or uninhabited areas.
    local uninhabited_coastal, uninhabited_inland = Lekmap_CityStates.AssignToRegions(num_city_states, num_civs, method)

    -- Step 2: Place city states.
    print("Lekmap_CityStates: Placing city states.")
    local uninhabited_candidates = #uninhabited_coastal + #uninhabited_inland

    for cs_number = 1, num_city_states do
        local region_number = region_assignments[cs_number]

        if region_number == -1 and uninhabited_candidates > 0 then
            -- Uninhabited placement.
            uninhabited_candidates = uninhabited_candidates - 1
            local x, y, success = Lekmap_CityStates.SelectPlot(uninhabited_coastal, uninhabited_inland, true, true)
            if success then
                Lekmap_CityStates.RecordPlacement(cs_number, x, y, -1)
            else
                num_discarded = num_discarded + 1
            end

        elseif region_number == -1 and uninhabited_candidates <= 0 then
            -- No uninhabited room; redirect to a random region.
            local rand_region = 1 + Map.Rand(num_civs, "CS redirect to region")
            Lekmap_CityStates.PlaceInRegion(cs_number, rand_region, method)

        else
            -- Region placement.
            Lekmap_CityStates.PlaceInRegion(cs_number, region_number, method)
        end
    end

    -- Step 3: Last-chance placement for discarded city states.
    if num_discarded > 0 then
        print("Lekmap_CityStates: " .. num_discarded .. " city states need last-chance placement.")
        local last_chance_plots = {}
        for y = 0, map_height - 1 do
            for x = 0, map_width - 1 do
                if Lekmap_CityStates.CanPlaceAt(x, y, -1, false, false, method) then
                    table.insert(last_chance_plots, y * map_width + x + 1)
                end
            end
        end

        if #last_chance_plots > 0 then
            Shuffle(last_chance_plots)
            local cs_list = {}
            for cs_num = 1, num_city_states do
                if not validity_table[cs_num] then
                    table.insert(cs_list, cs_num)
                end
            end
            for _, cs_num in ipairs(cs_list) do
                local x, y, success = Lekmap_CityStates.SelectPlot(last_chance_plots, {}, true, true)
                if success then
                    Lekmap_CityStates.RecordPlacement(cs_num, x, y, -1)
                    num_discarded = num_discarded - 1
                else
                    break
                end
            end
        end

        if num_discarded > 0 then
            print("Lekmap recovery: completing "..num_discarded.." city-state starts outside the preferred reservations.")
            local occupied={}
            for _,start in Lekmap_Utilities.OrderedPairs(Lekmap_Spawns.GetAllStartPlots()) do occupied[#occupied+1]=start end
            for _,start in Lekmap_Utilities.OrderedPairs(city_state_plots) do occupied[#occupied+1]=start end
            for cs=1,num_city_states do
                if not validity_table[cs] then
                    local x,y
                    for distance=5,1,-1 do
                        x,y=Lekmap_Utilities.FindFallbackStart(occupied,distance,false)
                        if x then break end
                    end
                    if not x then x,y=Lekmap_Utilities.FindFallbackStart(occupied,1,true) end
                    if x then
                        Lekmap_CityStates.RecordPlacement(cs,x,y,-1)
                        occupied[#occupied+1]={x=x,y=y}
                        num_discarded=num_discarded-1
                    end
                end
            end
        end
    end

    -- Step 4: Normalize terrain around placed city states.
    print("Lekmap_CityStates: Normalizing city state locations.")
    Lekmap_CityStates.NormalizeAll()

    -- Summary.
    local num_placed = 0
    for i = 1, num_city_states do
        if validity_table[i] then num_placed = num_placed + 1 end
    end
    print("Lekmap_CityStates: Placement complete. " .. num_placed .. "/" .. num_city_states .. " placed.")
end

------------------------------------------------------------------------------
-- ACCESSORS
------------------------------------------------------------------------------

function Lekmap_CityStates.GetPlot(cs_number)
    return city_state_plots[cs_number]
end

function Lekmap_CityStates.GetAllPlots()
    return city_state_plots
end

function Lekmap_CityStates.IsValid(cs_number)
    return validity_table[cs_number] == true
end

function Lekmap_CityStates.GetValidityTable()
    return validity_table
end

function Lekmap_CityStates.GetNumDiscarded()
    return num_discarded
end
