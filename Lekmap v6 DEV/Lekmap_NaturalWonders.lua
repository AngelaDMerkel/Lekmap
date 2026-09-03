------------------------------------------------------------------------------
--  FILE:     Lekmap_NaturalWonders.lua
--  AUTHOR:   EnormousApplePie
--  PURPOSE:  Natural wonder placement for Lekmap.
--            Reads placement rules from XML (GameInfo.Natural_Wonder_Placement),
--            generates candidate plot lists, selects and places wonders,
--            and applies impact layers to prevent collisions.
------------------------------------------------------------------------------
--  Depends on:
--      Lekmap_Constants.lua      (IMPACT_LAYER)
--      Lekmap_Impact.lua         (PlaceImpact, IsImpacted, GetValue)
--      Lekmap_Resources.lua      (MarkCollision)
--      Lekmap_Utilities.lua      (GenerateCoastalLandDataTable,
--                                 GenerateNextToCoastalLandDataTables)
--      NaturalWondersCustomMethods (engine include: NWCustomEligibility,
--                                   NWCustomPlacement)
--  Engine globals: Map, GameInfo, PlotTypes, TerrainTypes, FeatureTypes,
--                  DirectionTypes
------------------------------------------------------------------------------
--luacheck: globals Lekmap_NaturalWonders Lekmap_Impact Lekmap_Resources
--luacheck: globals Lekmap_Utilities
--luacheck: globals Lekmap_Constants
--luacheck: globals Map GameInfo PlotTypes TerrainTypes FeatureTypes DirectionTypes
--luacheck: globals NWCustomEligibility NWCustomPlacement

Lekmap_NaturalWonders = {}

------------------------------------------------------------------------------
-- PRIVATE STATE
------------------------------------------------------------------------------
local map_width, map_height = 0, 0

--- List of wonder feature type strings, indexed by wonder number.
local wonder_list = {}

--- Number of natural wonders defined in the game.
local num_nw = 0

--- XML row numbers for each wonder.
local xml_row_numbers = {}

--- Eligibility lists: candidate_lists[wonder_number] = { plot_index, ... }
local candidate_lists = {}

--- List of successfully placed wonder numbers.
local placed_wonders = {}

--- Atoll feature ID (for eligibility checks).
local feature_atoll = -1

--- Biggest landmass area ID.
local biggest_landmass_id = -1

--- Whether the world has significant oceans.
local world_has_oceans = false

--- Cached coastal data.
local plot_data_is_coastal = nil
local plot_data_is_next_to_coast = nil

------------------------------------------------------------------------------
-- NAMED CONSTANTS
------------------------------------------------------------------------------

--- NW count targets by world size.
local NW_TARGETS = {
    [GameInfo.Worlds.WORLDSIZE_DUEL.ID]     = 2,
    [GameInfo.Worlds.WORLDSIZE_TINY.ID]      = 3,
    [GameInfo.Worlds.WORLDSIZE_SMALL.ID]     = 4,
    [GameInfo.Worlds.WORLDSIZE_STANDARD.ID]  = 5,
    [GameInfo.Worlds.WORLDSIZE_LARGE.ID]     = 6,
    [GameInfo.Worlds.WORLDSIZE_HUGE.ID]      = 7,
}

--- Impact radii applied when a natural wonder is placed.
-- numeric literal: Lekmap_Constants not available at load time
local NW_IMPACT = {
    { layer = 5, radius = -1 },  -- IMPACT_LAYER.NATURAL_WONDER (-1 = computed as floor(map_height / 5))
    { layer = 1, radius = 1 },   -- IMPACT_LAYER.STRATEGIC
    { layer = 2, radius = 1 },   -- IMPACT_LAYER.LUXURY
    { layer = 3, radius = 1 },   -- IMPACT_LAYER.BONUS
    { layer = 4, radius = 2 },   -- IMPACT_LAYER.CITY_STATE
}

--- All six hex directions (from Lekmap_Constants).
-- Uses the shared DIRECTION_LIST to avoid duplication.

------------------------------------------------------------------------------
-- XML DATA STORAGE
-- One array per XML field, indexed by wonder number.
-- Loaded in LoadXMLData().
------------------------------------------------------------------------------
local xml_data = {}

