------------------------------------------------------------------------------
--  FILE:     Lekmap_Utilities.lua
--  AUTHOR:   EnormousApplePie (clean rewrite of HBMapmakerUtilities.lua)
--  PURPOSE:  General-purpose utility functions for Lekmap.
--            Consolidates table helpers, player/team info, landmass
--            boundary detection, coastal proximity data, and civ start
--            bias queries.
------------------------------------------------------------------------------
--  Depends on:
--      Lekmap_Constants.lua (Lekmap_Constants.DIRECTION_LIST)
--  Engine globals: Map, Players, GameDefines, Game, GameInfo, DB,
--                  PlotTypes, TerrainTypes
------------------------------------------------------------------------------
--luacheck: globals Lekmap_Utilities Lekmap_Constants
--luacheck: globals Map Players GameDefines Game GameInfo DB
--luacheck: globals PlotTypes TerrainTypes
--luacheck: ignore table

Lekmap_Utilities = {}

-- Native generation must return a playable map. Prefer existing mainland land,
-- then other land; only an exhausted layout permits a small terrain repair.
function Lekmap_Utilities.FindFallbackStart(occupied, minimum_distance, repair_terrain)
    local width,height=Map.GetGridSize()
    local mainland=Map.FindBiggestArea(false)
    local mainland_id=mainland and mainland:GetID()
    local best,best_score
    for y=0,height-1 do for x=0,width-1 do
        local plot=Map.GetPlot(x,y)
        local usable=not plot:IsNaturalWonder() and (repair_terrain or
            (not plot:IsWater() and not plot:IsMountain() and plot:GetResourceType(-1)==-1
                and plot:GetFeatureType()~=FeatureTypes.FEATURE_OASIS))
        if usable then
            local closest=width+height
            for _,start in ipairs(occupied) do closest=math.min(closest,Map.PlotDistance(x,y,start.x,start.y)) end
            if closest>=minimum_distance then
                local score=closest*100+(plot:IsFreshWater() and 10 or 0)
                if #occupied==0 then score=score-(math.abs(x-(width-1)/2)+math.abs(y-(height-1)/2))*100 end
                if mainland_id and plot:GetArea()==mainland_id then score=score+1000000 end
                if not best_score or score>best_score then best,best_score=plot,score end
            end
        end
    end end
    if not best then return nil end
    if repair_terrain then
        best:SetResourceType(-1,0)
        best:SetFeatureType(FeatureTypes.NO_FEATURE,-1)
        best:SetPlotType(PlotTypes.PLOT_LAND,false,true)
        best:SetTerrainType(TerrainTypes.TERRAIN_GRASS,false,true)
    end
    return best:GetX(),best:GetY()
end

