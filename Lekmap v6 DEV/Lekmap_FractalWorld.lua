------------------------------------------------------------------------------
--	FILE:          Lekmap_FractalWorld.lua  (renamed from HBFractalWorld.lua)
--	AUTHOR:        Bob Thomas
--	PYTHON TO LUA: Shaun Seckman
--	CONTRIB:       Brian Wade
--	PURPOSE:       Default method for plot generation
------------------------------------------------------------------------------
--	Copyright (c) 2009, 2010 Firaxis Games, Inc. All rights reserved.
------------------------------------------------------------------------------

-------------------------------------------------------------------------------------------
FractalWorld = {}
-------------------------------------------------------------------------------------------
function FractalWorld.Create(frac_x_exp, frac_y_exp)
	
	local grid_width, grid_height = Map.GetGridSize()
	
	local data = {
		InitFractal = FractalWorld.InitFractal,
		ShiftPlotTypes = FractalWorld.ShiftPlotTypes,
		ShiftPlotTypesBy = FractalWorld.ShiftPlotTypesBy,
		DetermineXShift = FractalWorld.DetermineXShift,
		DetermineYShift = FractalWorld.DetermineYShift,
		GenerateCenterRift = FractalWorld.GenerateCenterRift,
		GeneratePlotTypes = FractalWorld.GeneratePlotTypes,
		
		fractal_flags = Map.GetFractalFlags(),
		
		frac_x_exp = frac_x_exp,
		frac_y_exp = frac_y_exp,
		
		num_plots_x = grid_width,
		num_plots_y = grid_height,
		plot_types = table.fill(PlotTypes.PLOT_OCEAN, grid_width * grid_height),
	}
		
	return data