--- Initialize all XML data arrays.
local function InitXMLDataArrays()
    local fields = {
        "EligibilityMethodNumber", "TileChangesMethodNumber", "OccurrenceFrequency",
        "RequireBiggestLandmass", "AvoidBiggestLandmass",
        "RequireFreshWater", "AvoidFreshWater", "LandBased",
        "RequireLandAdjacentToOcean", "AvoidLandAdjacentToOcean",
        "RequireLandOnePlotInland", "AvoidLandOnePlotInland",
        "RequireLandTwoOrMorePlotsInland", "AvoidLandTwoOrMorePlotsInland",
        "CoreTileCanBeAnyPlotType", "CoreTileCanBeFlatland", "CoreTileCanBeHills",
        "CoreTileCanBeMountain", "CoreTileCanBeOcean",
        "CoreTileCanBeAnyTerrainType", "CoreTileCanBeGrass", "CoreTileCanBePlains",
        "CoreTileCanBeDesert", "CoreTileCanBeTundra", "CoreTileCanBeSnow",
        "CoreTileCanBeShallowWater", "CoreTileCanBeDeepWater",
        "CoreTileCanBeAnyFeatureType", "CoreTileCanBeNoFeature", "CoreTileCanBeForest",
        "CoreTileCanBeJungle", "CoreTileCanBeOasis", "CoreTileCanBeFloodPlains",
        "CoreTileCanBeMarsh", "CoreTileCanBeIce", "CoreTileCanBeAtoll",
        "AdjacentTilesCareAboutPlotTypes",
        "AdjacentTilesRequireFlatland", "RequiredNumberOfAdjacentFlatland",
        "AdjacentTilesRequireHills", "RequiredNumberOfAdjacentHills",
        "AdjacentTilesRequireMountain", "RequiredNumberOfAdjacentMountain",
        "AdjacentTilesRequireHillsPlusMountains", "RequiredNumberOfAdjacentHillsPlusMountains",
        "AdjacentTilesRequireOcean", "RequiredNumberOfAdjacentOcean",
        "AdjacentTilesAvoidFlatland", "MaximumAllowedAdjacentFlatland",
        "AdjacentTilesAvoidHills", "MaximumAllowedAdjacentHills",
        "AdjacentTilesAvoidMountain", "MaximumAllowedAdjacentMountain",
        "AdjacentTilesAvoidOcean", "MaximumAllowedAdjacentOcean",
        "AdjacentTilesCareAboutTerrainTypes",
        "AdjacentTilesRequireGrass", "RequiredNumberOfAdjacentGrass",
        "AdjacentTilesRequirePlains", "RequiredNumberOfAdjacentPlains",
        "AdjacentTilesRequireDesert", "RequiredNumberOfAdjacentDesert",
        "AdjacentTilesRequireTundra", "RequiredNumberOfAdjacentTundra",
        "AdjacentTilesRequireSnow", "RequiredNumberOfAdjacentSnow",
        "AdjacentTilesRequireShallowWater", "RequiredNumberOfAdjacentShallowWater",
        "AdjacentTilesRequireDeepWater", "RequiredNumberOfAdjacentDeepWater",
        "AdjacentTilesAvoidGrass", "MaximumAllowedAdjacentGrass",
        "AdjacentTilesAvoidPlains", "MaximumAllowedAdjacentPlains",
        "AdjacentTilesAvoidDesert", "MaximumAllowedAdjacentDesert",
        "AdjacentTilesAvoidTundra", "MaximumAllowedAdjacentTundra",
        "AdjacentTilesAvoidSnow", "MaximumAllowedAdjacentSnow",
        "AdjacentTilesAvoidShallowWater", "MaximumAllowedAdjacentShallowWater",
        "AdjacentTilesAvoidDeepWater", "MaximumAllowedAdjacentDeepWater",
        "AdjacentTilesCareAboutFeatureTypes",
        "AdjacentTilesRequireNoFeature", "RequiredNumberOfAdjacentNoFeature",
        "AdjacentTilesRequireForest", "RequiredNumberOfAdjacentForest",
        "AdjacentTilesRequireJungle", "RequiredNumberOfAdjacentJungle",
        "AdjacentTilesRequireOasis", "RequiredNumberOfAdjacentOasis",
        "AdjacentTilesRequireFloodPlains", "RequiredNumberOfAdjacentFloodPlains",
        "AdjacentTilesRequireMarsh", "RequiredNumberOfAdjacentMarsh",
        "AdjacentTilesRequireIce", "RequiredNumberOfAdjacentIce",
        "AdjacentTilesRequireAtoll", "RequiredNumberOfAdjacentAtoll",
        "AdjacentTilesAvoidNoFeature", "MaximumAllowedAdjacentNoFeature",
        "AdjacentTilesAvoidForest", "MaximumAllowedAdjacentForest",
        "AdjacentTilesAvoidJungle", "MaximumAllowedAdjacentJungle",
        "AdjacentTilesAvoidOasis", "MaximumAllowedAdjacentOasis",
        "AdjacentTilesAvoidFloodPlains", "MaximumAllowedAdjacentFloodPlains",
        "AdjacentTilesAvoidMarsh", "MaximumAllowedAdjacentMarsh",
        "AdjacentTilesAvoidIce", "MaximumAllowedAdjacentIce",
        "AdjacentTilesAvoidAtoll", "MaximumAllowedAdjacentAtoll",
        "ChangeCoreTileToMountain", "ChangeCoreTileToFlatland",
        "ChangeCoreTileTerrainToGrass", "ChangeCoreTileTerrainToPlains",
        "SetAdjacentTilesToShallowWater",
    }
    for _, field in ipairs(fields) do
        xml_data[field] = {}
    end
end

--- Load all placement data from XML into local arrays.
local function LoadXMLData()
    InitXMLDataArrays()
    for wonder_num = 1, num_nw do
        local row_num = xml_row_numbers[wonder_num]
        if row_num then
            local row = GameInfo.Natural_Wonder_Placement[row_num]
            if row then
                for field, arr in pairs(xml_data) do
                    arr[wonder_num] = row[field]
                end
            end
        end
    end
