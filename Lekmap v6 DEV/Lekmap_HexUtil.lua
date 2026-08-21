------------------------------------------------------------------------------
--  FILE:     Lekmap_HexUtil.lua
--  AUTHOR:   EnormousApplePie (rewrite of PlotIterators by whoward69)
--  PURPOSE:  Hex grid iteration utilities for Lekmap.
--            Provides coroutine-based iterators for walking hex rings and
--            areas, using hex (x,y,z) coordinate math.
------------------------------------------------------------------------------
--  Uses engine globals: Map, ToHexFromGrid, ToGridFromHex
------------------------------------------------------------------------------
--luacheck: globals Lekmap_HexUtil
--luacheck: globals Map ToHexFromGrid ToGridFromHex

Lekmap_HexUtil = {}

-- Reachability for start-area supply: land never crosses water; sea resources
-- can be approached through passable land and shallow water. This is a bounded
-- geographic test, not a simulation of units, technologies or movement costs.
function Lekmap_HexUtil.ReachablePlots(x, y, radius, allow_water)
    local width = Map.GetGridSize()
    local origin = Map.GetPlot(x, y)
    if not origin then return {} end
    local seen = { [y * width + x + 1] = 0 }
    local queue, head = { origin }, 1
    while head <= #queue do
        local plot = queue[head]
        head = head + 1
        local distance = seen[plot:GetY() * width + plot:GetX() + 1]
        if distance < radius then
            for direction = 0, 5 do
                local next_plot = Map.PlotDirection(plot:GetX(), plot:GetY(), direction)
                if next_plot then
                    local index = next_plot:GetY() * width + next_plot:GetX() + 1
                    local water_ok = not next_plot:IsWater() or
                        (allow_water and next_plot:GetTerrainType() == TerrainTypes.TERRAIN_COAST)
                    if seen[index] == nil and water_ok and not next_plot:IsMountain()
                        and next_plot:GetFeatureType() ~= FeatureTypes.FEATURE_ICE then
                        seen[index] = distance + 1
                        queue[#queue + 1] = next_plot
                    end
                end
            end
        end
    end
    return seen
end

------------------------------------------------------------------------------
-- SECTOR AND DIRECTION CONSTANTS
------------------------------------------------------------------------------
Lekmap_HexUtil.SECTOR_NORTH          = 1
Lekmap_HexUtil.SECTOR_NORTHEAST      = 2
Lekmap_HexUtil.SECTOR_SOUTHEAST      = 3
Lekmap_HexUtil.SECTOR_SOUTH          = 4
Lekmap_HexUtil.SECTOR_SOUTHWEST      = 5
Lekmap_HexUtil.SECTOR_NORTHWEST      = 6

Lekmap_HexUtil.DIRECTION_CLOCKWISE        = false
Lekmap_HexUtil.DIRECTION_ANTICLOCKWISE    = true

Lekmap_HexUtil.DIRECTION_OUTWARDS    = false
Lekmap_HexUtil.DIRECTION_INWARDS     = true

Lekmap_HexUtil.CENTRE_INCLUDE        = true
Lekmap_HexUtil.CENTRE_EXCLUDE        = false

------------------------------------------------------------------------------
-- HEX EDGE WALKING FUNCTIONS
-- In hex coordinates x + y + z = 0, so z = -(x + y).
-- Each function walks one edge of a hex ring of the given radius.
------------------------------------------------------------------------------
local function EdgeNorth(hex_x, hex_y, radius, step)
    return { x = hex_x - radius + step, y = hex_y + radius }
end
local function EdgeNortheast(hex_x, hex_y, radius, step)
    return { x = hex_x + step, y = hex_y + radius - step }
end
local function EdgeSoutheast(hex_x, hex_y, radius, step)
    return { x = hex_x + radius, y = hex_y - step }
end
local function EdgeSouth(hex_x, hex_y, radius, step)
    return { x = hex_x + radius - step, y = hex_y - radius }
end
local function EdgeSouthwest(hex_x, hex_y, radius, step)
    return { x = hex_x - step, y = hex_y - radius + step }
end
local function EdgeNorthwest(hex_x, hex_y, radius, step)
    return { x = hex_x - radius, y = hex_y + step }
end

local ALL_EDGES = {
    EdgeNorth, EdgeNortheast, EdgeSoutheast,
    EdgeSouth, EdgeSouthwest, EdgeNorthwest,
}
local NUM_EDGES = 6

------------------------------------------------------------------------------
--- RotateEdges
--- Rotates the edge walk order so iteration starts from the given sector.
---
--- @param  sector       starting sector (1-6)
--- @param  anticlockwise  true to reverse walk direction
--- @return rotated edge function array
------------------------------------------------------------------------------
local function RotateEdges(sector, anticlockwise)
    local edges = {}
    for edge_index = 1, NUM_EDGES do
        edges[edge_index] = ALL_EDGES[edge_index]
    end
    if sector then
        local rotations = anticlockwise and 1 or 2
        for _ = 1, sector - rotations do
            table.insert(edges, table.remove(edges, 1))
        end
    end
    return edges
end

------------------------------------------------------------------------------
--- PlotRingIterator
--- Iterates over every plot on the border of a hex ring at the given radius,
--- centered on center_plot, starting from sector and moving in the given
--- direction.
---
--- @param  center_plot    engine plot object at the ring center
--- @param  radius         ring distance (must be >= 1)
--- @param  sector         starting sector (optional, default north)
--- @param  anticlockwise  true for counter-clockwise iteration
--- @return iterator function yielding plot objects
------------------------------------------------------------------------------
function Lekmap_HexUtil.PlotRingIterator(center_plot, radius, sector, anticlockwise)
    if center_plot == nil or radius <= 0 then
        return function() return nil end
    end

    local hex = ToHexFromGrid({ x = center_plot:GetX(), y = center_plot:GetY() })
    local hex_x, hex_y = hex.x, hex.y
    local edges = RotateEdges(sector, anticlockwise)

    local walker = coroutine.create(function()
        if anticlockwise then
            for side = NUM_EDGES, 1, -1 do
                for step = radius, 1, -1 do
                    coroutine.yield(edges[side](hex_x, hex_y, radius, step))
                end
            end
        else
            for side = 1, NUM_EDGES do
                for step = 0, radius - 1 do
                    coroutine.yield(edges[side](hex_x, hex_y, radius, step))
                end
            end
        end
        return nil
    end)

    return function()
        local result_plot = nil
        local success, hex_coord = coroutine.resume(walker)
        while success and hex_coord ~= nil and result_plot == nil do
            result_plot = Map.GetPlot(ToGridFromHex(hex_coord.x, hex_coord.y))
            if result_plot == nil then
                success, hex_coord = coroutine.resume(walker)
            end
        end
        return success and result_plot or nil
    end
end

------------------------------------------------------------------------------
--- PlotAreaSpiralIterator
--- Iterates over every plot within an area of the given radius in concentric
--- rings.  Can work outwards or inwards, optionally including the center.
---
--- @param  center_plot    engine plot object at the area center
--- @param  radius         maximum ring distance
--- @param  sector         starting sector (optional)
--- @param  anticlockwise  true for counter-clockwise
--- @param  inwards        true to spiral from outer ring inward
--- @param  include_centre true to yield the center plot
--- @return iterator function yielding plot objects
------------------------------------------------------------------------------
function Lekmap_HexUtil.PlotAreaSpiralIterator(center_plot, radius, sector, anticlockwise, inwards, include_centre)
    local walker = coroutine.create(function()
        if include_centre and not inwards then
            coroutine.yield(center_plot)
        end
        if inwards then
            for ring = radius, 1, -1 do
                for edge_plot in Lekmap_HexUtil.PlotRingIterator(center_plot, ring, sector, anticlockwise) do
                    coroutine.yield(edge_plot)
                end
            end
        else
            for ring = 1, radius do
                for edge_plot in Lekmap_HexUtil.PlotRingIterator(center_plot, ring, sector, anticlockwise) do
                    coroutine.yield(edge_plot)
                end
            end
        end
        if include_centre and inwards then
            coroutine.yield(center_plot)
        end
        return nil
    end)

    return function()
        local success, area_plot = coroutine.resume(walker)
        return success and area_plot or nil
    end
end

------------------------------------------------------------------------------
--- PlotAreaSweepIterator
--- Iterates over every plot within an area of the given radius by radial
--- sweep.  Instead of completing each ring before moving to the next, this
--- walks one plot from each ring per radial direction.
---
--- @param  center_plot    engine plot object at the area center
--- @param  radius         maximum ring distance
--- @param  sector         starting sector (optional)
--- @param  anticlockwise  true for counter-clockwise
--- @param  inwards        true to sweep from outer ring inward
--- @param  include_centre true to yield the center plot
--- @return iterator function yielding plot objects
------------------------------------------------------------------------------
function Lekmap_HexUtil.PlotAreaSweepIterator(center_plot, radius, sector, anticlockwise, inwards, include_centre)
    local walker = coroutine.create(function()
        if include_centre and not inwards then
            coroutine.yield(center_plot)
        end

        local ring_iterators = {}
        for ring = 1, radius do
            ring_iterators[ring] = Lekmap_HexUtil.PlotRingIterator(center_plot, ring, sector, anticlockwise)
        end

        for _ = 1, NUM_EDGES do
            if inwards then
                for outer = radius, 1, -1 do
                    for inner = radius, outer, -1 do
                        coroutine.yield(ring_iterators[inner]())
                    end
                end
            else
                for outer = 1, radius do
                    for inner = outer, radius do
                        coroutine.yield(ring_iterators[inner]())
                    end
                end
            end
        end

        if include_centre and inwards then
            coroutine.yield(center_plot)
        end
        return nil
    end)

    return function()
        local success, area_plot = coroutine.resume(walker)
        return success and area_plot or nil
    end
end