end	
-------------------------------------------------------------------------------------------
function FractalWorld:InitFractal(args)
	if(args == nil) then args = {} end
	
	print("=============== USING NQ PANGAEA FRACTAL ===============")

	--local continent_grain = args.continent_grain or 2
	local continent_grain = 1
	--local rift_grain = args.rift_grain or -1 -- Default no rifts. Set grain to between 1 and 3 to add rifts. - Bob
	local rift_grain = 1
	--local invert_heights = args.invert_heights or false
	local invert_heights = false
	--local polar = args.polar or true
	local polar = true
	local ridge_flags = args.ridge_flags or self.fractal_flags
	
	local frac_flags = {}
	
	if(invert_heights) then
		frac_flags.FRAC_INVERT_HEIGHTS = true
	end
	
	if(polar) then
		frac_flags.FRAC_POLAR = true
	end
	
	if(rift_grain > 0 and rift_grain < 4) then
		self.rifts_frac = Fractal.Create((self.num_plots_x), self.num_plots_y, rift_grain, {}, self.frac_x_exp, self.frac_y_exp)
		self.continents_frac = Fractal.CreateRifts((self.num_plots_x * 1.1), self.num_plots_y, continent_grain, frac_flags, self.rifts_frac, self.frac_x_exp, self.frac_y_exp)
	else
		self.continents_frac = Fractal.Create(self.num_plots_x, self.num_plots_y, continent_grain, frac_flags, self.frac_x_exp, self.frac_y_exp)	
	end

	-- Use Brian's tectonics method to weave ridgelines in to the continental fractal.
	-- Without fractal variation, the tectonics come out too regular.
	--
	--[[ "The principle of the RidgeBuilder code is a modified Voronoi diagram. I 
	added some minor randomness and the slope might be a little tricky. It was 
	intended as a 'whole world' modifier to the fractal class. You can modify 
	the number of plates, but that is about it." ]]-- Brian Wade - May 23, 2009
	--
	local world_size_types = {}
	for row in GameInfo.Worlds() do
		world_size_types[row.Type] = row.ID
	end
	local size_key = Map.GetWorldSize()
	local size_values = {
		[world_size_types.WORLDSIZE_DUEL]     = 4,
		[world_size_types.WORLDSIZE_TINY]     = 8,
		[world_size_types.WORLDSIZE_SMALL]    = 8,
		[world_size_types.WORLDSIZE_STANDARD] = 20,
		[world_size_types.WORLDSIZE_LARGE]    = 24,
		[world_size_types.WORLDSIZE_HUGE]     = 32,
	}
	--
	local num_plates = size_values[size_key] or 4
	-- Blend a bit of ridge into the fractal.
	-- This will do things like roughen the coastlines and build inland seas. - Brian
	self.continents_frac:BuildRidges(num_plates, ridge_flags, 1, 4)
end
-------------------------------------------------------------------------------------------
function FractalWorld:ShiftPlotTypes()
	local strip_radius = self.strip_radius
	local shift_x = 0
	local shift_y = 0

	shift_x = self:DetermineXShift()
	shift_y = self:DetermineYShift()
	
	self:ShiftPlotTypesBy(shift_x, shift_y)
end
-------------------------------------------------------------------------------------------	
function FractalWorld:ShiftPlotTypesBy(x_shift, y_shift)
    if x_shift == 0 and y_shift == 0 then return end
    local buffer = {}
    for i = 1, self.num_plots_x * self.num_plots_y do buffer[i] = self.plot_types[i] end
    for y = 0, self.num_plots_y - 1 do
        for x = 0, self.num_plots_x - 1 do
            local sx = (x + x_shift) % self.num_plots_x
            local sy = (y + y_shift) % self.num_plots_y
            self.plot_types[y * self.num_plots_x + x + 1] = buffer[sy * self.num_plots_x + sx + 1]
        end
    end
end

-------------------------------------------------------------------------------------------
function FractalWorld:DetermineXShift()
	--[[ This function will align the most water-heavy vertical portion of the map with the 
	vertical map edge. This is a form of centering the landmasses, but it emphasizes the
	edge not the middle. If there are columns completely empty of land, these will tend to
	be chosen as the new map edge, but it is possible for a narrow column between two large 
	continents to be passed over in favor of the thinnest section of a continent, because
	the operation looks at a group of columns not just a single column, then picks the 
	center of the most water heavy group of columns to be the new vertical map edge. ]]--

	-- First loop through the map columns and record land plots in each column.
	local land_totals = {}
	for x = 0, self.num_plots_x - 1 do
		local current_column = 0
		for y = 0, self.num_plots_y - 1 do
			local i = y * self.num_plots_x + x + 1
			if (self.plot_types[i] ~= PlotTypes.PLOT_OCEAN) then
				current_column = current_column + 1
			end
		end
		table.insert(land_totals, current_column)
	end
	
	-- Now evaluate column groups, each record applying to the center column of the group.
	local column_groups = {}
	-- Determine the group size in relation to map width.
	local group_radius = math.floor(self.num_plots_x / 10)
	-- Measure the groups.
	for column_index = 1, self.num_plots_x do
		local current_group_total = 0
		for current_column = column_index - group_radius, column_index + group_radius do
			local current_index = current_column % self.num_plots_x
			if current_index == 0 then -- Modulo of the last column will be zero; this repairs the issue.
				current_index = self.num_plots_x
			end
			current_group_total = current_group_total + land_totals[current_index]
		end
		table.insert(column_groups, current_group_total)
	end
	
	-- Identify the group with the least amount of land in it.
	local best_value = self.num_plots_y * (2 * group_radius + 1) -- Set initial value to max possible.
	local best_group = 1 -- Set initial best group as current map edge.
	for column_index, group_land_plots in ipairs(column_groups) do
		if group_land_plots < best_value then
			best_value = group_land_plots
			best_group = column_index
		end
	end
	
	-- Determine X Shift
	local x_shift = best_group - 1
	return x_shift
end
-------------------------------------------------------------------------------------------
function FractalWorld:DetermineYShift()
	-- Counterpart to DetermineXShift()

	-- First loop through the map rows and record land plots in each row.
	local land_totals = {}
	for y = 0, self.num_plots_y - 1 do
		local current_row = 0
		for x = 0, self.num_plots_x - 1 do
			local i = y * self.num_plots_x + x + 1
			if (self.plot_types[i] ~= PlotTypes.PLOT_OCEAN) then
				current_row = current_row + 1
			end
		end
		table.insert(land_totals, current_row)
	end
	
	-- Now evaluate row groups, each record applying to the center row of the group.
	local row_groups = {}
	-- Determine the group size in relation to map height.
	local group_radius = math.floor(self.num_plots_y / 15)
	-- Measure the groups.
	for row_index = 1, self.num_plots_y do
		local current_group_total = 0
		for current_row = row_index - group_radius, row_index + group_radius do
			local current_index = current_row % self.num_plots_y
			if current_index == 0 then -- Modulo of the last row will be zero; this repairs the issue.
				current_index = self.num_plots_y
			end
			current_group_total = current_group_total + land_totals[current_index]
		end
		table.insert(row_groups, current_group_total)
	end
	
	-- Identify the group with the least amount of land in it.
	local best_value = self.num_plots_x * (2 * group_radius + 1) -- Set initial value to max possible.
	local best_group = 1 -- Set initial best group as current map edge.
	for row_index, group_land_plots in ipairs(row_groups) do
		if group_land_plots < best_value then
			best_value = group_land_plots
			best_group = row_index
		end
	end
	
	-- Determine Y Shift
	local y_shift = best_group - 1
	return y_shift
end
-------------------------------------------------------------------------------------------
function FractalWorld:GenerateCenterRift()
	-- Causes a rift to break apart and separate any landmasses overlaying the map center.
	-- Rift runs south to north ala the Atlantic Ocean.
	-- Any land plots in the first or last map columns will be lost, overwritten.
	-- This rift function is hex-dependent. It would have to be adapted to work with squares tiles.
	-- Center rift not recommended for non-oceanic worlds or with continent grains higher than 2.
	-- 
	-- First determine the rift "lean". 0 = Starts west, leans east. 1 = Starts east, leans west.
	local rift_lean = Map.Rand(2, "FractalWorld Center Rift Lean - Lua")
	
	-- Set up tables recording the rift line and the edge plots to each side of the rift line.
	local rift_line = {}
	local west_of_rift = {}
	local east_of_rift = {}
	-- Determine minimum and maximum length of line segments for each possible direction.
	local primary_max_length = math.max(1, math.floor(self.num_plots_y / 8))
	local secondary_max_length = math.max(1, math.floor(self.num_plots_y / 11))
	local tertiary_max_length = math.max(1, math.floor(self.num_plots_y / 14))
	
	-- Set rift line starting plot and direction.
	local start_distance_from_center = math.floor(self.num_plots_y / 8)
	if rift_lean == 0 then
		start_distance_from_center = -(start_distance_from_center)
	end
	local start_x = math.floor(self.num_plots_x / 2) + start_distance_from_center
	local start_y = 0
	local starting_direction = DirectionTypes.DIRECTION_NORTHWEST
	if rift_lean == 0 then
		starting_direction = DirectionTypes.DIRECTION_NORTHEAST
	end
	-- Set rift X boundary.
	local rift_x_boundary = math.floor(self.num_plots_x / 2) - start_distance_from_center
	
	-- Rift line is defined by a series of line segments traveling in one of three directions.
	-- East-leaning lines move NE primarily, NW secondarily, and E tertiary.
	-- West-leaning lines move NW primarily, NE secondarily, and W tertiary.
	-- Any E or W segments cause a wider gap on that row, requiring independent storage of data regarding west or east of rift.
	--
	-- Key variables need to be defined here so they persist outside of the various loops that follow.
	-- This requires that the starting plot be processed outside of those loops.
	local current_direction = starting_direction
	local current_x = start_x
	local current_y = start_y
	table.insert(rift_line, {current_x, current_y})
	-- Record west and east of the rift for this row.
	local row_index = current_y + 1
	west_of_rift[row_index] = current_x - 1
	east_of_rift[row_index] = current_x + 1
	-- Set this rift plot as type Ocean.
	local plot_index = current_x + 1 -- Lua arrays starting at 1 sure makes for a lot of extra work and chances for bugs.
	self.plot_types[plot_index] = PlotTypes.PLOT_OCEAN -- Tiles crossed by the rift all turn in to water.
	
	-- Generate the rift line.
	if rift_lean == 0 then -- Leans east
		while current_y < self.num_plots_y - 1 do
			-- Generate a line segment
			local next_direction = 0

			if current_direction == DirectionTypes.DIRECTION_EAST then
				local segment_length = Map.Rand(tertiary_max_length + 1, "FractalWorld Center Rift Segment Length - Lua")
				-- Choose next direction
				if current_x >= rift_x_boundary then -- Gone as far east as allowed, must turn back west.
					next_direction = DirectionTypes.DIRECTION_NORTHWEST
				else
					local dice = Map.Rand(3, "FractalWorld Center Rift Direction - Lua")
					if dice == 1 then
						next_direction = DirectionTypes.DIRECTION_NORTHWEST
					else
						next_direction = DirectionTypes.DIRECTION_NORTHEAST
					end
				end
				-- Process the line segment
				local plots_to_do = segment_length
				while plots_to_do > 0 do
					current_x = current_x + 1 -- Moving east, no change to Y.
					row_index = current_y
					-- west_of_rift[row_index] does not change.
					east_of_rift[row_index] = current_x + 1
					plot_index = current_y * self.num_plots_x + current_x + 1
					self.plot_types[plot_index] = PlotTypes.PLOT_OCEAN
					plots_to_do = plots_to_do - 1
				end

			elseif current_direction == DirectionTypes.DIRECTION_NORTHWEST then
				local segment_length = Map.Rand(secondary_max_length + 1, "FractalWorld Center Rift Segment Length - Lua")
				-- Choose next direction
				if current_x >= rift_x_boundary then -- Gone as far east as allowed, must turn back west.
					next_direction = DirectionTypes.DIRECTION_NORTHWEST
				else
					local dice = Map.Rand(4, "FractalWorld Center Rift Direction - Lua")
					if dice == 2 then
						next_direction = DirectionTypes.DIRECTION_EAST
					else
						next_direction = DirectionTypes.DIRECTION_NORTHEAST
					end
				end
				-- Process the line segment
				local plots_to_do = segment_length
				while plots_to_do > 0 and current_y < self.num_plots_y - 1 do
					-- Identifying hex plots other than to east or west is tricky.
					-- The X coord could be one of two possibilities.
					-- Call on Map.PlotDirection to safely handle this task.
					local next_plot = Map.PlotDirection(current_x, current_y, current_direction)
					current_x = next_plot:GetX()
					current_y = current_y + 1
					row_index = current_y
					west_of_rift[row_index] = current_x - 1
					east_of_rift[row_index] = current_x + 1
					plot_index = current_y * self.num_plots_x + current_x + 1
					self.plot_types[plot_index] = PlotTypes.PLOT_OCEAN
					plots_to_do = plots_to_do - 1
				end
				
			else -- NORTHEAST
				local segment_length = Map.Rand(primary_max_length + 1, "FractalWorld Center Rift Segment Length - Lua")
				-- Choose next direction
				if current_x >= rift_x_boundary then -- Gone as far east as allowed, must turn back west.
					next_direction = DirectionTypes.DIRECTION_NORTHWEST
				else
					local dice = Map.Rand(2, "FractalWorld Center Rift Direction - Lua")
					if dice == 1 and current_y > self.num_plots_y * 0.28 then
						next_direction = DirectionTypes.DIRECTION_EAST
					else
						next_direction = DirectionTypes.DIRECTION_NORTHWEST
					end
				end
				-- Process the line segment
				local plots_to_do = segment_length
				while plots_to_do > 0 and current_y < self.num_plots_y - 1 do
					-- Identifying hex plots other than to east or west is tricky.
					-- The X coord could be one of two possibilities.
					-- Call on Map.PlotDirection to safely handle this task.
					local next_plot = Map.PlotDirection(current_x, current_y, current_direction)
					current_x = next_plot:GetX()
					current_y = current_y + 1
					row_index = current_y
					west_of_rift[row_index] = current_x - 1
					east_of_rift[row_index] = current_x + 1
					plot_index = current_y * self.num_plots_x + current_x + 1
					self.plot_types[plot_index] = PlotTypes.PLOT_OCEAN
					plots_to_do = plots_to_do - 1
				end
			end
			
			-- Line segment is done, set next direction.
			current_direction = next_direction
		end

	else -- Leans west
		while current_y < self.num_plots_y - 1 do
			-- Generate a line segment
			local next_direction = 0

			if current_direction == DirectionTypes.DIRECTION_WEST then
				local segment_length = Map.Rand(tertiary_max_length + 1, "FractalWorld Center Rift Segment Length - Lua")
				-- Choose next direction
				if current_x <= rift_x_boundary then -- Gone as far west as allowed, must turn back east.
					next_direction = DirectionTypes.DIRECTION_NORTHEAST
				else
					local dice = Map.Rand(3, "FractalWorld Center Rift Direction - Lua")
					if dice == 1 then
						next_direction = DirectionTypes.DIRECTION_NORTHEAST
					else
						next_direction = DirectionTypes.DIRECTION_NORTHWEST
					end
				end
				-- Process the line segment
				local plots_to_do = segment_length
				while plots_to_do > 0 do
					current_x = current_x - 1 -- Moving west, no change to Y.
					row_index = current_y
					west_of_rift[row_index] = current_x - 1
					-- east_of_rift[row_index] does not change.
					plot_index = current_y * self.num_plots_x + current_x + 1
					self.plot_types[plot_index] = PlotTypes.PLOT_OCEAN
					plots_to_do = plots_to_do - 1
				end

			elseif current_direction == DirectionTypes.DIRECTION_NORTHEAST then
				local segment_length = Map.Rand(secondary_max_length + 1, "FractalWorld Center Rift Segment Length - Lua")
				-- Choose next direction
				if current_x <= rift_x_boundary then -- Gone as far west as allowed, must turn back east.
					next_direction = DirectionTypes.DIRECTION_NORTHEAST
				else
					local dice = Map.Rand(4, "FractalWorld Center Rift Direction - Lua")
					if dice == 2 then
						next_direction = DirectionTypes.DIRECTION_WEST
					else
						next_direction = DirectionTypes.DIRECTION_NORTHWEST
					end
				end
				-- Process the line segment
				local plots_to_do = segment_length
				while plots_to_do > 0 and current_y < self.num_plots_y - 1 do
					-- Identifying hex plots other than to east or west is tricky.
					-- The X coord could be one of two possibilities.
					-- Call on Map.PlotDirection to safely handle this task.
					local next_plot = Map.PlotDirection(current_x, current_y, current_direction)
					current_x = next_plot:GetX()
					current_y = current_y + 1
					row_index = current_y
					west_of_rift[row_index] = current_x - 1
					east_of_rift[row_index] = current_x + 1
					plot_index = current_y * self.num_plots_x + current_x + 1
					self.plot_types[plot_index] = PlotTypes.PLOT_OCEAN
					plots_to_do = plots_to_do - 1
				end
				
			else -- NORTHWEST
				local segment_length = Map.Rand(primary_max_length + 1, "FractalWorld Center Rift Segment Length - Lua")
				-- Choose next direction
				if current_x <= rift_x_boundary then -- Gone as far west as allowed, must turn back east.
					next_direction = DirectionTypes.DIRECTION_NORTHEAST
				else
					local dice = Map.Rand(2, "FractalWorld Center Rift Direction - Lua")
					if dice == 1 and current_y > self.num_plots_y * 0.28 then
						next_direction = DirectionTypes.DIRECTION_WEST
					else
						next_direction = DirectionTypes.DIRECTION_NORTHEAST
					end
				end
				-- Process the line segment
				local plots_to_do = segment_length
				while plots_to_do > 0 and current_y < self.num_plots_y - 1 do
					-- Identifying hex plots other than to east or west is tricky.
					-- The X coord could be one of two possibilities.
					-- Call on Map.PlotDirection to safely handle this task.
					local next_plot = Map.PlotDirection(current_x, current_y, current_direction)
					current_x = next_plot:GetX()
					current_y = current_y + 1
					row_index = current_y
					west_of_rift[row_index] = current_x - 1
					east_of_rift[row_index] = current_x + 1
					plot_index = current_y * self.num_plots_x + current_x + 1
					self.plot_types[plot_index] = PlotTypes.PLOT_OCEAN
					plots_to_do = plots_to_do - 1
				end
			end
			
			-- Line segment is done, set next direction.
			current_direction = next_direction
		end
	end
	-- Process the final plot in the rift.
	west_of_rift[self.num_plots_y] = current_x - 1
	east_of_rift[self.num_plots_y] = current_x + 1
	plot_index = (self.num_plots_y - 1) * self.num_plots_x + current_x + 1
	self.plot_types[plot_index] = PlotTypes.PLOT_OCEAN

	-- Now force the rift to widen, causing land on either side of the rift to drift apart.
	local horizontal_drift = 3
	local vertical_drift = 2
	--
	if rift_lean == 0 then
		-- Process Western side from top down.
		for y = self.num_plots_y - 1 - vertical_drift, 0, -1 do
			local this_row_x = west_of_rift[y+1]
			for x = horizontal_drift, this_row_x do
				local source_plot_index = y * self.num_plots_x + x + 1
				local dest_plot_index = (y + vertical_drift) * self.num_plots_x + (x - horizontal_drift) + 1
				self.plot_types[dest_plot_index] = self.plot_types[source_plot_index]
			end
		end
		-- Process Eastern side from bottom up.
		for y = vertical_drift, self.num_plots_y - 1 do
			local this_row_x = east_of_rift[y+1]
			for x = this_row_x, self.num_plots_x - horizontal_drift - 1 do
				local source_plot_index = y * self.num_plots_x + x + 1
				local dest_plot_index = (y - vertical_drift) * self.num_plots_x + (x + horizontal_drift) + 1
				self.plot_types[dest_plot_index] = self.plot_types[source_plot_index]
			end
		end
		-- Clean up remainder of tiles (by turning them all to Ocean).
		-- Clean up bottom left.
		for y = 0, vertical_drift - 1 do
			local this_row_x = west_of_rift[y+1]
			for x = 0, this_row_x do
				local plot_index = y * self.num_plots_x + x + 1
				self.plot_types[plot_index] = PlotTypes.PLOT_OCEAN
			end
		end
		-- Clean up top right.
		for y = self.num_plots_y - vertical_drift, self.num_plots_y - 1 do
			local this_row_x = east_of_rift[y+1]
			for x = this_row_x, self.num_plots_x - 1 do
				local plot_index = y * self.num_plots_x + x + 1
				self.plot_types[plot_index] = PlotTypes.PLOT_OCEAN
			end
		end
		-- Clean up the rift.
		for y = vertical_drift, self.num_plots_y - 1 - vertical_drift do
			local west_x = west_of_rift[y-vertical_drift+1] - horizontal_drift + 1
			local east_x = east_of_rift[y+vertical_drift+1] + horizontal_drift - 1
			for x = west_x, east_x do
				local plot_index = y * self.num_plots_x + x + 1
				self.plot_types[plot_index] = PlotTypes.PLOT_OCEAN
			end
		end

	else -- rift_lean = 1
		-- Process Western side from bottom up.
		for y = vertical_drift, self.num_plots_y - 1 do
			local this_row_x = west_of_rift[y+1]
			for x = horizontal_drift, this_row_x do
				local source_plot_index = y * self.num_plots_x + x + 1
				local dest_plot_index = (y - vertical_drift) * self.num_plots_x + (x - horizontal_drift) + 1
				self.plot_types[dest_plot_index] = self.plot_types[source_plot_index]
			end
		end
		-- Process Eastern side from top down.
		for y = self.num_plots_y - 1 - vertical_drift, 0, -1 do
			local this_row_x = east_of_rift[y+1]
			for x = this_row_x, self.num_plots_x - horizontal_drift - 1 do
				local source_plot_index = y * self.num_plots_x + x + 1
				local dest_plot_index = (y + vertical_drift) * self.num_plots_x + (x + horizontal_drift) + 1
				self.plot_types[dest_plot_index] = self.plot_types[source_plot_index]
			end
		end
		-- Clean up remainder of tiles (by turning them all to Ocean).
		-- Clean up top left.
		for y = self.num_plots_y - vertical_drift, self.num_plots_y - 1 do
			local this_row_x = west_of_rift[y+1]
			for x = 0, this_row_x do
				local plot_index = y * self.num_plots_x + x + 1
				self.plot_types[plot_index] = PlotTypes.PLOT_OCEAN
			end
		end
		-- Clean up bottom right.
		for y = 0, vertical_drift - 1 do
			local this_row_x = east_of_rift[y+1]
			for x = this_row_x, self.num_plots_x - 1 do
				local plot_index = y * self.num_plots_x + x + 1
				self.plot_types[plot_index] = PlotTypes.PLOT_OCEAN
			end
		end
		-- Clean up the rift.
		for y = vertical_drift, self.num_plots_y - 1 - vertical_drift do
			local west_x = west_of_rift[y+vertical_drift+1] - horizontal_drift + 1
			local east_x = east_of_rift[y-vertical_drift+1] + horizontal_drift - 1
			for x = west_x, east_x do
				local plot_index = y * self.num_plots_x + x + 1
				self.plot_types[plot_index] = PlotTypes.PLOT_OCEAN
			end
		end
	end
end
-------------------------------------------------------------------------------------------
function FractalWorld:GeneratePlotTypes(args)
	--[[ Civ4's truncated "Climate" setting has been abandoned. Civ5 has returned to 
	Civ3-style map options for World Age, Temperature, and Rainfall. Control over the 
	terrain has been removed from the XML.  - Bob Thomas, March 2010  ]]--
	--
	-- Sea Level and World Age map options affect only plot generation.
	-- Temperature map options affect only terrain generation.
	-- Rainfall map options affect only feature generation.
	--
	local args = args or {}
	local sea_level = args.sea_level or 2 -- Default is Medium sea level.
	local world_age = args.world_age or 2 -- Default is 4 Billion Years old.
	-- Note: World Age and Sea Level settings, if applicable, must be passed in by the map script.
	--
	local sea_level_low = args.sea_level_low or 65
	local sea_level_normal = args.sea_level_normal or 72
	local sea_level_high = args.sea_level_high or 78
	local world_age_old = args.world_age_old or 2
	local world_age_normal = args.world_age_normal or 3
	local world_age_new = args.world_age_new or 5
	--
	local extra_mountains = args.extra_mountains or 0
	local grain_amount = args.grain_amount or 3
	local adjust_plates = args.adjust_plates or 1.0
	local shift_plot_types = args.shift_plot_types ~= false
	local tectonic_islands = args.tectonic_islands or false
	local hills_ridge_flags = args.hills_ridge_flags or self.fractal_flags
	local peaks_ridge_flags = args.peaks_ridge_flags or self.fractal_flags
	local has_center_rift = args.has_center_rift or false
	
	-- Set Sea Level according to user selection. - Bob
	local water_percent = sea_level_normal
	if sea_level == 1 then -- Low Sea Level
		water_percent = sea_level_low
	elseif sea_level == 3 then -- High Sea Level
		water_percent = sea_level_high
	else -- Normal Sea Level
	end

	-- Set values for hills and mountains according to World Age chosen by user. - Bob
	local adjustment = world_age_normal
	if world_age == 3 then -- 5 Billion Years
		adjustment = world_age_old
		adjust_plates = adjust_plates * 0.75
	elseif world_age == 1 then -- 3 Billion Years
		adjustment = world_age_new
		adjust_plates = adjust_plates * 1.5
	else -- 4 Billion Years
	end
	-- Apply adjustment to hills and peaks settings.
	local hills_bottom_1 = 28 - adjustment
	local hills_top_1 = 28 + adjustment
	local hills_bottom_2 = 72 - adjustment
	local hills_top_2 = 72 + adjustment
	local hills_clumps = 1 + adjustment
	local hills_near_mountains = 90 - (adjustment * 2) - extra_mountains
	local mountains = 100 - adjustment - extra_mountains

	-- Hills and Mountains handled differently according to map size - Bob
	local world_size_types = {}
	for row in GameInfo.Worlds() do
		world_size_types[row.Type] = row.ID
	end
	local size_key = Map.GetWorldSize()
	-- Fractal Grains
	local size_values = {
		[world_size_types.WORLDSIZE_DUEL]     = 3,
		[world_size_types.WORLDSIZE_TINY]     = 3,
		[world_size_types.WORLDSIZE_SMALL]    = 4,
		[world_size_types.WORLDSIZE_STANDARD] = 4,
		[world_size_types.WORLDSIZE_LARGE]    = 5,
		[world_size_types.WORLDSIZE_HUGE]     = 5,
	}
	local grain = size_values[size_key] or 3
	-- Tectonics Plate Counts
	local plate_values = {
		[world_size_types.WORLDSIZE_DUEL]     = 6,
		[world_size_types.WORLDSIZE_TINY]     = 9,
		[world_size_types.WORLDSIZE_SMALL]    = 12,
		[world_size_types.WORLDSIZE_STANDARD] = 18,
		[world_size_types.WORLDSIZE_LARGE]    = 24,
		[world_size_types.WORLDSIZE_HUGE]     = 30,
	}
	local num_plates = plate_values[size_key] or 5
	-- Add in any plate count modifications passed in from the map script. - Bob
	num_plates = num_plates * adjust_plates

	-- Generate fractals to govern hills and mountains - Bob
	self.hills_frac = Fractal.Create(self.num_plots_x, self.num_plots_y, grain, self.fractal_flags, self.frac_x_exp, self.frac_y_exp)
	self.mountains_frac = Fractal.Create(self.num_plots_x, self.num_plots_y, grain, self.fractal_flags, self.frac_x_exp, self.frac_y_exp)

	-- Use Brian's tectonics method to weave ridgelines in to the fractals.
	-- Without fractal variation, the tectonics come out too regular.
	--
	--[[ "The principle of the RidgeBuilder code is a modified Voronoi diagram. I 
	added some minor randomness and the slope might be a little tricky. It was 
	intended as a 'whole world' modifier to the fractal class. You can modify 
	the number of plates, but that is about it." ]]-- Brian Wade - May 23, 2009
	--
	-- Have the hills be clumpy with a bit of ridges in them - Brian
	self.hills_frac:BuildRidges(num_plates, hills_ridge_flags, 1, 2)
	-- Have the mountain ranges tend to be be distinct - Brian
	self.mountains_frac:BuildRidges((num_plates * 2) / 3, peaks_ridge_flags, 6, 1)

	-- Get height values for plot types
	local water_threshold = self.continents_frac:GetHeight(water_percent)
	local hills_bottom_1_threshold = self.hills_frac:GetHeight(hills_bottom_1)
	local hills_top_1_threshold = self.hills_frac:GetHeight(hills_top_1)
	local hills_bottom_2_threshold = self.hills_frac:GetHeight(hills_bottom_2)
	local hills_top_2_threshold = self.hills_frac:GetHeight(hills_top_2)
	local hills_clumps_threshold = self.mountains_frac:GetHeight(hills_clumps)
	local hills_near_mountains_threshold = self.mountains_frac:GetHeight(hills_near_mountains)
	local mountain_threshold = self.mountains_frac:GetHeight(mountains)
	local pass_threshold = self.hills_frac:GetHeight(hills_near_mountains)

	-- Get height values for tectonic islands
	local mountain_100 = self.mountains_frac:GetHeight(100)
	local mountain_99 = self.mountains_frac:GetHeight(99)
	local mountain_97 = self.mountains_frac:GetHeight(97)
	local mountain_95 = self.mountains_frac:GetHeight(95)
	
	--[[ Activate printout for debugging only.
	print("-") print("--- Plot Generation Readout ---")
	print("- Sea Level Setting:", sea_level)
	print("- World Age Setting:", world_age)
	print("- Water Percentage:", water_percent)
	print("- Mountain Threshold:", mountains)
	print("- Foot Hills Threshold:", hills_near_mountains)
	print("- Clumps of Hills %:", hills_clumps)
	print("- Loose Hills %:", 4 * adjustment)
	print("- Tectonic Plate Count:", num_plates)
	print("- Tectonic Islands?", tectonic_islands)
	print("- Center Rift?", has_center_rift)
	print("- - - - - - - - - - - - - - - - -")
	]]--

	-- Main loop
	for x = 0, self.num_plots_x - 1 do
		for y = 0, self.num_plots_y - 1 do
		
			local i = y * self.num_plots_x + x + 1
			local continent_val = self.continents_frac:GetHeight(x, y)
			local mountain_val = self.mountains_frac:GetHeight(x, y)
			local hill_val = self.hills_frac:GetHeight(x, y)
	
			if(continent_val <= water_threshold) then
				self.plot_types[i] = PlotTypes.PLOT_OCEAN
				
				if tectonic_islands then -- Build islands in oceans along tectonic ridge lines - Brian
					if (mountain_val == mountain_100) then -- Isolated peak in the ocean
						self.plot_types[i] = PlotTypes.PLOT_MOUNTAIN
					elseif (mountain_val == mountain_99) then
						self.plot_types[i] = PlotTypes.PLOT_HILLS
					elseif (mountain_val == mountain_97) or (mountain_val == mountain_95) then
						self.plot_types[i] = PlotTypes.PLOT_LAND
					end
				end
					
			else
				if (mountain_val >= mountain_threshold) then
					if (hill_val >= pass_threshold) then -- Mountain Pass though the ridgeline - Brian
						self.plot_types[i] = PlotTypes.PLOT_HILLS
					else -- Mountain
						self.plot_types[i] = PlotTypes.PLOT_MOUNTAIN
					end
				elseif (mountain_val >= hills_near_mountains_threshold) then
					self.plot_types[i] = PlotTypes.PLOT_HILLS -- Foot hills - Bob
				else
					if ((hill_val >= hills_bottom_1_threshold and hill_val <= hills_top_1_threshold) or (hill_val >= hills_bottom_2_threshold and hill_val <= hills_top_2_threshold)) then
						self.plot_types[i] = PlotTypes.PLOT_HILLS
					else
						self.plot_types[i] = PlotTypes.PLOT_LAND
					end
				end
			end
		end
	end

	if(shift_plot_types) then
		self:ShiftPlotTypes()
		-- Center Rift warrants plot shifting to guarantee centered landmasses.
		if(has_center_rift) then
			self:GenerateCenterRift()
		end
	end

	return self.plot_types
end
-------------------------------------------------------------------------------------------