end

------------------------------------------------------------------------------
-- ELIGIBILITY CHECKS
------------------------------------------------------------------------------

--- Basic eligibility: check if the NW impact layer is clear at this plot.
local function IsPlotEligible(x, y)
    local IMPACT_LAYER = Lekmap_Constants.IMPACT_LAYER
    local plot = Map.GetPlot(x, y)
    return plot ~= nil and not plot:IsNaturalWonder() and plot:GetResourceType(-1) == -1
        and not Lekmap_Resources.IsCollision(x, y)
        and not Lekmap_Impact.IsImpacted(IMPACT_LAYER.NATURAL_WONDER, x, y)
end

--- Extended eligibility: check the plot and all 6 adjacent plots.
local function IsCandidateEligible(x, y)
    local DIRECTION_LIST = Lekmap_Constants.DIRECTION_LIST
    if not IsPlotEligible(x, y) then return false end
    for _, dir in ipairs(DIRECTION_LIST) do
        local adjacent_plot = Map.PlotDirection(x, y, dir)
        if adjacent_plot == nil then return false end
        if not IsPlotEligible(adjacent_plot:GetX(), adjacent_plot:GetY()) then
            return false
        end
    end
    return true
end

------------------------------------------------------------------------------
--- Check if a plot can host a specific natural wonder type.
--  If eligible, adds the plot index to candidate_lists[wonder_num].
--
--  @param x, y          plot coordinates
--  @param wonder_num    wonder number (1-based)
------------------------------------------------------------------------------
local function CheckSpecificWonder(x, y, wonder_num)
    local DIRECTION_LIST = Lekmap_Constants.DIRECTION_LIST
    local plot = Map.GetPlot(x, y)
    if not plot then return end
    local plot_index = y * map_width + x + 1

    -- Custom eligibility method.
    if xml_data.EligibilityMethodNumber[wonder_num] and xml_data.EligibilityMethodNumber[wonder_num] ~= -1 then
        if NWCustomEligibility(x, y, xml_data.EligibilityMethodNumber[wonder_num]) == true then
            table.insert(candidate_lists[wonder_num], plot_index)
        end
        return
    end

    -- Landmass checks.
    if world_has_oceans then
        if xml_data.RequireBiggestLandmass[wonder_num] == true then
            if plot:GetArea() ~= biggest_landmass_id then return end
        elseif xml_data.AvoidBiggestLandmass[wonder_num] == true then
            if plot:GetArea() == biggest_landmass_id then return end
        end
    end

    -- Fresh water checks.
    if xml_data.RequireFreshWater[wonder_num] == true then
        if not plot:IsFreshWater() then return end
    elseif xml_data.AvoidFreshWater[wonder_num] == true then
        if plot:IsRiver() or plot:IsLake() or plot:IsFreshWater() then return end
    end

    -- Land / Sea.
    if xml_data.LandBased[wonder_num] == true then
        if plot:IsWater() then return end

        -- Coastal positioning.
        if xml_data.RequireLandAdjacentToOcean[wonder_num] == true then
            if plot_data_is_coastal[plot_index] ~= true then return end
        elseif xml_data.AvoidLandAdjacentToOcean[wonder_num] == true then
            if plot_data_is_coastal[plot_index] == true then return end
        end
        if xml_data.RequireLandOnePlotInland[wonder_num] == true then
            if plot_data_is_next_to_coast[plot_index] ~= true then return end
        elseif xml_data.AvoidLandOnePlotInland[wonder_num] == true then
            if plot_data_is_next_to_coast[plot_index] == true then return end
        end
        if xml_data.RequireLandTwoOrMorePlotsInland[wonder_num] == true then
            if plot_data_is_coastal[plot_index] == true or plot_data_is_next_to_coast[plot_index] == true then return end
        elseif xml_data.AvoidLandTwoOrMorePlotsInland[wonder_num] == true then
            if plot_data_is_coastal[plot_index] ~= true and plot_data_is_next_to_coast[plot_index] ~= true then return end
        end
    end

    -- Core tile: plot type.
    if xml_data.CoreTileCanBeAnyPlotType[wonder_num] ~= true then
        local plot_type = plot:GetPlotType()
        local ok = false
        if plot_type == PlotTypes.PLOT_LAND     and xml_data.CoreTileCanBeFlatland[wonder_num] == true then ok = true end
        if plot_type == PlotTypes.PLOT_HILLS    and xml_data.CoreTileCanBeHills[wonder_num]    == true then ok = true end
        if plot_type == PlotTypes.PLOT_MOUNTAIN and xml_data.CoreTileCanBeMountain[wonder_num] == true then ok = true end
        if plot_type == PlotTypes.PLOT_OCEAN    and xml_data.CoreTileCanBeOcean[wonder_num]    == true then ok = true end
        if not ok then return end
    end

    -- Core tile: terrain type.
    if xml_data.CoreTileCanBeAnyTerrainType[wonder_num] ~= true then
        local terrain_type = plot:GetTerrainType()
        local ok = false
        if terrain_type == TerrainTypes.TERRAIN_GRASS   and xml_data.CoreTileCanBeGrass[wonder_num]        == true then ok = true end
        if terrain_type == TerrainTypes.TERRAIN_PLAINS  and xml_data.CoreTileCanBePlains[wonder_num]       == true then ok = true end
        if terrain_type == TerrainTypes.TERRAIN_DESERT  and xml_data.CoreTileCanBeDesert[wonder_num]       == true then ok = true end
        if terrain_type == TerrainTypes.TERRAIN_TUNDRA  and xml_data.CoreTileCanBeTundra[wonder_num]       == true then ok = true end
        if terrain_type == TerrainTypes.TERRAIN_SNOW    and xml_data.CoreTileCanBeSnow[wonder_num]         == true then ok = true end
        if terrain_type == TerrainTypes.TERRAIN_COAST   and xml_data.CoreTileCanBeShallowWater[wonder_num] == true then ok = true end
        if terrain_type == TerrainTypes.TERRAIN_OCEAN   and xml_data.CoreTileCanBeDeepWater[wonder_num]    == true then ok = true end
        if not ok then return end
    end

    -- Core tile: feature type.
    if xml_data.CoreTileCanBeAnyFeatureType[wonder_num] ~= true then
        local feature_type = plot:GetFeatureType()
        local ok = false
        if feature_type == FeatureTypes.NO_FEATURE          and xml_data.CoreTileCanBeNoFeature[wonder_num]    == true then ok = true end
        if feature_type == FeatureTypes.FEATURE_FOREST      and xml_data.CoreTileCanBeForest[wonder_num]       == true then ok = true end
        if feature_type == FeatureTypes.FEATURE_JUNGLE      and xml_data.CoreTileCanBeJungle[wonder_num]       == true then ok = true end
        if feature_type == FeatureTypes.FEATURE_OASIS       and xml_data.CoreTileCanBeOasis[wonder_num]        == true then ok = true end
        if feature_type == FeatureTypes.FEATURE_FLOOD_PLAINS and xml_data.CoreTileCanBeFloodPlains[wonder_num] == true then ok = true end
        if feature_type == FeatureTypes.FEATURE_MARSH       and xml_data.CoreTileCanBeMarsh[wonder_num]        == true then ok = true end
        if feature_type == FeatureTypes.FEATURE_ICE         and xml_data.CoreTileCanBeIce[wonder_num]          == true then ok = true end
        if feature_type == feature_atoll                     and xml_data.CoreTileCanBeAtoll[wonder_num]        == true then ok = true end
        if not ok then return end
    end

    -- Adjacent tiles: plot types.
    if xml_data.AdjacentTilesCareAboutPlotTypes[wonder_num] == true then
        local num_land, num_flat, num_hills, num_mountain, num_hills_mtn, num_ocean = 0, 0, 0, 0, 0, 0
        for _, dir in ipairs(DIRECTION_LIST) do
            local adjacent_plot = Map.PlotDirection(x, y, dir)
            local plot_type = adjacent_plot:GetPlotType()
            if plot_type == PlotTypes.PLOT_OCEAN then
                num_ocean = num_ocean + 1
            else
                num_land = num_land + 1
                if plot_type == PlotTypes.PLOT_LAND then num_flat = num_flat + 1
                else num_hills_mtn = num_hills_mtn + 1
                    if plot_type == PlotTypes.PLOT_HILLS then num_hills = num_hills + 1
                    else num_mountain = num_mountain + 1 end
                end
            end
        end
        if xml_data.AdjacentTilesRequireFlatland[wonder_num]           and num_flat      < xml_data.RequiredNumberOfAdjacentFlatland[wonder_num]           then return end
        if xml_data.AdjacentTilesRequireHills[wonder_num]              and num_hills     < xml_data.RequiredNumberOfAdjacentHills[wonder_num]              then return end
        if xml_data.AdjacentTilesRequireMountain[wonder_num]           and num_mountain  < xml_data.RequiredNumberOfAdjacentMountain[wonder_num]           then return end
        if xml_data.AdjacentTilesRequireHillsPlusMountains[wonder_num] and num_hills_mtn < xml_data.RequiredNumberOfAdjacentHillsPlusMountains[wonder_num] then return end
        if xml_data.AdjacentTilesRequireOcean[wonder_num]              and num_ocean     < xml_data.RequiredNumberOfAdjacentOcean[wonder_num]              then return end
        if xml_data.AdjacentTilesAvoidFlatland[wonder_num]  and num_flat     > xml_data.MaximumAllowedAdjacentFlatland[wonder_num]  then return end
        if xml_data.AdjacentTilesAvoidHills[wonder_num]     and num_hills    > xml_data.MaximumAllowedAdjacentHills[wonder_num]     then return end
        if xml_data.AdjacentTilesAvoidMountain[wonder_num]  and num_mountain > xml_data.MaximumAllowedAdjacentMountain[wonder_num]  then return end
        if xml_data.AdjacentTilesAvoidOcean[wonder_num]     and num_ocean    > xml_data.MaximumAllowedAdjacentOcean[wonder_num]     then return end
    end

    -- Adjacent tiles: terrain types.
    if xml_data.AdjacentTilesCareAboutTerrainTypes[wonder_num] == true then
        local num_grass, num_plains, num_desert, num_tundra, num_snow, num_coast, num_deep = 0, 0, 0, 0, 0, 0, 0
        for _, dir in ipairs(DIRECTION_LIST) do
            local adjacent_plot = Map.PlotDirection(x, y, dir)
            local terrain_type = adjacent_plot:GetTerrainType()
            if     terrain_type == TerrainTypes.TERRAIN_GRASS   then num_grass  = num_grass + 1
            elseif terrain_type == TerrainTypes.TERRAIN_PLAINS  then num_plains = num_plains + 1
            elseif terrain_type == TerrainTypes.TERRAIN_DESERT  then num_desert = num_desert + 1
            elseif terrain_type == TerrainTypes.TERRAIN_TUNDRA  then num_tundra = num_tundra + 1
            elseif terrain_type == TerrainTypes.TERRAIN_SNOW    then num_snow   = num_snow + 1
            elseif terrain_type == TerrainTypes.TERRAIN_COAST   then num_coast  = num_coast + 1
            elseif terrain_type == TerrainTypes.TERRAIN_OCEAN   then num_deep   = num_deep + 1 end
        end
        if xml_data.AdjacentTilesRequireGrass[wonder_num]        and num_grass  < xml_data.RequiredNumberOfAdjacentGrass[wonder_num]        then return end
        if xml_data.AdjacentTilesRequirePlains[wonder_num]       and num_plains < xml_data.RequiredNumberOfAdjacentPlains[wonder_num]       then return end
        if xml_data.AdjacentTilesRequireDesert[wonder_num]       and num_desert < xml_data.RequiredNumberOfAdjacentDesert[wonder_num]       then return end
        if xml_data.AdjacentTilesRequireTundra[wonder_num]       and num_tundra < xml_data.RequiredNumberOfAdjacentTundra[wonder_num]       then return end
        if xml_data.AdjacentTilesRequireSnow[wonder_num]         and num_snow   < xml_data.RequiredNumberOfAdjacentSnow[wonder_num]         then return end
        if xml_data.AdjacentTilesRequireShallowWater[wonder_num] and num_coast  < xml_data.RequiredNumberOfAdjacentShallowWater[wonder_num] then return end
        if xml_data.AdjacentTilesRequireDeepWater[wonder_num]    and num_deep   < xml_data.RequiredNumberOfAdjacentDeepWater[wonder_num]    then return end
        if xml_data.AdjacentTilesAvoidGrass[wonder_num]          and num_grass  > xml_data.MaximumAllowedAdjacentGrass[wonder_num]          then return end
        if xml_data.AdjacentTilesAvoidPlains[wonder_num]         and num_plains > xml_data.MaximumAllowedAdjacentPlains[wonder_num]         then return end
        if xml_data.AdjacentTilesAvoidDesert[wonder_num]         and num_desert > xml_data.MaximumAllowedAdjacentDesert[wonder_num]         then return end
        if xml_data.AdjacentTilesAvoidTundra[wonder_num]         and num_tundra > xml_data.MaximumAllowedAdjacentTundra[wonder_num]         then return end
        if xml_data.AdjacentTilesAvoidSnow[wonder_num]           and num_snow   > xml_data.MaximumAllowedAdjacentSnow[wonder_num]           then return end
        if xml_data.AdjacentTilesAvoidShallowWater[wonder_num]   and num_coast  > xml_data.MaximumAllowedAdjacentShallowWater[wonder_num]   then return end
        if xml_data.AdjacentTilesAvoidDeepWater[wonder_num]      and num_deep   > xml_data.MaximumAllowedAdjacentDeepWater[wonder_num]      then return end
    end

    -- Adjacent tiles: feature types.
    if xml_data.AdjacentTilesCareAboutFeatureTypes[wonder_num] == true then
        local num_none, num_forest, num_jungle, num_oasis, num_flood, num_marsh, num_ice, num_atoll = 0, 0, 0, 0, 0, 0, 0, 0
        for _, dir in ipairs(DIRECTION_LIST) do
            local adjacent_plot = Map.PlotDirection(x, y, dir)
            local feature_type = adjacent_plot:GetFeatureType()
            if     feature_type == FeatureTypes.NO_FEATURE           then num_none   = num_none + 1
            elseif feature_type == FeatureTypes.FEATURE_FOREST       then num_forest = num_forest + 1
            elseif feature_type == FeatureTypes.FEATURE_JUNGLE       then num_jungle = num_jungle + 1
            elseif feature_type == FeatureTypes.FEATURE_OASIS        then num_oasis  = num_oasis + 1
            elseif feature_type == FeatureTypes.FEATURE_FLOOD_PLAINS then num_flood  = num_flood + 1
            elseif feature_type == FeatureTypes.FEATURE_MARSH        then num_marsh  = num_marsh + 1
            elseif feature_type == FeatureTypes.FEATURE_ICE          then num_ice    = num_ice + 1
            elseif feature_type == feature_atoll                     then num_atoll  = num_atoll + 1 end
        end
        if xml_data.AdjacentTilesRequireNoFeature[wonder_num]    and num_none   < xml_data.RequiredNumberOfAdjacentNoFeature[wonder_num]    then return end
        if xml_data.AdjacentTilesRequireForest[wonder_num]       and num_forest < xml_data.RequiredNumberOfAdjacentForest[wonder_num]       then return end
        if xml_data.AdjacentTilesRequireJungle[wonder_num]       and num_jungle < xml_data.RequiredNumberOfAdjacentJungle[wonder_num]       then return end
        if xml_data.AdjacentTilesRequireOasis[wonder_num]        and num_oasis  < xml_data.RequiredNumberOfAdjacentOasis[wonder_num]        then return end
        if xml_data.AdjacentTilesRequireFloodPlains[wonder_num]  and num_flood  < xml_data.RequiredNumberOfAdjacentFloodPlains[wonder_num]  then return end
        if xml_data.AdjacentTilesRequireMarsh[wonder_num]        and num_marsh  < xml_data.RequiredNumberOfAdjacentMarsh[wonder_num]        then return end
        if xml_data.AdjacentTilesRequireIce[wonder_num]          and num_ice    < xml_data.RequiredNumberOfAdjacentIce[wonder_num]          then return end
        if xml_data.AdjacentTilesRequireAtoll[wonder_num]        and num_atoll  < xml_data.RequiredNumberOfAdjacentAtoll[wonder_num]        then return end
        if xml_data.AdjacentTilesAvoidNoFeature[wonder_num]      and num_none   > xml_data.MaximumAllowedAdjacentNoFeature[wonder_num]      then return end
        if xml_data.AdjacentTilesAvoidForest[wonder_num]         and num_forest > xml_data.MaximumAllowedAdjacentForest[wonder_num]         then return end
        if xml_data.AdjacentTilesAvoidJungle[wonder_num]         and num_jungle > xml_data.MaximumAllowedAdjacentJungle[wonder_num]         then return end
        if xml_data.AdjacentTilesAvoidOasis[wonder_num]          and num_oasis  > xml_data.MaximumAllowedAdjacentOasis[wonder_num]          then return end
        if xml_data.AdjacentTilesAvoidFloodPlains[wonder_num]    and num_flood  > xml_data.MaximumAllowedAdjacentFloodPlains[wonder_num]    then return end
        if xml_data.AdjacentTilesAvoidMarsh[wonder_num]          and num_marsh  > xml_data.MaximumAllowedAdjacentMarsh[wonder_num]          then return end
        if xml_data.AdjacentTilesAvoidIce[wonder_num]            and num_ice    > xml_data.MaximumAllowedAdjacentIce[wonder_num]            then return end
        if xml_data.AdjacentTilesAvoidAtoll[wonder_num]          and num_atoll  > xml_data.MaximumAllowedAdjacentAtoll[wonder_num]          then return end
    end

    -- Passed all checks.
    table.insert(candidate_lists[wonder_num], plot_index)
