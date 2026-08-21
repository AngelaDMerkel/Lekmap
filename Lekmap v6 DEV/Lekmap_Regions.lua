------------------------------------------------------------------------------
--  FILE:     Lekmap_Regions.lua
--  AUTHOR:   EnormousApplePie
--  PURPOSE:  Regional division, terrain measurement, and type classification.
--            Replaces the region-related functions from HBAssignStartingPlots.
--            Currently supports Method 1 (Biggest Landmass) for Pangaea.
------------------------------------------------------------------------------
--  Requires: Lekmap_Constants.lua  (REGION_TYPE)
--            Lekmap_Utilities.lua  (ObtainLandmassBoundaries, TestMembership,
--                                   GetPlayerAndTeamInfo)
------------------------------------------------------------------------------
--luacheck: globals Lekmap_Regions Lekmap_Utilities
--luacheck: globals Map PlotTypes TerrainTypes FeatureTypes Lekmap_Constants
--luacheck: ignore table

Lekmap_Regions = {}

------------------------------------------------------------------------------
-- PLOT FERTILITY WEIGHTS
-- Named constants that replace the bare magic numbers in the original
-- MeasureStartPlacementFertilityOfPlot. These control how desirable each
-- tile trait is for starting location division.
------------------------------------------------------------------------------
local FERTILITY = {
    MOUNTAIN       = -1,
    SNOW           = -2,
    ICE            = -1,
    OCEAN          =  2,
    OASIS          =  4,
    FLOOD_PLAINS   =  4,
    GRASS          =  3,
    PLAINS         =  4,
    TUNDRA         =  1,
    DESERT         = -1,
    HILLS_BONUS    =  1,
    FOREST_BONUS   =  0,
    JUNGLE_PENALTY = -1,
    MARSH_PENALTY  = -2,
    RIVER_BONUS    =  1,
    COASTAL_BONUS  =  2,
}

------------------------------------------------------------------------------
-- DIVISION TABLE
-- Maps number of required divisions (2-22) to { numDivides, subdivisions }
-- or for prime numbers > 3 to { chopPercent, firstSub, laterSub }.
-- Replaces the massive if/elseif chain in DivideIntoRegions.
------------------------------------------------------------------------------
local PRIME_DIVISIONS = {
    [5]  = { chopPercent = 59.2,  firstSub = 3,  laterSub = 2  },
    [7]  = { chopPercent = 42.2,  firstSub = 3,  laterSub = 4  },
    [11] = { chopPercent = 27,    firstSub = 3,  laterSub = 8  },
    [13] = { chopPercent = 38.1,  firstSub = 5,  laterSub = 8  },
    [17] = { chopPercent = 52.8,  firstSub = 9,  laterSub = 8  },
    [19] = { chopPercent = 36.7,  firstSub = 7,  laterSub = 12 },
}

local COMPOSITE_DIVISIONS = {
    [2]  = { divides = 2, subs = 1  },
    [3]  = { divides = 3, subs = 1  },
    [4]  = { divides = 2, subs = 2  },
    [6]  = { divides = 3, subs = 2  },
    [8]  = { divides = 2, subs = 4  },
    [9]  = { divides = 3, subs = 3  },
    [10] = { divides = 2, subs = 5  },
    [12] = { divides = 3, subs = 4  },
    [14] = { divides = 2, subs = 7  },
    [15] = { divides = 3, subs = 5  },
    [16] = { divides = 2, subs = 8  },
    [18] = { divides = 3, subs = 6  },
    [20] = { divides = 2, subs = 10 },
    [21] = { divides = 3, subs = 7  },
    [22] = { divides = 2, subs = 11 },
}

------------------------------------------------------------------------------
-- REGION TYPE CLASSIFICATION THRESHOLDS
-- Percentage of areaPlots required for a terrain type to dominate.
-- The active classification path (lines 2809-2874 of the original).
------------------------------------------------------------------------------
local CLASSIFY_TUNDRA_SNOW_PCT    = 0.10
local CLASSIFY_JUNGLE_PCT         = 0.12
local CLASSIFY_JUNGLE_COMBO_PCT   = 0.10
local CLASSIFY_JUNGLE_FOREST_PCT  = 0.24
local CLASSIFY_FOREST_PCT         = 0.21
local CLASSIFY_FOREST_HIGH_PCT    = 0.80
local CLASSIFY_FOREST_COMBO_PCT   = 0.30
local CLASSIFY_DESERT_PCT         = 0.15
local CLASSIFY_WETLANDS_PCT       = 0.11
local CLASSIFY_WETLANDS_MIN_COUNT = 6
local CLASSIFY_HILLS_PCT          = 0.37
local CLASSIFY_GRASS_PCT          = 0.20
local CLASSIFY_GRASS_RATIO        = 0.70
local CLASSIFY_PLAINS_PCT         = 0.27
local CLASSIFY_PLAINS_RATIO       = 0.80
local CLASSIFY_HYBRID_PCT         = 0.80