function Lekmap_Utilities.EnsureNativeStarts()
    local occupied={}
    for id=0,GameDefines.MAX_CIV_PLAYERS-1 do
        local player=Players[id]
        if player and player:IsEverAlive() then
            local plot=player:GetStartingPlot()
            local valid=plot and not plot:IsWater() and not plot:IsMountain() and not plot:IsNaturalWonder()
            if valid then
                for _,other in ipairs(occupied) do
                    if other.x==plot:GetX() and other.y==plot:GetY() then valid=false;break end
                end
            end
            if not valid then
                local x,y
                for distance=5,1,-1 do
                    x,y=Lekmap_Utilities.FindFallbackStart(occupied,distance,false)
                    if x then break end
                end
                if not x then x,y=Lekmap_Utilities.FindFallbackStart(occupied,1,true) end
                if x then
                    plot=Map.GetPlot(x,y)
                    player:SetStartingPlot(plot)
                    print(string.format("Lekmap recovery: player %d starts at (%d,%d)",id,x,y))
                end
            end
            if plot then
                plot:SetResourceType(-1,0)
                occupied[#occupied+1]={x=plot:GetX(),y=plot:GetY(),player=id,minor=id>=GameDefines.MAX_MAJOR_CIVS}
            end
        end
    end
    return occupied
end

-- A deterministic connected Pangaea used only if no usable fractal candidate
-- survives, or if an unexpected Lua error interrupts the ordinary pipeline.
function Lekmap_Utilities.EmergencyPlotTypes()
    local width,height=Map.GetGridSize()
    local plots={}
    for y=0,height-1 do for x=0,width-1 do
        local dx=(x-(width-1)/2)/(width*0.43)
        local dy=(y-(height-1)/2)/(height*0.43)
        local land=dx*dx+dy*dy<=1
        plots[y*width+x+1]=land and ((x+2*y)%5==0 and PlotTypes.PLOT_HILLS or PlotTypes.PLOT_LAND) or PlotTypes.PLOT_OCEAN
    end end
    return plots
end

local recovering_generation=false
function Lekmap_Utilities.RecoverGeneration()
    local retry_placement=not recovering_generation
    recovering_generation=true
    print("Lekmap recovery: generating a simple connected fallback map.")
    local width,height=Map.GetGridSize()
    local types=Lekmap_Utilities.EmergencyPlotTypes()
    for index=0,width*height-1 do
        local plot=Map.GetPlotByIndex(index)
        plot:SetResourceType(-1,0)
        plot:SetFeatureType(FeatureTypes.NO_FEATURE,-1)
        if plot.SetWOfRiver then plot:SetWOfRiver(false,FlowDirectionTypes.NO_FLOWDIRECTION) end
        if plot.SetNWOfRiver then plot:SetNWOfRiver(false,FlowDirectionTypes.NO_FLOWDIRECTION) end
        if plot.SetNEOfRiver then plot:SetNEOfRiver(false,FlowDirectionTypes.NO_FLOWDIRECTION) end
        if plot.SetImprovementType then plot:SetImprovementType(-1) end
        if plot.SetRouteType then plot:SetRouteType(-1) end
        plot:SetPlotType(types[index+1],false,false)
        plot:SetTerrainType(plot:IsWater() and TerrainTypes.TERRAIN_COAST or TerrainTypes.TERRAIN_GRASS,false,false)
    end
    Map.RecalculateAreas()
    -- Re-run the normal climate and placement modules on safe geometry. Their
    -- selected options remain authoritative; no lobby interaction is needed.
    if GenerateTerrain then pcall(GenerateTerrain) end
    if AddFeatures then pcall(AddFeatures) end
    local river_spacing=({9,7,5})[Map.GetCustomOption(9)] or 7
    for index=0,width*height-1 do
        local plot=Map.GetPlotByIndex(index)
        local east=Map.PlotDirection(plot:GetX(),plot:GetY(),DirectionTypes.DIRECTION_EAST)
        if plot.SetWOfRiver and plot:GetX()%river_spacing==0 and not plot:IsWater() and east and not east:IsWater() then
            plot:SetWOfRiver(true,FlowDirectionTypes.FLOWDIRECTION_NORTH)
        end
    end
    Map.RecalculateAreas()
    if retry_placement and StartPlotSystem then
        local placed=pcall(StartPlotSystem)
        if placed then recovering_generation=false;return end
    end
    local starts=Lekmap_Utilities.EnsureNativeStarts()
    local occupied={}
    for _,start in ipairs(starts) do occupied[start.y*width+start.x+1]=true end
    -- Mod-independent base resources. No scripted placement module is needed
    -- on this path, so an error there cannot prevent recovery.
    local distribution=Map.GetCustomOption(25) or 2
    local strategic_types={RESOURCE_IRON=true,RESOURCE_HORSE=true,RESOURCE_COAL=true,
        RESOURCE_OIL=true,RESOURCE_ALUMINUM=true,RESOURCE_URANIUM=true}
    local function permitted(name,plot)
        if not strategic_types[name] or distribution==1 then return true end
        if distribution==2 and (name=="RESOURCE_IRON" or name=="RESOURCE_HORSE") then return true end
        local distances={}
        for _,start in ipairs(starts) do if not start.minor then
            local distance=Map.PlotDistance(plot:GetX(),plot:GetY(),start.x,start.y)
            if distance<=3 then return false end
            local team=Players[start.player]:GetTeam()
            if not distances[team] or distance<distances[team] then distances[team]=distance end
        end end
        local ordered={};for _,distance in pairs(distances) do ordered[#ordered+1]=distance end;table.sort(ordered)
        if #ordered==1 then return ordered[1]>=6 end
        return #ordered>=2 and ordered[2]-ordered[1]<=4 and ordered[2]<=ordered[1]*1.5
    end
    local land_resources={"RESOURCE_COW","RESOURCE_STONE","RESOURCE_HORSE","RESOURCE_IRON",
        "RESOURCE_GOLD","RESOURCE_COAL","RESOURCE_ALUMINUM","RESOURCE_URANIUM"}
    for index=0,width*height-1 do
        local plot=Map.GetPlotByIndex(index)
        if not occupied[index+1] then
            local near_start=false
            for _,start in ipairs(starts) do
                if Map.PlotDistance(plot:GetX(),plot:GetY(),start.x,start.y)<=3 then near_start=true;break end
            end
            local resource,name
            if plot:IsWater() then
                if plot:IsAdjacentToLand() and index%5==0 then
                    name=index%10==0 and "RESOURCE_OIL" or "RESOURCE_FISH"
                    resource=GameInfoTypes[name]
                end
            elseif near_start or index%5==0 then
                name=land_resources[(index+math.floor(index/width))%#land_resources+1]
                resource=GameInfoTypes[name]
                if name=="RESOURCE_IRON" or name=="RESOURCE_GOLD" or name=="RESOURCE_COAL" or name=="RESOURCE_ALUMINUM" then
                    plot:SetPlotType(PlotTypes.PLOT_HILLS,false,false)
                else
                    plot:SetPlotType(PlotTypes.PLOT_LAND,false,false)
                end
            end
            if resource and permitted(name,plot) then
                local strategic=Game.GetResourceUsageType(resource)==ResourceUsageTypes.RESOURCEUSAGE_STRATEGIC
                plot:SetResourceType(resource,strategic and 4 or 1)
            end
        end
    end
    Map.RecalculateAreas()
    recovering_generation=false
end

------------------------------------------------------------------------------
-- TABLE HELPERS
------------------------------------------------------------------------------

-- Lua hash iteration order is not a multiplayer contract. Use ordered keys in
-- passes that consume randomness or compete for the same plots.
function Lekmap_Utilities.OrderedPairs(tbl)
    local keys = {}
    for key in pairs(tbl) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b)
        if type(a) == type(b) then return a < b end
        return tostring(a) < tostring(b)
    end)
    local index = 0
    return function()
        index = index + 1
        local key = keys[index]
        if key ~= nil then return key, tbl[key] end
    end
end

--- Checks whether a value exists in a table.
--- @param  tbl    table to search
--- @param  value  value to find
--- @return true if found
function Lekmap_Utilities.TestMembership(tbl, value)
    for _, entry in pairs(tbl) do
        if entry == value then
            return true
        end
    end
    return false
end

--- Returns a shuffled copy of a sequential table (no gaps).
--- Uses Map.Rand for deterministic replay support.
--- @param  source_table  sequential table to shuffle
--- @return shuffled copy
function Lekmap_Utilities.GetShuffledCopyOfTable(source_table)
    local length = table.maxn(source_table)
    local copy = {}
    for index = 1, length do
        copy[index] = source_table[index]
    end

    local shuffled = {}
    local remaining = length
    for _ = 1, length do
        local random_index = 1 + Map.Rand(remaining, "Shuffling table entry - Lua")
        table.insert(shuffled, copy[random_index])
        table.remove(copy, random_index)
        remaining = remaining - 1
    end
    return shuffled
end

--- Finds all indices in a table that match a given value.
--- @param  source_table  table to search
--- @param  value         value to match
--- @return found (bool), count (int), matching_indices (table)
function Lekmap_Utilities.IdentifyTableIndex(source_table, value)
    local found = false
    local count = 0
    local matching_indices = {}
    for index, entry in pairs(source_table) do
        if entry == value then
            found = true
            count = count + 1
            table.insert(matching_indices, index)
        end
    end
    return found, count, matching_indices
end

--- Prints all key-value pairs in a table.  Debug only.
--- @param  source_table  table to print
function Lekmap_Utilities.PrintContentsOfTable(source_table)
    print("--------------------------------------------------")
    print("Table printout:")
    for index, data in pairs(source_table) do
        print("  index:", index, "value:", data)
    end
    print("--------------------------------------------------")
end

------------------------------------------------------------------------------
-- PLOT INDEX HELPERS
------------------------------------------------------------------------------

--- Converts (x, y) to a 1-based plot index for use with data tables.
--- @param  x  plot X coordinate
--- @param  y  plot Y coordinate
--- @return 1-based plot index
function Lekmap_Utilities.PlotIndex(x, y)
    local map_width = Map.GetGridSize()
    return y * map_width + x + 1
end

------------------------------------------------------------------------------
-- ADJACENCY HELPERS
-- These replace the repeated 6-direction check blocks in the old code
-- by using DIRECTION_LIST from Lekmap_Constants.
------------------------------------------------------------------------------

--- Checks if any adjacent plot satisfies a predicate function.
--- @param  x          plot X coordinate
--- @param  y          plot Y coordinate
--- @param  predicate  function(adjacent_plot, adj_x, adj_y, adj_index) -> bool
--- @return true if any adjacent plot satisfies the predicate
function Lekmap_Utilities.AnyAdjacentSatisfies(x, y, predicate)
    local DIRECTION_LIST = Lekmap_Constants.DIRECTION_LIST
    for _, direction in ipairs(DIRECTION_LIST) do
        local adjacent_plot = Map.PlotDirection(x, y, direction)
        if adjacent_plot ~= nil then
            local adj_x = adjacent_plot:GetX()
            local adj_y = adjacent_plot:GetY()
            local adj_index = Lekmap_Utilities.PlotIndex(adj_x, adj_y)
            if predicate(adjacent_plot, adj_x, adj_y, adj_index) then
                return true
            end
        end
    end
    return false
end

------------------------------------------------------------------------------
-- PLAYER AND TEAM INFO
------------------------------------------------------------------------------

--- Returns player count, city-state count, player ID list, and team info.
--- @return num_civs, num_city_states, player_id_list, is_team_game,
---         teams_with_major_civs, num_civs_per_team
function Lekmap_Utilities.GetPlayerAndTeamInfo()
    local num_civs = 0
    local num_city_states = 0
    local player_id_list = {}
    local city_state_ids = {}

    for player_index = 0, GameDefines.MAX_MAJOR_CIVS - 1 do
        local player = Players[player_index]
        if player:IsEverAlive() then
            num_civs = num_civs + 1
            table.insert(player_id_list, player_index)
        end
    end

    for player_index = GameDefines.MAX_MAJOR_CIVS, GameDefines.MAX_CIV_PLAYERS - 1 do
        local player = Players[player_index]
        if player:IsEverAlive() then
            num_city_states = num_city_states + 1
            table.insert(city_state_ids, player_index)
        end
    end

    local is_team_game = false
    local total_teams = Game.CountCivTeamsEverAlive()
    local teams_of_civs = total_teams - num_city_states
    if teams_of_civs < num_civs then
        is_team_game = true
    end

    local teams_with_major_civs = {}
    local num_civs_per_team = table.fill(0, GameDefines.MAX_CIV_PLAYERS)
    num_civs_per_team[0] = 0
    for player_index = 0, GameDefines.MAX_MAJOR_CIVS - 1 do
        local player = Players[player_index]
        if player:IsEverAlive() then
            local team_id = player:GetTeam()
            num_civs_per_team[team_id] = num_civs_per_team[team_id] + 1
            if not Lekmap_Utilities.TestMembership(teams_with_major_civs, team_id) then
                table.insert(teams_with_major_civs, team_id)
            end
        end
    end

    return num_civs, num_city_states, player_id_list, is_team_game,
           teams_with_major_civs, num_civs_per_team, city_state_ids
end

------------------------------------------------------------------------------
-- LANDMASS BOUNDARIES
------------------------------------------------------------------------------

--- Finds the bounding rectangle of a landmass by area ID.
--- @param  area_id  engine area ID of the landmass
--- @return table { west_x, south_y, east_x, north_y, width, height, wraps_x, wraps_y }
function Lekmap_Utilities.ObtainLandmassBoundaries(area_id)
    local map_width, map_height = Map.GetGridSize()
    local wraps_x = false
    local wraps_y = false
    local west_x, east_x, south_y, north_y

    if Map:IsWrapX() then
        wraps_x = Lekmap_Utilities._CheckAreaWraps(area_id, map_width, map_height, true)
    end
    if Map:IsWrapY() then
        wraps_y = Lekmap_Utilities._CheckAreaWraps(area_id, map_width, map_height, false)
    end

    west_x, east_x, wraps_x = Lekmap_Utilities._FindEdgesX(area_id, map_width, map_height, wraps_x)
    south_y, north_y, wraps_y = Lekmap_Utilities._FindEdgesY(area_id, map_width, map_height, wraps_y)

    local width, height
    if wraps_x then
        width = (east_x + map_width) - west_x + 1
    else
        width = east_x - west_x + 1
    end
    if wraps_y then
        height = (north_y + map_height) - south_y + 1
    else
        height = north_y - south_y + 1
    end

    return { west_x, south_y, east_x, north_y, width, height, wraps_x, wraps_y }
end

--- Checks if an area wraps around a map edge.
--- @param  area_id     engine area ID
--- @param  map_width   map width
--- @param  map_height  map height
--- @param  is_x_axis   true for X wrap check, false for Y
--- @return true if area wraps around the edge
function Lekmap_Utilities._CheckAreaWraps(area_id, map_width, map_height, is_x_axis)
    local found_first = false
    local found_last = false
    local iter_max = is_x_axis and (map_height - 1) or (map_width - 1)

    for iter_index = 0, iter_max do
        local plot_first, plot_last
        if is_x_axis then
            plot_first = Map.GetPlot(0, iter_index)
            plot_last = Map.GetPlot(map_width - 1, iter_index)
        else
            plot_first = Map.GetPlot(iter_index, 0)
            plot_last = Map.GetPlot(iter_index, map_height - 1)
        end
        if plot_first:GetArea() == area_id then found_first = true end
        if plot_last:GetArea() == area_id then found_last = true end
    end

    return found_first and found_last
end

--- Finds west and east edges of a landmass.
--- @param  area_id     engine area ID
--- @param  map_width   map width
--- @param  map_height  map height
--- @param  wraps_x     whether the area wraps in X
--- @return west_x, east_x, wraps_x (potentially updated)
function Lekmap_Utilities._FindEdgesX(area_id, map_width, map_height, wraps_x)
    local west_x, east_x

    if not wraps_x then
        for x = 0, map_width - 1 do
            if Lekmap_Utilities._ColumnContainsArea(x, map_height, area_id) then
                west_x = x
                break
            end
        end
        for x = map_width - 1, 0, -1 do
            if Lekmap_Utilities._ColumnContainsArea(x, map_height, area_id) then
                east_x = x
                break
            end
        end
    else
        local spans_entire_world = true
        for x = map_width - 2, 1, -1 do
            if not Lekmap_Utilities._ColumnContainsArea(x, map_height, area_id) then
                west_x = x + 1
                spans_entire_world = false
                break
            end
        end
        for x = 1, map_width - 2 do
            if not Lekmap_Utilities._ColumnContainsArea(x, map_height, area_id) then
                east_x = x - 1
                spans_entire_world = false
                break
            end
        end
        if spans_entire_world then
            wraps_x = false
            west_x = 0
            east_x = map_width - 1
        end
    end

    return west_x, east_x, wraps_x
end

--- Finds south and north edges of a landmass.
--- @param  area_id     engine area ID
--- @param  map_width   map width
--- @param  map_height  map height
--- @param  wraps_y     whether the area wraps in Y
--- @return south_y, north_y, wraps_y (potentially updated)
function Lekmap_Utilities._FindEdgesY(area_id, map_width, map_height, wraps_y)
    local south_y, north_y

    if not wraps_y then
        for y = 0, map_height - 1 do
            if Lekmap_Utilities._RowContainsArea(y, map_width, area_id) then
                south_y = y
                break
            end
        end
        for y = map_height - 1, 0, -1 do
            if Lekmap_Utilities._RowContainsArea(y, map_width, area_id) then
                north_y = y
                break
            end
        end
    else
        local spans_entire_world = true
        for y = map_height - 2, 1, -1 do
            if not Lekmap_Utilities._RowContainsArea(y, map_width, area_id) then
                south_y = y + 1
                spans_entire_world = false
                break
            end
        end
        for y = 1, map_height - 2 do
            if not Lekmap_Utilities._RowContainsArea(y, map_width, area_id) then
                north_y = y - 1
                spans_entire_world = false
                break
            end
        end
        if spans_entire_world then
            wraps_y = false
            south_y = 0
            north_y = map_height - 1
        end
    end

    return south_y, north_y, wraps_y
end

--- Returns true if any plot in column x belongs to the given area.
function Lekmap_Utilities._ColumnContainsArea(x, map_height, area_id)
    for y = 0, map_height - 1 do
        if Map.GetPlot(x, y):GetArea() == area_id then
            return true
        end
    end
    return false
end

--- Returns true if any plot in row y belongs to the given area.
function Lekmap_Utilities._RowContainsArea(y, map_width, area_id)
    for x = 0, map_width - 1 do
        if Map.GetPlot(x, y):GetArea() == area_id then
            return true
        end
    end
    return false
end

------------------------------------------------------------------------------
-- COASTAL PROXIMITY DATA
-- These functions generate boolean lookup tables indicating how far inland
-- each plot is from salt water.  Used for start placement and resource
-- distribution.
------------------------------------------------------------------------------

-- Distinguish the main ocean from enclosed seas by water-area identity.
-- Fresh water on a land tile may come from a river; it cannot identify a sea.
function Lekmap_Utilities.GetWaterKind(plot)
    if not plot or not plot:IsWater() then return nil end
    if plot:IsLake() then return "lake" end
    local ocean = Map.FindBiggestArea(true)
    if ocean and plot:GetArea() == ocean:GetID() then return "ocean" end
    return "inland_sea"
end

function Lekmap_Utilities.AdjacentToOcean(x, y)
    local plot = Map.GetPlot(x, y)
    return plot and not plot:IsWater() and Lekmap_Utilities.AnyAdjacentSatisfies(x, y, function(other)
        return Lekmap_Utilities.GetWaterKind(other) == "ocean"
    end) or false
end

function Lekmap_Utilities.AdjacentToInlandSea(x, y)
    local plot = Map.GetPlot(x, y)
    return plot and not plot:IsWater() and Lekmap_Utilities.AnyAdjacentSatisfies(x, y, function(other)
        return Lekmap_Utilities.GetWaterKind(other) == "inland_sea"
    end) or false
end

--- Returns true if the plot at (x, y) is land adjacent to salt water.
function Lekmap_Utilities.AdjacentToSaltWater(x, y)
    local plot = Map.GetPlot(x, y)
    if plot:GetPlotType() == PlotTypes.PLOT_OCEAN then
        return false
    end
    return Lekmap_Utilities.AnyAdjacentSatisfies(x, y, function(adjacent_plot)
        return adjacent_plot:GetPlotType() == PlotTypes.PLOT_OCEAN and not adjacent_plot:IsLake()
    end)
end

--- Returns true if the plot at (x, y) is ocean adjacent to the given landmass.
function Lekmap_Utilities.AdjacentToMainland(x, y, area_id)
    local plot = Map.GetPlot(x, y)
    if plot:GetPlotType() ~= PlotTypes.PLOT_OCEAN or plot:IsLake() then
        return false
    end
    return Lekmap_Utilities.AnyAdjacentSatisfies(x, y, function(adjacent_plot)
        return adjacent_plot:GetPlotType() ~= PlotTypes.PLOT_OCEAN and adjacent_plot:GetArea() == area_id
    end)
end

--- Generates a boolean table marking all land plots adjacent to salt water.
--- @return is_coastal  boolean lookup table indexed by plot index
function Lekmap_Utilities.GenerateCoastalLandDataTable()
    local map_width, map_height = Map.GetGridSize()
    local is_coastal = table.fill(false, map_width * map_height)

    for x = 0, map_width - 1 do
        for y = 0, map_height - 1 do
            if Lekmap_Utilities.AdjacentToOcean(x, y) then
                is_coastal[Lekmap_Utilities.PlotIndex(x, y)] = true
            end
        end
    end
    return is_coastal
end

--- Generates coastal and next-to-coastal data tables.
--- @return is_coastal, is_next_to_coast  boolean lookup tables
function Lekmap_Utilities.GenerateNextToCoastalLandDataTables()
    local is_coastal = Lekmap_Utilities.GenerateCoastalLandDataTable()
    local map_width, map_height = Map.GetGridSize()
    local is_next_to_coast = table.fill(false, map_width * map_height)

    for x = 0, map_width - 1 do
        for y = 0, map_height - 1 do
            local plot_index = Lekmap_Utilities.PlotIndex(x, y)
            local plot = Map.GetPlot(x, y)
            if not is_coastal[plot_index] and not plot:IsWater() then
                if Lekmap_Utilities.AnyAdjacentSatisfies(x, y, function(_, _, _, adj_index)
                    return is_coastal[adj_index] == true
                end) then
                    is_next_to_coast[plot_index] = true
                end
            end
        end
    end
    return is_coastal, is_next_to_coast
end

--- Generates a table marking plots three tiles from the coast.
--- @param  is_coastal        output of GenerateCoastalLandDataTable
--- @param  is_next_to_coast  output of GenerateNextToCoastalLandDataTables
--- @return is_three_from_coast  boolean lookup table
function Lekmap_Utilities.GenerateThreeFromCoastTable(is_coastal, is_next_to_coast)
    local map_width, map_height = Map.GetGridSize()
    local is_three_from_coast = table.fill(false, map_width * map_height)

    for x = 0, map_width - 1 do
        for y = 0, map_height - 1 do
            local plot_index = Lekmap_Utilities.PlotIndex(x, y)
            local plot = Map.GetPlot(x, y)
            if not is_coastal[plot_index] and not is_next_to_coast[plot_index] then
                if not plot:IsWater() or plot:IsFreshWater() then
                    if Lekmap_Utilities.AnyAdjacentSatisfies(x, y, function(_, _, _, adj_index)
                        return is_next_to_coast[adj_index] == true
                    end) then
                        is_three_from_coast[plot_index] = true
                    end
                end
            end
        end
    end
    return is_three_from_coast
end

--- Generates mainland coast data (ocean plots adjacent to biggest landmass).
--- @return is_mainland_coast  boolean lookup table
function Lekmap_Utilities.GenerateMainlandCoastDataTable()
    local map_width, map_height = Map.GetGridSize()
    local biggest_area = Map.FindBiggestArea(false)
    local mainland_area_id = biggest_area:GetID()
    local is_mainland_coast = table.fill(false, map_width * map_height)

    for x = 0, map_width - 1 do
        for y = 0, map_height - 1 do
            if Lekmap_Utilities.AdjacentToMainland(x, y, mainland_area_id) then
                is_mainland_coast[Lekmap_Utilities.PlotIndex(x, y)] = true
            end
        end
    end
    return is_mainland_coast
end

--- Generates mainland coast and expanded coast (2 tiles out) data.
--- @return is_mainland_coast, is_expanded_coast  boolean lookup tables
function Lekmap_Utilities.GenerateMainlandExpandedCoastData()
    local is_mainland_coast = Lekmap_Utilities.GenerateMainlandCoastDataTable()
    local map_width, map_height = Map.GetGridSize()
    local is_expanded_coast = table.fill(false, map_width * map_height)

    for x = 0, map_width - 1 do
        for y = 0, map_height - 1 do
            local plot_index = Lekmap_Utilities.PlotIndex(x, y)
            local plot = Map.GetPlot(x, y)
            if not is_mainland_coast[plot_index] and plot:IsWater()
            and plot:GetTerrainType() == TerrainTypes.TERRAIN_COAST then
                if Lekmap_Utilities.AnyAdjacentSatisfies(x, y, function(_, _, _, adj_index)
                    return is_mainland_coast[adj_index] == true
                end) then
                    is_expanded_coast[plot_index] = true
                end
            end
        end
    end
    return is_mainland_coast, is_expanded_coast
end

--- Generates table of plots three tiles from the mainland coast.
--- @param  is_mainland_coast  output of GenerateMainlandCoastDataTable
--- @param  is_expanded_coast  output of GenerateMainlandExpandedCoastData
--- @return is_three_from_mainland  boolean lookup table
function Lekmap_Utilities.GenerateThreeFromMainlandCoast(is_mainland_coast, is_expanded_coast)
    local map_width, map_height = Map.GetGridSize()
    local is_three_from_mainland = table.fill(false, map_width * map_height)

    for x = 0, map_width - 1 do
        for y = 0, map_height - 1 do
            local plot_index = Lekmap_Utilities.PlotIndex(x, y)
            local plot = Map.GetPlot(x, y)
            if not is_mainland_coast[plot_index] and not is_expanded_coast[plot_index]
            and plot:IsWater() and not plot:IsLake()
            and plot:GetTerrainType() == TerrainTypes.TERRAIN_COAST then
                if Lekmap_Utilities.AnyAdjacentSatisfies(x, y, function(_, _, _, adj_index)
                    return is_expanded_coast[adj_index] == true
                end) then
                    is_three_from_mainland[plot_index] = true
                end
            end
        end
    end
    return is_three_from_mainland
end

------------------------------------------------------------------------------
-- CIV START BIAS QUERIES
-- These read from the GameInfo database to determine start preferences
-- for specific civilizations.
------------------------------------------------------------------------------

--- Returns true if this civ type requires an ocean-adjacent start.
--- @param  civ_type  string civ type name (e.g. "CIVILIZATION_ENGLAND")
--- @return true if coastal start required
function Lekmap_Utilities.CivNeedsCoastalStart(civ_type)
    for row in GameInfo.Civilization_Start_Along_Ocean{ CivilizationType = civ_type } do
        if row.StartAlongOcean == true then
            return true
        end
    end
    return false
end

--- Returns true if this civ type requires a river-adjacent start.
function Lekmap_Utilities.CivNeedsRiverStart(civ_type)
    for row in GameInfo.Civilization_Start_Along_River{ CivilizationType = civ_type } do
        if row.StartAlongRiver == true then
            return true
        end
    end
    return false
end

--- Returns true if this civ type should be placed first among coastal starts.
function Lekmap_Utilities.CivNeedsPlaceFirstCoastalStart(civ_type)
    for row in GameInfo.Civilization_Start_Place_First_Along_Ocean{ CivilizationType = civ_type } do
        if row.PlaceFirst == true then
            return true
        end
    end
    return false
end

--- Returns the count of start region priorities for this civ.
function Lekmap_Utilities.GetNumStartRegionPriorityForCiv(civ_type)
    for row in DB.Query("select count(*) as count from Civilization_Start_Region_Priority where CivilizationType = ?", civ_type) do
        return row.count
    end
    return 0
end

--- Returns the count of start region avoids for this civ.
function Lekmap_Utilities.GetNumStartRegionAvoidForCiv(civ_type)
    for row in DB.Query("select count(*) as count from Civilization_Start_Region_Avoid where CivilizationType = ?", civ_type) do
        return row.count
    end
    return 0
end

--- Returns a sorted list of region type IDs this civ prioritizes.
function Lekmap_Utilities.GetStartRegionPriorityListForCiv_GetIDs(civ_type)
    local region_types = {}
    for row in GameInfo.Civilization_Start_Region_Priority{ CivilizationType = civ_type } do
        table.insert(region_types, row.RegionType)
    end
    local region_ids = {}
    for _, region_type_name in ipairs(region_types) do
        local region_type_id = GameInfo.Regions[region_type_name].ID
        if not Lekmap_Utilities.TestMembership(region_ids, region_type_id) then
            table.insert(region_ids, region_type_id)
        end
    end
    table.sort(region_ids)
    return region_ids
end

--- Returns a sorted list of region type IDs this civ avoids.
function Lekmap_Utilities.GetStartRegionAvoidListForCiv_GetIDs(civ_type)
    local region_types = {}
    for row in GameInfo.Civilization_Start_Region_Avoid{ CivilizationType = civ_type } do
        table.insert(region_types, row.RegionType)
    end
    local region_ids = {}
    for _, region_type_name in ipairs(region_types) do
        local region_type_id = GameInfo.Regions[region_type_name].ID
        if not Lekmap_Utilities.TestMembership(region_ids, region_type_id) then
            table.insert(region_ids, region_type_id)
        end
    end
    table.sort(region_ids)
    return region_ids
end

--- Returns an unsorted list of region type names this civ prioritizes.
function Lekmap_Utilities.GetStartRegionPriorityListForCiv_GetTypes(civ_type)
    local region_types = {}
    for row in GameInfo.Civilization_Start_Region_Priority{ CivilizationType = civ_type } do
        table.insert(region_types, row.RegionType)
    end
    return region_types
end

--- Returns an unsorted list of region type names this civ avoids.
function Lekmap_Utilities.GetStartRegionAvoidListForCiv_GetTypes(civ_type)
    local region_types = {}
    for row in GameInfo.Civilization_Start_Region_Avoid{ CivilizationType = civ_type } do
        table.insert(region_types, row.RegionType)
    end
    return region_types
end