end

------------------------------------------------------------------------------
-- CANDIDATE GENERATION
------------------------------------------------------------------------------

------------------------------------------------------------------------------
--- Scan the entire map and build candidate lists for all NW types.
--  Returns a priority-ordered list of wonder numbers (fewest candidates first,
--  then weighted by OccurrenceFrequency).
------------------------------------------------------------------------------
function Lekmap_NaturalWonders.GenerateCandidates()
    map_width, map_height = Map.GetGridSize()

    -- Discover atoll feature ID.
    feature_atoll = -1
    for row in GameInfo.Features() do
        if row.Type == "FEATURE_ATOLL" then
            feature_atoll = row.ID
            break
        end
    end

    -- Determine biggest landmass and ocean status.
    local biggest_landmass = Map.FindBiggestArea(false)
    biggest_landmass_id = biggest_landmass and biggest_landmass:GetID() or -1

    local biggest_ocean = Map.FindBiggestArea(true)
    local ocean_plots = biggest_ocean and biggest_ocean:GetNumTiles() or 0
    world_has_oceans = (ocean_plots > (map_width * map_height) / 4)

    -- Join active feature types to placement rows. DLC/mod tables can contain
    -- disabled types or sparse IDs; row count is not the active wonder count.
    num_nw, wonder_list, xml_row_numbers = 0, {}, {}
    local placement_by_type = {}
    for row in GameInfo.Natural_Wonder_Placement() do placement_by_type[row.NaturalWonderType] = row end
    for feature in GameInfo.Features() do
        local row = placement_by_type[feature.Type]
        if feature.NaturalWonder and row and (row.OccurrenceFrequency or 1) > 0 then
            num_nw = num_nw + 1
            wonder_list[num_nw], xml_row_numbers[num_nw] = feature.Type, row.ID
        end
    end
    if num_nw == 0 then
        print("Lekmap_NaturalWonders: No active natural wonders with placement rules.")
        return {}
    end

    -- Load XML data.
    LoadXMLData()

    -- Initialize candidate lists.
    candidate_lists = {}
    for i = 1, num_nw do
        candidate_lists[i] = {}
    end

    -- Generate coastal data for land-based NW checks.
    plot_data_is_coastal, plot_data_is_next_to_coast = Lekmap_Utilities.GenerateNextToCoastalLandDataTables()

    -- Scan every plot.
    for y = 0, map_height - 1 do
        for x = 0, map_width - 1 do
            if IsCandidateEligible(x, y) then
                for wonder_num = 1, num_nw do
                    CheckSpecificWonder(x, y, wonder_num)
                end
            end
        end
    end

    -- Count candidates and build priority order (fewest first).
    local candidate_counts = {}
    for wonder_num = 1, num_nw do
        candidate_counts[wonder_num] = #candidate_lists[wonder_num]
        print(string.format("Lekmap_NaturalWonders: %s has %d candidate plots.", wonder_list[wonder_num] or "?", candidate_counts[wonder_num]))
    end

    -- Sort by candidate count ascending.
    local eligible_wonders = {}
    for wonder_num = 1, num_nw do
        if candidate_counts[wonder_num] > 0 then
            table.insert(eligible_wonders, { wonder_num = wonder_num, count = candidate_counts[wonder_num] })
        end
    end
    table.sort(eligible_wonders, function(a, b)
        if a.count == b.count then return a.wonder_num < b.wonder_num end
        return a.count < b.count
    end)

    -- Weighted draws without replacement. Removing selected wonders makes
    -- the work bounded and prevents starvation of rare remaining types.
    local remaining, final_order = {}, {}
    for _, entry in ipairs(eligible_wonders) do table.insert(remaining, entry.wonder_num) end
    while #remaining > 0 do
        local total = 0
        for _, number in ipairs(remaining) do total = total + (xml_data.OccurrenceFrequency[number] or 1) end
        local roll = Map.Rand(total, "NW selection")
        local accumulated = 0
        for index, number in ipairs(remaining) do
            accumulated = accumulated + (xml_data.OccurrenceFrequency[number] or 1)
            if roll < accumulated then
                table.insert(final_order, number)
                table.remove(remaining, index)
                break
            end
        end
    end

    return final_order