------------------------------------------------------------------------------
-- MODULE STATE
-- Populated by Generate(), consumed by downstream systems.
------------------------------------------------------------------------------
Lekmap_Regions.regions       = {}
Lekmap_Regions.terrainCounts = {}
Lekmap_Regions.regionTypes   = {}

------------------------------------------------------------------------------
-- REGION RECORD CONSTRUCTOR
-- Returns a named-field table instead of a positional array.
------------------------------------------------------------------------------
local function CreateRegionRecord(west_x, south_y, width, height, area_id, fertility, plot_count)
    local avg_fertility = 0
    if plot_count > 0 then
        avg_fertility = fertility / plot_count
    end
    return {
        westX        = west_x,
        southY       = south_y,
        width        = width,
        height       = height,
        areaID       = area_id,
        fertility    = fertility,
        plotCount    = plot_count,
        avgFertility = avg_fertility,
    }
end

------------------------------------------------------------------------------
-- TERRAIN COUNTS CONSTRUCTOR
-- Returns a named-field table instead of a 23-element positional array.
------------------------------------------------------------------------------
local function CreateTerrainCounts()
    return {
        totalPlots  = 0,   areaPlots   = 0,
        water       = 0,   flatlands   = 0,   hills  = 0,   peaks   = 0,
        lake        = 0,   coast       = 0,   ocean  = 0,   ice     = 0,
        grass       = 0,   plains      = 0,   desert = 0,   tundra  = 0,   snow = 0,
        forest      = 0,   jungle      = 0,   marsh  = 0,
        river       = 0,   floodplain  = 0,   oasis  = 0,
        coastalLand = 0,   nextToCoast = 0, inlandSeaCoast = 0,
    }
end

------------------------------------------------------------------------------
-- PLOT FERTILITY SCORING
-- Measures how desirable a single plot is for starting location placement.
-- Replaces MeasureStartPlacementFertilityOfPlot (lines 1511-1585 original).
------------------------------------------------------------------------------
function Lekmap_Regions.MeasurePlotFertility(x, y, check_coastal)
    local plot         = Map.GetPlot(x, y)
    local plot_type    = plot:GetPlotType()
    local terrain_type = plot:GetTerrainType()
    local feature_type = plot:GetFeatureType()

    if plot_type == PlotTypes.PLOT_MOUNTAIN then
        return FERTILITY.MOUNTAIN
    end
    if terrain_type == TerrainTypes.TERRAIN_SNOW then
        return FERTILITY.SNOW
    end
    if feature_type == FeatureTypes.FEATURE_ICE then
        return FERTILITY.ICE
    end
    if plot_type == PlotTypes.PLOT_OCEAN then
        return FERTILITY.OCEAN
    end
    if feature_type == FeatureTypes.FEATURE_OASIS then
        return FERTILITY.OASIS
    end
    if feature_type == FeatureTypes.FEATURE_FLOOD_PLAINS then
        return FERTILITY.FLOOD_PLAINS
    end

    local value = 0

    if terrain_type == TerrainTypes.TERRAIN_GRASS then
        value = FERTILITY.GRASS
    elseif terrain_type == TerrainTypes.TERRAIN_PLAINS then
        value = FERTILITY.PLAINS
    elseif terrain_type == TerrainTypes.TERRAIN_TUNDRA then
        value = FERTILITY.TUNDRA
    elseif terrain_type == TerrainTypes.TERRAIN_DESERT then
        value = FERTILITY.DESERT
    end

    if plot_type == PlotTypes.PLOT_HILLS then
        value = value + FERTILITY.HILLS_BONUS + FERTILITY.HILLS_BONUS
    end

    if feature_type == FeatureTypes.FEATURE_FOREST then
        value = value + FERTILITY.FOREST_BONUS
    elseif feature_type == FeatureTypes.FEATURE_JUNGLE then
        value = value + FERTILITY.JUNGLE_PENALTY
    elseif feature_type == FeatureTypes.FEATURE_MARSH then
        value = value + FERTILITY.MARSH_PENALTY
    end

    if plot:IsRiverSide() or plot:IsFreshWater() then
        value = value + FERTILITY.RIVER_BONUS
    end

    if check_coastal and plot:IsCoastalLand() then
        value = value + FERTILITY.COASTAL_BONUS
    end

    return value