end

------------------------------------------------------------------------------
-- PLACEMENT
------------------------------------------------------------------------------

------------------------------------------------------------------------------
--- Apply terrain changes and place a natural wonder at (x, y).
------------------------------------------------------------------------------
local function ApplyTileChangesAndPlace(x, y, wonder_num, row_num)
    local DIRECTION_LIST = Lekmap_Constants.DIRECTION_LIST
    local plot = Map.GetPlot(x, y)

    -- Custom tile changes.
    local tile_method = xml_data.TileChangesMethodNumber[wonder_num]
    if tile_method and tile_method ~= -1 then
        NWCustomPlacement(x, y, row_num, tile_method)
    else
        -- Standard tile changes from XML flags.
        if xml_data.ChangeCoreTileToMountain[wonder_num] == true then
            if not plot:IsMountain() then
                plot:SetPlotType(PlotTypes.PLOT_MOUNTAIN, false, false)
            end
        elseif xml_data.ChangeCoreTileToFlatland[wonder_num] == true then
            if plot:GetPlotType() ~= PlotTypes.PLOT_LAND then
                plot:SetPlotType(PlotTypes.PLOT_LAND, false, false)
            end
        end
        if xml_data.ChangeCoreTileTerrainToGrass[wonder_num] == true then
            if plot:GetTerrainType() ~= TerrainTypes.TERRAIN_GRASS then
                plot:SetTerrainType(TerrainTypes.TERRAIN_GRASS, false, false)
            end
        elseif xml_data.ChangeCoreTileTerrainToPlains[wonder_num] == true then
            if plot:GetTerrainType() ~= TerrainTypes.TERRAIN_PLAINS then
                plot:SetTerrainType(TerrainTypes.TERRAIN_PLAINS, false, false)
            end
        end
        if xml_data.SetAdjacentTilesToShallowWater[wonder_num] == true then
            for _, dir in ipairs(DIRECTION_LIST) do
                local adjacent_plot = Map.PlotDirection(x, y, dir)
                if adjacent_plot and adjacent_plot:GetTerrainType() ~= TerrainTypes.TERRAIN_COAST then
                    adjacent_plot:SetTerrainType(TerrainTypes.TERRAIN_COAST, false, false)
                end
            end
        end
    end

    -- Get feature ID and place.
    local feature_id
    for row in GameInfo.Features() do
        if row.Type == wonder_list[wonder_num] then
            feature_id = row.ID
            break
        end
    end
    if feature_id then
        plot:SetFeatureType(feature_id)
    end