end

------------------------------------------------------------------------------
-- RECTANGLE FERTILITY MEASUREMENT
-- Measures fertility for all plots inside a rectangle.
-- Returns: fertility_table, fertility_sum, plot_count
------------------------------------------------------------------------------
function Lekmap_Regions.MeasureRectangleFertility(west_x, south_y, width, height)
    local fertility_table = {}
    local fertility_sum   = 0
    local plot_count      = width * height

    for y = south_y, south_y + height - 1 do
        for x = west_x, west_x + width - 1 do
            local value = Lekmap_Regions.MeasurePlotFertility(x, y, false)
            table.insert(fertility_table, value)
            fertility_sum = fertility_sum + value
        end
    end

    return fertility_table, fertility_sum, plot_count
end

------------------------------------------------------------------------------
-- LANDMASS FERTILITY MEASUREMENT
-- Measures fertility for all plots within the bounding box of a landmass,
-- setting non-member plots to zero. Handles world wrap.
-- Returns: fertility_table, fertility_sum, plot_count
------------------------------------------------------------------------------
function Lekmap_Regions.MeasureLandmassFertility(area_id, west_x, east_x, south_y, north_y, wraps_x, wraps_y)
    local map_width, map_height = Map.GetGridSize()

    local x_end = wraps_x and (east_x + map_width) or east_x
    local y_end = wraps_y and (north_y + map_height) or north_y

    local fertility_table = {}
    local fertility_sum   = 0
    local plot_count      = 0

    for y_loop = south_y, y_end do
        for x_loop = west_x, x_end do
            plot_count = plot_count + 1
            local x = x_loop % map_width
            local y = y_loop % map_height
            local plot = Map.GetPlot(x, y)

            if plot:GetArea() ~= area_id then
                table.insert(fertility_table, 0)
            else
                local value = Lekmap_Regions.MeasurePlotFertility(x, y, true)
                table.insert(fertility_table, value)
                fertility_sum = fertility_sum + value
            end
        end
    end

    return fertility_table, fertility_sum, plot_count
end

------------------------------------------------------------------------------
-- REMOVE DEAD ROWS
-- Trims zero-only rows and columns from the edges of a fertility table
-- after a region has been divided. Improves subdivision accuracy.
-- Returns: adjusted_table, west_x, south_y, width, height
------------------------------------------------------------------------------
function Lekmap_Regions.RemoveDeadRows(fertility_table, west_x, south_y, width, height)
    local map_width, map_height = Map.GetGridSize()

    local function IsRowAllZero(row)
        for x = 0, width - 1 do
            local i = row * width + x + 1
            if fertility_table[i] ~= 0 then return false end
        end
        return true
    end

    local function IsColAllZero(col)
        for y = 0, height - 1 do
            local i = y * width + col + 1
            if fertility_table[i] ~= 0 then return false end
        end
        return true
    end

    local adjust_south = 0
    for y = 0, height - 1 do
        if not IsRowAllZero(y) then break end
        adjust_south = adjust_south + 1
    end

    local adjust_north = 0
    for y = height - 1, 0, -1 do
        if not IsRowAllZero(y) then break end
        adjust_north = adjust_north + 1
    end

    local adjust_west = 0
    for x = 0, width - 1 do
        if not IsColAllZero(x) then break end
        adjust_west = adjust_west + 1
    end

    local adjust_east = 0
    for x = width - 1, 0, -1 do
        if not IsColAllZero(x) then break end
        adjust_east = adjust_east + 1
    end

    if adjust_south == 0 and adjust_north == 0 and adjust_west == 0 and adjust_east == 0 then
        return fertility_table, west_x, south_y, width, height
    end

    local new_west_x  = (west_x + adjust_west) % map_width
    local new_south_y = (south_y + adjust_south) % map_height
    local new_width   = width - adjust_west - adjust_east
    local new_height  = height - adjust_south - adjust_north

    local adjusted = {}
    for y = 0, new_height - 1 do
        for x = 0, new_width - 1 do
            local i = (y + adjust_south) * width + (x + adjust_west) + 1
            table.insert(adjusted, fertility_table[i])
        end
    end

    print(string.format("  Removed dead rows: W=%d E=%d S=%d N=%d", adjust_west, adjust_east, adjust_south, adjust_north))

    return adjusted, new_west_x, new_south_y, new_width, new_height
end

------------------------------------------------------------------------------
-- CHOP INTO TWO REGIONS
-- Splits a rectangle along the longer axis to produce two sub-rectangles
-- whose fertility ratio approximates chop_percent / (100 - chop_percent).
-- Returns: { fert_a, rect_a, fert_b, rect_b }
--   where rect_a/rect_b are positional tables for recursion:
--   { west_x, south_y, width, height, area_id, fertility, plot_count }
------------------------------------------------------------------------------
function Lekmap_Regions.ChopIntoTwo(fertility_table, rect_data, b_taller, chop_percent)
    local map_width, map_height = Map.GetGridSize()

    local r_west_x  = rect_data[1]
    local r_south_y = rect_data[2]
    local r_width   = rect_data[3]
    local r_height  = rect_data[4]
    local r_area_id = rect_data[5]
    local target_fertility = rect_data[6] * chop_percent / 100

    local first_fert  = 0
    local second_fert = 0
    local fert_a = {}
    local fert_b = {}

    local first_west_x, first_south_y, first_width, first_height
    local second_west_x, second_south_y, second_width, second_height

    if b_taller then
        -- Divide horizontally: first region on bottom, second on top.
        first_west_x  = r_west_x
        first_south_y = r_south_y
        first_width   = r_width
        second_west_x = r_west_x
        second_width  = r_width

        local split_row = 0
        for y = 0, r_height - 1 do
            for x = 0, r_width - 1 do
                local i = y * r_width + x + 1
                first_fert = first_fert + fertility_table[i]
                table.insert(fert_a, fertility_table[i])
            end
            if first_fert >= target_fertility then
                split_row = y
                break
            end
        end

        first_height   = split_row + 1
        second_south_y = (r_south_y + split_row + 1) % map_height
        second_height  = r_height - first_height

        for y = first_height, r_height - 1 do
            for x = 0, r_width - 1 do
                local i = y * r_width + x + 1
                second_fert = second_fert + fertility_table[i]
                table.insert(fert_b, fertility_table[i])
            end
        end
    else
        -- Divide vertically: first region on left, second on right.
        first_south_y  = r_south_y
        first_height   = r_height
        second_south_y = r_south_y
        second_height  = r_height

        local split_col = 0
        for x = 0, r_width - 1 do
            for y = 0, r_height - 1 do
                local i = y * r_width + x + 1
                first_fert = first_fert + fertility_table[i]
            end
            if first_fert >= target_fertility then
                split_col = x
                break
            end
        end

        first_west_x  = r_west_x
        first_width   = split_col + 1
        second_west_x = (r_west_x + split_col + 1) % map_width
        second_width  = r_width - first_width

        for y = 0, r_height - 1 do
            for x = first_width, r_width - 1 do
                local i = y * r_width + x + 1
                second_fert = second_fert + fertility_table[i]
                table.insert(fert_b, fertility_table[i])
            end
        end

        for y = 0, r_height - 1 do
            for x = 0, first_width - 1 do
                local i = y * r_width + x + 1
                table.insert(fert_a, fertility_table[i])
            end
        end
    end

    -- Trim dead rows from both sub-regions.
    local a_fert, a_west_x, a_south_y, a_width, a_height =
        Lekmap_Regions.RemoveDeadRows(fert_a, first_west_x, first_south_y, first_width, first_height)
    local b_fert, b_west_x, b_south_y, b_width, b_height =
        Lekmap_Regions.RemoveDeadRows(fert_b, second_west_x, second_south_y, second_width, second_height)

    local rect_a = { a_west_x, a_south_y, a_width, a_height, r_area_id, first_fert,  a_width * a_height }
    local rect_b = { b_west_x, b_south_y, b_width, b_height, r_area_id, second_fert, b_width * b_height }

    return { a_fert, rect_a, b_fert, rect_b }
end