end

--- Apply impact layers after placing a natural wonder.
local function ApplyNWImpact(x, y, wonder_num)
    local IMPACT_LAYER = Lekmap_Constants.IMPACT_LAYER
    local nw_radius = math.floor(map_height / 5)

    for _, entry in ipairs(NW_IMPACT) do
        local radius = entry.radius
        if radius == -1 then radius = nw_radius end
        Lekmap_Impact.PlaceImpact(entry.layer, x, y, radius)
    end

    -- Mark collision.
    Lekmap_Resources.MarkCollision(x, y)

    -- Great Barrier Reef special: also impact its SE tile.
    if wonder_list[wonder_num] == "FEATURE_REEF" then
        local se_plot = Map.PlotDirection(x, y, DirectionTypes.DIRECTION_SOUTHEAST)
        if se_plot then
            local se_x, se_y = se_plot:GetX(), se_plot:GetY()
            Lekmap_Impact.PlaceImpact(IMPACT_LAYER.STRATEGIC, se_x, se_y, 1)
            Lekmap_Impact.PlaceImpact(IMPACT_LAYER.LUXURY,    se_x, se_y, 1)
            Lekmap_Impact.PlaceImpact(IMPACT_LAYER.BONUS,     se_x, se_y, 1)
            Lekmap_Resources.MarkCollision(se_x, se_y)
        end
    end
end

------------------------------------------------------------------------------
--- Attempt to place a specific natural wonder from its candidate list.
--
--  @param wonder_num   wonder number
--  @return true if placed
------------------------------------------------------------------------------
function Lekmap_NaturalWonders.AttemptToPlace(wonder_num)
    local IMPACT_LAYER = Lekmap_Constants.IMPACT_LAYER
    local candidates = candidate_lists[wonder_num]
    if not candidates or #candidates == 0 then return false end

    -- Shuffle candidates.
    local shuffled = {}
    for _, plot_index in ipairs(candidates) do table.insert(shuffled, plot_index) end
    for i = #shuffled, 2, -1 do
        local j = Map.Rand(i, "Shuffle NW candidates") + 1
        shuffled[i], shuffled[j] = shuffled[j], shuffled[i]
    end

    for _, plot_index in ipairs(shuffled) do
        local plot_x = (plot_index - 1) % map_width
        local plot_y = (plot_index - plot_x - 1) / map_width

        -- Check NW layer is still clear (another NW may have been placed since candidacy).
        if IsCandidateEligible(plot_x, plot_y) then
            local row_num = xml_row_numbers[wonder_num]
            ApplyTileChangesAndPlace(plot_x, plot_y, wonder_num, row_num)
            table.insert(placed_wonders, wonder_num)
            ApplyNWImpact(plot_x, plot_y, wonder_num)
            print("Lekmap_NaturalWonders: Placed " .. (wonder_list[wonder_num] or "NW#" .. wonder_num) .. " at (" .. plot_x .. ", " .. plot_y .. ")")
            return true
        end
    end

    return false