------------------------------------------------------------------------------
-- CHOP INTO THREE REGIONS
-- Cuts off approximately one-third, then splits the remainder in half.
-- Returns: { fert_a, rect_a, fert_b, rect_b, fert_c, rect_c }
------------------------------------------------------------------------------
function Lekmap_Regions.ChopIntoThree(fertility_table, rect_data, b_taller)
    local initial = Lekmap_Regions.ChopIntoTwo(fertility_table, rect_data, b_taller, 33)

    local results = {}
    table.insert(results, initial[1])
    table.insert(results, initial[2])

    local remainder_fert = initial[3]
    local remainder_rect = initial[4]

    local remainder_taller = (remainder_rect[4] > remainder_rect[3])
    local second = Lekmap_Regions.ChopIntoTwo(remainder_fert, remainder_rect, remainder_taller, 48.5)

    table.insert(results, second[1])
    table.insert(results, second[2])
    table.insert(results, second[3])
    table.insert(results, second[4])

    return results
end

------------------------------------------------------------------------------
-- RECURSIVE REGION DIVISION (Ed Beach algorithm)
-- Divides a rectangle of fertility data into num_divisions sub-regions.
-- Each leaf region is stored in Lekmap_Regions.regions.
-- Uses positional rect tables internally for recursion compatibility,
-- but converts to named records when storing final regions.
------------------------------------------------------------------------------
function Lekmap_Regions.DivideIntoRegions(num_divisions, fertility_table, rect_data)

    if num_divisions == 1 then
        -- Base case: this rectangle IS a region.
        local region = CreateRegionRecord(
            rect_data[1], rect_data[2], rect_data[3], rect_data[4],
            rect_data[5], rect_data[6], rect_data[7]
        )
        table.insert(Lekmap_Regions.regions, region)
        local idx = #Lekmap_Regions.regions
        print(string.format("  Defined Region #%d", idx))
        return
    end

    if num_divisions < 1 then
        print("ERROR: DivideIntoRegions called with < 1 divisions")
        return
    end

    local b_taller = (rect_data[4] > rect_data[3])

    -- Check for prime numbers > 3 that need uneven splitting.
    local prime_info = PRIME_DIVISIONS[num_divisions]
    if prime_info then
        local results = Lekmap_Regions.ChopIntoTwo(fertility_table, rect_data, b_taller, prime_info.chopPercent)
        Lekmap_Regions.DivideIntoRegions(prime_info.firstSub, results[1], results[2])
        Lekmap_Regions.DivideIntoRegions(prime_info.laterSub, results[3], results[4])
        return
    end

    -- Composite or small numbers (2, 3, 4, 6, 8, 9, 10, ..., 22).
    local comp_info = COMPOSITE_DIVISIONS[num_divisions]
    if not comp_info then
        print("ERROR: Unsupported division count: " .. tostring(num_divisions))
        return
    end

    if comp_info.divides == 2 then
        local results = Lekmap_Regions.ChopIntoTwo(fertility_table, rect_data, b_taller, 49.5)
        Lekmap_Regions.DivideIntoRegions(comp_info.subs, results[1], results[2])
        Lekmap_Regions.DivideIntoRegions(comp_info.subs, results[3], results[4])

    elseif comp_info.divides == 3 then
        local results = Lekmap_Regions.ChopIntoThree(fertility_table, rect_data, b_taller)
        Lekmap_Regions.DivideIntoRegions(comp_info.subs, results[1], results[2])
        Lekmap_Regions.DivideIntoRegions(comp_info.subs, results[3], results[4])
        Lekmap_Regions.DivideIntoRegions(comp_info.subs, results[5], results[6])
    end
end