end

------------------------------------------------------------------------------
-- ORCHESTRATOR
------------------------------------------------------------------------------

------------------------------------------------------------------------------
--- Main entry point for natural wonder placement.
--
--  @param args  table:
--      wonder_amount   (number) override NW count (nil = use map size default)
------------------------------------------------------------------------------
function Lekmap_NaturalWonders.PlaceAll(args)
    args = args or {}
    map_width, map_height = Map.GetGridSize()
    placed_wonders = {}

    print("Lekmap_NaturalWonders: Beginning natural wonder placement.")

    -- Generate candidates.
    local priority_order = Lekmap_NaturalWonders.GenerateCandidates()
    if #priority_order == 0 then
        print("Lekmap_NaturalWonders: No eligible sites found for any natural wonder.")
        return
    end

    -- Determine target count.
    local target = NW_TARGETS[Map.GetWorldSize()] or 5
    if args.wonder_amount ~= nil then
        target = args.wonder_amount
    end
    local num_to_place = math.min(target, #priority_order)

    -- Split into selected and fallback.
    local selected, fallback = {}, {}
    for i, wonder_num in ipairs(priority_order) do
        if i <= num_to_place then
            table.insert(selected, wonder_num)
        else
            table.insert(fallback, wonder_num)
        end
    end

    -- Place selected NWs.
    local num_placed = 0
    for _, wonder_num in ipairs(selected) do
        if Lekmap_NaturalWonders.AttemptToPlace(wonder_num) then
            num_placed = num_placed + 1
        end
    end

    -- Fallback: if not enough placed, try the rest.
    if num_placed < num_to_place then
        for _, wonder_num in ipairs(fallback) do
            if num_placed >= num_to_place then break end
            if Lekmap_NaturalWonders.AttemptToPlace(wonder_num) then
                num_placed = num_placed + 1
            end
        end
    end

    -- Summary.
    if num_placed >= num_to_place then
        print("Lekmap_NaturalWonders: All " .. num_placed .. " natural wonders placed.")
    else
        print("Lekmap_NaturalWonders: " .. num_placed .. "/" .. num_to_place .. " natural wonders placed.")
    end
end

------------------------------------------------------------------------------
-- ACCESSORS
------------------------------------------------------------------------------

function Lekmap_NaturalWonders.GetPlacedWonders()
    return placed_wonders
end

function Lekmap_NaturalWonders.GetNumPlaced()
    return #placed_wonders
end

function Lekmap_NaturalWonders.GetWonderList()
    return wonder_list
end