------------------------------------------------------------------------------
-- TERRAIN MEASUREMENT
-- Counts 23 terrain/feature/plot-type elements in a region.
-- Returns a named-field table. Replaces MeasureTerrainInRegions.
------------------------------------------------------------------------------
function Lekmap_Regions.MeasureTerrain(region, coastal_data, next_to_coast_data)
    local map_width, map_height = Map.GetGridSize()
    local counts = CreateTerrainCounts()

    for region_y = 0, region.height - 1 do
        for region_x = 0, region.width - 1 do
            counts.totalPlots = counts.totalPlots + 1
            local x = (region_x + region.westX) % map_width
            local y = (region_y + region.southY) % map_height
            local plot = Map.GetPlot(x, y)
            local area_of_plot = plot:GetArea()
            local plot_type    = plot:GetPlotType()
            local terrain_type = plot:GetTerrainType()
            local feature_type = plot:GetFeatureType()

            if plot_type == PlotTypes.PLOT_MOUNTAIN then
                counts.peaks = counts.peaks + 1

            elseif plot_type == PlotTypes.PLOT_OCEAN then
                counts.water = counts.water + 1
                if terrain_type == TerrainTypes.TERRAIN_COAST then
                    if plot:IsLake() then
                        counts.lake = counts.lake + 1
                    else
                        counts.coast = counts.coast + 1
                    end
                else
                    counts.ocean = counts.ocean + 1
                end
                if feature_type == FeatureTypes.FEATURE_ICE then
                    counts.ice = counts.ice + 1
                end

            else
                -- Hills or flatlands. Only count if plot belongs to region's area (or area is -1).
                if area_of_plot == region.areaID or region.areaID == -1 then
                    counts.areaPlots = counts.areaPlots + 1
                    local plot_index = map_width * y + x + 1

                    local function CountCoastal()
                        if coastal_data and coastal_data[plot_index] then
                            counts.coastalLand = counts.coastalLand + 1
                        elseif next_to_coast_data and next_to_coast_data[plot_index] then
                            counts.nextToCoast = counts.nextToCoast + 1
                        end
                    end

                    local function CountFeature()
                        if feature_type == FeatureTypes.FEATURE_FOREST then
                            counts.forest = counts.forest + 1
                        elseif feature_type == FeatureTypes.FEATURE_JUNGLE then
                            counts.jungle = counts.jungle + 1
                        elseif feature_type == FeatureTypes.FEATURE_MARSH then
                            counts.marsh = counts.marsh + 1
                        elseif feature_type == FeatureTypes.FEATURE_FLOOD_PLAINS then
                            counts.floodplain = counts.floodplain + 1
                        elseif feature_type == FeatureTypes.FEATURE_OASIS then
                            counts.oasis = counts.oasis + 1
                        end
                    end

                    if plot_type == PlotTypes.PLOT_HILLS then
                        counts.hills = counts.hills + 1
                    else
                        counts.flatlands = counts.flatlands + 1
                        if terrain_type == TerrainTypes.TERRAIN_GRASS then
                            counts.grass = counts.grass + 1
                        elseif terrain_type == TerrainTypes.TERRAIN_PLAINS then
                            counts.plains = counts.plains + 1
                        elseif terrain_type == TerrainTypes.TERRAIN_DESERT then
                            counts.desert = counts.desert + 1
                        elseif terrain_type == TerrainTypes.TERRAIN_TUNDRA then
                            counts.tundra = counts.tundra + 1
                        elseif terrain_type == TerrainTypes.TERRAIN_SNOW then
                            counts.snow = counts.snow + 1
                        end
                    end

                    CountCoastal()
                    if Lekmap_Utilities.AdjacentToInlandSea(x, y) then counts.inlandSeaCoast = counts.inlandSeaCoast + 1 end
                    CountFeature()

                    if plot:IsRiverSide() then
                        counts.river = counts.river + 1
                    end
                end
            end
        end
    end

    return counts
end

------------------------------------------------------------------------------
-- REGION TYPE CLASSIFICATION
-- Determines the REGION_TYPE for a region based on its terrain counts.
-- Uses the active classification thresholds (the simpler, non-Barathor path).
------------------------------------------------------------------------------
function Lekmap_Regions.ClassifyRegionType(counts)
    local REGION_TYPE = Lekmap_Constants.REGION_TYPE

    local area = counts.areaPlots
    if area == 0 then return REGION_TYPE.HYBRID end

    local tundra_snow = counts.tundra + counts.snow

    if tundra_snow >= area * CLASSIFY_TUNDRA_SNOW_PCT then
        return REGION_TYPE.TUNDRA
    end

    if counts.jungle >= area * CLASSIFY_JUNGLE_PCT then
        return REGION_TYPE.JUNGLE
    end
    if counts.jungle >= area * CLASSIFY_JUNGLE_COMBO_PCT
       and (counts.jungle + counts.forest) >= area * CLASSIFY_JUNGLE_FOREST_PCT then
        return REGION_TYPE.JUNGLE
    end

    if counts.forest >= area * CLASSIFY_FOREST_PCT then
        return REGION_TYPE.FOREST
    end
    if counts.forest >= area * CLASSIFY_FOREST_HIGH_PCT
       and (counts.jungle + counts.forest) >= area * CLASSIFY_FOREST_COMBO_PCT then
        return REGION_TYPE.FOREST
    end

    if counts.desert >= area * CLASSIFY_DESERT_PCT then
        return REGION_TYPE.DESERT
    end

    if counts.marsh >= area * CLASSIFY_WETLANDS_PCT
       or counts.marsh >= CLASSIFY_WETLANDS_MIN_COUNT then
        return REGION_TYPE.WETLANDS
    end

    if counts.hills >= area * CLASSIFY_HILLS_PCT then
        return REGION_TYPE.HILLS
    end

    if counts.grass >= area * CLASSIFY_GRASS_PCT
       and counts.grass * CLASSIFY_GRASS_RATIO > counts.plains then
        return REGION_TYPE.GRASS
    end

    if counts.plains >= area * CLASSIFY_PLAINS_PCT
       and counts.plains * CLASSIFY_PLAINS_RATIO > counts.grass then
        return REGION_TYPE.PLAINS
    end

    local combined_land = counts.grass + counts.plains + counts.desert
                        + counts.tundra + counts.snow + counts.hills + counts.peaks
    if combined_land > area * CLASSIFY_HYBRID_PCT then
        return REGION_TYPE.HYBRID
    end

    return REGION_TYPE.HYBRID
end

------------------------------------------------------------------------------
-- PRINT TERRAIN SUMMARY
-- Logs terrain counts for a region (debug output).
------------------------------------------------------------------------------
local function PrintTerrainSummary(region_index, counts)
    print(string.format("--- Region #%d Terrain ---", region_index))
    print(string.format("  Total: %d  Area: %d  Water: %d", counts.totalPlots, counts.areaPlots, counts.water))
    print(string.format("  Flat: %d  Hills: %d  Peaks: %d", counts.flatlands, counts.hills, counts.peaks))
    print(string.format("  Grass: %d  Plains: %d  Desert: %d  Tundra: %d  Snow: %d",
          counts.grass, counts.plains, counts.desert, counts.tundra, counts.snow))
    print(string.format("  Forest: %d  Jungle: %d  Marsh: %d  Flood: %d  Oasis: %d",
          counts.forest, counts.jungle, counts.marsh, counts.floodplain, counts.oasis))
    print(string.format("  River: %d  CoastalLand: %d  NextToCoast: %d",
          counts.river, counts.coastalLand, counts.nextToCoast))
end

------------------------------------------------------------------------------
-- REGION TYPE NAME (for logging)
------------------------------------------------------------------------------
local REGION_TYPE_NAMES = {
    [1] = "Tundra",    -- REGION_TYPE.TUNDRA
    [2] = "Jungle",    -- REGION_TYPE.JUNGLE
    [3] = "Forest",    -- REGION_TYPE.FOREST
    [4] = "Desert",    -- REGION_TYPE.DESERT
    [5] = "Hills",     -- REGION_TYPE.HILLS
    [6] = "Plains",    -- REGION_TYPE.PLAINS
    [7] = "Grassland", -- REGION_TYPE.GRASS
    [8] = "Hybrid",    -- REGION_TYPE.HYBRID
    [9] = "Wetlands",  -- REGION_TYPE.WETLANDS
}

function Lekmap_Regions.GetRegionTypeName(region_type)
    return REGION_TYPE_NAMES[region_type] or "Undefined"
end

------------------------------------------------------------------------------
-- MAIN ENTRY POINT: Generate()
-- Divides the map into regions, measures terrain, classifies types.
--
-- args fields:
--   method           1 = Biggest Landmass (only supported method for now)
--   coastalData      plotDataIsCoastal table (from GenerateNextToCoastalLandDataTables)
--   nextToCoastData  plotDataIsNextToCoast table
--   numCivs          number of civilizations to create regions for
------------------------------------------------------------------------------
function Lekmap_Regions.Generate(args)
    print("Lekmap_Regions: Generating regions")
    local args = args or {}
    local method = args.method or 1

    -- Reset module state.
    Lekmap_Regions.regions       = {}
    Lekmap_Regions.terrainCounts = {}
    Lekmap_Regions.regionTypes   = {}

    local num_civs           = args.numCivs or 0
    local coastal_data       = args.coastalData
    local next_to_coast_data = args.nextToCoastData
    if not coastal_data or not next_to_coast_data then
        coastal_data, next_to_coast_data = Lekmap_Utilities.GenerateNextToCoastalLandDataTables()
    end

    if num_civs == 0 then
        print("  WARNING: numCivs is 0, no regions will be generated.")
        return
    end

    if method == 1 then
        Lekmap_Regions.GenerateBiggestLandmass(num_civs)
    else
        -- TODO: Methods 2 (Continental) and 3/4 (Rectangular) for future map types.
        print(string.format("  WARNING: Region method %d not yet implemented, falling back to method 1.", method))
        Lekmap_Regions.GenerateBiggestLandmass(num_civs)
    end

    -- Measure terrain and classify types for each region.
    for i, region in ipairs(Lekmap_Regions.regions) do
        local terrain_counts = Lekmap_Regions.MeasureTerrain(region, coastal_data, next_to_coast_data)
        table.insert(Lekmap_Regions.terrainCounts, terrain_counts)
        PrintTerrainSummary(i, terrain_counts)

        local region_type = Lekmap_Regions.ClassifyRegionType(terrain_counts)
        table.insert(Lekmap_Regions.regionTypes, region_type)
        print(string.format("  Region #%d classified as: %s", i, Lekmap_Regions.GetRegionTypeName(region_type)))
    end

    print(string.format("Lekmap_Regions: %d regions generated.", #Lekmap_Regions.regions))
end

------------------------------------------------------------------------------
-- METHOD 1: BIGGEST LANDMASS
-- All civs start on the biggest landmass. Identifies it, measures fertility,
-- then divides it into one region per civ.
------------------------------------------------------------------------------
function Lekmap_Regions.GenerateBiggestLandmass(num_civs)
    print("  Method 1: Biggest Landmass")

    local biggest_area = Map.FindBiggestArea(false)
    local area_id      = biggest_area:GetID()

    local bounds  = Lekmap_Utilities.ObtainLandmassBoundaries(area_id)
    local west_x  = bounds[1]
    local south_y = bounds[2]
    local east_x  = bounds[3]
    local north_y = bounds[4]
    local width   = bounds[5]
    local height  = bounds[6]
    local wraps_x = bounds[7]
    local wraps_y = bounds[8]

    print(string.format("  Biggest landmass: AreaID=%d  W=%d E=%d S=%d N=%d  Size=%dx%d  Wraps: X=%s Y=%s",
          area_id, west_x, east_x, south_y, north_y, width, height, tostring(wraps_x), tostring(wraps_y)))

    local fert_table, fert_sum, plot_count =
        Lekmap_Regions.MeasureLandmassFertility(area_id, west_x, east_x, south_y, north_y, wraps_x, wraps_y)

    print(string.format("  Fertility: %d  Plots: %d  Avg: %.2f", fert_sum, plot_count, fert_sum / math.max(plot_count, 1)))

    local rect_data = { west_x, south_y, width, height, area_id, fert_sum, plot_count }
    Lekmap_Regions.DivideIntoRegions(num_civs, fert_table, rect_data)
end

------------------------------------------------------------------------------
-- ACCESSORS
-- Convenience functions for downstream consumers.
------------------------------------------------------------------------------
function Lekmap_Regions.GetRegion(index)
    return Lekmap_Regions.regions[index]
end

function Lekmap_Regions.GetRegionType(index)
    return Lekmap_Regions.regionTypes[index]
end

function Lekmap_Regions.GetTerrainCounts(index)
    return Lekmap_Regions.terrainCounts[index]
end

function Lekmap_Regions.GetRegionCount()
    return #Lekmap_Regions.regions
end

------------------------------------------------------------------------------
-- BACKWARD-COMPATIBLE EXPORT
-- Converts the named-field region data back into the positional arrays
-- that HBAssignStartingPlots expects, so downstream code keeps working
-- until it is fully migrated.
--
-- Usage (inside HBAssignStartingPlots):
--   local compat = Lekmap_Regions.ExportForLegacy()
--   self.regionData          = compat.regionData
--   self.regionTerrainCounts = compat.regionTerrainCounts
--   self.regionTypes         = compat.regionTypes
------------------------------------------------------------------------------
function Lekmap_Regions.ExportForLegacy()
    local region_data = {}
    for _, r in ipairs(Lekmap_Regions.regions) do
        table.insert(region_data, {
            r.westX, r.southY, r.width, r.height,
            r.areaID, r.fertility, r.plotCount, r.avgFertility,
        })
    end

    local region_terrain_counts = {}
    for _, c in ipairs(Lekmap_Regions.terrainCounts) do
        table.insert(region_terrain_counts, {
            c.totalPlots, c.areaPlots,
            c.water, c.flatlands, c.hills, c.peaks,
            c.lake, c.coast, c.ocean, c.ice,
            c.grass, c.plains, c.desert, c.tundra, c.snow,
            c.forest, c.jungle, c.marsh,
            c.river, c.floodplain, c.oasis,
            c.coastalLand, c.nextToCoast,
        })
    end

    return {
        regionData          = region_data,
        regionTerrainCounts = region_terrain_counts,
        regionTypes         = Lekmap_Regions.regionTypes,
    }
end
